# Postulate Stage 0 — Parser technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **parserének** technikai
> specifikációja: típusok, kifejezések, utasítások, deklarációk és blokkok
> (`type`, `expr`, `stmt`, `decl`, `block`, `func_block`). Előfeltétele a
> [postulate_stage0_spec.md](postulate_stage0_spec.md) (nyelvtan, szemantika)
> és a [postulate_stage0_lexer_spec.md](postulate_stage0_lexer_spec.md) (a már
> elkészült, tesztelt lexer — ennek `lex_next` rutinjára épül minden itt
> leírtak). A **top-level** parsolása (`function`/`struct`/`extern`
> deklarációk, `params`) **nem** tárgya ennek a dokumentumnak — tudatosan
> elhalasztott, külön menetben kerül sorra.

---

## 1. Cél és hatókör

A `type` és `expr` nyelvtani szabályok (ld. fő spec 4. fejezete) a legönállóbb,
mindenhonnan újrahasznosított építőelemek — deklarációk, paraméterek,
struct-mezők, mind típusra hivatkoznak; utasítások, kezdőértékek, mind
kifejezésre. Ezért ezek kapták az első, önmagában tesztelhető parser-szeletet.
Erre épül a második szelet: **utasítások, deklarációk, blokkok** — minden, ami
egy függvénytörzs parsolásához kell (`func_block`), a top-level
függvény-/struct-/extern-aláírások kivételével.

A cél egy **különálló `build/parser` bináris**, ami stdin-ről egy irányjelző
sorral kezdődő forrást olvas (`TYPE`, `EXPR`, `DECL`, `STMT` vagy
`FUNC_BLOCK`, ld. 13. fejezet), a maradékot a megfelelő nyelvtani szabály
szerint parsolja, és az eredmény AST-t szöveges, zárójelezett formában
(S-kifejezés, ld. 11. fejezet) írja ki stdoutra — vagy szintaktikai hiba
esetén diagnosztikát ír stderr-re és `exit(1)`-gyel lép ki.

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
elemlistája — és ebben a menetben újonnan az `assign_stmt` pár-listája, a
`block`/`func_block` utasítás-listája, valamint a `func_block` deklaráció-listája
— mind ugyanazt a mintát követik, dinamikus memóriafoglalás nélkül:

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
- `parse_call_args`: 0 is megengedett (`args ::= expr_list?`).
- `parse_array_literal`, struct-literal mezőlista: **legalább 1** kötelező.
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

`parse_block`: `{` után hurokban `parse_stmt()`-et hív, amíg `tok_cur !=
TOK_RBRACE`, majd `}`. Nulla utasítás is érvényes (nincs "legalább 1"
ellenőrzés).

`parse_func_block`: `{` után **először** egy hurok, amíg `tok_cur` `mut`/
`const` (mindegyiket `parse_decl`-lel parsolva), **utána** egy hurok
`parse_block`-hoz hasonlóan (`parse_stmt`, amíg nem `}`), majd `}`. A két
lista egymás után, nem egymásba ágyazva használja a verem-scratch-et (ld. 8.
fejezet).

### 9.7 Implementáció közben feltárt hibaosztályok

Ennek a szeletnek a megírása közben két, korábban rejtve maradt, valódi hiba
derült ki a **már meglévő** típus-/kifejezés-parser és AST-dump kódban — mindkettő
azért maradt rejtve korábban, mert a KORÁBBI hívási helyek "véletlenül" sosem
igényelték a hibás viselkedés kiváltását. Mindkettőt kijavítottuk; mindkettő
tanulsága érdemes explicit rögzítésre, mert egy jövőbeli bővítés ugyanebbe a
csapdába eshet:

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

---

## 10. Hibakezelés és diagnosztika

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

## 11. AST dump formátum

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

---

## 12. Tesztkészlet

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

A pontos stderr-szöveg és pozíció-számok mindig a ténylegesen lefordított
bináris valós kimenetéből kerülnek rögzítésre — sosem kézzel kitalálva.

---

## 13. Driver (`parser_main.asm`)

Az irányjelző-sor felismerése: az első `\n`-ig tartó span hossza és tartalma
összehasonlítva minden ismert irányjelzővel (`TYPE`, `EXPR`, `DECL`, `STMT`
— mind 4 bájt —, és `FUNC_BLOCK` — 10 bájt). Mivel az irányjelzők hossza
eltérő lehet, egy általános `bytes_equal(ptr1, ptr2, len)` segédfüggvény
végzi az összehasonlítást (a korábbi, fix 4 bájtos `bytes_equal4` helyett),
minden jelöltnél előbb a hosszt, csak egyezés esetén a tartalmat vizsgálva.

A `\n` utáni pozíció adja a tényleges parsolás kezdő offszetét, amire
`parser_init` hívódik. Sikeres parsolás után a driver **kötelezően**
`parser_expect(TOK_EOF, "expected end of input")`-ot hív. Ezután a
megfelelő `dump_*` a kind alapján, `flush_out`, `exit(0)`. Nincs külön
`BLOCK` irányjelző — a `block` szabály csak `if`/`while`/`func_block`-on
belül fordul elő, ezeken keresztül már lefedett.

---

## 14. Javasolt implementációs sorrend

0. Az `AST_DECL_MUT`..`AST_FUNC_BLOCK` konstansok felvétele az `ast.inc`-be
   (tiszta adat, kockázat nélkül).
1. `bytes_equal4` → általános `bytes_equal` + hossz-ellenőrzős diszpatch a
   `parser_main.asm`-ben, egyelőre csak `TYPE`/`EXPR` bekötve. **Kapu: a
   meglévő 12 fixture változatlanul átmegy**, mielőtt új nyelvtani kód íródna.
2. `stmt_parser.asm`: csak `parse_assign_or_expr_stmt` (a kockázatos
   szétválasztás). `dump_stmt` (csak `AST_STMT_ASSIGN`/`AST_STMT_EXPR`) +
   `dump_assign_pair`. Minimális `parse_stmt` (csak az alapértelmezett ág) és
   a `STMT` irányjelző bekötése. A 16–19. fixture. **Kapu** — ez különíti el
   és igazolja a szelet egyetlen valóban új logikáját, mielőtt bármi ráépülne.
3. `parse_stmt` bővítése if/while/return-nel + `parse_block`; `dump_stmt`
   bővítése, `dump_block` hozzáadása. A 20–23. fixture. Kapu.
4. `parse_decl` + `dump_decl`; `DECL` irányjelző. A 13–15. fixture. Kapu.
5. `parse_func_block` + `dump_func_block`; `FUNC_BLOCK` irányjelző. A 24–25.
   fixture (a 25. végponttól-végpontig igazolja a 2. lépés automatikus
   átbukás-állítását). Kapu.
6. Teljes regresszió: mind a 25 fixture a `run_parser_tests.sh`-on keresztül,
   egyetlen `docker build`, 25/25.
7. `Stage0/README.md` frissítése (új irányjelzők, dump-formák).
