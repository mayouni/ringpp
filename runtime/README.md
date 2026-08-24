# The Ring runtime stubs

Five Ring 1.27 VM binaries, one per platform, that `ringpp build` (B3)
attaches bytecode to. **These are not the `ringpp` CLI** — that ships from
[`bin/`](../bin/README.md). This is Ring itself, compiled from Ring's own
source by Ring++, so a packaged program needs no separate install of Ring
to run.

Built by [`tests/b2_runtimes.ps1`](../tests/b2_runtimes.ps1), which
generalises the mechanism [F-29](../docs/FINDINGS.md) proved for one
target: `zig cc` against `D:\ring127\language\src\*.c`, one target triple
per platform, no vendoring, no patching.

| file | target triple | size | how far it is verified |
|---|---|---:|---|
| `win64/ring.exe` | `x86_64-windows-gnu` | 500 KB | **executed**, output diffed against Ring's own official build |
| `linux-x64/ring` | `x86_64-linux-musl` | 2.8 MB | **executed** under WSL, output diffed against Ring's own official build |
| `linux-arm64/ring` | `aarch64-linux-musl` | 2.9 MB | built and format-checked only |
| `macos-x64/ring` | `x86_64-macos` | ~0.4 MB | built and format-checked only |
| `macos-arm64/ring` | `aarch64-macos` | ~0.5 MB | built and format-checked only |

Same split as `bin/README.md`, for the same reason: this machine can
execute x64 Windows and x64 Linux (under WSL) and nothing else. The other
three are compiled from identical source by the same compiler and
confirmed to be the right format and architecture — **compiled and
correct are different claims**, and this table says which applies to
each.

## What "executed... diffed against the official build" means

Not bytecode portability — that is B0's question, already answered
([F-29](../docs/FINDINGS.md)). This is a narrower one: **does a runtime
we compiled from Ring's own source behave like the one Mahmoud ships?**
For win64 and linux-x64, a fixture exercising integer arithmetic, float
formatting, string case and loop accumulation is compiled and run through
the stub, and the output must match `D:\ring127\bin\ring.exe` exactly.

## One file, not two — a stricter claim than the official build

`ring.exe` here needs **no companion `ring.dll`**. Compiling
`language/src/*.c` directly links the whole VM into one binary; deleting
`ring.dll` from the directory and re-running the fixture produced
identical output. The official distribution ships the VM as a separate
DLL — for its own reasons, likely a shared-load path across Ring's tool
family — but nothing about the VM requires it. Every platform here is one
file. (See the refinement note on F-28 in `docs/FINDINGS.md` — the
two-file, 1.3 MB claim was measured against the *official* build; this is
smaller and stricter.)

## Rebuilding

```bash
powershell -File tests\b2_runtimes.ps1
```

Needs `zig` on `PATH` and a Ring source tree (`D:\ring127\language\src`
by default, `-RingSrc`/`-RingInc` to point elsewhere). Prints `SKIP` with
a named reason when either is absent — never a silent no-op. ~6 seconds
for all five targets on this machine.

## Not yet shipped

These are build **outputs**, produced by the script above, not (yet)
committed binaries the way `bin/` is. Whether they belong in the
repository the same way — and under what size and `.gitattributes`
policy — is a B3 question, once `ringpp build` is the thing that actually
consumes them.
