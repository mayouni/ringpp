# Upstream material

> **Nothing here is sent unless Mansour asks explicitly, after reviewing it
> himself.** That is the standing rule; a finding that feels important does
> not reopen it.

`ring-lang/ring` has **issues and discussions disabled**, so the channels
are pull requests and the Ring Google Group. Mahmoud develops Ring in
**PWCT**, so C patches get reimplemented there rather than merged as-is —
**a finding travels better than a patch**. Every item below leads with the
reproducer and points at the cause; a patch is attached only where the fix
is one condition and has been built and regression-checked.

## Status

| | item | target | patch | status |
|---|---|---|---|---|
| 1 | [memcpy, zero-byte source](memcpy-nul-source/) | ring-lang/ring | yes, verified | **APPLIED** — [#1643](https://github.com/ring-lang/ring/pull/1643) closed with *"will revise/fix using PWCT"*, then applied as [`8675fe3a`](https://github.com/ring-lang/ring/commit/8675fe3a761791932e14dcd299a93de9093a0c1c) (`ring_vm_api_ispointer`) + tests [`834ecd68`](https://github.com/ring-lang/ring/commit/834ecd68795ceb195099137560865b173dd68579), [`9ddcc7ee`](https://github.com/ring-lang/ring/commit/9ddcc7ee8de2fa97f6de8c56b9fc340a5154f766) |
| 2 | [empty catch grows the VM stack](empty-catch-stack/) | ring-lang/ring | yes, verified | **APPLIED** — [#1644](https://github.com/ring-lang/ring/pull/1644) closed, fix landed as [`cda2ecf0`](https://github.com/ring-lang/ring/commit/cda2ecf05a39c0e7268623f918934157fe64c603) (*"Free stack when we catch an error"*) + test [`22beec8c`](https://github.com/ring-lang/ring/commit/22beec8cc999f520d6bf0ab8d7e8f28dcb152f80) |
| 3 | [`ring_state_findvar` name case](state-findvar/) | ring-lang/ring | yes, verified | **APPLIED** — [#1645](https://github.com/ring-lang/ring/pull/1645) closed, fix landed as [`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094) + test [`ed69e68`](https://github.com/ring-lang/ring/commit/ed69e6824652025651638e6ee7d7262b2accba08), credited to Mansour Ayouni and Youssef Saeed |
| 4 | [two pointer-API doc notes](pointer-api-docs/) | ring-lang/ring | docs only | **CLOSED** — [#1646](https://github.com/ring-lang/ring/pull/1646), declined with reasons worth keeping (below) |
| 5 | [grammar findings](tree-sitter-ring-notes.md) | ysdragon/tree-sitter-ring | no | **FIXED upstream** — [issue #2](https://github.com/ysdragon/tree-sitter-ring/issues/2) fixed by Youssef Saeed in [`287afffb`](https://github.com/ysdragon/tree-sitter-ring/commit/287afffb), shipped as v1.1.1. Re-measured 2026-08-23: wrongly-rejected files **18 → 11** across 10,233, seven fixed, no regressions. Issue still open pending our confirmation. |
| 6 | [reply with the re-measured number](tree-sitter-ring-issue2-reply.md) | ysdragon/tree-sitter-ring#2 | no | **DRAFTED, NOT SENT** — the confirmation that closes #2. Mansour posts it. |

**One item is pending:** the reply at row 6. It is written and waiting on the
author — it carries a correction of a number this project already published,
so it should not go out unread.

## Considered and deliberately not sent

| finding | why not |
|---|---|
| **F-22** — a pointer cached inside an object dangles once the object is copied | Not a Ring defect. `documents/source/usingref.txt` already states it in two lines (35: assignment copies by value; 36: adding a list/object to a list creates a copy) and documents `ref()` as the remedy. A note would restate the chapter to an audience Mahmoud describes as expecting to know pointers and memory management — the reason [#1646](https://github.com/ring-lang/ring/pull/1646) was declined. |
| **F-17** — a method shadows a same-named builtin inside its class | Language design, not a bug. It is a `ringpp check` rule instead. |
| **F-18** — `N` and `n` are the same variable | Documented case-insensitivity. |
| **F-21** — every `func` after the first `class` becomes a method | Documented file structure. |

These live in [FINDINGS.md](../docs/FINDINGS.md) and drive lint rules; they
are not upstream material. The test for sending is *"does Ring behave other
than as documented, or crash?"* — not *"did this cost me a day?"*

## Documentation: the standard, from #1646's rejection

Mahmoud declined the doc notes, and the reasons generalise:

1. **Write at the chapter's declared audience.** `lowlevel.txt` opens by
   saying it is for C/C++ developers building Ring libraries, *expected to
   know pointers and dynamic memory management*. Explaining that a string
   argument is copied so the write lands on the copy reads to them like
   *"one apple plus another apple is two apples"*.
2. *"One of the known disadvantages of using AI to write/improve
   documentation is writing too much (repeating sentences & adding
   unnecessary info)."*
3. **Document the correct behaviour only.** For low-level functions,
   document what happens when used *correctly*; failure modes are handled
   during revisions and stated specifically then. That chapter is not part
   of the language — it is a tool for specific cases.

The lesson for this project: cataloguing silent failure modes is exactly
right for [FINDINGS.md](../docs/FINDINGS.md) and the `ringpp check` rules,
and exactly wrong as an upstream documentation contribution. Read the
chapter's opening paragraphs first, and prefer no note over an obvious one.

## What the outcomes say so far

| PR | shape | outcome |
|---|---|---|
| #1639 | two C fixes | closed — but **applied** six days later, [`7acf95bf`](https://github.com/ring-lang/ring/commit/7acf95bf) + [`4014382a`](https://github.com/ring-lang/ring/commit/4014382a) |
| #1643 | one C fix + test | closed — but **applied**, [`8675fe3a`](https://github.com/ring-lang/ring/commit/8675fe3a) |
| #1642 | **a finding**, diff offered as illustration | **merged** |
| #1645 | fix + test, framed as a finding | closed — but **applied**, credited, and widened from one function to four |
| #1644 | fix + test, framed as a finding | closed — but **applied**, [`cda2ecf0`](https://github.com/ring-lang/ring/commit/cda2ecf0) |

> **Corrected 2026-08-15.** This table previously recorded #1639 and #1643 as
> *"closed unmerged — will fix using PWCT"* and #1644 as *open*. All three had
> been implemented. The rule stated below was already written here and had
> never been applied backwards to the pull requests that preceded the one that
> taught it. The full register is at
> [`ringupstream/REGISTER.md`](https://github.com/mayouni/ringupstream).

The one that merged was framed as a finding with the diff offered as
illustration. That is the shape to prefer — and #1645 shows why more
sharply than #1642 did. **The PR being closed is not the outcome; the
commit is.** Mahmoud reimplements in PWCT, so a closed PR whose fix lands
under his own commit with credit is a *success*, and reading the PR state
alone would have recorded it as a failure. Check the commits before
concluding anything about a closed PR here.

#1645 also earned more than it asked for: it reported one function, and
Youssef Saeed's follow-up turned it into four — including
`ring_state_newvar`, whose failure mode (a variable that exists and
cannot be addressed) was worse than the one reported. A finding invites
that; a patch does not.

**Withdrawn as duplicates**, checked against the RingScript session:

- `ringvm_genarray` documentation — already carried by their item 5 and
  **merged as [#1642](https://github.com/ring-lang/ring/pull/1642)**.
- the string-argument copy — their item 3, drafted and not yet sent. One
  case, one thread.

## How each was verified

Ring 1.27's `language/` builds from source with `zig cc -O2` in ~6 s
(44 `.c` files, `ringw.c` excluded). Items 1 and 3 were built twice —
identical sources but for the patch — and compared:

- **Item 1**: exhaustive over the four classes of string argument that can
  reach the changed branch; character-identical output except the `memcpy`
  calls that used to abort.
- **Item 3**: every case variant now resolves; all six tests under
  `language/tests/scripts/` that use `ring_state_*` byte-identical.

Item 2 has a five-arm reproducer showing exactly which shape leaks
(`bench/16_empty_catch_leak.ring`) but no patch — `ring_vm_catch()` does
restore `nSP` via `ring_vm_restorestate()`, and I could not isolate what
puts the slot back. Reporting the behaviour beats guessing at a line.

Item 5's disagreement rate is **~0.16%** (9 files of 5,566), measured by
running the vendored grammar over Softanza and Ring's own corpus and
letting `ring -norun` adjudicate every disagreement.

## If any is ever sent

Fork, branch, apply, PR — the mechanics used for #1643 are recorded in
[`memcpy-nul-source/README.md`](memcpy-nul-source/README.md). The
repository is 3.7 GB, so use the Git Data API rather than cloning, and
patch the **exact bytes** of the current `master` file so line endings and
unrelated lines stay untouched.

**Encoding, learned the hard way.** Windows PowerShell 5.1's
`Get-Content -Raw` decodes UTF-8 as Windows-1252, so any read-modify-write
through it turns `—` into `â€"`, `×` into `Ã—`, `µ` into `Âµ` — and
`Set-Content -Encoding utf8` adds a BOM. That corrupted eight files here
and three PR bodies that were live on GitHub before it was noticed.

**Never build a `--body-file` by PowerShell round-trip.** Write the file
with an editor that emits UTF-8 and hand it to `gh` from Bash untouched.
Before and after any bulk edit:

```bash
grep -rl 'â€\|Ã—\|Âµ' --include=*.md --include=*.ring --include=*.zig .
```
