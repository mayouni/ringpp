# P3 workload: Softanza's `stkBuffer`

**Status: step (a) done — the module is reachable. The `RppBuffer` swap,
step (c), has not been started.**

The plan was to reimplement `stkBuffer.Write` on `RppBuffer` and gate it on
"Softanza's own memory tests pass unchanged". Neither half was available:
the module could not be used through its own API, and its test file cannot
pass. So the order became **repair, then optimise**.

Gate: `ring bench/workload/stkbuffer_reachable.ring` → **12 passed, 0
failed, REACHABLE**. It was 0/12 before.

## Baseline, measured

500 overwrites of 8 bytes, via direct construction (Ring 1.27):

| buffer | per write |
|---:|---:|
| 1 KB | 4 µs |
| 10 KB | 8 µs |
| 100 KB | 20 µs |

`Write` is `left(@buffer, n) + data + right(@buffer, ...)` — the cost
scales with the buffer, not with the 8 bytes written. That is the F-7 shape
and `RppBuffer.Poke` would make it constant. The win is real; it is just
not the first problem.

Reproduce: `ring bench/workload/stkbuffer_baseline.ring`

## (a) What was repaired — eight defects

All in `stzlib/core/system/`. Each was verified failing first, and the
change is the smallest one that makes the intended API work.

| # | file | defect | fix |
|---|---|---|---|
| 1 | `stkMemory.ring` | `GetBuffer()` read `@aBufferId`, which does not exist | use `@aBuffers` |
| 2 | `stkMemory.ring` | a **failed lookup grew the registry** — `@aBuffers["nope"]` *creates* the key, so `NumberOfBuffers()` climbed on every miss | look the id up with `FindBuffer()` before indexing |
| 3 | `stkMemory.ring` | `CreateBuffer()` returned `1`, and the generated id was not returned either — no way to reach the buffer | return the buffer (`stkBuffer.Clone()` already assumed this) |
| 4 | `stkMemory.ring` | the registry stored a **copy** of the buffer, frozen while it was still empty | `ref(_oBuffer_)` |
| 5 | `stkMemory.ring` | `GetBufferById()` / `GetBufferInfo()` called by `stkPointer` but never defined | added as one-line aliases |
| 6 | `stkPointer.ring` | `init` validated `nPointerId <= 0` while `stkMemory` passes `"ptr1"` → `Error (R41) Invalid numeric string` | validate the id the way `stkBuffer` validates its own |
| 7 | `stkPointer.ring` | `catch cError` in three places — **Ring's `catch` takes no parameter**, so every one raised `Error (R24) uninitialized variable` instead of handling the error | `catch` + `cCatchError` |
| 8 | `stkBuffer.ring` | `Read()` printed two `DEBUG` lines to stdout | removed |

Defects 2, 4 and 7 are the interesting ones: each made the module *look*
like it worked while quietly doing the wrong thing.

## (b) Making `stkBufferTest.ring` real

It was not a broken suite — it was a **scratch file of 23 snippets**, and
two things stopped it being run as one:

- 23 `/*--- Test N` headers with only **one** `*/`, so Ring treated lines
  6–482 as a single comment and only Test 23 ever executed;
- `pf()` ends with `STOP()`, which raises — fine for running one snippet,
  fatal for a suite.

Changes, all minimal:

| what | why |
|---|---|
| `/*--- Test N` → `#--- Test N`, stray `*/` removed | the headers were never meant to comment code out |
| `pf()` → `pfq()` in the test; `pfq()` added to `stkProfiler.ring` | same timing banner, without `STOP()` |
| `new stkBuffer(n)` → `oMem.CreateBuffer(n)` | the class is owned by `stkMemory` by design; the old one-arg form belongs to `stkbuffer-copy.ring` |
| `new stkBuffer("data")` → `oMem.CreateBufferFromData(...)` | new factory on `stkMemory`; `stkBuffer.InitWithData()` existed for this and had no caller |
| `AppendFromFileXT()` added to `stkBuffer` | called by Test 14; the only genuinely missing buffer method |
| Test 17 commented with a `#TODO` | needs `RangeToPointer`, `stkPointer.Type()`, `RingValue()` — none exist. Left as written rather than invented. |
| `? clock() - nStart` → a bounded assertion | a raw timing printed 0 or 1 between runs, so no byte-comparable baseline was possible |

**Gate:** `test/run_stkbuffertest.sh` — runs the suite and diffs against
`test/correct/stkBufferTest.txt`, filtering the profiler banner and the
engine-DLL warning. Stable across six consecutive runs. `--bless` re-records.

### Two behaviours the working suite exposes

Recorded, not fixed — they are behavioural questions, not defects I should
decide alone:

1. **`Compact()` does not shrink capacity.** Test 11 writes 5 bytes into a
   10-byte buffer, `Resize(20)`, then `Compact()` and expects `Capacity()`
   to be 5. It stays 20. The test file already carried the note
   `# Buffer size mismatch` here.
2. **`Size()` succeeds on a freed buffer.** Test 19 calls `Free()`, checks
   `IsValid()` is false, then expects `Size()` to raise. It returns
   normally, so the test prints `Should not reach here`. `Size()` does not
   call `ValidateBuffer()` while `Read()` and `Write()` do.

Both are now visible in the baseline, so whichever way they are settled the
suite will notice.

## (c) The in-place write

`Write` rebuilt the whole string on every call. When the write lands
entirely inside the existing bytes, nothing has to move, so the bytes now
go in place through a pointer. Growth, padding, prepend, insert, delete and
resize are untouched — they still rebuild, because they must.

**A/B, one variable changed** (`@nInPlaceMin` raised to disable the path),
20,000 overwrites of 8 bytes, `bench/workload/stkbuffer_ab.ring`:

| buffer | rebuild | in place | |
|---:|---:|---:|---|
| 1 KB | 6.50 µs | 4.55 µs | 1.4× |
| 10 KB | 7.55 µs | 4.40 µs | 1.7× |
| 100 KB | 21.45 µs | 4.40 µs | 4.9× |
| 1 MB | 660.50 µs | **4.40 µs** | **150×** |

The ratio is not the point. The point is that the second column is **flat**:
`Write` no longer scales with the buffer.

**Gate:** `test/run_stkbuffertest.sh` byte-identical, and
`stkbuffer_reachable.ring` 12/12.

### Three things this cost, worth keeping

1. **The first version was 56 µs per write at 1 MB — still O(size).** The
   culprit was `_nLenBuffer_ = len(@buffer)`. Passing a string to a
   function copies it onto the VM stack first (FINDINGS F-5), so asking a
   1 MB buffer for its length costs a 1 MB copy. `@nSize` is maintained as
   exactly that value and reading it is free. **The fix for an O(n)
   problem contained its own O(n) line.**
2. **`varptr(:buffer, …)` raises `Error (R6)`.** A Softanza attribute
   written `@buffer` is *literally named* `@buffer`, so the call has to be
   `varptr("@buffer", …)`. Same family as the dead `varptr` in
   `stkPointer`, different root cause.
3. **The suite passed while the new code never ran.** Every buffer in
   `stkBufferTest.ring` is smaller than the 512-byte threshold, so
   "byte-identical" was true and meaningless. `stkbuffer_ab.ring` exists
   because of that: it exercises 1 KB to 1 MB and checks the written bytes,
   including an `int2bytes(256)` source — the leading-zero shape that
   aborts `memcpy` on Ring 1.27 (F-14, ring-lang/ring#1643).

Per-call cost is now ~4.4 µs, of which most is `varptr` (~0.8 µs) plus the
method-call and argument handling. Caching the address would remove it, but
every method that reassigns `@buffer` would have to invalidate the cache —
more invasive than this change, and not measured as necessary.

## What blocked it — as originally found

1. **`stkMemory.GetBuffer()` always raises.** It reads `@aBufferId`, an
   attribute that does not exist; the field is `@aBuffers`.
   → `Error (R5) : Can't access the list item, Object is not list`
2. **`stkMemory.CreateBuffer()` returns `1`, not the buffer**, and the
   generated id (`"buf1"`) is not returned either. With (1) broken, there
   is **no working path from `stkMemory` to a buffer**. Direct
   construction — `new stkBuffer(oMem, cId, nSize)` — is the only route,
   and it works.
3. **The narration documents an API that does not exist.**
   `base/doc/narrations/stz-lowlevel-system-programming.md` opens with
   `oBuffer = oMemory.CreateBuffer(50)`, which returns `1`.
4. **`stkBufferTest.ring` cannot pass.** 23 `/*` openers, 1 `*/` closer, so
   Ring treats lines 6–482 as one comment and only Test 23 runs — which
   calls `new stkBuffer(20)`, a one-argument constructor the loaded class
   does not have (it takes `oMemory, cId, nSize`). The test matches
   `stkbuffer-copy.ring`, not `stkBuffer.ring`.
5. **`stkBuffer.Read()` prints debug output** to stdout in shipped code:
   `DEBUG Read: @nSize = 11, nOffset = 0, nLength = 5`.

Previously found in the same module: `stkPointer.InitializeLowLevelAccess`
is dead — `varptr(:cBufferData, …)` against a local named `_cBufferData_`,
inside a `try`/`catch` that silently sets the pointer to `NULL`
(docs/DESIGN.md §4).

## Where it stands

- **(a) done.** The module is reachable; `stkbuffer_reachable.ring` is the
  gate and holds at 12/12.
- **(b) done — the suite runs.** `stkBufferTest.ring` executes all 19 live
  sections end to end and exits 0; it previously ran one section and
  aborted. See "(b)" below.
- **(c) done — `Write` is O(1) in the buffer size.** See below.
- **(c) note — it is *not* a drop-in for `RppBuffer`:**
  `RppBuffer`'s invariant is fixed capacity created once, while `@buffer`
  is resized by `Prepend`, `Insert`, `Delete`, `Resize` and `Clear`. The
  proportionate first step is the in-place path for the overwrite case
  only — when `nOffset + len(data) <= len(@buffer)` — leaving the growth
  paths alone.

Also still open, found earlier: `stkPointer.InitializeLowLevelAccess` takes
`varptr(:cBufferData, …)` against a local named `_cBufferData_`, so the name
never resolves and the low-level path stays `NULL`. Repairing defect 7 means
that failure is now *reported* rather than swallowed, which is the point,
but the name itself is untouched — and even corrected it would point at a
method-local that dies on return.

`ringpp check` flags defect 5's neighbourhood already; defects 1 and 2 are
the kind of thing it should learn to catch (a read of an attribute never
assigned anywhere in the class).
