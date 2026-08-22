# 06 — A binary record codec, and the landmine under it

**The task:** pack fixed-width binary records into a buffer and read them
back. A network frame. A file format. An index.

**This example is different from the others.** Its value is not the speedup —
which goes *both ways* here, as measured below. Its value is that **the
obvious optimisation kills your process**, silently, and no amount of careful
Ring will save you from it.

---

## The landmine

Having read [example 04](../04-slice-a-large-string/), you now know `substr()`
copies the whole buffer, so you reach for a pointer. This is the natural next
step, and it is fatal:

```ring
p = varptr(:cBuf, "char *")
memcpy(p, int2bytes(256), 4)        # the process VANISHES
```

No error. No line number. No exit message. **`try/catch` cannot trap it.**

`ring_vm_api_ispointer` (`ringapi.c:118`) uses `strcmp()` to test whether a
string argument is the literal `"NULL"`. `int2bytes(256)` is `00 01 00 00` — it
*begins* with a zero byte, so `strcmp` sees an empty string, reclassifies the
argument as a NULL pointer, rewrites the stack slot, and `memcpy` copies from
address 0. ([FINDINGS F-14](../../docs/FINDINGS.md), reported upstream as
[ring-lang/ring#1643](https://github.com/ring-lang/ring/pull/1643).)

**Which values?** Every multiple of 256. Every zeroed field. `double2bytes()`
of almost any round number. In other words: **exactly the values a binary
codec is made of.**

`RppBuffer.Poke()` branches on the first byte and takes a pointer-to-pointer
route for that case, so the common path stays fast and the fatal one never
happens. **Every record in this example has a leading zero byte, on purpose** —
it is a live test of that guard.

The four shapes, round-tripped:

```
int2bytes(0)      -> 0        (00 00 00 00)
int2bytes(256)    -> 256      (00 01 00 00)
double2bytes(1.5) -> 1.50     (00 00 00 00 00 00 f8 3f)
the literal NULL  -> NULL     (strcmp's other trap)
```

The crash itself is **not run here** — it would kill the process and the gate
would report "did not reach its OK marker" rather than the truth. It is
reproduced deliberately and in isolation in
[`bench/15_memcpy_nul_source.ring`](../../bench/15_memcpy_nul_source.ring).

## The speed goes both ways, and the example says so

| records | buffer | raw Ring | Ring++ | |
|---:|---:|---:|---:|---|
| 5,000 | 78 KB | **30 ms** | 71 ms | **raw Ring wins, 2.3×** |
| 20,000 | 312 KB | 557 ms | **343 ms** | **Ring++ wins, 1.6×** |

**The first draft of this example measured one size and claimed a win.** It
measured 5,000 records, Ring++ came out 3× *slower*, and the prose still said
Ring++ wins. Rather than grow the buffer until the number flattered the
library — which is how benchmarks lie — it now measures **both** sizes and
reports the crossover. That is the fact a codec author actually needs.

## Why the crossover exists

The two costs scale along **different axes**:

| | grows with |
|---|---|
| `substr()` | the **size of the buffer** (it copies all of it, per field) |
| `Peek()` | the **number of fields** (a method call, a bounds check, a `varptr` — ~3.2 µs each, see [example 08](../08-where-ringpp-loses/)) |

So the crossover moves with your record count and buffer size, not with your
taste. On an 80 KB buffer, `substr`'s copy is cheap enough to beat the
per-field overhead. At 312 KB it is not.

## What to actually do

> **Come here for correctness.**

On a small buffer, plain Ring is faster, simpler, and cannot crash — **use
it**. Reach for `RppBuffer` when the buffer is large, **or when you were about
to write `memcpy` yourself**. That second case is the one that matters: the
moment you reach for a pointer, you are one `int2bytes(256)` away from a
process that vanishes.

## Run it

```bash
ring examples/06-a-binary-record-codec/example.ring
```
