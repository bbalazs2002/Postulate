# Postulate Stage 0 — Lexer technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **lexikai elemzőjének** (tokenizer)
> technikai specifikációja. Előfeltétele és kiegészítése a
> [postulate_stage0_spec.md](postulate_stage0_spec.md)-nek (nyelvtan, szemantika,
> tervezési döntések) — ott nem ismételt részleteket (kulcsszólista, lexikai
> nyelvtan) onnan kell venni. A parser, az AST-építés és az LLVM IR-kiírás **nem**
> tárgya ennek a dokumentumnak; azok külön specifikációt kapnak, amikor sorra
> kerülnek.

---

## 1. Cél és hatókör

A lexer egy önmagában lefordítható, futtatható, önmagában tesztelhető bináris:
forráskódot olvas be (stdin), tokenek sorozatára bontja, és azt szöveges formában
kiírja (stdout). Célja kettős:

1. **Közvetlen cél:** bizonyítani, hogy a Stage 0 eszközlánc (NASM + `ld`, Docker
   alatt, libc nélkül) működik, és hogy a lexikai nyelvtan (ld. a fő spec 4.
   fejezete) hibamentesen implementálható tiszta syscall-alapú assemblyben.
2. **Hosszú távú cél:** a lexer belső token-előállító rutinja (`lex_next`)
   változtatás nélkül újrafelhasználható lesz a parser által, amikor az elkészül —
   ezért a lexer és a köré épített teszt-driver szigorúan külön van választva (ld.
   3. és 5. fejezet).

---

## 2. Eszközlánc és build-környezet

| Döntés | Választás | Indoklás |
|---|---|---|
| Assembler | **NASM**, Intel szintaxis | Olvashatóbb, mint az AT&T szintaxisú GNU `as` — jobban illik a projekt formális, precíz dokumentációs stílusához. |
| Linker | `ld` közvetlenül | Nincs `gcc` driver, nincs `crt0`, nincs libc — a belépési pont saját `_start`. |
| Linkelési kapcsolók | `-static -no-pie -e _start` | Modern Ubuntu `ld`-je alapból PIE-t (`ET_DYN`) próbál generálni, ami egy saját `_start`-tal, abszolút címzésű kód esetén (pl. az ugrótábla, ld. 6.1) futásidőben megmagyarázhatatlan hibákkal állna le. A `-static -no-pie` sima `ET_EXEC`-et, pozíció-függő linkelést kényszerít ki — pontosan azt, amit a kód elvár. |
| Build-/tesztkörnyezet | Docker, `ubuntu:24.04` | A Windows hoszton nincs natív ELF64 eszközlánc; a fő spec 2. fejezete is a `ubuntu-latest` CI-környezettel való paritást írja elő. Az image build lépésként futtatja a fordítást *és* a tesztkészletet is — egyetlen `docker build` a teljes pass/fail kapu. |
| Csomagok az image-ben | `nasm`, `binutils`, `bash`, `diffutils` | A fordításhoz és a teszt-diffeléshez szükséges minimum. |

---

## 3. Mappastruktúra

```
Stage0/
  README.md                # build/teszt parancsok, exit kódok, token-dump formátum
  Dockerfile
  .dockerignore
  scripts/
    build.sh                # nasm + ld, a konténeren belül fut
    run_tests.sh             # a fixture-futtató, a konténeren belül fut
  src/
    config.inc               # SRC_BUF_SIZE / OUT_BUF_SIZE konstansok
    tokens.inc                # TOK_* kind konstansok + a token-struct layout
    lexer.asm                 # skip_trivia + lex_next + kulcsszó-/szám-felismerés — nincs benne syscall
    main.asm                  # _start, read_all/write_all, driver-hurok, diagnosztika
  tests/
    cases/
      01_function_basic.{ptl,expected.stdout,expected.stderr,expected.exit}
      02_integer_literals.{...}
      03_operators.{...}
      04_comments.{...}
      05_lexer_error.{...}
      06_unterminated_comment.{...}
      07_based_form_empty_digits.{...}
```

**A `lexer.asm` / `main.asm` szétválasztás lényege:** a `lexer.asm` kizárólag a
tényleges tokenizáló motort tartalmazza (`skip_trivia`, `lex_next`, kulcsszó- és
szám-felismerés), és **egyetlen syscallt sem hív** — csak a hívó által átadott
pufferből olvas, és a hívó által átadott token-structba ír. A `main.asm` birtokolja
az összes syscallt, a stdin-beolvasó hurkot, a driver print-hurkot és minden
diagnosztika-formázást. Ez teszi lehetővé, hogy egy későbbi parser közvetlenül a
`lexer.asm`-hez linkeljen, a `main.asm` érintése nélkül.

A `Stage0/build/` mappa (fordítási melléktermékek) `.gitignore`-ba kerül.

---

## 4. Token-reprezentáció

### 4.1 Token-kind konstansok

Minden kulcsszóhoz, operátorhoz és írásjelhez **külön** kind-konstans tartozik
(nem egy általános `KEYWORD`/`OP` cimke, amit később szöveg alapján kellene
újra azonosítani) — így egy későbbi parser közvetlenül `kind` szerint tud
elágazni, szöveg-összehasonlítás nélkül.

| Kategória | Konstansok | Érték-tartomány |
|---|---|---|
| Speciális | `TOK_EOF`, `TOK_IDENT`, `TOK_INT` | 0–2 |
| Kulcsszavak (24 db) | `TOK_KW_FUNCTION`, `TOK_KW_STRUCT`, `TOK_KW_EXTERN`, `TOK_KW_MUT`, `TOK_KW_CONST`, `TOK_KW_IF`, `TOK_KW_ELSE`, `TOK_KW_WHILE`, `TOK_KW_RETURN`, `TOK_KW_TRUE`, `TOK_KW_FALSE`, `TOK_KW_NULL`, `TOK_KW_INT8`, `TOK_KW_INT16`, `TOK_KW_INT`, `TOK_KW_INT32`, `TOK_KW_INT64`, `TOK_KW_UINT8`, `TOK_KW_UINT16`, `TOK_KW_UINT`, `TOK_KW_UINT32`, `TOK_KW_UINT64`, `TOK_KW_BOOL`, `TOK_KW_VOID` | 10–33 |
| Strukturális írásjelek | `TOK_COLON` (`:`), `TOK_SEMI` (`;`), `TOK_COMMA` (`,`), `TOK_DOT` (`.`), `TOK_LPAREN`, `TOK_RPAREN`, `TOK_LBRACE`, `TOK_RBRACE`, `TOK_LBRACKET`, `TOK_RBRACKET` | 40–49 |
| Operátorok | `TOK_ASSIGN` (`:=`), `TOK_EQ` (`==`), `TOK_NE` (`!=`), `TOK_LE` (`<=`), `TOK_GE` (`>=`), `TOK_SHL` (`<<`), `TOK_SHR` (`>>`), `TOK_ANDAND` (`&&`), `TOK_OROR` (`\|\|`), `TOK_BANG` (`!`), `TOK_MINUS`, `TOK_STAR`, `TOK_AMP` (`&`), `TOK_SLASH`, `TOK_PERCENT`, `TOK_PLUS`, `TOK_LT`, `TOK_GT`, `TOK_CARET` (`^`), `TOK_PIPE` (`\|`) | 60–79 |
| Hibák | `TOK_ERROR_COMMENT` (lezáratlan blokk-komment), `TOK_ERROR` (ismeretlen karakter) | 253–254 |

A `:` strukturális írásjelnek számít (típus-annotációkban, mező-deklarációkban
fordul elő, nem kifejezés-operátor), a `:=` viszont — bár `:`-tal kezdődik —
operátor, mivel az érékadás kifejezés/utasítás-szintű operátora.

### 4.2 Token-struct (32 bájt)

| Mező | Offszet | Méret | Tartalom |
|---|---|---|---|
| `kind` | 0 | 8 bájt | a fenti kind-konstansok egyike |
| `offset` | 8 | 8 bájt | a token első bájtjának bájt-offszete a forráspufferben |
| `length` | 16 | 8 bájt | a token forrás-span hossza bájtban |
| `value` | 24 | 8 bájt | `TOK_INT` esetén a kiszámított numerikus érték, egyébként 0 |

**Miért offszet+hossz, és nem másolt szöveg?** A forráspuffer a teljes futás
alatt rezidens marad (nincs dinamikus memóriakezelés a projektben, ld. fő spec
2. fejezet) — így bármely fogyasztó (a teszt-driver most, egy parser később)
közvetlenül a forráspufferbe tud belemetszeni `offset`/`length` alapján, külön
string-tábla nélkül.

### 4.3 A numerikus érték kiszámítása a lexerben történik

A `TOK_INT` `value` mezőjét maga a `lex_next` számítja ki szken­nelés közben
(nem külön lépésben), mivel az akkumuláció ingyenes melléktermék a számjegy-sor
beolvasása során:

- `decimal_form`: `value = value*10 + számjegy` minden beolvasott számjegyre.
- `based_form` (`digit+ "n" value_digit+`): a `digit+` előtag decimálisan
  értelmezve adja a `base`-t; ezután minden `value_digit`-re
  `value = value*base + számjegy_érték` (`0-9 → 0-9`, `a-f`/`A-F → 10-15`,
  a bázistól függetlenül). A lexer **nem** ellenőrzi, hogy `base ∈ {2, 8, 10, 16}`
  — ez a fő spec explicit tervezési döntése szerint ("a nyelvtan megengedőbb,
  mint a szemantika") egy későbbi szemantikai fázis feladata. Túlcsordulás esetén
  a 64 bites `value` egyszerűen becsavarodik (wraparound) — nincs külön
  túlcsordulás-ellenőrzés ezen a szinten.

---

## 5. Belső hívási konvenció

Mivel a belső (nem-syscall) rutinhívásokhoz nincs öröklött ABI, a System V
AMD64 caller-saved/callee-saved felosztását követjük következetesen:

- **Caller-saved** (a hívott szabadon felülírhatja): `rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11`
- **Callee-saved** (a hívottnak `push`/`pop`-olnia kell, ha hozzányúl): `rbx, rbp, r12, r13, r14, r15`

### `lex_next` szignatúra

```
be:  rdi = src_buf mutató
     rsi = kurzor (bájt-offszet, honnan induljon a keresés)
     rdx = a puffer érvényes hossza (bájtban)
     rcx = mutató egy hívó által foglalt, 32 bájtos token-structra (kitöltendő)
ki:  rax = az új kurzor-pozíció (a következő híváskor ez kerül rsi-be)
     [rcx] = a kitöltött token-struct
```

Nincs rejtett globális "aktuális pozíció" — a kurzort a hívó explicit módon
adja át és kapja vissza. Ez teszi lehetővé, hogy egy későbbi rekurzív
leszállásos parser triviálisan tudjon lookahead/backtracking céljából
kurzor-pozíciókat menteni/visszaállítani, anélkül hogy globális állapotot
kellene kezelnie.

---

## 6. Lexikai elemzés algoritmusa

### 6.1 Diszpatch: 256-bejegyzéses ugrótábla

A `lex_next` az első nem-trivia bájt értékére indexelt, 256 bejegyzésből álló
ugrótáblával dönt (`dq` cím-tömb, `jmp [tábla + rax*8]`) — nem egymásra épülő
`cmp`/`je` láncolattal. Minden betű-értékű bájt (52 db) ugyanarra az
azonosító-felismerő ágra mutat, minden számjegy-bájt (10 db) ugyanarra a
szám-felismerő ágra, minden írásjel saját, kis kezelőre, minden más bájt a
hiba-ágra (`TOK_ERROR`). Az azonosító/szám *folytatásának* eldöntése (még
azonosító-karakter-e a következő bájt?) egyszerű intervallum-összehasonlítással
történik, nem külön táblával — egy egyetlen nagy táblát megéri fenntartani (kb.
60 láncolt összehasonlítást vált ki), de nem érdemes mindenhol táblázni.

### 6.2 Maximal munch — kétkarakteres operátorok

Hét kezdő-bájt igényel egy bájtnyi előretekintést: `: = ! < > & |`. Minden
esetben ellenőrizni kell, hogy `kurzor+1 < puffer_hossz`, mielőtt a következő
bájtot megnézzük — egy forrás, ami pontosan egy ilyen bájttal ér véget, nem
olvashat túl a pufferen.

| Kezdő bájt | Ha a következő `=` | Ha a következő más | Van önálló (1 karakteres) forma? |
|---|---|---|---|
| `:` | `:=` (`TOK_ASSIGN`) | `:` (`TOK_COLON`) | igen |
| `=` | `==` (`TOK_EQ`) | **`TOK_ERROR`** | **nincs** |
| `!` | `!=` (`TOK_NE`) | `!` (`TOK_BANG`) | igen |
| `<` | `<=` (`TOK_LE`); ha a következő `<`: `<<` (`TOK_SHL`) | `<` (`TOK_LT`) | igen |
| `>` | `>=` (`TOK_GE`); ha a következő `>`: `>>` (`TOK_SHR`) | `>` (`TOK_GT`) | igen |
| `&` | ha a következő `&`: `&&` (`TOK_ANDAND`) | `&` (`TOK_AMP`) | igen |
| `\|` | ha a következő `\|`: `\|\|` (`TOK_OROR`) | `\|` (`TOK_PIPE`) | igen |

**Kritikus eset:** a bare `=` **soha nem** érvényes token (a teljes nyelvtanban
nincs önálló `=` — csak `:=`, `==`, `!=`, `<=`, `>=` részeként fordul elő). Az
`=` mégis önálló diszpatch-bejegyzést kap (mert az `==` ezzel a bájttal
kezdődik); ha az előretekintés nem `=`-t talál, az eredmény `TOK_ERROR`, **nem**
egy visszaesés valamilyen önálló token-formára — ez az egyetlen a hét eset
közül, ahol a "nem illeszkedik a kétkarakteres forma" eset hiba, nem érvényes
egykarakteres token.

A `/` külön kezelendő (ld. 6.3), mert kétkarakteres formái (`//`, `/*`) nem
operátorok, hanem teljes egészében a trivia-hurokban elnyelődnek, sosem lesznek
tokenek.

Minden más egykarakteres token (`; , . ( ) { } [ ] - * % + ^`) előretekintés
nélkül, közvetlenül diszpatchol.

### 6.3 Trivia: whitespace és kommentek

A `skip_trivia` minden `lex_next`-hívás elején lefut, és addig hurkol, amíg
tényleges (nem-trivia) tartalmat nem talál — mert egymásba ágyazott
whitespace/komment-sorozatok (`"  // c\n  /* c */  azonosító"`) egy körrel nem
kezelhetők:

1. Amíg a bájt whitespace (szóköz, tab, CR, LF): léptet.
2. Ha a bájt `/`, megnézi a következőt:
   - `/`: sor-komment — a következő `\n`-ig vagy a fájl végéig léptet. Ha a fájl
     a sor-komment lezáró `\n`-je nélkül ér véget, az **sikeres** lezárás, nem
     hiba (a nyelvtan szigorú `line_comment ::= "//" ... newline` olvasata
     szerint ez hiba lenne, de a specifikáció tudatosan megengedőbb itt — egy,
     a fájl végén `\n` nélkül záruló komment elutasítása indokolatlanul
     szigorú lenne).
   - `*`: blokk-komment — feljegyzi a nyitó `/*` pozícióját (a hibaüzenethez),
     és a `*/` bájtsorozatot keresi. Ha megtalálja, továbblép és folytatja a
     trivia-hurkot. **Ha a puffer vége előbb jön el, mint a `*/`, ez hiba**
     (`TOK_ERROR_COMMENT`), az `offset` a nyitó `/*` pozíciójára mutat (nem a
     fájl végére) — a lezáratlan komment kezdete a hasznos, cselekvésre
     ösztönző hivatkozási pont.
   - bármi más: nem komment, a `/` maga `TOK_SLASH` — ez már nem a
     trivia-hurok, hanem egy valódi token.
3. Egyébként: a hurok véget ér, ez a bájt a következő valódi token kezdete.
4. Ha a kurzor elérte a puffer végét: `TOK_EOF` (`offset = puffer_hossz,
   length = 0`).

### 6.4 Azonosító és kulcsszó felismerés — hossz szerinti bucketing

24 kulcsszó van összesen. A választott stratégia **hossz szerinti bucketing**,
nem trie és nem egyenes 24-elemű lineáris keresés: egy kézzel írt NASM trie a
kódmennyiséghez képest aránytalanul hibalehetőség-érzékeny lenne 24 bejegyzésre,
egy feltétel nélküli 24-elemű lineáris keresés pedig feleslegesen sok
összehasonlítást pazarolna a (leggyakoribb) esetre, amikor az azonosító egyetlen
kulcsszóval sem egyezik.

| Hossz | Kulcsszavak |
|---|---|
| 2 | `if` |
| 3 | `mut`, `int` |
| 4 | `else`, `true`, `null`, `int8`, `bool`, `void`, `uint` |
| 5 | `const`, `while`, `false`, `int16`, `int32`, `int64`, `uint8` |
| 6 | `struct`, `extern`, `return`, `uint16`, `uint32`, `uint64` |
| 8 | `function` |
| 1, 7, 9+ | *(üres — azonnal `TOK_IDENT`, összehasonlítás nélkül)* |

Az 1, 7 és 9+ hosszak — amik minden egybetűs változónevet lefednek (pl. `n`,
`e`, `b`, `x`, `y`, `a`, `p`, mind előfordulnak a fő spec mintaprogramjában) —
nulla string-összehasonlítással `TOK_IDENT`-té oldódnak fel. Egy találó
bucketen belül egyszerű, bájtonkénti összehasonlítás dönt (nem szó/dword-szintű
csomagolt összehasonlítás, ami rövid azonosítóknál a puffer végén túlolvasást
kockáztatna).

---

## 7. Hibakezelés és diagnosztika

A `lex_next` **sosem** végez I/O-t és sosem lép ki — a hibákat (`TOK_ERROR`,
`TOK_ERROR_COMMENT`) ugyanúgy egyszerű token-kindként adja vissza, mint bármely
más tokent. Ez megőrzi a "tiszta, újrafelhasználható szken­nelő rutin"
tulajdonságot a hibaútra is: egy későbbi, hosszabb életű fordítóba ágyazott
parser dönthet úgy, hogy több hibát is összegyűjt egyetlen kilépés helyett — ez
a döntés nem lehet a szken­nelőbe égetve.

A tényleges diagnosztika-viselkedés — formázás, stderr-írás, kilépési kód
kiválasztása — kizárólag a `main.asm` driver-hurkában történik:

- **`TOK_ERROR`** — két különböző alfajtát fed le, más-más üzenettel, mert a
  driver a `TOK_LENGTH_OFF` mezőn dönt el, melyikről van szó (ld. `lexer.asm`
  három `TOK_ERROR`-termelő helye):
  - **Ismeretlen karakter** (`TOK_LENGTH_OFF = 1`, akár egy bare `=`, akár
    bármilyen más fel nem ismert bájt): stderr-re írja: `lex error:
    unexpected character '@' (0x40) at line 3, col 12 (byte offset 41)`.
  - **Üres bázisjegy-sorozat** (`TOK_LENGTH_OFF = 0` — pl. `16n` közvetlenül
    egy nem hexajegy karakter előtt vagy a fájl végén): stderr-re írja:
    `lex error: based-form integer literal has no digits after 'n' at line
    L, col C (byte offset O)`. **Nem** a "unexpected character" formát
    használja — ebben az esetben a hibás pozíció utáni bájt (ha van
    egyáltalán) semmiben nem hibás önmagában, tehát azt "hibás karakterként"
    megnevezni félrevezető lenne (és fájlvégi esetben nem is létező bájtot
    olvasna ki). Ld. `tests/cases/07_based_form_empty_digits`.
  Mindkét alfajta esetén: kiírja stdoutra az addig helyesen felismert
  tokeneket (a hiba előtti prefix nem vész el — ld. 9. fejezet), és
  `exit(1)`.
- **`TOK_ERROR_COMMENT`** (lezáratlan blokk-komment): hasonlóan, `lex error:
  unterminated block comment starting at line 5, col 1 (byte offset 88)`,
  ugyanaz a flush-majd-exit(1) viselkedés.
- **Kilépési kódok:** `0` = siker, `1` = lexikai hiba (rossz karakter /
  lezáratlan komment), `2` = I/O-jellegű hiba (puffer túl kicsi, `read`/`write`
  syscall hiba) — a két hibaosztály elkülönítése azért fontos, hogy a
  tesztkészlet (ld. 10. fejezet) meg tudja különböztetni őket.

**Sor/oszlop számítás** szándékosan **nincs** a `lex_next` forró útvonalán —
csak a hiba-jelentési útvonalon, egy külön segédrutinnal, ami egyetlen
végigolvasással megszámolja a `\n` bájtokat a puffer elejétől a hiba
pozíciójáig (`sor = számláló+1`, `oszlop = offszet - utolsó_newline_offszet`).
Ez O(n), de csak egyszer fut, a hiba útvonalán, egy amúgy is kilépő
programban — nem éri meg emiatt bonyolítani a `lex_next` hívási konvencióját
(ami minden híváshoz extra állapotot igényelne).

---

## 8. I/O mechanika

### 8.1 Statikus pufferek

```nasm
SRC_BUF_SIZE equ 1024*1024   ; 1 MiB
OUT_BUF_SIZE equ 65536       ; 64 KiB
```

Mindkettő `.bss`-ben (`resb`), **nem** `.data`-ban (`db 0` kitöltéssel) — a
`.bss`-t a kernel nulláz be betöltéskor, és nem foglal helyet a lemezen lévő
ELF-fájlban, míg egy `db 0` × 1 MiB blokk szó szerint egy megabájttal növelné a
bináris méretét.

### 8.2 Beolvasás (stdin → `src_buf`)

Ismételt `read(0, ...)` hívás `src_buf`-ba, amíg EOF (`rax == 0`) vagy a puffer
betelik EOF nélkül (ez utóbbi hiba, `exit(2)`, mivel a forrás meghaladja a fix
1 MiB-os pufferméretet). A ciklus kezeli a részleges olvasást (POSIX `read`
kevesebb bájtot is visszaadhat a kértnél, EOF előtt is — sosem szabad
feltételezni, hogy egyetlen `read` hívás mindent beolvas).

### 8.3 Kiírás — egy közös `write_all`

Egyetlen újrafelhasználható retry-hurok mind a stdout (token-dump), mind a
stderr (diagnosztika) számára, ugyanazzal a részleges-írás-kezeléssel.

### 8.4 `rax` előjeles ellenőrzése

A nyers Linux x86_64 syscall ABI hiba esetén közvetlenül `-errno`-t ad vissza
`rax`-ban (nincs libc `errno` globális változó). Minden syscall visszatérési
érték ellenőrzésének **előjeles** összehasonlításnak kell lennie (`cmp rax, 0`
/ `jl`) — előjel nélküli bájtszámként értelmezve egy hiba "kb. 18 trillió bájt
beolvasása"-ként jelenne meg.

---

## 9. Token-dump formátum

A driver a token-kindeket egy adat-vezérelt `{címke, echo_spelling}` táblán
keresztül formázza (nem kind-enkénti elágazással):

| Kategória | Példa kindek | Kiírt forma |
|---|---|---|
| azonosító | `TOK_IDENT` | `IDENT is_even` |
| kulcsszó | bármely `TOK_KW_*` | `KW function` |
| egész literál | `TOK_INT` | `INT 16n1F` (a nyers forrásszöveget írja ki, nem a kiszámított értéket) |
| operátor | `TOK_ASSIGN`, `TOK_EQ`, `TOK_PLUS`, … | `OP :=`, `OP ==`, `OP +` |
| strukturális írásjel | `TOK_LBRACE`, `TOK_SEMI`, `TOK_COLON`, … | `LBRACE`, `SEMI`, `COLON` (önmagában, szöveg nélkül) |
| a bemenet vége | `TOK_EOF` | záró `EOF` sor sikeres futás esetén |

A záró `EOF` sor explicit kiírása azért fontos, mert így egy összeomlás miatt
csonka dump vizuálisan megkülönböztethető egy ténylegesen teljes futástól.

---

## 10. Tesztkészlet

Minden fixture a `Stage0/tests/cases/` alatt egy `.ptl` forrásból és három
elvárt-kimenet fájlból áll (`.expected.stdout`, `.expected.stderr`,
`.expected.exit`), amiket a `scripts/run_tests.sh` `diff`-el a tényleges
kimenettel szemben — sikeres esetekben `.expected.stderr` üres és
`.expected.exit` `0`.

| Fixture | Mit fed le |
|---|---|
| `01_function_basic` | Kulcsszavak, azonosítók, zárójelek/kapcsos zárójelek (pl. a fő spec `is_even` mintafüggvénye). |
| `02_integer_literals` | `decimal_form`, `based_form` hexában (`16n1F`) és oktálisan (`8n17`), plusz egy szintaktikailag helyes, de szemantikailag érvénytelen bázisú `based_form` (`99n5`), bizonyítva a lexer szándékos megengedőségét. |
| `03_operators` | Minden kétkarakteres operátor az egykarakteres párja mellett, mindkét irányban, hogy a maximal-munch hibák (mindkét irányban) kiderüljenek. |
| `04_comments` | Sor- és blokk-kommentek token-szerű szöveggel a belsejükben, bizonyítva hogy a szken­nelés helyesen folytatódik utánuk. |
| `05_lexer_error` | Egy valódi érvénytelen bájt (`@`), ellenőrizve: a hiba előtti helyesen felismert prefix megjelenik stdouton, a pontos stderr-diagnosztika, `exit(1)`. |
| `06_unterminated_comment` | Lezáratlan `/*`, ellenőrizve a `TOK_ERROR_COMMENT`-et és hogy a diagnosztika a komment *nyitására*, nem a fájl végére mutat. |
| `07_based_form_empty_digits` | `16n;` — üres bázisjegy-sorozat, ellenőrizve a dedikált `"has no digits after 'n'"` üzenetet, nem az "unexpected character" formát (ld. 7. fejezet). |

---

## 11. Ismert buktatók (implementáció közben szem előtt tartandó)

- **A `syscall` utasítás feltétel nélkül felülírja `rcx`-et és `r11`-et** (a
  kernel ezeket használja a visszatérési RIP/RFLAGS mentésére) — sosem szabad
  feltételezni, hogy ezek túlélnek egy `syscall` hívást. Ehhez kapcsolódik: a
  nyers syscall ABI a 4. paramétert `r10`-ben várja, nem `rcx`-ben (nem
  releváns a `read`/`write`/`exit` esetén, mivel azoknak ≤3 paraméterük van, de
  számítani fog, amint a fő spec `sys_mmap`-ja — 6 paraméter — implementálásra
  kerül).
- **Az 5. fejezet belső hívási konvenciója teljes egészében saját találmány**
  — semmilyen eszköz nem ellenőrzi be nem tartását. Minden rutin elején egy
  rövid megjegyzés arról, mely regisztereket érinti, és a callee-saved
  regiszterek következetes `push`/`pop`-olása az egyetlen védőháló.
- **NASM szekció-konvenciók:** `.text` a kódnak, `.data` az inicializált
  adatoknak (ugrótábla-bejegyzések, hibaüzenet-szövegek, dump-formátum tábla),
  `.bss` (`resb`) a két fix méretű pufferhez (ld. 8.1) — a `.bss` helyes
  használata tartja alacsonyan a lemezen lévő bináris méretét.
- **`-static -no-pie` linkelés** — ld. 2. fejezet táblázata; ez a legvalószínűbb
  forrása egy build-időben néma, futásidőben rejtélyes hibának, ha kimarad.
- **Verem-igazítás** (`rsp % 16 == 0` minden `call` pillanatában), amint a
  `main.asm`-ben belső hívások (`call lex_next`, `call write_all`) megjelennek
  — olcsó fegyelmi kérdés, de elhagyása látens hibákat okozhat, ha valaha SSE
  utasítás (pl. `movaps`, ami 16 bájtos igazítást igényel) kerülne a kódba.
- **Határellenőrzés mind a hét 6.2-beli előretekintési pontnál** — hét külön
  hely, hét külön alkalom elrontani; érdemes egy közös "nézz bele vagy EOF"
  segédrutinba kiszervezni, nem hét helyen külön kézzel ellenőrizni.

---

## 12. Javasolt implementációs sorrend

Az eszközlánc/linkelés kockázatait érdemes a lexikai logika előtt lezárni —
ezek a legkevésbé ismert részei a projektnek, és itt a legvalószínűbb, hogy egy
"lefordul, de a bináris rejtélyesen elszáll" típusú hiba keletkezik.

1. Vázstruktúra + `Dockerfile` + `scripts/build.sh`; egy triviális `_start`,
   ami csak `exit(0)`-t hív. `docker build` zöld legyen, mielőtt bármilyen
   lexikai logika íródna — ez ellenőrzi a Docker-elérhetőséget, a
   `-static -no-pie` linkelést és a konténer-pipeline-t magát.
2. `read_all`/`write_all` implementálása; a `_start` egyelőre csak
   változtatás nélkül visszaírja stdinről stdoutra, amit kap. Ellenőrzi a
   részleges olvasás/írás kezelését és a puffer-megtelt hibaágat.
3. `tokens.inc`/`config.inc` lezárása (struct layout, kind konstansok) —
   minden további lépés erre épül.
4. `skip_trivia` önmagában (whitespace + mindkét komment-forma, beleértve a
   lezáratlan komment hibáját).
5. Diszpatch + írásjelek/operátorok (azonosítók/számok egy hiba-stubra
   mutatnak egyelőre) — ellenőrzés a `03` fixture-rel.
6. Azonosító + kulcsszó bucket-illesztés — ellenőrzés a `01` fixture-rel.
7. Szám-felismerés (decimális + `based_form`, beleértve az üres
   `value_digit+` hibát) — ellenőrzés a `02` fixture-rel.
8. Hiba-diagnosztika a `main.asm`-ben (sor/oszlop, stderr-formázás,
   kilépési kódok) — ellenőrzés a `05`/`06` fixture-ekkel.
9. Teljes driver-hurok + formátum-tábla + `EOF` sentinel — a teljes
   tesztkészlet lefuttatása.
10. `Stage0/README.md` — build/teszt parancsok, kilépési kódok, dump-formátum
    dokumentálása.
