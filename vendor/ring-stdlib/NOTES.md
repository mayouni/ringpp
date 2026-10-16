# The Ring standard library, vendored

**Ring 1.27.0**: `bin/load/` (75 files -- the shims a program reaches with
`load "stdlibcore.ring"` and its siblings) and `libraries/stdlib/` (27 files
-- the library itself). Copied byte for byte; `SHA256SUMS` records every one and
`tests/run-all.ps1` checks it on every run under the gate `vendored stdlib`. Two
files were not taken: `libraries/stdlib/test.mdb` (a 540 KB Access database for
the ODBC example) and `test.ring` (its driver). Nothing else was left out.

`LICENSE` is Ring's own, unaltered: MIT, (c) 2016-2026 Mahmoud Fayed, and the
two files under `libraries/stdlib` credit CalmoSoft as well. The work is theirs.

## Why it is here

Softanza's loader (`core/common/stkRingLibs.ring`, line 6) does `load
"stdlibcore.ring"`. Ring finds that in `<exefolder>/load/`; the shim there loads
`/../../libraries/stdlib/stdlib.rh` and `usestdlibcore.ring`, where a leading `/`
means "relative to `<exefolder>/load/`" -- probed on 1.27, 2026-09-09. So the
estate depends on Ring's LIBRARY files, not only on its VM, and an oracle
that carries `ring.exe` alone dies on line 6 of every Softanza program. Found
when a 99-file sweep passed before and after a migration because every
file had failed identically, both times.

## The layout it reproduces

    runtime/<platform>/ring.exe          the oracle (tests/b2_runtimes.ps1)
    runtime/<platform>/load/             <- load/
    runtime/libraries/stdlib/            <- libraries/stdlib/   (shared by all)
    zig-out/bin/rnxc.exe
    zig-out/bin/load/                    <- load/      (build.zig installs both,
    zig-out/libraries/stdlib/            <- libraries  so rnxc resolves the same way)

From `<exefolder>/load/x`, `/../../libraries/stdlib` is `<exefolder>/../libraries/
stdlib` -- one level up from the platform directory, hence `runtime/libraries`.

## Not modified

Not one line is edited. `stdlibcore.ring` loads nothing native; the shims for GUI,
database and network libraries are here for fidelity and load DLLs this
project does not ship -- a program that loads one gets Ring's own error.
