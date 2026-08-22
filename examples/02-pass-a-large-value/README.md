# 02 — Passing a large value to a function

**This is the thesis.** Everything else in Ring++ is a consequence of one
measured fact about the Ring VM:

> A **list** crosses a call boundary **by reference**.
> A **string** crosses a call boundary **by copy**.

`RING_VM_STACK_PUSHCVAR` (`vm.h:230`) is `ring_itemarray_setstring2_gc(...)`
— a byte copy onto the VM stack. A helper that takes a 1 MB string copies a
megabyte **before its first line runs**, on every call.

**The result** (1 MB buffer, 1,500 helper calls):

| | |
|---|---:|
| raw Ring | **434 ms** |
| Ring++ | **5 ms** |
| | **86×** |
| bytes copied, raw | **1,430 MB** |
| bytes copied, Ring++ | **0** |

Output identical, asserted.

---

## The whole difference

```ring
func RawWay cData, nCalls, nSize
    nSum = 0
    for i = 1 to nCalls
        nSum += ByteAtRaw(cData, (i * 7919) % (nSize - 1))
    next
    return nSum

func ByteAtRaw cData, nOffset
    return ascii(cData[nOffset + 1])
```

```ring
func RppWay oBuf, nCalls, nSize
    nSum = 0
    for i = 1 to nCalls
        nSum += ByteAtRpp(oBuf, (i * 7919) % (nSize - 1))
    next
    return nSum

func ByteAtRpp oBuf, nOffset
    return oBuf.Byte(nOffset)
```

The loop is the same. The helper is the same shape. **What changed is what
you hold**: an `RppBuffer` is an object, an object is a list, and a list
crosses by reference.

## Why this is hard to see

The helper reads **one byte**. It is obviously cheap. The cost is not in the
function — it is in *the act of calling it*, and there is nothing at the call
site to look at.

This is why "it got slow when the files got bigger" is such a common story in
Ring, and why the fix is so rarely found by reading the loop.

## Where this loses — the honest half

Nothing is free. Reading through the object costs a **method call (~340 ns)**
where raw Ring costs an **index (~30 ns)**. If the buffer is small enough
that copying it is cheap — a few KB — the raw form is faster *and* simpler.

**The crossover is the size of the value, not the number of calls.** A
100-byte string passed a million times is fine. A 1 MB string passed a
thousand times is not.

## A note on the number

[FINDINGS F-5](../../docs/FINDINGS.md) reports ~2,200× for 3,000 calls on a
1 MB string against a pointer handle. This example measures **86×** because
it compares against `RppBuffer.Byte()` — a real method call with a bounds
check — rather than against a raw pointer read. That is the honest
comparison for code you would actually write; `AddressUnchecked()` exists
for the case where you have measured and need the other 25×.

## Run it

```bash
ring examples/02-pass-a-large-value/example.ring
```
