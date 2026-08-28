# The checker's frontier

What forty-five findings teach about growing `ringpp check` — and the map
for growing it from 21 rules toward two goals Mansour set: **name every
critical performance bottleneck with its rewrite**, and **catch every Ring
error that can be caught before the program runs**.

This document is the plan. Its discipline comes first, because every
false start this project has made came from skipping it.

---

## 1. How a rule is born — five lessons paid for, not adopted

**A rule is a measurement that happens to have a syntax.** Every rule in
the checker traces to a number in FINDINGS.md, and both directions of that
arrow matter: `len-in-loop-header` exists because 701 ms was measured, and
`fabs`-hoisting has *no* rule because 20 ns ≈ 21 ns was measured (F-44).
The anti-rules are part of the catalog.

**Generalising past the measurement is how false positives are made.**
The one FP class this checker has shipped: `len()` in a for-header was
measured in the *bound* position and the rule fired on the *start*
position too — where Ring evaluates once (1 ms vs 4,725 ms). 40% of its
hits in one corpus were wrong until the sites were read. The rule for
rules: **fire on the shape that was measured, not the shape that looks
similar.**

**Verify the semantics before the rule, not after.** F-45's rules were
preceded by five tiny programs answering: does this ship in dead code? does
`exit` cross a call? is `exit 2` at depth 2 legal? does Ring already catch
`class A from A`? The last answer *deleted* a planned rule — Ring catches
it at compile time (C24), so a checker rule would be noise. Ring's own
coverage is part of the map.

**Defects and opportunities must not share a channel.** The `err/warn/
perf/note` tiers are for things wrong *now*; the `adv` tier
(`--advise`) is for working code that a measured idiom beats. Mixing them
is how a lint gets ignored — so advice is invisible by default, counted in
one summary line.

**Value-dependent cost is advice; value-independent error is a defect.**
Static analysis sees shapes, never sizes. `substr` in a loop is quadratic
*if the string is large* → `perf`, human decides. `exit` outside a loop
raises *always* → `err`, no judgment needed. This single distinction
decides almost every tier assignment below.

---

## 2. The performance frontier

Every performance finding so far reduces to **four cost mechanisms**. Each
mechanism is a family of checkable shapes; the shipped rules and the
candidates both belong to one.

### Mechanism A — strings copy at every boundary (F-1, the founding fact)

| shape | status | number behind it |
|---|---|---|
| `substr()` in a loop | ✅ `substr-in-loop` | 12.5 µs vs 0.09 µs (F-6) |
| `len(s)` in a loop bound / while condition | ✅ `len-in-loop-header` | 701 ms vs 4 ms (F-41) |
| `left+patch+substr` rebuild | ✅ `advise-patch-rebuild` | 12.9× (F-1, ex. 01) |
| `memcpy` into a string | ✅ `memcpy-string-dest` | silent no-op (F-1) |
| **string arg to a user call inside a loop** | **candidate** | ~750 µs/MB per crossing (F-5) — needs the loop-context measurement |
| **`substr(s,i,1)` specifically → `s[i]`** | **candidate** (sharpen existing message) | 316 µs vs 0.07 µs (F-8) |
| **handle-rebuild in a loop** (constructor + free of a loop-invariant value each pass) | **candidate** | 10× measured once (CASE-SOFTANZA) — needs a second corpus shape before it generalises |

The candidate to do first is the **string argument crossing a call in a
loop**: the `stringish` name-tracking it needs already exists (built for
`memcpy-string-dest`), the tier is `adv` (a small string crossing cheaply
is fine), and it is the checker finally pointing at F-1 itself rather than
at F-1's symptoms.

### Mechanism B — list access walks from a cursor (F-42)

| shape | status | number |
|---|---|---|
| `ringvm_genarray` in a loop | ✅ `genarray-in-loop` | 95× / −16× (F-9, F-10) |
| **jumping index in a loop** — `a[nMid]`, `a[nIdx]` where the index is not the induction variable ± constant | **candidate**, `adv` | 22 → 798 ms scaling (F-42); RppIndexed recovers 8× |

FP control for the candidate: fire only when the index variable is
*reassigned inside the loop body* (that is what "jumping" is, lexically).
Sequential and offset access stay silent.

### Mechanism C — the interpreter's own per-op costs (F-43, F-44)

| shape | status | number |
|---|---|---|
| `for-in` | ✅ `advise-forin` | ~2× (F-43) |
| `varptr()` in a loop | ✅ `varptr-in-loop` | 790 ns/call (F-4) |
| hoist-a-cheap-call | ❌ **anti-rule, permanent** | 20 ns ≈ 21 ns (F-44) |

Mechanism C is close to exhausted: the costs are flat and small, so few
shapes clear the bar of *worth a diagnostic*.

### Mechanism D — crossing a native seam per item instead of per algorithm

`memcpy` chunk assembly (28× *slower*, F-5), the Softanza engine bridge
(10×, CASE-SOFTANZA), and RppBuffer-per-byte (27× against, CASE-SOFTANZA)
are all one law: **the seam is crossed once per algorithm or the seam
wins.** It is also the hardest mechanism to lint — the same call is right
outside a loop and wrong inside one, and "expensive call" is not visible
in syntax. The honest instrument here may not be a rule but a *profile*:
`ringpp` could one day count seam-crossings at runtime the way `RppAdvise`
already counts idiom misuse. Held until a design exists.

---

## 3. The correctness frontier — Ring's R-catalog as the map

Ring's VM defines **55 numbered runtime errors** (`vm.h:573–629`). That
catalog is the complete list of everything Ring can refuse at runtime —
which makes it the complete worklist for "catch it at compile time
instead." Each entry gets one question: **is there a syntactic shape that
guarantees this error?**

Triage of all 55, grouped by answer:

### Already caught by `ringpp check` (7)

| error | rule |
|---|---|
| R4 stack overflow via empty catch | `empty-catch` (F-16) |
| R6 variable required (varptr spelling) | `varptr-unknown-name` (F-2) |
| R19 / R20 arity | `type-arity` + cross-file layer |
| R9 / R22 exit/loop outside loop | `exit-outside-loop` (F-45) |
| R10 / R23 exit/loop depth (literals) | `exit-bad-depth` (F-45) |
| R3 call without definition | `undefined-function` (F-46) |
| R24 uninitialised variable | `uninitialized-variable` (F-47) |
| R11 / R15 unknown class / parent | `unknown-class` (F-48) |

### Ring already catches at compile time — no rule needed (verified, not assumed)

R30 parent=child class (C24). Others in the C-catalog likewise; each
candidate below gets the same dead-code verification F-45's rules got, and
any that Ring's compiler already rejects is dropped.

### Statically guaranteed — the near queue (each needs its F-45-style verification first)

| error | shape | tier | machinery |
|---|---|---|---|
| R25 unknown package | `import X` with no `package X` in the set | `err` | classnames machinery, one more collector — verified R25 at runtime already |
| R7 letter = multi-char literal | `s[i] = "xy"` where `s` is stringish | `warn` | `stringish` ✅; needs list-exclusion to reach zero-FP |
| R26 / R27 private access | `o.method()` against a class layout where it is private | `note` | class layout parse |
| R52 return inside call args | syntactic | `err` | trivial |
| R28 / R29 for/step bad literal type | `for i = "a" to ...` | `err` | trivial, literals only |

**R3 shipped (2026-08-28), and building it sharpened the map.** The first
sweep produced 4,429 false positives in Softanza, all one mechanism: *a
library file's calls resolve at runtime through whoever loads it, not
through its own `load` lines* — per-closure absence proves nothing. The
shipped rule speaks only over a whole-set definition universe with no
holes: every file parsed, every load resolved, no loadlib/eval in reach,
name absent in every form. That trade — err-tier certainty bought with
narrow coverage — is now the template every "statically guaranteed" row
above inherits, and **R24 was the first to inherit it (2026-08-28)**: same
universe gates, plus two of its own — methods excluded by ROW (the grammar
leaves post-class functions at root level; Ring makes them methods, F-21),
and `new X { ... }` bodies excluded as object scope. **R11/R15 followed
the same day** (`unknown-class`, F-48) and paid the template forward: its
17 fragment-file false positives in ring127/applications moved the
loadlib/eval/unresolved gates from per-closure to SET-GLOBAL for every
absence-based rule. Four rules, four pre-ship saves. R25 (unknown
package) is the next trivial member of the family; R7/R52/R28/R29 remain
queued above.

### Fundamentally dynamic — the honest wall (most of the catalog)

R1 divide by zero, R2 index range, R18/R40/R41/R55 numerics, R35 files,
R38/R46 libraries, R42/R44 eval, R12/R14 on dynamic objects… these depend
on **values**, and no static analyzer sees values. Two escape hatches
exist, both long-game:

- **Literals**: `x / 0` with a literal zero *is* static. Cheap partial
  rules are possible for several of these; each is a small win, none is a
  wall-breach.
- **Type inference on the annotation channel**: Ring's parser already
  accepts and discards type annotations (the checker's founding
  observation). Level 1 checks declared signatures. **Level 2 — inferring
  local types from literals and propagation — would move R21 (operator on
  wrong types), R8, R13, R45 partially into reach.** This is the largest
  single expansion available and the right shape for it is a design
  document of its own before any code.

---

## 4. The order of work

1. ~~**R3 undefined-function**~~ — **shipped** as `rpp/undefined-function`
   (F-46), with the three-gate humility its first 4,429 false positives
   demanded.
2. **String-arg-in-loop advice** — the checker finally pointing at F-1
   itself. `adv` tier, `stringish` exists.
3. **R11/R15 unknown class** — same walker as C22, small.
4. **R24 use-before-assign** — bounded to per-function, `warn`,
   documented humility.
5. **Jumping-index advice** (Mechanism B) — after a second corpus
   measurement confirms the lexical "index reassigned in body" test
   matches the runtime behaviour.
6. **Level-2 type inference** — design document first. This is the one
   that changes what the checker *is*.

Each lands the way F-45 landed: semantics verified against Ring 1.27
before the rule, a fixture defect, a why entry, a corpus sweep read
site-by-site before anything is reported, and the shipped binaries
rebuilt.

---

## 5. What stays out, permanently

- **Hoist-a-call advice** — wrong half the time (F-44).
- **Anything whose mechanism is unexplained** — F-39's binary-search gap
  stayed out of the checker for a day and a half until F-42 demonstrated
  the cursor walk; measured-but-unexplained never ships as a rule.
- **Style** — naming, layout, comment density. Other tools' business.
- **Rules Ring's own compiler already enforces** — verified per rule, the
  way C24 deleted one here.

The front page claims 0 false positives. Every line of this frontier is
subordinate to keeping that sentence true.
