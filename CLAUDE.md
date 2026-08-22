# Ring++

**Ring++ is an independent project.** It depends on nothing but Ring itself:
no other package, no extension, no DLL, no sibling repository. It is
developed alongside Softanza and used by it, and is not part of it.

If you are an AI session working here, this file is the whole brief.

---

## The thesis, and why it is not "pointers are fast"

Ring++ does **not** exist because pointers beat Ring operations. On most work
they lose — measurably, by 3–28×, because every crossing from Ring into a C
function costs ~100 ns and the pointer route needs more crossings.

It exists because of one structural fact, measured in `docs/FINDINGS.md`:

> **A Ring string is copied every time it crosses a call boundary.
> A list is not.**

`RING_VM_STACK_PUSHCVAR` (`vm.h:230`) is a byte copy onto the VM stack.
Everything expensive about data-heavy work in Ring traces to that macro, and
everything Ring++ can honestly offer is a way of not paying it.

The target is banking, government and consumer platforms — high data volumes,
complex processing, optimisation, ML and AI. **Never gate the project on a
workload census**; those domains are the justification.

## No claim without a number

Every rule, every idiom and every example traces to a measurement in
`docs/FINDINGS.md`. **No rule ships without a number behind it.**

- **A/B on two builds or two code paths differing in exactly one thing**, on
  Ring 1.27 (`D:\ring127\bin\ring.exe`).
- **Report minima over repetitions**, never a single run. A single run once
  published `substr` at 53 µs and a 50,000× ratio; the true figures were
  12.5 µs and ~140×.
- Two significant figures. Say **"below the timer floor"**, never "0" —
  `clock()` has 1 ms resolution.
- **Always state the pattern the change HURTS.** A benchmark that shows only
  its good case is marketing. Three of the eight examples conclude that
  Ring++ is the wrong tool for the shape they demonstrate, and that is what
  makes the other five believable.

If a measurement disagrees with `FINDINGS.md`, **investigate before
publishing**. Example 08 disagreed by 13× and the gap turned out to be the
safety wrapper; example 07 disagreed by two orders of magnitude and the gap
was sub-state creation. Both became the useful half of their example.

## Examples are gates, not brochures

Each `examples/NN-*/example.ring` holds the raw-Ring path and the Ring++ path
side by side in one file, and:

1. **asserts byte-identical output BEFORE printing any speed number** — a
   false speed claim must not be able to reach the pass line;
2. prints the A/B, minima over repetitions;
3. states where Ring++ loses;
4. ends with `EXAMPLE nn OK`, which is what the runner looks for.

`examples/run-all.ps1` runs them **leashed** (see below) and is wired into
`tests/run-all.ps1`. Documentation that is not executed goes stale silently;
here a stale example fails the build.

## Never flood the machine

**Measured 2026-08-21 by freezing this machine three times.** A session
backgrounded `zig build` on a vendored engine — 186 steps compiling ggml,
wgpu, HarfBuzz, PCRE2, SQLite, libcurl, libuv and mbedtls — and ran repo-wide
scans while it built. Two hard freezes. Then it froze a **third** time on an
already-capped `zig build -j2` with nothing else running:

```
RAM        31.6 GB
PAGE FILE   2.0 GB     <-- the whole problem
```

With no virtual-memory cushion this machine does not slow down under
pressure — it stops dead and only a restart recovers it. One compile of
tree-sitter's `parser.c` (21 MB of generated switch statements) takes several
GB by itself. **Capping parallelism is necessary and NOT sufficient**: ask the
machine for its actual free memory at the moment of the call.

- **Never background anything that builds or scans.** Backgrounding hides
  load, it does not reduce it — and the hidden load is what the next command
  gets piled onto.
- **Cap every native build**: `zig build -j2`. The default is one job per core.
- **One tree scan at a time.**
- **Price it out loud first.** Anything that compiles third-party sources or
  scans >1,000 files gets a sentence saying what it costs and a chance to say
  no. Slow is fine; a dead machine is not.
- **After any freeze**: kill stray processes, delete scratch files written
  into someone's repository, and confirm their work survived
  (`git diff --numstat`) before anything else.

A gate you could not run is **named and explained**, never quietly skipped —
and *"I could not run it without risking the machine"* is a legitimate reason.
`tests/run-all.ps1` prints `SKIP` with a reason for its one optional gate.

## Keep the loop short

**Edit to verdict targets SECONDS.** A monolithic suite is a pre-commit gate:
run once per task, never after every edit.

- **Probe first** — a new guard is born standalone, folded in only when green.
- **A scoped run PRINTS what it skipped, by name.** Coverage dropped silently
  is a green nobody earned.
- **`substr(s, i, 1)` on a big string is NOT cheap — it copies.** Measured on
  Ring 1.27: 316 µs per call on a 1.8 MB buffer against 0.07 µs for `s[i]`,
  same character returned. Use `s[i]`, or slice the row once and index inside
  the slice.
- **Name your fast path** — one process, many assertions. Process cold start
  is the tax nobody budgets.
- **Flaky is a latency defect** — a re-run is the most expensive wait there is.

## Ring traps this project has already paid for

All measured, all in `docs/FINDINGS.md`. `ringpp why <rule|F-n|code>` explains
any of them from the command line.

- **All functions before all classes.** Every `func` after the first `class`
  becomes a method of it (F-21).
- **Private attribute names must be prefixed** (`cRppData`, `nRppOff`). A
  class attribute silently clobbers a *caller's* variable of the same name,
  and a bare declaration creates no property at all (F-25). Gated by
  `tests/name_collision.ring`.
- **Never cache an address inside an object.** Ring copies objects on
  assignment and list insertion; the copy carries the original's address and
  the process vanishes with no message (F-22).
- **`memcpy` dies on a source string starting with a zero byte** on Ring
  ≤ 1.27 — every multiple of 256, every zeroed field (F-14).
- **An empty `catch` leaks a VM stack slot** — ~1003 of them is `R4` from code
  with no recursion (F-16).
- **`N` and `n` are the same variable.** Ring identifiers are
  case-insensitive (F-18).
- **`get` and `put` cannot be method names** (F-20).

## Working rules

**Upstream.** *Never open a pull request or an issue on `ring-lang/ring`.*
Findings go to the Ring Google Group and **Mansour posts them himself**.
Prepare the text; do not send it. The single exception is an explicit
instruction from him after he has reviewed it. A **finding travels better than
a patch** — Mahmoud develops Ring in PWCT, so C patches get reimplemented
rather than merged, and the one contribution that merged was framed as a
finding with the diff offered as illustration. **A closed PR is not the
outcome; the commit is** — check the commits before concluding anything.

**Encoding.** *Never round-trip text through PowerShell `Get-Content` /
`Set-Content`.* `Get-Content -Raw` decodes UTF-8 as Windows-1252 and
`Set-Content -Encoding utf8` adds a BOM. That corrupted eight files here and
three PR bodies that were already live. Use Python with explicit
`encoding='utf-8', newline=''`, and beware `\b` and `\f` in Python string
literals when writing Windows paths.

**Words name states, never people.** A term describes what an artefact *is*
and never reads as a verdict on whoever made it — so it is **uncommitted
work**, never a "dirty" tree.

## Running everything

```
powershell -File tests\run-all.ps1
```

Runs the Ring gates, the Zig unit tests, the lint and type gates, and all
eight examples. One optional gate scans an external corpus when present and
prints `SKIP` with its reason when not.
