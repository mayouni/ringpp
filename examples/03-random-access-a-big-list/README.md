# 03 — Random access into a big list

**The most surprising result in this project**, and the one that changes how
you read your own code:

> **How a list was built decides what it costs to read.**

A Ring list is a linked list with a one-entry cursor cache. Walking it in
order is fast — every step hits the cache. Jumping around it is **O(n) per
read**, because each jump walks from the head.

So `aList[i]` — the plainest expression in the language — is cheap or
quadratic depending on whether your `i` values happen to ascend. **Nothing
in the source distinguishes the two.** ([FINDINGS F-19](../../docs/FINDINGS.md))

**The result** (20,000 items built by appending, 20,000 permuted reads):

| | |
|---|---:|
| raw Ring | **101 ms** |
| Ring++ | **3 ms** |
| | **33×** |

---

## The whole difference

The reading loop is **identical** in both versions:

```ring
func ReadLoop aList, nReads, nItems
    nSum = 0
    nSeed = 1
    for i = 1 to nReads
        nSeed = (nSeed * 16807) % 2147483647
        nSum += aList[(nSeed % nItems) + 1]
    next
    return nSum
```

Ring++ is **two lines around it**:

```ring
oIdx = new RppIndexed(aList)        # open the phase
nRpp = ReadLoop(aList, nReads, nItems)
bValid = oIdx.Release(aList)        # close it
```

`ringvm_genarray` asks the VM to build a real pointer array for the list,
making index access O(1). `RppIndexed` wraps that as a **phase**, because one
structural mutation frees the array and silently returns you to walking.

## Why it is a phase and not a flag

`Release()` returns whether the index was **still valid** at the close. If the
list changed size during the phase, it says so and files advice — because an
index that quietly stopped working looks exactly like one that never helped.

It also states what it **cannot** see:

> `sort()` and `reverse()` invalidate the index without changing `len()`, so
> `Release()` cannot detect them. Re-open the phase after sorting.

## Where this loses — the honest half

- **Below 64 items it refuses.** The walk is cheaper than the array, and it
  tells you why rather than pretending to help.
- **Mutation during the phase is worse than not indexing.** Every append
  frees the array and the next read rebuilds it. Write-heavy code pays up to
  **16×** for this (F-9, F-10). Open the phase *after* the mutations, never
  around them.

## Two notes on the measurement

**The read order is Park–Miller, not `i * k % n`.** A stride that ascends is
cursor-friendly, and would make "random" reads fast for the wrong reason.
Measuring the wrong sequence is exactly how the first version of F-19 got its
numbers wrong.

**33×, not the 219× in F-19.** The gap grows with n, because the raw side is
O(n) per read. At 20,000 items it is 33×; F-19's larger case reached 219×.
Both are real — which is the point: this is the one cost in Ring that gets
*disproportionately* worse as your data grows.

## And a warning worth more than the speedup

[FINDINGS F-23](../../docs/FINDINGS.md): on a VM patched to generate the
items array itself — as RingScript's does — this idiom buys **nothing**,
because the VM already does from C what `RppIndexed` does from Ring. 467 ms
became 4 ms without Ring++ at all.

Gate the outcome, not the mechanism.

## Run it

```bash
ring examples/03-random-access-a-big-list/example.ring
```
