# Google Group draft — Ring runs on Android phones, and one build choice makes it 7× faster there

> **Status: DRAFTED, NOT SENT.** Mansour posts it, if and when he judges it
> ready. Same channel rule as every other item in `upstream/`.

---

Subject: **Ring runs on Android with no NDK and no Qt — and one build flag plus one linked library made it up to 7× faster there**

Hello Mahmoud and all,

Two pieces of good news about Ring on phones, both measured on a real
Android device (Infinix X6817, arm64, Android 12), both achieved **without
changing a single line of Ring's source**.

**1. Ring runs on Android as-is.**

A Ring VM compiled as an ordinary static Linux binary (with `zig cc`,
targeting `aarch64-linux-musl`) runs directly on Android phones. No NDK, no
Qt, no Java bridge — the same `ring` executable that runs on a Linux
server runs on the phone, and a signed APK around it is ordinary Android
SDK work.

The reason it works is a strength of Ring's own design: Ring's VM is a
clean bytecode interpreter that never asks the operating system for
executable memory. Android forbids that request inside apps and kills the
process making it — that is how runtimes like Node.js fail there. Ring
never makes the request, so Android has no objection. The design choice
that keeps Ring's VM simple is the same one that opens the platform.

**2. On such static Linux builds, one linked library makes string-heavy
Ring code 3.6–7.7× faster.**

While benchmarking on the phone we saw something strange: arithmetic and
list code ran at the speed we expected, but string-heavy code (loops using
`substr`, string concatenation, `s[i]` over big strings) was 5× slower
than it should have been relative to the same machine's arithmetic. The
profiler showed the Ring VM itself was almost idle — less than half a
percent of the time — and the operating system kernel was consuming more
than half of it.

The cause was not Ring and not the phone. Static Linux binaries built
against the **musl** C library use musl's memory allocator, and that
allocator returns every large memory block to the operating system the
moment it is freed, then asks for it back on the next allocation. Ring
naturally allocates and frees large blocks constantly when it copies
strings, so every copy was paying two system calls plus the cost of the
OS wiping the returned pages. Desktop builds (Visual C++, glibc) never
show this, because their allocators keep recycled blocks ready in user
space.

The fix is to link a different allocator at build time. We used
Microsoft's **mimalloc** (MIT licensed, one extra file in the compile
line):

    zig cc -target aarch64-linux-musl -O2 -w \
        -DMI_MALLOC_OVERRIDE=1 -I mimalloc/include \
        -I ring/language/include ring/language/src/*.c \
        mimalloc/src/static.c -o ring -lm

Same phone, same Ring programs, before → after:

    scanning a string byte by byte     3653 ms  ->  515 ms   (7.1x)
    substr(s,i,1) in a loop            2945 ms  ->  383 ms   (7.7x)
    patching a large string            2246 ms  ->  626 ms   (3.6x)
    arithmetic / lists                 unchanged (they never paid the tax)

Every program's output stayed byte-identical throughout, verified across
both x64 and arm64. This applies to **any** static musl build of Ring —
Alpine Linux and small Docker images included — not only Android.

**A bonus from Ring's own source tree.** While investigating we also
enabled the computed-goto dispatch that Ring already ships in
`language/build/vmcgoto/` (`RING_VM_COMPUTEDGOTO`). On gcc/clang builds it
is worth a further ~5–8% on our suite, again with byte-identical output.
It seems not widely known that this exists — it deserves a line in the
build documentation.

Everything above is reproducible from the Ring++ repository
(`docs/ANDROID.md`, `tests/android_campaign.ps1`), including the APK
recipe and the profiler evidence. Photos of a Ring program running on the
physical phone are there too.

Ring on a phone in one command was already a nice result. Ring on a phone
at full speed is a better one — and both came from Ring's own design
holding up exactly as built.

Best,
Mansour

---

## Notes for the maintainer of this repo (not part of the post)

- The post deliberately does not name the 22–29× worst-case slowdown as a
  "Ring problem" anywhere — it was a build-environment problem, and the
  text keeps cause and credit accurate: Ring's no-JIT design is praised
  twice, both times honestly.
- The full evidence chain is FINDINGS **F-40** (profile, refuted
  hypotheses, before/after, cycle counts) plus `vendor/mimalloc/NOTES.md`
  (provenance, when to reconsider).
- If Mahmoud engages, the useful follow-up is the build-docs line about
  `RING_VM_COMPUTEDGOTO`, which is his code and his win to announce.
