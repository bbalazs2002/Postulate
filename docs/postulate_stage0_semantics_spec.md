# Postulate Stage 0 — Szemantikai elemző technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **szemantikai elemzőjének**
> technikai specifikációja — három menetben: **1. fázis** (névfeloldás +
> alap típusellenőrzés), **2. fázis** (tömb-/struct-literál teljesség,
> based-form számjegy-tartomány, "minden végrehajtási út return-nel
> zárul" vezérlésfolyam-elemzés) és **3. fázis** (tömb broadcast-init,
> fordítási idejű tömbindex-tartomány — mindkettő a kódgenerátor Phase 2
> tervezése közben talált, a fő specben már implicit módon jelen lévő, de
> a checkerben eddig hiányzó szabály). A 3. fázissal a fő spec teljes
> szemantikai szabálylistája lefedésre kerül, a benne magában is
> kifejezetten Stage 0-n túlinak jelölt két tétel kivételével (ld. 10.
> fejezet). Előfeltétele a
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
szemantika utasít el"` elv). A parser saját, fokozatos fejlesztési
fegyelmét folytatva, ez két menetben valósult meg.

**1. fázisban megvalósítva** (az alap, amire minden további szabály épül):
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
- Tömb-/struct-literál **elemenkénti** típuspropagáció (a teljesség
  ekkor még elhalasztva).

**2. fázisban megvalósítva** (ld. 7.4/7.5/8.1 fejezet a részletekért):
- Tömb-literál elemszáma pontosan a deklarált tömbmérettel egyezik.
- Struct-literál minden mezője pontosan egyszer szerepel (duplikátum és
  hiányzó mező egyaránt hiba).
- Based-form számjegy-tartomány: a bázis `{2, 8, 10, 16}` egyike, minden
  számjegy `< bázis`.
- "Minden végrehajtási út return-nel zárul" nem-`void` függvényekben.

**3. fázisban megvalósítva** (ld. 7.6/8.2 fejezet a részletekért):
- Tömb broadcast-init: egy skalár kezdőérték/érték szórása minden elemre,
  ha a típusa a tömb elemtípusával egyezik.
- Tömbindex fordítási idejű tartomány-ellenőrzése bare integer-literál
  indexre.

**Tudatosan Stage 0-n túlra hagyva** (a fő spec is így jelöli, nem
elhalasztott, hanem kizárt tétel ebből a fordítóból, ld. 10. fejezet):
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
`STRUCT_LIT`/`ARRAY_LIT`: elemenkénti típuspropagáció, kiegészítve a 2.
fázisban a teljesség-ellenőrzéssel (ld. 7.4/7.5).

### 7.1 Tömb-literál elemszám (2. fázis)

`.array_lit`-ben, amikor `expected_type` egy valódi `AST_TY_ARRAY` (a
gyakorlati eset — minden tömb-típusú pozíció, decl init vagy struct-mező
init, mindig explicit méretet deklarál): az elemtípus megállapítása után
azonnal összeveti a literál tényleges elemszámát (`AST_EX_ARRAY_LIT`
saját `b` mezője) az elvárt típus deklarált méretével (`AST_TY_ARRAY` `b`
mezője, még mindig `r12`-ben az ág elejétől). A kontextus nélküli eset
(`.array_lit_no_context`) nem kap ellenőrzést — ritka, defenzív ág, a
gyakorlatban sosem így ellenőrződik egy valódi program tömb-literálja.

### 7.2 Struct-literál teljesség (2. fázis)

Mezőnkénti "látott" jelző szükséges, hogy mind a **duplikált** (már
látott mező újra megadva), mind a **hiányzó** (sosem látott mező) esetet
elkapja. Nem kell új regiszter: a meglévő scratch-terület
(`.struct_lit_found`-ban `sub rsp, 32`, a stabil `r14` bázison keresztül
címezve) egyszerűen `MAX_LIST_ARITY` bájttal nő (`sub rsp, 32 +
MAX_LIST_ARITY`) — egy bájt minden lehetséges mező-indexre, közvetlenül a
4 meglévő quad-slot után, `[r14 + 32 + mező_index]`-en címezve. Nullázva
`[0, field_count)`-ra, amint `r13` (a struct decl) ismert — verem-memória,
nem `.bss`, tehát (a kódbázis eddigi ÖSSZES többi scratch-területétől
eltérően, amik mind `.bss`-alapúak, tehát eleve nullázottak) explicit
nullázás kell.

`.struct_field_scan` hurkának saját indexe (`r15`) pontosan a talált mező
saját indexe a struct mezőlistájában, amikor `.struct_field_found`-ba
érünk — közvetlenül újrahasznosítva a "látott" tömb indexeként, nincs
külön könyvelés. Ott: `[r14+32+r15]` ellenőrzése minden más előtt — ha már
`1`, `"duplicate field initializer 'X'"` a field_init saját pozícióján
(`find_offset`, ami az 1. fázis óta kezeli az `AST_FIELD_INIT`-et);
egyébként `1`-re állítva folytatódik, változatlanul.

A `.struct_lit_loop` végén (`.struct_lit_done`, a visszatérési típus
szintézise előtt) végigscanneli `[r14+32, r14+32+field_count)`-ot bármely
még-`0` bejegyzésért — `"missing field initializer 'X'"` az adott index
saját `AST_FIELD_DECL`-jével (a struct mezőlistájából) névre/pozícióra.

### 7.3 Based-form számjegy-tartomány (`validate_int_literal`, 2. fázis)

Önálló, `check_expr`'s `.int` ágából hívott rutin (a kontextustól
függetlenül, a típus eldöntése előtt fut). Visszaszeleteli a literál nyers
szövegét `[parser_src_buf + name_offset, name_len)`-ből (`AST_EX_INT`-en
csak az 1. fázis óta elérhető) és `'n'`-t keres:

- Nincs `'n'` → `decimal_form`, nincs mit ellenőrizni.
- Van `'n'` → a `'n'` előtti számjegyek (a lexer által már garantáltan
  decimálisak) adják a bázist — pontosan `2`, `8`, `10` vagy `16` kell
  legyen (négy `cmp`, nincs szükség táblázatra ennyi értékhez), egyébként
  `"based-form literal base must be 2, 8, 10, or 16, found N"`. A `'n'`
  utáni minden számjegy dekódolva (ugyanaz a `0-9`/`a-f`/`A-F` foldolás,
  amit a `lexer.asm` `lex_handle_number`-je is használ az érték
  kiszámításához) és `< bázis` ellenőrizve — az első sértés
  `"based-form literal has a digit that is not valid in base N"`. Mindkét
  hibaág a literál saját pozícióján jelent (`name_offset` közvetlenül
  elérhető, nincs szükség `find_offset`-re).

### 7.5 Egy második, talált és javított hiba (szintén a struct-literál útján)

A fenti 7.2 fejezet fixture-jeinek megírása közben (két azonos hosszúságú
mezőnév, `struct Point { x; y; }`) egy **másik**, korábban rejtve maradt,
1. fázisból örökölt hiba is előkerült: `.struct_field_scan` a struct
mezőlistáját és mezőszámát `rcx`/`rdx`-ben tartotta a scan-hurok egésze
alatt, majd egy beágyazott `call bytes_equal`-t hívott — ami **saját maga
is `rcx`-et használ belső scratch-ként**, és `rdx`-et is felülírja (a
hívás 3. argumentuma). Az első olyan összehasonlításnál, ahol a névhossz
egyezik, de a tényleges bájtok nem (pontosan ez történik "y"-t keresve,
ha az első jelölt "x" — mindkettő 1 hosszú), a hurok saját felső korlátja
korrupálódott, és a keresés idő előtt "nincs ilyen mező"-t jelentett —
annak ellenére, hogy a mező valójában létezett, csak még nem került sorra.
**Javítás:** a struct mezőlistáját és mezőszámát minden hurok-iterációban
frissen, `r13`-ból (a struct decl, végig védett) olvassuk vissza, sosem
`rcx`/`rdx`-ben gyorsítótárazva a hívás felett.

`find_offset(node) -> offset`: mivel a legtöbb összetett csomópont-fajta
(`BINARY`, `UNARY`, `INDEX`, `CALL`, ...) nem hordoz saját pozíciót, ez a
segédrutin egy kijelölt gyerekbe rekurzál, amíg el nem ér egy olyan
csomópontot, ami tényleg hordoz span-t (`IDENT`/`INT`/`BOOL`/`NULL`/
`FIELD`/`FIELD_INIT`, és a `STMT_RETURN` a saját `return`-kulcsszó
pozíciójára esik vissza, ha nincs kifejezése).

### 7.4 Egy talált és javított hiba (1. fázis, a nagyméretű fekete-doboz programon bukott el)

`.struct_field_found` ág — a talált `AST_FIELD_DECL`
pointert `rcx`-ben tartotta, majd egy beágyazott `check_expr` hívás
**után** újra beolvasta `[rcx + ...]`-t a típus lekéréséhez. Az `rcx`
hívó által mentendő regiszter, a `check_expr` belseje felülírja — ugyanaz
a hibaosztály, mint az `ast_dump.asm` `emit_str`-`rax` esete a parser
fázisból, csak `rcx`-szel. Javítás: a mezőtípust egy védett regiszterbe
(`r12`, ami ezen az ágon máshol nincs használatban) mentjük a beágyazott
hívás **előtt**.

### 7.6 Tömbindex fordítási idejű tartomány-ellenőrzés (3. fázis)

A `.index` ágban, az index-kifejezés `integer`-típus-ellenőrzése után:
csak akkor fut, ha az index-kifejezés **szó szerint** egy `AST_EX_INT`
csomópont (bare integer literál) — nincs általános konstans-összevonás
tetszőleges kifejezésekre (pl. `1+2`), összhangban azzal, hogy a Stage 0
egyáltalán nem tartalmaz optimalizáló/foldoló menetet. Ha a literál saját
értéke (`AST_A_OFF`) `>=` a tömbtípus deklarált elemszámával
(`AST_B_OFF` az `AST_TY_ARRAY` csomóponton), `"array index out of range
for a declared size of N"` hiba. Egy valódi dinamikus (változó/számított)
index **sosem** kerül ellenőrzésre — ez szándékosan egy nulla futásidejű
költségű, csak fordítási idejű diagnosztika marad, nem egy rejtett
futásidejű bounds-check (a kódgenerátor `INDEX` lvalue-kódgenerálása sem
ad ki soha futásidejű ellenőrzést, ld. `docs/postulate_stage0_codegen_spec.md`).

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

### 8.1 "Minden végrehajtási út return-nel zárul" (2. fázis)

Az egyetlen tétel ebben a fázisban, ami nem "bővíts egy meglévő ágat" —
strukturális indukció utasítás-*listákon*, nem egyetlen csomópont saját
alakjának ellenőrzése.

- **`stmts_always_return(stmts_ptr, count) -> 1/0`** — igaz, ha a
  listában **bármelyik** utasítás mindig visszatér (nem csak az utolsó:
  ha egy korábbi utasítás mindig visszatér, minden utána lévő elérhetetlen
  a saját alakjától függetlenül — ez a fázis nem vezet be külön "elérhetetlen
  kód" figyelmeztetést, csak nem hagyja, hogy a holt kód alakja
  befolyásolja a döntést). Szó szerint megosztva `AST_BLOCK` (`a`=stmts,
  `b`=count) és `AST_FUNC_BLOCK` (`c`=stmts, `d`=stmt_count) között — azonos
  csomópont-pointer-tömb alak, csak más mező-offszet a két hívási helyen.
- **`stmt_always_returns(stmt) -> 1/0`** — kind szerint diszpatcher:
  - `AST_STMT_RETURN` → mindig `1`.
  - `AST_STMT_IF` → csak akkor `1`, ha **van** `else`-ága **és** mindkét ág
    (`stmts_always_return` rájuk) mindig visszatér. `else` nélkül mindig
    `0` (az `else` nélküli út definíció szerint átesik).
  - `AST_STMT_WHILE` → általában `0` (Stage 0-ban nincs `break`, de egy
    hurok törzse nulla alkalommal is lefuthat, hacsak a feltétel nem
    feltétlenül igaz — ez az elemzés nem következtet tetszőleges
    kifejezésekre). **Egy megalapozott speciális eset**: ha a feltétel
    szó szerint az `AST_EX_BOOL` `true` literál, a hurok csakis
    `return`-nel léphet ki (vagy örökké fut — mindkettő elfogadható módja
    annak, hogy "sosem esik át ezen a ponton", ugyanúgy, mint pl. a Rust
    `loop {}`-ja) — ez az eset `1`, a törzstől függetlenül.
  - `AST_STMT_ASSIGN` / `AST_STMT_EXPR` → mindig `0`.
- **Bekötés**: `check_function_body`-ban, a `check_func_block` sikeres
  lefutása után, ha a függvény deklarált visszatérési típusa nem `void`,
  `stmts_always_return` a func_block saját utasítás-listáján; ha `0`,
  `"function 'X' may not return a value on every execution path"` a
  függvény saját nevének span-ján (a szignatúrájából — ez az egyetlen
  diagnosztika ebben az egész fázisban, ami egy felső szintű deklarációra
  horgonyoz, nem kifejezésre/utasításra, tehát nincs szüksége
  `find_offset`-re, egyenesen `err_append_span` a szignatúra nevén).

### 8.2 Tömb broadcast-init (3. fázis)

`check_decl` és `check_stmt`'s `.assign` pár-hurka mindkettő ugyanazt a
`check_expr(rhs, target_type)` + `types_equal` mintát követi — ha ez
sikertelen **és** `target_type.kind == AST_TY_ARRAY` **és** `rhs` nem
szó szerint egy `AST_EX_ARRAY_LIT` (azok saját, változatlan
elemszám+elemtípus ellenőrzésen mennek át `check_expr`'s `.array_lit`
ágában), egy új `check_array_broadcast_compatible` segéd fut le
tartalék-ként: `rhs`-t **újra** leellenőrzi, ezúttal a tömb
**elemtípusával** mint elvárt típussal (nem a tömbtípussal magával), és
`types_equal`-lel az elemtípus ellen. Siker esetén ez egy érvényes
broadcast (`mut arr: int32[3] := 0;`), a meglévő
`msg_decl_init_type_mismatch`/`msg_assign_type_mismatch` hibaüzenetek
változatlanok maradnak, csak most már csak a valódi eltérésekre futnak
le. A `check_expr` második hívása biztonságos, mert a rutin maga
side-effect-mentes az `expected_type` szempontjából (csak literálok
fogyasztják el, és sosem hibáznak rá — mindig a hívó `types_equal`-je
dönt).

---

## 9. Tesztkészlet

Három, egymást kiegészítő verifikáció:

1. **`tests/checker_cases/`** + `scripts/run_checker_tests.sh` — 33
   helyes/hibás pár (66 fixture: 24 pár/48 fixture az 1. fázisból, 7
   pár/14 fixture a 2.-ból, 2 pár/4 fixture a 3.-ból), egy-egy a fent
   felsorolt szabályokhoz, mindegyik hiba **pontosan egy** eltérést
   tartalmaz a helyes párjához képest. Nincs irányjelző-sor (a
   `build/checker` mindig a teljes fájlt egy `program`-ként dolgozza fel).
2. A **12 helyes fekete doboz program** (`tests/blackbox_cases/*_valid.ptl`,
   a parser fázisból) újrafuttatva `build/checker`-en keresztül — valós,
   nem minimalizált kód a tervezés igazolására, nem csak célzott
   mini-fixture-ökön. Az 1. fázisban ez fedte fel a 7.4. fejezet `rcx`
   hibáját és egy valódi hibát a saját teszt-programban
   (`sys_exit(common)` `common: int32` argumentummal `int64` paraméter
   ellen — mivel a nyelvnek nincs explicit típuskonverziós szintaxisa, ez
   tényleg érvénytelen volt, a fixture lett javítva, nem a checker). A 2.
   fázisban mind a 12 program változatlanul, hiba nélkül ment át az új
   teljesség-/vezérlésfolyam-szabályokon is.
3. A teljes `docker build` — mind a négy csomag (lexer, fehér doboz
   parser, fekete doboz parser, checker) egyetlen kapun át.

Minden `.expected.*` a ténylegesen lefordított bináris valós
kimenetéből — sosem kézzel kitalálva.

---

## 10. Stage 0-n kívül eső tételek

Ez a két tétel a fő spec szerint is **nem** Stage 0 követelmény (nem
"elhalasztott", hanem kifejezetten kizárt ebből a fordítóból):

- "Figyelmen kívül hagyott visszatérési érték" figyelmeztetés — a fő
  spec is csak egy jövőbeli/végleges fordítói funkcióként jegyzi.
- Előre deklarált (test nélküli) függvények — külön, még meg sem írt
  nyelvtani bővítés (nem azonos az `extern function`-nel).

Ezeken túl a szemantikai elemzőn kívüli, saját fázist igénylő munka:
**kódgenerálás** (LLVM IR vagy natív kód) — ez a következő, érdemben más
jellegű lépés a bootstrap-láncban.
