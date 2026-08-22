# Postulate Stage 0 — Kódgenerátor technikai specifikáció

> Ez a dokumentum a Stage 0 bootstrap fordító **kódgenerátorának**
> technikai specifikációja — **1. fázis**: egyfüggvényes (`main`),
> csak skalár típusokat kezelő, teljes kifejezés-/`if`/`while`-kódgenerálás,
> a fehérlistázott `extern` syscall-okra való hívással bezárólag. A cél
> egy **negyedik, önálló `build/codegen` bináris** — a
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
- **Ennek a fázisnak a hatóköre** — a legegyszerűbb végpontok-közti szelet,
  ami az egész új csővezetéket bizonyítja (`.ptl` → ellenőrzött AST →
  `.asm` szöveg → `nasm`+`ld` → valódi Linux bináris → **lefuttatva
  ellenőrizve**), mielőtt a memóriaelrendezés bonyolultsága hozzáadódna:
  - **Egy függvény** (kötelezően `main` néven).
  - **Csak skalár típusok** (`int8`..`int64`/`uint8`..`uint64`/`bool`) —
    struct/tömb/pointer **nem** ebben a fázisban.
  - Teljes kifejezés- és `if`/`while`-kódgenerálás.
  - Hívás **csak** fehérlistázott `extern` függvényre (syscall shim) —
    felhasználói függvények egymás közti hívása (és így rekurzió is)
    **még nem** ebben a fázisban.
  - Minden ezen túli konstrukció (struct/tömb/pointer, `INDEX`/`FIELD`,
    `STRUCT_LIT`/`ARRAY_LIT`, felhasználói függvényhívás, több függvényes
    program) **lentebb dokumentálva van**, de **nincs implementálva** —
    ezeket a `codegen error: ...` diagnosztika (4-es kilépőkód, ld. 9.
    fejezet) jelzi tisztán, ahelyett hogy rossz kódot generálna.

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
  `[block_ptr + (i-1)*8]`).
- A hívott fél pontosan **két** dolgot kap, **`rdi`**/**`rsi`**-ben:
  egy pointert az első argumentumra (`rdi`) és az argumentumok számát
  (`rsi`) — mindig ugyanez a két regiszter, függetlenül az aktuális
  argumentumszámtól.
- **Visszatérési érték**: skalár/pointer típusok → `rax` (nincs
  megváltoztatva). `void` → `rax` nincs felhasználva. **Struct
  visszatérési típusok** (elhalasztva ebben a fázisban, de a válasz már
  most eldöntött): a hívó egy harmadik, rejtett argumentumot ad át —
  egy pointert oda, ahova az eredményt írni kell (`rdx`, amit ez a
  konvenció egyébként nem használ) — a hívott fél ezen a pointeren
  keresztül írja az eredményt, `rax` helyett.
- A hívó takarít a hívás után (`add rsp, N*8`, `N` fordítási időben
  ismert hívási helyenként — előtte 16-ra kerekítve, ld. 4. fejezet).

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
bájt` — mind implementálva, akkor is, ha `field_offset`/a struct-ág a
`type_size`-ban ebben a fázisban nem érhető el (semmi nem generál
struct-típusú kifejezést) — a primitívek teljesek, a spec dokumentálja
őket előre a következő fázishoz.

`check_supported_scalar_type(type_node)` — **ez a fázis-hatókör
kikényszerítésének helye**: `codegen error`-ral leáll, ha a típus nem
egy beépített `int8`..`uint64`/`bool` bázistípus (struct-név hivatkozás,
`AST_TY_POINTER`, `AST_TY_ARRAY` mind elutasítva). Minden `decl` és
minden paraméter típusán lefut, mielőtt a kódgenerátor bármit kiadna rá.

---

## 6. AST-csomópont → assembly, megvalósítási állapottal

### 6.1 Literálok, azonosító (megvalósítva)

`AST_EX_INT`/`AST_EX_BOOL`: `mov rax, <érték>`. `AST_EX_NULL`:
`mov rax, 0` (a gyakorlatban elérhetetlen egy jól tipizált, csak-skalár
programban, mivel pointer-kontextus nélkül sosem szerepelhetne érvényes
programban — pointerek ebben a fázisban nincsenek). `AST_EX_IDENT`:
`gen_lvalue` (`lea rbx, [rbp - offset]`), majd `emit_sized_load`.

### 6.2 Unáris (megvalósítva: `-`, `!`; elhalasztva: `*`, `&`)

| op | kódgenerálás |
|---|---|
| `-` | `gen_rvalue(operand)`; `neg rax` |
| `!` | `gen_rvalue(operand)`; `xor rax, 1` |
| `*` (deref) | **elhalasztva** — pointer típus nem ebben a fázisban |
| `&` (address-of) | **elhalasztva** — ua. |

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

### 6.4 `INDEX` / `FIELD` (dokumentálva, elhalasztva)

Lvalue: `gen_lvalue(base) -> rbx`; `INDEX`: `push rbx; gen_rvalue(index);
imul rax, elem_size; pop rbx; add rbx, rax`. `FIELD`: `add rbx,
field_offset(...)`. Mindkettő pointer/tömb/struct típust igényel — ebben
a fázisban elérhetetlen, `codegen_fail`-lel jelezve, ha mégis előfordulna.

### 6.5 `CALL` (megvalósítva: `extern` fehérlista; elhalasztva: felhasználói függvény)

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

**Fontos hatóköri korlát**: `sys_read`/`sys_write`/`sys_mmap` mindegyike
legalább egy `*uint8` (pointer) paramétert igényel — mivel a pointer
típusok ebben a fázisban nincsenek kódgenerálva, ezek a syscall-ok a
gyakorlatban **nem hívhatók** egy Phase 1-es programból (a típusellenőrző
elutasítana bármilyen skalár értéket, amit pointer helyett próbálnánk
átadni). Egyedül **`sys_exit(code: int64)`** hívható ténylegesen ebben a
fázisban — ez elég a syscall-shim mechanizmus (argumentum-shuffling,
`syscall` kiadása) végponttól végpontig való bizonyításához, a
3/6-argumentumos esetek bizonyítása a pointer-kódgenerálás
implementációjára vár.

Felhasználói függvényhívás (`call pf_<name>`, `mov rdi,rsp; mov rsi,N`)
**dokumentálva**, de **elhalasztva** — több függvényes program
ebben a fázisban `codegen error`-t vált ki (`gen_program`, ld. 7.
fejezet).

### 6.6 `STRUCT_LIT` / `ARRAY_LIT` (dokumentálva, elhalasztva)

Egy harmadik kódgenerálási mód, `gen_init(target_address, node)` —
sosem szabadon lebegő rvalue, mindig egy már ismert cél-cím kitöltése.
`STRUCT_LIT`: mezőnként `target_base + field_offset(...)`. `ARRAY_LIT`:
elemenként `target_base + i * elem_size` (a fő spec §4 stratégiája
szerint: `arr[0] := e0; arr[1] := e1; ...`).

### 6.7 Utasítások (megvalósítva: mind)

- **`AST_DECL_MUT`/`CONST`**: `check_supported_scalar_type`; init nélkül
  nincs kiadás; van init esetén `gen_rvalue` majd `gen_named_local_addr`
  majd `emit_sized_store` — ebben a sorrendben biztonságos, mert egy
  egyszerű lokális cím-számítása sosem nyúl `rax`-hoz.
- **`AST_STMT_ASSIGN`**: Dijkstra/Hoare szimultán szemantika, **két
  menetben**: 1. menet minden párra `gen_lvalue(lhs)` (push `rbx`), majd
  `gen_rvalue(rhs)` (push `rax`) — a cím **és** az érték is push-olva,
  mert a cím maga is a *előző* állapottól függhet; 2. menet fordított
  sorrendben pop-olva és tárolva. Az egyes párok cél-típusát (a
  `emit_sized_store` méretezéséhez) a Stage 0 fordító **saját natív**
  stack-jén tárolt scratch-tömb őrzi meg — teljesen elkülönítve attól a
  "push"/"pop" **szövegtől**, amit ez a rutin a *cél* program stack-jére
  ír ki.
- **`AST_STMT_IF`/`AST_STMT_WHILE`**: egyedi `.L<N>_else`/`.L<N>_end`
  illetve `.L<N>_start`/`.L<N>_end` címkékkel, `cmp rax, 0`+`je`
  vezérléssel.
- **`AST_STMT_RETURN`**: kifejezéssel: `gen_rvalue` (az érték már
  `rax`-ban van, az ABI visszatérési regiszter — nincs extra mozgatás),
  `jmp .epilogue`. Kifejezés nélkül: `jmp .epilogue` közvetlenül. Minden
  függvénynek pontosan egy epilógus címkéje van.
- **`AST_STMT_EXPR`**: `gen_rvalue`, az eredmény eldobva.

### 6.8 Felső szint (megvalósítva: `AST_FUNCTION`+`AST_PROGRAM`; `AST_EXTERN_DECL`/`AST_STRUCT_DECL` nem adnak ki semmit)

- **`AST_FUNCTION`**: `pf_<name>` címke; prológus a saját lokális
  táblájából méretezve; törzs `gen_func_block`-on át; egy epilógus.
  Ebben a fázisban pontosan egy, `main` nevű függvény várt — ha nincs,
  ha kettő van, vagy ha az egyetlen nem `main`, `codegen error`.
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

**Fázis-hatókör kikényszerítés** (`codegen_program.asm` `gen_program`):
`AST_STRUCT_DECL` jelenléte, egynél több `AST_FUNCTION`, vagy az egyetlen
függvény "main"-től eltérő neve mind `codegen error`-t vált ki, mielőtt
bármi kiadásra kerülne.

Új fájlok: `codegen_types.asm`, `codegen_expr.asm`, `codegen_stmt.asm`,
`codegen_program.asm`, `codegen_main.asm`.

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

A `tests/codegen_cases/` alatti 10 fixture lefedi: aritmetikát,
összehasonlításokat (előjeles és előjeltelen), `if`/`else`-t, `while`-t,
`&&`/`||` rövidzárat (megfigyelhető módon — egy nullával osztás, ami
csak akkor futna le, ha rosszul lenne kiértékelve), egy explicit
`sys_exit`-hívást, unáris/bitwise operátorokat, osztást/maradékot, és
szimultán értékadást.

---

## 9. Kilépőkódok — kiegészítés

A meglévő táblázat (ld. `Stage0/README.md`) egy új sorral egészül ki:

| Kód | Jelentés |
|---|---|
| `4` | Kódgenerátor-hiba (`build/codegen` only). A program **szemantikailag érvényes**, de a kért konstrukció ezen a fázison kívül esik (struct/tömb/pointer, felhasználói függvényhívás, több függvényes program, stb.) — diagnosztika stderr-re, `codegen error:` prefixszel. Nem összekeverendő a 3-as (szemantikai hiba) kóddal: a 4-es soha nem jelent érvénytelen Postulate-forrást, csak a fordító jelenlegi hatókörén kívül esőt. |

---

## 10. Ismert, ebben a fázisban tudatosan meg nem valósított tételek

- Struct/tömb/pointer típusú deklarációk és kifejezések (`INDEX`,
  `FIELD`, `UNARY(*)`, `UNARY(&)`, `STRUCT_LIT`, `ARRAY_LIT`,
  `gen_init`, tömb broadcast-init ciklus).
- Felhasználói függvények egymás közti hívása (és így rekurzió) — a
  hívási konvenció maga (2. fejezet) már teljesen dokumentált és
  eldöntött, csak a kódgenerálás maga hiányzik.
- Struct visszatérési típus (rejtett `rdx` output-pointer konvenció
  dokumentálva, ld. 2. fejezet, de nincs bekötve).
- Több függvényes programok.
- `sys_read`/`sys_write`/`sys_mmap` ténylegesen kipróbálva (a pointer-
  paraméterük miatt ez a pointer-kódgenerálásra vár, ld. 6.5).

Ezek mind a struct/tömb/pointer-kódgenerálás következő fázisára várnak;
ekkor ez a dokumentum bővül, nem cserélődik le.
