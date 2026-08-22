# Ring++

**Write more performant, more governable Ring — in Ring itself. And learn,
along the way, why Ring is built the way it is.**

## Two halves — which is which, before anything else

|  | what it is | how you get it | what it needs |
|---|---|---|---|
| **The library** | pointer-backed buffers, zero-copy views, a list index phase, a sub-state sandbox — measured ways to stop paying costs Ring's design already lets you avoid | a normal Ring package: `ringpm install ringpp`, then **`load "ringpp.ring"`** | **pure Ring.** Stock `ring.exe` and nothing else — it works wherever Ring works, including WASM |
| **The CLI** | type checking, static analysis and explanation for **large** Ring projects — measured on [Softanza](https://github.com/mayouni/stzlib): **923,000 lines across 6,014 files in 43 seconds** | **one prebuilt binary**, shipped inside the same package: `ringpp check myproject/` | **nothing at all.** You run it; you compile nothing. No C compiler, no clang, no toolchain — ever |

Either half is usable alone. They meet in the middle: the checker's rules
exist because the library's measurements found the traps, and the library's
idioms are what the checker recommends.

---

Ring++ came out of a real evaluation. The engineering team of a bank
running Ring in production was impressed by the language — and when they
tested it against their larger projects, **type safety** was the concern
that remained. Ring++ is the practical answer to that concern, built
without leaving Ring and without fighting it.

## What Ring++ is, in five commitments

1. **More performant Ring, in Ring.** Buffers, zero-copy views, list
   phases, sandboxes — each one a documented, measured way to stop paying
   a cost Ring's design already lets you avoid. No C, no extension, no
   rewrite in another language.
2. **Type safety for large Ring projects.** A static checker built on
   **[`tree-sitter-ring`](https://github.com/ysdragon/tree-sitter-ring),
   the Ring grammar written by Youssef Saeed
   ([`@ysdragon`](https://github.com/ysdragon))** — vendored here under
   its MIT licence — plus Ring's own `typehints` channel, the annotations
   Ring's parser already accepts on purpose and currently throws away. It
   reads across the **load graph**, so a call in one file is checked
   against a definition in another. On real codebases it found
   **two functions in Ring's own standard library that have never worked**
   — `encrypt_ex` and `decrypt_ex` call the wrong function and die with
   `R20` on every call — with **zero false positives across Ring's 1,959
   files**. See [the case study](docs/CASE-TYPE-SAFETY.md), which also
   records the three false positives it *did* produce and what they cost.
3. **Governability for business-domain projects.** Static analysis
   (`check`), explanation (`why`), and gates that assert behaviour — so a
   bank, a ministry, or a platform team can *audit* a Ring codebase, not
   just run it. Relying on nothing but Ring.
4. **An educational framework with comparative testability.** Every
   example is one file holding the plain-Ring way and the Ring++ way,
   asserting byte-identical output, printing the measured difference, and
   explaining *why Ring behaves as it does*. The goal is advanced
   programmers who take advantage of Ring's internal design **without
   fighting it or breaking its culture**.
5. **A schoolcase for low-level programming, in Mahmoud Fayed's patterns
   of thinking.** Not his implementation — his *way*: a small opinionated
   surface over something vast, simplicity as a feature, and the tradeoff
   always stated. Three of the eight examples conclude that plain Ring is
   the right answer for their shape; that balance *is* the curriculum.

**Ring++ is dependency-free.** It needs nothing but Ring itself — no other
package, no extension to compile, no toolchain. It is
developed alongside [Softanza](https://github.com/mayouni/stzlib)
and used by it, but it is not part of it and never requires it. And
because it builds on Ring's internals, it names **exactly** what it needs
from them in one short document — [docs/VM-CONTRACT.md](docs/VM-CONTRACT.md)
— machine-checked on every load, so a future Ring that changes something
is detected and named, never fought.

---

## Install

```
ringpm install ringpp
```

Then, from anywhere:

```ring
load "ringpp.ring"

oBuf = new RppBuffer(1024)
oBuf.Poke(0, "hello")
? oBuf.Peek(0, 5)        # --> hello
```

The same install puts the `ringpp` **CLI** on your machine — one prebuilt
binary, made with Zig:

```
ringpp check myproject/     # type safety + the measured lint rules
ringpp why R4               # explain the Ring error you actually saw
```

**No C compiler, no clang, no toolchain is required or suggested — ever.**
The Zig source of the CLI is in the repository; only someone who wants to
*adapt* the CLI installs the Zig compiler.

Five prebuilt binaries ship: Windows x64, Linux x64 and arm64 (static
musl — one file for any Linux), macOS x64 and arm64.
[`bin/README.md`](bin/README.md) says which is which **and how far each
one is verified** — Windows and Linux x64 were executed against the full
fixture set; the other three are compiled and format-checked but have not
been run, because this machine cannot run them.

*Status: the library, the CLI, and eight measured examples are **built
and gated**. `powershell -File tests\run-all.ps1` runs everything.*

---

## Start here

| | |
|---|---|
| **[docs/CASE-TYPE-SAFETY.md](docs/CASE-TYPE-SAFETY.md)** | **What the checker actually found** — two dead functions in Ring's own standard library, two live bugs in Softanza, and the three false positives it produced along the way. |
| **[docs/VM-CONTRACT.md](docs/VM-CONTRACT.md)** | The abstract interface: exactly what Ring++ needs from the VM, as observable behaviours, probe-checked on every load — and a proposed contract both parties could agree on. |
| **[docs/FINDINGS.md](docs/FINDINGS.md)** | What the Ring VM actually does, measured. Read this first — two of its numbers killed the design I set out to write. |
| **[docs/DESIGN.md](docs/DESIGN.md)** | The library half: what Ring++ is, the layer map, the surface, safety, upgrades, `myctiger`, Softanza, and the risks. |
| **[docs/DESIGN_TOOLCHAIN.md](docs/DESIGN_TOOLCHAIN.md)** | The toolchain half: types, compilation, static analysis, the vendored VM, what Julia teaches and where the analogy breaks. |
| **[docs/CLI.md](docs/CLI.md)** | `ringpp` — one CLI, in the `zin` house style, with the two altitudes visible in every help screen. |
| **[docs/PHASE_PLAN.md](docs/PHASE_PLAN.md)** | Phases with gates. A plan is not done until its gate runs. |
| **[docs/UPSTREAM_NOTES.md](docs/UPSTREAM_NOTES.md)** | Draft text for the Ring Google Group. Not sent. |
| **[bench/](bench)** | The programs that produced every number. |

## The thesis, in one paragraph

Ring passes **lists by reference** and **strings by copy**. That single
asymmetry — `RING_VM_STACK_PUSHCVAR` in `vm.h:230` — is behind almost
everything that is slow about large-data work in Ring. Passing a 1 MB
string to a function costs **~750 µs**; passing a handle to the same
bytes costs **0.3 µs**. `substr(cBig, n, 10)` on a 500 KB string costs
**12.5 µs** because it first copies half a megabyte; `ptr2str(p, n, 10)`
costs **0.09 µs**. Patching 2,000 offsets costs **803 ms** in pure Ring
and **1 ms** in place. Ring++ is the way to hold a large value still.

What Ring++ is **not** is "pointers are faster." They usually are not:
building 1.6 MB from 8-byte chunks is **28× slower** through `memcpy`
than through `cOut += chunk`, because Ring's string append already
doubles its capacity and every crossing into C costs ~100 ns. The
library's most common correct answer must be *no*, and it should be able
to say so at runtime.

## The annotation channel — the discovery type safety stands on

**Ring's parser already accepts type annotations, on purpose** —
`/* Support Type Identifier */`, `stmt.c:1217` — and
`ring_state_stringtokens` hands them back verbatim. `int func Sum(int x,
int y)` runs today on stock `ring.exe`. Ring++ consumes a channel that
already exists and is currently thrown away — the clearest possible case
of building on Mahmoud's design rather than around it. Annotated Ring++
source **always keeps running under stock Ring**; the checker adds
meaning, never syntax.

(Measured before building: the two halves of an annotation are different
mechanisms — parameter types are a parser feature that costs nothing,
while a *return* annotation is a variable read that needs
`typehints.ring` loaded or it raises `R24`. [FINDINGS
F-24](docs/FINDINGS.md) has the table; the checker knows the difference.)

## Research annex: the measured native headroom

Compilation is **not part of the Ring++ product** — no C compiler, no
toolchain is ever asked of a user. But the headroom was measured, and the
numbers are kept because they map where Ring's own boundary sits
([`bench/headroom/`](bench/headroom), [`docs/DESIGN_TOOLCHAIN.md`](docs/DESIGN_TOOLCHAIN.md)):

| kernel | Ring | native | ratio |
|---|---:|---:|---:|
| scalar loop, 20 M iterations | 1151 ms | 18 ms | **64×** |
| dot product, 1 M doubles | 92 ms | 0.96 ms | **96×** |
| byte scan, 5 MB | 645 ms | 0.22 ms | **~3000×** |

If a compiled half is ever built, it will be proposed separately, with
its own gates — and `RppBuffer` is already its calling convention.

## The one story that explains the whole design

`ringvm_genarray()` makes a permuted read of an 80,000-item list **~95×
faster**. It also makes a write-heavy loop **10–16× slower**, and a single
`aList + x` silently destroys the array. The break-even is around 10–20
random reads per mutation.

So the power was already in the language. What was missing was a way to
reach it that is explicit, local, and obvious in the code — and that
refuses when it would make things worse. Ring++ is meant to be a hundred
decisions of that shape.

## Reproducing the numbers

Ring 1.27.0 is required; the 1.26 install has its own pathologies.

```bash
D:\ring127\bin\ring.exe bench\07_by_value_tax.ring
```

Each program in `bench/` prints its own table. `bench/safety/` contains
four programs that demonstrate the failure modes — **two of them kill
the process on purpose**; run each in its own shell.

## Ground rules for this project

1. **Never fight the VM.** No fork, no shadow allocator, no global
   interception. Anything needing a VM change is a *finding*, reported
   separately.
2. **Survive Ring upgrades untouched.** A ~30-name declared surface,
   one behavioural probe per name, honest degradation instead of
   breakage.
3. **No dependency the user must install.** The library is pure Ring, one
   `load`. The CLI is one shipped binary. The Zig *compiler* is needed
   only by someone adapting the CLI's source — never by a user.
4. **Measure, never assume.** Every claim is an A/B differing in one
   thing, and **every claim ships with the pattern it hurts**.
5. **Never open a pull request or an issue on `ring-lang/ring`** by
   default — prepare the text, don't send it. Findings go to the Ring
   Google Group, posted by Mansour. *One exception:* he asks explicitly
   to publish, after reviewing the finding himself.

## Credits

**Mahmoud Fayed** — for Ring, and for the design this project is built on
rather than around. The annotation channel Ring++ reads was put there
deliberately; the list/string asymmetry the library exploits is a
considered tradeoff, not an accident. Commitment 5 above is meant
literally: this is a schoolcase in his patterns of thinking.

**Youssef Saeed ([`@ysdragon`](https://github.com/ysdragon))** — for
**[`tree-sitter-ring`](https://github.com/ysdragon/tree-sitter-ring)**,
the Ring grammar the entire type-safety half stands on. It is vendored
here under its MIT licence (`vendor/tree-sitter-ring/LICENSE`) and built
into the shipped binary, so every `ringpp check` is running his work. It
was adopted rather than written from scratch because it independently
reached the same reading of Ring's type annotations that the measurements
here did — the strongest signal available that the reading is right.
Grammar findings from this project go back to him as
[issues](https://github.com/ysdragon/tree-sitter-ring/issues), never
patches around him. And when this project reported one case-sensitivity
defect in `ring_state_findvar`, his follow-up turned it into **four** —
including `ring_state_newvar`, whose failure mode (a variable that exists
and cannot be addressed) was worse than the one originally reported. The
fix landed as
[`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094),
credited to both.

**The tree-sitter authors** — for the runtime, also vendored under MIT
(`vendor/tree-sitter/`). Full third-party licence list in
[`LICENSE`](LICENSE).
