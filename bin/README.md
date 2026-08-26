# The shipped `ringpp` binaries

One prebuilt CLI per platform, so **no user ever installs a compiler**.
All five are produced from the same source by Zig 0.15.2, cross-compiled
from one Windows host in about 90 seconds total.

**Grammar: `tree-sitter-ring` v1.1.1** (`b44d254`), vendored under
`vendor/tree-sitter-ring/` and statically linked into every binary here.
All five were rebuilt when the grammar was bumped — a shipped binary that
disagrees with the vendored source about what parses is the kind of
inconsistency nobody finds until a user reports it. Verified after the
rebuild: `bin/win64` and `bin/linux-x64` both accept
`tests/fixtures/tsring_issue2/case4_nested_digit.ring`, which the previous
grammar rejected.

| file | format, verified with `file(1)` | size | how far it is verified |
|---|---|---:|---|
| `win64/ringpp.exe` | PE32+ x86-64 | 3.4 MB | **run**: full gate, all corpora |
| `linux-x64/ringpp` | ELF x86-64, **statically linked** | 7.3 MB | **run** under WSL Ubuntu — see below |
| `linux-arm64/ringpp` | ELF aarch64, **statically linked** | 7.4 MB | built and format-checked only |
| `macos-x64/ringpp` | Mach-O x86_64 | 3.1 MB | built and format-checked only |
| `macos-arm64/ringpp` | Mach-O arm64 | 3.0 MB | built and format-checked only |

## What "verified" means here, exactly

**Windows and Linux x64 were executed.** The Linux binary was run under
WSL Ubuntu against the same fixtures as the Windows one:

- `ringpp version` and `ringpp why R4` produce correct output
- `ringpp check tests/fixtures/lint_bad.ring` reports the **identical
  rule set** to the Windows binary
- `ringpp check tests/fixtures/xfile` reproduces the whole cross-file
  layer — the arity report naming its defining file, the `C22` duplicate
  at the join, and silence on the independent programs — with paths
  correctly rendered `/`-separated instead of `\`

That last one matters: path normalisation is the part of the project
layer most likely to differ between platforms, and it does not.

**The other three were not executed**, because this machine cannot run
aarch64 or macOS code. They are compiled from identical source by the
same compiler, and `file(1)` confirms each is the format and architecture
it claims — but *compiled and correct are different words*, and this
table says which applies.

If you run one of the three, `ringpp version` then
`ringpp check tests/fixtures/xfile` is the two-command smoke test. A
report of either working or failing is welcome.

## Why the Linux binaries are the big ones

They are linked against **musl, statically** — no glibc version
dependency, so one file runs on any Linux from an old CentOS to a current
Ubuntu. That portability costs about 3.7 MB against a dynamic glibc
build, and it is worth it for a tool people install rather than build.

## Why symbols are kept

All five are `ReleaseSafe` **with debug info**. Stripping the Linux
binaries halves them (6.7 → 3.0 MB, measured) and would take the package
from 22.6 MB to about 15 MB.

Symbols are kept anyway, deliberately: this checker produced three false
positives on its first real corpus runs, and a young tool that crashes on
someone's project should hand them a stack trace worth pasting into a bug
report. When the rules have settled, add `.strip = true` to the module in
`build.zig` and the 7 MB comes back.

## Rebuilding them

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl  -j2
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -j2
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos      -j2
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos       -j2
```

`-j2` is not optional on the maintainer's machine — see the headroom rule
in [`CLAUDE.md`](../CLAUDE.md).

Cross-compiling needed one source change: tree-sitter's `parser.c` and
`tree.c` call `fdopen()` for debug output, which `-std=c11` does not
declare on glibc, musl or macOS. `build.zig` now passes
`-D_POSIX_C_SOURCE=200809L` and `-D_DARWIN_C_SOURCE`. The Windows build
never noticed.
