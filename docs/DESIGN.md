# Ring++ — design

*August 11, 2026. Written after, and entirely downstream of,
[FINDINGS.md](FINDINGS.md). Read that first: two of its measurements
killed the design I set out to write, and a third replaced it.*

---

## 0. What changed after measuring

The brief proposes: ordinary Ring, and where it matters, drop a level —
a real sized buffer, `WriteInt32`, `CopyFrom`. I built that shape and
measured it. **Building 1.6 MB through a sized buffer with `memcpy` is
28× slower than `cOut += chunk`** (F-8). `varptr` costs 790 ns per call,
twelve times an ordinary function call (F-4). On writing, Ring is
already good: `ring_string_add2_gc` doubles capacity, so `+=` is
amortised O(1).

So the honest thesis is not *"pointers are faster."* It is:

> **Ring passes lists by reference and strings by copy. Ring++ is the
> way to hold a large value still.**

Three measurements carry the project:

- passing a 1 MB string to a function: **~750 µs**; passing a handle to
  the same bytes: **0.3 µs** (F-5);
- `substr(cBig, n, 10)` on a 500 KB string: **12.5 µs**;
  `ptr2str(p, n, 10)`: **0.09 µs** — ~140×, growing with the string
  (F-6). Ring already has an O(1) substring, spelled `ptr2str`, and
  nobody uses it;
- patching bytes at an offset: **803 ms** rebuilding versus **1 ms**
  in place (F-7) — here there is no pure-Ring alternative at all.

And one measurement keeps the project honest: `ringvm_genarray` is ~95×
on read-heavy work and **10–16× worse** on write-heavy work, with the
break-even at ~10–20 random reads per mutation (F-9, F-10).

Everything below follows from those four facts.

---

## 1. What Ring++ is

**A pure-Ring library. One `load`, no build, no extension, no vendored
interpreter, no compiler on the user's machine.**

```ring
load "ringpp.ring"
```

That is the whole installation on every platform Ring runs on, including
RingScript in the browser, because every primitive it uses is registered
by the VM core (`genlib_e.c`, `file_e.c`, `vminfo_e.c`, `list_e.c`) and
none requires an extension.

### Alternatives rejected

**A vendored/patched Ring.** Forfeits the one property that makes
findings credible — that Ring++ runs on *Mahmoud's* Ring, byte for byte
— and makes constraint 2 (survive upgrades untouched) unachievable by
construction: a patched tree must be re-patched every release. RingScript
already occupies that niche with an 8-patch vendor discipline and a
byte-exact oracle to police it; Ring++ must not need one.

**A C extension.** It would buy real speed: a single C function doing
"scan this buffer for delimiters and return the offsets" would beat
anything above. But it needs a compiler and a per-platform artifact,
which kills "one project, two altitudes." The moment a Ring programmer
must build something, they are back where Ring++ was invented to rescue
them from. Deferred to Phase 5 as a strictly optional accelerator behind
an already-working pure-Ring implementation — never as the only path.

**Code generation, the `myctiger` shape.** Argued in §7. Short version:
generation cannot return a value into the running program, which is
exactly what the brief asks for.

**A layer inside Softanza.** Argued in §8. Recommendation: independent,
with Softanza as its first consumer.

### What Ring++ is *not*

Not a framework, not a DSL, not a replacement for any Ring idiom that
already wins. Its most common correct answer to "should I use Ring++
here?" must be **no** — and it should be able to say so, out loud, at
runtime (§4, `RppAdvise`).

---

## 2. Layer map

```
  L4  your program            ordinary Ring, unchanged
      ──────────────────────────────────────────────  the visible seam:
  L3  rpp/idioms.ring         every name starts with Rpp
        RppScan RppPack RppIndexed RppSandbox RppAdvise
        — named decisions; each one is a "when", not a "how"
      ──────────────────────────────────────────────
  L2  rpp/core.ring
        RppBuffer  RppView  RppBytes  RppState
        — owns lifetimes, checks bounds, caches addresses
      ──────────────────────────────────────────────
  L1  rpp/probe.ring          the declared compatibility surface
        the ~20 primitives Ring++ rests on, each with a
        behavioural probe and a degradation policy
      ──────────────────────────────────────────────
  L0  Ring VM                 untouched, unforked, any 1.2x
```

### Where the boundary is

Three rules, chosen so a reader can see the seam without a manual:

1. **Every Ring++ name begins with `Rpp`.** No exceptions, no aliases
   without the prefix. Grep is the audit tool.
2. **Ring++ never takes or returns a large string by value.** Anything
   big crosses as an `RppBuffer` or `RppView` — objects, which are
   lists, which cross by reference (F-5). A function that accepts a
   `cString` parameter is, by construction, not a Ring++ hot path.
3. **Anything that can kill the process ends in `Unchecked`.**
   `oBuf.Poke(n, c)` is bounds-checked. `oBuf.PokeUnchecked(n, c)` is
   not, and the word is in the call site forever.

### The one invariant everything rests on

> **An `RppBuffer` owns a Ring string that is created once and never
> reassigned.**

Because: `varptr` on a string returns `pItem->data.pString->cStr`
(`ringapi.c:274`) — a pointer into the String's buffer. `ring_string_add2_gc`
reallocates on growth (`rstring.c:117`) and `ring_string_set2_gc`
reallocates when the new size exceeds capacity (`rstring.c:59`). Either
moves the bytes and leaves any cached address dangling — a silent wrong
answer or a hard crash (F-9 in the safety table). So the buffer's backing
string is written **only** through the pointer, never through Ring
assignment, and growth means *a new buffer plus an explicit copy*, with
the address re-cached.

This is why the buffer must be an object with the string as an
attribute: attributes are the only place where Ring++ can hold both the
string and the address, keep them in step, and reach the string with
`varptr` (F-2).

---

## 3. The surface

Each facility below names the Ring primitive it rests on. Nothing here
is invented; the value added is *which one, when, and with what check*.

### Group A — Buffers and views (the O(1) slice)

| Ring++ | rests on | what it adds |
|---|---|---|
| `RppBuffer(nBytes)` | `space` (`genlib_e.c:1354`), `varptr` | allocates once, caches the base address once, records capacity |
| `oBuf.Poke(nOff, cBytes)` | `setptr` + `memcpy` | bounds check before the write; closes F-1 (a `memcpy` onto a string is a silent no-op) and F-7's crash |
| `oBuf.Peek(nOff, nLen)` | `ptr2str` | bounds check before the read; closes the silent over-read. **The O(1) slice: 0.09 µs where `substr` costs 12.5 µs on a 500 KB string** |
| `oBuf.View(nOff, nLen)` | address arithmetic only | **zero-copy window**; the parser primitive |
| `oView.Peek/Byte/Sub` | `ptr2str`, `getptr` | a slice that costs nothing until you materialise it |
| `oBuf.Str()` | `ptr2str(p, 0, n)` | the *explicit* exit back to an ordinary Ring string. Named so the copy is visible. |
| `oBuf.Grow(n)` | new `space` + `memcpy` | the only legal resize; re-caches the address |
| `oBuf.LoadFile / SaveFile` | `fread`/`fwrite` | fills a buffer without a round trip through a Ring string |

`RppView` is the piece that earns the project. A tokeniser over a 10 MB
document holds one buffer and walks views; nothing is copied until a
token is actually needed as a Ring value. Today the same loop in pure
Ring pays `substr`'s 12.5 µs per slice on a 500 KB input — and that
figure scales with the document, so it gets worse exactly where it
matters (F-6).

### Group B — Bytes and packing

| Ring++ | rests on |
|---|---|
| `oBuf.PokeInt32 / PeekInt32` | `int2bytes` / `bytes2int` (`file_e.c:31,34`) |
| `oBuf.PokeDouble / PeekDouble` | `double2bytes` / `bytes2double` |
| `oBuf.PokeFloat / PeekFloat` | `float2bytes` / `bytes2float` — *registered, and missing from the brief's list* |
| `RppHex(c)` / `RppUnhex(c)` | `str2hex` / `hex2str` |
| `RppHash(c)` | `murmur3hash` (`math_e.c:26`) |
| `RppBytesOf(x)` / `RppEndian()` | `bytes`, probe-detected byte order |

Ring's packing functions are already correct and already cheap. Group B
is a naming and endianness layer, not an optimisation. It should say so.

### Group C — List phases

| Ring++ | rests on | what it adds |
|---|---|---|
| `RppIndexed(aList)` … `.Release()` | `ringvm_genarray` (`vminfo_e.c:365`) | **refuses below the break-even**, and detects staleness |
| `RppRows(nRows, nCols)` | `list(r, c)` (`list_e.c:208`) | the 6× 2D idiom (F-12), named |
| `RppAppend` guidance | plain `+` | documents that appending beats preallocation for flat lists (F-12) |

`RppIndexed` is the whole philosophy in one object. It is a **phase**,
not a property (F-10). It refuses to act when the list is small enough
that the array cannot pay for itself; it records `len()` at entry and
warns on `Release()` if the list changed underneath. Honest limitation,
measured: **`sort()` invalidates the array without changing the size**
(verified: 0 ms → 36 ms), so the size check catches adds, deletes and
inserts but not sorts and reverses. The documentation must say that in
those words.

### Group D — Sub-interpreters

| Ring++ | rests on | what it adds |
|---|---|---|
| `RppSandbox()` | `ring_state_init` | a second, isolated VM: 0.35 ms to create (F-13) |
| `.Run(cCode)` | `ring_state_runcode` | a Ring error inside does **not** kill the host |
| `.Get(cName)` | `ring_state_findvar` | **lowercases the name** — closes F-3, the silent `0` |
| `.Set(cName, v)` | `ring_state_setvar` | |
| `.Quiet()` | `ringvm_hideerrormsg` inside the state | |
| `RppSyntaxOk(cCode)` | `ring_state_scannererror` | a syntax verdict **without running** the code |
| `RppTokens(cCode)` | `ring_state_stringtokens` | Ring's own scanner, as a list, with no extension |

This is the most under-used thing in Ring and the brief is right about
it. But it must be sold for what it measured as: **containment, not
speed.** The same work ran 42 ms in a fresh sub-state versus 24 ms in the
host. Its uses are sandboxing generated or user-supplied Ring, giving a
risky computation a blast radius, syntax-checking a snippet before
`eval`, and tokenising Ring source for tools.

### Group E — Introspection (diagnostics only, never a hot path)

`RppVmInfo()` over `ringvm_info`; `RppFunctions()`, `RppClasses()`,
`RppCFunctions()` over the corresponding `ringvm_*list`; `RppMemPool()`
over `ringvm_ismempool`. Each of these copies a VM structure into a fresh
list on every call — `ringvm_memorylist` copies every scope twice
(`vminfo_e.c:80-84`). They belong in a diagnostic report, never in a loop.

### Group F — Deliberately not surfaced

| primitive | why hidden |
|---|---|
| `memcpy` with a **string** destination | it silently does nothing (F-1). Ring++ must never make it reachable; `Poke` exists so nobody needs it. |
| raw `setptr` on a Ring++ object's address | the whole safety model is that Ring++ owns the address. Exposed only as `oBuf.AddressUnchecked()`. |
| `obj2ptr` / `ptr2obj` | round-tripping an object through a pointer defeats reference counting; the failure is a use-after-free with no diagnostic. No measured need. |
| `ringvm_runcode` / `runcodeatins` in the host | the sandboxed form (Group D) does the same job with a blast radius. |
| `ringvm_settrace` / trace callbacks | a trace hook on the host VM is a global side effect; violates "no clever global interception." |
| `loadlib` / `closelib` / `ringvm_translatecfunction` | Phase 5 territory (§6), never in the core. |
| `ringvm_writeringo` / `ringvm_ringolists` | object-file surgery. Interesting, no measured need, high blast radius. |
| `callgc` | it is `ring_vm_gc_deletetemplists` (`genlib_e.c:1282`), not a general collector. Exposing it under a friendly name would teach the wrong model. |

### Findings that would need a VM change — reported, not worked around

These are **findings**, listed separately per constraint 1. Ring++ does
not depend on any of them being fixed; the draft text for the Google
Group is in [UPSTREAM_NOTES.md](UPSTREAM_NOTES.md).

- **VM-1** `memcpy(cRingString, …)` silently writes the discarded stack
  copy. Either error on a string destination, or document it. Currently
  it reads as working code that does nothing.
- **VM-2** `ring_state_findvar` reports "not found" as the number `0`,
  which is indistinguishable from a variable whose value is `0`. ~~And it
  requires the identifier already folded to lower case~~ — **the case
  half is fixed upstream** (2026-08-14,
  [`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094)),
  and it turned out to affect four functions: `varptr`, `findvar`,
  `setvar` and `newvar`. The `0`-for-absent half stands. See F-3.
- **VM-3** `ptr2str` performs no bounds check and will happily return
  4096 bytes of adjacent heap from a 16-byte buffer. A length is
  impossible to know in general, so this may simply be documentation —
  but it is currently a silent information-disclosure primitive.
- **VM-4** There is no way to ask a list whether it currently has an
  items array, and no `ringvm_deletearray` to drop one. A read-only
  predicate would let a library detect staleness precisely instead of
  guessing from `len()`.
- **VM-5** `RING_VM_STACK_PUSHCVAR` copies string arguments (the ≈2,200×).
  Already drafted for upstream by RingScript
  (`D:\GitHub\ringscript\docs\UPSTREAM_CASE.md`). Ring++ is designed to
  work around it, not to wait for it.

---

## 4. Safety

Pointer territory, and the measurements are unforgiving (FINDINGS Part 5).

**What can happen, measured:**

| failure | observed |
|---|---|
| read past the end | 4096 bytes of adjacent heap returned as a normal Ring string. Exit code 0. |
| write past the end | process death. Exit 1. No message, no line number, no traceback. |
| read a pointer whose variable left scope | garbage returned silently. Exit 0. |
| read a wild address | process death. **`try/catch` does not catch it.** |

Ring's `try/catch` traps VM errors, not access violations. Once the
primitive is called, there is nothing left to check. So:

**What Ring++ prevents.** Every offset and length is checked *in Ring,
before* the primitive is called, against a capacity the buffer itself
recorded at construction. The cost is a handful of comparisons — the
same order as the 97 ns the `memcpy` costs — and it is paid everywhere
except on explicitly named `…Unchecked` entry points. This turns three of
the four rows above into a catchable Ring error with a line number.

**What Ring++ cannot prevent.**

- A buffer whose owning object is garbage-collected while a `View` or a
  raw address is still held. Ring++ mitigates by making views hold a
  reference to their buffer, so the buffer cannot die first; it cannot
  stop a user who extracted `AddressUnchecked()`.
- Anything reached through `…Unchecked`, by definition.
- A crash inside a *sub-state* is still a process crash: sub-states
  contain **Ring errors**, not signals (F-13).
- Concurrent mutation of a buffer from threads. Ring++ is single-VM,
  single-thread; the list cursor is already disabled under
  `lUsingThreads` (`rlist.c:185`) and Ring++ takes no position beyond
  documenting that it is not thread-safe.

**How failures are reported.** One mechanism, no exceptions: `raise()`
with a message of the shape
`Rpp: <op> out of range — offset N, length L, capacity C`. It carries
the three numbers that let a reader fix it, and it is catchable. Silent
degradation is forbidden — the Softanza precedent below is precisely
why.

**The precedent, from Mansour's own code.** In
`stzlib\core\system\stkPointer.ring:712-728`, `InitializeLowLevelAccess`
does `varptr(:cBufferData, :char)` while the local variable is named
`_cBufferData_`, inside a `try/catch` that sets `@pLowLevelPtr = NULL`
on failure. Verified in isolation: a `varptr` on a name that does not
exist raises `Error (R6) : Variable is required`. So that catch fires,
and the whole low-level path is dead — silently, permanently, and the
class keeps working through its string fallback. Even if the name were
right, the pointer would target a local that dies when the method
returns.

That is not a criticism of Softanza; it is the best available evidence
that this surface cannot be used safely by hand, and it is why Ring++'s
error policy is *raise, never swallow*.

---

## 5. Surviving Ring 1.28 and 1.35

Constraint 2 is the hardest one, and it is met by making the exposed
surface small and *behaviourally* verified rather than
version-sniffed.

### The declared compatibility surface

Ring++ depends on exactly these, and nothing else:

```
space  varptr  getptr  setptr  nullptr  ptrcmp  memcpy  ptr2str
int2bytes  bytes2int  float2bytes  bytes2float  double2bytes  bytes2double
str2hex  hex2str  murmur3hash
list  len  raise  clock  clockspersecond
ringvm_genarray  ringvm_info  ringvm_cfunctionslist
ring_state_init  ring_state_delete  ring_state_runcode
ring_state_findvar  ring_state_setvar
ring_state_stringtokens  ring_state_scannererror
```

Roughly 30 names. Each one is a row in `rpp/probe.ring`.

### The conformance suite — behaviour, not version numbers

`rpp/probe.ring` runs at `load` time in well under a second and answers
one question per row: *does this build still behave the way Ring++
assumes?* Not "is it present" — `ringvm_cfunctionslist()` answers
presence — but "does it do the thing":

- write through `varptr` + `memcpy` into a 16-byte buffer and read the
  bytes back — the F-1/F-2 assumption;
- confirm the address from `varptr` is **stable** across a read of the
  variable;
- `ringvm_genarray` on a 200-item list, then confirm a permuted read got
  faster and that one `+` made it slow again — the F-9 assumption, as
  behaviour;
- round-trip every packing pair and record endianness;
- create a sub-state, run `nx = 1`, read it back lower-cased, delete it;
- confirm a sub-state error does not kill the host.

`bench/` is the seed of this suite: those programs are already the
assumptions written as executable statements.

### Degradation policy, per row

Three outcomes, and the choice is fixed per facility at design time so
behaviour never depends on a guess:

| outcome | meaning | example |
|---|---|---|
| **HARD** | the facility is unavailable; calling it raises immediately with the probe's name | `varptr` semantics changed → `RppBuffer` is unavailable |
| **SOFT** | a slower pure-Ring path takes over, and `RppAdvise()` reports the substitution | `ringvm_genarray` gone → `RppIndexed` becomes a no-op wrapper; the code still runs, slower |
| **INFO** | recorded, no behavioural effect | endianness, `ringvm_info` layout |

`ringvm_info` returns a **positional list of 25 values** with no keys
(`vminfo_e.c:310-362`). That layout is exactly the kind of thing a new
release reorders. So it is INFO only, read by field *count* first, and
nothing in Ring++ ever branches on it.

### What happens when a function Ring++ relies on changes

Concretely, three cases:

- **Removed.** `ringvm_cfunctionslist()` no longer lists it. Probe fails
  at load; policy applies (HARD or SOFT); `RppReport()` names the row,
  the Ring version, and the consequence.
- **Signature changed** (an extra argument, a different return shape).
  The probe calls it for real and compares the result; a shape change
  fails the probe like a removal.
- **Behaviour changed silently** — the dangerous case, and the reason
  probes assert *outcomes*. If `varptr` ever returns a copy instead of
  the live buffer, the write-and-read-back probe catches it in the first
  second of the first program, not in a customer's ledger three months
  later.

**Version detection is a label, not a gate.** Ring++ records
`RppRingVersion()` for the report and never branches on it. A build
that passes the probes is supported whatever it calls itself; a build
that fails them is not, whatever it calls itself. That is what makes
"survive upgrades untouched" achievable rather than aspirational: the
suite tells you in seconds, and the answer is not an opinion.

**Upgrade gate.** A new Ring release is "supported" when
`ring probe.ring` is green **and** `bench/` re-runs inside the recorded
tolerances on that build. Both are minutes of work, and both are in the
repository from Phase 0.

---

## 6. The Zig build

Constraint 3 says Zig is the ally for packaging and no dependency the
user must install. The most useful thing I can say here is the thing the
measurements permit:

> **For Phases 0–4, Ring++ produces no build artifact at all, and that
> is the strongest possible form of "no dependency the user must
> install."**

It is pure Ring. `load "ringpp.ring"` on Windows, Linux, macOS, and in
RingScript's WASM build, with the *stock* `ring.exe` already on the
machine. A `build.zig` that produced nothing would be theatre.

Zig earns its place at three specific points, none of them on the user's
critical path:

**(a) The upgrade matrix — Phase 4, maintainer-only.** The claim "Ring++
survives 1.28" is worth what it can be demonstrated on. `build.zig`
compiles the Ring VM from a source tree (the 43-file C core builds
cleanly under `zig cc` — RingScript proved it, including `wasm32-wasi`)
and produces one `ring` binary per version under test. Then
`zig build conformance` runs `probe.ring` and `bench/` against each.
Installed on the maintainer's machine: **Zig only**. No MSVC, no
CMake, no Qt — the VM core needs none of them.

**(b) The optional accelerator — Phase 5, opt-in, never required.**
If, and only if, a Phase-4 measurement shows a specific loop where the
pure-Ring implementation cannot reach, `build.zig` cross-compiles one
small extension exporting a handful of `RING_API` functions, and Ring++
`loadlib`s it *when present*, falling back to the pure path when absent.
`zig cc` cross-compiles to every target from one host without an SDK,
which is exactly why this is possible at all — and it stays behind a
gate that must first prove the pure path insufficient.

**(c) Delivery — Phase 6, optional.** `ring2exe` already exists;
Softanza's delivery plane already does this properly. Ring++ should
contribute a payload, not a second delivery mechanism.

**No `build.zig.zon`, nothing fetched at build time**, matching
RingScript's `build.zig`. The Ring source tree used by (a) is vendored or
pointed at by path, never downloaded during a build.

---

## 7. `myctiger` — what it got right, why it stopped, and why Ring++ is not it

*Source: `github.com/ringpackages/myctiger`, read in full. It is roughly
90 lines of Ring — `src/lib/classes.ring` (1.8 KB), `functions.ring`,
`globals.ring` — plus a vendored 190 KB TCC and a byte-exact test
harness.*

**What it got right, and got right beautifully:**

- **Zero new syntax.** `Tiger { … }` is Ring's brace scoping;
  `braceExprEval` receives every expression statement whose value is
  discarded, so a bare string literal becomes `printf(...)`. `` C `…` ``
  is an *attribute named `C`* whose `getC` accessor flips a flag, so the
  next backtick literal is routed to raw injection. A DSL keyword built
  out of Ring's getter magic, in three lines.
- **Ring as a staging language.** `for t = 1 to 5` inside the block runs
  at generation time and *unrolls* into five `printf` lines in the `.c`.
  That is real multi-stage programming, and it is the genuinely good idea
  in the project.
- **The toolchain is vendored.** TCC ships in `tools/`, 190 KB, no
  install. Mahmoud reached the same conclusion as constraint 3, in 2025,
  with a smaller hammer.
- **Byte-exact tests.** `tests/correct/` versus `tests/current/` —
  the same discipline as RingScript's oracle.

**Why I think it stopped.** Three structural reasons, in order of
weight:

1. **The generated program cannot talk back.** Ring values are baked in
   as literals; nothing the C program computes can return to the Ring
   program that generated it. So it is a C-program *generator*, not a
   Ring *accelerator* — it cannot answer "my Ring loop is too slow."
2. **`braceExprEval` only sees discarded expression values**, so the
   expressible surface is strings and literals. Every real C
   construct — a declaration, a type, a function, a struct — has to be
   written as raw C in backticks, at which point you are writing C in a
   string with none of Ring's help. The abstraction dissolves exactly
   where it would have to be strongest.
3. **No composition.** No Tiger functions mapping to C functions, no
   expression model, no types. It stops at `printf`, and the three test
   scripts (`hello`, `helloc`, `test`) show it never met a real workload.

Mahmoud labelled it "Prototype of the idea" himself. I read it as an
idea correctly identified and deliberately parked.

**Is code generation the right shape for Ring++?** No — and the brief's
instinct is right for a reason the measurements make concrete.

The brief's premise is *"a programmer hits a wall inside an existing
Ring program."* Generation requires leaving the program, and every
generation design must then answer "how do the values get in and out."
The answer is marshalling, and marshalling is precisely the expensive
thing: ~750 µs to move 1 MB across one call boundary (F-5). A generated C
function called in a hot loop would pay Ring's C-call overhead plus
argument copying, and would have to be enormously better at its job to
win back what the boundary costs.

There is one place generation genuinely fits, and it is where myctiger
was pointing: **generating a Ring C-extension** — a real `.dll`/`.so`
registering `RING_API` functions that the same program `loadlib`s. Same
process, no marshalling wall beyond the ordinary C-function boundary,
and Ring already supports the whole path. That is §6(b), Phase 5,
opt-in, and gated on a measurement that proves the pure path
insufficient. It is a *later escape hatch*, exactly as the brief
suspected — not the shape of the thing.

---

## 8. Softanza — independent, and its first consumer

**Recommendation: Ring++ is independent of Softanza. Softanza's
`stkBuffer` / `stkPointer` are then reimplemented on top of it.**

Three reasons, all evidential.

**1. The promise is `load` and go.** Ring++'s reason to exist is that
a programmer in a hot loop can reach for it in the same file. Making it
a layer inside an 11,000-line system module (or a much larger library)
means every user of Ring++ takes on Softanza. That is a fine trade for a
Softanza user and a fatal one for everyone else — and it is the everyone
else that makes findings credible when they reach the Google Group.

**2. Constraint 2 becomes unachievable.** "Survives Ring upgrades
untouched" is a claim about a ~30-name surface with a probe per name
(§5). Inherit Softanza's surface and the claim becomes a claim about
Softanza, which is not a claim Ring++ can keep.

**3. Softanza's system module is the evidence for the split.** Studied
in full:

- `stkBuffer` (22 KB) is a Ring string with a bounds-checked API. Its
  `Write` is `left(@buffer, n) + data + right(...)` — O(n) per write, the
  803 ms shape from F-7. It never touches `varptr` or `memcpy`.
- `stkPointer` (22 KB) does reach for the low-level layer, and its one
  entry point into it is dead: `varptr(:cBufferData, :char)` against a
  local named `_cBufferData_`, inside a `try/catch` that silently sets
  the pointer to `NULL` (§4). Even with the name corrected, the target
  is a method-local string that is freed when the method returns.
- Across the whole of `stzlib`, `varptr` appears **7 times**, six of them
  in `-copy` files.

The reading is not that this is bad code. It is that **the raw surface
defeated its author**, in his own library, and did so *silently* — which
is the exact argument for Ring++, made by the strongest possible
witness.

**What Ring++ inherits from Softanza's style** — this part is genuinely
good and should be kept:

- a thin façade class over a core class (`stz…` over `stk…`) → Ring++'s
  `idioms` over `core`;
- `…Q()` constructor functions so an object can be built and used in one
  expression → `RppBufferQ(n)` alongside `new RppBuffer(n)`;
- short aliases beside long names, at the façade only, never in the core;
- **named constants instead of magic numbers** — Ring++ has real ones to
  name: `RPP_APPEND_CROSSOVER = 512` (F-8), `RPP_INDEX_MIN_READS = 20`
  (F-10), `RPP_POOL_L3 = 512` (`pooldata.h:29`);
- validate at the boundary and `raise()` a message a human can act on.

**What it does differently:**

- **Raise, never swallow.** No `try/catch` that degrades in silence.
  Every probe result is reportable through `RppReport()`.
- **Own the lifetime.** A Softanza `stkPointer` points at whatever it was
  handed; an `RppView` holds a reference to the `RppBuffer` that owns
  its bytes, so the bytes cannot be freed while the view lives.
- **No IDs.** `stkBuffer` addresses buffers by string ID through a
  container; Ring++ passes the object, which crosses by reference for
  free.
- **Refuse when it would be slower.** `RppIndexed` on a 40-item list, or
  a `Poke` loop below 512-byte chunks, should say so via `RppAdvise()`.
  No Softanza class currently tells its caller it is the wrong tool.

**The joining move.** Once Ring++ is at Phase 3, `stkBuffer.Write`
becomes an `RppBuffer.Poke`, and Softanza's memory framework gets F-7's
803 ms → 1 ms for free. That is the migration that proves Ring++ is real,
and it is why "independent" costs Softanza nothing.

---

## 9. Honest risks — and what should make you abandon this

**R1 — Building for the wrong shape.** The *need* is settled: Ring++
exists to remove Ring's weakness in performant, data-intensive work —
banking, government, consumer platforms, with the volumes, optimisation,
ML and AI that come with them. The residual risk is narrower and more
real: **building facilities that do not match the shapes those domains
actually have.** The measured evidence that this risk bites is already
in hand — a packed numeric array, the obvious thing to build for ML
work, is **2.2× slower** than an ordinary Ring list until the loop
around it is compiled (F-15). Ship it early and you have made things
worse while feeling productive.

*Mitigation, not abandonment:* every facility lands with the pattern it
hurts measured on the same build, and `RppAdvise` says *no* at runtime
when the caller is on the wrong side of a break-even. `RppArray` waits
for the compiler.

**R2 — The surface is one refactor from disappearing.** Everything rests
on `varptr` returning `pItem->data.pString->cStr` and on `space()`
producing a string whose buffer does not move. Both are internal details
that happen to be observable. A future release that interns strings, or
copies on write, or compacts the pool, would take Ring++'s foundation
away with no ill intent and no warning. The probes turn that from a
silent catastrophe into an immediate, named failure — but they cannot
prevent it. *Abandon if:* an upstream direction is announced that makes
string buffers non-stable.

**R3 — Ring++ teaches a dangerous habit.** Making pointer work pleasant
means more Ring programmers doing pointer work, and F-7's second row
is a process death with no message. A library that is 95% safe in a
domain where the 5% has no diagnostic may be worse than no library.
Mitigations: the `Unchecked` suffix, buffers owning lifetimes, and
`RppAdvise` saying *no*. *Abandon if:* Phase 2's fuzz gate cannot get a
crash rate of zero through the checked API.

**R4 — Ring gets faster and the reason evaporates.** RingScript has
already drafted the `PUSHCVAR` case upstream. If Mahmoud takes it, F-5's
≈2,200× and F-6's ~140× both collapse, and two of Ring++'s three
pillars go with them. F-7 (in-place patching) survives, but one pillar
is a utility, not a project. *This is a risk I would happily lose to* —
and it argues for sending the findings early rather than building on
top of them.

**R5 — The naming discipline erodes.** The `Rpp` prefix and the
`Unchecked` suffix are the entire visibility story. The first convenience
alias that drops them turns the visible seam into an invisible one.
*Abandon the convention, and the project's second stated property is
gone.*

**R6 — Measuring on one machine.** Every number here is Windows 11, one
x64 laptop, one build. The 512-byte crossover in particular is an
allocator and cache artefact and will move on Linux, on ARM, and in
WASM. Phase 4's matrix exists to find out; until it runs, the constants
in Group C and F-8 are provisional and should be documented as such.

**What would make me say "do something else instead."** Not the absence
of workloads — the domains supply those. The signals that would actually
mean *stop* are: R2 (a Ring release makes string buffers non-stable, and
the foundation goes), R3 (the P2 fuzz gate cannot reach a zero crash
rate through the checked API), or R4 (upstream takes the `PUSHCVAR`
case and two of the three pillars collapse — a loss worth having).

In any of those cases the residue is still valuable and already
half-written: publish [FINDINGS.md](FINDINGS.md) and
[UPSTREAM_NOTES.md](UPSTREAM_NOTES.md) to the Ring Google Group as
*documentation of an undocumented surface*, and ship the probe suite as
a standalone diagnostic. The traps in Part 1 are real, they are
invisible, one of them is a **process-killing bug** (F-14), and another
is currently sitting silently in Softanza.
