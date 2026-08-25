<p align="center"><img src="ringpp-logo.jpg" alt="Ring++" width="160"></p>

# Ring++

**Ring, faster and safer — without ever leaving Ring.** A dependency-free
library and a one-binary CLI, each one also a window onto how Mahmoud Fayed
built a small, friendly language over a large and unforgiving one underneath.

## Three things, each measured

| | what it is | the number |
|---|---|---:|
| **[Performant code](site/performance.html)** | `RppBuffer` / `RppView` — a block of bytes that crosses a function call by reference, the way every Ring object already does, instead of by copy | **75×** faster — 302 ms → 4 ms, same loop, byte-identical result |
| **[Static analysis](site/checker.html)** | `ringpp check` — reads the type annotations Ring's own parser already accepts and silently discards, across the whole load graph | **2** functions in Ring's own shipped stdlib that have never worked, **0** false positives across 1,959 files |
| **[Native build](site/build.html)** | `ringpp build` — Ring's own bytecode plus a prebuilt runtime stub, no C compiler involved anywhere | **1** command, **5** platforms, **0** compilers installed |

Not three separate tools — three angles on one idea: **Ring already has the
machinery for this, mostly unused.** [The library reference](site/reference.html)
has every method with a real example; [Start here](site/start.html) has the
install.

Either half — library or CLI — is usable alone. They meet in the middle: the
checker's rules exist because the library's measurements found the traps, and
the library's idioms are what the checker recommends.

---

## Why this exists

Ring++ came out of real projects, not a lab. Teams who liked Ring and wanted
to keep using it — for a server talking to a browser, for work that has to
survive a dropped connection, for datasets too large to shrug off — kept
hitting the same three walls: some operations on big data were slower than
they should be, nothing checked a large codebase before it ran, and shipping
usually meant asking someone to install a compiler, or a GUI toolkit whose
licence terms were their own kind of risk. Separately, the engineering team
of a bank running Ring in production tested it against their larger projects
and came back with the same second concern: **type safety at scale**. Ring++
answers each one directly, without leaving Ring and without adding a
dependency to it.

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

That's one method of four classes — [every method on all four is on one
page](site/reference.html), each with a real example.

The same install puts the `ringpp` **CLI** on your machine — one prebuilt
binary, made with Zig:

```
ringpp check myproject/     # type safety + the measured lint rules
ringpp why R4               # explain the Ring error you actually saw
ringpp build myproject/main.ring --out dist --target linux-x64
```

**No C compiler, no clang, no toolchain is required or suggested — ever.**
The Zig source of the CLI is in the repository; only someone who wants to
*adapt* the CLI installs the Zig compiler.

Five prebuilt binaries ship: Windows x64, Linux x64 and arm64 (static
musl — one file for any Linux), macOS x64 and arm64, all cross-built from a
single machine. [`bin/README.md`](bin/README.md) says which is which **and
how far each one is verified** — Windows and Linux x64 were executed against
the full fixture set; the other three are compiled and format-checked but
have not been run, because this machine cannot run them.

*Status: the library, the CLI, and eight measured examples are **built
and gated**. `powershell -File tests\run-all.ps1` runs everything.*

A site organised around the three pillars above lives in
[`site/`](site/index.html) — open `site/index.html` directly, or enable
GitHub Pages on this repository (Settings → Pages → deploy from `site/`)
to put it at `mayouni.github.io/ringpp`. Not deployed by this commit;
deployment is a repository setting only the owner can flip.

---

## Start here

| | |
|---|---|
| **[site/reference.html](site/reference.html)** | The library, one page — every `RppBuffer`, `RppView`, `RppIndexed` and `RppSandbox` method, with a real example for each. |
| **[docs/CLI.md](docs/CLI.md)** | `ringpp` — every command, real captured output, no compiler needed for any of it. |
| **[docs/CASE-TYPE-SAFETY.md](docs/CASE-TYPE-SAFETY.md)** | **What the checker actually found** — two dead functions in Ring's own standard library, two live bugs in Softanza, and the three false positives it produced along the way. |
| **[docs/SIBLINGS.md](docs/SIBLINGS.md)** | What running Ring++ against RingScript, RingServ and MicroRing actually found — real code, real gaps in Ring++'s own claims caught along the way, and where Ring++ honestly does not apply. |
| **[docs/VM-CONTRACT.md](docs/VM-CONTRACT.md)** | The abstract interface: exactly what Ring++ needs from the VM, as observable behaviours, probe-checked on every load — and a proposed contract both parties could agree on. |
| **[docs/FINDINGS.md](docs/FINDINGS.md)** | What the Ring VM actually does, measured. Read this first — two of its numbers killed the design I set out to write. |
| **[docs/DESIGN.md](docs/DESIGN.md)** | The library half: what Ring++ is, the layer map, the surface, safety, upgrades, `myctiger`, Softanza, and the risks. |
| **[docs/DESIGN_TOOLCHAIN.md](docs/DESIGN_TOOLCHAIN.md)** | The toolchain half: types, compilation, static analysis, the vendored VM, what Julia teaches and where the analogy breaks. |
| **[docs/PHASE_PLAN.md](docs/PHASE_PLAN.md)** | Phases with gates. A plan is not done until its gate runs. |
| **[docs/UPSTREAM_NOTES.md](docs/UPSTREAM_NOTES.md)** | Draft text for the Ring Google Group. Not sent. |
| **[bench/](bench)** | The programs that produced every number. |

## Performant code, the thesis in one paragraph

Ring passes **lists by reference** and **strings by copy**. That single
asymmetry — `RING_VM_STACK_PUSHCVAR` in `vm.h:230` — is behind almost
everything that is slow about large-data work in Ring. Passing a 1 MB
string to a function costs **~750 µs**; passing a handle to the same
bytes costs **0.3 µs**. `substr(cBig, n, 10)` on a 500 KB string costs
**12.5 µs** because it first copies half a megabyte; `ptr2str(p, n, 10)`
costs **0.09 µs**. Patching 2,000 offsets costs **803 ms** in pure Ring
and **1 ms** in place. Ring++ is the way to hold a large value still —
this is not a Ring++ invention: it's how every class instance in Ring
already behaves, extended to bytes.

What Ring++ is **not** is "pointers are faster." They usually are not:
building 1.6 MB from 8-byte chunks is **28× slower** through `memcpy`
than through `cOut += chunk`, because Ring's string append already
doubles its capacity and every crossing into C costs ~100 ns. The
library's most common correct answer must be *no*, and it should be able
to say so at runtime.

## Static analysis, the annotation channel it stands on

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

On real codebases the checker found **two functions in Ring's own
standard library that have never worked** — `encrypt_ex` and
`decrypt_ex` call the wrong function and die with `R20` on every call —
with **zero false positives across Ring's 1,959 files**. See [the case
study](docs/CASE-TYPE-SAFETY.md), which also records the three false
positives an earlier version *did* produce and what they cost.

## Native build, the two doors already open

Run `ring yourfile.ring -go` on stock Ring today and it writes
`yourfile.ringo` — compiled bytecode, no C compiler involved at any
point; that's how Ring itself starts up fast. Ring's own packaging tool,
`ring2exe`, takes the other door from there: it writes a C file and hands
it to Visual C++, GCC or Clang. `ringpp build` keeps the bytecode Ring
already writes and attaches a small prebuilt copy of Ring itself that
knows how to run it — nothing new invented, just the door that was
already open. It also refuses to package a program that reaches Ring's
Qt bridge: bundling the one library static analysis can name
(`ringqt.dll`) once produced a package that reported nothing missing and
crashed with **no diagnostic at all**, because that DLL itself links
roughly 75 further Qt libraries no `.ring` source ever names — on top of
Qt's own dual licence being a real business risk for anything shipped to
customers, decided against before Ring++ existed.

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
considered tradeoff, not an accident. Rule 1 above is meant literally:
this is a schoolcase in his patterns of thinking, not in his
implementation.

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
