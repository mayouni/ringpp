# ringzip, vendored -- the one native Ring extension the estate loads

From **Ring 1.27.0** `extensions/ringzip/`, byte for byte: the binding
(`ring_libzip.c`, 322 lines, and its `.rh` of function names), the shim
(`ziplib.ring`), and the library it binds -- kuba--/zip (`zip.c`, `zip.h`,
public domain / unlicense, see the end of zip.h) on `miniz.h` (MIT, RAD Game
Tools and Valve). Ring's own build scripts, tests and code generator are
not taken; `SHA256SUMS` records the six files and the licence.

## Why it is here

Line 1 of Softanza's `base/file/stzFile.ring` is `load "ziplib.ring"`, and the
shim loads `ring_libzip.dll`. It is the ONLY native Ring extension live
Softanza loads (every other one is archive or plugin code -- read on
2026-09-09). With the VM and the standard library vendored, this was the
last file between the oracle and a Softanza program reaching its own
first assertion.

## How it is built -- and for whom

`tests/b2_runtimes.ps1` builds it with the same `zig cc` that builds the VM,
against the vendored headers, and places the result beside the ORACLE:
the oracle's `ring.exe` exports its API and the extension imports from it.
That is Ring's C API -- `RING_API_GETSTRING`, `ring_list_*` -- so this extension
belongs to Ring's VM and to nothing else. **rnxc cannot host it**: Ring++ is
not Ring's VM, and a Ring extension calling back into Ring's API has no
meaning there. What Softanza's zip features run on under Ring++ is a
design item (its own engine, or a native of ours), recorded, not decided.

## Not modified

Not one line is edited. The layout it expects -- `<exefolder>/load/ziplib.ring`
-> `/../../extensions/ringzip/ziplib.ring` -> `LoadLib("ring_libzip.dll")` beside
the binary -- is reproduced under `runtime/` exactly.
