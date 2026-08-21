# Postulate Stage 0 — Típus- és kifejezés-parser technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **típus- és kifejezés-parserének**
> technikai specifikációja. Előfeltétele a [postulate_stage0_spec.md](postulate_stage0_spec.md)
> (nyelvtan, szemantika) és a [postulate_stage0_lexer_spec.md](postulate_stage0_lexer_spec.md)
> (a már elkészült, tesztelt lexer — ennek `lex_next` rutinjára épül minden itt
> leírtak). Az utasítások, deklarációk és a top-level (`function`/`struct`/
> `extern`) parsolása **nem** tárgya ennek a dokumentumnak — tudatosan
> elhalasztott, külön specifikációt kap egy későbbi menetben.

---

## 1. Cél és hatókör

A `type` és `expr` nyelvtani szabályok (ld. fő spec 4. fejezete) a legönállóbb,
mindenhonnan újrahasznosított építőelemek — deklarációk, paraméterek,
struct-mezők, mind típusra hivatkoznak; utasítások, kezdőértékek, mind
kifejezésre. Ezért ezek kapják az első, önmagában tesztelhető parser-szeletet,
ugyanúgy, ahogy a lexer is önálló, tesztelt egységként készült el, mielőtt bármi
ráépült volna.

A cél egy **különálló `build/parser` bináris**, ami stdin-ről egy irányjelző
sorral kezdődő forrást olvas (`TYPE` vagy `EXPR`, ld. 12. fejezet), a maradékot
a megfelelő nyelvtani szabály szerint parsolja, és az eredmény AST-t szöveges,
zárójelezett formában (S-kifejezés, ld. 11. fejezet) írja ki stdoutra — vagy
szintaktikai hiba esetén diagnosztikát ír stderr-re és `exit(1)`-gyel lép ki,
ugyanúgy, ahogy a lexer teszi a lexikai hibákkal.

---

## 2. Eszközlánc és build-környezet

Változatlan a lexerhez képest (NASM, Intel szintaxis; `ld -static -no-pie`;
Docker, `ubuntu:24.04`) — ld. a lexer-spec 2. fejezetét. Új elem: a meglévő
`build/lexer` bináris mellé egy **második, önálló `build/parser` bináris**
készül, saját `_start`-tal, hogy a meglévő lexer-bináris és annak 6 fixture-je
érintetlen maradjon.

---

## 3. Megosztott futásidejű kód kiemelése (`runtime.asm`)

A lexer driver (`main.asm`) már tartalmaz mindent, amire a parser drivernek is
szüksége lesz: pufferelt syscall I/O (`read_all`, `write_all`, `emit_str`,
`flush_out`) és diagnosztika-építés (`compute_line_col`, `err_append_str`,
`err_append_dec`, `err_append_hex_byte`). Ahelyett, hogy ezt a parser
binárisban megismételnénk, ezek a rutinok (és a hozzájuk tartozó `.bss`:
`src_buf`, `src_len`, `scratch_byte`, `out_buf`, `out_cursor`, `err_buf`,
`err_cursor`) átkerülnek egy új `runtime.asm`/`runtime.inc` párba, amit mindkét
bináris linkel. A `main.asm`-ben marad minden, ami kizárólag a lexer-driveré
(`_start`, `format_and_emit_token`, `report_error`, `report_error_comment`,
`tok`, `punct_labels`).

**Ez tisztán refaktor, viselkedésváltozás nélkül** — az implementáció első
lépése, és addig nem szabad továbblépni, amíg a meglévő 6 lexer-fixture
változatlanul át nem megy utána (ld. 13. fejezet, 0. lépés).

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

Ez pontosan úgy tükrözi a lexer 32 bájtos, fix méretű token-structját (ld.
lexer-spec 4.2), ahogy az illik — minden ebben a nyelvtani szeletben előforduló
csomópont-fajta elfér 4 mezőben.

### 4.2 Csomópont-fajták

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_TY_BASE` | beépített típus-tag (0, ha azonosítónévvel hivatkozott típus; egyébként a `TOK_KW_INT8`..`TOK_KW_BOOL` konstans, közvetlenül a lexer `tokens.inc`-jéből) | `name_offset` | `name_len` | — |
| `AST_TY_POINTER` | `inner` (csomópont-ptr) | — | — | — |
| `AST_TY_ARRAY` | `elem` (csomópont-ptr) | `count` (a `TOK_INT` már kiszámított `value` mezőjéből) | — | — |
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
alapértelmezett forma, ld. fő spec 4. fejezet) `AST_TY_ARRAY{ elem =
AST_TY_POINTER{T} }`-ként épül; a `*(T[N])` (zárójellel) `AST_TY_POINTER{
inner = AST_TY_ARRAY{T, N} }`-ként — ugyanaz a két csomópont-fajta, csak más
sorrendben összeállítva, attól függően, melyik nyelvtani alternatíva
illeszkedett (ld. 7. fejezet).

### 4.3 Aréna és allokátor

```nasm
AST_ARENA_SIZE equ 1024*1024   ; 1 MiB (config.inc-ben, az SRC_BUF_SIZE mintájára)
MAX_LIST_ARITY equ 256          ; egyetlen változó aritású lista fix felső korlátja
```

`ast_arena: resb AST_ARENA_SIZE` + `ast_cursor: resq 1` (bump-pointer). A
`.bss` betöltéskor nullázott — mivel ez egyetlen, egyszeri lefutású folyamat
(egy parsolás, majd kilépés), a csomópontok mezői "hiányzó = 0" alapon
kezelhetők explicit nullázás nélkül, ugyanúgy, ahogy a token-struct `value`
mezője is (lexer-spec 4.3).

- **`ast_alloc_node`** — be: `rdi` = `kind`. ki: `rax` = friss, `kind`-del
  megjelölt 40 bájtos csomópont-pointer.
- **`ast_alloc_bytes`** — be: `rdi` = bájtszám (mindig `elemszám*8`, ptr-tömbökhöz). ki: `rax` = pointer.

Mindkettő **hiba esetén** (aréna kimerülése) fatal: rögzített stderr-üzenet,
`exit(2)` — ugyanabba a kategóriába tartozik, mint a lexer puffer-túlcsordulási
útvonala (erőforrás-jellegű, nem szintaktikai hiba).

---

## 5. Token-előretekintés (`parser_tokens.asm`)

A `lex_next` (ld. lexer-spec 5. fejezet) egyetlen tokent ad vissza hívásonként,
explicit kurzorral. A parsernek ennél egy kicsivel többre van szüksége: **két
tokenes előretekintésre** — sem többre, sem kevesebbre —, mert a nyelvtanban
pontosan két helyen kell "a jelenlegi token utáni token"-t megnézni anélkül,
hogy elfogyasztanánk:

1. A típus-nyelvtan pointer-tömb egyértelműsítése (`*` után: a következő token
   `base_type`-e, és az AZT követő token `[`-e?).
2. A `struct_literal` és a puszta `identifier` szétválasztása `primary`-ban
   (jelenlegi token `identifier`; a következő token `{`-e?).

Ehhez egy **2 rekeszes puffer** elég:

```nasm
tok_cur:        resb TOKEN_SIZE   ; 32 bájt, a tokens.inc-ből
tok_peek:       resb TOKEN_SIZE
tok_peek_valid: resq 1
raw_cursor:     resq 1             ; a lex_next saját, bájt-offszet kurzora
```

- **`parser_init`** (be: `rdi`=forráspuffer, `rsi`=kezdő offszet, `rdx`=hossz):
  beállítja a globálisokat, `tok_peek_valid=0`, meghívja `parser_advance`-t
  egyszer, hogy az első valódi token bekerüljön `tok_cur`-ba.
- **`parser_advance`**: ha `tok_peek_valid`, 32 bájtot másol `tok_peek`→`tok_cur`,
  törli a flaget (nincs újabb `lex_next`-hívás — a `raw_cursor` már a
  `tok_peek` utáni pozíciót tükrözi). Egyébként közvetlenül hívja `lex_next`-et
  `tok_cur`-ba, és frissíti `raw_cursor`-t.
- **`parser_peek`**: ha `!tok_peek_valid`, `lex_next`-et hív `tok_peek`-be és
  beállítja a flaget; **nem fogyaszt**, `tok_cur` változatlan. Ki: `rax` =
  `tok_peek` címe.
- **`parser_expect`** (be: `rdi`=elvárt `TOK_*` kind, `rsi`/`rdx`=hibaüzenet):
  ha `tok_cur.kind != rdi`, `report_parse_error`-t hív (nem tér vissza);
  egyébként `parser_advance`-ot hív. Ez fedi le a nyelvtanban mindenütt
  ismétlődő "ezt a tokent kötelezően el kell fogyasztani, vagy hiba" mintát
  (`;`, `)`, `]`, `}`, `:=`, egy mezőnév-`identifier`, …) egyetlen hívással.

---

## 6. Típus-parser (`type_parser.asm`)

`token_starts_base_type(kind)`: `kind == TOK_IDENT`, vagy `TOK_KW_INT8 <= kind
<= TOK_KW_BOOL`. Ez egyetlen tartomány-ellenőrzésként működik, mert a
`tokens.inc` a 11 beépített típus-kulcsszót egymás után, megszakítás nélkül
sorolja fel (22–32) — ez a kódban explicit megjegyzésre kerül, hogy a
`tokens.inc` egy jövőbeli átrendezése ne törje el csendben.

`parse_type` — kizárólag `tok_cur.kind` alapján dönt, **visszalépés
(backtracking) nélkül** (a típus-nyelvtan 4 alternatívája LL(1) plusz egy extra
előretekintéssel egyértelműsíthető, ld. lexer-spec 4. fejezet type-szabálya):

- **`TOK_STAR`**: fogyaszt. Ha `token_starts_base_type(tok_cur)` **és**
  `parser_peek().kind == TOK_LBRACKET`: parsolja a `base_type`-ot, becsomagolja
  `AST_TY_POINTER`-be, elfogyasztja a `[ INT ]`-et, becsomagolja
  `AST_TY_ARRAY{elem=pointer_csomópont, count=N}`-be — ez az alapértelmezett
  "N pointer tömbje" forma. Egyébként: rekurzívan `parse_type`-ot hív az
  operandusra, becsomagolja `AST_TY_POINTER{inner}`-be — ez az általános
  "pointer `<type>`-ra" forma (ez fedi le a `*(T[N])` esetet is, mert a `(` egy
  beágyazott `parse_type`-ot indít, ami a tömb-csomópontot burok nélkül adja
  vissza — ld. következő pont).
- **`TOK_LPAREN`**: fogyaszt, rekurzívan `parse_type`, `parser_expect(TOK_RPAREN)`,
  a belső csomópontot burok nélkül adja vissza (átlátszó csoportosítás).
- **`token_starts_base_type`**: parsolja a `base_type`-ot; ha `tok_cur.kind ==
  TOK_LBRACKET`, elfogyasztja a `[ INT ]`-et, becsomagolja `AST_TY_ARRAY`-be;
  egyébként a `base_type` csomópontot adja vissza változatlanul.
- egyébként: `report_parse_error("expected type")`.

---

## 7. Kifejezés-parser (`expr_parser.asm`)

**Egy nyelvtani szint = egy rutin**, közvetlen, szó szerinti fordítása az EBNF
láncnak (nem Pratt/precedencia-mászás) — ez illeszkedik a lexer már bevált
elvéhez (a hosszúság szerinti kulcsszó-bucketing előnyben részesítése a trie-jal
szemben, kifejezetten az ellenőrizhetőség miatt): kézzel írt assemblyben,
debugger nélküli iterációval, minden rutin 1:1 megfeleltethető egy EBNF sornak.

A lánc: `parse_logic_or` → `parse_logic_and` → `parse_comparison` →
`parse_bit_or` → `parse_bit_xor` → `parse_bit_and` → `parse_shift` →
`parse_additive` → `parse_multiplicative` → `parse_unary` → `parse_postfix` →
`parse_primary`. Minden bináris szint (a `comparison` kivételével) egy `while`
ciklus: parsolja a szorosabban kötő szintet, majd amíg a jelenlegi token az adott
szint operátor-készletébe esik, fogyaszt, parsolja a jobb operandust, épít
`AST_EX_BINARY`-t.

**`parse_comparison`** az egyetlen kivétel — `if`, nem `while`:

```
node = parse_bit_or()
if tok_cur.kind in {==, !=, <, >, <=, >=}:
    op = tok_cur.kind; advance()
    rhs = parse_bit_or()
    node = build_binary(op, node, rhs)
return node   ; nincs hurok -- egy közvetlenül következő második
              ; összehasonlító operátor szándékosan fogyasztatlan marad
```

Ha egy második összehasonlító operátor következik (`a < b < c`), a
`parse_comparison` csak `a < b`-t fogyasztja el; a megmaradt `< c` fogyasztatlanul
buborékol fel egészen a driver záró `parser_expect(TOK_EOF, ...)`
ellenőrzéséig (ld. 12. fejezet), ahol szintaktikai hibaként jelentkezik. **Ez a
szándékolt mechanizmus, nem hiányosság** — a nyelvtan `?`-jének (nem `*`-nak) a
lehető legszó szerintibb fordítása; a kódban ezt explicit megjegyzés jelzi,
mert ez az egyetlen pont, ahol egy áttekintő hiányzó ellenőrzést gyaníthatna.

**`parse_unary`** (jobbról-balra asszociatív prefix-lánc): ha `tok_cur.kind`
`! - * &` egyike, fogyaszt, rekurzívan önmagát hívja az operandusra, becsomagolja
`AST_EX_UNARY`-be; egyébként `parse_postfix`-ra delegál.

**`parse_postfix`** (balról-jobbra asszociatív szuffix-hurok): `parse_primary`,
majd hurokban fogyaszt `[expr]`-t (→ `AST_EX_INDEX`), `.identifier`-t (→
`AST_EX_FIELD`), `(args?)`-ot (→ `AST_EX_CALL`, a 8. fejezet szerinti
lista-segéddel), amíg valamelyik illeszkedik.

**`parse_primary`**: `tok_cur.kind` szerint dönt — `TOK_IDENT` esetén egy
további tokent tekint előre (`parser_peek`); ha az `TOK_LBRACE`,
`parse_struct_literal`-ra delegál (visszalépés nélkül, ld. 5. fejezet); egyébként
`AST_EX_IDENT`-et épít. `TOK_INT` → `AST_EX_INT`. `TOK_KW_TRUE`/`TOK_KW_FALSE`
→ `AST_EX_BOOL`. `TOK_KW_NULL` → `AST_EX_NULL`. `TOK_LPAREN` → belső kifejezés
parsolása, `)` elvárása, burok nélküli visszaadás (átlátszó csoportosítás).
`TOK_LBRACE` → `parse_array_literal`. Egyébként: `report_parse_error("expected
expression")`.

---

## 8. Változó aritású listák

A `call`-argumentumok, a `struct_literal` mezőlistája és az `array_literal`
elemlistája mind ugyanazt a mintát követik, dinamikus memóriafoglalás nélkül:

1. `MAX_LIST_ARITY*8` bájt fenntartása a **gépi verem**-en (`sub rsp, ...`).
2. Elemek parsolása egyesével (vesszővel elválasztva), mindegyik pointer
   beírása a verem-scratch-be, számláló növelése.
3. A lista lezárultával `ast_alloc_bytes(count*8)` az arénában, majd a
   verem-scratch pontos méretű másolása oda.
4. A verem-scratch felszabadítása (`add rsp, ...`).

**Miért verem, és nem egy közös globális scratch-puffer?** Egy `{1, mult(4),
9}` tömb-literál második eleme maga is egy függvényhívás saját
argumentumlistával — ennek parsolása közben a KÜLSŐ tömb-literál listája még
nyitva van. Egy közös globális puffer ilyenkor egymást írná felül; a natív
verem-rekurzió (minden beágyazott lista-parsolás saját, friss
`rsp`-relatív scratch-tartományt kap) ezt ingyen, kézi verem-a-vermeken-belül
bűvészkedés nélkül megoldja.

`parse_call_args` megenged 0 argumentumot (`args ::= expr_list?`);
`parse_array_literal` és a struct-literal mezőlistája mindkettő **legalább 1**
elemet követel meg (a nyelvtanban itt nincs `?`) — egy azonnal záró
határolójel 0 elemmel ezekben a két esetben szintaktikai hiba.

---

## 9. Hibakezelés és diagnosztika

Kiterjeszti (nem duplikálja) a lexer meglévő `err_buf`/`err_append_*`/
`compute_line_col` infrastruktúráját (ld. lexer-spec 7. fejezet), ami a 3.
fejezet szerint a `runtime.asm`-be kerül át. Új `report_parse_error` (be:
`rsi`/`rdx` = üzenet) a `parser_tokens.asm`-ben: felépíti az `err_buf`-ba a
`parse error: <üzenet> at line L, col C (byte offset O), found <token-leírás>`
sort (a pozíció `compute_line_col(tok_cur.offset)`-ből, a token-leírás a
`format_and_emit_token` kind-tartomány szerinti diszpatchának megfelelő, de
`err_append_str`-en keresztül stderr-re célzó változatából), kiírja
stderr-re, `exit(1)`.

**Kilépési kód: `1`**, ugyanabba a kategóriába, mint a lexikai hiba — egy külső
hívónak csak az számít, hogy "a bemenet hibás", nem hogy melyik fázis
találta meg; a stderr-szöveg továbbra is megkülönbözteti (`lex error:` vs.
`parse error:`). Az `exit(2)` továbbra is kizárólag erőforrás-jellegű hibáknak
(aréna kimerülése, syscall-hiba) van fenntartva.

Nincs `flush_out` hívás a hiba előtt (szemben a lexer hibaútvonalaival) — a
parser csak egy **teljesen sikeres** parsolás után írja ki az AST-dumpot
(parsolás-majd-dump két fázisú, nem folyamatos), tehát sosem keletkezik
részleges stdout-tartalom, amit menteni kellene hiba esetén.

---

## 10. AST dump formátum

Egysoros, teljesen zárójelezett S-kifejezés, záró `\n`-nel, forrásszöveg
visszaszeletelésével mindenütt, ahol lehetséges (a lexer "offszet+hossz,
sosem másolt szöveg" elvét követve, ld. lexer-spec 4.2).

**Típus-dump** (`dump_type`):

| `kind` | Kiírt forma |
|---|---|
| `AST_TY_BASE` | `(base <spelling>)` — a `src_buf`-ból visszaszeletelve, egységesen kezelve a beépített kulcsszavakat és az azonosítónévvel hivatkozott típusokat is (mindkét esetben `b`/`c` mindig ki van töltve) |
| `AST_TY_POINTER` | `(ptr <inner>)` |
| `AST_TY_ARRAY` | `(array <inner> <N>)` |

**Kifejezés-dump** (`dump_expr`):

| `kind` | Kiírt forma |
|---|---|
| `AST_EX_INT` | `(int <érték>)` — **a kiszámított decimális érték, nem a nyers forrás-írásmód** (szemben a lexer `INT 16n1F` konvenciójával). Szándékos eltérés: az AST szintjén a `16n1F` már a `31` szemantikai értékké vált, a nyers forrás-span idefent már nem hordoz többlet-információt. |
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

Az operátor-szimbólumok egy `op_symbol_labels` táblából jönnek, a `main.asm`
meglévő `punct_labels` mintájára indexelve (`kind - TOK_ASSIGN`), kihasználva,
hogy a `tokens.inc` mind a 20 operátort egymás után sorolja fel (60–79).

---

## 11. Tesztkészlet

Új `Stage0/tests/parser_cases/` mappa, ugyanaz a 3-fájlos konvenció, mint a
lexernél (`.ptl` / `.expected.stdout` / `.expected.stderr` / `.expected.exit`),
de minden `.ptl` fixture **első sora egy irányjelző** (`TYPE` vagy `EXPR`),
amit a driver az elemzés előtt levág — ez teszi lehetővé, hogy a nem top-level
`type`/`expr` szabályokat önmagukban lehessen tesztelni.

| Fixture | Tartalom | Elvárt kimenet |
|---|---|---|
| `01_type_simple_base` | `TYPE` / `int32` | `(base int32)` |
| `02_type_pointer_array` | `TYPE` / `*Node[3]` | `(array (ptr (base Node)) 3)` |
| `03_type_paren_pointer_to_array` | `TYPE` / `*(int32[10])` | `(ptr (array (base int32) 10))` |
| `04_expr_precedence` | `EXPR` / `1 + 2 * 3 - 4 / 2` | teljes, precedencia szerinti fa |
| `04b_expr_bitwise_vs_comparison` | `EXPR` / `e & 1 == 1` | igazolja, hogy `&` szorosabban köt, mint `==` |
| `05_expr_struct_literal` | `EXPR` / `Pair { a := 8, b := 15 }` | `(struct Pair (field a (int 8)) (field b (int 15)))` |
| `06_expr_array_literal` | `EXPR` / `{1, 2, 3}` | `(array_lit (int 1) (int 2) (int 3))` |
| `07_expr_postfix_chain` | `EXPR` / `arr[0].next(1, 2)` | vegyes index/mező/hívás lánc |
| `08_expr_syntax_error` | `EXPR` / `a < b < c` | üres stdout, `exit(1)`, stderr a fogyasztatlan `<`-ról |

A pontos stderr-szöveg és pozíció-számok (8. fixture, és a típus-oldali
hiba-fixture a 13. fejezet 3. lépéséből) a ténylegesen lefordított bináris
valós kimenetéből kerülnek rögzítésre — sosem kézzel kitalálva, ugyanúgy, ahogy
a lexer fixture-jeinél történt.

---

## 12. Driver (`parser_main.asm`)

Az irányjelző-sor felismerése: az első `\n`-ig tartó span összehasonlítása
`"TYPE"`/`"EXPR"`-rel (mindkettő 4 bájt), a `\n` utáni pozíció adja a tényleges
parsolás kezdő offszetét. `parser_init` erre az offszetre hívódik. Sikeres
parsolás után a driver **kötelezően** `parser_expect(TOK_EOF, "expected end of
input")`-ot hív — ez zárja ki, hogy egy hiányos parsolás (pl. a nem láncolható
`comparison` fogyasztatlanul hagyott maradéka) észrevétlen maradjon. Ezután
`dump_type`/`dump_expr` a kind alapján, `flush_out`, `exit(0)`.

---

## 13. Javasolt implementációs sorrend

0. `runtime.asm` kiemelése — **kapu: a meglévő 6 lexer-fixture változatlanul
   átmegy** utána, mielőtt egyetlen sor új parser-kód is íródna.
1. Aréna-allokátor (`ast.inc`/`ast.asm`) — gyors kézi ellenőrzés (`ast_alloc_node`
   térközei, nullázottsága), mielőtt nyelvtani kód épülne rá.
2. Token-előretekintés (`parser_tokens.asm`) — kézi ellenőrzés egy rövid,
   kódba írt teszt-string ellen, nyelvtani kódtól függetlenül.
3. Típus-parser teljes egészében + `dump_type` + minimális `parser_main.asm`
   (csak `TYPE` irányjelző). Az 1–3. fixture, plusz egy szándékos típus-oldali
   hiba-fixture. Előre hozva, mert a `*T[N]` vs. `*(T[N])` egyértelműsítés a
   legkényesebb logika ebben a szeletben.
4. Kifejezés-precedencia-lánc, `primary` egyelőre csak
   azonosító/egész/bool/null/zárójel esetekre korlátozva (struct/tömb-literál
   és hívás még nem). A 4., 4b. és 8. fixture.
5. Változó aritású szerkezetek (hívás-argumentumok, tömb-literál,
   struct-literál + `field_init`) és a struct-literál előretekintés
   `primary`-ban. Az 5., 6., 7. fixture.
6. `parser_main.asm` befejezése (irányjelző-feldolgozás, záró EOF-ellenőrzés,
   dump-vagy-hiba), `report_parse_error` befejezése. Teljes 9 fixture-ös
   készlet a `run_parser_tests.sh`-on keresztül.
7. `build.sh`/`Dockerfile` bekötése mindkét binárishoz; egyetlen `docker build`
   zöld 6/6 lexer + 9/9 parser fixture-re.
8. `Stage0/README.md` frissítése (új bináris, irányjelző-konvenció,
   dump-formátum, bővített kilépésikód-leírás).
