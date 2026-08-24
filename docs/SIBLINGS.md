# How RingScript, RingServ and MicroRing could benefit from Ring++

*Measured 2026-08-25. Three read-only investigations — `ringpp check` and
`ringpp deps` run against each sibling's own source, plus a targeted grep
for the code shapes Ring++'s library targets. No file in any sibling
repository was edited; this project does not write to sibling
repositories (`CLAUDE.md`'s estate rule). Two real defects in Ring++'s
own published claims were found and fixed along the way — see
[F-23](FINDINGS.md#f-23-a-patched-vm-can-make-a-ring-idiom-worthless--and-the-gate-must-say-so)
and the WASM row in [DESIGN_BUILD.md §3](DESIGN_BUILD.md#3-targets--measured-plausible-and-not)
— which is the reason to run this kind of check periodically rather than
once.*

## RingScript — Ring in the browser

**`ringpp check` on the project's own `.ring` source** (excluding the
generated `tests/doc-snippets` corpus): zero errors, zero warnings. The
only hits are `rpp/substr-in-loop`, real and worth naming:

- `main.ring:29` and `lib.ring:196` (`RingScriptBaseName`) — the *same*
  hand-written backward char-scan, duplicated in two files.
- `lib.ring:75`, `playground/json-reference.ring` (7 hits),
  `src/ringlib/json.ring` (7 hits), `src/ringlib/stzZql.ring` (9 hits) —
  tokenizer/parser code, the textbook shape.
- `samples/route-orders/orders.ring` — 4 hits.

**`ringpp deps`**: every entry point checked reports **PURE RING** — no
`loadlib`/`loadlibfile` anywhere in the project's own code. `ringpp
build` is a clean technical fit for packaging RingScript's own tooling,
though RingScript already ships its own cross-compiled binaries by a
different route (see the RingServ section — the same is true there).

**The strongest finding: RingScript independently built `RppIndexed` by
hand.** `playground/lib/table/table.ring:44-72` carries its own staleness
flag (`lTableIndexed`), its own break-even floor
(`nTableIndexFloor = 64`), explicit `ringvm_genarray()` calls in
`TableIndex()`, and an invalidator (`TableTouch()`) — the same shape
`RppIndexed` packages as a library. This is validation, not competition:
a sibling converged on the idiom without adopting it.

**A real correction this investigation produced**: F-23 claimed
RingScript's vendored VM made `RppIndexed` redundant, on the strength of
a vendor patch that RingScript itself withdrew eight days before F-23 was
written (`ringscript/docs/VENDOR_PATCHES.md` §8 — rejected upstream by
Mahmoud Fayed, 1.7–2.3× *slower* on mixed workloads). Re-measured fresh,
both VMs behave identically now. Full account and corrected numbers in
FINDINGS.md.

**A real correction to Ring++'s own WASM claim**: `DESIGN_BUILD.md` said
Ring's only WASM story was Qt-WASM samples. RingScript compiles the bare
Ring C VM to `wasm32-wasi` directly with `zig cc` — no Emscripten, no Qt
(`build.zig`: `.cpu_arch = .wasm32, .os_tag = .wasi`,
`wasi_exec_model = .reactor`). This is a real, checkable reference for
extending B2's cross-compilation to a WASM target, not researched by
Ring++ until this investigation found it already solved next door.

**A genuine, larger opportunity, honestly scoped as bigger than a swap**:
`src/bridge.zig:349` isolates crashes with `try eval(...) catch
rs_reporterror(...) done` — same-VM try/catch, not `ring_state_*`
sub-state isolation, so global pollution across evaluations is possible.
`RppSandbox` would be a genuine upgrade, but adopting it means
restructuring the bridge's eval model, not a drop-in replacement.

## RingServ — Ring on the server

**`ringpp check` on `src/ringlib/*.ring`** (RingServ's Ring-authored
app layer — its engine is Zig/C, Ring hosts services inside it): **0
error, 0 warn, 27 perf, 0 note** across 15 files. All 27 are
`rpp/substr-in-loop`, concentrated in one place:

- `json.ring:159,178,267,390,407,482,491` and `jsserv.ring:112,130,163,
  217,225,228,241` — the JSON encode/decode path.
- `journal.ring:150(×2),160`, `config.ring:59,77,83,169`,
  `gesture.ring:54,56,63,74,75,82`, `main.ring:29`, `lib.ring:24,90`.

**A concrete, numbered `RppBuffer` candidate**: `json.ring:152-194`
(`JsonEncode`) builds output with `cOut = cQ` then repeated
`cOut += substr(...)` inside nested loops — Ring's default O(n)-per-append
rebuild, on the exact path `journal.ring`, `family.ring`, `jsserv.ring`,
`sync.ring` and `serv.ring` all call to serialise every response. This is
real and specific; whether the win is *meaningful* depends on RingServ's
actual payload sizes, which this investigation did not measure — a
follow-up for whoever owns that repository, not a claim to make from
outside it.

**Empty-catch — genuinely absent, and worth saying plainly rather than
searching until something is found.** Every one of ~24 `catch` blocks in
RingServ's own `.ring` files does something in the handler (`return
RsRefuse(400,...)`, `raise(cCatchError)`, a rollback call) — none empty,
none discard-and-fall-through. `ringpp check` corroborates this: zero
`rpp/empty-catch` hits. RingServ's own error-boundary discipline already
avoids this bug class.

**Packaging — already solved, by a different and *correct* route.**
RingServ ships prebuilt Zig cross-compiled binaries for the same five
platforms Ring++ targets, built by its own `build.zig` and CI. `ringpp
build` targets pure-Ring entry points with no C compiler; RingServ's
binary is Zig/C-native with an *embedded* Ring VM, a different shape
`ringpp build` was never designed for. It does not apply here, and
saying so is the honest reading, not a gap to close.

**A real limitation in Ring++'s own tool, found by testing it against
real code**: `ringpp deps` on RingServ's `main.ring` only reached one
file, because RingServ self-loads `lib.ring` via `eval('load "..."')`
rather than a static `load` statement — invisible to `deps`'s static
scan by construction. Not fixed here (out of scope for a read-only
investigation), named so it is not forgotten:
**`ringpp deps` cannot see a `load` reached through `eval`.**

## MicroRing — Ring on the device

**The headline finding: MicroRing's own tier split lines up almost
exactly with a boundary Ring++ already drew independently.** MicroRing
names three tiers (`readme.md`): **Tier 1** — Raspberry Pi / Linux,
*"trivial and first,"* currently shipping (`zig build release` already
produces static `aarch64`/`arm`-musl Linux binaries). **Tier 2** —
RP2350+PSRAM bare-metal MCU, *"the heart of the project,"* unbuilt.
**Tier 3** — ESP32-C/RISC-V bare metal, unbuilt. Ring++'s own
[DESIGN_BUILD.md](DESIGN_BUILD.md) ruled bare-metal microcontrollers out
of scope and Linux-class embedded in — Tier 1 is the second, Tiers 2/3
are the first. **Both readings are true of one repository, at different
tiers**, confirmed by MicroRing's own architecture docs rather than
assumed from outside.

**`ringpp check`**: 0 error, 0 warn, 0 perf, 0 note across all 54 `.ring`
files. Genuinely clean — not an omission, an actual result.

**`ringpp deps`**: every entry point reports **PURE RING**, consistent
with `devlib`'s own stated charter.

**One narrow, honest library-idiom match**: `src/devlib/device.ring:
786-810` (`MR_JsonStr`) is a textbook string-rebuild-in-loop, called from
`MR_WriteTrace` to build a `--trace` JSON file. But it runs on the
**host** during tracing, not device-resident — the code's own comment at
line 788 shows the author already avoiding the *worse* anti-pattern
(`s[i]`, not `substr(s,i,1)`), and the memory-scarcity argument that
would make this urgent on Tier 2/3 does not apply to host-side tooling.
A modest, real opportunity — not evidence of a device-side problem,
because there isn't one here yet.

**`ringpp build` applies to Tier 1 only** — ordinary static-linked Linux
ARM, the same territory as any other sibling's Linux arm64 target — and
has **zero applicability to Tiers 2/3**, which is most of MicroRing's
stated ambition. Those use MicroZig/ESP-IDF firmware builds, correctly
outside what Ring++'s runtime-stub mechanism was ever designed for.

## What this adds up to

| | files checked clean | perf hits (all `substr-in-loop`) | concrete idiom match | packaging fit |
|---|---:|---:|---|---|
| RingScript | all, 0 error/warn | ~28 | `RppIndexed`, independently hand-built | technical fit, but redundant — already solved |
| RingServ | all, 0 error/warn | 27 | `RppBuffer` — `json.ring:152-194` | does not apply — different artefact shape |
| MicroRing | all, 0 error/warn | ~1 (host-side, minor) | none urgent | Tier 1 only; Tiers 2/3 out of scope by design |

**Zero dormant bugs found across three real, substantial codebases** —
unlike the run against Ring's own stdlib and Softanza, which found real
R19/R20/C22 defects. That is itself the finding: these three projects
are already disciplined about the bug classes `ringpp check` targets.
What Ring++ offers them is not bug-finding here — it is the buffer
idiom in two of the three, and, in RingScript's case, evidence that its
own hand-built solution already matches Ring++'s design.

**One real gap in Ring++'s own tooling, found by using it**: `ringpp
deps` cannot follow a `load` reached through `eval(...)`, which is
exactly how RingServ's own entry point works. Not fixed in this pass —
recorded so it is not lost.

**Two real corrections to Ring++'s own published claims**, both caught
by this investigation and neither found any other way: F-23's central
table was measuring a VM patch that no longer existed, and
`DESIGN_BUILD.md`'s WASM row was wrong about what "Ring's only WASM
story" actually was. Both are the kind of finding this document exists
to produce — evidence that changes a conclusion, not evidence that
confirms one everyone already believed.
