# 01 — Patching a large buffer in place

**The task:** hold a large block of text and overwrite small fields inside
it, many times. A template being filled. A fixed-width record file being
updated. A protocol frame whose header changes on every send.

**The result**, on this machine (Ring 1.27, 500 KB buffer, 2,000 patches of
8 bytes):

| | |
|---|---:|
| raw Ring | **404 ms** |
| Ring++ | **7 ms** |
| | **57×** |

Output **byte-identical**, asserted by the example itself. If it were not,
the speed number would mean nothing and the example would say so.

---

## The whole difference

```ring
func RawWay nSize, nPatches, cPatch
    cBuf = copy("x", nSize)
    nLen = len(cPatch)
    nStep = floor(nSize / nPatches)

    for i = 0 to nPatches - 1
        nOff = i * nStep
        cBuf = left(cBuf, nOff) + cPatch + right(cBuf, nSize - nOff - nLen)
    next
    return cBuf
```

```ring
func RppWay nSize, nPatches, cPatch
    oBuf = new RppBuffer(nSize)
    oBuf.Fill(0, nSize, ascii("x"))
    nStep = floor(nSize / nPatches)

    for i = 0 to nPatches - 1
        oBuf.Poke(i * nStep, cPatch)
    next
    return oBuf.Str()
```

Same file, same project, one `load`. That is the point of Ring++: you do
not leave Ring, and you do not restructure the program. You reach for a
different container at the one place that hurts.

## Why the raw version is slow, and why you would never notice

Ring strings are immutable at the language level, so

```ring
cBuf = left(cBuf, nOff) + cPatch + right(cBuf, ...)
```

builds an **entirely new string** on every write. One 8-byte patch into a
500 KB buffer copies 500 KB. Two thousand patches copy **a gigabyte to
write sixteen kilobytes**.

Nothing about that line looks expensive. It is three builtin calls and a
concatenation — which is exactly why it survives code review, and why the
program is merely "a bit slow" until the buffer grows.

`RppBuffer.Poke()` writes **through a pointer** into bytes the buffer owns
([FINDINGS F-1, F-7](../../docs/FINDINGS.md)). The cost is the 8 bytes
written, not the 500,000 held.

## Where this loses — the honest half

Every claim in this project ships with the case it hurts.

- **Below ~512 bytes**, the `varptr` call costs more than the copy it
  avoids. `RPP_MEMCPY_CROSSOVER` exists for exactly this reason, and at 64
  bytes with 10 patches **raw Ring wins**.
- `RppBuffer` is for a buffer you **hold and hit repeatedly**. Building a
  short string once, then throwing it away, is Ring's job and Ring is good
  at it.

## A note on the number

[FINDINGS F-7](../../docs/FINDINGS.md) reports 803 ms → 1 ms for the
patching loop *alone*. This example measures the **whole task** — allocate,
fill, patch, and copy the finished bytes back out — because that is what a
program actually does. The end-to-end figure is smaller and more honest;
`oBuf.Str()` copies the 500 KB out once, and that copy is real.

## Run it

```bash
ring examples/01-patch-a-large-buffer/example.ring
```

It prints the comparison, asserts the outputs match, and ends with
`EXAMPLE 01 OK` — which is what the gate looks for.
