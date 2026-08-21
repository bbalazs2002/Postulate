# Postulate — Stage 0 nyelvi specifikáció

> Ez a dokumentum minden információt tartalmaz, ami a **Postulate** nyelv Stage 0
> bootstrap fordítójának elkészítéséhez szükséges. Célja, hogy egy másik
> munkamenetben is folytatható legyen a fejlesztés, előzmények nélkül is.

---

## 1. Projekt kontextus

A Postulate egy **saját tervezésű, C-szerű programozási nyelv**, amelynek célja egy
saját, moduláris, multi-architektúrás hobbi operációs rendszer megírása. A nyelv fő
tervezési célja **nem** a maximális kifejezőerő vagy kényelem, hanem hogy:

1. Alkalmas legyen **matematikai pontosságú, specifikáció szintű helyesség-bizonyításra**
   (Hoare-logika, ELTE IK "Bevezetés a programozáshoz" / Fóthi Ákos-féle relációs
   modell alapján — állapottér, paramétertér, elő-/utófeltétel, leggyengébb előfeltétel).
2. Szintaxisában is tükrözze ezt a formális, pszeudokód-szerű gondolkodásmódot.
3. Imperatív **és** funkcionális stílusú használatra is alkalmas legyen.
4. Kernel-fejlesztésre (rendszerprogramozásra) legyen alkalmas: nincs GC, nincs
   rejtett futásidejű overhead, explicit memóriakezelés.

### Névválasztás

A nyelv neve **Postulate**. Elutasított jelöltek és okuk:
- `N` — foglalt (N-lang, ALGOL N)
- `Nerd` — foglalt, aktív, friss projekt (LLM-natív nyelv, nerd-lang.org)
- `Axiom` — foglalt (ismert számítógépes algebra rendszer)
- `QED` — foglalt (több projekt is, egyikük pont formális verifikáció témában)
- `Certus` — részben foglalt (2025-ös publikáció, assurance-case DSL)
- `Verus` — foglalt (jelentős, aktív Rust-verifikációs eszköz)
- `Praecis` — szabad volt, de fonetikailag közel áll a "Praxis" névhez (SPARK Ada
  előd cég neve), ezért mellőzve

A `Postulate` szabad, jelentése (posztulátum = bizonyítás nélkül elfogadott,
alapul szolgáló állítás) illeszkedik a verifikációs célhoz. Bónusz: hasonlít a
magyar "pusztulat" szóra (önironikus utalás a nyelv szigorúságára/nehézségére).

### Fájlkiterjesztés

**`.ptl`** — enyhe, de elhanyagolható ütközés van: IBM Rational Rose "Petal" UML
fájlformátum (inaktív eszköz), és a Python Quixote sablonnyelv (elavult). Egyik sem
aktív programozási nyelv, a gyakorlati kockázat alacsonynak ítélve elfogadva.

---

## 2. Bootstrap terv (nagy kép)

```
Stage 0 (assembly, x86_64, Linux host)
   │  fordítja a Stage 1 forráskódját
   ▼
Stage 1 (Postulate nyelven írva, LLVM IR célkódot generál)
   │  self-hosting: Stage 1 lefordítja saját magát
   ▼
Self-hosting elérve — Stage 0 ("bootstrap mag") ezután történeti/eldobható
```

- **Stage 0 célja kizárólag annyi**, hogy a Stage 1 fordítót (ami már magán a
  Postulate nyelven van írva) le tudja fordítani. Nem kell a teljes nyelvet
  támogatnia — csak egy minimális, jól körülhatárolt részhalmazt (ez a jelen
  dokumentum tárgya).
- **Stage 1-től kezdve** LLVM IR-t generál a fordító, kihasználva az LLVM kész,
  kiforrott backend-jeit minden célarchitektúrához (x86_64, ARM, RISC-V stb.) —
  így nem kell saját codegent írni minden architektúrához.
- **Host környezet:** a fejlesztő gépén Windows 11 x64 fut, de a Stage 0/Stage 1
  fordítók **Linux x86_64 hoszton** futnak (Docker-en keresztül), hogy megegyezzen
  a GitHub Actions CI (ubuntu-latest) syscall-környezetével. A Stage 0 assembly
  közvetlenül a **Linux x86_64 syscall ABI-t** (System V AMD64 calling convention)
  éri el — nincs libc, nincs dinamikus linkelés, statikus, syscall-alapú bináris.
- Stage 0/Stage 1 **a fejlesztői (host) gépen fut**, nem a majdani saját OS-en —
  az még nem létezik, amikor a fordítót futtatod. Ezért a Stage 0-nak saját
  I/O-t és memóriafoglalást (`mmap`, `read`, `write`, `exit` syscall-okon
  keresztül) kell biztosítania, libc nélkül.

---

## 3. Stage 0 — mit tartalmaz és mit nem

### Mit tartalmaz (indoklással)

A Stage 0 pontosan annyit tartalmaz, amennyi egy **lexer + rekurzív leszállásos
parser + AST-építés + szöveges LLVM IR-kiírás** megírásához szükséges a Stage 1
fordító megírásához:

- Fix méretű egész típusok, `bool`, nyers pointer, fix méretű tömb, `struct`
- Csak függvény-elején történő deklaráció (állapottér rögzítése — Hoare-logika-barát)
- `if`/`else`, `while`, `return`
- Szimultán értékadás (`:=`), Dijkstra/Hoare-szemantikával
- Teljes kifejezés-nyelvtan operátor-precedenciával
- Több számrendszerű egész literál, `bool` literál, `null`
- `//` és `/* */` kommentek

### Mit szándékosan kizártunk Stage 0-ból

- Generikusok, closure-ök, kivételkezelés, OOP (öröklés, dinamikus diszpatch), GC
- Sztenderd könyvtár, string típus, char típus, float típus
- Verifikációs kontraktus-szintaxis (`requires`/`ensures`/invariáns) — ez a nyelv
  *fő* célja lesz, de csak Stage 1-től kezdve jelenik meg
- Többfájlos modul-/include-rendszer
- Referencia szerinti paraméterátadás (csak érték szerint, ld. lentebb)
- `**` hatványozó operátor (ld. "Későbbre halasztott döntések")

---

## 4. Teljes formális nyelvtan (EBNF) — Stage 0

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function | struct_decl

struct_decl    ::= "struct" identifier "{" field_decl+ "}"
field_decl     ::= identifier ":" type ";"

function       ::= "function" identifier "(" params? ")" ":" type func_block
params         ::= param ("," param)*
param          ::= identifier ":" type

func_block     ::= "{" decl* stmt* "}"
block          ::= "{" stmt* "}"
decl           ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"

stmt           ::= assign_stmt | if_stmt | while_stmt | return_stmt | expr_stmt

assign_pair    ::= lvalue ":=" expr
assign_stmt    ::= assign_pair ("," assign_pair)* ";"
lvalue         ::= "*" lvalue | identifier ( "[" expr "]" | "." identifier )*

if_stmt        ::= "if" "(" expr ")" block ("else" block)?
while_stmt     ::= "while" "(" expr ")" block
return_stmt    ::= "return" expr? ";"
expr_stmt      ::= expr ";"

expr           ::= logic_or
logic_or       ::= logic_and ("||" logic_and)*
logic_and      ::= comparison ("&&" comparison)*
comparison     ::= bit_or (("==" | "!=" | "<" | ">" | "<=" | ">=") bit_or)?
bit_or         ::= bit_xor ("|" bit_xor)*
bit_xor        ::= bit_and ("^" bit_and)*
bit_and        ::= shift ("&" shift)*
shift          ::= additive (("<<" | ">>") additive)*
additive       ::= multiplicative (("+" | "-") multiplicative)*
multiplicative ::= unary (("*" | "/" | "%") unary)*
unary          ::= ("!" | "-" | "*" | "&") unary | postfix
postfix        ::= primary postfix_op*
postfix_op     ::= "[" expr "]" | "." identifier | "(" args? ")"
primary        ::= struct_literal | array_literal | identifier | literal | "(" expr ")"
args           ::= expr_list?
expr_list      ::= expr ("," expr)*

struct_literal ::= identifier "{" field_init ("," field_init)* "}"
field_init     ::= identifier ":=" expr

array_literal  ::= "{" expr_list "}"

literal         ::= integer_literal | bool_literal | null_literal
integer_literal ::= decimal_form | based_form
decimal_form    ::= digit+
based_form      ::= digit+ "n" value_digit+
bool_literal    ::= "true" | "false"
null_literal    ::= "null"

base_type      ::= "int8" | "int16" | "int" | "int32" | "int64"
                  | "uint8" | "uint16" | "uint" | "uint32" | "uint64"
                  | "bool" | identifier
type           ::= base_type "[" integer_literal "]"
                  | "*" type
                  | base_type

identifier     ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
digit          ::= "0".."9"
value_digit    ::= "0".."9" | "a".."f" | "A".."F"

comment        ::= line_comment | block_comment
line_comment   ::= "//" (any_char_except_newline)* newline
block_comment  ::= "/*" (any_char)* "*/"

keywords       ::= "function" | "struct" | "mut" | "const" | "if" | "else" | "while"
                  | "return" | "true" | "false" | "null"
                  | "int8" | "int16" | "int" | "int32" | "int64"
                  | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "bool"
```

### Szemantikai megkötések (nem nyelvtaniak — a fordító szemantikai elemző
fázisában ellenőrizendők, nem a lexer/parser szintjén)

| Terület | Szabály |
|---|---|
| Számrendszer-bázis | Kizárólag `{2, 8, 10, 16}` lehet a `based_form` bázisa; minden `value_digit` kisebb kell legyen a bázisnál. **Tudatosan megengedőbb a nyelvtan, mint a szemantika** — később bővíthető a bázishalmaz a szemantikai elemző módosításával, a nyelvtan változatlanul hagyásával. |
| Deklaráció helye | Kizárólag a `func_block` legelején — beágyazott blokkokban (`if`/`while` teste) nem lehet `decl`. Ez a `func_block` vs. `block` külön szabállyal már a nyelvtan szintjén ki van zárva. |
| Paraméterátadás | Mindig **érték szerint** Stage 0-ban (nincs referencia-átadás). |
| `const` | Kötelező inline `:=` inicializálás; a `const` azonosító **soha** nem lehet `lvalue` célpont `assign_stmt`-ben. |
| `mut` (skalár típus) | Opcionális inline inicializálás; tetszőlegesen újraírható. |
| `mut`/`const` (tömb-típus) | **Kötelező** `:=` inicializálás; az érték egyetlen kifejezés, amit **minden tömbelemre alkalmaz (broadcast)**. Pl. `mut arr : int32[10] := 0;` → mind a 10 elem 0. |
| `mut`/`const` (struct-típus) | **Kötelező** `:=` inicializálás, kizárólag `struct_literal` formában. |
| `struct_literal` | A hivatkozott `struct` **minden** mezőjét pontosan egyszer, explicit módon meg kell adnia — hiányzó vagy duplikált mező fordítási hiba. Cél: soha ne jöhessen létre inicializálatlan ("szemét") memóriatartalmú struct-példány. |
| `comparison` | **Nem láncolható** — `a < b < c` nyelvtanilag hibás (a `?` jelöli a nyelvtanban: legfeljebb egy összehasonlító operátor). Ez tudatos eltérés a matematikai konvenciótól, hogy elkerüljük a C öröklött, megtévesztő láncolási viselkedését. |
| `int` / `uint` | `int` ≡ `int16`, `uint` ≡ `uint16` — teljesen ekvivalens alul fekvő típusok, nem külön típusok. |
| Implicit típuskonverzió | **Tilos.** Bináris operátorok mindkét operandusának szigorúan azonos típusúnak kell lennie (pl. `int8 + int32` fordítási hiba). Ez kiküszöböli a komplex implicit coercion/zext/sext logikát a Stage 0 kódgenerátorból, és összhangban van a nyelv "explicit mindenben" alapkonvenciójával. |
| `array_literal` | Az elemek száma pontosan meg kell egyezzen a deklarált tömbmérettel (`N`). Eltérés esetén fordítási hiba — köztes, részleges lista nem megengedett (ugyanaz a "nincs szemét memória" elv, mint a struct-oknál). A fordító a listát belsőleg sorozatos indexelt értékadásra bontja szét (`arr[0] := e0; arr[1] := e1; ...`), nincs hozzá külön kódgenerálási eset. |
| Pointer-aritmetika | **Tiltott Stage 0-ban.** Pointereken kizárólag címképzés (`&`) és dereferálás (`*`) megengedett — `p + 1` stílusú kifejezések fordítási hibát adnak. A tömbelérés `arr[i]` formában továbbra is támogatott. Ez a megkötés **később, egy adott fázisban feloldásra kerül** — ld. "Későbbi fázisokra halasztott döntések". |
| Szimultán értékadás | `assign_stmt`-ben minden `lvalue` célpontnak különbözőnek kell lennie egy soron belül. A jobb oldalak kiértékelése az utasítás **előtti** állapoton történik; az összes hozzárendelés csak ez után, egyszerre lép érvénybe (Dijkstra/Hoare-szemantika). |

### Operátor-precedencia és asszociativitás (a nyelvtani lánc sorrendje már ezt
tükrözi, legerősebbtől leggyengébbig)

| Szint (erős→gyenge) | Operátorok | Asszociativitás |
|---|---|---|
| `postfix` | `[]`, `.`, `()` | bal |
| `unary` | `!`, `-`, `*` (dereferencia), `&` (cím) | jobb (prefix-lánc) |
| `multiplicative` | `*`, `/`, `%` | bal |
| `additive` | `+`, `-` | bal |
| `shift` | `<<`, `>>` | bal |
| `bit_and` | `&` | bal |
| `bit_xor` | `^` | bal |
| `bit_or` | `|` | bal |
| `comparison` | `==`, `!=`, `<`, `>`, `<=`, `>=` | **nem láncolható** |
| `logic_and` | `&&` | bal |
| `logic_or` | `||` | bal |

**Fontos:** a bitwise operátorok szorosabban kötnek, mint az összehasonlítás
(Python-stílus) — ez tudatosan megfordítja a klasszikus C-hibát, ahol pl.
`e & 1 == 1` a `e & (1 == 1)`-ként értelmeződik. Nálunk `e & 1 == 1` ≡
`(e & 1) == 1`.

---

## 5. Tervezési döntések — indoklással (gyors referencia)

- **`:=` értékadás, nem `=`** — az ELTE programozáselméleti (Dijkstra/Hoare)
  jelöléshagyományt követi; szó szerint megegyezik Fóthi Ákos *Bevezetés a
  programozáshoz* c. könyvének jelölésével.
- **Csak `mut` és `const`, nincs `let`** — a `let` felesleges lett volna, mivel a
  cél csak kétfajta változó (tetszőlegesen módosítható / állandó).
- **Deklaráció csak a függvény elején** — rögzíti az "állapotteret" a függvény
  teljes törzsére, megkönnyítve a Hoare-hármas alapú bizonyítást.
- **`function name(params) : type { }`** — nem `fn`/`->`, hanem `function`/`:`.
- **Azonosítókban nincs kötőjel** — ütközne a kivonás operátorral (`a-b`
  kétértelmű lenne maximális illesztés esetén); csak `_` engedélyezett.
- **Kommentek C-stílusúak** (`//`, `/* */`).
- **Több számrendszerű literál `BÁZISnÉRTÉK` formában** (pl. `16n1F`), nem
  `0x`/`0b` prefixekkel — nyitva hagyja a jövőbeli bázisbővítést; csak a
  szemantikai elemzőt kell módosítani, a nyelvtant nem.
- **`^` marad bitwise XOR**, nem hatványozás — a hatványozáshoz `**` lesz
  bevezetve, de **később**, nem Stage 0-ban (ld. lent).
- **Tömbméret postfix jelölésű** (`int32[10]`, nem `[10]int32`).
- **Struct- és tömb-deklarációknál kötelező a teljes inicializálás** — nincs
  "szemét" memóriatartalmú összetett érték; ez matematikailag is konzisztens
  Fóthi könyvének rekord-definíciójával (a rekord *maga* a teljes komponens-n-es,
  fogalmilag nem létezhet részleges kitöltés).

---

## 6. Későbbi fázisokra (nem Stage 0-ra) halasztott döntések

1. **UTF-8 forráskód-kódolás támogatása** — a Stage 0 egyelőre ASCII-alapú,
   de a Postulate-nek végül UTF-8-at kell támogatnia (nem csak ASCII-t).
2. **`**` hatványozó operátor**, jobbról balra asszociatívan
   (`2**3**2 = 2**(3**2)`), `^` marad XOR-ra fenntartva. Nincs natív x86_64
   egész-hatványozó utasítás — szoftveresen, ismételt négyzetreemeléssel
   (exponentiation by squaring) implementálandó, ha bevezetésre kerül.
3. **Referencia szerinti paraméterátadás** — Stage 0-ban minden paraméter
   érték szerint adódik át. Később az érték szerinti átadás marad az
   alapértelmezett, de explicit jelöléssel (szintaxisa még kidolgozandó)
   lehetővé válik a referencia-átadás is.
4. **Pointer-aritmetika** — Stage 0-ban tiltott (csak `&`/`*` engedélyezett),
   de egy későbbi fázisban bevezetésre kerül. A bevezetés módja (pl. csak
   típusméret-skálázott léptetés, vagy nyers byte-offset) még kidolgozandó.

---

## 7. Nyitott, még véglegesen el nem döntött kérdések

- **String/char típus** — Stage 0-ban tudatosan nincs, a Stage 1 lexer/parser
  nyers `uint8` bájtokként kezeli a szöveget. Később, ha a nyelv bővül,
  újra átgondolandó.
- **`postfix_op` külön szabályként** — nyelvtanilag és **kódgenerálásban is**
  külön AST-csomópont-típusként kezelendő (nem összeolvasztva a `postfix`
  szabállyal) — ez explicit kérés volt, tartsd meg az implementáció során.

*(A tömb-literál (`array_literal`) korábban nyitott kérdés volt, mostanra
véglegesítve — ld. a 4. fejezet nyelvtanát és az 5. szemantikai táblázat
`array_literal` sorát.)*

---

## 8. Formális háttér — megfelelés Fóthi Ákos *Bevezetés a programozáshoz* c.
könyvének relációs modelljével

A nyelv konstrukciói közvetlenül visszavezethetők a könyv formalizmusára — ez
lesz a bizonyítási apparátus alapja, amikor a verifikációs szintaxis (Stage 1+)
bevezetésre kerül:

- **`while_stmt`** ≡ könyv `DO(π, S0)` konstrukciója (6.3, 7.3 fejezet) — a
  ciklus levezetési szabálya (invariáns `P`, terminálófüggvény `t`) közvetlenül
  alkalmazható.
- **`assign_stmt`** (szimultán értékadás) ≡ könyv 8.4. definíciója (Elemi
  programok — Értékadás), szó szerint ugyanaz a `:=` jelölés és szemantika.
- **`struct`** ≡ könyv "rekord" típuskonstrukciója (11.1–11.2 fejezet) —
  szelektorfüggvények (`t.si`), mezőértékadás (`t.si := ti`) pontosan egyeznek.
- **`if`/`else`** a könyv általánosabb, nemdeterminisztikus `IF(π1:S1,...,πn:Sn)`
  konstrukciójának (6.2, 7.2 fejezet) egy determinisztikus, kéttagú, kimerítő
  speciális esete. `else` nélküli `if` megfeleltethető `IF(π: S, ¬π: SKIP)`-nek,
  ahol `SKIP` a könyv 8.2. definíciója szerinti identitás-program.
- Tudatosan **nem** vettük át: `ABORT` (soha nem terminál), értékkiválasztás
  (`:∈`, nemdeterminisztikus) — ezek a relációs modell nemdeterminizmus-kezeléséhez
  kellenek, de egy tényleges, determinisztikus fordítóprogram célnyelvéhez nem
  szükségesek.

---

## 9. Minta program (a legutóbb egyeztetett szintaxis szerint)

```postulate
// Szintaxis-bemutató a Postulate nyelvhez.

struct Node {
  value : int32;
  next  : *Node;
}

struct Pair {
  a : uint8;
  b : uint8;
}

function is_even(n : int32) : bool {
  mut remainder : int32;
  remainder := n % 2;
  return remainder == 0;
}

function power_by_squaring(base : uint64, exp : uint64) : uint64 {
  mut result : uint64 := 1;
  mut b      : uint64 := base;
  mut e      : uint64 := exp;

  while (e > 0) {
    if ((e & 1) == 1) {
      result := result * b;
    }
    b := b * b;
    e := e >> 1;
  }

  return result;
}

function swap_values(x : int32, y : int32) : int32 {
  mut a : int32 := x;
  mut b : int32 := y;

  // Szimultán értékadás: a jobb oldalak az eredeti állapotban értékelődnek ki
  a := b, b := a;

  return a;
}

function make_pair(x : uint8, y : uint8) : Pair {
  return Pair { a := x, b := y };
}

function mult(x : int) : int {
  return x * 2;
}

function main() : int32 {
  const pair : Pair := Pair { a := 8n17, b := 16n1F };
  const total : uint := 16n64;            // uint ≡ uint16

  mut n2 : Node := Node { value := 99, next := null };
  mut n1 : Node := Node { value := 1,  next := &n2 };

  mut arr : int32[10] := 0;               // minden elem 0-ra inicializálva
  arr[0] := 5;
  arr[1] := 10;

  // array_literal: pontosan 10 elem, tetszőleges expr (pl. függvényhívás) is lehet
  mut arr2 : int32[10] := {1, 2, 3, 4, 5, 6, 7, mult(4), 9, 10};

  mut p   : *int32 := &arr[0];
  mut sum : int32   := *p + arr[1];

  if (is_even(sum)) {
    sum := sum * 2;
  } else {
    sum := sum + 1;
  }

  return sum;
}
```

---

## 10. Következő lépés (ahol a tervezés abbamaradt)

A Stage 0 nyelvtan **formálisan lezártnak** tekinthető (a 7. pontban jelzett
nyitott kérdések kivételével, amik nem blokkolják az indulást). A logikus
következő lépések egy új munkamenetben:

1. Dönteni a tömb-literál bevezetéséről (7. pont), vagy elhalasztani.
2. Lexer implementációjának megkezdése x86_64 assembly-ben (Linux syscall ABI),
   a fenti `identifier`/`literal`/`comment`/`keywords` szabályok alapján.
3. Rekurzív leszállásos parser felépítése a fenti EBNF alapján.
4. GitHub Actions CI beállítása (QEMU + Docker-alapú build környezet) —
   ez a projekt egy korábbi, ehhez a dokumentumhoz nem tartozó megbeszélésének
   témája volt, érdemes külön összefoglalni, ha szükséges.
