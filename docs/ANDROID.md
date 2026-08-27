# Ring on Android

A Ring program, running as an ordinary Android app, from one command.

```
ringpp build app.ring --target android
```

Out comes a signed `.apk` you can install. No NDK, no Qt, no Qt Creator, no
Gradle, no JNI, no C compiler.

---

## 1. Tutorial — from a `.ring` file to an app on your phone

### What you need first

Android is **the one `--target` that needs a toolchain**, and this document
says so up front rather than letting the command look free and fail later.
You need two things:

| | why |
|---|---|
| **Android SDK** — build-tools + one platform `android.jar` | an APK's manifest is *binary* XML, and only Google's `aapt2` writes it |
| **JDK 17 or newer** | `javac`, `d8`, `apksigner` and `jar` all live there |

You do **not** need the NDK. That surprises people, and section 3 explains
why. Install both with Android Studio, or with the standalone command-line
tools; nothing else is required.

Point the CLI at them with `--sdk` and `--jdk`, or set `ANDROID_HOME` and
`JAVA_HOME` and pass nothing.

### Step 1 — write ordinary Ring

Nothing here is Android-flavoured. This is the demo that ships in
[`android/app.ring`](../android/app.ring), trimmed:

```ring
? "Ring on Android"

aRows = []
for i = 1 to 6
    aRows + ["item-" + i, i * i]
next

oAcc = new Accumulator
for r in aRows
    oAcc.Add(r[2])
next
? "sum of squares : " + oAcc.Total()

write("report.txt", "written from Ring")
? "read back : " + read("report.txt")

class Accumulator
    nTotal = 0
    func Add nValue
        nTotal += nValue
    func Total
        return nTotal
```

Lists, a class holding state, file I/O. No imports, no bindings, no
lifecycle callbacks.

### Step 2 — build

```bash
ringpp build app.ring --target android --label "My App"
```

```
  [1/6] aapt2 link   (manifest + bytecode)
  [2/6] javac        (the generated Activity)
  [3/6] d8           (dex)
  [4/6] pack         (dex + the VM per ABI)
        lib/arm64-v8a/libring.so  3895376 bytes
        lib/x86_64/libring.so  3756832 bytes
  [5/6] zipalign
  [6/6] apksigner
        creating a debug keystore (first build only)

built  app-android/app.apk   2.3 MB
  package  org.ringpp.app
  abis     arm64-v8a x86_64
```

### Step 3 — install and run

```bash
adb install -r app-android/app.apk
adb shell am start -n org.ringpp.app/.MainActivity
```

The app opens, runs your program, and shows what it printed along with the
device, the ABI, the Android version and the exit code.

### Step 4 — when you change the program

Re-run the same build command. The keystore is created once and reused, so
`adb install -r` keeps working; a fresh key on every build would fail with a
signature mismatch on the second install and read as a broken app.

---

## 2. Reference

```
ringpp build <entry.ring> --target android [options]
```

| option | default | meaning |
|---|---|---|
| `--sdk <dir>` | `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, then `%LOCALAPPDATA%\Android\Sdk` | Android SDK root |
| `--jdk <dir>` | `$JAVA_HOME` | JDK 17+ |
| `--package <id>` | `org.ringpp.<entry-basename>` | application id |
| `--label <text>` | the entry's basename | name under the launcher icon |
| `--app-version <text>` | `1.0` | `versionName` in the manifest |
| `--keystore <path>` | `<out>/debug.jks` | signing keystore, created once |
| `--out <dir>` | `<entry-basename>-android` | output directory |
| `--runtime-dir <dir>` | beside `ringpp`, then `./runtime` | where the B2 stubs live |

**Build-tools selection.** The highest installed version wins, except that a
prerelease (`36.1.0-rc1`) is only used when nothing else is installed. Picking
the highest number alone would quietly build every APK with a release
candidate — a difference nobody asked for and nobody would notice until
something behaved oddly.

**What lands in the APK**

```
AndroidManifest.xml        generated, binary XML from aapt2
classes.dex                the generated Activity, ~90 lines of Java
assets/app.ringo           your program, compiled by ring -go
lib/arm64-v8a/libring.so   the Ring VM  (every modern phone)
lib/x86_64/libring.so      the Ring VM  (the emulator)
```

**API levels.** `minSdk 24`, `targetSdk 34`. 24 is the first level where
running a bundled executable out of `nativeLibraryDir` is dependable, and it
is also the level at or above which `apksigner` can skip v1 signing.

**What it refuses to do.** A program that reaches a native library through
`loadlib` is refused, not half-packaged: an Android build of that library
would need the NDK, and an APK that installs and then dies on the phone is
the worst outcome this target can produce. `ringpp deps <entry>` names what
is in the way. A program whose dependency picture is incomplete (`load`
targets that could not be resolved) is refused for the same reason — pass
`--ring-root`.

---

## 3. Why there is no NDK

The Ring VM inside the APK is **byte-identical** to the `linux-arm64` stub
every other `ringpp build` ships. Not a port, not a rebuild — the same file,
carried under the name Android insists on.

That works because of a property of Ring that usually looks like a weakness:

> **Ring's VM is a plain bytecode interpreter with no JIT.**

A JIT has to ask the kernel for memory that is both writable and executable.
On Android, the seccomp filter applied to app processes refuses that request,
and the process dies with `SIGSYS` before it prints anything. That is exactly
how a static musl build of Node fails on Android — measured on real hardware
in an earlier project, exit 159 at V8 initialisation.

Ring never makes that call, so nothing objects to it. **The property that
costs Ring speed is the property that bought it the platform.**

Two Android rules are load-bearing and easy to get wrong:

- The VM must be named `lib*.so`. Android extracts and marks executable
  *only* files matching that pattern — even though this one is an executable
  and not a library at all.
- `android:extractNativeLibs="true"` is what puts it on the filesystem.
  Without it the VM stays compressed inside the APK and cannot be run as a
  process.

Both are set for you. Both cost hours if you meet them the hard way.

---

## 4. What we measured on a real phone

Device: **Infinix X6817**, `arm64-v8a`, Android 12 (API 31). Everything below
is reproducible with:

```
powershell -File tests\android_campaign.ps1
```

### The library works on ARM

All six of Ring++'s own gates — the same files the desktop suite runs, with
nothing Android-aware in them — pass on the phone: the VM contract probe,
the buffer tests, the idiom tests, the name-collision gate, the differential
gate and the bounds fuzz.

Ten computed results from the algorithm suite are **byte-identical on x64
Windows and arm64 Android**. That is why the suite prints its answers rather
than comparing them against constants written by hand: a constant is a guess,
agreement between two instruction sets is evidence.

### The phone looked 22–29× slower on strings — and that number caught a real bug in our own runtime

The first session produced a two-band table: compute 4–8× slower on the
phone, anything that copies strings **22–29×** slower. That asymmetry
looked like mobile memory hardware. It was not. Profiling on the device
(`simpleperf` ships on Android) put the interpreter at **0.44%** of cycles
and the *kernel* at ~60%: musl's allocator serves every large allocation
with a fresh `mmap` and returns it with `munmap`, so each large-string copy
Ring makes became two syscalls plus a page-fault storm. The desktop's CRT
recycles those blocks and never pays this.

The fix changed no Ring source: the musl stubs now link **mimalloc**
([F-40](FINDINGS.md), provenance in `vendor/mimalloc/NOTES.md`), and the
same rebuild switched on Ring's own shipped computed-goto dispatch
(`RING_VM_COMPUTEDGOTO`, worth 5–8%). String workloads got **3.6–7.7×
faster** on the device in one day, answers byte-identical throughout.

**The table after the fix** — same source, minimum of three runs,
milliseconds:

| workload | x64 desktop | arm64 phone | phone is |
|---|---:|---:|---:|
| sieve of primes | 86 | 585 | 6.8× slower |
| matrix multiply | 63 | 426 | 6.8× slower |
| recursive fib | 22 | 163 | 7.4× slower |
| mergesort | 110 | 569 | 5.2× slower |
| binary search | 176 | 653 | 3.7× slower |
| byte scan over a string | 13 | 77 | 5.9× slower |
| patching a buffer, raw Ring | 86 | 541 | 6.3× slower |
| reading slices, raw Ring | 108 | 573 | 5.3× slower |
| `substr(s,i,1)` in a loop | 96 | 387 | 4.0× slower |

One uniform band, **2.0–7.4×**, no string outlier. The Ring++ pairs hold
desktop-class ratios on the device — buffer patching **11.8×**, slice
reads **12.7×**, `substr(s,i,1)` → `s[i]` **8.8×**. Honest numbers: the
first session's 49–66× "mobile wins" were real measurements, but a third
of each ratio was the allocator bug donating to our side. We would rather
fix the runtime everyone gets than keep a flattering benchmark.

### Where it goes the other way

`RppIndexed` — the permuted-list-read idiom — wins less on the phone:
8.5× on the desktop, **2.9×** on the device. Raw list indexing is only
2.0× slower on ARM (it is cache-friendly and copies nothing), while the
idiom's own overhead pays the phone's general tax. The technique that
avoids copying holds its value on mobile; the technique that avoids
*pointer chasing* wins smaller.

Both directions are reported because a benchmark that shows only its good
case is marketing.

### Ring beside two other runtimes, on the same phone, in the same session

All three produce **identical answers** for all six algorithms — that is
checked, and it is what makes the timings comparable at all.

| workload | Ring 1.27 | Lua 5.4 | ART (dalvikvm) |
|---|---:|---:|---:|
| sieve | 584.81 | 71.08 | 2.48 |
| matmul | 425.90 | 28.37 | 1.86 |
| fib | 163.47 | 13.38 | 1.39 |
| mergesort | 569.37 | 49.54 | 5.19 |
| binary search | 653.23 | 6.22 | 0.60 |
| byte scan | 76.93 | 12.03 | 0.76 |

(The Ring column is the runtime after two findings. Byte scan read
3 740 ms — 311× behind Lua — when first measured; [F-40](FINDINGS.md)
(the musl allocator) took it to 515, and [F-41](FINDINGS.md) (the
`for i = 1 to len(s)` header trap, which Lua never pays because its `for`
evaluates the bound once) took it to 77. The impossible-looking gap is what
led to the profiles that found both bugs.)

**Read these two columns differently.**

**ART is a compiler.** It JITs hot loops to native arm64. An optimising
compiler beating a plain interpreter by 100–250× on compute is the expected
result, not a discovery. It is in the table because it is the runtime that
ships on the device, so it sets the ceiling of what that hardware can do.

**Lua is the fair peer** — the same kind of thing as Ring: small,
dynamically typed, register-based bytecode, no JIT, 1-indexed, embedded
rather than hosted. On ordinary compute Ring is **8–15× behind it**. That is
a gap in interpreter engineering, and it is the honest number to quote when
someone asks how Ring compares to other small languages.

Two entries sit outside that band:

- **byte scan is no longer an outlier.** 311× behind Lua decomposed into
  the musl allocator (7.1×, F-40) times the for-header trap (6.7×, F-41);
  what remains is 6.4× — inside the normal band. The residue is
  structural: Ring's `s[i]` builds a one-character string where Lua's
  `string.byte` returns a number.
- **binary search is solved too** ([F-42](FINDINGS.md)): Ring reaches a
  list element by walking from a cursor at the last accessed position, so a
  random access costs O(distance) — and binary search's first probe jumps
  half the list. The algorithm was O(n) per query while reading as
  O(log n). `RppIndexed` (Ring's own `ringvm_genarray` underneath)
  restores O(1) access: 657 → 131 ms on the device, same hits, and the
  gap to Lua falls from 105× to 21× — ordinary interpreter cost, not a
  mystery. The suite now carries `binsearch-rpp` beside `binsearch`.

Every anomaly this campaign surfaced is now fixed or mechanistically
explained — which took five findings, four refuted hypotheses, and a
profiler, in that order. The rule that survives the exercise: publish the
measurement immediately, and the mechanism only after it is demonstrated.

---

## 5. Troubleshooting

**`could not find a JDK` / `could not find the Android SDK`**
The message names the exact path it looked at. Set `JAVA_HOME` /
`ANDROID_HOME`, or pass `--jdk` / `--sdk`.

**`no Linux runtime stub found`**
The Android VM *is* the `linux-arm64` stub. Build the B2 runtimes:
`powershell -File tests\b2_runtimes.ps1`, or pass `--runtime-dir`.

**`INSTALL_FAILED_UPDATE_INCOMPATIBLE`**
An APK with the same package id, signed with a different key, is installed.
`adb uninstall <package>` first. This happens if the keystore was deleted
between builds.

**The app opens and shows `FAILED: ... error=13, Permission denied`**
The VM was not marked executable, which means it was not named `lib*.so` or
`extractNativeLibs` was off. Both are generated correctly; this only appears
in a hand-edited manifest.

**Device shows `unauthorized` in `adb devices`**
Unlock the phone and accept the USB-debugging prompt. A locked screen drops
the authorisation, so a long build can find the device gone.

**Non-ASCII output arrives as mojibake**
Fixed in the generated build (`javac -encoding UTF-8`), but if you compile
Java yourself, that flag is not optional — without it `javac` reads the
source in the system codepage and the damage is only visible on the phone.

---

## 6. What is not covered

- **iOS** needs a macOS host and Xcode. That is Apple's constraint, not a
  design choice here.
- **WebAssembly** is deliberately *not* Ring++'s. RingScript already solved
  it, Zig-first, with no Emscripten and no Qt; duplicating it would split
  effort for no gain.
- **Bare-metal devices** (RP2350, ESP32) are MicroRing's Tiers 2–3. The
  runtime-stub mechanism has nothing to offer there.

See [BUILD-OPTIONS.md](BUILD-OPTIONS.md) for how the three Ring packaging
tools compare, and which sibling project owns which target.
