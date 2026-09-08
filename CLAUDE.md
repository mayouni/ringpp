# Ring++

**Ring++ is dependency-free, and becoming independent.** The library half
needs nothing but a Ring VM: no other package, no extension, no DLL, no
sibling repository. Ring++ now builds that VM itself. It is developed
alongside Softanza and used by it, and is not part of it.

If you are an AI session working here, this file is the whole brief.

---

## The mission — restated by Mansour, 2026-09-07

**Ring++ is a bridge, and it is named as one.** Its job is to carry the
Softanza codebase and the customers depending on it off a platform whose
decisions sit with a single maintainer, and onto ground Mansour controls.
The destination is **Haro**, a new language built on the VM this project
produces. Ring++ is what keeps ~300K lines of existing Ring working while
that is built.

Five commitments, in order. Review every change against them.

1. **Sovereignty over the runtime.** Nothing the project depends on may be
   withdrawn by anyone else. The VM is built here, from source, per
   platform. Every remaining reach outside this repository is a defect to
   be closed, not a convenience to be relied on.
2. **The existing estate keeps running.** Softanza's code is the
   compatibility specification. That is what makes this a bridge rather
   than a rewrite, and it is why compatibility is decided **per defect** --
   keep, fix silently, break with a checker rule, or drop with a stated
   constraint -- never as a blanket promise.
3. **Performance and portability.** The two pillars upstream removed from
   the package description. They are the engineering case and they are
   measured, never asserted.
4. **Type safety for large projects**, through the vendored tree-sitter
   checker and the `typehints` channel. Still the strategic centre: it is
   the practical answer to a real bank engineering team whose remaining
   concern at scale was exactly this. (The team is not named in public
   documents.)
5. **One shipped binary.** The CLI is a single prebuilt Zig binary. No C
   compiler, no clang, no toolchain is ever required or suggested to a
   user. The Zig *source* is provided; only an adapter of the CLI installs
   the Zig compiler.

**The validation ladder, in order:** Softanza first, then RingServ,
RingScript and MicroRing. Each migrates to Ring++ and cuts its relation to
Ring. A release means those run, not that a registry accepts a manifest.

**Where the runtime actually stands, 2026-09-07.** `runtime/` holds five
Ring VM binaries built by `zig cc` from Ring's C source, one per platform,
with mimalloc linked (the Android allocator fix, `fa939f7`). Windows x64
and Linux x64 are *executed* and diffed against Ring's own build; the other
three are compiled and format-checked, and `runtime/README.md` keeps that
distinction visible. **The source is vendored** under `vendor/ring-vm/` --
80 files from Ring 1.27.0, byte-identical to upstream, MIT licence and
copyright carried with them -- so a clean clone builds its own runtime.
The gate `vendored VM` checks all 81 hashes on every run, and needs no
Ring, no compiler and no network to do it.

**Never verify a runtime change by comparing binaries.** The toolchain is
not deterministic: two `zig cc` builds of identical source on this machine
gave `3D177B27...` and `53FE874A...`. Compare the SOURCE, and test the
BEHAVIOUR -- `b2_runtimes.ps1` runs the result and diffs its output against
Ring's own build, for the two targets this machine can execute. And note
that `build/vmcgoto/vmcgoto.c` is part of the source, not an extra: without
it, `-DRING_VM_COMPUTEDGOTO=1` leaves `ring_vm_computedgoto` undefined.

**Open source, and not a strategy.** The projects stay public so the Ring
team can learn from the documented defects and their fixes if they choose
to. That is a courtesy, not a goal, and no work here is planned around
whether they do.

[docs/VM-CONTRACT.md](docs/VM-CONTRACT.md), machine-checked by
`rpp/probe.ring` on every load, is no longer a proposal to anyone. It is
the boundary this project owns and may change deliberately -- and the probe
is what tells you the day a change moved it.

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

That one is the deepest, and it is no longer the only one. The full defect
catalogue -- safety hazards, internal design, ergonomics, governance -- is in
`softanza/memos/2026-08-30-ringpp-design-charter.md`, each defect turned
into a design principle. More are recoverable from the Softanza repository
and its archive, where every workaround is a defect whose cost was already
paid.

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

**A divergence from Ring is not a finding — it is a decision, and it goes in
`docs/CORRECTIONS.md`.** `FINDINGS.md` records what Ring does;
`CORRECTIONS.md` records where Ring++ deliberately does something else, with
the verdict (keep / fix silently / break with a rule / drop with a
constraint), who decided, and **what the choice costs**. Every entry names
its cost, because a correction with no stated cost is a correction nobody
audited. Mansour decides these, one defect at a time — never as a blanket
policy.

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
- **`for i = 1 to len(s)` is O(n²) on a string.** The header is re-evaluated
  every iteration and each evaluation copies the whole string into `len()`;
  `while i <= len(s)` is worse. Hoist the bound (F-41). Lists are exempt —
  they pass by reference. Caught by `rpp/len-in-loop-header`.
- **`s[i]` on a string is a character on Ring and a CODE on Ring++** (F-54).
  `ascii(s[i])` agrees on both, which is why every bench hid it for weeks.
  Now that two runtimes exist, this is the trap most likely to bite.
- **Ring has NO string escapes, in any delimiter** (F-55). `"a\nb"` is four
  characters. `\"` does not escape the quote — it closes the literal and
  leaves the backslash in, sometimes without raising at all. Use
  `RppStr()` from `rpp/str.ring`; `ringpp expand` folds it away.
- **`char()` wraps modulo 256, silently** (F-56). `char(0x4E2D)` is byte 45,
  an ASCII hyphen; `char(0x1F600)` is byte 0, which F-14 then turns into a
  process death. A codepoint needs `RppStr("\uNNNN")`.

## Working rules

**Upstream.** *Never open a pull request or an issue on `ring-lang/ring`,
and never campaign anywhere.* The reason is no longer diplomacy: this
project has left. Anything that goes out at all goes out because **Mansour
sends it himself** — prepare text if asked, never send it. Strategic
documents about replacing Ring stay private. Credit generously in anything
public; the engineering argument is the only one this project makes.

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
fifteen examples. One optional gate scans an external corpus when present
and prints `SKIP` with its reason when not.

Both gaps this section used to name are **closed, 2026-09-07**:

- ~~No gate builds the VM from vendored source~~ — `vendored VM` checks the
  manifest and `b2 runtimes` builds all five platforms from it.
- ~~No gate installs the package~~ — **there is no package.** `package.ring`
  was deleted: Ring++ ships as a repository, cloned or copied, and the
  library is relocatable. The manifest had drifted badly enough to prove the
  point — its `:files` omitted `rpp/tui.ring`, which `ringpp.ring` loads, so
  an install from it could not complete `load "ringpp.ring"` (`Error (E9)`),
  and `str.ring`, `memo.ring` and 7 of the 15 examples were missing too.

**The shape both had is worth remembering**, because the next one will look
like this: a gate that passes because it runs where the files happen to
exist. If a claim is about a machine that is not this one — an install, a
clean clone, another platform — build that condition and test it, or say
plainly that it is untested.
