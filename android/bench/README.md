# The device benchmark

Three runtimes, six identical algorithms, one phone, one session.

| file | runtime | how it gets there |
|---|---|---|
| `algorithms.ring` | Ring 1.27 + Ring++ | the arm64 stub from `runtime/linux-arm64/` |
| `bench.lua` | Lua 5.4 | a static arm64 binary you build once (below) |
| `Bench.java` | Android's own ART | `javac` → `d8` → `dalvikvm`, already on the device |

Run everything, including the library's own gates on ARM:

```
powershell -File tests\android_campaign.ps1
```

The campaign SKIPs cleanly when no authorised device is attached. The two
neighbour runtimes are optional: each is reported as measured or as absent,
and neither can fail the campaign on speed. What they *can* fail on is
disagreeing with Ring about an answer — a neighbour computing something
different makes its timings meaningless, so that part is checked.

## Why these three

**Lua is the fair peer.** Same kind of thing as Ring: small, dynamically
typed, register-based bytecode, no JIT, 1-indexed, embedded rather than
hosted. The gap to Lua is a gap in interpreter engineering.

**ART is the ceiling.** It JITs hot loops to native arm64, so the gap to it
is a gap in compilation strategy — a different question. It is here because
it is what the device already runs, so it says what the hardware can do.

Ring's own no-JIT design is why it runs on Android at all
([F-36](../../docs/FINDINGS.md)): it never asks the kernel for executable
memory, so the seccomp filter that kills other portable runtimes never fires.
The thing that costs it speed in this table bought it the platform.

## Building the neighbours

**ART** — needs the JDK and build-tools the Android target already needs:

```bash
javac -nowarn -encoding UTF-8 -d out/classes Bench.java
java -cp "$SDK/build-tools/<ver>/lib/d8.jar" com.android.tools.r8.D8 \
     --min-api 24 --output out out/classes/Bench.class
```

**Lua** — one download and one `zig cc`, about three seconds:

```bash
curl -o lua.tgz https://www.lua.org/ftp/lua-5.4.7.tar.gz
tar xzf lua.tgz && cd lua-5.4.7/src
zig cc -target aarch64-linux-musl -O2 -static -o lua-arm64 \
    $(ls *.c | grep -v '^luac\.c$') -lm
```

Put the result at `%TEMP%\claude\ringpp-lua\lua-arm64` and the campaign finds
it. Nothing is vendored into this repository — Ring++ is dependency-free, and
a benchmark's neighbours are not dependencies.

## Reading the output

`CHECK <name> <value>` lines **must** match everywhere — across x64 and
arm64, and across all three runtimes. The campaign fails if they do not. This
is why the suite prints its answers instead of comparing them against
constants typed into the file: a constant is a guess, agreement between two
instruction sets and three runtimes is evidence.

`TIME <name> <ms>` lines are minima over three runs and are *expected* to
differ. They are reported, never asserted — hardware is not behaviour.

`WARN <name> at-timer-floor` means a measurement landed near `clock()`'s 1 ms
resolution and is a floor, not a value. Raise the scale:
`ring algorithms.ring 4`.

The results, and what they teach, are in
[docs/ANDROID.md §4](../../docs/ANDROID.md).
