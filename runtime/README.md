# runtime/ -- what the build and the measurements write

Nothing here is tracked but this file: everything in `runtime/` is produced by a script, and `.gitignore` keeps it out of the
repository.

## The oracle

Ring 1.27 itself, compiled from its own source (`vendor/ring-vm/`, vendored verbatim under its MIT licence) by
[`tests/b2_runtimes.ps1`](../tests/b2_runtimes.ps1) with `zig cc`, one binary per platform. **It is never shipped.** It exists
so that "Ring++ answers as Ring does" is a measurement: every probe, every A/B and every wide-suite comparison runs on it.

| file | target triple | how far it is verified |
|---|---|---|
| `win64/ring.exe` | `x86_64-windows-gnu` | **executed**: the reference every comparison on Windows is made against |
| `linux-x64/ring` | `x86_64-linux-gnu` | **executed** under WSL: the reference on Linux |
| `linux-arm64/ring` | `aarch64-linux-musl` | built and format-checked only |
| `macos-x64/ring` | `x86_64-macos` | built and format-checked only |
| `macos-arm64/ring` | `aarch64-macos` | built and format-checked only |

This machine can run x64 Windows and x64 Linux and nothing else, so the other three are compiled from the same source by the same
compiler and checked for format and architecture: **compiled and correct are different claims**, and the table says which
applies. The Linux binary is glibc, as Ring's own Linux build is: a static musl build cannot load a native library (F-83). The
Windows and Linux binaries are one file each and export Ring's C API, so a Ring extension loads against them with no `ring.dll`
beside them.

Ring's standard library (`vendor/ring-stdlib`) is laid out beside each binary the way Ring lays it out, because the programs
being compared load it.

    powershell -File tests\b2_runtimes.ps1

## The rest

    package/        the Ring++ packages, laid by bench/package.py: rnxc, Ring's library, Softanza and its engine
    engine-copy/    Softanza's engine built for Ring++ by bench/engine_copy.py
    oracle-cache*/  the oracle's transcripts, kept so a measurement pass does not re-run Ring
    *.json, *.log   the tables and logs the measurement scripts write

Any of it can be deleted; the scripts that wrote it write it again.
