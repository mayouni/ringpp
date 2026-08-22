# How small can the vendored toolchain be?

*Measured August 11, 2026, **Zig 0.15.2** on Windows 11 x64. Every number
below came from these scripts, with the **Zig cache redirected and wiped
before every run** — otherwise a cached artifact hides the fact that a
needed file was deleted, and you conclude you can ship something you
cannot.*

> **Version note.** Zig **0.16.0** (2026-04-13) *has* now been measured
> side by side — see [§ Zig 0.16](#zig-0160-measured-side-by-side) at the
> end. Short version: same binary size, same kernel speed, 1.4× slower
> to compile, build API unchanged.

## The stand-in kernel

[`kern.c`](kern.c) is what a generated Ring++ kernel looks like: buffer
handles in, a scalar out, plus the `ringlib_init` export every Ring
extension must have. No C++, no threads, nothing beyond `stddef.h`.

## Reproducing

```powershell
powershell -File probe-all-targets.ps1 -ZigExe D:\Zig\zig.exe -Label REFERENCE
```

```powershell
powershell -File make-minimal-tree.ps1 -Src D:\Zig -Dst C:\tmp\zg_linux -LibcDirs musl -IncludeDirs any-linux-any,generic-musl,x86_64-linux-musl,x86_64-linux-any
```

```powershell
powershell -File probe-one-target.ps1 -ZigExe C:\tmp\zg_linux\zig.exe -Target x86_64-linux-musl -Out t.so
```

## What is in the 332 MB

| | MB |
|---|---:|
| `zig.exe` | **168.5** |
| `lib/libc/include` | 105.9 — of which `any-windows-any` alone is **64.5** |
| `lib/std` | 13.7 |
| `lib/include` (clang builtins) | 12.4 |
| `lib/libcxx` + `libcxxabi` | 9.3 |
| `lib/libc/mingw` | 7.4 |
| `lib/compiler` | 3.9 |
| `lib/libtsan` | 2.9 |
| `lib/libc/musl` + `glibc` + `wasi` + `darwin` | 5.4 |
| everything else | ~2.5 |

## What can be removed — verified, cold cache

| step | result | MB |
|---|---|---:|
| baseline, all 6 shipped targets build | 6/6 pass | 332.5 |
| drop `doc`, `libcxx`, `libcxxabi`, `libtsan`, all BSD header sets | 6/6 pass | **295.6** |
| also drop `lib/std` | **0/6 — "unable to find zig installation directory"** | 281.9 |
| keep only `lib/std/std.zig` as a marker | **0/6 — "sub-compilation of compiler_rt failed"** | 281.9 |

`lib/std` cannot go: `compiler_rt` and the C runtime shims are Zig
source compiled on demand, and they import it.

## Per-target minimal trees — all verified building a shared library

| target family | on disk | zipped |
|---|---:|---:|
| `aarch64-macos-none` | 206.4 MB | **60 MB** |
| `x86_64-linux-musl` | 209.7 MB | **63 MB** |
| `x86_64-windows-gnu` | 271.8 MB | **69 MB** |
| all targets (stock install) | 332.5 MB | 89 MB |

The floor is `zig.exe` itself at 168.5 MB — it contains clang and LLVM,
and `zig cc` cannot exist without them.

## The measurement that changes the answer

Same kernels as [`../headroom/`](../headroom), across optimisation
levels. **Minimum of 5 process launches per binary** — an earlier
single-run pass produced a table that swung 2× and led me to a
conclusion the minima later withdrew (see the correction below).

| | K1 scalar loop | K2 dot product | K3 byte scan |
|---|---:|---:|---:|
| **Ring 1.27 interpreted** | 1151 ms | 92 ms | 645 ms |
| `zig cc -O0` | 46 ms — **25×** | 4.04 ms — **23×** | 8.99 ms — **72×** |
| `zig cc -O1` | 19 ms — 61× | 1.00 ms — 92× | 0.21 ms — 3071× |
| `zig cc -O2` | 19 ms — 61× | 0.98 ms — 94× | 0.21 ms — 3071× |
| `zig cc -Os` | 23 ms — 50× | 0.99 ms — 93× | 0.24 ms — 2688× |
| `zig cc -O3` | 19 ms — 61× | 0.98 ms — 94× | 0.23 ms — 2870× |

Two things fall out:

1. **Even with no optimisation at all you get 22–72× over Ring.** That
   is the range a small C compiler can reach, which is why the answer to
   "make the toolchain smaller" is to *tier* it, not to shave Zig
   (see [DESIGN_TOOLCHAIN.md §7](../../docs/DESIGN_TOOLCHAIN.md#7--the-distribution--tiered-not-shaved)).
2. **`-O1` ≈ `-O2` ≈ `-O3`.** There is no reason to go past `-O2`, and
   no penalty for stopping there. `-Os` costs ~20% on K1 and is
   otherwise equal.

> **Correction.** A first single-run pass of this table reported `-O3`
> and `-Os` as *worse* on K1 (36–38 ms against 19 ms) and put the `-O0`
> band at 27–87×. Both were measurement noise. At minima the levels
> converge and the `-O0` band is 22–72×. This is the third time in this
> project that single-run timings produced a wrong conclusion; the rule
> in [FINDINGS.md](../../docs/FINDINGS.md) — *report minima over
> repetitions* — exists because of exactly this.

The `-O0` → `-O1` jump on K3 (8.99 → 0.21 ms, **43×**) is vectorisation:
that is what the big toolchain actually buys, and it only shows up on
loops a vectoriser can see.

## Compile latency — the "JIT" tax

`zig cc -O2 -shared` on the kernel, minimum of 6 warm runs, quiet machine:

| | first ever (empty cache) | warm `-O2` | warm `-O0` |
|---|---:|---:|---:|
| zig 0.15.2 | **41.6 s** | 220 ms | 294 ms |
| zig 0.16.0 | **55.2 s** | 324 ms | 400 ms |

Two operational facts worth more than they look:

- **The first compile on a fresh machine costs 40–55 seconds**, because
  Zig builds `compiler_rt` and the target libc before it can link
  anything. This is once per (target, Zig version) — and it must be paid
  by `ringpp vendor install`, never by a user's first `ringpp run`.
  **Pre-warming the cache is a shipping requirement, not an
  optimisation.**
- **`-O0` is *slower* to compile than `-O2`** (294 vs 220 ms) — the
  output is larger and linking dominates. So "use `-O0` for a fast
  edit-run loop" is false here. A small compiler is fast because it is
  small, not because the optimiser is off. That strengthens the case for
  a genuinely tiny Tier 2 rather than just passing `-O0` to Zig.

## Zig 0.16.0, measured side by side

Downloaded from ziglang.org, SHA256 verified against the official
`index.json` (`68659eb5…5a7e`), extracted and run alongside 0.15.2 on
the same machine, same hour.

| | 0.15.2 | 0.16.0 |
|---|---:|---:|
| `zig.exe` | 168.5 MB | **168.9 MB** |
| install on disk | 332.5 MB | **345.6 MB** |
| official download (win-x64) | — | 92.7 MB |
| builds all 6 shipped targets | 6/6 | **6/6** |
| K1 / K2 / K3 at `-O2` | 19 / 0.98 / 0.21 ms | **19 / 0.99 / 0.22 ms** |
| K1 / K2 / K3 at `-O0` | 46 / 4.04 / 8.99 ms | **43 / 4.22 / 8.91 ms** |
| warm kernel compile | 220 ms | **324 ms** (1.5×) |
| first-ever compile | 41.6 s | **55.2 s** |
| RingScript-era `build.zig` API | OK | **OK, unchanged** |

**Conclusions.**

- `zig.exe` is the same size, which is the plainest possible evidence
  that **LLVM has not been removed**. It is still LLVM 21 inside.
- **Kernel performance is identical.** Nothing in the tiering changes.
- **0.16 is ~1.5× slower to compile a kernel.** For a compile-and-cache
  design that is a real cost on the first call and zero thereafter, but
  it is a reason not to upgrade without a motive.
- **The build API survives.** The 0.15-era surface RingScript uses —
  `createModule`, `addExecutable{.root_module}`, `wasi_exec_model`,
  `rdynamic`, `stack_size`, `initial_memory`, `addInstallFile`,
  `resolveTargetQuery`, `addRunArtifact`, custom steps — builds
  unchanged on 0.16.0. That was the expensive risk and it did not
  materialise.

> **One transient to be aware of.** The first `zig build` on 0.16 with a
> cold cache, while the machine was loaded, failed once with
> `sub-compilation of wasi libc.a failed` pointing at musl's `carg.c`.
> It did not reproduce on any subsequent run with a fresh cache and the
> machine quiet, and plain `zig cc -target wasm32-wasi` never failed.
> Recorded because it would cost someone an afternoon, not because it is
> a known defect.

**Recommendation: stay on 0.15.2 for now.** 0.16 buys nothing measurable
here and costs 1.5× compile time. Revisit when a specific need appears —
and keep both in the P4 matrix so the answer stays current.
