# Postulate Stage 0 — Parser technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **parserének** technikai
> specifikációja: típusok, kifejezések, utasítások, deklarációk, blokkok és
> a felső szintű deklarációk (`type`, `expr`, `stmt`, `decl`, `block`,
> `func_block`, `function`, `struct_decl`, `extern_decl`, `params`,
> `program`). Előfeltétele a
> [postulate_stage0_spec.md](postulate_stage0_spec.md) (nyelvtan, szemantika)
> és a [postulate_stage0_lexer_spec.md](postulate_stage0_lexer_spec.md) (a már
> elkészült, tesztelt lexer — ennek `lex_next` rutinjára épül minden itt
> leírtak). Ezzel a menettel a `build/parser` a Stage 0 EBNF **teljes**
> nyelvtanát lefedi — a `program` szabálytól a legmélyebb kifejezés-szintig.

---

## 1. Cél és hatókör

A `type` és `expr` nyelvtani szabályok (ld. fő spec 4. fejezete) a legönállóbb,
mindenhonnan újrahasznosított építőelemek — deklarációk, paraméterek,
struct-mezők, mind típusra hivatkoznak; utasítások, kezdőértékek, mind
kifejezésre. Ezért ezek kapták az első, önmagában tesztelhető parser-szeletet.
Erre épül a második szelet: **utasítások, deklarációk, blokkok** — minden, ami
egy függvénytörzs parsolásához kell (`func_block`). A harmadik, ezzel a
menettel lezáruló szelet: **a felső szintű deklarációk** —
`function`/`struct_decl`/`extern_decl`, a köztük megosztott `params`/`param`
gépezet, és a mindezt összefogó `program` szabály. Ezzel a `build/parser`
egy teljes Stage 0 forrásfájlt elejétől végéig fel tud dolgozni.

A cél egy **különálló `build/parser` bináris**, ami stdin-ről egy irányjelző
sorral kezdődő forrást olvas (`TYPE`, `EXPR`, `DECL`, `STMT`, `FUNC_BLOCK`,
`TOP_LEVEL_DECL` vagy `PROGRAM`, ld. 14. fejezet), a maradékot a megfelelő
nyelvtani szabály szerint parsolja, és az eredmény AST-t szöveges,
zárójelezett formában (S-kifejezés, ld. 12. fejezet) írja ki stdoutra — vagy
szintaktikai hiba esetén diagnosztikát ír stderr-re és `exit(1)`-gyel lép ki.

---

## 2. Eszközlánc és build-környezet

Változatlan a lexerhez képest (NASM, Intel szintaxis; `ld -static -no-pie`;
Docker, `ubuntu:24.04`) — ld. a lexer-spec 2. fejezetét. A `build/lexer`
mellett egy **második, önálló `build/parser` bináris** készül, saját
`_start`-tal.

---

## 3. Megosztott futásidejű kód kiemelése (`runtime.asm`)

A lexer driver (`main.asm`) tartalmazza a pufferelt syscall I/O-t
(`read_all`, `write_all`, `emit_str`, `flush_out`) és a diagnosztika-építést
(`compute_line_col`, `err_append_str`, `err_append_dec`, `err_append_hex_byte`).
Ezek (és a hozzájuk tartozó `.bss`: `src_buf`, `src_len`, `scratch_byte`,
`out_buf`, `out_cursor`, `err_buf`, `err_cursor`) a `runtime.asm`/`runtime.inc`
párban élnek, amit mindkét bináris linkel. A `main.asm`-ben marad minden, ami
kizárólag a lexer-driveré.

---

## 4. AST-csomópont reprezentáció

Nincs dinamikus memóriafoglalás sehol a projektben (ld. fő spec 2. fejezete) —
az AST csomópontjai egy fix méretű **aréna** (bump allocator) fölött élnek,
sosem szabadulnak fel egyenként.

### 4.1 Csomópont-layout: 40 bájt, `kind` + 4 általános mező

| Mező | Offszet | Tartalom |
|---|---|---|
| `kind` | 0 | az alábbi `AST_*` konstansok egyike |
| `a` | 8 | csomópont-specifikus |
| `b` | 16 | csomópont-specifikus |
| `c` | 24 | csomópont-specifikus |
| `d` | 32 | csomópont-specifikus |

### 4.2 Csomópont-fajták — típusok és kifejezések

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_TY_BASE` | beépített típus-tag (0, ha azonosítónévvel hivatkozott típus; egyébként a `TOK_KW_INT8`..`TOK_KW_BOOL` konstans) | `name_offset` | `name_len` | — |
| `AST_TY_POINTER` | `inner` (csomópont-ptr) | — | — | — |
| `AST_TY_ARRAY` | `elem` (csomópont-ptr) | `count` | — | — |
| `AST_EX_INT` | `value` | — | — | — |
| `AST_EX_BOOL` | `value` (0/1) | — | — | — |
| `AST_EX_NULL` | — | — | — | — |
| `AST_EX_IDENT` | `name_offset` | `name_len` | — | — |
| `AST_EX_UNARY` | `op` (`TOK_BANG`/`TOK_MINUS`/`TOK_STAR`/`TOK_AMP`) | `operand` (ptr) | — | — |
| `AST_EX_BINARY` | `op` (`TOK_ASSIGN`..`TOK_PIPE` tartomány) | `left` (ptr) | `right` (ptr) | — |
| `AST_EX_INDEX` | `base` (ptr) | `index` (ptr) | — | — |
| `AST_EX_FIELD` | `base` (ptr) | `name_offset` | `name_len` | — |
| `AST_EX_CALL` | `callee` (ptr) | `args` (ptr aréna-tömbre, 0 ha nincs argumentum) | `arg_count` | — |
| `AST_EX_STRUCT_LIT` | `name_offset` | `name_len` | `fields` (ptr `AST_FIELD_INIT`-ptr tömbre) | `field_count` (≥1) |
| `AST_EX_ARRAY_LIT` | `elems` (ptr ptr-tömbre) | `elem_count` (≥1) | — | — |
| `AST_FIELD_INIT` | `name_offset` | `name_len` | `value` (ptr) | — |

**Nincs külön "pointer-tömb" csomópont-fajta.** A `*T[N]` (zárójel nélkül,
alapértelmezett forma) `AST_TY_ARRAY{ elem = AST_TY_POINTER{T} }`-ként épül; a
`*(T[N])` (zárójellel) `AST_TY_POINTER{ inner = AST_TY_ARRAY{T, N} }`-ként —
ugyanaz a két csomópont-fajta, csak más sorrendben összeállítva (ld. 7.
fejezet).

### 4.3 Csomópont-fajták — utasítások, deklarációk, blokkok

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_DECL_MUT` | `name_offset` | `name_len` | `type` (ptr) | `init` (ptr, 0 ha nincs) |
| `AST_DECL_CONST` | `name_offset` | `name_len` | `type` (ptr) | `init` (ptr, 0 ha nincs) |
| `AST_ASSIGN_PAIR` | `lvalue` (kifejezés-alakú ptr) | `rhs` (ptr) | — | — |
| `AST_STMT_ASSIGN` | `pairs` (ptr aréna-tömbre) | `pair_count` (mindig ≥1, ld. lent) | — | — |
| `AST_STMT_IF` | `cond` (ptr) | `then_block` (`AST_BLOCK` ptr) | `else_block` (ptr, 0 ha nincs) | — |
| `AST_STMT_WHILE` | `cond` (ptr) | `body` (`AST_BLOCK` ptr) | — | — |
| `AST_STMT_RETURN` | `expr` (ptr, 0 ha nincs) | — | — | — |
| `AST_STMT_EXPR` | `expr` (ptr) | — | — | — |
| `AST_BLOCK` | `stmts` (ptr aréna-tömbre) | `stmt_count` (≥0 — `stmt*`) | — | — |
| `AST_FUNC_BLOCK` | `decls` (ptr aréna-tömbre) | `decl_count` (≥0) | `stmts` (ptr aréna-tömbre) | `stmt_count` (≥0) |

**Az `AST_DECL_MUT`/`AST_DECL_CONST` két külön `kind`, nem egy közös
csomópont + flag-mező** — ez szabadít fel egy negyedik mezőt (`d` = `init`),
ugyanúgy, ahogy az `AST_EX_BOOL` sem különálló "bool-tag" mezőt kapott, hanem
maga a `value` (0/1) hordozza a jelentést.

**Az `AST_STMT_ASSIGN.pair_count` sosem lehet 0**, ezért (szemben az
`array_literal`/`struct_literal`-lal) nincs "üres lista hiba" ág — az első pár
a parsolási algoritmus szerkezete miatt garantáltan létezik: a pár-építő ciklus
csak azután indul, hogy már megbizonyosodtunk róla, hogy `tok_cur == TOK_ASSIGN`
(ld. 9. fejezet).

**A `lvalue` nem kap külön csomópont-fajtát** — a meglévő `AST_EX_UNARY`
(`*lvalue` forma), `AST_EX_IDENT`, `AST_EX_INDEX`, `AST_EX_FIELD` csomópontokat
használja újra, mert az `lvalue` nyelvtanilag szigorúan részhalmaza az
`expr`-nek (ld. 9. fejezet indoklása).

### 4.4 Aréna és allokátor

```nasm
AST_ARENA_SIZE equ 1024*1024   ; 1 MiB (config.inc-ben, az SRC_BUF_SIZE mintájára)
MAX_LIST_ARITY equ 256          ; egyetlen változó aritású lista fix felső korlátja
```

`ast_arena: resb AST_ARENA_SIZE` + `ast_cursor: resq 1` (bump-pointer). A
`.bss` betöltéskor nullázott — mivel ez egyetlen, egyszeri lefutású folyamat,
a csomópontok mezői "hiányzó = 0" alapon kezelhetők explicit nullázás nélkül.

- **`ast_alloc_node`** — be: `rdi` = `kind`. ki: `rax` = friss, `kind`-del
  megjelölt 40 bájtos csomópont-pointer.
- **`ast_alloc_bytes`** — be: `rdi` = bájtszám (mindig `elemszám*8`, ptr-tömbökhöz). ki: `rax` = pointer.

Mindkettő **hiba esetén** (aréna kimerülése) fatal: rögzített stderr-üzenet,
`exit(2)`.

### 4.5 Csomópont-fajták — felső szintű deklarációk

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_PARAM` | `name_offset` | `name_len` | `type` (ptr) | — |
| `AST_FIELD_DECL` | `name_offset` | `name_len` | `type` (ptr) | — |
| `AST_SIGNATURE` | `name_offset` | `name_len` | `params` (ptr aréna-tömbre) | `param_count` |
| `AST_STRUCT_DECL` | `name_offset` | `name_len` | `fields` (ptr aréna-tömbre) | `field_count` (≥1) |
| `AST_FUNCTION` | `signature` (ptr) | `return_type` (ptr, 0 = `void`) | `body` (`AST_FUNC_BLOCK` ptr) | — |
| `AST_EXTERN_DECL` | `signature` (ptr) | `return_type` (ptr, 0 = `void`) | — | — |
| `AST_PROGRAM` | `decls` (ptr aréna-tömbre) | `decl_count` (≥1) | — | — |

**Miért van külön `AST_SIGNATURE` csomópont, ahelyett hogy `AST_FUNCTION`
közvetlenül tartalmazná mindet?** A `function` és az `extern_decl` a
nyelvtanban szó szerint megosztja az `identifier "(" params? ")"` részt.
Egy `function`-nek 6 mezőnyi hasznos adatra lenne szüksége: név
(offset+len = 2 mező, mert a kódbázis konvenciója szerint a névfoglalás
sosem a leírás másolása, hanem mindig a forrás visszaszeletelése — ld. 4.1)
+ a `params` *lista* (ptr+count = 2 mező, a paraméterek tényleges száma
akárhány lehet, a `sys_write` 3 és a `sys_mmap` 6 paramétere is ugyanarra a
"ptr, count" párra esik össze parsolás után) + `return_type` (1) +
`body` (1). Ez több, mint a négy általános mező. Ahelyett, hogy ad hoc
csomagolással megoldanánk, kiemeltük a közös prefixet egy önálló
`AST_SIGNATURE` csomópontba — ugyanaz az elv, mint amivel az
`AST_ASSIGN_PAIR`/`AST_FIELD_INIT` is kiemeli a nagyobb szerkezetekből a
közös alakot. Az `AST_FUNCTION` és `AST_EXTERN_DECL` így már csak 2–3 mezőt
használ (`signature` ptr + `return_type` ptr, `AST_FUNCTION` esetén
`body` ptr is), és a felbontás magát az EBNF saját közös-prefix
faktorálását tükrözi, nem harcol ellene. A `return_type` ugyanazt a
"0 = hiányzik" konvenciót használja, mint a `STMT_RETURN` kifejezése, a
`DECL` kezdőértéke, vagy a `STMT_IF` `else`-ága — `0` jelenti a `void`-ot,
mivel a `void` nem tagja a `type` szabálynak, tehát nem keverhető össze
egy valódi típus-pointerrel.

**Az `AST_PARAM` és az `AST_FIELD_DECL` szerkezetileg azonos** (mindkettő
csak "név : típus"), mégis két külön `kind` — mert két külön nyelvtani
szabály, egymástól független kontextusban (függvény-aláírás vs.
struct-test), különböző jövőbeli szemantikai szereppel (hívási konvenció
vs. mező-elrendezés). Ugyanaz az indoklás, amivel az `AST_DECL_MUT`/
`AST_DECL_CONST` is két külön `kind` maradt a majdnem azonos alak ellenére.

---

## 5. Token-előretekintés (`parser_tokens.asm`)

A `lex_next` egyetlen tokent ad vissza hívásonként, explicit kurzorral. A
parsernek **2 tokenes előretekintés** kell — sem többre, sem kevesebbre —, mert
a nyelvtanban pontosan két helyen kell "a jelenlegi token utáni token"-t
megnézni anélkül, hogy elfogyasztanánk:

1. A típus-nyelvtan pointer-tömb egyértelműsítése.
2. A `struct_literal` és a puszta `identifier` szétválasztása `primary`-ban.

```nasm
tok_cur:        resb TOKEN_SIZE   ; 32 bájt, a tokens.inc-ből
tok_peek:       resb TOKEN_SIZE
tok_peek_valid: resq 1
raw_cursor:     resq 1             ; a lex_next saját, bájt-offszet kurzora
```

- **`parser_init`** (be: `rdi`=forráspuffer, `rsi`=kezdő offszet, `rdx`=hossz):
  beállítja a globálisokat, meghívja `parser_advance`-t egyszer.
- **`parser_advance`**: ha `tok_peek_valid`, 32 bájtot másol `tok_peek`→`tok_cur`;
  egyébként közvetlenül hívja `lex_next`-et `tok_cur`-ba.
- **`parser_peek`**: ha `!tok_peek_valid`, `lex_next`-et hív `tok_peek`-be; **nem
  fogyaszt**. Ki: `rax` = `tok_peek` címe.
- **`parser_expect`** (be: `rdi`=elvárt `TOK_*` kind, `rsi`/`rdx`=hibaüzenet):
  ha nem egyezik, `report_parse_error`; egyébként `parser_advance`.

---

## 6. Típus-parser (`type_parser.asm`)

`token_starts_base_type(kind)`: `kind == TOK_IDENT`, vagy `TOK_KW_INT8 <= kind
<= TOK_KW_BOOL` (a `tokens.inc` 22–32 tartománya).

`parse_type` — kizárólag `tok_cur.kind` alapján dönt, **visszalépés nélkül**:

- **`TOK_STAR`**: fogyaszt. Ha `token_starts_base_type(tok_cur)` **és**
  `parser_peek().kind == TOK_LBRACKET`: `base_type` → `AST_TY_POINTER` →
  `[ INT ]` → `AST_TY_ARRAY{elem=pointer_csomópont, count=N}` (alapértelmezett
  "N pointer tömbje" forma). Egyébként: rekurzívan `parse_type` az
  operandusra, `AST_TY_POINTER{inner}` (fedi a `*(T[N])` esetet is).
- **`TOK_LPAREN`**: fogyaszt, rekurzívan `parse_type`, `)` elvárása, burok
  nélküli visszaadás.
- **`token_starts_base_type`**: `base_type`; ha `[` következik, `AST_TY_ARRAY`;
  egyébként változatlanul.
- egyébként: `report_parse_error("expected type")`.

---

## 7. Kifejezés-parser (`expr_parser.asm`)

**Egy nyelvtani szint = egy rutin**, közvetlen fordítása az EBNF láncnak (nem
Pratt/precedencia-mászás).

A lánc: `parse_logic_or` → `parse_logic_and` → `parse_comparison` →
`parse_bit_or` → `parse_bit_xor` → `parse_bit_and` → `parse_shift` →
`parse_additive` → `parse_multiplicative` → `parse_unary` → `parse_postfix` →
`parse_primary`. Minden bináris szint (a `comparison` kivételével) egy `while`
ciklus.

**`parse_comparison`** az egyetlen kivétel — `if`, nem `while` (a nyelvtan `?`
jelének szó szerinti fordítása; egy második összehasonlító operátor
fogyasztatlanul marad, és a driver záró EOF-ellenőrzésén bukik el — ez a
szándékolt mechanizmus, nem hiányosság).

**`parse_unary`** (jobbról-balra asszociatív prefix-lánc, `! - * &`).

**`parse_postfix`** (balról-jobbra asszociatív szuffix-hurok: `[expr]` →
`AST_EX_INDEX`, `.identifier` → `AST_EX_FIELD`, `(args?)` → `AST_EX_CALL`).

**`parse_primary`**: `TOK_IDENT` esetén `parser_peek`; ha `{` következik,
`parse_struct_literal`; egyébként `AST_EX_IDENT`. `TOK_INT`/`TOK_KW_TRUE`/
`TOK_KW_FALSE`/`TOK_KW_NULL`/`TOK_LPAREN`/`TOK_LBRACE` a megfelelő ágra.

---

## 8. Változó aritású listák

A `call`-argumentumok, a `struct_literal` mezőlistája, az `array_literal`
elemlistája, az `assign_stmt` pár-listája, a `block`/`func_block`
utasítás-listája, a `func_block` deklaráció-listája — és ebben a menetben
újonnan a `params` paraméterlistája, a `struct_decl` mezőlistája (`field_decl+`)
és a `program` deklaráció-listája (`top_level_decl+`) — mind ugyanazt a
mintát követik, dinamikus memóriafoglalás nélkül:

1. `MAX_LIST_ARITY*8` bájt fenntartása a **gépi verem**-en (`sub rsp, ...`).
2. Elemek parsolása egyesével, mindegyik pointer beírása a verem-scratch-be.
3. Lezáráskor `ast_alloc_bytes(count*8)` az arénában, majd pontos méretű
   másolás oda.
4. A verem-scratch felszabadítása (`add rsp, ...`).

**Miért verem, és nem közös globális scratch-puffer?** Egy `{1, mult(4), 9}`
tömb-literál második eleme maga is egy függvényhívás saját
argumentumlistával — a natív verem-rekurzió (minden beágyazott lista-parsolás
saját, friss `rsp`-relatív scratch-tartományt kap) ezt ingyen megoldja.

Arítás-követelmények szabályai listánként:
- `parse_call_args`, `parse_params`: 0 is megengedett (`args ::= expr_list?`,
  `params ::= param ("," param)*` a hívó oldali `params?`-on keresztül) —
  vessző-elválasztott, üres eset ellenőrzés nélkül megengedett.
- `parse_array_literal`, struct-literal mezőlista: **legalább 1** kötelező,
  vessző-elválasztott.
- `assign_stmt` pár-listája: nincs explicit "üres lista" ág — szerkezetileg
  garantált legalább 1 (ld. 4.3).
- `block` (`stmt*`) és `func_block` deklaráció-listája (`decl*`): **0 is
  megengedett** — nincs "legalább 1" ellenőrzés, mert a nyelvtanban itt nincs
  `+`, csak `*`.
- `func_block` **két egymást követő** (nem egymásba ágyazott) változó aritású
  listát fut le ugyanazon a verem-scratch-tartományon: a deklaráció-lista
  teljesen lezárul (aréna-commit + `rsp` felszabadítás) még mielőtt az
  utasítás-lista scratch-je lefoglalódna — nincs időbeli átfedés, tehát nincs
  ütközés.
- `struct_decl` mezőlistája (`field_decl+`) és `program` deklaráció-listája
  (`top_level_decl+`): **legalább 1** kötelező, de **nincs vessző-elválasztó**
  — mindegyik elem önmagát zárja (`field_decl`-t a saját `;`-je,
  `top_level_decl`-t a nyelvtani szerkezete), tehát a ciklus feltétele "a
  záró token (`}` / `EOF`) ellenőrzése minden elem után", nem "vessző
  ellenőrzése". Az üres eset dedikált hibaüzenettel van ellenőrizve előre —
  ugyanaz a minta, mint az `array_literal`/`struct_literal` "legalább 1"
  ellenőrzése —, nem a `func_block` decl/stmt-sorrend hibájának automatikus
  átbukására hagyatkozva (ld. 9.2 és 10.4): ott volt egy alacsonyabb
  precedenciájú szabály, amire át lehetett bukni; itt nincs.

---

## 9. Utasítás- és deklaráció-parser (`stmt_parser.asm`)

### 9.1 Az `assign_stmt` / `expr_stmt` szétválasztása

A `stmt` nyelvtan `assign_stmt` és `expr_stmt` alternatívái ugyanazokkal a
tokenekkel kezdődhetnek — az `lvalue` és az `expr` a legelején teljesen
átfedi egymást (mindkettő kezdődhet `*`-gal vagy azonosítóval). A formális
nyelvtan az `lvalue`-t saját, szűkebb szabályként definiálja (nincs hívás,
nincs bináris operátor, nincs literál — csak `*`-prefix lánc és
azonosító+index/mező-szuffix).

Két megoldás közül választva:

- **Dedikált, szigorúan `lvalue`-nyelvtant követő `parse_lvalue`.** Elvetve:
  egy `mult(4);` (`expr_stmt`) esetén egy valóban szigorú `parse_lvalue` a
  `mult`-ot fogyasztaná el, majd megállna a `(`-nál (a hívás-szuffix nincs az
  `lvalue` nyelvtanban) — az innen való felépüléshez vagy visszalépés kellene,
  vagy a `parse_lvalue`-nak úgyis újra kellene implementálnia a
  `parse_postfix`/`parse_unary` logikáját a tartalék esetre. Ez több kódot és
  nagyobb hibafelületet jelentene azért a haszonért (az `1 + 2 := 3;`
  elutasítása parsolási időben), amit a projekt már korábban is szándékosan a
  szemantikai fázisra halasztott máshol (struct-literal mezőteljesség,
  based-form számjegy-tartomány).
- **A meglévő `parse_expr()` hívása mindig elsőként, majd elágazás
  `tok_cur.kind == TOK_ASSIGN` szerint.** *Ez a választott megoldás.* A
  `TOK_ASSIGN` (`:=`) az `expr` egyetlen operátor-készletében sem szerepel
  (sem a bináris szinteken, sem `unary`/`postfix`-ban), így a `parse_expr()`
  garantáltan pontosan egy `:=` előtt áll meg, ha az következik — ellenőrizve
  kézzel az `a[0] := 5;` és a `*p := *p + 1;` teljes precedencia-láncon való
  végigkövetésével. Nulla új mechanizmus, nulla visszalépés. Megengedőbb, mint
  a formális nyelvtan (pl. `1 + 2 := 3;` szintaktikailag elfogadásra kerül,
  az elutasítás a szemantikai fázisra marad) — ez ugyanaz a mintázat, amit a
  projekt már többször tudatosan alkalmazott.

Emiatt **nincs külön `parse_lvalue` rutin, és nincs külön csomópont-fajta az
`lvalue`-nak** — ld. 4.3.

### 9.2 `parse_stmt` — diszpatcher

```
parse_stmt:
    tok_cur.kind == TOK_KW_IF     -> parse_if_stmt      (tail call)
    tok_cur.kind == TOK_KW_WHILE  -> parse_while_stmt    (tail call)
    tok_cur.kind == TOK_KW_RETURN -> parse_return_stmt   (tail call)
    egyébként                     -> parse_assign_or_expr_stmt (tail call)
```

**Ez teszi automatikussá — nem külön ellenőrzésként — azt, hogy "`decl` csak a
`func_block` `stmt*`-ja előtt állhat":** a `parse_stmt`-nek nincs
`TOK_KW_MUT`/`TOK_KW_CONST` ága, így egy odatévedt `mut`/`const` a
`parse_assign_or_expr_stmt` → `parse_expr` → `parse_primary` láncon landol,
aminek szintén nincs ilyen ága, és `"expected expression"` hibát ad — ez
közvetlen következménye annak, hogy a `func_block` deklaráció-ciklusa csak
addig hívja a `parse_decl`-t, amíg `tok_cur` `mut`/`const`, semmi extra
ellenőrzés nem kell hozzá.

### 9.3 `parse_assign_or_expr_stmt`

```
node = parse_expr()
if tok_cur.kind != TOK_ASSIGN:
    parser_expect(TOK_SEMI, "expected ';'")
    return ast_alloc_node(AST_STMT_EXPR){a=node}

; assign_stmt: node az első lvalue
pairs = []
loop:
    parser_expect(TOK_ASSIGN, "expected ':='")   ; fogyasztja a ':='-t (az elsőt is, egységesség kedvéért)
    rhs = parse_expr()
    pairs.append(ast_alloc_node(AST_ASSIGN_PAIR){a=node, b=rhs})
    if tok_cur.kind != TOK_COMMA: break
    parser_advance()                              ; ','
    node = parse_expr()                            ; következő lvalue
commit pairs -> arena (ld. 8. fejezet)
parser_expect(TOK_SEMI, "expected ';'")
return ast_alloc_node(AST_STMT_ASSIGN){a=pairs_ptr, b=count}
```

### 9.4 `parse_decl`

```
decl ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"
```

Kiválasztja a `kind`-et (`AST_DECL_MUT`/`AST_DECL_CONST`) a `mut`/`const`
kulcsszóból, elfogyasztja, elvárja az azonosítót (`name_offset`/`name_len`),
`:`, `parse_type()`, opcionálisan `:=` + `parse_expr()` (`init` = 0, ha
hiányzik), `;`. A típus- és kezdőérték-parsolás (`parse_type`/`parse_expr`)
között élő regisztereket (`kind`, `name_offset`, `name_len`) a hívó saját
kerete véd (push/pop a rutin elején/végén) — ugyanaz a fegyelem, mint a
kifejezés-parserben.

### 9.5 `parse_if_stmt`, `parse_while_stmt`, `parse_return_stmt`

```
if_stmt    ::= "if" "(" expr ")" block ("else" block)?
while_stmt ::= "while" "(" expr ")" block
return_stmt ::= "return" expr? ";"
```

`if`/`while`: `(` `expr` `)` elvárása, majd `parse_block()` (és `if` esetén
opcionális `else` + újabb `parse_block()`). `return`: ha `tok_cur ==
TOK_SEMI` közvetlenül a `return` kulcsszó után, nincs kifejezés (`value` = 0)
— nem kell előretekintés, a `;` önmagában egyértelmű.

### 9.6 `parse_block`, `parse_func_block`

```
block      ::= "{" stmt* "}"
func_block ::= "{" decl* stmt* "}"
```

`parse_block`: a nyitó `{`-t **explicit `parser_expect(TOK_LBRACE, ...)`
ellenőrzi**, nem puszta `parser_advance` — a nyelvnek **nincs** kapcsos
zárójel nélküli, egyetlen utasításos blokk-alternatívája (pl. az
`if (a == b) return;` szintaktikai hiba, nem egy egyutasításos blokk
rövidítése). Utána hurokban `parse_stmt()`-et hív, amíg `tok_cur !=
TOK_RBRACE`, majd `}`. Nulla utasítás is érvényes (nincs "legalább 1"
ellenőrzés). Az explicit ellenőrzés hiánya (puszta `parser_advance`, ami
feltétel nélkül elnyelte volna a `tok_cur`-t, bármi is legyen az) korábban
egy csendes, félrevezető hibaútvonalhoz vezetett volna — ld. 9.7's
"gap-vs-bug" jegyzete.

`parse_func_block`: `{` után **először** egy hurok, amíg `tok_cur` `mut`/
`const` (mindegyiket `parse_decl`-lel parsolva), **utána** egy hurok
`parse_block`-hoz hasonlóan (`parse_stmt`, amíg nem `}`), majd `}`. A két
lista egymás után, nem egymásba ágyazva használja a verem-scratch-et (ld. 8.
fejezet).

### 9.7 Implementáció közben feltárt hibaosztályok

Ennek a szeletnek a megírása közben három, korábban rejtve maradt probléma
derült ki a **már meglévő** típus-/kifejezés-parser és AST-dump kódban —
mindegyik azért maradt rejtve korábban, mert a KORÁBBI hívási helyek
"véletlenül" sosem igényelték a hibás viselkedés kiváltását. Mindegyiket
kijavítottuk; mindegyik tanulsága érdemes explicit rögzítésre, mert egy
jövőbeli bővítés ugyanebbe a csapdába eshet:

1. **Regiszter-védelem hiánya "levél" ágakban.** A `parse_primary`
   `.ident_or_struct`/`.int` ágai, és a `parse_type`/`parse_base_type` több ága,
   közvetlenül írták az `r12`/`r13`/`r14` regisztereket `push`/`pop` védelem
   nélkül — ez addig nem okozott hibát, amíg egyetlen hívó sem tartott bennük
   élő állapotot egy beágyazott híváson át. Az `assign_stmt` pár-listája (ami
   `r12`-ben tartja az aktuális `lvalue`-t, miközben az RHS-t egy újabb
   `parse_expr()` hívással parsolja) volt az első hívó, ami ezt ténylegesen
   megkövetelte — és pontosan ott bukott ki szegmentálási hibaként. **Szabály,
   amit ez megerősít:** minden rutin, ami `r12`–`r15`/`rbx`-et belső célra
   használja, **kötelezően** `push`/`pop`-olja őket a saját kerete
   elején/végén — függetlenül attól, hogy a JELENLEGI hívók igénylik-e ezt,
   mert egy JÖVŐBELI hívó igényelheti.
2. **`emit_str`-hívás által felülírt `rax` újrafelhasználása.** Az
   `ast_dump.asm` több "opcionális gyerek" mintája (`if` `else`-ága, `return`
   kifejezése) a mintát `rax = [csomópont+mező]; cmp rax,0; ha nem 0: emit_str
   (elválasztó szóköz kiírása); mov rdi,rax; dump_*` alakban írta — de az
   `emit_str` hívás **felülírja `rax`-ot** (hívó által mentendő regiszter,
   ahogy máshol is), így a `mov rdi, rax` már a rossz (`emit_str` belső
   számításából származó) értéket használta. **Javítás:** az `emit_str` hívás
   után a mezőt **újra be kell olvasni** a csomópontból (`mov rdi,
   [csomópont+mező]`), nem szabad a korábban betöltött `rax`-ra hagyatkozni.
3. **Hiányzó `'{'`-ellenőrzés `parse_block`-ban ("gap-vs-bug").** A
   `parse_block` a nyitó `'{'`-t eredetileg feltétel nélküli
   `parser_advance`-szel fogyasztotta el, `parser_expect` helyett — sem ez a
   rutin, sem a hívói (`parse_if_stmt`, `parse_while_stmt`) nem ellenőrizték
   előtte, hogy `tok_cur` tényleg `TOK_LBRACE`. Ez nem crashelt (nem
   `undefined`-viselkedés, mint az 1–2. pont), csak **elnyelte** a
   `tok_cur`-t, bármi is volt az, és a hibát (ha volt) egy sokkal
   zavaróbb, félrevezető helyen jelentette — pl. `if (a == b) return;`
   esetén az eredetileg kiadott hiba `"expected expression"` volt a `;`-nél,
   nem `"expected '{'"` a `return`-nél. Explicit felhasználói döntés
   véglegesítette: a nyelvnek **nincs** kapcsos zárójel nélküli,
   egyetlen-utasításos blokk-alternatívája — a `block ::= "{" stmt* "}"`
   nyelvtani szabály `'{'`-je mindig kötelező, sosem elhagyható. **Javítás:**
   `parse_block` elején `parser_expect(TOK_LBRACE, "expected '{'")`,
   `parser_advance` helyett (ld. 9.6, és a 35–37. fixture).

---

## 10. Felső szintű deklaráció-parser (`top_parser.asm`)

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function | struct_decl | extern_decl

struct_decl    ::= "struct" identifier "{" field_decl+ "}"
field_decl     ::= identifier ":" type ";"

function       ::= "function" identifier "(" params? ")" ":" return_type func_block
return_type    ::= type | "void"
extern_decl    ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
params         ::= param ("," param)*
param          ::= identifier ":" type
```

Kizárólag a **nyelvtani alakot** ellenőrzi ez a rutinkészlet — a szemantikai
megkötések (extern-név fehérlista, struct-mező teljesség, return-típus és
kifejezés-típus egyezése, kihasználatlan visszatérési érték figyelmeztetése)
mind egy jövőbeli szemantikai-elemző fázisra maradnak, ugyanaz a "parser
megenged, a szemantika utasít el" elv, amit a projekt már korábban is
következetesen alkalmazott. **Nem tárgya ennek a menetnek** a `function`
teste nélküli előre-deklarálása sem (a fő spec "Későbbre halasztott
döntések" 6. pontja) — az `extern function`-től eltérő, önálló, elhalasztott
nyelvtani bővítés.

### 10.1 `parse_param`, `parse_params`, `parse_signature`, `parse_return_type`

A `function` és az `extern_decl` közös gépezete, ezért ez épül fel elsőként:

- **`parse_param`** (`identifier ":" type`) — `r12`/`r13` = `name_offset`/
  `name_len`, `r14` = `parse_type()` eredménye; `AST_PARAM` csomópontot épít.
  Ugyanaz az alak, mint `expr_parser.asm` `parse_field_init`-je.
- **`parse_params`** (`param ("," param)*`, azaz a hívó felől nézve a teljes
  `params?` — nulla vagy több) — betű szerint ugyanaz a szerkezet, mint
  `expr_parser.asm` `parse_call_args`-a: `TOK_RPAREN` ellenőrzése előre az
  üres esethez (nem hiba — a `params` opcionális), egyébként
  vessző-elválasztott hurok `parse_param`-mal. `rax` = tömb-ptr (0, ha üres),
  `rdx` = elemszám — ugyanaz a két-visszatérésiérték konvenció, mint
  `parse_call_args`-nál, mert a `params` nyers payload az `AST_SIGNATURE`-nek,
  nem önálló csomópont.
- **`parse_signature`** (`identifier "(" params? ")"`) — `r12`/`r13` = név
  offset/len, `r14`/`r15` = `parse_params` ptr/count eredménye;
  `AST_SIGNATURE` csomópontot épít. Szó szerint megosztva a
  `parse_function` és a `parse_extern_decl` között — ez a csomópont-kiemelés
  közvetlen haszna.
- **`parse_return_type`** (`type | "void"`) — triviális: ha
  `tok_cur.kind == TOK_KW_VOID`, fogyaszt és `0`-t ad vissza; egyébként
  tail-call `parse_type`-ra. Nincs önálló csomópontja, ugyanaz a "0 =
  hiányzik" idióma.

### 10.2 `parse_function`, `parse_extern_decl`

```
function ::= "function" identifier "(" params? ")" ":" return_type func_block
```

`r12` = `parse_signature()` eredménye, `r13` = `parse_return_type()`
eredménye (0 = `void`), `r14` = `parse_func_block()` eredménye (a
`stmt_parser.asm`-ből extern-elt rutin, már kezeli a `"{" decl* stmt* "}"`
törzset). `:` kötelező a szignatúra és a `return_type` között
(`parser_expect`).

```
extern_decl ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
```

`r12`/`r13` = szignatúra/`return_type`-vagy-0. Az `"extern"` után
kifejezetten ellenőrzi és fogyasztja a `"function"` kulcsszót (saját
hibaüzenettel, ha hiányzik — önmagában az `extern` nem jelent semmit ebben a
nyelvtanban), utána ugyanaz a `parse_signature`/`parse_return_type` lánc,
mint `function`-nél, záró `;`-vel (nincs törzs).

### 10.3 `parse_field_decl`, `parse_struct_decl`

```
struct_decl ::= "struct" identifier "{" field_decl+ "}"
field_decl  ::= identifier ":" type ";"
```

`parse_field_decl` azonos `parse_param`-mal, plusz egy záró
`parser_expect(TOK_SEMI)`; `AST_FIELD_DECL` csomópontot épít.
`parse_struct_decl`: `"struct"` + név fogyasztása, `parser_expect(TOK_LBRACE)`,
majd a `field_decl+` (legalább 1, **nincs** vessző-elválasztó — minden
`field_decl` a saját `;`-jével zárul, ezért a ciklus feltétele "`}`
ellenőrzése minden elem UTÁN", nem "vessző ellenőrzése ELŐTTE", szemben a
`params`/`args`/`array_literal` vessző-elválasztott listáival) — ugyanaz az
üres-lista-előre-ellenőrzés minta, mint `parse_array_literal`/
`parse_struct_literal`-nál, dedikált üzenettel
(`"struct declaration requires at least one field"`).

### 10.4 `parse_top_level_decl`, `parse_program`

```
top_level_decl ::= function | struct_decl | extern_decl
```

Tiszta diszpatcher, csak tail call-ok (ugyanaz az alak, mint `parse_stmt`):
`TOK_KW_FUNCTION` → `parse_function`, `TOK_KW_STRUCT` → `parse_struct_decl`,
`TOK_KW_EXTERN` → `parse_extern_decl`, egyébként
`report_parse_error("expected top-level declaration")`. Szemben
`parse_stmt`-tel, itt **nincs** alacsonyabb precedenciájú szabály, amire át
lehetne bukni egy nem-egyező tokennél, ezért — a `func_block` decl/stmt-
sorrend-hibájával ellentétben (ld. 9.2) — ehhez saját, explicit
hibaüzenet kell.

```
program ::= top_level_decl+
```

`r12` = darabszám, `r13` = aréna-cél: ugyanaz az egy-vagy-több minta, mint
`parse_struct_decl` mezőlistája (üres eset előre ellenőrizve, dedikált
üzenettel: `"program requires at least one top-level declaration"`), hurok
`parse_top_level_decl`-lel `TOK_EOF`-ig. **Nem** fogyasztja el magát az
`EOF`-ot — a driver saját, minden irányjelzőnél azonos
`parser_expect(TOK_EOF, ...)` utóellenőrzése végzi el ezt egységesen.

### 10.5 Export-konvenció

A `top_parser.asm` minden felső szintű rutinja `global` — ugyanaz a "minden
rutin exportálva" szokás, mint `type_parser.asm`/`expr_parser.asm`/
`stmt_parser.asm`-ben (egyedül az `ast_dump.asm` minimál-exportos, mert ott
a segédrutinok sosem lépik át a fájlhatárt).

---

## 11. Hibakezelés és diagnosztika

Kiterjeszti (nem duplikálja) a lexer meglévő `err_buf`/`err_append_*`/
`compute_line_col` infrastruktúráját (`runtime.asm`). `report_parse_error`
(be: `rsi`/`rdx` = üzenet) a `parser_tokens.asm`-ben: felépíti az `err_buf`-ba
a `parse error: <üzenet> at line L, col C (byte offset O), found <token-leírás>`
sort, kiírja stderr-re, `exit(1)`.

**Kilépési kód: `1`**, ugyanabba a kategóriába, mint a lexikai hiba. Az
`exit(2)` kizárólag erőforrás-jellegű hibáknak (aréna kimerülése,
syscall-hiba) van fenntartva.

Nincs `flush_out` hívás a hiba előtt — a parser csak egy **teljesen sikeres**
parsolás után írja ki az AST-dumpot.

---

## 12. AST dump formátum

Egysoros, teljesen zárójelezett S-kifejezés, záró `\n`-nel, forrásszöveg
visszaszeletelésével mindenütt, ahol lehetséges.

**Típus-dump** (`dump_type`):

| `kind` | Kiírt forma |
|---|---|
| `AST_TY_BASE` | `(base <spelling>)` |
| `AST_TY_POINTER` | `(ptr <inner>)` |
| `AST_TY_ARRAY` | `(array <inner> <N>)` |

**Kifejezés-dump** (`dump_expr`):

| `kind` | Kiírt forma |
|---|---|
| `AST_EX_INT` | `(int <érték>)` — kiszámított decimális érték, nem a nyers forrás-írásmód |
| `AST_EX_BOOL` | `(bool true)` / `(bool false)` |
| `AST_EX_NULL` | `(null)` |
| `AST_EX_IDENT` | `(ident <név>)` |
| `AST_EX_UNARY` | `(unary <szimbólum> <operandus>)` |
| `AST_EX_BINARY` | `(binary <szimbólum> <bal> <jobb>)` |
| `AST_EX_INDEX` | `(index <alap> <index>)` |
| `AST_EX_FIELD` | `(field <alap> <név>)` |
| `AST_EX_CALL` | `(call <hívott> <arg0> <arg1> ...)` |
| `AST_EX_STRUCT_LIT` | `(struct <TípusNév> (field <név0> <érték0>) ...)` |
| `AST_EX_ARRAY_LIT` | `(array_lit <elem0> <elem1> ...)` |

**Utasítás-/deklaráció-dump** (`dump_stmt`, `dump_decl`, `dump_func_block`):

| `kind` | Kiírt forma |
|---|---|
| `AST_DECL_MUT` | `(decl_mut <név> <típus>)`, záró `<init>`-tal, ha van |
| `AST_DECL_CONST` | `(decl_const <név> <típus>)`, záró `<init>`-tal, ha van |
| `AST_ASSIGN_PAIR` | `(pair <lvalue> <rhs>)` — belső segéd, csak `dump_node_list`-en keresztül érhető el, a `dump_field_init` mintájára |
| `AST_STMT_ASSIGN` | `(assign <pair0> <pair1> ...)` |
| `AST_STMT_IF` | `(if <cond> <then_block>)`, záró `<else_block>`-kal, ha van |
| `AST_STMT_WHILE` | `(while <cond> <body_block>)` |
| `AST_STMT_RETURN` | `(return)` vagy `(return <expr>)` |
| `AST_STMT_EXPR` | `(expr_stmt <expr>)` — szándékosan nem puszta `<expr>` újra-kiírás, hogy a `STMT` irányjelzővel készült dump láthatóan különbözzön ugyanannak a szövegnek az `EXPR` irányjelzős dumpjától |
| `AST_BLOCK` | `(block <stmt0> <stmt1> ...)` — belső segéd (`dump_block`), `if`/`while` használja |
| `AST_FUNC_BLOCK` | `(func_block (decls <decl0> ...) (stmts <stmt0> ...))` — saját, kétlistás dump, kétszer hívja a `dump_node_list`-et |

Hiányzó opcionális gyerek (decl kezdőértéke, `if` `else`-ága, `return`
kifejezése) egyszerűen kimarad — ugyanaz a konvenció, mint a 0 argumentumú
hívás dumpja.

Az operátor-szimbólumok egy `op_symbol_labels` táblából jönnek, a `kind -
TOK_ASSIGN` index alapján (60–79 tartomány).

**Felső szintű dump** (`dump_top_level_decl`, `dump_program`):

| `kind` | Kiírt forma |
|---|---|
| `AST_PARAM` | `(param <név> <típus>)` — belső segéd, csak `dump_node_list`-en keresztül, a `dump_field_init` mintájára |
| `AST_FIELD_DECL` | `(field_decl <név> <típus>)` — ugyanaz a szerep, struct-testekhez |
| `AST_FUNCTION` | `(function <név> (params <p0> ...) <return_type> <func_block-dump>)` |
| `AST_EXTERN_DECL` | `(extern_decl <név> (params <p0> ...) <return_type>)` |
| `AST_STRUCT_DECL` | `(struct_decl <név> (fields <f0> ...))` |
| `AST_PROGRAM` | `(program <decl0> <decl1> ...)` |

A `<return_type>` a puszta `void` szó (zárójel nélkül — kulcsszó-atom, nem
összetett csomópont; minden valódi `type`-dump mindig `(`-vel kezdődik, tehát
nincs ütközés), ha a pointer 0, egyébként a meglévő `dump_type`-on keresztül
— egy kis belső `dump_return_type` segédben faktorálva, ugyanúgy, ahogy a
`dump_block` is megosztott a `dump_stmt` if/while ágai között.

Kizárólag a **`dump_top_level_decl`** és a **`dump_program`** `global`-exportos
— pontosan a `dump_stmt` mintáját követve: a `dump_top_level_decl` egyetlen
rutin, beágyazott `.function`/`.struct_decl`/`.extern_decl` cím-címkékkel
(nem három külön nevesített dump-rutin), ugyanaz az alak, amit a `dump_stmt`
is használ az öt utasítás-fajtájára. A `dump_param`/`dump_field_decl`/
`dump_return_type` belső marad, ahogy a `dump_field_init`/`dump_block`/
`dump_assign_pair` is az. Minden új, `emit_str`-hívás UTÁNI mező-olvasás
`[rbx + mező]`-ből újra beolvas, sosem egy korábban betöltött regiszterre
hagyatkozva — ld. 9.7, az előző menetben talált `emit_str`-`rax` hiba
tanulsága.

---

## 13. Tesztkészlet

`Stage0/tests/parser_cases/` mappa, 3-fájlos konvenció (`.ptl` /
`.expected.stdout` / `.expected.stderr` / `.expected.exit`), minden `.ptl`
fixture **első sora egy irányjelző**.

| Fixture | Tartalom | Elvárt kimenet |
|---|---|---|
| `01_type_simple_base` | `TYPE` / `int32` | `(base int32)` |
| `02_type_pointer_array` | `TYPE` / `*Node[3]` | `(array (ptr (base Node)) 3)` |
| `03_type_paren_pointer_to_array` | `TYPE` / `*(int32[10])` | `(ptr (array (base int32) 10))` |
| `04_expr_precedence` | `EXPR` / `1 + 2 * 3 - 4 / 2` | teljes, precedencia szerinti fa |
| `04b_expr_bitwise_vs_comparison` | `EXPR` / `e & 1 == 1` | `&` szorosabban köt, mint `==` |
| `05_expr_struct_literal` | `EXPR` / `Pair { a := 8, b := 15 }` | `(struct Pair (field a (int 8)) (field b (int 15)))` |
| `06_expr_array_literal` | `EXPR` / `{1, 2, 3}` | `(array_lit (int 1) (int 2) (int 3))` |
| `07_expr_postfix_chain` | `EXPR` / `arr[0].next(1, 2)` | vegyes index/mező/hívás lánc |
| `08_expr_syntax_error` | `EXPR` / `a < b < c` | üres stdout, `exit(1)`, stderr a fogyasztatlan `<`-ról |
| `13_decl_mut_with_init` | `DECL` / `mut x : int32 := 5;` | alap mut decl |
| `14_decl_const` | `DECL` / `const total : uint := 100;` | const decl |
| `15_decl_mut_no_init` | `DECL` / `mut n : int32;` | elhagyott kezdőérték |
| `16_stmt_expr_call` | `STMT` / `mult(4);` | `expr_stmt` — a szétválasztás nem-`:=` ága |
| `17_stmt_assign_single` | `STMT` / `x := 5;` | a szétválasztás `:=` ága, egy pár |
| `18_stmt_assign_multi` | `STMT` / `a := b, b := a;` | Dijkstra-csere, szimultán értékadás |
| `19_stmt_assign_deref_lvalue` | `STMT` / `*p := *p + 1;` | `lvalue`'s `"*" lvalue` forma |
| `20_stmt_if_else` | `STMT` / `if (x > 0) { y := 1; } else { y := 2; }` | beágyazott blokk-dump, mindkét ág |
| `21_stmt_while` | `STMT` / `while (e > 0) { e := e - 1; }` | while + blokk |
| `22_stmt_return_value` | `STMT` / `return x + 1;` | return kifejezéssel |
| `23_stmt_return_void` | `STMT` / `return;` | return kifejezés nélkül |
| `24_func_block_full` | `FUNC_BLOCK` / a fő spec `is_even`-szerű törzse | `decl*` + `stmt*` együtt |
| `25_func_block_decl_after_stmt_error` | `FUNC_BLOCK` / `{ mut x : int32 := 1; x := 2; mut y : int32 := 3; }` | a decl-elhelyezési szabály a `"expected expression"` úton bukik el, külön ellenőrzés nélkül |
| `26_top_level_struct_single_field` | `TOP_LEVEL_DECL` / `struct Node { value : int32; }` | struct_decl, egy mező |
| `27_top_level_struct_multi_field` | `TOP_LEVEL_DECL` / `struct Point { x : int32; y : int32; }` | struct_decl, több mező |
| `28_top_level_struct_empty_error` | `TOP_LEVEL_DECL` / `struct Empty { }` | `field_decl+` üres-lista elutasítás |
| `29_top_level_function_void_no_params` | `TOP_LEVEL_DECL` / `function noop() : void { return; }` | üres `params?`, `void` return_type |
| `30_top_level_function_with_params` | `TOP_LEVEL_DECL` / `function add(a: int32, b: int32) : int32 { return a + b; }` | paraméterlista, nem-`void` return_type |
| `31_top_level_extern_with_params` | `TOP_LEVEL_DECL` / `extern function sys_write(fd: int64, buf: *uint8, count: uint64) : int64;` | extern_decl, pointer-típusú paraméter, a fő spec saját whitelist-példája |
| `32_top_level_extern_void` | `TOP_LEVEL_DECL` / `extern function sys_exit(code: int64) : void;` | extern_decl, `void` return_type |
| `33_program_struct_and_function` | `PROGRAM` / egy `struct`, majd egy azt használó `function` | `program`'s `top_level_decl+`, több deklaráció, kereszt-deklarációs mezőelérés |
| `34_program_empty_error` | `PROGRAM` / üres bemenet | `top_level_decl+` üres-lista elutasítás |
| `35_stmt_if_missing_braces_error` | `STMT` / `if (a == b) return;` | `parse_block` explicit `'{'`-ellenőrzése (ld. 9.7/3) |
| `36_stmt_while_missing_braces_error` | `STMT` / `while (a == b) return;` | ugyanaz, `while` ágon |
| `37_stmt_if_else_missing_braces_error` | `STMT` / `if (a == b) { return; } else return;` | ugyanaz, az `else`-ág `parse_block` hívásán |

A pontos stderr-szöveg és pozíció-számok mindig a ténylegesen lefordított
bináris valós kimenetéből kerülnek rögzítésre — sosem kézzel kitalálva.

---

## 14. Driver (`parser_main.asm`)

Az irányjelző-sor felismerése: az első `\n`-ig tartó span hossza és tartalma
összehasonlítva minden ismert irányjelzővel (`TYPE`, `EXPR`, `DECL`, `STMT`
— mind 4 bájt —, `PROGRAM` — 7 bájt —, `FUNC_BLOCK` — 10 bájt —, és
`TOP_LEVEL_DECL` — 14 bájt). Mivel az irányjelzők hossza eltérő lehet, egy
általános `bytes_equal(ptr1, ptr2, len)` segédfüggvény végzi az
összehasonlítást, minden jelöltnél előbb a hosszt, csak egyezés esetén a
tartalmat vizsgálva.

A `\n` utáni pozíció adja a tényleges parsolás kezdő offszetét, amire
`parser_init` hívódik. Sikeres parsolás után a driver **kötelezően**
`parser_expect(TOK_EOF, "expected end of input")`-ot hív. Ezután a
megfelelő `dump_*` a kind alapján, `flush_out`, `exit(0)`. Nincs külön
`BLOCK` irányjelző — a `block` szabály csak `if`/`while`/`func_block`-on
belül fordul elő, ezeken keresztül már lefedett. Hasonlóképp **nincs** külön
irányjelző `function`/`struct_decl`/`extern_decl`-enként — a `TOP_LEVEL_DECL`
egyetlen irányjelző, a `parse_top_level_decl`/`dump_top_level_decl`
diszpatcheren keresztül fedi le mindhármat, a fixture forrásszövege
választja ki, melyik ágat gyakorolja — ugyanaz a minta, mint ahogy az öt
utasítás-fajtát is egyetlen `STMT` irányjelző fedi le.

---

## 15. Implementációs sorrend — felső szintű deklarációk

0. A 7 új `AST_*` konstans felvétele az `ast.inc`-be
   (`AST_PARAM`..`AST_PROGRAM`, ld. 4.5).
1. `parse_param` / `parse_params` / `parse_signature` / `parse_return_type`
   — a megosztott gépezet, elsőként megírva és leellenőrizve, mert mind a
   `function`, mind az `extern_decl` erre épül.
2. `parse_function` + `parse_extern_decl` + `parse_top_level_decl`
   (egyelőre csak function/extern ág). `dump_param`, `dump_return_type`,
   `dump_top_level_decl` (function/extern esetek). `TOP_LEVEL_DECL`
   irányjelző bekötése. A 29–32. fixture. **Kapu.**
3. `parse_field_decl` + `parse_struct_decl`, a `parse_top_level_decl` struct
   ágának bővítése + `dump_top_level_decl` struct esete + `dump_field_decl`.
   A 26–28. fixture. **Kapu.**
4. `parse_program` + `dump_program`; `PROGRAM` irányjelző. A 33–34.
   fixture. **Kapu.**
5. Teljes regresszió: mind a 34 parser-fixture + 6 lexer-fixture egyetlen
   `docker build`-en keresztül. Elsőre zöld — nem derült ki új
   regiszter-védelmi vagy `emit_str`-mellékhatás hiba ebben a menetben (a
   9.7-ben rögzített két szabály következetes betartása ellenőrzésre került
   minden új rutinnál írás közben, nem utólag hibakereséssel).
6. `Stage0/README.md` frissítése (irányjelző-táblázat, dump-forma-példa,
   Layout szakasz).
7. Utólagos javítás, felhasználói kérésre: `parse_block` hiányzó `'{'`
   ellenőrzésének pótlása (`parser_expect`, ld. 9.6/9.7-3) — a nyelvnek
   nincs kapcsos zárójel nélküli blokk-alternatívája, ezt a parsernek is ki
   kell kényszerítenie, ne csak a formális nyelvtannak. A 35–37. fixture.
   Teljes regresszió: 37 parser-fixture + 6 lexer-fixture, zöld.

Ezzel a Stage 0 EBNF **teljes** nyelvtana le van fedve a `build/parser`
binárisban — a `program` szabálytól a legmélyebb kifejezés-szintig. Nincs
további tudatosan elhalasztott parser-szelet; a hátralévő nyitott pontok
(forward-declared függvények test nélkül, extern-fehérlista/típus-egyezés
szemantikai ellenőrzése, kódgenerálás LLVM IR-re) mind egy jövőbeli,
szemantikai-elemző/kódgeneráló fázis hatókörébe tartoznak, nem a parseréba.
