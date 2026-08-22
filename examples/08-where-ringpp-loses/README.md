# 08 — Where Ring++ loses

**This example exists to show the tool failing.** A curriculum that only shows
its good cases has not taught anyone when to reach for the thing — it has only
taught them to trust it, which is worse than useless.

**The task:** hold 400,000 doubles and add them up.

**The intuition, which is wrong:** *"a packed 8-bytes-per-double buffer must
beat a Ring list — it is contiguous, it is cache-friendly, it is what C would
do."*

**The measurement:**

| | |
|---|---:|
| plain Ring list | **44 ms** |
| Ring++ packed buffer | **1,237 ms** |
| | **28× SLOWER** |

The example **passes because of that**, and says so.

---

## Why it loses, and it is not the reason you would guess

| | |
|---|---:|
| one list item — one indexed read | ~0.1 µs |
| one `PeekDouble` — method call, `CheckRange` method call, `varptr`, `getptr`, `ptr2str`, `bytes2double` | ~3.2 µs |

**The dominant term is the `varptr`.** `RppBuffer.Base()` re-derives the
address on *every* access:

```ring
func Base
    return getptr(varptr(:cData, "char *"))
```

and `varptr` costs **~790 ns** ([FINDINGS F-4](../../docs/FINDINGS.md)) — a
name lookup plus a three-item list built to carry the pointer, per call.

**That is deliberate, and it is a correctness tax rather than an oversight.**
Ring copies an object on assignment and on list insertion, so a *cached*
address inside a copied buffer dangles into freed memory and the process
vanishes with no message ([FINDINGS F-22](../../docs/FINDINGS.md) — found by
this project's own fuzz harness, after 100,000 accesses). Re-deriving is what
makes `RppBuffer` safe to copy.

## The measured gap I did not expect

[FINDINGS F-15](../../docs/FINDINGS.md) reports **2.2×** for the *raw* packed
idiom — `bytes2double(ptr2str(...))` against a cached pointer. Through the
**safe API** it is **28×**.

That 13× difference *is the wrapper*, and the wrapper is what stops it
crashing. I did not predict this before running the example; the number
disagreed with FINDINGS, so it got investigated rather than reported.

## When it inverts

The same packed bytes read by **compiled** code are the K2 kernel:
**1,000,000 doubles in 0.96 ms** native against **92 ms** as a Ring list.

A packed numeric array is a **compiled-half data structure**. It is not wrong
— it is *premature*. This is why `RppArray` is not in the library yet and
will arrive **with** the compiler rather than before it.

## The rule this teaches, and it is the useful one

> `RppBuffer` is for **bulk** operations — poke a range, peek a range, hold a
> value across a call boundary.

Examples [01](../01-patch-a-large-buffer/), [02](../02-pass-a-large-value/)
and [04](../04-slice-a-large-string/) each touch the buffer a few thousand
times and win **23–86×**.

This loop touches it **400,000 times, one element at a time**. That is the
shape to avoid: **per-element access through a safe wrapper pays the safety on
every element.**

Ring++ wins where it *removes* a copy or a walk. It loses where it *adds* a
call boundary to something Ring already does in one indexed read. Reach for it
when you can name which.

## Run it

```bash
ring examples/08-where-ringpp-loses/example.ring
```
