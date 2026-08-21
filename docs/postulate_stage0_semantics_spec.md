# Postulate Stage 0 — Szemantikai elemző technikai specifikáció (1. fázis)

> Ez a dokumentum a Stage 0 bootstrap fordító **szemantikai elemzőjének**
> technikai specifikációja — az első fázis: **névfeloldás + alap
> típusellenőrzés**. Előfeltétele a
> [postulate_stage0_spec.md](postulate_stage0_spec.md) (nyelvtan,
> szemantikai megkötések 4. fejezete) és a
> [postulate_stage0_parser_spec.md](postulate_stage0_parser_spec.md) (a
> már elkészült, teljes nyelvtant lefedő parser — ennek `parse_program`
> kimenetére épül minden itt leírtak). A cél egy **harmadik, önálló
> `build/checker` bináris** — a `lexer → parser → checker` rétegződés
> folytatása, a Stage 0 bootstrap fordító végleges neve **Hoare** lesz,
> ez a menet még nem az a végleges, egyesített `hoare` parancssori eszköz,
> hanem annak egy köztes építőeleme.

---

## 1. Cél és hatókör

A fő spec 4. fejezetének "Szemantikai megkötések" táblázata 16+ szabályt
sorol fel, amiket a parser tudatosan nem ellenőriz (`"parser megenged,
szemantika utasít el"` elv). Ez a fázis **nem** próbálja mindet egy menetben
megvalósítani — a parser saját, fokozatos fejlesztési fegyelmét folytatva,
csak az **alapot**: névfeloldás + szimbólumtáblák + alap típusellenőrzés,
ami minden további szabály előfeltétele.

**Ebben a fázisban megvalósítva:**
- Felső szintű névregisztráció (struct/function/extern), duplikált név tiltása.
- Extern-fehérlista validáció (név + pontos aláírás-egyezés).
- Függvényenkénti lapos helyi szimbólumtábla (param + decl), duplikátum tiltás.
- Azonosító-felbontás (identifier → local; call → global callable).
- Típus-felbontás (struct-név hivatkozások érvényessége mindenhol, ahol
  típus szerepel: mező, paraméter, visszatérési típus, helyi decl).
- Bináris/érték­adás/return/hívás-argumentum típusegyezés (`int`≡`int16`,
  `uint`≡`uint16` foldolással).
- Mező- és index-hozzáférés érvényessége (struct/tömb/pointer alak).
- `lvalue`-alak ellenőrzése értékadás célpontjára és `&`-ra.
- `const` újraírásának tiltása (pointeren keresztüli írás kivételével).
- Szimultán értékadás cél-egyediség (szintaktikai azonosság szerint).
- `if`/`while` feltétel `bool` volta.
- Tömb-/struct-literál **elemenkénti** típuspropagáció (a teljesség —
  pontos elemszám, minden mező pontosan egyszer — **elhalasztva**, ld. 8.
  fejezet).

**Tudatosan elhalasztva egy jövőbeli fázisra** (ld. 8. fejezet a teljes
listáért): tömb-/struct-literál teljesség, based-form számjegy-tartomány,
"minden végrehajtási út return-nel zárul" vezérlésfolyam-elemzés,
"figyelmen kívül hagyott visszatérési érték" figyelmeztetés, előre
deklarált (test nélküli) függvények.

---

## 2. Három nyitott kérdés a nyelvi specifikációban — itt eldöntve

A tervezés/implementáció során három olyan pont derült ki, amit a fő spec
nem mond ki explicit módon. Mindhárom eldöntésre került (a döntés
indoklásával), de érdemes lenne a fő specbe is felvenni — ez nem történt
meg ebben a menetben, csak itt van rögzítve.

### 2.1 Literál-tipizálás

A nyelvtanban nincs literál-utótag (`5i32` stílusú jelölés nincs), tehát
egy csupasz `5`-nek nem lehet önmagában rögzített típusa — miközben az
"Implicit típuskonverzió: Tilos" szabály megköveteli, hogy minden
kifejezésnek legyen *pontos* típusa az összehasonlításhoz. Az egyetlen
életképes olvasat (és az egyetlen, ami összhangban van a fő spec saját
mintaprogramjával, ahol csupasz literálok kerülnek különböző méretű
mezőkbe): **kontextuális/tipizálatlan konstans** modell, Go mintájára — az
`int`/`bool`/`null` literáloknak nincs saját, rögzített típusuk;
`check_expr` egy `expected_type` paramétert kap, amit **kizárólag** a
literálok fogyasztanak el ténylegesen.

### 2.2 A formális `lvalue` szabály nem fedi le a `(*arr)[i]` alakot

`lvalue ::= "*" lvalue | identifier ("[" expr "]" | "." identifier)*` — ez
csak azt engedi meg, hogy a `*` egy **másik `lvalue`-t** előzzön meg, nem
egy zárójelezett-majd-indexelt kifejezést. De a `(*arr)[i] := ...`
pontosan az a minta, amit a `*(T[N])` pointer-tömb tervezési döntés
(kifejezés-parser fázis) lehetővé tesz, és amit a fekete doboz
tesztkészlet is végig használ. A parser már elfogadja (megengedő
tervezésű, a szemantika dönt). **Ez a fázis strukturálisan definiálja az
"érvényes lvalue"-t**, nem a nyelvtan betűje szerint: bármely kifejezés,
ami **kizárólag** `IDENT`/`UNARY(*)`/`INDEX`/`FIELD` csomópontokból épül
fel, végül egy csupasz azonosítónál záródva — ez természetesen elfogadja
a `(*arr)[i]`-t is.

### 2.3 `const` és `*` kölcsönhatása

Hibás-e a `*p := 5;`, ha `p` egy `const` pointer? Maga `p` újraírása hiba
lenne, de a rajta keresztüli írás más eset — a Stage 0-nak nincs külön
`const T` vs. `T` típus-minősítője, a `const` a **kötésre** vonatkozó
egyszeri-értékadás tulajdonság, nem a mutatott értékre. Szabály: az
`lvalue`-láncot kívülről befelé bejárva, ha egy `*` dereferencia
**előbb** előfordul, mint hogy elérnénk az alap-azonosítót, az
"íráson-keresztül-pointer" — a `const` állapota innentől irreleváns. Csak
az a lánc kap `const`-ellenőrzést, ami **deref nélkül** éri el az
alap-azonosítót.

---

## 3. Architektúra: `build/checker` (harmadik, önálló bináris)

Ugyanaz a rétegződés, mint lexer→parser: a checker linkeli a teljes
meglévő parser-/lexer-kódot (`lexer.asm`, `parser_tokens.asm`,
`type_parser.asm`, `expr_parser.asm`, `stmt_parser.asm`, `top_parser.asm`,
`ast.asm`, `runtime.asm`), de **nem** linkeli `ast_dump.asm`-et (nincs rá
szüksége — a checker sikeres futás esetén csak `OK`-t ír, nem AST-dumpot).

`checker_main.asm` driverje **nem** irányjelző-alapú (szemben
`parser_main.asm` teszt-driverjével) — a teljes stdin-t egyetlen
`program`-ként olvassa be és ellenőrzi, mert ellenőrzés mindig a teljes
programra vonatkozik. Ez a jelenleg elkészült binárisok közül a
legközelebbi ahhoz, ahogy a végleges `hoare` parancssori eszköz egy `.ptl`
fájlt kap.

**Kilépési kódok**, kiegészítve:

| Kód | Jelentés |
|---|---|
| `0` | Siker — `OK\n` stdoutra. |
| `1` | Lexikai/szintaktikai hiba (változatlan, a parsertől örökölve). |
| `2` | Erőforrás-jellegű hiba (változatlan). |
| `3` | **Új: szemantikai hiba.** `semantic error: <üzenet> at line L, col C (byte offset O)` stderr-re. |

---

## 4. Nincs új AST-csomópont — egy kivétellel

A szimbólumtáblák és a típusellenőrzés **csak-olvasás** jellegű bejárás a
meglévő AST fölött — nincs új `AST_*` kind, nincs visszaírt annotáció,
nincs perzisztens "dekorált AST" (semmi nem fogyasztja még — egy jövőbeli
kódgeneráló fázis eldöntheti majd, kell-e neki perzisztens típus-annotáció
vagy újra lefuttatja az inferenciát; ez a döntés **nem** ebben a fázisban
születik).

**Az egyetlen kivétel:** `AST_EX_INT`/`AST_EX_BOOL`/`AST_EX_NULL` eredetileg
csak az értéket tárolta (`a` mező; `b`/`c`/`d` üres) — a többi "névvel
bíró" csomóponttal (`AST_EX_IDENT`, `AST_TY_BASE` névhivatkozás esete)
ellentétben nem őrizte meg a forrás-span-t. Egy literálra összpontosuló
típushiba (pl. `if (5) { ... }`) diagnosztikájához **kell** valamilyen
pozíció. Javítás: `AST_EX_INT` `b`/`c` mezője mostantól `name_offset`/
`name_len` (az `a`-ban maradó érték mellett); `AST_EX_BOOL`/`AST_EX_NULL`
`a`/`b` (illetve `b`/`c`) mezője ugyanez — additív, nem-törő változtatás
(`dump_expr` `.int`/`.bool`/`.null` esetei nem olvassák ezeket a mezőket,
nem kellett módosítani). `expr_parser.asm` `.int`/`.true`/`.false`/`.null`
ágai kaptak pár extra `mov`-ot a `parser_advance` **előtt**, hogy a tokent
el ne veszítsék.

**Egy második, hasonló kiegészítés:** `AST_STMT_RETURN` `b` mezője
mostantól a `return` kulcsszó saját forrás-offszetje — az egyetlen
utasítás-fajta, aminek erre szüksége volt, mert a "hiányzó return érték"
hiba (`return;` egy nem-`void` függvényben) esetén nincs kifejezés,
amire a diagnosztika pozícióját rá lehetne akasztani, és semmilyen más
mező nem ad erre alternatívát.

---

## 5. Szimbólumtáblák (`symtab.asm`)

Nincs beágyazott hatókör modellezendő: a Stage 0 kizárólag a `func_block`
elején enged `decl`-t (soha `if`/`while` testében) — tehát **pontosan egy**
lapos hatókör van függvényenként (param-jai + saját decl-jei), nincs
árnyékolási szabály. Mindhárom tábla lapos, `MAX_LIST_ARITY`-korlátos
tömb, lineáris kereséssel — ugyanaz a minta, mint minden más változó
aritású lista a kódbázisban (`symtab.inc` rögzíti a rekord-elrendezéseket,
megosztva az író `symtab.asm` és az olvasó `sema_expr.asm`/`sema_stmt.asm`
között).

- **Globális tábla**, `AST_PROGRAM`-onként egyszer, két al-menetben, hogy
  a deklarációs sorrend és a kölcsönös/előre hivatkozások (egy később
  deklarált függvényt hívó függvény, önmagát hívó `gcd`, egy később
  deklarált structra hivatkozó struct) sorrendtől függetlenül működjenek:
  - *1a menet — nevek regisztrálása*: `struct_table` (`{name_offset,
    name_len, AST_STRUCT_DECL ptr}`), `callable_table` (`{name_offset,
    name_len, is_extern, AST_SIGNATURE ptr, return_type ptr}` —
    function+extern egyesítve, mindkettő azonosan "névvel hívható").
    Duplikátum-ellenőrzés **egy közös névtérben**, struct+function+extern
    együtt (egyszerűsítő, felülvizsgálható döntés — nem nyelvi
    követelmény).
  - *1b menet — minden deklarált típus felbontása*: minden típus-előfordulás
    (struct-mezők, paraméterek, visszatérési típusok) végigfut a
    `resolve_type`-on, miután minden név ismert.
  - *2. menet — minden függvénytörzs ellenőrzése* a most már teljes
    globális táblával.
- **Helyi tábla**, függvényenként újraépítve: lapos `{name_offset,
  name_len, type ptr, is_const}` lista a szignatúra param-jaiból + a
  `func_block` decl-jeiből. Ugyanúgy duplikátum-ellenőrzött (param/param,
  param/decl, decl/decl — nincs mit árnyékolni). **Itt** történik minden
  helyi decl saját típusának felbontása is (nem az 1b menetben — csak
  akkor kell érvényesnek lennie, amikor az adott függvény törzsét
  ellenőrizzük, nem korábban).
- **Keresés**: lineáris scan + `bytes_equal` (a `parser_main.asm`-ből
  ismert minta helyi másolata, a kódbázis "kis segédfüggvények
  fájlonként duplikálva" konvenciója szerint).

---

## 6. Típusok (`sema_types.asm`)

Egy "típus" itt egyszerűen egy már létező `AST_TY_*` csomópontra mutató
pointer — leggyakrabban egy már az AST-ban ülő csomópont (egy decl saját
típusa, egy szimbólumtábla-bejegyzés típusa), esetenként frissen
szintetizált (`get_bool_type`/`get_int_type`/`get_null_default_type`
kanonikus szingletonok, vagy `&x` eredménytípusa `sema_expr.asm`-ben) —
`ast_alloc_node`-on keresztül.

- **`resolve_type`**: rekurzív érvényesség-ellenőrzés — `POINTER` a belsőre
  rekurzál, `ARRAY` az elemre, beépített `BASE` mindig érvényes,
  struct-név `BASE` (tag=0) a globális struct-táblában keresendő, hiba ha
  nincs.
- **`types_equal`**: strukturális összehasonlítás, `int`≡`int16` /
  `uint`≡`uint16` foldolással (a fő spec "int/uint" sora — más
  `TOK_KW_*` tag, azonos alul fekvő típus); struct-név `BASE`-ek
  névspan-összehasonlítással; `ARRAY` emellett elemszám-egyezést is
  megkövetel. **0 ("void") egyik oldalon sem egyenlő semmivel** — ez a
  kikötés zárja le egyöntetűen azt az esetet, amikor egy `void`
  visszatérésű hívás eredményét értékként próbálják felhasználni (ld. 7.
  fejezet).

---

## 7. Kifejezés-ellenőrzés (`sema_expr.asm`)

`check_expr(node, expected_type) -> resolved type ptr` — egy nagy
diszpatcher, `dump_expr` csomópont-fajtánkénti alakját követve, formázás
helyett számítással/ellenőrzéssel. Az `expected_type`-ot **csak** a
literálok (`INT`/`BOOL`/`NULL`) és az `array_literal` fogyasztja
ténylegesen (utóbbi az elemtípust tanulja meg belőle, mivel önmagában
nincs típus-annotációja).

Bináris/aritmetikai kifejezéseknél: **amelyik oldal NEM csupasz literál,
azt ellenőrizzük előbb**, és az ő eredménye horgonyozza a másik oldalt (ha
mindkettő literál, a külső `expected_type` horgonyozza az elsőt, az pedig
a másodikat) — ld. 2.1. fejezet. `CALL`: a hívott kizárólag csupasz
`IDENT` lehet, ami a globális `callable_table`-ben feloldódik (Stage
0-ban nincs függvénymutató/first-class function); argumentum-szám és
-típus egyezés a szignatúra param-jaival. `FIELD`/`INDEX`: alap típusa
struct/tömb kell legyen, a mező/index érvényessége ellenőrzött.
`STRUCT_LIT`/`ARRAY_LIT`: elemenkénti típuspropagáció (a teljesség
elhalasztva).

`find_offset(node) -> offset`: mivel a legtöbb összetett csomópont-fajta
(`BINARY`, `UNARY`, `INDEX`, `CALL`, ...) nem hordoz saját pozíciót, ez a
segédrutin egy kijelölt gyerekbe rekurzál, amíg el nem ér egy olyan
csomópontot, ami tényleg hordoz span-t (`IDENT`/`INT`/`BOOL`/`NULL`/
`FIELD`/`FIELD_INIT`, és a `STMT_RETURN` a saját `return`-kulcsszó
pozíciójára esik vissza, ha nincs kifejezése).

**Talált és javított hiba (a nagyméretű fekete-doboz programon
bukott el):** `.struct_field_found` ág — a talált `AST_FIELD_DECL`
pointert `rcx`-ben tartotta, majd egy beágyazott `check_expr` hívás
**után** újra beolvasta `[rcx + ...]`-t a típus lekéréséhez. Az `rcx`
hívó által mentendő regiszter, a `check_expr` belseje felülírja — ugyanaz
a hibaosztály, mint az `ast_dump.asm` `emit_str`-`rax` esete a parser
fázisból, csak `rcx`-szel. Javítás: a mezőtípust egy védett regiszterbe
(`r12`, ami ezen az ágon máshol nincs használatban) mentjük a beágyazott
hívás **előtt**.

---

## 8. Utasítás-ellenőrzés, extern-fehérlista, `check_program` (`sema_stmt.asm`)

- **`check_decl`**: ha van kezdőérték, `check_expr` a deklarált típussal
  mint elvárt típussal, majd `types_equal`.
- **`check_stmt`**: `assign`/`if`/`while`/`return`/`expr_stmt` ágak. Az
  `assign` a legösszetettebb: minden párra `lvalue`-alak ellenőrzés (2.2),
  `const`-ellenőrzés (2.3), majd `check_expr`+`types_equal` az RHS-re; az
  összes pár után egy páronkénti (O(n²), de a párok száma a gyakorlatban
  2-4) `lvalue_equal` strukturális összehasonlítás a duplikált célpontok
  ellen — **csak szintaktikai** azonosságot néz (`x := 1, x := 2;` hibázik,
  `arr[i] := 1, arr[j] := 2;` nem, még ha `i == j` futásidőben — nincs
  aliasing-elemzés, tudatos hatókör-korlát).
- **`check_extern_whitelist`**: a fő spec 2. fejezetének 4 fix szignatúrája
  (`sys_read`/`sys_write`/`sys_mmap`/`sys_exit`) — név `bytes_equal`-lel
  azonosítva, majd param-onkénti `types_equal` a `mk_base`/`mk_ptr_base`
  segédekkel szintetizált elvárt típusok ellen.
- **`check_program`**: `build_global_tables` (1a) → `resolve_all_types`
  (1b) → minden `AST_FUNCTION` törzse (`build_local_table` +
  `check_func_block`) + minden `AST_EXTERN_DECL` a fehérlistával szemben
  (2. menet). A struct-deklarációknak nincs további teendőjük — az 1b
  menet már ellenőrizte a mezőik típusait.

---

## 9. Tesztkészlet

Három, egymást kiegészítő verifikáció:

1. **`tests/checker_cases/`** + `scripts/run_checker_tests.sh` — 24
   helyes/hibás pár (48 fixture), egy-egy a fent felsorolt szabályokhoz,
   mindegyik hiba **pontosan egy** eltérést tartalmaz a helyes párjához
   képest. Nincs irányjelző-sor (a `build/checker` mindig a teljes fájlt
   egy `program`-ként dolgozza fel).
2. A **12 helyes fekete doboz program** (`tests/blackbox_cases/*_valid.ptl`,
   a parser fázisból) újrafuttatva `build/checker`-en keresztül — valós,
   nem minimalizált kód a tervezés igazolására, nem csak célzott
   mini-fixture-ökön. Ez fedte fel a fenti `rcx` hibát, és egy valódi
   hibát is a saját teszt-programban: `sys_exit(common)` `common: int32`
   argumentummal `int64` paraméter ellen — mivel a nyelvnek nincs explicit
   típuskonverziós szintaxisa, ez tényleg érvénytelen volt, a fixture lett
   javítva (`sys_exit(0)`), nem a checker.
3. A teljes `docker build` — mind a négy csomag (lexer, fehér doboz
   parser, fekete doboz parser, checker) egyetlen kapun át.

Minden `.expected.*` a ténylegesen lefordított bináris valós
kimenetéből — sosem kézzel kitalálva.

---

## 10. Elhalasztott szabályok (jövőbeli fázisok)

- `array_literal`/`struct_literal` **teljesség** (pontos elemszám, minden
  mező pontosan egyszer) — jelenleg csak elemenkénti típuspropagáció fut.
- Based-form számjegy-tartomány (`{2,8,10,16}` bázis, számjegy < bázis) —
  megköveteli, hogy `AST_EX_INT` a nyers span-t is megőrizze (ami most már
  megvan, ld. 4. fejezet), de a bázis/számjegyek tényleges validálása még
  nincs implementálva.
- "Minden végrehajtási út return-nel zárul" — vezérlésfolyam-elemzés,
  algoritmikusan különálló, saját fázist érdemel.
- "Figyelmen kívül hagyott visszatérési érték" figyelmeztetés — a fő
  spec is csak egy jövőbeli/végleges fordítói funkcióként jegyzi, nem
  Stage 0 követelmény.
- Előre deklarált (test nélküli) függvények — külön, még meg sem írt
  nyelvtani bővítés.
- Kódgenerálás (LLVM IR vagy natív kód) — ez a szemantikai elemzőn túli,
  saját fázis.
