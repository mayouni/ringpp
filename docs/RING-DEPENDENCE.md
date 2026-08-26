# The Ring-dependence audit

*Measured 2026-08-26, across four repositories: Ring++, Softanza (`stzlib`),
RingServ and RingScript. Nothing here is an estimate.*

**Why this exists.** The question "should we stay on Ring, fork it, or build
our own language?" has been asked as a mood for a while. It cannot be
answered as a mood. This file turns it into an inventory: exactly what the
estate consumes from Ring, separated by what replacing each layer would
actually cost. The strategic reading is at the end; the numbers come first,
so a future reader can disagree with the conclusion and keep the data.

**Method.** Ring's builtin vocabulary is not guessed — it is extracted from
`RING_API_REGISTER(...)` in Ring 1.27's own C source: **258 names**. Every
`.ring` file in the four repositories was scanned with ripgrep for
identifiers in call position, folded to lower case (Ring identifiers are
case-insensitive — F-18), and intersected with that list. Archived trees and
`.claude` worktrees excluded. The whole scan takes under two seconds, which
is worth stating because the fear that it was expensive is part of why it had
not been done.

---

## 1. What the estate is made of

| | lines | files | classes | functions |
|---|---:|---:|---:|---:|
| **Softanza** (`stzlib`) | **727,744** | 6,020 | 754 | 46,666 |
| RingServ | 6,611 | 555 | 2 | 222 |
| RingScript | 6,271 | 580 | 11 | 310 |
| Ring++ | 5,090 | 77 | 6 | 190 |
| **Ring total** | **745,716** | 7,232 | 773 | 47,388 |
| *Softanza's Zig engine* | *156,449* | *380* | — | — |

The estate is roughly **746,000 lines of Ring** and **156,000 lines of Zig**.

---

## 2. What it consumes from Ring, by tier

Builtin call sites, classified by what it would cost to replace them:

| project | distinct builtins | call sites | **T3 internals** | T2 binary | T1 ordinary |
|---|---:|---:|---:|---:|---:|
| Ring++ | 73 | 1,046 | **25 names / 296** | 8 / 73 | 40 |
| Softanza | 155 | 44,920 | **13 names / 115** | 11 / 399 | 131 |
| RingServ | 39 | 795 | **0 / 0** | 1 / 3 | 38 |
| RingScript | 48 | 752 | **2 names / 4** | 1 / 3 | 45 |

- **Tier 3 — Ring's internals.** `varptr`, `memcpy`, `ptr2str`, `setptr`,
  `ringvm_*`, `ring_state_*`, `space`. Nothing outside Ring provides these.
  This is the only true technical lock-in.
- **Tier 2 — binary/system surface.** `int2bytes`, `loadlib`, `fopen`,
  `eval`. Every language has equivalents with different semantics; porting
  needs care, not invention.
- **Tier 1 — ordinary.** `len`, `upper`, `substr`, `sin`. Mechanical.

### The headline number

```
builtin call sites, all four projects : 47,513
  of those, Tier 3 (Ring internals)   :    415   0.87%
  of those, Tier 2 (binary/system)    :    478   1.01%
distinct Tier-3 names, whole estate   :     26
```

**The deep dependency on Ring's internals is 26 names and under 1% of call
sites** — and [VM-CONTRACT.md](VM-CONTRACT.md) already fences about twenty of
them, machine-checked on every load by `rpp/probe.ring`.

The 26:

```
getptr  memcpy  nullptr  object2pointer  ptr2str  ptrcmp  setptr  space  varptr
ring_state_init  ring_state_runcode  ring_state_findvar  ring_state_setvar
ring_state_delete  ring_state_scannererror  ring_state_stringtokens
ringvm_genarray  ringvm_hideerrormsg  ringvm_info  ringvm_codelist
ringvm_functionslist  ringvm_classeslist  ringvm_packageslist
ringvm_fileslist  ringvm_ringolists  ringvm_writeringo
```

**RingServ touches none of them.** RingScript touches two. The internals
concentrate almost entirely in Ring++ (296 sites) — which is exactly what
Ring++ is *for*, and means the siblings are portable in a way the estate had
never actually verified.

---

## 3. The seam nobody had measured

Softanza's engine is Zig. The Ring side of that boundary:

| layer | lines | files |
|---|---:|---:|
| Zig engine | 156,449 | 380 |
| Ring API layer over it (`stz_*.ring`) | 2,869 | 84 |
| **FFI bridge proper** (`stk_*.ring`) | **92** | **4** |
| `loadlib` call sites, whole estate | 113 | — |

**A third of the estate by volume is already Ring-independent, joined to Ring
by a 92-line adapter.** That is the single most strategically important
number in this file. Whatever host language the engine ever answers to, the
part that has to be rewritten to move it is under a hundred lines.

---

## 4. Where the lock-in actually is

Not in the internals. **In the 745,716 lines of Ring syntax and object
model** — 773 classes, 47,388 functions, 7,281 `load` statements, and 1,045
uses of Ring's brace-scope idiom (`oObj { ... }`) in Softanza alone.

Softanza is not "a library that happens to be written in Ring." It is
written *in Ring's grain*: the brace scope, the method-resolution order, the
case-insensitivity, the copy-on-assign object semantics that Ring++'s own
findings (F-22, F-25, F-27) document. That is the asset and the anchor at the
same time.

**So the intuitive framing was backwards.** The pointer tricks feel like the
deep dependency because they are the exotic part. They are 0.87%. The
ordinary-looking Ring code is the dependency, and there are three quarters of
a million lines of it.

---

## 5. The three options, priced

| option | preserves 746K lines | cost | reversible |
|---|---|---|---|
| **Stay, behind contracts** *(current)* | yes | process only | yes |
| **Governed distribution** | yes | pinning, gates, LTS promises, response commitments | yes |
| **Fork Ring's VM** | yes | maintaining a C VM in perpetuity | partly |
| **New language** | **no** | 746K-line migration + a decade of ecosystem | no |

**Fork is cheaper than it looks and less necessary than it looks.** Phase B2
already builds Ring's VM from source for five platforms in about two and a
half minutes warm, and Ring++'s CLI cross-builds to all five. The capability
exists and is gated. But a fork buys governance that a *distribution* also
buys, at the price of a permanent C maintenance burden and a social cost —
so it is the answer only if upstream becomes unresponsive, which the
2026-08-25 stdlib fix (one day, credited) is evidence against.

**A new language is the only irreversible option**, and the 746,000-line
figure is why. AI shrinks the cost of *building* a language by an order of
magnitude; it does not shrink the ecosystem, the migration, or the decade.
Rational only if the language itself becomes the product.

**The governed distribution is the answer to the actual customer objection.**
The objection is not "Ring is technically weak" — Ring++ answers that. It is
governance: bus factor, release discipline, security response. That is
answered by owning the layer customers touch — a pinned Ring, run through
27 gates, findings published, response times stated — not by arguing in a
mailing list and not by forking.

---

## 6. What this audit does not cover

Stated so the gaps are visible rather than implied:

- **Language semantics are counted, not analysed.** 1,045 brace-scopes is a
  volume, not a difficulty rating. Nobody has attempted a mechanical
  Ring-to-anything translation to find out what actually resists.
- **The Ring stdlib surface** (`libraries/stdlib/*.ring`) is consumed through
  ordinary calls and is folded into Tier 1 here. A port would need its own
  inventory.
- **Toolchain dependence** — `ringpm`, `ring2exe`, `ring.exe -go` — is
  process, not code, and is not measured.
- **The ~75-library Qt surface** is out of scope by decision (F-30), so it is
  not a dependency this estate carries at all.
- **No migration was attempted.** Every cost above is an inventory, not an
  experiment. The next honest step, if the question ever turns live, is to
  port one non-trivial Softanza module and measure what it actually took.

---

## 7. The finding, in one line

> **Ring++ was built to escape Ring's performance limits and ended up
> measuring the estate's dependence on Ring instead: 26 internal names under
> a contract, a 92-line bridge to a 156,000-line portable engine, and 746,000
> lines of Ring that are the real anchor.**

The technical exit is cheap and already half-built. The linguistic exit is
expensive and nobody should take it for governance reasons — because
governance has a cheaper answer that keeps every line.
