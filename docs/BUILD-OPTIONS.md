# Packaging a Ring program — the options, compared

*Written 2026-08-26. Every capability below was read from the tool's own
source or documentation, and every build result was produced on this machine.
Nothing is inferred from a README alone where source was available.*

Ring has more than one way to turn a program into something you hand to
someone else, and they are not competing answers to one question — they are
answers to **different** questions. This file lays them side by side so a
Ring programmer can pick on purpose rather than by habit.

The three:

- **Ring2EXE** — ships with Ring. `tools/ring2exe/ring2exe.ring`.
- **Ring2EXE++** — [Youssef Saeed's](https://github.com/ysdragon/ring2exe-plus)
  extended tool: many more packaging formats, auto-detection, presets.
- **`ringpp build`** — Ring++'s packager, the subject of this repository.

---

## 1. The short version

| | Ring2EXE | Ring2EXE++ | `ringpp build` |
|---|---|---|---|
| **C compiler needed** | **yes** | **yes** (MSVC/MinGW/Clang/TCC, auto-detected) | **no, ever** |
| **Output** | one executable | one executable | a **pair**: `app[.exe]` + `app.ringo` |
| **Cross-build from one machine** | no | not documented | **yes — 5 targets** |
| **Installer formats** | dist folders | **DEB, RPM, AppImage, Flatpak, Snap, DMG, PKG, NSIS, Inno, MSI** | none |
| **Mobile** | **yes** — prepares a Qt project | — | not yet (§4) |
| **WebAssembly** | **yes** — prepares a Qt project | — | not its job (§5) |
| **Lists native deps before building** | — | auto-detects libraries | **yes**, `ringpp deps`, statically |
| **Refuses an unsafe package** | — | — | **yes**, by design (§3) |

**Read the columns, not the rows.** Ring2EXE++ is clearly the strongest at
producing installers — ten formats is a serious piece of work, and nothing in
Ring++ approaches it. Ring2EXE is the only one that reaches mobile and the
browser at all. `ringpp build` is the only one that needs no compiler and
cross-builds. Three bargains, and the right one depends on what you are
shipping.

---

## 2. What each one actually does

**Ring2EXE** writes a C file that embeds your program, then invokes a real C
compiler on your machine to produce one executable. For mobile and
WebAssembly it does something different, and the distinction matters: it
**prepares a Qt project** — copying `extensions/android/ringqt/project/*`,
substituting your `.ringo` name into `main.cpp` and `project.qrc`. The build
itself then happens in Qt Creator, with the Qt Android or Qt WebAssembly
toolchain installed. That is a documented and reasonable design; it simply
means the tool hands you a project, not a package.

**Ring2EXE++** keeps the C-compiler approach and invests heavily where it
pays off for distribution: auto-detecting which libraries your program needs,
build presets, UPX compression, a `ring2exe.conf` project file, and the ten
installer formats above. If your problem is *"I need a proper `.deb` and a
signed installer"*, this is the tool that solves it.

**`ringpp build`** takes the other fork in Ring's own design. Ring can
already compile a program to bytecode with no C compiler involved —
`ring app.ring -go` writes `app.ringo`. Ring++ keeps that bytecode and
attaches a small prebuilt copy of Ring's own VM, compiled ahead of time for
each target. Nothing is compiled on your machine, so nothing needs a
compiler on it.

---

## 3. What `ringpp build` does by design that the others do not aim to

These are not gaps in the other tools. They are consequences of a different
starting requirement, and worth stating plainly.

**No compiler on any machine, ever.** Not "usually not", not "auto-detected".
The five runtime stubs are compiled once, here, and shipped. A user with no
build tools at all can package a Ring program.

**Cross-building.** One machine produces packages for Windows x64, Linux x64,
Linux arm64, macOS x64 and macOS arm64. Measured on this machine, cold then
warm: 75 s for the first target, 11–14 s for each subsequent one. A Windows
laptop can ship a Linux arm64 build without a Linux arm64 machine, a VM or a
container — verified by running the result under WSL and comparing output
byte-for-byte against Ring's own build.

**It tells you what it cannot see, and refuses rather than guessing.** This
is the design difference that matters most, and it comes from a measurement
rather than a preference:

- `ringpp deps` lists every native library a program can reach, statically,
  before anything is built — with the file and line that declared each one.
- A library it cannot find is written `MISSING` in the manifest. Never
  dropped silently.
- If the `load` chain cannot be followed completely, it reports **`NO
  VERDICT`** instead of an empty dependency list. An answer that looks like
  a verdict but is really a measure of what the tool could not see is worse
  than no answer.
- It **refuses outright** to package a program that reaches Ring's Qt bridge.
  The reason is measured, not ideological: bundling the one library static
  analysis can name (`ringqt.dll`) produces a package that reports nothing
  missing and then dies with **no diagnostic at all** — `0xC0000409`, no
  message — because that DLL depends on roughly seventy-five further Qt
  libraries no `.ring` source ever names ([F-30](FINDINGS.md)).

That last one is a limitation and a feature at the same time, and it is the
honest reason Ring++ does not do Qt GUIs. It is not a claim that Qt is wrong
— it is that this particular mechanism cannot package it *safely*, so it
declines instead of shipping something that fails silently in a user's hands.

**Where it is weaker, stated plainly.** The output is a pair of files, not
one executable. There are no installer formats. It needs Ring installed on
the *build* machine (it calls `ring -go`). It does not do GUIs. If any of
those matter to you, one of the other two tools is the better answer, and
this file is not trying to talk you out of it.

---

## 4. Mobile — measured, not promised

The interesting question is whether the stub mechanism reaches mobile
**without Qt**. It was tested rather than argued about. `zig cc`, Ring's own
43 C source files, on this machine today:

| target | result |
|---|---|
| `aarch64-linux-musl` (Linux ARM, Raspberry Pi, Termux) | **builds, 2 s**, static ELF |
| `aarch64-linux-android` | **fails** — `unable to provide libc for target … android.29` |
| `aarch64-ios` | **fails** — `'stdio.h' file not found` |

**The blocker is not the mechanism. It is the platform SDK.** Zig ships libc
for Linux, Windows and macOS, but not Android's bionic and not the iOS SDK —
those come from the Android NDK and Xcode respectively, and any native
toolchain needs them.

So an honest statement of where mobile stands:

- **Android is reachable** by pointing `zig cc` at an installed NDK sysroot.
  That trades Ring's current requirement — Qt **and** Qt Creator **and** the
  NDK — for the NDK alone. A real reduction, and still not "no toolchain".
  Untried here; the NDK is a large download and this has not been attempted.
- **iOS additionally requires a macOS host and Xcode**, which is Apple's
  constraint rather than anyone's design choice.
- **Linux ARM already works today** and is the one mobile-adjacent target
  that needs nothing extra — which is also MicroRing's Tier 1 territory.

Nothing is promised here. What is established is that the *packaging
mechanism* is not what stands in the way, and that a Qt-free mobile path is
an SDK problem rather than an architecture problem.

---

## 5. The ecosystem — who covers what, so nobody duplicates

This matters more than any single tool. Four projects share one language, and
the useful arrangement is that each owns a target the others do not touch.

| target | covered by | how |
|---|---|---|
| **Browser / WebAssembly** | **RingScript** | Ring's VM compiled to WASM, Zig-first — no Emscripten, no npm, **no Qt** |
| **Server** | **RingServ** | one static binary, HTTP core |
| **Desktop native**, 5 platforms | **`ringpp build`** | bytecode + prebuilt stub, no compiler |
| **Installers & packaging formats** | **Ring2EXE++** | ten formats, C compiler |
| **Mobile via Qt** | **Ring2EXE** | prepares a Qt project |
| **Device — Linux class** (Pi, ARM SBC) | **MicroRing** Tier 1, and `ringpp build` | static musl ARM |
| **Device — bare metal** (RP2350, ESP32) | **MicroRing** Tiers 2–3 | MicroZig / ESP-IDF, outside Ring++ by design |

**Ring++ should not build a WebAssembly target.** RingScript already solved
that problem, without Qt and without Emscripten, and duplicating it would
split effort for no gain. If the two ever meet, the useful shape is Ring++
*packaging for* RingScript's runtime, not competing with it.

**Ring++ should not go past Linux-class devices.** MicroRing's Tiers 2 and 3
are bare-metal firmware builds; the runtime-stub mechanism has nothing to
offer there and says so.

**The one genuinely uncovered square is mobile without Qt** — and §4 says
what it would actually cost.

---

## 6. Reproducing any of this

The cross-build timings, the byte-identical WSL comparison, and the Qt
refusal are all gated in this repository's own test suite:

```
powershell -File tests\run-all.ps1
```

`b2 runtimes` builds all five stubs from Ring's VM source; `b3 cross` builds
on Windows for Linux x64 and runs the result under WSL; `b3 no-qt` puts the
Qt exclusion back and confirms the silent-crash package reappears, because a
refusal nobody has watched fail is not known to work.

The mobile results in §4 are three `zig cc` invocations against
`D:\ring127\language\src`, reproducible in about ten seconds.
