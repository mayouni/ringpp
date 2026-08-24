# P0 — Baselines

*Closed 2026-08-25, alongside P3 part 3 — see the note there for why
these two landed together. Every number below already existed in
[FINDINGS.md](FINDINGS.md) before this file was written; P0's own gate
only asks that they be gathered against the three chosen shapes with a
stated size. Nothing here is a new measurement.*

Three shapes, chosen from the target domains (banking, government,
consumer platforms — high data volumes, complex processing) rather than
from a code audit, per [PHASE_PLAN.md](PHASE_PLAN.md#p0--baselines-one-afternoon-not-a-permission-gate):

| shape | stand-in | size | today, Ring 1.27 | size basis |
|---|---|---|---:|---|
| a large record stream sliced field by field | [F-6](FINDINGS.md), `bench/08_string_ops_tax.ring` | 500 KB string | **12.5 µs** per 10-byte slice | **estimate** — chosen for the benchmark, not sourced from a production log |
| a dense numeric kernel (scoring, optimisation, ML inner loop) | K2, `bench/headroom/`, [DESIGN_TOOLCHAIN.md §7](DESIGN_TOOLCHAIN.md) | 1 M doubles | **92 ms** per dot product | **estimate** — a round number picked to be measurable, not a specific workload's array size |
| a wide table read out of order (reporting, reconciliation) | [F-9](FINDINGS.md), `bench/03_lists.ring` | 80,000-item list | **1562–1579 ms** for 80,000 permuted reads | **estimate** — chosen to keep `ringvm_genarray`'s cost visible above the timer floor, not a real table's row count |

**All three sizes are stated estimates, marked as such, per the gate's
own rule**: *"where a production size is not to hand, use a stated
estimate and mark it as such — an estimate that is written down can be
corrected; an unstated one cannot."* None of Ring++'s claims traces back
to a Softanza production log naming a real record-stream length, kernel
size, or table row count. If a real size ever supersedes one of these,
correct this file in place, dated, rather than replacing it silently —
the standing house rule for every other correction in this project.

## What this does and does not license

**Licenses:** citing these three numbers as "the shape this project
optimises for" — which is what every one of the eight `examples/`
already does.

**Does not license:** claiming any Ring++ speedup number was measured
*at* a real production size. It was measured at a size chosen to be
reproducible and to keep the effect above Ring's 1 ms `clock()` floor.
The two are not the same claim, and conflating them is exactly the
failure this project's own house rules warn against (`CLAUDE.md`, *No
claim without a number*).

## Why P0 was closed only now, alongside P3

P0's own gate says it may run in parallel with P1 and T1 and blocks
nothing — which is exactly why it sat untouched for the project's entire
life: nothing ever failed for its absence. It surfaced again while
closing P3 part 3, whose gate literally names *"workload #1 from P0"* —
and there was no P0 artifact to point at. Closing it here, using numbers
that already existed, cost nothing; the honest admission is that it
should not have taken finishing P3 to notice it was still open.
