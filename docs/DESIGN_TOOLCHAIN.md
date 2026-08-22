# Ring++ II — the toolchain half

*August 11, 2026. The second half of Ring++: a vendored VM, a type
checker, compilation, a static analyser, a multiplatform build, and one
CLI. Written after measuring the headroom rather than assuming it.*

**Read [DESIGN.md](DESIGN.md) first.** That is the library half. This
document only makes sense on top of it, and §2 explains why the two are
one project rather than two.

---

## 0. What I think — the short answer

**Yes, with one reframing, one discovery, and two refusals.**

**The reframing.** This is not "a library, and separately a compiler."
The compiled half cannot get its data in cheaply without the library
half. A native kernel called from Ring costs ~43 ns to enter — but hand
it a 1 MB string and you pay ~750 µs to copy the argument (F-5), which
erases any conceivable speedup. **`RppBuffer` is the calling convention
of the compiled half.** Typed native code takes buffer addresses and
lengths, never Ring strings. That is what makes the two halves one
design instead of two projects sharing a name.

**The discovery, and it is a good one.** Ring's parser already accepts
type annotations — deliberately, with a comment saying so:

```c
/* Support Type Identifier */
if (nStart && ring_parser_isidentifier(pParser)) {
        cToken = pParser->cTokenText;
        ring_parser_nexttoken(pParser);
}
```
> `stmt.c:1217` and `:1232`, in `ring_parser_paralist`

So `int func Sum(int x, int y)` compiles and runs today on stock
`ring.exe` — the parser takes the type, throws it away, and keeps the
identifier. And the annotations are **recoverable**, from Ring, with no
extension: `ring_state_stringtokens` returns them verbatim
([`bench/12_typehints_channel.ring`](../bench/12_typehints_channel.ring)):

```
[4] int      <- the annotation, preserved in the token stream
[0] 9        <- keyword: func
[4] sum
[1] (
[4] int      <- parameter annotation, preserved
[4] x
```

This is the same shape as `ringvm_genarray`: **Mahmoud built the
channel, documented it as "no type checking will be done by the
compiler", and left it for someone to consume.** Ring++ consumes it.
No new syntax, no fork, and — the property that matters most —
**annotated Ring++ source still runs unchanged under stock `ring.exe`.**

**Refusal 1: no tracing JIT.** Argued in §5. Julia's speed comes from
type inference plus LLVM, and Julia *ships LLVM*. A hand-written
tracing JIT for Ring means per-architecture encoders, W^X memory, and a
second semantics to keep byte-identical with the first. What delivers
Julia's *outcome* is compile-and-cache, and I measured it at **130 ms**
per kernel with `zig cc`. That is a JIT in every way the user
experiences.

**Refusal 2: no second language.** Every Ring++ construct must be legal
Ring that stock Ring runs correctly, if slower. The moment `ringpp` is
required to run the source, this stops being loyalty to Ring and becomes
a fork with better manners.

---

## 1. The measured case for compiling at all

Three kernels, identical algorithms, Ring 1.27 interpreted versus
`zig cc -O2` native
([`bench/headroom/`](../bench/headroom)):

| kernel | Ring | native | ratio |
|---|---:|---:|---:|
| K1 — scalar loop, 20 M iterations of `s += i*b` | 1151 ms | 18 ms | **64×** |
| K2 — dot product, 1 M doubles | 92 ms | 0.96 ms | **96×** |
| K3 — byte scan, count `,` in 5 MB | 645 ms | 0.22 ms | **~3000×** |

K3's three thousand is not a typo and not a trick: the C compiler
vectorises a byte scan, and Ring executes an interpreted loop with a
string-index opcode per byte. That is what a compiler buys.

Put beside the library half's numbers, the picture is honest:

| | best case | what it costs |
|---|---:|---|
| `ringpp.ring` alone | 95×–2200× on *specific structural* problems | one `load`, 0 MB |
| compiled kernels | 64×–3000× on *any numeric or byte loop* | a 332 MB toolchain |

The library half wins where Ring's *representation* is wrong. The
compiled half wins where Ring's *execution* is slow. Neither replaces
the other, and a project aimed at critical, data-intensive software
needs both.

### And the constraint that shapes everything

Per-call boundary cost, measured (F-4): entering a C function from Ring
is **~43 ns**. So a compiled kernel must do enough work per call to
dwarf that, and must not be handed anything Ring would copy. Two rules
fall out, and they are architectural, not stylistic:

1. **Compiled functions take scalars, buffer handles, and lengths.**
   Never a Ring string. Never a Ring list by value.
2. **The unit of compilation is a loop nest, not a statement.** A
   compiled `add(a,b)` is slower than the interpreted one. A compiled
   `SumColumn(oBuf, nRows, nCol)` is 96×.

---

## 2. Ring already contains the compiler front end

The most surprising result of this session's reading is how little
Ring++ has to build. Everything a front end needs is reachable **from
Ring, with no extension**:

| need | Ring primitive | verified |
|---|---|---|
| source → tokens, **type annotations preserved** | `ring_state_stringtokens` | [`bench/12`](../bench/12_typehints_channel.ring) |
| syntax verdict without running | `ring_state_scannererror` | [`bench/06`](../bench/06_substates.ring) |
| source → bytecode | `ringvm_codelist` — 442 instructions from a 20-line file | [`bench/13`](../bench/13_bytecode_channel.ring) |
| symbol table | `ringvm_functionslist` (name, PC, file), `…classeslist`, `…packageslist` | [`bench/13`](../bench/13_bytecode_channel.ring) |
| bytecode → file, file → bytecode | `ringvm_writeringo` / `ringvm_ringolists` — round-tripped 442 entries exactly | [`bench/13`](../bench/13_bytecode_channel.ring) |
| compile without running | `ring file.ring -norun -go` → `.ringo` | verified |
| isolated compilation | `ring_state_init` + `ring_state_runcode`, 0.35 ms, errors contained | F-13 |
| load native code | `loadlib` → a DLL exporting `ringlib_init(RingState*)` (`dll_e.h:30`) | verified |

**So Ring++ never writes a Ring parser.** It reads Ring's own tokens and
Ring's own bytecode. This is what makes constraint 2 — surviving Ring
upgrades — even thinkable for a toolchain: when Ring 1.35 changes the
grammar, Ring++'s front end changes with it automatically, because it
*is* Ring's front end.

The Zig side's job is therefore narrower and more honest than "write a
compiler": **host the VM, be the build system, and be the native
back end.**

---

## 3. The type system

Three levels, and the level is a property of the *function*, not of the
project.

### Level 0 — hint (what Ring does today)

`int func Sum(int x, int y)`. Parsed, discarded, no checking. Ring++
changes nothing here; source at level 0 keeps working.

### Level 1 — checked

`ringpp check` reads the annotations from the token stream, infers
within the function body, and reports mismatches — statically, with a
file and line. **Runtime behaviour is unchanged.** This is the level
almost all code should sit at, and it is where the value/effort ratio is
best: it costs no toolchain, no compilation, and no risk.

### Level 2 — compilable

A function is **Rpp-compilable** when everything it touches has a
concrete machine type. This is Julia's "type-stable function" idea,
made explicit instead of inferred:

- every parameter, local and the return value is one of:
  `int`, `double`, `bool`, `byte`, or an `RppBuffer` / `RppView` handle;
- it calls only other compilable functions, or nothing;
- no `eval`, no dynamic attribute access, no `ringvm_*`, no object
  allocation, no exceptions;
- loops have integer induction variables.

Everything else stays interpreted, forever, with no penalty and no
warning fatigue. **The default is interpreted. Compilation is opted
into per function**, in the same spirit as `ringvm_genarray` being
opted into per call site.

### What hints cannot say, and how to say it

Ring's hint vocabulary is fixed (`typehints.ring` is 1,271 bytes of
`int = :int`). For anything beyond a type, Ring++ uses a marker inside a
**Ring comment**, which stock Ring ignores completely:

```ring
#@rpp compile target=native,wasm
double func DotProduct(RppBuffer oA, RppBuffer oB, int nLen)
    ...
```

A comment is the only extension channel that is guaranteed invisible to
every Ring version, past and future. Nothing in Ring++ ever requires a
token Ring would reject.

### The correctness problem, and the only acceptable answer

**Ring does not enforce annotations.** A caller can pass a string to
`int func Sum(int x, int y)` and the interpreter will happily
concatenate. If the compiled version assumed `int`, the two would
disagree — and a library that silently changes results under
compilation is worse than no library.

So: **every compiled entry point validates its arguments at the
boundary and falls back to the interpreted function on any mismatch.**
A type-tag check per argument is a few nanoseconds against a call that
must already be doing microseconds of work to be worth compiling. This
is the deoptimisation guard, and it is non-negotiable.

The gate that enforces it: **every test and benchmark must produce
byte-identical output with compilation on and off.** If they differ, the
compiler is wrong, not the interpreter. Same discipline as RingScript's
byte-exact oracle, applied to a different axis.

---

## 4. Compilation: one pipeline, two triggers

```
  annotated Ring source
        │
        ├─ Ring's scanner  (ring_state_stringtokens)      ← not ours
        ├─ Ring's compiler (ringvm_codelist / .ringo)     ← not ours
        │
        ▼
  rpp/analyse   type check + compilability decision      (pure Ring)
        ▼
  rpp/emit      typed IR → C source                      (pure Ring)
        ▼
  zig cc -O2 -shared   → .dll / .so / .dylib             (vendored Zig)
        ▼
  loadlib → ringlib_init(RingState*) registers the kernel
        ▼
  guarded dispatch: types match → native, else interpreted
```

**`ringpp build`** runs this ahead of time for every compilable
function, for every target.
**`ringpp run`** runs it on first call, and caches.

Same pipeline. The only difference is when it fires.

### Why generate C rather than machine code

- One back end for every target Zig supports, from one host, with no
  SDK — the same property that made RingScript's `build.zig` possible.
- No per-architecture instruction encoder, no W^X page dance, no
  unwinder.
- The generated C is **readable and diffable**, which matters enormously
  when the gate is "byte-identical output". `ringpp build --emit-c`
  should be a supported, documented output.
- It is the myctiger idea, aimed at the target that can talk back: not
  a standalone `.exe`, but a **Ring extension the same program loads**
  (`ringlib_init`, `dll_e.h:30`). That is the shape myctiger was
  pointing at and could not reach, because a generated program cannot
  return a value to the program that generated it (DESIGN §7).

### The "JIT", named honestly

Measured on a quiet machine, minimum of 6 warm runs
([`bench/toolchain/`](../bench/toolchain)):

| | zig 0.15.2 | zig 0.16.0 |
|---|---:|---:|
| **first ever, empty cache** | **41.6 s** | **55.2 s** |
| warm, `-O2` | 220 ms | 324 ms |
| warm, `-O0` | 294 ms | 400 ms |

So: **~220 ms per kernel, once.** Cache key = hash(generated C) + type
signature + target triple. First call to a hot function pays 220 ms;
every later call in that run, and **every later run of the program**, is
native and free. That is exactly Julia's "time-to-first-plot" trade, and
it is honest to call it *compile-and-cache*, not a tracing JIT.

**Two operational facts the measurement forced out, both shipping
requirements rather than tuning:**

- **The first compile on a fresh machine costs 40–55 seconds**, because
  Zig builds `compiler_rt` and the target libc before it can link
  anything. That is once per (target, Zig version) — and it must be paid
  by `ringpp vendor install`, which **pre-warms the cache by compiling a
  throwaway kernel for every configured target**. A user's first
  `ringpp run` must never sit through it. Nothing in a JIT design
  survives a 45-second first call.
- **`-O0` is slower to compile than `-O2`** (294 ms vs 220 ms) — larger
  output, link dominates. So there is no "fast debug compile" flag to
  reach for; if the edit-run loop needs to be quicker, it needs a
  smaller compiler (Tier 2), not a lower optimisation level.

What I explicitly reject, and why:

| approach | verdict |
|---|---|
| tracing/template JIT written in Zig | per-arch encoders, W^X, a second semantics to keep byte-identical. Multi-month, and **no measurement yet says compile-and-cache is insufficient.** Revisit only if one does. |
| ship LLVM | a dependency larger and less pleasant than Zig, for the same result |
| rewrite the VM (register machine, NaN-boxing) | forfeits "same VM as `ring.exe`" — the property that makes every Ring++ finding credible |
| interpret faster (computed goto, per-file `-O2`) | already done and measured in RingScript: **~1.15× on dispatch**. Real, small, and not what this half is for. |

---

## 5. Static analysis — the part I would build first

`ringpp check` is the highest value per unit of effort in this entire
document. It needs no toolchain, no compilation, and no risk, and it
is the natural home for everything the first half discovered.

**Four rule families:**

**(a) The traps from [FINDINGS.md](FINDINGS.md).** These are the rules
nobody else can write, because nobody else measured them:

| rule | from |
|---|---|
| `memcpy` with a string destination is a silent no-op | F-1 |
| `varptr` inside a loop — 790 ns/call, hoist it | F-4 |
| a large string passed by value to a function | F-5 |
| `substr` on a large string in a loop — use `RppView` | F-6 |
| `ringvm_genarray` inside a loop that also mutates the list | F-9, F-10 |
| ~~`ring_state_findvar` with a non-lower-case name~~ — **dropped**: fixed upstream 2026-08-14, and it was four functions, not one. Folding the name is correct on every version, so `RppSandbox` just does it. | F-3 |
| `ptr2str` with a length not provably within bounds | F-5, safety |
| building a string by `memcpy` in chunks under 512 bytes | F-8 |

**(b) Type-hint conformance** — level 1 above.

**(c) The compilability report.** Julia's `@code_warntype`, and the
feature that makes the type system *learnable* rather than mysterious:

```
ringpp why SumColumn

  SumColumn (ledger.ring:214) — NOT compiled
    ✗ parameter aRows has no annotation (inferred: list)
    ✗ calls FormatMoney (ledger.ring:88), which is not compilable
    ✓ nCol : int
    ✓ loop induction variable i : int
  Fix the two ✗ above and this function compiles.
  Estimated: 40–90× on the measured shape of its inner loop.
```

Without this, "why is my code still slow?" has no answer and the whole
typed half is folklore. With it, the path is mechanical.

**(d) Hygiene from the bytecode** — unreachable code, unused locals,
functions never called — read from `ringvm_codelist` sliced by
`ringvm_functionslist` PCs.

### The one thing Ring does not give us: a tree with columns

Ring hands over its scanner, its bytecode, its symbol table and its
object-file format (§2). It does **not** hand over a syntax tree with
source spans: tokens are flat, and bytecode carries line numbers only.
A linter that cannot say *line 720, column 21* is not a linter.

**[`tree-sitter-ring`](https://github.com/ysdragon/tree-sitter-ring)
fills exactly that hole, and it was evaluated rather than assumed**
([`bench/treesitter/`](../bench/treesitter)):

- **Fidelity: zero disagreements with Ring on valid code.** 967/978 of
  Ring 1.27's own test suite parse clean; every one of the 11 failures
  is either the NaturalLib runtime DSL (unsupported by design) or a file
  **Ring itself rejects**. Softanza's `base/system/` is 24/24.
- **Type annotations arrive as named fields** —
  `(typed_parameter type: … name: …)` — with line *and* column. Better
  than re-parsing the token stream, which is what §2 would otherwise
  force.
- **The leading return-type hint is recoverable** without a grammar
  change: `int func Sum(…)` parses as an `expression_statement`
  immediately preceding the `function_definition` — exactly as Ring's
  own parser treats it.
- **Cost: 2.68 MB and 4.4 s to build** with `zig cc -O2`, statically
  linked into the `ringpp` binary. The user installs nothing;
  `ringpp check` stays a Tier 0 command. Softanza already vendors the
  tree-sitter runtime, so the infrastructure cost is zero.

**The bounding rule, and it is not negotiable: tree-sitter is a lens,
not a judge.**

| question | authority |
|---|---|
| Is this valid Ring? | `ring_state_scannererror` / `ring -norun` |
| What does it mean, what does it compile to? | `ringvm_codelist`, `.ringo` |
| Where is it, what shape is it? | **tree-sitter** |

Ring++'s upgrade story (§5 of [DESIGN.md](DESIGN.md)) rests on consuming
*Ring's own* front end, so a second definition of Ring's syntax is
precisely the risk this project set out to avoid. The grammar is also
deliberately **more permissive** than Ring in places — its author
documents that `ok`/`on`/`off` demote in a superset of Ring's
runtime-counter behaviour — and a more permissive parser can never
adjudicate validity.

**Permanent gate:** every file `ringpp check` parses must get the same
accept/reject verdict from `ring -norun`. A disagreement is a bug in the
vendored grammar, never a diagnostic shown to a user. Same discipline as
RingScript's byte-exact oracle, applied to a new axis, and it runs in
seconds.

*It has already paid for itself: the evaluation found four Softanza test
files with unclosed `/*` comments that Ring refuses to run
(`Error (S2)`). Dead test files, nothing reporting it — the first real
`ringpp check` finding, produced before a line of `ringpp check`
existed.*

---

## 6. The CLI

One tool, in the house style of `zin` (banner box, scope line, grouped
commands, availability markers, shortcuts, `doctor` / `info` /
`completions` / `grammar dump`). Full mock-up in [CLI.md](CLI.md).

The one design decision worth stating here: **availability markers carry
the two altitudes.** A user with only `ringpp.ring` and stock
`ring.exe` sees `check`, `fmt`, `info`, `why`, `bench` as available and
`build`, `run --native`, `dist` as `(needs toolchain)`, with
`ringpp vendor install` as the named way to get them. Nothing silently
fails, and nothing is hidden.

---

## 7 — The distribution: tiered, not shaved

The first instinct is to shrink Zig. I tried it properly — build a
minimal tree, wipe the compiler cache, and check that all six shipped
targets still produce a shared library. Full method and scripts in
[`bench/toolchain/`](../bench/toolchain).

**What shaving actually buys:**

| step | result | MB |
|---|---|---:|
| stock install, 6/6 targets build | baseline | 332.5 |
| drop `doc`, `libcxx`, `libcxxabi`, `libtsan`, all BSD header sets | still 6/6 | **295.6** |
| also drop `lib/std` | **0/6 — "unable to find zig installation directory"** | 281.9 |
| keep only `lib/std/std.zig` as a marker | **0/6 — "sub-compilation of compiler_rt failed"** | 281.9 |

`lib/std` cannot go: `compiler_rt` and the C runtime shims are Zig
source compiled on demand and they import it. Per-target trees, each
verified building a real shared library:

| target family | on disk | **zipped** |
|---|---:|---:|
| `aarch64-macos-none` | 206.4 MB | **60 MB** |
| `x86_64-linux-musl` | 209.7 MB | **63 MB** |
| `x86_64-windows-gnu` | 271.8 MB | **69 MB** |
| all targets | 332.5 MB | 89 MB |

So shaving takes a Linux host from 332 → 210 MB on disk and **63 MB to
download**. Worth doing, and that is where it stops: **`zig.exe` alone is
168.5 MB**, because it contains clang and LLVM, and `zig cc` cannot
exist without them. There is no 20 MB version of this road.

### The measurement that changes the question

Same kernels, across optimisation levels
([`bench/toolchain/`](../bench/toolchain)):

Minima of 5 launches, both Zig versions agreeing:

| | K1 scalar | K2 dot product | K3 byte scan |
|---|---:|---:|---:|
| Ring 1.27 interpreted | 1151 ms | 92 ms | 645 ms |
| `zig cc -O0` | **25×** | **23×** | **72×** |
| `zig cc -O1` | 61× | 92× | 3071× |
| `zig cc -O2` | 61× | 94× | 3071× |

**With no optimisation at all, you already get 22–72× over Ring.** The
big toolchain buys the step from 25× to 61×, and — on loops a vectoriser
can see — from 72× to 3000×. That is a real prize, but it is not the
*entry* prize. The entry prize is available from a compiler small enough
to forget about.

*(`-O1` ≈ `-O2` ≈ `-O3`: no reason to go past `-O2`, no penalty for
stopping there. An earlier single-run pass of this table reported `-O3`
and `-Os` as **worse**, and put the `-O0` band at 27–87×; the minima
withdrew both. Third time in this project that single-run timings
produced a wrong conclusion.)*

### So: four tiers, one behaviour

| tier | what you install | kernels run at | cross-compiles |
|---|---|---|---|
| **0 — library** | `ringpp.ring`, ~0 MB | interpreted | — |
| **1 — system compiler** | **nothing** — `cc`/`clang`/`gcc`/MSVC already on the box | 25–3000× | host only |
| **2 — tiny C compiler** | ~1–5 MB, vendored, TCC-class | 22–72× | host only |
| **3 — vendored Zig** | 60–69 MB download, 206–272 MB on disk | 25–3000× | **every target from one host** |

Tier 1 is the one most likely to cost nothing at all: a bank or
government development machine almost always has a C compiler already.
`ringpp doctor` should look for one before proposing any download.

Tier 2 is the myctiger precedent, exactly — Mahmoud vendored TCC at
190 KB in 2025 and it was the right instinct. It also has a property
Tier 3 lacks: a tiny compiler is *fast*, which matters for the
compile-and-cache path.

Note carefully **why** it is fast, because the measurement surprised me:
`zig cc -O0` is **slower** to compile than `-O2` (294 ms vs 220 ms) —
the output is larger and linking dominates. So "pass `-O0` for a quick
edit-run loop" is false. A small compiler is fast because it is small,
not because the optimiser is off. That is an argument for a genuinely
tiny Tier 2 rather than for tuning Zig's flags.

**Caveat, and it is a real one:** the 22–72× above is `-O0` used as a
*proxy* for TCC-class codegen. Before committing to Tier 2, compile the
same three kernels with the actual compiler and confirm — the proxy
could be off in either direction.

Tier 3 earns its 69 MB on exactly two things: **vectorisable loops**
(K3's 87× → 3000×) and **cross-compilation**. If you are shipping one
binary for five platforms from one machine, nothing else does that.

**The rule that keeps this honest:** the tier changes speed, never
semantics. The byte-identical gate (§3) holds at every tier, and
`ringpp doctor` states which tier you are on and what the next one would
buy — in measured multiples, not adjectives.

### What Zig 0.16 changes — and what it does not

*Checked August 11, 2026, because "Zig has dropped LLVM" is in the air
and it would move the floor if true.*

**It is not true yet — and I stopped reading and measured it.** Zig
0.16.0 was downloaded from ziglang.org, SHA256-verified against the
official `index.json`, and run beside 0.15.2 on this machine within the
same hour ([`bench/toolchain/`](../bench/toolchain)):

| | 0.15.2 | 0.16.0 |
|---|---:|---:|
| `zig.exe` | 168.5 MB | **168.9 MB** |
| install on disk | 332.5 MB | **345.6 MB** |
| builds all 6 shipped targets | 6/6 | **6/6** |
| K1 / K2 / K3 at `-O2` | 19 / 0.98 / 0.21 ms | **19 / 0.99 / 0.22 ms** |
| K1 / K2 / K3 at `-O0` | 46 / 4.04 / 8.99 ms | **43 / 4.22 / 8.91 ms** |
| warm kernel compile | 220 ms | **324 ms** (1.5× slower) |
| first-ever compile, empty cache | 41.6 s | **55.2 s** |
| RingScript-era `build.zig` API | OK | **OK, unchanged** |

- **`zig.exe` is the same size** — the plainest possible evidence that
  LLVM has not been removed. Release notes confirm **LLVM 21** inside,
  and `zig cc` still works because `zig cc` *is* clang.
- What actually changed, from 0.15.1 onward: the **self-hosted x86_64
  backend is the default for Debug builds**, making debug compilation
  roughly 5× faster. That affects compiling *Zig*, not C.
- **Kernel performance is identical**, so nothing in the tiering moves.
- **The build API survives**, which was the expensive risk. The 0.15-era
  surface RingScript uses — `createModule`,
  `addExecutable{.root_module}`, `wasi_exec_model`, `rdynamic`,
  `stack_size`, `initial_memory`, `addInstallFile`,
  `resolveTargetQuery`, `addRunArtifact`, custom steps — builds
  unchanged.
- Official 0.16.0 downloads: **93 MiB** windows-x64, **53 MiB**
  linux-x64, **50 MiB** macos-arm64 — the *complete* toolchain,
  xz-compressed, i.e. about what the hand-stripped single-target trees
  above cost (60–69 MB zipped). **Independent confirmation that shaving
  is not where the win is.**

**Recommendation: stay on 0.15.2.** 0.16 buys nothing measurable here
and costs 1.5× compile time. Revisit on a specific need, and keep both
in the P4 matrix.

**The direction is real, though, and it is a design input:**

- [ziglang/zig#20875](https://github.com/ziglang/zig/issues/20875)
  proposes that ziglang.org binaries stop linking clang and LLVM, with
  `zig cc` / `zig c++` / `zig translate-c` moving to a **separate
  project** (`zig-extras cc`).
- [ziglang/zig#16269](https://github.com/ziglang/zig/issues/16269)
  proposes using **Aro** — Zig's own C compiler, written in Zig — to
  compile C when built without LLVM.

**What that would mean for Ring++, if it lands:**

1. The plain `zig` binary gets much smaller, but **`zig cc` leaves with
   LLVM.** Tier 3 would then depend on whatever ships `zig cc`, not on
   `zig` itself. A naming change for us, not an architectural one.
2. An **Aro-based C compiler with no LLVM has no LLVM optimiser**, so no
   vectorisation — which puts it squarely in the **27–87× band measured
   above at `-O0`**. In other words, a future no-LLVM Zig lands
   *exactly* in the Tier 2 slot this design already reserves, and would
   be a far better Tier 2 than TCC (same language, same build system,
   same cross-compilation story, no third vendor).

So the tiering is **robust to this change rather than threatened by
it**: whichever way upstream goes, Ring++ needs a small C compiler for
the entry win and a vectorising one for the top end, and it detects
which it has. That is the whole reason not to design around a single
`zig cc`.

Both of those are now measured, so what remains for the P4 matrix is
**keeping them current**: it carries a Zig axis as well as a Ring axis,
and re-runs `bench/toolchain/` per version so the tier bands above
cannot go stale.

### Vendoring Ring itself is free

The Ring VM source is **1.0 MB** — 43 C files plus headers. Vendoring
the *interpreter* costs nothing worth discussing; only the *compiler*
does. That asymmetry is worth remembering: the reproducible-VM and
conformance-matrix parts of this design (§P4) are cheap, and they are
the parts that make upgrades survivable.

**`build.zig` produces**, with Zig as the only thing installed:

- `ringpp` — the CLI, cross-compiled for Windows x64, Linux x64/arm64,
  macOS x64/arm64 (the five targets RingScript already ships);
- `ring` — the vendored VM built from source, one binary per Ring
  version under test, feeding the conformance matrix
  ([PHASE_PLAN.md](PHASE_PLAN.md) P4);
- compiled kernels for every target of a user's project;
- optionally `ringpp.wasm` — the vendored VM for the browser, which
  RingScript has already proven builds under `wasm32-wasi`.

No `build.zig.zon`, nothing fetched at build time. Same rule as
RingScript.

---

## 8. What Julia teaches, and where the analogy breaks

**What transfers:**

- *Type stability is the unit of optimisation*, not the program. Julia
  compiles a method when its argument types are concrete; Ring++
  compiles a function when its annotations are concrete. Same idea,
  declared instead of inferred.
- *Compilation is a cache, not a phase.* Julia's users live with
  "time-to-first-X" and it is fine because it happens once. 130 ms is a
  far smaller pill than Julia's.
- *Introspection is the teaching tool.* `@code_warntype` is why Julia
  programmers learn type stability at all. `ringpp why` is the direct
  equivalent and must ship with the first compiled function, not after.
- *The dynamic path stays first-class.* Julia never stopped being
  dynamic. Neither does Ring.

**Where it breaks, and this must be said plainly:**

- Julia was designed for this from day one: parametric types, multiple
  dispatch, an IR built for inference. Ring is a dynamically typed
  interpreter with `Item` unions, doubles for all numbers, and strings
  copied on every call boundary. **Ring++ cannot infer its way to speed;
  it can only compile what the programmer declares.** The typed subset
  will always be a subset.
- Julia has no interpreted twin to stay byte-identical with. Ring++
  does, and that constraint is what keeps it honest — and what caps how
  aggressive it may ever be.
- Julia enforces types at dispatch. Ring enforces nothing, which is why
  §3's boundary guard exists and why it can never be optimised away.

The right expectation: **Ring++ makes the hot 5% of a Ring program run
at C speed while the other 95% stays exactly as dynamic and pleasant as
Ring is today.** Not "Ring becomes fast." That is a smaller claim than
Julia's, and it is one that can actually be kept.

---

## 9. Risks specific to this half

**T1 — Two semantics.** The moment a compiled function exists, there
are two implementations of it, and they can drift. Mitigation is the
byte-identical gate on every test, plus the boundary guard. *Abandon
the compiled half if* the differential suite cannot be kept green.

**T2 — Toolchain weight.** Vendoring a compiler is a real adoption cost,
and the first half's whole promise was "no dependency the user must
install." Largely answered by §7's tiering: analysis needs no compiler,
27–87× needs a ~2 MB one, and only vectorisation and cross-compilation
need the 63 MB download. What survives as a risk is **operational**, not
technical: in banking and government, pulling any binary through a
change-controlled network is a process, not a click. Mitigation is
Tier 1 — detect the compiler already on the machine and vendor nothing.

**T3 — The upgrade surface grows.** The library half depends on ~30
Ring functions. The toolchain half adds: the token stream's shape, the
bytecode listing's shape, the `.ringo` format, the `ringlib_init` ABI,
the parser's `Support Type Identifier` branch, **and now a vendored
tree-sitter grammar that is a second definition of Ring's syntax**. Each
needs a probe. The conformance matrix stops being a nicety and becomes
the thing that makes upgrades survivable. The grammar's probe is the
cheapest of them all — re-run the accept/reject sweep over Ring's own
test suite — and it is the one most likely to fire, because the grammar
tracks Ring by hand rather than automatically.

**T4 — Annotations that lie.** Covered by the boundary guard, but worth
naming as a permanent hazard: a user who annotates for speed rather than
for truth gets a silent fallback and no speedup, and will blame the
compiler. `ringpp why` must report *guard failures observed at runtime*,
not only static reasons.

**T5 — Scope.** This half is years, not weeks. The phasing in §10 is
built so that value lands early and the expensive parts are always
optional. *The honest failure mode is a half-built compiler that nobody
can rely on* — which is exactly how `myctiger` ended, and it ended that
way at 90 lines. At 90,000 lines it would be much worse.

**T6 — It could make Ring look bad.** If `ringpp check` ships a rule
list that reads as "here are twelve ways Ring is slow," it becomes
ammunition rather than a contribution. The framing must stay what the
measurements actually support: *these are the places where Ring's
design trades speed for simplicity, and here is how to opt out at the
call site.* Same tone as the Google Group drafts.

---

## 10. Phases and gates — the toolchain half

**T1 and T2 need nothing installed and can start immediately, in
parallel with the library half.** T3 onward follows P1–P2, because
compiled kernels need `RppBuffer` as their calling convention.

**T1 — `ringpp check`, no compiler required. — DONE, August 11, 2026.**
`zig build` produces `ringpp`; `ringpp check <path>` walks a tree and applies
six rules. Gate met: `stkPointer.ring:720:44` reported by file, line and
column, and **0 errors across Ring's own 973-file test suite, its libraries
and its 1,605 samples** — the only two errors in all of `stzlib` are the two
real `varptr` bugs. Fidelity measured with `tests/fidelity.ps1`: on 5,566
Softanza files the grammar disagrees with Ring on 9 (~0.16%), and **none of
those reach the user as an error** — a parse failure is reported as
`rpp/unparsed`, a note saying rules were not applied, because the lens can
be wrong and the user's code is not on trial for it. One concrete grammar
bug found and recorded for upstream: **Ring identifiers may begin with a
digit** (`3Copies(:of = "x")` is valid Ring; the grammar rejects it).

*Original scope:*
The annotation extractor and rule family (a) from §5, built on a
vendored `tree-sitter-ring` statically linked into the `ringpp` binary
(2.68 MB — evaluated in [`bench/treesitter/`](../bench/treesitter)),
with Ring's own scanner kept as the authority on validity.
*Gate, two parts:* (1) running `ringpp check` on Softanza's
`base/system/` reports the dead `varptr` in `stkPointer.ring:720` and
the O(n) `stkBuffer.Write`, **by file, line and column**, with no false
positives on the rest of the tree; (2) the fidelity gate — every file
`ringpp check` parses gets the same accept/reject verdict as
`ring -norun`, across Ring 1.27's own 978-file test suite and all of
`stzlib`. A disagreement is a grammar bug, never a user-facing
diagnostic.

**T2 — Type checking and `ringpp why`.**
Level 1 checking, plus the compilability report with reasons.
*Gate:* on a hand-written corpus of 30 annotated functions — 15
compilable, 15 not, each with a stated reason — `ringpp why` agrees with
the hand-written expectation 30/30. **No code is compiled in this
phase.** The report must be trustworthy before anything acts on it.

**T3 — The vendored VM, tier detection, and the CLI skeleton.**
`build.zig` builds `ring` from vendored source on five targets; `ringpp`
ships with `check`, `why`, `info`, `doctor`, `vendor`, `version`,
`help`, `completions`. `vendor` implements the four tiers of §7,
including detecting a system compiler before proposing any download.
*Gate, two parts:* (1) `ringpp doctor` on a machine with **only** Zig
installed reports a green conformance run (P1's probe suite) against
the freshly built VM; (2) on a machine with **no** compiler and no Zig,
`ringpp check` and `ringpp why` still work, and `ringpp doctor` reports
tier 0 and prices tiers 1–3 correctly.

**T4 — One compiled kernel, end to end.**
Emit C for a single function shape — a numeric loop over one
`RppBuffer` — compile it with vendored `zig cc`, load it with
`loadlib`, guard it, dispatch it.
*Gate, three parts:* (1) byte-identical output with compilation on and
off, on the full test corpus; (2) the K2 dot-product shape reproduces
its measured range, reported **with** the call-boundary cost included so
the number is what a user actually gets; (3) a deliberately mistyped
call is observed falling back to the interpreter, and `ringpp why`
reports the guard failure.

**T5 — `ringpp build`, multiplatform.**
AOT for every compilable function, cross-compiled to five targets from
one host.
*Gate:* one `ringpp build` on Windows produces working artifacts for
Linux x64 and macOS arm64, verified by running the test corpus on each
(CI or a real machine — not asserted).

**T6 — Compile-and-cache ("JIT").**
The runtime trigger and the content-addressed cache.
*Gate:* a program whose hot function is compiled on first call runs
within 150 ms of the AOT-built version on its first run, and matches it
on the second. Cache invalidation proven by editing the function and
observing a recompile.

**T7 *(conditional)* — anything more ambitious.**
Inference beyond annotations, a real JIT back end, multi-function
inlining. **Only on a measurement showing the above is insufficient for
a named workload.** Not before.

---

## 11. My honest recommendation on sequencing

If I could only build three things from this document, in order:

1. **`ringpp check` with the FINDINGS rules** (T1). No toolchain, no
   risk, immediate value, and it is the only static analyser in
   existence that knows these traps.
2. **`ringpp why`** (T2). It makes the type story teachable, and it is
   useful even if nothing is ever compiled.
3. **One compiled kernel shape** (T4). Proves the architecture end to
   end — annotations → C → `zig cc` → `loadlib` → guarded dispatch — on
   the narrowest possible surface.

Everything after that is scaling a proven pipeline. Everything before
T4 is reversible. That ordering is what turns "years, not weeks" from a
risk into a plan.

The target domains — banking, government, consumer platforms, with their
volumes, optimisation and ML/AI workloads — settle *what* to aim at, and
they aim it precisely: dense numeric kernels (K2's 96×), large record
streams (F-6's slicing wall), and wide tables read out of order (F-9's
95×). Those three shapes are what P0 baselines and what T4 must hit.

One consequence worth stating, because it is counter-intuitive and
measured: **`RppArray` — a packed numeric array, the obvious thing to
build for ML work — must not ship before the compiler.** Read from
interpreted Ring it is 2.2× *slower* than an ordinary Ring list (F-15).
It becomes the right representation only once the loop around it is
native. Build the compiler first, then the array.
