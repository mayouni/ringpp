# Ring++ by example — a school of Ring's internal design

**These examples are the educational framework of the project, not its
marketing.** Each one takes an ordinary task, solves it twice — plain Ring
and Ring++, same file, same data — and asserts the two produce byte-identical
output before any number is printed. The *diff* between the two solutions is
the lesson, and the lesson is always about **Ring's own internal design and
its rationale**: why strings cross call boundaries by copy, why a list's
build order decides its read cost, why `substr` scales with the source, why
a sub-state is cheap to keep and expensive to create.

The goal is an advanced Ring programmer who takes maximum advantage of
Mahmoud Fayed's design **without fighting it or breaking its culture** — and
who learns, from a language deliberately built small and lightweight, the
*patterns of thinking* that made it so. That is why three of the eight
examples conclude that plain Ring is the right answer for their shape: the
curriculum is the equilibrium, not the speedup.

Every example here is **one runnable file** holding the raw-Ring way and the
Ring++ way side by side. Each one:

1. **teaches** — the two functions are adjacent, so the diff *is* the lesson
2. **runs** — a real task, on real data
3. **proves itself** — both paths must produce **byte-identical** output, and
   the example asserts it before printing any speed number
4. **measures** — prints the A/B, minimum over repetitions
5. **gates** — `examples/run-all.ps1` fails if either half regresses
6. **is the documentation** — each README quotes its own functions, so the
   prose cannot drift from the code

That last point is the reason for the shape. Documentation that is not
executed goes stale silently; here a stale example fails the build.

## Running them

```bash
powershell -File examples\run-all.ps1
```

They also run as part of the full gate, `tests\run-all.ps1`.

**Every example runs leashed** — a hard memory ceiling, a hard timeout, and a
system-wide free-RAM floor, enforced by the runner. This machine has 31.6 GB
of RAM against a 2 GB page file, so memory pressure stops it dead instead of
slowing it down. An example that loops gets killed and named; it cannot take
the machine with it.

## The rule every example obeys

**No speedup is printed without the correctness assertion passing first**, and
**every example states where it loses**. A benchmark that only shows its good
case is marketing, and this project's whole claim to be trusted is that its
numbers came with the pattern they hurt ([FINDINGS](../docs/FINDINGS.md)).

## The set

| | example | shows | traced to | status |
|---|---|---|---|---|
| 01 | [patch a large buffer](01-patch-a-large-buffer/) | in-place writes vs rebuilding the string | F-1, F-7 | **63×**, done |
| 02 | [pass a large value to a function](02-pass-a-large-value/) | *the thesis*: lists cross by reference, strings cross by copy | F-5 | **86x**, done |
| 03 | [random access into a big list](03-random-access-a-big-list/) | how a list was **built** decides its access cost | F-19 | **33x**, done |
| 04 | [slice a large string in a loop](04-slice-a-large-string/) | `substr` copies the whole string first | F-6 | **23x**, done |
| 05 | [scan a large file without copying it](05-scan-a-file-without-copying/) | composition — and it **found [F-25](../docs/FINDINGS.md)** | F-6, F-25 | **4x**, done |
| 06 | [a binary record codec](06-a-binary-record-codec/) | the zero-byte `memcpy` trap that **kills the process** | F-14 | **crossover**, done |
| 07 | [run generated Ring safely](07-run-generated-ring-safely/) | containment, not speed — `eval()` shares your variables | F-13, F-3 | **2.3x slower**, done |
| 08 | [**where Ring++ loses**](08-where-ringpp-loses/) | per-element access pays the safety tax on every element | F-15, F-4, F-22 | **28x SLOWER**, done |

**All eight are done.** Three of them (06, 07, 08) conclude that Ring++ is
the wrong choice for the shape they demonstrate, and one (05) found a live
bug in the library while being written. That spread is what makes the other
numbers believable.

Example 02 is the one that matters most. Everything else in Ring++ is a
consequence of the single measured fact that a Ring string is **copied every
time it crosses a call boundary** while a list is not.

Example 08 is deliberately a case where Ring++ **loses**, and it earned its
place: the measured slowdown came out **28x** where FINDINGS F-15 predicted
2.2x. Investigating that gap produced the most useful rule in the whole set --
`RppBuffer` is for **bulk** operations, because per-element access through a
safe wrapper pays the safety on every element. A curriculum that never shows
the tool failing has not taught anyone when to use it.
