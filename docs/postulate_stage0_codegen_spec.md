# Postulate Stage 0 — Kódgenerátor technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **kódgenerátorának**
> technikai specifikációja — **1. fázis**: egyfüggvényes (`main`),
> csak skalár típusokat kezelő, teljes kifejezés-/`if`/`while`-kódgenerálás,
> a fehérlistázott `extern` syscall-okra való hívással bezárólag. **2.
> fázis**: struct/tömb/pointer típusú lokálisok és paraméterek, teljes
> `INDEX`/`FIELD`/`UNARY(*)`/`UNARY(&)`-kódgenerálás, struct-/tömb-literál
> (`STRUCT_LIT`/`ARRAY_LIT`), tömb broadcast-init, struct-/tömb-érték
> egyszerű másolása (`p2 := p1;`), és tetszőleges számú felhasználói
> függvény egymás közti hívása (rekurzióval együtt) — mindezt **kivéve**
> egy struct/tömb **érték** függvényhívás-határon való átvitelét
> (argumentumként vagy visszatérési értékként). **3. fázis**: pontosan
> ez a kihagyott tétel — struct/tömb érték most már argumentumként **és**
> visszatérési értékként is átmehet egy hívás-határon (ld. 2. és 6.5-6.8.
> fejezet); két szűk, tudatosan elhalasztott eset marad nyitva (ld. 10.
> fejezet). A cél egy **negyedik, önálló `build/codegen` bináris** — a
> `lexer → parser → checker → codegen` rétegződés folytatása. Előfeltétele
> a [postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
> (a már elkészült, teljes szemantikai ellenőrzés — a generált kód csak
> olyan programra készül, ami már átment rajta) és a
> [postulate_stage0_parser_spec.md](postulate_stage0_parser_spec.md)
> (AST-csomópont-elrendezés). A Stage 0 compiler végleges neve **Hoare**;
> ez a menet még nem az egyesített `hoare` CLI, hanem annak egy köztes
> építőeleme.
>
> Emlékeztető (2026-08-21-i döntés): **a Stage 0-nak nincs optimalizáló
> menete** — a lenti kódgenerálás szándékosan naiv (nincs regiszter-
> allokáció, konstans-összevonás, holt kód eltávolítás). Az optimalizálás
> a Stage 1 (önmagát fordító, Postulate-ben írt) compiler dolga lesz.

---

## 1. Cél és hatókör

- **Kimenet**: `build/codegen` **NASM assembly szöveget** ír stdout-ra,
  amit a már meglévő `nasm`+`ld` eszközlánc fordít le és linkel (ugyanaz
  a láncszem, amit `Stage0/scripts/build.sh` maga is használ) — nincs
  saját ELF-writer vagy linker.
- **Struct-elrendezés**: **packed, nincs padding** — a mezők a deklaráció
  sorrendjében, egymás után, kitöltés nélkül. Ezt a Stage 1 megírásakor
  érdemes felülvizsgálni (a természetes/ABI-igazítás lesz ekkor a
  valószínű alternatíva); most a legegyszerűbb helyes választás egy nem
  optimalizáló bootstrap fordítóhoz.
- **1. fázis hatóköre** — a legegyszerűbb végpontok-közti szelet, ami az
  egész új csővezetéket bizonyítja (`.ptl` → ellenőrzött AST → `.asm`
  szöveg → `nasm`+`ld` → valódi Linux bináris → **lefuttatva
  ellenőrizve**), mielőtt a memóriaelrendezés bonyolultsága hozzáadódna:
  egy függvény (`main`), csak skalár típusok, teljes kifejezés-/
  `if`/`while`-kódgenerálás, hívás csak fehérlistázott `extern`
  függvényre.
- **2. fázis hatóköre** (ld. 6. fejezet a részletekért) — mindaz, amit az
  1. fázis "dokumentálva, elhalasztva"-ként jelölt, a struct/tömb
  **érték** hívás-határon átvitele kivételével:
  - Struct/tömb/pointer típusú `decl`/paraméter (2. fázisban a
    paraméterek **csak** skalár/pointer maradtak, mert egy paraméter
    definíció szerint hívás-határon kel át, míg egy `decl` nem — ezt a
    3. fázis oldja fel, ld. lent).
  - `INDEX`/`FIELD`/`UNARY(*)`/`UNARY(&)` — összeköthető, tetszőleges
    mélységben (`*arr[2]`, `*values.value.ptrs[3]`), rekurzív
    `gen_lvalue`/`gen_rvalue`-definíció révén.
  - `STRUCT_LIT`/`ARRAY_LIT` (decl-init, egy-páros és több-páros
    szimultán értékadás jobb oldalán is), tömb broadcast-init, struct-/
    tömb-érték egyszerű másolása (`p2 := p1;`).
  - Tetszőleges számú `AST_FUNCTION`, egymás közti hívással és
    rekurzióval.
  - `sys_read`/`sys_write`/`sys_mmap` immár ténylegesen hívható (pointer
    argumentumaikhoz most már van kódgenerálás).
- **3. fázis hatóköre** (ld. 2. és 6.5-6.8. fejezet a részletekért) —
  struct/tömb **érték** immár átmehet egy felhasználói függvényhívás
  határán, mindkét irányban:
  - **Argumentumként**: egy összetett paraméter bejövő 8 bájtos rése
    immár egy **címet** tartalmaz érték helyett (ugyanúgy, ahogy egy
    pointer-argumentum már eddig is) — a hívó vagy egy már létező
    lvalue (lokális, mező, elem, egy másik összetett-visszatérésű hívás
    eredménye) címét adja tovább közvetlenül, **másolás nélkül**, vagy
    (struct-/tömb-literál argumentum esetén) egy friss ideiglenes
    területre materializálja azt. A **valódi**, érték-szerinti másolatot
    a **hívott fél saját** prológusa készíti (`emit_param_copy`
    összetett ága, `rep movsb` a bejövő pointerből a saját lokális
    résébe) — a hívó oldalán így nem kell "védeni" semmit a hívás után,
    a hívott a saját, független példányát kapja.
  - **Visszatérési értékként**: a rejtett `rdx` output-pointer konvenció
    (ld. 2. fejezet, már 2. fázis óta dokumentálva, most bekötve) — a
    hívó egy friss ideiglenes területet foglal a célprogram saját
    stack-jén (`sub rsp, <méret>`), ennek címét adja át `rdx`-ben, a
    hívott fél pedig ide írja a `return`-nel visszaadott értéket
    közvetlenül, `rax` helyett.
  - Minden más konstrukció (ld. 10. fejezet: egy összetett-visszatérésű
    hívás mint egy struct-/tömb-literál mező-/elem-értéke; összetett
    típusú `BINARY` operátorok) **lentebb dokumentálva van**, de
    **nincs implementálva** — ezeket a `codegen error: ...` diagnosztika
    (4-es kilépőkód, ld. 9. fejezet) jelzi tisztán, ahelyett hogy rossz
    kódot generálna.

---

## 2. Hívási konvenció

**Nem a platform ABI — egy egyedi, egységes, argumentumszám-független
konvenció** felhasználó-függvény hívásokra (az `extern`/syscall hívás
külön, fix alakú útvonal, ld. 6. fejezet `AST_EX_CALL` — ez a döntés
sosem kell hogy együttműködjön a valódi SysV ABI-val, mert nincs olyan
idegen kód, amit egy lefordított Postulate függvénynek közvetlenül
hívhatóvá kéne tennie *magából* — az `extern function` egy zárt,
4-syscall fehérlista, nem általános FFI).

- Az argumentumok **jobbról balra** kerülnek kiértékelésre, és
  azonnal, egyenként **push**-olásra — függetlenül a számuktól. Mivel
  `arg1` (a legbaloldalibb) kerül kiértékelésre **utoljára**, ő kerül
  push-olásra is utoljára, tehát a stack-en `rsp`-hez legközelebb lesz —
  a stack `arg1, arg2, ..., argN` sorrendben, felülről lefelé olvasható,
  egyenként 8 bájtos résekben (egységesen 8 bájt, függetlenül az
  argumentum tényleges deklarált méretétől — a legegyszerűbb címzés:
  `[block_ptr + (i-1)*8]`). Egy **skalár/pointer** argumentum rése az
  értékét tartalmazza; egy **összetett** argumentum rése (3. fázis) egy
  **címet** tartalmaz (ld. lent) — a rés mérete és a konvenció alakja
  emiatt nem változik, csak az, hogy mit jelent a benne lévő 8 bájt.
- A hívott fél pontosan **két** dolgot kap, **`rdi`**/**`rsi`**-ben:
  egy pointert az első argumentumra (`rdi`) és az argumentumok számát
  (`rsi`) — mindig ugyanez a két regiszter, függetlenül az aktuális
  argumentumszámtól.
- **Visszatérési érték**: skalár/pointer típusok → `rax` (nincs
  megváltoztatva). `void` → `rax` nincs felhasználva. **Struct/tömb
  visszatérési típusok** (3. fázis): a hívó egy harmadik, rejtett
  argumentumot ad át — egy pointert oda, ahova az eredményt írni kell
  (`rdx`, amit ez a konvenció egyébként nem használ) — a hívott fél
  ezen a pointeren keresztül írja az eredményt, `rax` helyett. A hívó
  ezt a pointert **nem** tartja élve egy regiszterben az argumentum-
  kiértékelés teljes ideje alatt (a beágyazott hívások szabadon
  felülírnák) — a célterületet a saját argumentum-blokkja **elé**
  foglalja (`sub rsp, <méret, 8-ra kerekítve>`, `gen_lvalue` `CALL`
  ága, `codegen_expr.asm`), majd a `call pf_<name>` közvetlen előtt egy
  fordítási időben ismert `lea rdx, [rsp + N]`-nel számítja újra a
  címét (`N` = a hívás saját argumentum-blokkjának teljes, ekkorra már
  ismert mérete, ld. lent) — nincs szüksége egyetlen extra regiszterre
  sem, ami "túlélné" a köztes kiértékelést.
- **Összetett argumentum-materializáció** (3. fázis, `gen_user_call`,
  `codegen_expr.asm`): a hívott fél saját paraméter-típusa dönti el
  (nem az argumentum-kifejezés saját, esetlegesen eltérő típusa —
  bár a checker már garantálja, hogy a kettő megegyezik), hogy egy
  argumentum összetett-e. Ha igen:
  - **lvalue-alakú forrás** (`IDENT`/`INDEX`/`FIELD`/`UNARY(*)`/`CALL`):
    a forrás **saját** címe (`gen_lvalue(arg) -> rbx`) kerül közvetlenül
    push-olásra, **másolás nélkül** — a hívott fél saját prológusa
    (`emit_param_copy`) másolja ki onnan a saját, független példányát,
    tehát a hívó oldalán nincs értelme előre másolni.
  - **struct-/tömb-literál forrás**: egy friss ideiglenes terület
    foglalása (`sub rsp, <méret, 8-ra kerekítve>`), a literál
    materializálása bele (`gen_init_push`/`gen_init_pop_store`, ld.
    6.6 — a cél címe a `gen_init_push` **visszatérési értékéből**
    [összesen push-olt bájtok] számítva vissza, egy fordítási időben
    ismert `lea rbx, [rsp + leaf_bytes]`-szel, mert a levelek a
    foglalás **után** kerülnek push-olásra), majd ennek a friss
    területnek a címe push-olva.
  - Az összes ilyen ideiglenes terület (mind az összetett argumentumoké,
    mind egy beágyazott, összetett-visszatérésű hívásból származó
    argumentumé) a hívás **saját** végső `add rsp, N`-jével szabadul fel
    — `N` innentől nem egyszerűen `arg_count*8`, hanem minden argumentum
    tényleges lefoglalt méretének összege, 16-ra kerekítve (a padding-
    döntés emiatt egy előzetes, semmit ki nem adó menetet igényel, ami
    kiszámolja `N`-et, mielőtt bármit is kiadna — ld. `gen_user_call`
    fejlécét).
- A hívó takarít a hívás után (`add rsp, N`, `N` fordítási időben
  ismert hívási helyenként — előtte 16-ra kerekítve, ld. 4. fejezet és
  fent).

**Kikötés, explicit módon kimondva**: az argumentum-kifejezések **jobbról
balra** értékelődnek ki. Ha két argumentum kiértékelése közös állapotot
érint (mellékhatásos beágyazott hívásokon, `&`-ból származó pointereken
keresztül stb.), a jobboldali argumentum mellékhatása történik meg előbb.
Ez **szándékos, dokumentált** viselkedés, nem hiba. Ugyanígy vonatkozik
az `extern`/syscall hívási helyekre is (ld. 6. fejezet) — így a teljes
nyelvre **pontosan egy** kiértékelési sorrend-szabály van, még akkor is,
ha a két hívásfajta másképp helyezi el a kiértékelt argumentumokat.

### 2.1 Stack-fegyelem

**Minden `push`-nak, amit egy függvény generált kódja kiad, meg kell
lennie a párja `pop`-jának** (vagy egy azzal egyenértékű tömeges
`add rsp, ...`-nak) mielőtt a függvény visszatér. Egy függvény saját
`rsp`-re gyakorolt nettó hatása, a prológus végétől az epilógus elejéig,
**nulla** kell legyen.

Ez különösen a fenti hívási konvenció miatt fontos: egy hívott fél kap
egy pointert (`rdi`) olyan memóriába, amit **nem ő maga** push-olt — a
hívó frissen push-olt argumentum-blokkja, a hívott fél saját `rbp`-je
*fölött* a hívó frame-jében. Egy függvény szabadon **olvashat** olyan
stack-memóriát, amit nem ő push-olt (a saját bejövő argumentum-blokkja
pont ilyen), de sosem `pop`-olhatja, nem írhat bele, és nem kezelheti
saját lokális scratch területként — csak az veheti vissza egy adott
területet, aki push-olta.

---

## 3. Regiszter-konvenció: érték vs. cím

Minden kifejezés-kódgeneráló rutin kétféle egyike, mindegyiknek **saját,
külön eredmény-regisztere** van — szigorúan szétválasztva, ne mindkettő
`rax`-on menjen keresztül, hogy egy olyan konstrukció, aminek egyszerre
kell érték **és** cím (a szimultán értékadás a motiváló eset), sose
írja felül egymást csendben:

- **`gen_rvalue(node) -> érték a target `rax`-ban`** — "mire értékelődik
  ki ez a kifejezés". Előjeles típusok `movsx`-szel 64 bitre kiterjesztve,
  előjeltelen/`bool` `movzx`-szel.
- **`gen_lvalue(node) -> cím a target `rbx`-ben`** — "hol él ez a
  kifejezés a memóriában". Csak értékadás célpontjára és `&` operandusára
  használt — és láncoltan, `gen_rvalue` maga is emezt hívja `IDENT`/
  `INDEX`/`FIELD`/`UNARY(*)` esetén.

`rbx` callee-saved, túléli bármely beágyazott `call`/`syscall`-t extra
védelem nélkül, és ez a kódbázis már eddig is ezt a szerepet szánta neki
máshol (pl. `sema_expr.asm` `.struct_lit` scratch-alapja).

**Megjegyzés a "két világról"**: ez a dokumentum (és a hozzá tartozó
`codegen_*.asm` fájlok) `rbx`/`r12`-`r15`-öt **a Stage 0 fordító saját**
fordítási idejű könyveléséhez használják, a kódbázis egyetemes
konvenciója szerint — ez teljesen elkülönül attól az `rbx`-től, amiről
fentebb szó volt, ami a **generált** assembly szöveg futásidejű
regiszterére utal, amit csak az olvas vissza, ami expliciten `"[rbx]"`
szöveget ír ki (`emit_sized_load`/`emit_sized_store`).

---

## 4. Stack-frame elrendezés

Klasszikus frame-pointer prológus/epilógus:

```nasm
pf_main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, <locals_size>     ; 16 többszörösére kerekítve
    ; -- egy load+store parametérenként, [rdi + i*8]-ból --
    ; ... törzs ...
.epilogue:
    mov     rsp, rbp
    pop     rbp
    ret
```

`<locals_size>`-nek 16 többszörösének kell lennie: az ABI garantálja,
hogy `rsp % 16 == 0` közvetlenül egy `call` előtt; a `call` maga push-ol
egy 8 bájtos visszatérési címet (hívott fél belépéskor: `rsp % 16 == 8`);
`push rbp` visszaállítja a 16-igazítást (`rsp % 16 == 0`) — tehát
`sub rsp, N` csak akkor tartja meg ezt az invariánst (ami *ennek* a
függvénynek a saját beágyazott `call`-jaihoz kell), ha `N % 16 == 0`.

Minden lokális (paraméter vagy `decl`) pontosan **egy fix stack-rést**
kap, a saját típusa szerint méretezve. A paraméterek egy pointer+szám
párként érkeznek (ld. 2. fejezet), és azonnal átmásolódnak a saját
résükbe a prológusban.

**Újrahasznosítás**: a függvényenkénti lokális lista már megvan a
szemantikai ellenőrzőtől (`symtab.asm` `build_local_table`/`local_table`)
— a kódgenerátor nem származtatja újra, hanem újra lefuttatja
(`build_local_table`, már exportálva), és hozzáad egy **párhuzamos
tömböt** (`codegen_program.asm` `local_offsets`), ugyanúgy indexelve,
mint a `local_table`-t — nem `symtab.inc`-módosítás.

---

## 5. Típusméretek és struct-elrendezés (`codegen_types.asm`)

| Típus | Méret | Előjeles? |
|---|---|---|
| `int8` / `uint8` / `bool` | 1 bájt | igen / nem / n/a |
| `int16` / `uint16` / `int` / `uint` | 2 bájt | igen / nem |
| `int32` / `uint32` | 4 bájt | igen / nem |
| `int64` / `uint64` | 8 bájt | igen / nem |
| pointer (bármely `AST_TY_POINTER`) | 8 bájt | n/a (cím) |
| tömb `T[N]` | `size(T) * N`, összefüggő | n/a |
| struct | mezőméretek packed összege, deklarációs sorrendben | n/a |

`type_size(type_node) -> bájt`, `is_signed_type(type_node) -> 1/0`,
`struct_size(struct_decl) -> bájt`, `field_offset(struct_decl, name) ->
bájt`, `field_type(struct_decl, name) -> típus` (utóbbi kettő a
mezőnevek szerinti lineáris kereséssel, ugyanaz az alak, csak más
visszatérési érték — ld. `sema_expr.asm`'s `.struct_field_scan` minta,
nem osztott kód).

`is_scalar_loadable_type(type_node) -> 1/0` — igaz, ha a típus tényleg
elfér egy 8 bájtos regiszterben (beépített bázistípus vagy pointer). A
`decl`ek **bármilyen** típust elfogadnak (a lokálisok sosem kelnek át
hívás-határon önmagukban), de ezt a szűkebb ellenőrzést a kódgenerátor
számos ponton lefuttatja, immár **döntésre**, nem **elutasításra**
(3. fázis óta — 2. fázisban ugyanezek a pontok még kizárólag
`codegen_fail`-lel reagáltak egy `false` eredményre):

- `gen_rvalue`'s `IDENT`/`INDEX`/`FIELD`/`UNARY(*)` load-útvonala, mielőtt
  a betöltött értéket `rax`-ba tenné — egy `false` itt továbbra is
  `codegen_fail` (`msg_composite_as_scalar`): egy összetett értéket
  sosem lehet közvetlenül skalárként kezelni, csak a mezőin/elemein
  keresztül, vagy egy teljes másolással.
- `gen_rvalue`'s `BINARY` ága (csak a bal operandusra — a jobb oldal
  garantáltan ugyanaz a típus, ld. `types_equal`) — ugyanígy elutasítva
  (ld. 10. fejezet: ez a checker egy tudatosan meg nem szüntetett
  megengedő rése, nem a 3. fázis tárgya).
- `gen_rvalue`'s `CALL` ága: mielőtt a hívott függvény visszatérési
  értékét `rax`-ba venné, ellenőrzi, hogy az skalár-e — ha nem,
  `codegen_fail`, mert `gen_rvalue` sosem adhat vissza összetett
  értéket (ld. 6.5 lent). Egy összetett-visszatérésű hívás **csak**
  `gen_lvalue` saját `CALL` ágán át érhető el.
- `gen_function` a paraméter-/visszatérési típus mentén dönt (ld. 6.8):
  skalár → a régi, változatlan másolási/visszatérési útvonal; összetett
  → az új, 3. fázisbeli útvonal (`emit_param_copy` összetett ága, illetve
  a rejtett output-pointer-rés). **Nincs többé elutasítás** ezen a
  ponton.
- `gen_user_call` szintén a hívott fél deklarált visszatérési típusa és
  minden egyes paramétere mentén dönt (skalár vagy összetett ág), nem
  utasít el semmit — ld. 6.5.

---

## 6. AST-csomópont → assembly, megvalósítási állapottal

### 6.1 Literálok, azonosító (megvalósítva)

`AST_EX_INT`/`AST_EX_BOOL`: `mov rax, <érték>`. `AST_EX_NULL`:
`mov rax, 0` (a gyakorlatban elérhetetlen egy jól tipizált, csak-skalár
programban, mivel pointer-kontextus nélkül sosem szerepelhetne érvényes
programban — pointerek ebben a fázisban nincsenek). `AST_EX_IDENT`:
`gen_lvalue` (`lea rbx, [rbp - offset]`), majd `emit_sized_load`.

### 6.2 Unáris (megvalósítva: mind)

| op | kódgenerálás |
|---|---|
| `-` | `gen_rvalue(operand)`; `neg rax` |
| `!` | `gen_rvalue(operand)`; `xor rax, 1` |
| `*` (deref) | rvalue: `gen_lvalue` (a pointer értéke *maga* a cél cím: `gen_rvalue(operand) -> rax`; `mov rbx, rax`), majd guardolt `emit_sized_load` — ugyanaz az útvonal, mint `IDENT`/`INDEX`/`FIELD` |
| `&` (address-of) | csak rvalue: `gen_lvalue(operand) -> rbx`; `mov rax, rbx`; eredmény típusa egy frissen szintetizált `AST_TY_POINTER` (`ast_alloc_node`, ugyanaz a minta, mint `sema_expr.asm`'s `.unary_addr`-je) |

### 6.3 Bináris (megvalósítva: mind)

Általános minta (a `&&`/`||` kivételével):

```nasm
    ; gen_rvalue(left)
    push    rax
    ; gen_rvalue(right)
    mov     rcx, rax        ; rcx = right
    pop     rax             ; rax = left
    ; kombinálás (op-specifikus) -- eredmény rax-ban
```

| Op-ok | Kombináló lépés |
|---|---|
| `+ - * & \| ^` | `add/sub/imul/and/or/xor rax, rcx` |
| `<< >>` | `shl rax, cl` mindig; `>>`: `sar` (előjeles) / `shr` (előjeltelen) |
| `/ %` | `cqo`+`idiv rcx` (előjeles) vagy `xor rdx,rdx`+`div rcx` (előjeltelen); `%` a `rdx`-et mozgatja `rax`-ba |
| `== != < > <= >=` | `cmp rax, rcx` + `setcc al` (`==`/`!=` előjelfüggetlen; `< > <= >=` `setl/setg/setle/setge` előjeles, `setb/seta/setbe/setae` előjeltelen) + `movzx rax, al` |
| `&& \|\|` | rövidzár, egyedi `.L<N>_false`/`.L<N>_true`/`.L<N>_end` címkékkel — ld. lent |

```nasm
; a && b
    ; gen_rvalue(a)
    cmp     rax, 0
    je      .L<N>_false
    ; gen_rvalue(b)
    jmp     .L<N>_end
.L<N>_false:
    mov     rax, 0
.L<N>_end:
```

### 6.4 `INDEX` / `FIELD` (megvalósítva)

Lvalue: `gen_lvalue(base) -> rbx`; `INDEX`: `push rbx; gen_rvalue(index);
imul rax, elem_size; pop rbx; add rbx, rax`. `FIELD`: `gen_lvalue(base)`
(mindig struct-típusú, `add rbx, field_offset(struct_decl, name)`.
Mindkettő tetszőleges mélységben összeköthető más lvalue-alakokkal
(`*arr[2]`, `*values.value.ptrs[3]`), mivel `gen_lvalue`/`gen_rvalue`
rekurzívan van definiálva a teljes kifejezés-nyelvtanon, nem alak
szerinti mintaillesztéssel — a mélység "ingyenes". Nincs futásidejű
`INDEX`-bounds-check (a "nincs rejtett futásidejű költség" elvvel
összhangban) — egy fordítási idejű, bare-literál-indexre szűkített
tartomány-ellenőrzés a szemantikai elemzőben már ezt megelőzően kiszűri
a konstans-index-túlcímzést (ld.
[postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
§7.6); egy valódi dinamikus index sosem kerül ellenőrzésre.

### 6.5 `CALL` (megvalósítva: `extern` fehérlista és felhasználói függvény, tetszőleges argumentum-/visszatérési típussal)

```nasm
    ; argN..arg1, jobbról balra, egyenként push-olva
.push_loop:
    ; gen_rvalue(arg_i); push rax
    ; -- extern (syscall) eset --
    pop     rdi                 ; ha arg_count >= 1
    pop     rsi                 ; ha >= 2
    pop     rdx                 ; ha >= 3
    pop     rcx                 ; ha >= 4
    mov     r10, rcx            ; syscall lenullázza rcx/r11-et, ezért r10
    pop     r8                  ; ha >= 5
    pop     r9                  ; ha >= 6
    mov     rax, <syscall szám>
    syscall
```

A syscall-számok (`sys_read`=0, `sys_write`=1, `sys_mmap`=9,
`sys_exit`=60) ugyanazok, mint amiket `runtime.asm` már használ,
keresztellenőrizve, nem újra kitalálva.

1. fázisban `sys_read`/`sys_write`/`sys_mmap` mindegyike legalább egy
`*uint8` (pointer) paramétert igényelt, ami akkor még nem volt
kódgenerálva — 2. fázistól kezdve mindhárom ténylegesen hívható
(`21_sys_write_real_buffer` fixture: valódi buffer, `&msg[0]`).

**Felhasználói függvényhívás** (`gen_user_call`, `codegen_expr.asm`) —
pontosan a fent leírt konvenció: jobbról balra kiértékelve és push-olva
(egy dummy padding-push **elsőként**, ha szükséges — ld. 2. fejezet a
padding-döntés 3. fázisbeli általánosításáról); `mov rdi, rsp; mov rsi,
N; [lea rdx, [rsp + N'], ha a visszatérési típus összetett]; call
pf_<name>; add rsp, <N', 16-ra kerekítve>`. Minden argumentum a hívott
fél **saját, deklarált** paramétertípusa (nem az argumentum-kifejezés
saját típusa) mentén dől el skalár/összetett ágra:

- **skalár/pointer**: változatlan, `gen_rvalue(arg) -> rax`; `push rax`.
- **összetett**: ld. 2. fejezet ("Összetett argumentum-materializáció")
  — vagy a forrás **saját** címe push-olva (lvalue-alak), vagy egy
  friss ideiglenes terület materializálva és annak címe push-olva
  (literál-alak).

A hívott függvény saját visszatérési típusa is a deklarált típus
mentén dől el (`gen_user_call` a `call` közvetlen előtt): `void`/skalár
→ változatlan; összetett → a rejtett `rdx` output-pointer bekötve (ld.
2. fejezet). Rekurzió (közvetlen vagy kölcsönös) semmi extrát nem
igényel: minden hívás a saját, friss `rsp`-nél kap frame-et, és a
`local_table`/`local_offsets` csak *generáláskor* (fordítási idő), sosem
futásidőben kerül felhasználásra — ez összetett paraméterrel/
visszatérési típussal rekurzáló függvényre is igaz (ld. `codegen_cases/
27_composite_recursion.ptl`).

**Miért nem kell `BINARY`-nak külön guard**: `gen_rvalue` maga **sosem**
ad vissza összetett (struct/tömb) típust — `.load_via_lvalue`/`.deref`
saját maguk guardolnak (`is_scalar_loadable_type`), `INT`/`BOOL`/`NULL`/
`neg`/`lnot`/`addr` mindig skalár/pointer a saját szabályuk szerint,
`.call` pedig a hívott függvény visszatérési típusát már guardolta,
mielőtt visszatérne (ld. 5. fejezet) — egy összetett-visszatérésű hívás
csak `gen_lvalue`-n át érhető el, sosem `gen_rvalue`-n. Ez az invariáns
indukcióval öröklődik: semmi, ami `gen_rvalue`-n átmegy, sosem lehet
összetett típusú, tehát `BINARY` operandusai (mindkét oldal `gen_rvalue`-n
át kerül kiértékelésre) sosem lehetnek azok.

**`gen_lvalue`'s `CALL` ága** (3. fázis, `codegen_expr.asm`) — az
egyetlen útvonal, amin egy összetett-visszatérésű hívás elérhető:
lefoglal egy friss területet a hívott fél visszatérési típusának
méretével (`sub rsp, <méret, 8-ra kerekítve>` — ez a terület, mielőtt
`gen_user_call` egyáltalán elkezdené kiértékelni az argumentumokat, már
megvan, tehát azok elhelyezkedése *alatta* van a stack-en, sosem zavarja
meg), meghívja `gen_user_call`-t (a rejtett `rdx` így ezt a területet
kapja), majd ennek a területnek a címét adja vissza saját eredményként
(target `rbx`). **Tudatosan nem szabadítja fel** ezt a területet — a
hívó (akárki is legyen: decl-init/assign másolás, egy skalár mező/elem
kiolvasása, vagy egy beágyazott, összetett argumentum materializálása)
kapja meg ezt a felelősséget egy harmadik, `gen_lvalue`-ból visszaadott
kimeneti értékkel (`r8` a fordító saját regiszterében, "cleanup size"):
`0`, ha nincs mit felszabadítani (létező lokális címe), vagy a
lefoglalt bájtszám, ha van — a `INDEX`/`FIELD` ágak ezt változatlanul
továbbadják, ha az ő saját báziscímük is egy ilyen hívásból ered
(`f().mező`, `f()[i]`). Enélkül a mechanizmus nélkül egy ismételten
hívott, összetett-visszatérésű függvény (pl. egy ciklusban, vagy egy
kifejezésben többször) korlátlanul "szivárogtatná" a stack-területet,
egészen a függvény epilógusáig — ez volt a tervezés során felfedezett,
és a `r8`/cleanup mechanizmussal lezárt valódi kockázat.

### 6.6 `STRUCT_LIT` / `ARRAY_LIT` (megvalósítva) + tömb broadcast-init + struct-/tömb-másolás

Új fájl: `codegen_composite.asm`. Egy harmadik kódgenerálási mód,
**egységesen** használva decl-init, egy-páros és több-páros szimultán
értékadás jobb oldalán is (nincs külön gyors-útvonal) — két függvény,
mindig együtt hívva:

- **`gen_init_push(node)`** (1. menet): a literált **előre**, deklaráció-/
  index-sorrendben járja be; minden **levél** (skalár/pointer) mező/elem
  esetén `gen_rvalue(levél) -> rax`; `push rax`. Egy beágyazott összetett
  mező/elem inline rekurzióval csatlakozik ugyanahhoz a lapos,
  előre-sorrendű push-sorozathoz — **egyetlen cím sem** kerül elő ebben a
  menetben, tisztán érték-kiszámítás, tehát minden levél tényleg a
  *utasítás-előtti* állapotot látja, függetlenül attól, melyik páros
  vagy pozíció része.
- A célcím **utolsóként**, a `gen_init_push` visszatérése **után**
  kerül kiszámításra és push-olásra (`gen_lvalue(lhs) -> rbx`; `push
  rbx`) — biztonságos, mert semmi ez után nem nyúl `rbx`-hez ennél a
  párosnál, és az, hogy *utólag* (nem előbb, mint a skalár eset) kerül
  kiszámításra, nem változtat azon, milyen előtte-állapotot lát, mivel
  ebben a menetben semmi nem *ír* még.
- **`gen_init_pop_store(node, elvárt_típus, offset)`** (2. menet, amikor
  ennek a párosnak a sora jön a párok saját fordított sorrendjében): előbb
  `pop rbx` (a cím, ami utoljára lett push-olva az 1. menetben, tehát
  legfelül van); majd ugyanazt a struktúrát **fordított** sorrendben
  bejárva, `offset` fordítási idejű aritmetikaként halmozódik a beágyazott
  rekurzión át (nincs külön stack-bejegyzés szintenként — minden a
  megtartott `rbx`-ről címzett); minden levélre (fordítva bejárva, LIFO
  pop-sorrendnek megfelelően): `pop rax`; tárolás egy új
  `emit_sized_store_rbx_plus(type, offset)`-tel (ugyanaz, mint
  `emit_sized_store`, csak `"[rbx + <offset>]"`-tal `"[rbx]"` helyett —
  mert egyetlen megtartott báziscím sok, különböző offszetű tárolást
  szolgál ki egy literálon belül).
- Mező-név → deklarált-mező megfeleltetés (melyik `field_init` melyik
  struct-mezőnek felel meg, és milyen sorrendben kell push/pop-olni) egy
  új `find_field_init` segéddel — ugyanaz az alak, mint `sema_expr.asm`'s
  `.struct_field_scan`-je, nem osztott kód.

**Struct-/tömb-érték egyszerű másolása** (`p2 := p1;`, ellenőrizve a
checker ellen — egy struct-típusú `IDENT` tökéletesen jó jobb oldal egy
azonos típusú célnak, ugyanaz a strukturális `types_equal`): egyenes
`rep movsb` memóriamásolás (`emit_rep_movsb_copy`, `rdi`=cél, `rsi`=forrás
már beállítva a hívó által, `cld` az irány-flag tisztázására).

**Tömb broadcast-init** (`mut arr: int32[5] := 7;` — a szemantikai
elemző 3. fázisának új szabálya tette elérhetővé, ld.
[postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
§A1/§8.2): a skalár kifejezés **egyszer** kiértékelve (`gen_rvalue ->
rax`), majd egy futásidejű, számlált ciklus (`gen_composite_broadcast`)
tárolja ugyanazt az egy értéket mind az `N` elem-résbe (`elem_type`
sized `mov [rbx], r12<b/w/d/->` + `add rbx, elem_size` + `dec rcx`
ciklus, egyedi `.L<N>_start`/`.L<N>_end` címkékkel). Egy **összetett**
broadcast-forrás (amikor az elemtípus maga struct/tömb) tudatosan
`codegen_fail`-lel elutasítva — ritka, ebben a fázisban nem
implementált eset.

### 6.7 Utasítások (megvalósítva: mind)

- **`AST_DECL_MUT`/`CONST`**: init nélkül nincs kiadás. Van init esetén
  négyfelé ágazik a deklarált típus és az init-kifejezés alakja szerint:
  - **skalár/pointer** (`is_scalar_loadable_type`): `gen_rvalue` majd
    `gen_named_local_addr` majd `emit_sized_store` — ebben a sorrendben
    biztonságos, mert egy egyszerű lokális cím-számítása sosem nyúl
    `rax`-hoz (változatlan az 1. fázis óta).
  - **összetett, init egy `STRUCT_LIT`/`ARRAY_LIT`**: `gen_init_push`
    majd `gen_named_local_addr` majd `gen_init_pop_store` (ld. 6.6) —
    egyetlen írás, nincs szimultaneitási kockázat, ezért itt nem kell a
    cím push/pop-os védelme (szemben a több-páros `ASSIGN`-nal alább).
  - **összetett, init egy ugyanolyan típusú lvalue** (`IDENT`/`INDEX`/
    `FIELD`/`UNARY(*)`/`CALL` — utóbbi 3. fázis óta, ld. 6.5, és
    `gen_lvalue`+`types_equal` a deklarált típus ellen egyezést ad):
    struct-/tömb-másolás (ld. 6.6); ha a forrás egy `CALL` volt,
    `gen_lvalue` saját `r8` (cleanup) kimenete a másolás **után**
    felszabadításra kerül (`add rsp, r8`, ha nem nulla — ld. 6.5).
  - **összetett, init bármi más** (garantáltan skalár/pointer, ld. 6.5
    indukciós érv): tömb broadcast-init (ld. 6.6) — csak érvényes, ha a
    deklarált típus tömb (a checker sosem enged struct-broadcastot).
- **`AST_STMT_ASSIGN`**: Dijkstra/Hoare szimultán szemantika, **két
  menetben**, **páronként négyféle alakban** (skalár, összetett-literál,
  összetett-másolás, tömb-broadcast — ugyanaz a négy eset, mint fent, csak
  a két-menetes push/pop-sémára szabva). Minden páros saját (alak, típus)
  párja egy 2-qword-per-páros scratch-tömbben van eltárolva a Stage 0
  fordító **saját natív** stack-jén — teljesen elkülönítve attól a
  "push"/"pop" **szövegtől**, amit ez a rutin a *cél* program stack-jére
  ír ki:
  - **skalár**: 1. menet `gen_lvalue(lhs)` (push cím), `gen_rvalue(rhs)`
    (push érték) — cím **előbb**. 2. menet: pop érték, pop cím, tárolás.
  - **összetett-literál**: 1. menet `gen_init_push(rhs)` (levelek
    push-olva, előre sorrendben), **majd** `gen_lvalue(lhs)` (cím
    push-olva **utoljára**) — fordított sorrend a skalár esethez képest,
    ld. 6.6-nál a részletes indoklást. 2. menet: pop cím,
    `gen_init_pop_store`.
  - **összetett-másolás**: 1. menet `gen_lvalue(lhs)` (push cél-cím),
    `gen_lvalue(rhs)` (push forrás-cím, forrásalak `IDENT`/`INDEX`/
    `FIELD`/`UNARY(*)`/`CALL` — utóbbi 3. fázis óta) — mindkettő tiszta
    olvasás, sorrend-független. 2. menet: pop forrás → `rsi`, pop cél →
    `rdi`, `emit_rep_movsb_copy`, majd ha a forrás `gen_lvalue`-ja
    nemnulla `r8` (cleanup) kimenettel tért vissza, ennek felszabadítása
    (`add rsp, r8`) — a páros saját scratch-bejegyzése emiatt 3. fázistól
    3 qword/páros (alak, bal oldali típus, cleanup), nem 2.
  - **tömb-broadcast**: ugyanaz a push-alak, mint a skalár eset (cím,
    érték), de a 2. menetben `gen_composite_broadcast` a sima
    `emit_sized_store` helyett.
  
  A négy alak közötti döntés (páronként) tisztán strukturális — a bal
  oldal deklarált típusát és a jobb oldal AST-alakját nézi, nincs hozzá
  szükség kiértékelésre/emisszióra, tehát a döntés a 2. menetben (ahol a
  kiértékelés nélkül kell újra "tudni", melyik alak volt) is
  reprodukálható anélkül, hogy bármit újra kiadna.
- **`AST_STMT_IF`/`AST_STMT_WHILE`**: egyedi `.L<N>_else`/`.L<N>_end`
  illetve `.L<N>_start`/`.L<N>_end` címkékkel, `cmp rax, 0`+`je`
  vezérléssel.
- **`AST_STMT_RETURN`**: az enclosing függvény deklarált visszatérési
  típusa dönt (`cur_func_return_type`/`cur_func_out_ptr_offset`, két
  modul-szintű globális, amit `gen_function` állít be egyszer, mielőtt a
  törzs kódgenerálása elkezdődne — ld. 6.8; nem paraméterként fűzve át
  `gen_func_block`/`gen_block`/`gen_stmt`-en, mert `gen_function` sosem
  reentráns, tehát mindig pontosan egy érvényes érték él egyszerre):
  - **skalár/`void`**: változatlan — kifejezéssel `gen_rvalue` (az érték
    `rax`-ban, az ABI visszatérési regiszter), `jmp .epilogue`;
    kifejezés nélkül `jmp .epilogue` közvetlenül.
  - **összetett** (3. fázis): a célcím a hívó által mentett rejtett
    résből töltődik be (`[rbp - cur_func_out_ptr_offset]`, ld. 6.8), és
    az érték oda íródik közvetlenül — struct-/tömb-literál esetén
    `gen_init_push`/`gen_init_pop_store` (ld. 6.6, a célcím a levelek
    push-olása **után** kerül kiszámításra, ugyanúgy, ahogy decl-init/
    assign esetén); egyébként (lvalue-alak, `CALL`-t is beleértve)
    `gen_lvalue(kif) -> rbx` + `emit_rep_movsb_copy`. A forrás esetleges
    `r8` (cleanup) kimenete itt **szándékosan nincs felszabadítva** — a
    közvetlenül utána következő `.epilogue` (`mov rsp, rbp`) úgyis
    eldobja a teljes frame-et, cleanup nélkül is.
  Minden függvénynek pontosan egy epilógus címkéje van.
- **`AST_STMT_EXPR`**: `gen_rvalue`, az eredmény eldobva.

### 6.8 Felső szint (megvalósítva: `AST_FUNCTION`+`AST_PROGRAM`; `AST_EXTERN_DECL`/`AST_STRUCT_DECL` nem adnak ki semmit)

- **`AST_FUNCTION`**: `pf_<name>` címke (a függvény saját nevéből
  dinamikusan összerakva, nem csak `main`-re hardkódolva). 3. fázis óta
  a visszatérési típus **és** minden paraméter típusa tetszőleges lehet
  (nincs többé `codegen_fail`-lel elutasított eset itt):
  - **skalár/pointer paraméter**: változatlan sized-load+store másolás a
    bejövő résből (`emit_param_copy` skalár ága).
  - **összetett paraméter**: a bejövő rés egy **pointert** tartalmaz —
    `emit_param_copy` összetett ága `rep movsb`-vel másolja a mutatott
    memóriából a saját lokális résébe (a bejövő argumentum-blokk saját
    báziscíme, target `rdi`, ideiglenesen elmentve/visszaállítva egy
    `push`/`pop` párral, amíg `rdi`/`rsi` a `rep movsb` cél/forrás
    szerepét játssza).
  - **`void`/skalár visszatérési típus**: változatlan.
  - **összetett visszatérési típus**: a prológus egy extra, mindig
    8 bájtos rejtett rést foglal (a látható lokálisok mérete után
    közvetlenül, a `sub rsp, ...` teljes mérete emiatt újra 16-ra
    kerekítve), és ide menti el a bejövő `rdx`-et (a hívó output-
    pointere, ld. 2. fejezet) — közvetlenül a prológus után, mielőtt a
    törzs bármi mást tehetne vele. Ez a rés címe (`cur_func_out_ptr_offset`)
    és a deklarált visszatérési típus (`cur_func_return_type`) két
    modul-szintű globálisban kerül átadásra `gen_stmt`'s `.return_stmt`
    ágának (ld. 6.7) — **nem** a `local_table`/`compute_local_offsets`
    részeként (az tisztán felhasználó-deklarálta lokálisok/paraméterek
    dolga marad).
  Prológus a saját lokális táblájából méretezve; törzs `gen_func_block`-on
  át; egy epilógus. Tetszőleges számú `AST_FUNCTION` engedélyezett,
  **deklarációs sorrendben** generálva (a címke-hivatkozások egymás közt
  fordítási időben, NASM szinten oldódnak fel, függetlenül a kiadási
  sorrendtől — a kölcsönös rekurzió emiatt nem igényel külön kezelést).
  Pontosan egynek kell `main` nevűnek lennie (a `_start` belépési pont
  ezt hívja) — ha nincs, `codegen error`. `main`-nek **nulla**
  paraméterrel kell rendelkeznie (a `_start` sosem állítja be
  `rdi`/`rsi`-t a `call pf_main` előtt) — ezt `gen_program` explicit
  ellenőrzi, `codegen error`-ral, ha sérül.
- **Belépési pont / `AST_PROGRAM`**:

```nasm
BITS 64
section .text
global _start

_start:
    call    pf_main
    mov     rdi, rax        ; main visszatérési értéke -> kilépőkód
                             ; (mov rdi, 0, ha main : void)
    mov     rax, 60         ; sys_exit
    syscall

pf_main:
    ...
```

---

## 7. Új bináris: `build/codegen`

Negyedik menet, ugyanazzal a rétegződési fegyelemmel, mint
`lexer → parser → checker`: az egész meglévő lexer/parser verem
(változatlan), plusz a szemantikai ellenőrző `symtab.asm`/
`sema_types.asm`-je (közvetlenül újrahasznosítva — `build_global_tables`/
`build_local_table`/típus-felbontás céljából), de **nem**
`sema_expr.asm`/`sema_stmt.asm` *ellenőrző* logikája (a kódgenerátor csak
a `check_program` által épített táblákat akarja, nem az igen/nem
verdiktjét — újra fut `parse_program` + `check_program` a `build/checker`
mintájára, majd `gen_program`).

**Fázis-hatókör kikényszerítés** (2. fázistól): nincs pontos "egy
függvény" megkötés többé — `AST_STRUCT_DECL` és `AST_EXTERN_DECL` egyaránt
csendben kimarad a kódgenerálásból (nem hiba), tetszőleges számú
`AST_FUNCTION` megengedett. Az egyetlen kikényszerített dolog: pontosan
egy `main` nevű, nulla-paraméteres függvény kell legyen jelen
(`gen_program`). 3. fázis óta egy függvény visszatérési típusára/
paramétereire **nincs** többé megszorítás (ld. 6.8) — a `codegen_fail`
felület a 10. fejezetben leírt két, jóval szűkebb esetre korlátozódik.

Fájlok: `codegen_types.asm`, `codegen_expr.asm`, `codegen_stmt.asm`,
`codegen_program.asm`, `codegen_composite.asm` (2. fázistól, ld. 6.6),
`codegen_main.asm`.

---

## 8. Tesztelés — új típusú ellenőrzés

Minden korábbi menet fixture-je **statikus szöveget** hasonlított össze.
A kódgenerátor fixture-jeinek erősebbet kell bizonyítaniuk: hogy a
**generált assembly, lefordítva, linkelve és ténylegesen lefuttatva,
helyesen viselkedik**. `Stage0/scripts/run_codegen_tests.sh`: minden
`tests/codegen_cases/*.ptl`-re `build/codegen` → `.asm` szöveg → `nasm
-f elf64` → `ld -static -no-pie` → **a kapott bináris lefuttatása** →
a valódi kilépőkód (és stdout, ha van `.expected.stdout`)
összehasonlítása a becsomagolt `.expected.exit`/`.expected.stdout`
párral.

A `tests/codegen_cases/` alatti 29 fixture (10 az 1., 12 a 2., 7 a 3.
fázisból) lefedi: aritmetikát, összehasonlításokat (előjeles és
előjeltelen), `if`/`else`-t, `while`-t, `&&`/`||` rövidzárat
(megfigyelhető módon — egy nullával osztás, ami csak akkor futna le, ha
rosszul lenne kiértékelve), egy explicit `sys_exit`-hívást, unáris/
bitwise operátorokat, osztást/maradékot, szimultán értékadást,
struct-mező olvasás/írás, tömb-index olvasás/írás, pointer írás
dereferálson át, struct-/tömb-literál decl-init (beágyazott
tömb-struct-tömb literállal is), struct-érték másolás, **egy több-páros
szimultán értékadás, amiben egy struct-literál páros mezőkifejezése egy
másik páros által UGYANABBAN az utasításban módosított változót olvas**
(a legfontosabb 2. fázisbeli korrektségi teszt — csak akkor ad helyes
eredményt, ha a literál mezője valóban az *utasítás-előtti* értéket
látta), két-függvényes program, rekurzió (faktoriális), valódi
`sys_write` egy tényleges bufferrel, tömb broadcast-init.

**3. fázis fixture-jei**: struct-argumentum érték szerint (a hívott fél
a saját másolatát módosítja, a hívó eredeti példánya bizonyítottan
változatlan marad utána — `23_composite_param`), ugyanez tömb-
argumentumra (`25_composite_array_param`), struct visszatérési érték
decl-initben felhasználva (`24_composite_return`), láncolt/beágyazott
hívás: `f().mező` közvetlen olvasása (nincs köztes névvel ellátott
változó) **és** `g(f())` (egy összetett-visszatérésű hívás eredménye
közvetlenül egy másik összetett paraméterbe táplálva) egyazon
fixture-ben (`26_composite_chained_and_nested_call`), rekurzió összetett
paraméterrel **és** visszatérési típussal egyszerre
(`27_composite_recursion` — bizonyítja, hogy az ideiglenes-terület-
foglalás/felszabadítás-történet ismételt, beágyazott hívások alatt is
helyes marad), egy packed, nem-8-tal-osztható méretű struct (két
`int8` mező) mind argumentumként, mind visszatérési értékként
(`28_composite_packed_odd_size` — az általánosított igazítás-kerekítés
konkrét próbája), és egy `codegen_fail`-t váró fixture a tudatosan
hatókörön kívül hagyott esetre (`29_composite_call_as_literal_field_
deferred`, ld. 10. fejezet) — ez utóbbi az `.expected.codegen_exit`
opcionális fixture-konvenciót használja (ld. `run_codegen_tests.sh`).

---

## 9. Kilépőkódok — kiegészítés

A meglévő táblázat (ld. `Stage0/README.md`) egy új sorral egészül ki:

| Kód | Jelentés |
|---|---|
| `4` | Kódgenerátor-hiba (`build/codegen` only). A program **szemantikailag érvényes**, de a kért konstrukció ezen a fázison kívül esik (struct/tömb/pointer, felhasználói függvényhívás, több függvényes program, stb.) — diagnosztika stderr-re, `codegen error:` prefixszel. Nem összekeverendő a 3-as (szemantikai hiba) kóddal: a 4-es soha nem jelent érvénytelen Postulate-forrást, csak a fordító jelenlegi hatókörén kívül esőt. |

---

## 10. Ismert, ebben a fázisban tudatosan meg nem valósított tételek

Az 1. fázis listája a 2. fázissal gyakorlatilag lefedésre került, a 3.
fázis pedig lezárta a hívás-határ kérdését (struct/tömb *érték* immár
argumentumként **és** visszatérési értékként is átmehet egy felhasználói
függvényhívás határán, ld. 2. és 6.5-6.8. fejezet). Két, jóval szűkebb
tétel maradt nyitva:

- **Egy összetett-visszatérésű `CALL`, mint egy `STRUCT_LIT`/`ARRAY_LIT`
  mező-/elem-értéke.** `gen_init_push` (ld. 6.6) jelenlegi kétkategóriás
  levél-modellje ("skalár érték, push-olva" vagy "beágyazott literál,
  rekurzálva") nem számol egy harmadik, "`CALL`, cím kell neki, amibe
  írhat" kategóriával — az 1. menet előre haladó, csak-push-oló bejárása
  még nem rendelkezik ehhez egy céllal. Konkrét, jelenleg el nem
  fogadott példa (`codegen_fail`-lel tisztán elutasítva, nem rossz kódot
  generálva — a `gen_rvalue` `CALL`-ágának meglévő guardján keresztül,
  ld. 6.5, mert `gen_init_push` a `CALL`-levelet egyszerű skalár
  leaf-ként próbálja `gen_rvalue`-val kiértékelni):

  ```postulate
  struct Point { x: int32; y: int32; }
  struct Line { start: Point; end: Point; }

  function make_point(x: int32, y: int32) : Point {
    return Point { x := x, y := y };
  }

  function main() : int32 {
    // end mezőjének inicializálója egy beágyazott STRUCT_LIT -- ez már
    // megy (2. fázis óta). start mezőjének inicializálója egy
    // összetett-visszatérésű CALL -- ez NEM megy még: gen_init_push-nak
    // nincs `CALL`-levél esete. codegen_fail egy tiszta diagnosztikával,
    // nem rossz kód generálásával.
    mut l: Line := Line { start := make_point(1, 2), end := Point { x := 3, y := 4 } };
    return l.start.x;
  }
  ```

  Kerülőút, ami ma is működik: a hívás eredményének előzetes,
  **névvel ellátott** helyi változóba mentése — `mut s: Point :=
  make_point(1, 2); mut l: Line := Line { start := s, end := ... };` —
  mivel egy sima `IDENT` mező-inicializáló érték már működik (2. fázis
  óta), és `s` saját decl-initje `make_point(1, 2)`-ből pontosan a 3.
  fázis alap-esete (ld. 6.5/6.7). Csak a *közvetlen, névtelen* hívás
  mint mező-érték írásmódja van elhalasztva. (`tests/codegen_cases/
  29_composite_call_as_literal_field_deferred.ptl` ezt a pontos, elutasított
  esetet gyakorolja.)
- **Összetett típusú `BINARY` operátorok** (`==`, `<`, stb. struct/tömb
  operandusokon) — ez egy már **meglévő**, a checker `types_equal`-jából
  fakadó megengedő rés (`sema_expr.asm`'s `.binary_compare` nem korlátozza
  az operandus-kategóriát), amit ez a fázis nem hozott létre, és nem is
  köteles lezárni — a kódgenerátor oldalán ez már ma is tisztán zárva
  van: `gen_rvalue` sosem ad vissza összetett típust (ld. 6.5 indukciós
  érve), tehát egy összetett `BINARY` operandus `is_scalar_loadable_type`
  guardon bukik el, mielőtt bármi rosszul sülne el.
- Összetett (struct/tömb elemtípusú) tömb-broadcast-forrás (ld. 6.6) —
  ritka, tudatosan `codegen_fail`-lel elutasított eset, nem a
  hívás-határ-kérdés része, 2. fázis óta változatlan.

Ezek egy külön, még meg nem tervezett jövőbeli fázisra várnak; ekkor ez a
dokumentum bővül, nem cserélődik le.
