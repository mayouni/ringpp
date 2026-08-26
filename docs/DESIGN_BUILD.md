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

> **Corrected 2026-08-24, phase B3.** This section originally claimed the
> stub "looks for bytecode appended to its own image" and drew the result
> as **one file**. Both were assumption, not measurement, and B3 measured
> them false before writing any code around them: a same-named `.ringo`
> beside `ring.exe` is **not** auto-loaded when run with no arguments, and
> bytes appended to `ring.exe` do **nothing** — both confirmed by trying
> them. Ring's binary needs an explicit filename argument; nothing here
> changes that, and ground rule 1 (never fight the VM) says a source patch
> to add that lookup is a *finding*, not something Ring++ does itself.
>
> **Corrected again, 2026-08-26 (F-35).** The author of Ring read the
> announcement and pointed at the manual-distribution chapter. Re-measured:
> the *same-named* half above stands, but a file named literally
> `ring.ringo` (or `ring.ring`) in the **current directory** is auto-run
> before any argument is parsed (`state.c:476`). No source patch was ever
> needed for an argument-free launch — the fixed name was the door, and
> "needs an explicit filename argument" was the overreach.
>
> The real shape, corrected:

```
    app.ring  --(ring -go)-->  app.ringo        the whole program, deps embedded
                                   |
    runtime stub  ---------------- + --------->  app[.exe] + app.ringo
    (per platform, ~0.5-2.8 MB)                  a PAIR, no compiler,
                                                  invoked as `app app.ringo`
```

**A pair not a single file is still the right outcome.** No C compiler,
no linker step, two small files a user can `zip` or drop in a container
layer. A true one-file artefact — a loader Ring++ compiles itself, which
embeds the bytecode and execs (or statically links) the runtime — is not
ruled out by ground rule 1, since it touches no VM source, but it is
unbuilt and unscheduled; noted in [PHASE_PLAN.md](PHASE_PLAN.md) as future
work, not promised here.

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
| **desktop GUI (Qt)** | **OUT OF SCOPE, by principle — see §6** | not a size problem: bundling `ringqt.dll` alone produces a package that crashes with NO diagnostic, F-30 |
| **Linux-class SBC** (Raspberry Pi, IoT gateway) | **plausible, unmeasured** | needs an arm64 Ring runtime and a bytecode-portability test |
| **browser — WASM** | **plausible — a working precedent exists, unused by Ring++ so far** | corrected 2026-08-25: this row previously said Ring's *only* WASM story was Qt-WASM samples. Wrong — RingScript compiles the bare Ring C VM to `wasm32-wasi` directly with `zig cc`, no Emscripten, no Qt (`ringscript/build.zig`, `.cpu_arch = .wasm32, .os_tag = .wasi`, `wasi_exec_model = .reactor` for persistent state across JS calls, plus its own `wasi_stubs.c` for what WASI lacks). B2 already builds Ring's VM with `zig cc` per target; RingScript is a real, checkable reference for extending that to `wasm32-wasi` — found while studying RingScript for [`docs/SIBLINGS.md`](SIBLINGS.md), not by Ring++'s own research |
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

### The other one that does not work — and this one is not a size problem

**Ring's Qt bridge (`ringqt`, `ringqt_light`, `ringqt_core`) is excluded,
and it was not a close call.** Unlike the microcontroller case this is
not a resource limit — it is that B1's static analysis has no way to see
what `ringqt.dll` itself depends on. `loadlib` scanning names exactly one
file; that file links ~75 further Qt libraries (171 MB) at the OS loader
level, and nothing in a `.ring` file ever mentions them. Measured
directly, not assumed: bundling only what `deps` names produces a
manifest with no `MISSING` line and a package that crashes with **no
diagnostic at all** ([F-30](FINDINGS.md)) — a worse failure than simply
missing a library, because it looks complete right up until it isn't.

This also matches a principle stated independently of the measurement:
Softanza's Ring foundations aim to depend on nothing beyond what they
vendor and support themselves, and Qt's own weight and complexity put it
outside that on purpose. Both readings land in the same place. Ring++
does not package Qt-reaching programs — `ringpp deps` and `ringpp build`
both refuse on sight, naming the reason, rather than half-supporting a
result nobody should trust. Ruled in full in §6.

## 4. The blocking unknown — measured, and the answer is split

> **Is a `.ringo` portable across architectures?**
>
> **Yes for the bytecode. No for a program that touches native
> extensions — and the reason is not the one anyone would guess.**

Measured in phase B0 ([F-29](FINDINGS.md)), gate
[`tests/b0_bytecode.ps1`](../tests/b0_bytecode.ps1). A Linux
x86_64-musl Ring runtime was cross-compiled from Ring's own sources with
`zig cc` (43 files, 24 s, 2.78 MB) and driven under WSL.

| | result |
|---|---|
| pure-Ring bytecode, Windows x64 → Linux x64 | **byte-identical output** — ints, floats (`1/3` → `0.33` on both), string case, `ascii`/`char`, loops, list indexing |
| the same program plus `load "stdlib.ring"` | **fails on Linux** with `R38`, `libring_odbc.so` — while succeeding on Windows |

**The failure is not stdlib and not the bytecode.** A `loadlib` that
fails is **silent on Windows and fatal on Linux**. `stdlib.ring` reaches
extensions it does not need for `upper()`; Windows shrugs, Linux stops.
Proved both ways: an empty directory with only `ring.exe` + `ring.dll`
runs the stdlib program and exits 0, so Windows genuinely does not need
the extension either.

**So the design constraint is now known, and it is sharper than
"portable or not":**

> The bytecode travelling is **necessary and not sufficient**. A build
> half must resolve `loadlib` at *package* time or carry the target's
> extensions — otherwise an executable built and tested on Windows fails
> on Linux, for a library it never calls, in the user's hands rather
> than at build time.

Also learned, and worth watching more than the Ring version: the object
file is **text** and carries `# OBJECT 1.25` while Ring reports 1.27.0.
**The object format is versioned separately from the language**, and it
— not the Ring version — is what would silently invalidate every
already-packaged program.

**Still unmeasured: arm64.** Everything above is x64→x64. The honest
claim today is *"portable between x64 platforms"* and nothing wider.

## 4b. What B1 built, and the number that justifies it

`ringpp deps <file.ring> [--ring <dir>]` — **built 2026-08-24**, gate
`b1 deps`. It answers the question B0 opened, and it answers it
statically because Ring's own idiom writes all three platform file names
as literals in the source.

The result on a program whose only sin is `load "stdlib.ring"`:

> **Six native extensions — ODBC, MySQL, SQLite, internet, OpenSSL,
> PostgreSQL — reachable, in order to call `upper()`.**

That number is the argument for the command. Nobody would guess it, it is
invisible in the source of the program itself, and on Linux the first of
them is fatal. `ringpp deps` names `libring_odbc.so` without running
anything — the same failure B0 needed a cross-compiled Linux runtime and
a WSL round trip to find.

**It refuses rather than reassures.** Without `--ring` it cannot follow
`load "stdlib.ring"`, so it prints **NO VERDICT**, names the loads it
could not resolve, and exits non-zero. It never reports "pure Ring" for a
program it failed to read — that specific refusal is gated harder than
the happy path, because it is the one that would be believed at the
moment someone ships.

## 5. The sibling tools

RingServer, RingScript and MicroRing are all checked out beside this
repository, and each has a different relationship to this half:

- **RingServer** — the clearest win. A server is exactly the
  console-shaped, extension-light program that becomes a stub-plus-
  bytecode pair (§2) around a self-built runtime under 3 MB (B2), which is
  a container image layer rather than a base image.
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

## 6. What was asked, and how it was answered — decided 2026-08-24

Four decisions were the author's and not derivable from any measurement
alone. All four are now ruled:

1. **Bare-metal microcontroller support is DROPPED from the brief.** §3's
   measurement stands: a 1.2 MB VM with a GC does not fit an ESP32, and no
   packaging tool changes that. **Linux-class embedded stays in** — a
   Raspberry Pi or a gateway is the same work as Linux arm64. True bare
   metal is MicroRing's conversation, not this one.
2. **Cross-platform, not own-platform.** Ring++ will build and ship
   runtimes for other platforms, the same way it already ships five CLI
   binaries. This is the larger commitment named in the question — Ring++
   becomes a redistributor of Ring's own runtime, not only a tool that
   runs on it — taken deliberately rather than by default.
3. **Built in Ring++, not proposed upstream first.** The same posture as
   the type checker and the CLI: shipped here, working, rather than
   proposed and waited on. A working build half is also the strongest
   version of the finding this project would eventually owe Mahmoud —
   *"Ring can already build without a compiler"* lands better as a
   working tool than as a paragraph.
4. **Qt is excluded from the build half entirely — stated as a standing
   principle, and independently confirmed by measurement.** *"All
   Softanza projects, including the Ring projects made to be a foundation
   for them, are aimed to be dependency-free, except from the libs we
   vendor and support inside the solution. This excludes Qt and its
   heavyweight and complex structure from the picture."* Ring++ does not
   package a program that reaches Ring's Qt bridge (`ringqt`,
   `ringqt_light`, `ringqt_core`), full stop — not "not yet", not "ask for
   `--allow-qt`". The measurement in [F-30](FINDINGS.md), taken the same
   day, landed on the identical boundary independently: bundling only
   what `loadlib` scanning can name for a Qt program produces a package
   that crashes with **no diagnostic at all**, because `ringqt.dll` itself
   depends on ~75 further Qt libraries at the OS loader level that no
   `.ring` source ever names. Principle and measurement agreeing from two
   different directions is the strongest form of "ruled" this project can
   produce. Enforced, not just documented: `ringpp deps` and `ringpp
   build` both refuse on sight (§3, and the code in `src/deps.zig` /
   `src/pack.zig`).

**What this changes about §3 and §4.** Nothing in the measurements moves;
only the *appetite* was undecided, and it is decided now. Cross-platform
packaging depends on having a runtime for each target — B0 already proved
the mechanism (`zig cc` cross-compiling Ring's own VM sources, 43 files,
24 s, one Linux x64 runtime produced) for exactly one target. Producing
the others is now scheduled work, not a philosophical question.

See [PHASE_PLAN.md](PHASE_PLAN.md) for the phases this unblocks.
