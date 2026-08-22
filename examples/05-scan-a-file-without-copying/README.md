# 05 — Scanning a file without copying it

**The task:** read a data file of length-prefixed records and walk it, doing
something with each payload. A log. A binary export. A wire capture.

```
[4-byte length][payload ...][4-byte length][payload ...] ...
```

**The result** (996 KB file, 5,000 records of 200 bytes):

| | |
|---|---:|
| raw Ring | **419 ms** |
| Ring++ | **84 ms** |
| | **4×** |
| bytes copied, raw | **9,700 MB** |
| bytes copied, Ring++ | **996 KB** (the file, once) |

---

## The whole difference

```ring
cData = read(cFile)                              # the file, as one string
nLen  = bytes2int(substr(cData, nOff + 1, 4))    # copies the whole file
cPay  = substr(cData, nOff + 5, nLen)            # copies it again
nAcc += HandleRaw(cPay)                          # and copies the payload in
```

```ring
oBuf.LoadFile(cFile)                             # bytes the buffer owns
nLen  = oBuf.PeekInt32(nOff)
oView = oBuf.View(nOff + 4, nLen)                # a WINDOW, not a copy
nAcc += HandleView(oView)                        # an object: crosses by reference
```

**This is the composition example.** [02](../02-pass-a-large-value/) showed
that objects cross a call boundary by reference;
[04](../04-slice-a-large-string/) showed that `substr` copies the whole
source. Here they meet: the handler receives a **view** rather than a copied
string, so nothing is copied to reach it, and nothing is copied inside it.

## Why only 4×, when 04 got 25×

Because this is closer to a real program. The raw side does real work too, and
the Ring++ side pays [example 08](../08-where-ringpp-loses/)'s per-element tax
on every `PeekInt32` and every `oView.Byte()`. Two views per record, 5,000
records, at ~3.2 µs each is most of the 84 ms.

**4× on a realistic shape is worth more than 25× on a microbenchmark**, and
quoting the bigger number would have been the easier thing to do.

## Where this loses — the honest half

- **If you read a file and touch it once** — hand the whole thing to a regex,
  say — `read()` is right and this is pointless. The win comes from scanning
  the **same bytes many times**.
- **A view is a window, not a copy.** It is valid only while its buffer is
  alive. `RppView` holds a `ref()` to its owner for exactly that reason, so
  the bytes cannot be freed underneath it — the [F-22](../../docs/FINDINGS.md)
  lesson applied at the API boundary.
- **A handler that needs a real Ring string must call `Str()`** and pay the
  copy. The saving is in not needing one.

## What writing this example actually found

This example did not just measure a speedup — **it uncovered a live bug in
Ring++** ([FINDINGS F-25](../../docs/FINDINGS.md)).

The natural loop above, with variables named `nOff` and `nLen`, was being
**silently corrupted by `View()` itself**: `RppView`'s attributes were also
named `nOff` and `nLen`, and in Ring an attribute assignment inside a class
can resolve against a caller's variable and overwrite it. The walk drifted
four bytes per record and failed 200 bytes later with

```
Rpp: View out of range — offset 212, length 1145258561
```

where `1145258561` is `0x44434241` — the ASCII of the payload it had wandered
into. Nothing in that message points at the cause.

`RppBuffer` had the same exposure through `cData` and `nCap`. Both are fixed;
the attributes are now prefixed (`oRppOwner`, `nRppOff`, `cRppData`, …), and
[`tests/name_collision.ring`](../../tests/name_collision.ring) gates it with
15 assertions.

**The existing test suite could not see this** — `fuzz_bounds.ring` even
contained a live collision and passed, because the value written over it
happened to match the value being read.

That is the argument for examples that *run* rather than benchmarks that get
quoted from memory.

## Run it

```bash
ring examples/05-scan-a-file-without-copying/example.ring
```

It writes a temporary data file, scans it both ways, asserts the results
match, and removes the file.
