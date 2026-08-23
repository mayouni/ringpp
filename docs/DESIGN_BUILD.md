# The build half — shipping a Ring program

*Proposed by Mansour, 2026-08-23. **A proposal, not a commitment**: the
feasibility below is measured, the scope is not yet decided, and one
target on the original list does not work. Read §6 before agreeing to
anything.*

---

## 1. The thesis, in one sentence

**Ring can already produce a runnable artefact with no compiler. Nobody
can reach it.**

That is the same shape as the other two halves. The library half exists
because Ring already passes lists by reference and nobody could hold a
string still. The toolchain half exists because Ring's parser already
accepts type annotations and nobody could read them. This half exists
because:

| | |
|---|---|
| `ring app.ring -go` | writes `app.ringo` — bytecode |
| `ring app.ringo` | **runs it, with no compiler** |
| `load "stdlib.ring"` | is resolved at compile time and **embedded** — 301 B → 221,794 B |
| the runtime | `ring.exe` + `ring.dll` = **1.3 MB**, verified in an empty directory |

All four measured ([F-28](FINDINGS.md)). Meanwhile Ring's own
`ring2exe` writes a `.c` file and shells out to **Visual C++, GCC or
Clang**. A user who wants an executable is sent to install a C toolchain
to package a program that was already runnable.

**Ring++ removes the toolchain, exactly as commitment 5 says.** It does
not add a compiler; it ships the runtime it already ships binaries for,
and appends bytecode Ring already knows how to emit.

## 2. What a build actually is, then

```
    app.ring  --(ring -go)-->  app.ringo        the whole program, deps embedded
                                   |
    runtime stub  ---------------- + --------->  app.exe / app / app.wasm
    (per platform, ~1.3 MB)                      one file, no compiler
```

The stub is a prebuilt Ring runtime that looks for bytecode appended to
its own image, and runs it. This is the pattern behind
`deno compile` and `bun build --compile`; the novelty here is only that
Ring already has every piece and never assembled them.

**Ring++ already ships five prebuilt binaries for five platforms.** The
distribution machinery, the `.gitattributes` byte-exactness guard, the
format gate and the honest verification table in
[`bin/README.md`](../bin/README.md) all exist. This half reuses them for
runtimes instead of inventing a second mechanism.

## 3. Targets — measured, plausible, and not

**This is the section to argue with.** The original brief listed
desktop, mobile, server, cloud, microcontroller, IoT, browser JS/WASM.
They are not equally reachable and pretending otherwise would be the
first dishonest thing this project shipped.

| target | verdict | why |
|---|---|---|
| **desktop** (Win/mac/Linux, console) | **measured feasible** | F-28, on Windows x64 |
| **server / cloud / container** | **measured feasible** | same artefact; a 1.3 MB runtime is a very small image layer |
| **desktop GUI** | **feasible, not one file** | `loadlib` extensions cannot be embedded — the `ring_*.dll` ship beside it |
| **Linux-class SBC** (Raspberry Pi, IoT gateway) | **plausible, unmeasured** | needs an arm64 Ring runtime and a bytecode-portability test |
| **browser — WASM** | **unknown, needs research** | Ring's WASM story today is Qt-WASM samples; whether a bare VM targets wasm32 is not established here |
| **mobile** (Android/iOS) | **unknown** | packaging, signing and store rules dominate; the runtime is the easy part |
| **bare-metal microcontroller** (ESP32, Arduino) | **NO — say so now** | see below |

### The one that does not work

**A 1.2 MB VM with a full C runtime, a garbage collector and dynamic
`loadlib` does not fit a bare-metal microcontroller**, where RAM is
measured in tens or hundreds of kilobytes. No amount of build tooling
changes that; it is an interpreter-shaped problem, not a packaging one.

What *is* reachable and worth not confusing with it: **Linux-class
embedded** — a Raspberry Pi, an OpenWrt router, an industrial gateway.
Those run a normal Linux and a 1.3 MB runtime is nothing to them. If
"microcontroller/IoT" means those, it is in scope and it is the same work
as Linux arm64. If it means an ESP32, the honest answer is that Ring is
the wrong runtime and MicroRing is the conversation, not Ring++.

## 4. What must be measured before anything is promised

**The build half has one blocking unknown**, and it is deliberately the
first gate:

> **Is a `.ringo` portable across architectures?**

Every number in F-28 is Windows x64. If bytecode written on Windows does
not load on Linux arm64, then "build for any platform from any platform"
collapses into "build for your own platform", which is a much smaller —
though still useful — product. It was not tested because no non-Windows
Ring runtime was on the machine.

**Nothing about cross-platform output may be claimed until this is
measured.** WSL Ubuntu is present and already used to verify the Linux
CLI binary, so the x64 half of the answer is cheap. arm64 needs a real
device or an emulator, and that is a deliberate cost, not a default.

## 5. The sibling tools

RingServer, RingScript and MicroRing are all checked out beside this
repository, and each has a different relationship to this half:

- **RingServer** — the clearest win. A server is exactly the
  console-shaped, extension-light program that becomes one file plus a
  1.3 MB runtime, which is a container image layer rather than a base
  image.
- **RingScript** — already vendors and patches the VM
  ([F-23](FINDINGS.md) came from its `rlist.c`), so it is the one sibling
  that can say whether a *patched* runtime still loads stock bytecode.
  That is a conformance row, and `zig build conformance` already has the
  shape for it.
- **MicroRing** — is where the microcontroller conversation belongs, per
  §3.

**None of them may be edited from here.** Ring++ is dependency-free and
does not reach into sibling repositories; what it can offer them is an
artefact and a measurement.

## 6. What is being asked, honestly

This document establishes that the mechanism exists and measures it. It
does **not** yet justify a phase plan, because three decisions are the
author's and not derivable from any measurement:

1. **Is bare-metal microcontroller support dropped from the brief?**
   §3 says it cannot be delivered. If it stays, this half starts with a
   promise it will not keep.
2. **Cross-platform, or own-platform?** The answer depends on the
   portability measurement in §4 — but the *appetite* does not. Shipping
   runtimes for five platforms means Ring++ distributing Ring itself,
   which is a real commitment and arguably a governance question for
   Mahmoud, not only a technical one.
3. **Does this belong in Ring++ at all, or upstream?** Ring already owns
   `ring2exe`. A compiler-free build path is arguably a *finding* for
   Mahmoud — the project's standing rule is that a finding travels better
   than a patch. Building it here is defensible; building it here
   *without offering it* is the thing to be deliberate about.

Until those are answered, the phase entry in
[PHASE_PLAN.md](PHASE_PLAN.md) is **B0 only** — the measurement — and
nothing after it is scheduled.
