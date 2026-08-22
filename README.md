# Ring++

**A high-level, safe way into Ring's low-level surface — for Ring
programmers who hit a wall and do not want to leave the language.**

Ring++ exists to remove Ring's weakness in **performant, data-intensive
work**: banking, government and consumer platforms, with the data
volumes, complex processing, optimisation, ML and AI that come with
them. The answer to those needs should not be "rewrite that part in
another language." It should be Ring.

**Ring++ is an independent project.** It depends on nothing but Ring
itself — no other package, no extension to compile, no DLL. It is
developed alongside [Softanza](https://github.com/mansourayouni/stzlib)
and used by it, but it is not part of it and never requires it.

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

That is the whole dependency story. The library half is **pure Ring**,
loads in one line, and works wherever Ring works — including WASM.

The `ringpp` **CLI** (`check`, `why`, `ast`) is a separate, optional Zig
build and is deliberately *not* in the package: installing a Ring library
should never require a C toolchain. Build it from source when you want
static analysis.

*Status: the library, the CLI's analysis half, and eight measured
examples are **built and gated**. The compiler half (T3–T7) is designed
and not yet built. `powershell -File tests\run-all.ps1` runs everything.*

---

## Two halves, two altitudes of installation

| you install | you get | download |
|---|---|---:|
| `load "ringpp.ring"` | the **library half** — buffers, zero-copy views, list phases, sandboxes. Stock `ring.exe`, every platform Ring runs on, including WASM. | ~0 |
| \+ `ringpp` | **type checking and static analysis** — `check`, `why`. Needs no compiler at all. | ~0 |
| \+ any C compiler already on the machine | **compiled kernels**, 27–3000× | 0 |
| \+ vendored Zig, this host's targets | **cross-compilation** to Windows, Linux x64/arm64, macOS x64/arm64 from one machine | 63 MB |

The toolchain is **tiered, not all-or-nothing**: with no optimising
compiler at all you already get 22–72× on numeric kernels, so the big
download buys vectorisation and cross-compilation, not entry. Measured
in [`bench/toolchain/`](bench/toolchain), on Zig 0.15.2 **and** 0.16.0.

The second needs the first: a compiled kernel handed a Ring string pays
~750 µs per megabyte to receive it, which erases any speedup.
**`RppBuffer` is the calling convention of the compiled half** — which is
why these are one project and not two.

## Start here

| | |
|---|---|
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

## The headroom the toolchain half adds

Identical algorithms, Ring 1.27 interpreted versus `zig cc -O2` native
([`bench/headroom/`](bench/headroom)):

| kernel | Ring | native | ratio |
|---|---:|---:|---:|
| scalar loop, 20 M iterations | 1151 ms | 18 ms | **64×** |
| dot product, 1 M doubles | 92 ms | 0.96 ms | **96×** |
| byte scan, 5 MB | 645 ms | 0.22 ms | **~3000×** |

And the discovery that makes it reachable without a fork: **Ring's
parser already accepts type annotations on purpose** —
`/* Support Type Identifier */`, `stmt.c:1217` — and
`ring_state_stringtokens` hands them back verbatim. `int func Sum(int x,
int y)` runs today on stock `ring.exe`. Ring++ consumes a channel that
already exists and is currently thrown away. Annotated Ring++ source
must always keep running under stock Ring.

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
3. **No dependency the user must install.** Pure Ring, one `load`. Zig
   appears only for the maintainer's upgrade matrix and for strictly
   optional later planes.
4. **Measure, never assume.** Every claim is an A/B differing in one
   thing, and **every claim ships with the pattern it hurts**.
5. **Never open a pull request or an issue on `ring-lang/ring`** by
   default — prepare the text, don't send it. Findings go to the Ring
   Google Group, posted by Mansour. *One exception:* he asks explicitly
   to publish, after reviewing the finding himself.
