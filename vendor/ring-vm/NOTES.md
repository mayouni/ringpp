# The Ring VM source, vendored

**Ring 1.27.0**, from `language/src`, `language/include` and
`language/build/vmcgoto` of the official distribution. Copied **verbatim,
byte for byte** — 80 files, ~1 MB. `SHA256SUMS` records every one (plus the
licence), so drift is detectable rather than assumed, and `tests/run-all.ps1`
checks it on every run under the gate `vendored VM`.

`build/vmcgoto/` is easy to miss and is not optional: `vm.c` under
`-DRING_VM_COMPUTEDGOTO=1` references `ring_vm_computedgoto`, which is
defined only there. Vendoring `src` and `include` alone gives
`undefined symbol: _ring_vm_computedgoto` at link time.

**Do not verify this by comparing built binaries — the toolchain is not
deterministic.** Two `zig cc` builds of identical source, same flags, same
machine, gave `3D177B27…` and `53FE874A…`. The check that *is* available is
the source comparison: 80 of 80 files byte-identical to upstream. The check
that matters for behaviour is the one `b2_runtimes.ps1` already does —
running the result and diffing its output against Ring's own official
build, which it does for the two targets this machine can execute.

`LICENSE` is Ring's own, unaltered: MIT, © 2016-2026 Mahmoud Fayed. It
travels with the source because that is the condition the licence sets, and
because the work is his.

## Why it is here

Ring++ builds its own runtime — five platform binaries in
[`runtime/`](../../runtime/README.md), made by `zig cc` from these files.
Until now the build read them from `D:\ring127\language\src`, an
installation outside this repository. That meant a clean clone produced no
VM, and the runtime this project depends on sat on ground someone else
controls.

That is the whole point of vendoring it. **Sovereignty over the runtime is
the first commitment in [CLAUDE.md](../../CLAUDE.md)**: nothing this project
depends on may be withdrawn by anyone else.

## Not modified — and how the build changes behaviour anyway

Not one line of Ring's source is edited here. The two upgrades
`tests/b2_runtimes.ps1` applies are both build-time and both use doors Ring
already provides:

- **computed goto** — Ring ships this dispatch behind
  `RING_VM_COMPUTEDGOTO` (`vm.c`). Opened with a `-D`. Measured ~5-8% on the
  device suite, answers byte-identical.
- **mimalloc**, musl targets only — musl's allocator serves every large
  block with a fresh `mmap` and frees it with `munmap`, which cost Ring
  22-29× on Android until it was linked. See
  [`vendor/mimalloc/NOTES.md`](../mimalloc/NOTES.md).

Keeping the source unmodified is deliberate: it is what makes "we build
Ring's VM" a checkable claim rather than a fork nobody can audit. When a
change to the VM itself becomes necessary, it should arrive as a patch file
applied at build time, so the diff against upstream stays visible.

## Refreshing it

    python <scratch>/vendor_vm.py     # or copy the two directories again

then regenerate `SHA256SUMS` and re-run `tests\b2_runtimes.ps1`. The gate
`b2 runtimes` builds from **this** directory; the external path remains
available as `-RingSrc` / `-RingInc` for comparing against another Ring.
