# mimalloc 2.1.7 — why an allocator is vendored here

**Source:** `microsoft/mimalloc` tag `v2.1.7`, tarball sha256
`0eed39319f139afde8515010ff59baf24de9e47ea316a315398e8027d198202d`.
Only `src/`, `include/`, `LICENSE` and `readme.md` are kept; tests, docs and
build systems are not. MIT licensed. No file is modified.

**What it is for — one thing.** The static musl runtime stubs
(`linux-x64`, `linux-arm64`) link it in place of musl's own allocator, via
`-DMI_MALLOC_OVERRIDE` and one added translation unit (`src/static.c`) in
`tests/b2_runtimes.ps1`. No Ring source is touched. No other target uses it:
the Windows and macOS stubs keep their platform C runtime's allocator.

**The measurement that forced it (FINDINGS F-40).** On a physical arm64
phone, string-heavy Ring workloads ran 22–29× slower than on the desktop
while compute ran only 4–8× slower. `simpleperf` on the device showed the
interpreter at **0.44 %** of cycles, the kernel at ~60 %, with `__mmap` and
`__munmap` sitting directly under `__libc_malloc_impl`: musl's allocator
serves large allocations with a fresh `mmap` and returns them with `munmap`,
so every large-string copy Ring makes became two syscalls plus a page-fault
storm on cold pages. With mimalloc linked, the same suite's string
workloads ran **3.6–7.7× faster** (byte scan 3 653 → 515 ms), total cycles
fell 5.7×, and every computed CHECK value stayed byte-identical.

**Why this does not break the dependency-free promise.** Ring++'s promise is
to *users*: no compiler, no package, no DLL. This is a maintainer-side build
input for the prebuilt stubs, in the same position as the vendored
tree-sitter — the user still receives one static binary and installs
nothing. The stub grows from 3.0 MB to 3.9 MB, which is the price of not
paying two syscalls per large string.

**When to reconsider.** musl added its current allocator (mallocng) for
hardening, not speed, and its behaviour here is by design. If a future musl
grows large-block caching, or if Ring's pool manager starts covering large
strings, re-run `tests\android_campaign.ps1` with a stub built without this
override; if the string rows stay flat, delete this directory.
