# `ringpp` — the CLI, as it actually exists

*Rewritten 2026-08-25, replacing a document that described the CLI as
planned before the 2026-08-23 strategic reframe. Every example below is
a **real captured run** against the binary in this repository, not
invented output — the previous version's failure was describing commands
(`build` needing a C compiler, `doctor`, `vendor`) that were never built.
Verify anything here yourself: every command shown works exactly as
printed.*

---

## What ships today

Five commands: `check`, `why`, `deps`, `build`, and the undocumented
`ast`. All compiler-free — the CLI needs nothing beyond itself and,
for `build`, a working `ring` to shell out to for compilation.

```
$ ringpp help

+-------------------------------------+
|  Ring++ v0.1.0 -- Ring, two levels  |
+-------------------------------------+

Analyse

  ringpp check [path]         Type-check and lint; no run, no build     (always available)
  ringpp why <thing>          Explain a rule, a finding, or a Ring error code
  ringpp version              Show version
  ringpp help                 This screen

  `why` takes what you have in hand: a rule `check` printed
  (rpp/empty-catch), a finding (F-16), or the Ring error code you
  actually saw (R4). `ringpp why` alone lists everything it knows.

Package

  ringpp deps <file.ring> [--ring <dir>]
                               Native libraries this program can reach; no compiler
  ringpp build <file.ring> [options]
                               Bytecode + a runtime stub + declared native libs, one
                               package. `ringpp build -h` for the full option list.

Not built yet: probe, bench, run, emit, dist, doctor, vendor.
```

**That last line is load-bearing.** It is printed by the binary itself
(`src/main.zig`), not a claim in this document — so it cannot go stale
the way the previous CLI.md did. If it ever disagrees with this file,
believe the binary.

---

## `ringpp check` — type checking and lint, no run, no build

```
$ ringpp check tests/fixtures/lint_bad.ring

tests/fixtures/lint_bad.ring
  24:23  error  rpp/varptr-unknown-name
          varptr(:cBufferData) — no variable 'cBufferData' is assigned anywhere in this file
          varptr resolves the name in the current scope, then globals. An unknown
          name raises Error (R6), which a surrounding try/catch will swallow
          silently — leaving a NULL pointer and a dead code path. See FINDINGS
          F-2.
  37:9  warn   rpp/empty-catch
          empty catch — this leaks a VM stack slot per caught error
          ...
  45:21  perf   rpp/substr-in-loop
          substr() inside a loop
          ...

  1 error, 1 warn, 1 perf, 0 note   in 1 files (1.6 KB, 6 ms)
  ringpp why rpp/varptr-unknown-name   for any rule above
```

**16 rules today**, spanning three layers, each traceable to a measured
finding — *no rule ships without a number behind it*:

| layer | rules | what it needs |
|---|---|---|
| lint (`src/check.zig`) | 9 — `varptr-*`, `memcpy-*`, `substr-in-loop`, `genarray-in-loop`, `empty-catch`, `method-shadows-builtin`, `unparsed` | tree-sitter parse only |
| level-1 types (`src/types.zig`) | 5 — `type-hints-missing`, `type-arity`, `type-arg-mismatch`, `type-return-mismatch`, `type-not-a-hint` | Ring's own annotation channel |
| cross-file (`src/project.zig`) | 2 — `type-duplicate-func`, `type-declared-conflict` | the load graph, `--ring <dir>` to follow into Ring's own libraries |

Zero false positives across Ring's own 1,959-file corpus and Softanza's
6,012 — the full case study, including the three false positives caught
and fixed along the way, is
[CASE-TYPE-SAFETY.md](CASE-TYPE-SAFETY.md).

---

## `ringpp why` — explain a rule, a finding, or a Ring error code

```
$ ringpp why R4

rpp/empty-catch
An empty catch block leaks one VM stack slot per caught error

  Symptom  Error (R4) : Stack Overflow, from code containing no recursion at
           all. It arrives after roughly 1,003 caught errors, so it survives
           every small test and fails in the loop that runs all day.

  Cause    Ring pops the raised value only when something in the handler
           consumes it. An empty handler leaves it on the VM stack, which is
           RING_VM_STACK_SIZE (1004) deep.

  Fix      Put any statement in the handler. One assignment is enough. If the
           intent really is to ignore the error, ignore it explicitly: catch
           bIgnored = TRUE done.

  Evidence bench/16_empty_catch_leak.ring — five arms, showing exactly which
           shape leaks

  Upstream ring-lang/ring#1644 — open. Reported as a behaviour, not a patch:
           ring_vm_catch() does restore nSP via ring_vm_restorestate(), and
           what puts the slot back was not isolated. Reporting beats guessing
           at a line.

  See      docs/FINDINGS.md F-16
```

**Three ways in**, because a user arrives with whatever they have in
hand: a rule (`rpp/empty-catch`), a finding (`F-16`), or **the Ring error
code they actually saw** (`R4`). The third is the one that earns the
command — a bare error code names no cause. `ringpp why` with no
argument lists the whole catalog:

```
$ ringpp why

Rules that `ringpp check` can print:

  rpp/memcpy-string-dest      F-1, F-5
  rpp/varptr-unknown-name     R6, F-2, F-3
  ... (16 rules total)

Also explained — traps with no rule, because a linter cannot see them:

  F-22      Ring copies objects on assignment — a cached address inside
  F-21      Every func after the first class becomes a method of that
  F-18      N and n are the same variable
  F-20      get and put cannot be method names
  F-23      A gate that asserts a mechanism fails when someone fixes the
```

**21 entries total**, kept honest by two compile-time tests: every rule
`check.zig` can emit must have a catalog entry (scanned out of the
source), and every `F-n` cited must exist as a heading in
`docs/FINDINGS.md`. Both were verified by breaking them on purpose.

---

## `ringpp deps` — what a program needs beside the bytecode

Exists because a `.ringo` is portable between x64 platforms but a native
extension it reaches is not, and the failure lands at run time on the
user's machine rather than at build time
([F-29](FINDINGS.md)).

```
$ ringpp deps tests/fixtures/lint_bad.ring

tests/fixtures/lint_bad.ring
  load closure : 5 file(s) reached
  ring root    : NOT SUPPLIED — `load "stdlib.ring"` and friends
                 cannot be followed. Pass --ring <dir> for the whole picture.

  No native library is reachable from here.
  This program is PURE RING: one .ringo plus a Ring runtime is all it needs,
  and that is portable between x64 platforms (FINDINGS F-29).
```

A program that reaches `load "stdlib.ring"` names every extension it can
touch — six, just to offer `upper()` — with the platform-specific file
name for each and the line that declares it. A program reaching Ring's
Qt bridge (`ringqt`) is flagged `OUT OF SCOPE (Qt)` and exits non-zero
rather than being listed as an ordinary dependency — see the section
below.

**Refuses rather than guesses.** With no `--ring <dir>`, `load
"stdlib.ring"` cannot be followed, so a program that reaches it reports
`NO VERDICT`, not `PURE RING` — an answer that looks clean and is
actually a measure of what the tool could not see is exactly the defect
this project has caught and fixed twice already
([`tests/fidelity.ps1`](../tests/fidelity.ps1)'s own history).

---

## `ringpp build` — assemble a runnable package, no compiler

```
$ ringpp build -h

usage: ringpp build <entry.ring> [options]

  --target <platform>   win64 | linux-x64 | linux-arm64 | macos-x64 | macos-arm64
                        (default: the platform ringpp itself is running on)
  --ring <path>         a working `ring` executable, used to compile the
                        entry point ( -go ). Default: search PATH.
  --ring-root <dir>     a Ring install, so `load "stdlib.ring"` and friends
                        can be followed (same meaning as `ringpp deps --ring`)
  --runtime <path>      an explicit B2 runtime stub for --target
  --runtime-dir <dir>   search <dir>/<target>/ring[.exe] for the stub
                        (default: alongside the ringpp executable, then ./runtime)
  --lib-dir <dir>       a directory holding the TARGET's actual native
                        library files, to bundle what `deps` names
  --out <dir>           output directory (default: <entry-basename>-<target>)
```

**Two shapes, neither rounded up to the other.** A program with no
native reach:

```
$ ringpp build hello.ring --ring D:\ring127\bin\ring.exe --out out

built  C:\Temp\cli_demo\out
  hello.exe
  hello.ringo

run with:  hello.exe hello.ringo
```

Verified in this repository's own gate by copying exactly those two
files to a clean directory with nothing else present and running them —
correct output, no Ring install, no `ring.dll`.

A program reaching `stdlib.ring`, with `--ring-root` and `--lib-dir`
pointing at a real Ring install:

```
$ ringpp build lib.ring --ring-root D:\ring127 --lib-dir D:\ring127\bin --out out-lib

built  C:\Temp\cli_demo\out-lib
  lib.exe
  lib.ringo
  ring_odbc.dll
  ring_mysql.dll
  ring_sqlite.dll
  ring_internet.dll
  ring_openssl.dll
  ring_pgsql.dll

run with:  lib.exe lib.ringo
```

**Not one file.** Ring's own binary does not auto-load a same-named
`.ringo`, and appending bytecode to the exe does nothing — both measured
directly before this command was designed around a wrong assumption
([`docs/DESIGN_BUILD.md` §2](DESIGN_BUILD.md#2-what-a-build-actually-is-then)).
The artefact is always this pair, invoked together.

**Refuses, harder than the happy path, in two places:**

- no `--ring-root` when the program reaches `load`s that cannot be
  followed → non-zero exit, `BUILD-MANIFEST.txt` says `INCOMPLETE
  PICTURE`, never a package that silently claims nothing is missing;
- a program reaching Ring's Qt bridge (`ringqt`, `ringqt_light`,
  `ringqt_core`) → refused **before any output is written at all**.
  Bundling only what static analysis can name for a Qt program produces
  a package that *looks* complete and then crashes with **no diagnostic
  whatsoever** — measured directly, Windows exit `0xC0000409`, zero
  bytes of output ([F-30](FINDINGS.md)). Per the project's own
  dependency-free principle, Ring++ does not package Qt programs at all.

A missing declared library that the closure *did* resolve is different
from either: `BUILD-MANIFEST.txt` names it `MISSING` and the command
still exits 0 — the maintainer's choice not to supply `--lib-dir` is not
the same defect as not knowing what was needed.

---

## `ringpp ast` — undocumented, real, and worth knowing about

Not on the help screen on purpose — it prints the grammar's raw view of
a file, which is a tool for developing `check`'s own rules, not for a
typical user:

```
$ ringpp ast somefile.ring
```

Every rule in `check.zig` is written against a specific node shape, and
guessing at that shape is how a false positive gets born. This is the
fastest way to settle a disagreement between what a rule expects and
what the grammar actually produced.

---

## What is genuinely not built, and where it went

- **`probe`, `bench`, `run`, `emit`, `dist`, `doctor`, `vendor`** — the
  binary's own `help` screen names these as not built; believe it over
  this document.
- **The compiled-kernel half (T3–T7)** — the tier system, `run`
  compiling hot functions, cross-compilation via a vendored Zig — was
  the design this document previously described in full. Descoped
  2026-08-23; the reasoning is in `docs/PHASE_PLAN.md`, the surviving
  research in `docs/DESIGN_TOOLCHAIN.md`. If it ever returns, it returns
  as its own proposal with its own gates, not by this file quietly
  growing the commands back.
- **A literal one-file build artefact** — `ringpp build` produces a pair,
  not a single self-modifying executable; a loader that embeds the
  bytecode and execs the runtime touches no VM source and is not ruled
  out, but is unbuilt and unscheduled
  ([`docs/PHASE_PLAN.md`](PHASE_PLAN.md), the build half).

---

## House rules that still hold

- **ASCII only in console output.** No emoji, no box-drawing beyond
  `+-|` — visible in every example above.
- **Rule ids are namespaced `rpp/…`** and every one traces to a
  `FINDINGS.md` heading, machine-checked at compile time.
- **`why`, `deps` and `build` are each their own module**
  (`src/why.zig`, `src/deps.zig`, `src/pack.zig`) with a uniform `pub fn
  run(...)` entry point that `src/main.zig` dispatches to directly.
  `check` and `ast` are driven from handlers inside `main.zig` itself,
  since neither has grown large enough yet to earn its own file.
