# What the Ring VM actually does — measured

*Session of August 10–11, 2026. Every number here comes from a program in
[`bench/`](../bench) run against `D:\ring127\bin\ring.exe` (Ring 1.27.0,
Windows 11, x64). Every claim about the VM cites a line in the stock
1.27 source at `D:\ring127\language\src`, not the vendored RingScript
tree (which carries an experimental `rlist.h` patch and would have
lied to me).*

Read this before the design. The design is downstream of it, and two of
these findings killed the design I would otherwise have written.

---

## The short version

Ring++ does **not** exist because pointers are faster than Ring
operations. On most work they are slower — measurably, by 3–28×,
because every crossing from Ring into a C function costs ~100 ns and
the pointer route needs more crossings.

Ring++ exists because of one structural fact:

> **Ring copies a string every time it crosses a call boundary.**
> Lists cross by reference. Strings cross by `memcpy`.

Everything expensive about big-data work in Ring traces to that one
macro, and everything Ring++ can honestly offer is a way of not paying
it. The measured headline: passing a 1 MB string to an ordinary Ring
function 3,000 times costs **≈2,200 ms**; passing a pointer handle to
the same bytes costs **1 ms**. Same data, same VM, no patch.

---

## Part 1 — Traps that are invisible in the source

### F-1. `memcpy()` on a Ring string silently does nothing

```ring
cDest = space(16)
memcpy(cDest, "ABCDEFGH", 8)
? cDest        # --> "                " unchanged, no error
```

`ring_vm_generallib_memcpy` (`genlib_e.c:1457`) takes
`RING_API_GETSTRING(1)` as the destination. But a string argument
reaches a C function through `RING_VM_STACK_PUSHCVAR` (`vm.h:230`),
which is `ring_itemarray_setstring2_gc(...)` — a **byte copy onto the VM
stack**. The `memcpy` faithfully writes into that copy, and the copy is
discarded when the call returns.

The same call through a pointer works perfectly:

```ring
cDest = space(16)
memcpy(varptr(:cDest, "char *"), "ABCDEFGH", 8)
? cDest        # --> "ABCDEFGH        "
```

Two lines that look identical; one is a no-op. This is the single
strongest argument for the project. Evidence:
[`bench/10_pointer_reach.ring`](../bench/10_pointer_reach.ring).

### F-2. `varptr` resolves names in the *caller's* scope, and takes a runtime name

`ring_vm_api_varptr` (`ringapi.c:223`) sets
`pVM->pActiveMem = RING_API_CALLERSCOPE` and then does
`ring_vm_findvar(pVM, cStr)`. Three consequences, all verified:

- It works on an **object attribute** from inside a method
  (`varptr(:cData, "char *")` where `cData` is an attribute) — so a
  Ring++ buffer object can own its bytes. This is the load-bearing fact
  for the whole design.
- It works on a **global** from inside a function.
- It accepts a **computed name**: `varptr(cName, "char *")` where
  `cName` is a runtime string — **but on 1.27 that string must already be
  lower case.** `varptr("nTotal", "int")` raises `R6` while
  `varptr("ntotal", "int")` succeeds, for a variable that plainly exists.
  The `:nTotal` symbol form is fine, because the scanner folds the
  literal. Fixed upstream on 2026-08-14; see [F-3](#f-3) for the four
  functions this affected and why folding the name yourself is correct on
  every version.
- **It does *not* reach the caller's frame.** Resolution is ordinary
  Ring lookup — the current function's locals, then globals. A `varptr`
  for a variable that lives only in the caller raises
  `Error (R6) : Variable is required`, which is catchable.

  *Correction: an earlier draft of this file claimed varptr reached the
  caller's frame, on the strength of a test whose target happened to be
  declared at top level — i.e. a global. Re-tested against a true local
  ([`bench/11`](../bench/11_varptr_scope.ring)), it raises. The name
  `RING_API_CALLERSCOPE` in `ringapi.c:235` means "the scope of the Ring
  function that called this C function", which is the ordinary current
  scope, not one frame up.*

What it cannot do is give you a pointer to the caller's *original*
string when the string arrived as a parameter — the parameter is a copy
(F-1). Evidence: [`bench/11_varptr_scope.ring`](../bench/11_varptr_scope.ring).

### F-3. Four lookups that take a name **as a string** required it folded — fixed upstream 2026-08-14

**Version-dependent, not a standing trap.** On 1.27 it bites; from the
next release all four accept the name as written.

```ring
ring_state_runcode(st, "nTotal = 7")
ring_state_findvar(st, "nTotal")   # 1.27 --> 0   (silently "not found")
ring_state_findvar(st, "ntotal")   # 1.27 --> the variable
```

Ring is case-insensitive and stores identifiers folded to lower case;
these functions did a raw lookup. `findvar` reports absence as the number
`0`, which is indistinguishable from a variable whose value is 0.

**It was four functions, not one.** This file originally recorded only
`ring_state_findvar`. Youssef Saeed (`@ysdragon`) found that `varptr` had
it too, and following that turned up two more:

| call, name as written | on 1.27 | from the next release |
|---|---|---|
| `varptr("nTotal","int")` | `R6` Variable is required | ok |
| `ring_state_findvar(st,"nCount")` | returns `0`, silently | found |
| `ring_state_setvar(st,"nCount",v)` | `R6` | ok |
| `ring_state_newvar(st,"cRegion")` | no error, **unreachable variable** | ok |

`newvar` is the worst of them and matters for the embedding work: it
stored the name unfolded, so Ring code inside that sub-state got
`R24: Using uninitialized variable` for a variable that existed and that
nothing in the state could address. It also means folding only the
*reader* would have **broken** `newvar("cRegion")` + `findvar("cRegion")`,
which worked precisely because both were unfolded. All four or none.

**Applied by Mahmoud on 2026-08-14**, credited to Mansour Ayouni and
Youssef Saeed:
[`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094),
test in [`ed69e68`](https://github.com/ring-lang/ring/commit/ed69e6824652025651638e6ee7d7262b2accba08)
as `language/tests/scripts/general/varnameinstatefuncs.ring`.

**What Ring++ does about it.** Fold the name yourself before passing it.
The same code is then correct on both, because folding an already-folded
name is a no-op — so this needs no version check anywhere.

**The `:symbol` form was never affected**, which is why nothing in this
project tripped over it. Verified on 1.27:

```ring
nTotal = 7
varptr(:nTotal, "int")     # ok    -- the scanner folds the literal
varptr("nTotal", "int")    # R6    -- a string is passed through raw
varptr("ntotal", "int")    # ok
cName = "nTotal"
varptr(cName, "int")       # R6    -- and so is a computed name
```

`RppBuffer` uses `varptr(:cData, "char *")` and Softanza uses
`varptr("@buffer", "char *")` — a symbol, and a string already in lower
case. Across Softanza, Ring's libraries and Ring's applications there is
exactly **one** string-name `varptr` with an upper-case letter in it.
That is why this is recorded here rather than made a `ringpp check` rule:
one occurrence, in a stray copy file, already reported by
`rpp/varptr-unknown-name` for a different and also real reason.

Evidence: [`bench/06_substates.ring`](../bench/06_substates.ring).

### F-14. `memcpy()` kills the process when the source string starts with a zero byte

**A real bug, not a documentation gap.** Found while writing
[`bench/14`](../bench/14_numeric_array.ring), which would not run.

```ring
cBuf = space(64)
p = varptr(:cBuf, "char *")

memcpy(p, int2bytes(7),   4)    # 07000000 -- fine
memcpy(p, int2bytes(256), 4)    # 00010000 -- process dies, exit 1, no message
memcpy(p, double2bytes(1.5), 8) # 000000000000f83f -- dies
memcpy(p, "NULL", 4)            # dies
memcpy(p, char(0), 1)           # dies, copying ONE byte
```

**Mechanism**, `ring_vm_api_ispointer` (`ringapi.c:118-147`), reached
from `RING_API_ISCPOINTER(2)` → `ISLISTORNULL(2)` → `ISPOINTER(2)`:

```c
if (RING_API_ISSTRING(nPara)) {
    /* Treat NULL Strings as NULL Pointers - so we can use NULL instead of NULLPOINTER() */
    if ((strcmp(RING_API_GETSTRING(nPara), RING_CSTR_EMPTY) == 0) ||
        (strcmp(RING_API_GETSTRING(nPara), RING_CSTR_NULL) == 0)) {
            ...
            ring_vm_api_setptr(pPointer, nPara, pList, RING_OBJTYPE_VARIABLE);  /* rewrites the stack slot */
            ring_list_addpointer_gc(pVM->pRingState, pList2, NULL);             /* the pointer is NULL */
            return RING_TRUE;
```

`strcmp` cannot distinguish `""` from a binary string that merely
*begins* with a zero byte — even though the VM knows the real size
(`nSize` is 8). The convenience branch reclassifies the argument as a
NULL pointer and **rewrites the stack slot in place**. Then
`ring_vm_generallib_memcpy` (`genlib_e.c:1481-1487`):

```c
if (RING_API_ISSTRING(2))   { pSrc = RING_API_GETSTRING(2); }     /* real bytes */
if (RING_API_ISCPOINTER(2)) { pSrc = ring_list_getpointer(...); } /* now NULL   */
...
memcpy(pDest, pSrc, nNum);                                        /* copy from address 0 */
```

**Two predictions, both confirmed** ([`bench/15`](../bench/15_memcpy_nul_source.ring)):
`int2bytes(256)` (leading zero) dies while `int2bytes(7)` lives; the
literal `"NULL"` dies while `"NULX"` lives. The fault is entirely on the
source side — it dies even when the destination is a plain string, i.e.
the path that does nothing at all (F-1).

**Nothing else is affected.** `len`, `str2hex`, `bytes2double`, `left`
and `murmur3hash` all handle the same string correctly, because they use
the recorded size rather than `strcmp`.

**Why this matters more than it looks.** Binary packing produces leading
zero bytes constantly: `double2bytes` of almost any round value,
`int2bytes` of any multiple of 256, every zeroed field in a record. A
Ring programmer writing a binary codec meets this within minutes, and
what they get is a process that vanishes with no line number.

**Workaround, verified** (`bench/15` arm 6): pass the source as a
**pointer**, never as a string —
`setptr(q, getptr(varptr(:cVal, "char *")))` then `memcpy(p, q, n)`.
Round-trips correctly. `RppBuffer.Poke` must do this internally, always.

**Upstream fix** is one line and preserves behaviour: test the recorded
size instead of `strcmp` for the empty case —
`RING_API_GETSTRINGSIZE(nPara) == 0`. The `"NULL"` literal case still
needs a comparison, but only when the size is exactly 4. Draft in
[UPSTREAM_NOTES.md](UPSTREAM_NOTES.md).

### F-15. A packed numeric buffer *loses* to a Ring list — until the loop is native

200,000 doubles, minima of 5 runs
([`bench/14`](../bench/14_numeric_array.ring)):

| summing 200,000 doubles | ms |
|---|---:|
| ordinary Ring list, `s += aList[i]` | 12 |
| packed 8-bytes-per-double buffer, `bytes2double(ptr2str(...))` | 26 |

**2.2× slower**, because each element costs two C calls (~200 ns) against
the list's single indexed read (~60 ns). But the same data read by
*compiled* code is the K2 kernel: 1,000,000 doubles in **0.96 ms**
native versus **92 ms** as a Ring list
([`bench/headroom`](../bench/headroom)).

So a packed numeric array is a **compiled-half data structure**. In
interpreted Ring, use a list. This is the F-8 lesson again in a
different costume, and it is the reason `RppArray` must be introduced
together with the compiler, not before it.

### F-16. An **empty** `catch` block leaks a VM stack slot

Found while building `RppBuffer`'s fuzz gate, which catches 125,000
errors on purpose.

```ring
for i = 1 to 1100
    try  raise("x")  catch  done
next
# --> Error (R4) : Stack Overflow
```

No recursion, no nesting, nothing deep. `ringvm_info()[18]` is
`pVM->nSP`, and it grows by exactly **one per caught raise** —
`RING_VM_STACK_SIZE` is **1004** (`vm.h:14`), so the program dies at
about 1003.

**And it happens only when the catch block is empty**
([`bench/16`](../bench/16_empty_catch_leak.ring), 300 iterations per arm):

| | SP before → after |
|---|---|
| **empty catch** | 1 → **301** |
| catch with one statement (`nSink++`) | 1 → 1 |
| catch reading `cCatchError` | 1 → 1 |
| empty catch, body never raises | 1 → 1 |
| empty catch **plus a statement after the try** | 1 → 1 |

So any statement in the catch — or any statement after the try — drains
the slot. The raised value is left on the stack only when nothing
follows to consume it.

**Why it matters beyond the curiosity.** `try … catch done` with an
empty handler is the idiomatic way to write "ignore this error", and it
is exactly what a validation or probe loop does thousands of times. It
is also what **RingScript** does — it wraps *every* eval in a try/catch
shim, so a page that evaluates a thousand failing snippets would hit
R4 in the browser.

**For Ring++:** `raise()`-per-illegal-access is safe, because our own
handlers do work. But it is a real constraint on the safety story, and
it is now a lint rule (`rpp/empty-catch`).

### F-17. A method shadows a same-named builtin inside its own class

```ring
class T
     func Len
          return 99
     func Poke cBytes
          ? len(cBytes)        # --> Error (R20): Calling function with
                               #     extra number of parameters
```

Inside a class, an unqualified call resolves to a **method** before the
builtin. `len(x)` became `This.Len(x)`, which takes no arguments. The
error names neither `len` nor `Len`, and points at the calling line.

Cost me a debugging cycle on `RppBuffer.Len()`, which is now `Size()`.
Any class exposing `Len`, `Copy`, `Left`, `Right`, `Find`, `Sort`,
`Type`, `Space` or `Read` will do this to itself.

### F-18. `N` and `n` are the same variable

Ring is case-insensitive throughout, identifiers included:

```ring
nIters = 100000
for n in aSizes  ... next     # `n` == `N`
for i = 1 to N   ... next     # N is now the last element of aSizes
```

My fuzz harness silently ran zero iterations and reported a clean pass.
Nothing warns. Distinct-by-case names are the trap — `N`/`n`, `x`/`X`,
`oList`/`OLIST` — and they read as different variables to anyone coming
from C, Python or JavaScript.

### F-19. How a list was **built** decides its random-access cost — 219×

**This corrects F-9 and F-12.** 60,000-item list, 20,000 truly random reads
([`bench/17`](../bench/17_list_build_shape.ring)):

| built with | ms |
|---|---:|
| `list(N)` — block-allocated | **2** |
| `b = []` then `b + i` — appended | **439** |
| appended, then `ringvm_genarray(b)` | **2** |

`list(n)` allocates its `Items` in **one contiguous block**
(`ring_vm_api_newlistusingblocks`, `ringapi.c:516`), so the cursor walk is a
linear scan through contiguous memory. An append-built list chases pointers
across pool slots. Same O(n) walk, roughly **200× the constant**.

So **`ringvm_genarray` is the fix for append-built lists.** For a list you
control, building it with `list(n)` gets you there for free — and F-12
already showed `list(rows, cols)` is 6× faster to build for 2D. The
trade-off is only that appending builds a flat list slightly faster
(3 ms vs 6 ms for 80,000 items).

**Two measurement traps, both of which fooled me first**, and both of which
would have silently invalidated this table:

- An index sequence like `((i * 7919) % N) + 1` is **locally ascending**.
  Ring's list cursor serves it almost free, so it looks like random access
  and is not. Use a real shuffle.
- An LCG with a 2^31 multiplier **overflows the double mantissa** — Ring
  numbers are doubles, so `nS * 1103515245` loses precision above 2^53 and
  the generator degenerates. Park–Miller (`16807`, `2^31-1`) stays inside.

### F-20. `get` and `put` cannot be method names

```ring
class Sandbox
     func Get cName        # --> Error (C6) : Error in function name
```

They are Ring statement keywords and, unlike `ok`/`on`/`off`, they never
demote to identifiers. `RppSandbox` uses `Var()` and `SetVar()` because of
this. The error names the file and line but not the reason.

### F-21. Every `func` after the first `class` becomes a **method**

```ring
func Helper                # global
class A
     func Thing            # method of A
func AlsoGlobal?           # NO -- also a method of A
```

There is no separator and no warning. The symptom appears far away, as
`Error (R3) : Calling Function without definition: alsoglobal`, at a call
site that is perfectly correct. **All functions in a file must precede all
classes.** Cost me a cycle on `rpp/idioms.ring`, where `RppRows`,
`RppSandbox`, `RppSyntaxOk` and `RppTokens` had quietly become methods of
`RppIndexed`.

### F-22. Ring copies objects on assignment — a cached address inside one becomes dangling

**Not a Ring defect, and nothing to report upstream.** Ring documents this
plainly in `documents/source/usingref.txt`:

> *"In Ring, Using the Assignment (=) operator copy variables by value."*
> (line 35)
> *"Also, Adding a List/Object to another List create a new copy."* (line 36)

`ref()` is documented on the same page as the remedy. The bug was mine, and
it was not reading the chapter. It is recorded here because the *cost* of
missing it is disproportionate — a silent heap corruption — not because
Ring is at fault.

The single most expensive mistake in this project, hit **three times in one
afternoon** before the pattern was recognised:

```ring
aBufs + RppBuffer(64)        # stores a COPY of the object
oBuf  = oOther               # a COPY
@aBuffers + [cId, oBuffer]   # a COPY
```

Objects are lists, and adding a list to a list copies it. Every consequence
below is the same root cause:

| where | symptom |
|---|---|
| `RppBuffer` cached its address in `init()` | the copy carried the *original's* pointer; the original was a temporary that died, so writes went into freed memory. **The process vanished with no message** — it survived a 100,000-access fuzz until the allocator happened to reuse the block. |
| `RppView` stored `oBuf = oBuffer` | the view read a snapshot taken at `View()` time; later writes through the buffer were invisible. It only *looked* right because both copies shared the stale cached pointer above — one bug masking another. |
| Softanza's `stkMemory` registry | `GetBuffer()` returned a buffer frozen while it was still empty (`bench/workload/README.md`). |

**The fix in a class that owns memory is not to cache the address at all.**
Re-deriving with `varptr` costs ~0.8 µs and is correct by construction: a
copy resolves its *own* attribute, so it writes to its own bytes. Where a
genuine reference is wanted, `ref()` is required and load-bearing —
`oBuf = ref(oBuffer)`.

Measured price of correctness: `RppBuffer.Poke` went from 5.8× to **6× raw
`memcpy`**, still 66× faster than pure Ring on the patch case. Cheap.

**The rule:** in Ring, an object holding a pointer to its own memory must
never cache that pointer, because it cannot know it is still the original.

### F-23. A patched VM can make a Ring++ idiom worthless — and the gate must say so

Found by the conformance matrix (P4) on its first two-row run, which is
exactly what it was built for.

> **RETRACTED 2026-08-25, the table below — the conclusions after it
> stand and are strengthened.** Found while investigating how RingScript
> could benefit from Ring++ ([`docs/SIBLINGS.md`](SIBLINGS.md)): the
> vendor patch this table blames — auto-`genarray` on random access in
> `ring_list_getitem_gc` — was **withdrawn from RingScript on 2026-08-14**,
> eight days *before* this finding was written on 2026-08-22, and rejected
> upstream by Mahmoud Fayed for the same reason F-10 documents (mixed
> add/read workloads go 1.7–2.3× **slower**, not faster) — see
> RingScript's own [`docs/VENDOR_PATCHES.md` §8](https://github.com/mayouni/ringscript/blob/main/docs/VENDOR_PATCHES.md).
> This finding was stale from the moment it was written; nobody re-ran the
> conformance matrix against RingScript's VM after the patch left.
>
> **Re-measured 2026-08-25, both VMs rebuilt fresh from source, minimum
> of 3, the same benchmark, corrected to build the list by append**
> (`bench/03_lists.ring`'s own method — a first attempt at this recheck
> used pre-sized index assignment instead and got a misleadingly fast
> result on *both* VMs, which is what caught that the reproducer, not
> just the old finding, needed checking):
>
> | VM, both Ring 1.27.0, both `zig cc -O2` | baseline | with `RppIndexed` |
> |---|---:|---:|
> | stock `language/src` | 322–343 ms | 3–4 ms (~90×) |
> | RingScript's vendored `ringvm/src`, current | 310–339 ms | 3–4 ms (~90×) |
>
> **No divergence at all.** RingScript's VM does not make `RppIndexed`
> redundant; it never durably did. What RingScript did instead, after
> withdrawing the C-level patch, is more interesting than the retracted
> claim: it rebuilt the *same idea* by hand, in Ring, at the call site —
> `playground/lib/table/table.ring:44-72` carries its own staleness flag,
> its own break-even floor, and explicit `ringvm_genarray()` calls,
> independently converging on `RppIndexed`'s own design rather than
> making it obsolete. That is a validation the original table never
> claimed.

`RppIndexed` exists because of [F-19](#f-19): random access to a
list walks the linked list, so a permuted pass is O(n²). The table above
was originally offered as a case where a patched VM made the idiom
worthless, on the strength of a patch that was already gone.

Two things still follow, kept because they do not depend on the retracted
table — and the second is the general one:

1. **`RppIndexed` must stay a phase object that measures, not a wrapper
   that assumes.** No VM measured so far makes it redundant, but the
   design should not need one to prove that in order to be right: it
   already refuses small lists, and it must stay free to conclude "this
   VM does not need me" the day some VM actually does. The layer above
   Ring cannot assume the layer below stayed still.
2. **Gate the outcome, not the mechanism.** `tests/idioms.ring` asserts
   *a permuted pass over 20,000 rows is not quadratic* and accepts either
   route to it, rather than a fixed multiple. That design decision is
   independently correct and is kept even though the case that first
   motivated it turned out to be a false alarm.

**What the matrix actually caught, corrected:** not a VM that had made
the idiom obsolete — a *finding* that was already stale when it was
written, sitting uncaught for three days until a routine "how could a
sibling benefit from Ring++" investigation re-ran the same numbers and
they came back different. The lesson is not "the code adapted correctly
to a changed VM" (it did not need to; the VM had not changed how this
table claimed). The lesson is duller and more useful: **a measured
number is only as current as the day someone last re-ran it**, and nothing
here re-ran this one until a different task's evidence-gathering did.

### F-24. A Ring type annotation is two different mechanisms wearing one syntax

The design (DESIGN_TOOLCHAIN §3) assumed `int func Sum(int x, int y)` was
one feature the parser accepts and discards. Measuring it before writing
the checker showed it is two, and only one of them is free.

| | `func Sum(int x, int y)` | `int func Sum(...)` |
|---|---|---|
| what it is | a **parser** feature — `ring_parser_paralist`, stmt.c:1217 accepts the type and drops it | an ordinary **expression statement** reading a global named `int` |
| needs a library? | no | **yes** — `typehints.ring` defines `int = :int` |
| without it | works | **Error (R24) : Using uninitialized variable: int** |
| enforced? | no | no |

`load "stdlib.ring"` does **not** supply the vocabulary; the load must be
explicit. So a file that annotates its return types and never loads
`typehints.ring` does not merely lose its hints — it aborts, on a line
that reads like a declaration:

```ring
? "hi"

int func Sum(int x, int y)     # Line 3 Error (R24)
    return x + y
```

And nothing is checked either way. With the library loaded,
`Sum("a","b")` on `int x, int y` returns `"ab"` — string concatenation,
no error, no warning. That is the gap `ringpp check` level 1 fills, and
it is why DESIGN_TOOLCHAIN's boundary guard is non-negotiable for
level 2: a compiled version that believed the annotation would disagree
with the interpreter.

**Arity is the exception — Ring does enforce it**, and exactly:

| | |
|---|---|
| too few arguments | `Error (R19) : Calling function with less number of parameters` |
| too many | `Error (R20) : Calling function with extra number of parameters` |

Ring has no default parameters, so the count is decidable from the
source. That makes arity the one thing a static checker can call an
*error* rather than a warning, and it is where the value turned out to
be. Across Softanza's live tree (5,949 files) it found **99 call sites
in 46 distinct functions**, and across Ring's own tree (1,959 files)
exactly **one** — all dormant, because the paths are not exercised. The
dominant shape is an alias that forgot to forward its parameter, and one
was confirmed end to end:

```
func @IsContinuous()
    return IsContiguous()        # IsContiguous takes paList
```

```
Line 7574 Error (R19) : Calling function with less number of parameters
In function @iscontinuous() in file .../stzListFunc.ring
```

**The false positive that shaped the rule.** Ring's one-line class form
puts an attribute in exactly the position of a return annotation:

```ring
Class Point x y z func print see x + nl + y + nl + z + nl
```

`z` is an attribute, and the first version of the checker reported R24
on `ring127/samples/AQuickStart/OOP/oop1.ring` — correct code. Two
structural guards fixed it: the name must be in Ring's fixed hint
vocabulary, and it must not be part of a *run* of bare identifiers on
the same row. The cost is that `MyClass func Foo` is no longer seen,
which is also R24 without the library. Missing a true positive is much
cheaper than inventing a false one — and after the guards, Ring's 1,959
files produce exactly one type finding, which is a real bug in
`getquoteshistory/GetQuotesHistoryDraw.ring:3165`.

**Not upstream material.** Everything here is Ring behaving as
documented; the hint chapter says the types are hints. The finding is
that the two halves have different runtime requirements, which is a
thing to *check for*, not to report.

### F-25. A class attribute silently clobbers a caller variable of the same name

**A bug in Ring++, caused by a behaviour of Ring, found by writing an
example rather than by any test.**

Inside a Ring class, an attribute assignment can resolve against a
**caller's** variable of the same name and overwrite it. The attribute is
not set; the caller's value is destroyed.

```ring
cData = "CALLER OWNS THIS"
nCap  = 12345

oB = new RppBuffer(64)      # attributes were cData, nCap, ...
oB.Poke(0, "hello")

? cData     # --> "hello                    ..."   the buffer's backing string
? nCap      # --> 64                               the buffer's capacity
```

`RppBuffer` held `cData`, `nCap`, `pScratch`, `pSrcPtr`, `cNul`;
`RppView` held `oBuf`, `nOff`, `nLen`. Every one of those is a name a
caller plausibly uses, and **`cData` is one of the commonest names in the
data-processing code this library exists for.**

**How it presents.** Not as a crash at the call — as corruption several
iterations later. The loop that found it is the most natural one anybody
would write over length-prefixed records:

```ring
nOff = 0
for i = 1 to nRecs
    nLen  = oBuf.PeekInt32(nOff)
    oView = oBuf.View(nOff + 4, nLen)   # destroys nOff and nLen
    nOff += 4 + nLen
next
```

`View()` overwrote `nOff` and `nLen` with its own offset and length, the
walk drifted by four bytes per record, and the failure surfaced as
`View out of range — offset 212, length 1145258561` — a bounds error
200 bytes downstream, with a "length" that is the ASCII of the payload
(`0x44434241` = `"ABCD"`). Nothing in that message points at the cause.

When the caller's buffer was *also* named `oBuf`, it was louder but no
clearer: `Error (R31) : Trying to destroy the object using the self
reference`, raised from the class body's initialiser.

**Two related Ring facts, both measured here:**

- A **bare** attribute name on its own line (`oBuf`) does **not** create a
  property. The first assignment then has no attribute to land on. Adding
  `= NULL` creates it — but does not fix the clobbering.
- `This.oBuf = …` raises `Error (R12) : property not found` when the
  property was only declared bare, so the obvious defensive fix does not
  work either.

**The fix is the boring one that actually holds:** give private attributes
a prefix no caller types by accident — `cRppData`, `nRppCap`,
`pRppScratch`, `pRppSrcPtr`, `cRppNul`, `oRppOwner`, `nRppOff`, `nRppLen`.
`varptr(:cData, …)` must move with the rename or `Base()` resolves
nothing.

**Why the test suite could not see it.** Every existing test happened to
avoid the names — except `tests/fuzz_bounds.ring:59`, which contains
`nCap = oB.Capacity()`. That is a live collision, and it **passed anyway**,
because the value the library wrote over it was the same value being read.
A silent bug hidden by a coincidence, inside the harness written to find
silent bugs.

Regression: [`tests/name_collision.ring`](../tests/name_collision.ring),
15 assertions, gated. Verified non-vacuous by reintroducing one collision
and watching it fail.

**Not upstream material as it stands.** Ring's scoping rules may well
document this, and the reproducer would need reducing to a plain class
with no Ring++ around it before it is worth anyone's time. Recorded here
as a Ring++ defect with a Ring cause.

### F-26. A duplicate function name is a load-time kill — and that is what makes cross-file checking sound

Measured 2026-08-23, both shapes, Ring 1.27:

```ring
# one file
func Sum x, y     ...
func Sum a, b, c  ...
# --> Line 4 Error (C22) : Function redefinition, function is already defined!
```

```ring
# across a load
load "a.ring"        # defines Sum(x, y)
func Sum a, b, c     # this file's own
# --> Line 4 Error (C22), same message — the program NEVER STARTS
```

`C22` fires at **load time**, before the first line executes, and its
message names neither definition site.

**Why this finding matters more than it looks.** It is the soundness
proof for cross-file type checking. Within one load graph, a name that
resolves has **exactly one live definition** — any program carrying two
is dead before it runs. So a call in `app.ring` to a function defined in
`lib.ring`, reached through `load`, can be checked against that
definition with the *same certainty* as a same-file call: no other
definition can exist in a program that runs.

The same fact dictates the two edge behaviours:

- a name defined **twice inside one closure** is itself the defect —
  reported as `rpp/type-duplicate-func` at the **join file** (the one
  whose loads first bring the definitions together), with both sites
  named, since Ring's own message names neither;
- conflicted names are **excluded** from arity and type checking, because
  a report against an arbitrary one of the two would be a guess.

And the guard for trees of *independent programs* (an `examples/`
directory where every file defines its own `Helper()`): files are related
**only through `load` edges they actually contain**. The scan root is not
a program — the load graph is.

### F-27. Inside a class, a method beats a same-named global — even an inherited one

Measured 2026-08-23, five reproducers on Ring 1.27. The resolution order
for an **unqualified** call made inside a class body is:

```
own method  ->  inherited method  ->  global function  ->  builtin
```

and **arity is enforced at every step**:

| the case | Ring says |
|---|---|
| class defines `Helper(a,b)`, call `Helper(1)` | `R19` |
| no method; global `Helper(a,b)`, call `Helper(1)` | `R19` |
| parent defines `Helper(a,b)`, call `Helper(1)` in child | `R19` |
| method `Helper(a,b)` **and** global `Helper(x)`, call `Helper(1)` | `R19` — **the method wins** |
| **parent's** `Helper(a,b)` and global `Helper(x)`, call `Helper(1)` | `R19` — **inherited still wins** |

The last two are the ones that matter. A same-named global does **not**
rescue a wrong call, and inheritance does not weaken the rule.

**What this recovers.** [F-17](#f-17) established that a method shadows a
same-named builtin, and the checker's first version responded by giving
up on *every* call inside a class body — hundreds of thousands of call
sites in a large project, unchecked. F-27 says that surrender was too
broad: when the whole method chain is visible, the call is decidable with
the same certainty as a top-level one.

**Where it still refuses**, and both are real limits rather than laziness:

- **an unknown parent class** — `class Child from SomethingElsewhere`.
  The parent's method table is unknown, so any name not defined on the
  child could resolve to an inherited method of any arity. Nothing is
  reported.
- **a cycle or absurd depth** in the parent chain (guarded at 32 hops).

**A grammar detail that shapes the implementation.** tree-sitter nests
`class_definition` nodes — `class Child from Parent` is parsed *inside*
Parent's node — although Ring treats classes as siblings. A class's own
methods are therefore the `function_definition` children **before** any
nested `class_definition`, and the walker must restore the enclosing
class on the way out or a child's table leaks into its parent's tail.

### F-4. Cheap-looking calls that are not cheap

Net cost per call, 300,000 iterations, loop baseline subtracted
([`bench/02_unit_costs.ring`](../bench/02_unit_costs.ring)):

| call | ns/call | why |
|---|---:|---|
| `len("abc")` | 43 | a C function call |
| a Ring `func` call | 70 | |
| `getptr(p)` | 60 | reads one field |
| `memcpy(p, "ab", 2)` | 97 | |
| `ptr2str(p, 0, 8)` | 97 | |
| `substr(cV, 1, 8)` on a 64 B string | 70 | |
| **`nullptr()`** | **520** | builds a 3-item Ring list every call |
| **`varptr(:v, "char *")`** | **790** | `findvar` by name **+** builds that list |

`varptr` and `nullptr` are 8–12× a normal function call. A design that
calls `varptr` inside a loop has already lost. Every Ring++ buffer must
take its pointer **once**, at construction, and cache it — which also
means Ring++ must own the buffer's lifetime, because a cached pointer
that outlives its string is a dangling pointer (F-9).

---

## Part 2 — The one real win

### F-5. The by-value tax on strings: ~2,200×

3,000 calls passing a 1 MB string to a one-line Ring function
([`bench/07_by_value_tax.ring`](../bench/07_by_value_tax.ring)).
Three runs gave 2,206 / 2,238 / 2,367 ms — quote it as **≈2,200×**, not
to four digits:

| | ms | per call |
|---|---:|---:|
| `Consume(cBig)` — by value | 2206–2367 | ~750 µs |
| `ConsumeP(p, nLen)` — pointer handle | 1 | 0.3 µs |
| a 100,000-item **list** by value | 1 | lists cross by reference |

The tax is exactly the size of the string, paid on every crossing. It is
not specific to user functions: it is `RING_VM_STACK_PUSHCVAR`, so every
built-in that takes the string as an argument pays it too.

### F-6. Which core string operations pay it — and which don't

500 KB string, 2,000 calls per measurement, **7 repetitions, minimum
reported** ([`bench/08_string_ops_tax.ring`](../bench/08_string_ops_tax.ring)).

*Minimum, not mean: the first version of this benchmark reported single
runs and produced a table that swung 4× between runs — `substr` at
106 ms then 25 ms, `left` at 76 ms then 265 ms. Noise only ever adds
time, so the floor is the honest cost. The corrected table is both
stabler and less flattering than the one I first wrote.*

| operation | µs/call (floor) | pays the tax? |
|---|---:|---|
| `cBig[n]` — index one byte | **< 0.5** | no — the VM indexes the variable in place |
| `ptr2str(p, n, 10)` | **0.09** | no |
| `substr(cBig, n, 10)` | 12.5 | yes |
| `len(cBig)` | 12.5 | yes |
| `left(cBig, 10)` | 12.5 | yes |
| `substr(cBig, "gamma")` | 12.5 | yes |

The four taxed operations all cost **the same**, because what they cost
is the copy, and the operation itself is noise beside it. Control: the
same calls on a 64-byte string are all under the timer floor.

So: **`substr` of ten bytes costs 12.5 µs because it first copies half a
megabyte. `ptr2str` of the same ten bytes costs 0.09 µs** — the
per-call figure from F-4, which is stable at 300,000 iterations.
**~140× for this string size, and it grows with the string.**
Ring already has an O(1) substring; it is spelled `ptr2str` and nobody
knows it.

This is the parser/codec wall. It is also why `cBig[n]` being free
matters: character-at-a-time scanning in pure Ring is 67 ms for 500 KB
and is *not* the problem. Slicing is.

*Why F-5's per-call number (746 µs for 1 MB) is far more than twice
F-6's (12.5 µs for 500 KB): a call into a **Ring** function copies the
string twice — once onto the stack, once into the callee's scope — and
1 MB does not stay in cache, where 500 KB does. The tax is proportional
to size, but the constant depends on the call target and on cache
residency. Both numbers are reported as measured; neither should be
turned into a bytes-per-second rate.*

### F-7. In-place patching: Ring has no other way

2,000 eight-byte patches at scattered offsets in a 500 KB buffer
([`bench/09_inplace_patch.ring`](../bench/09_inplace_patch.ring)):

| | ms |
|---|---:|
| `cA = left(cA,n) + "PATCHED!" + substr(cA,n+8)` | 803 |
| `setptr(q, base+n)` `memcpy(q, "PATCHED!", 8)` | **1** |

Byte-identical results. Pure Ring must rebuild the whole string per
patch; there is no in-place write in the language. This is the one place
where "drop a level" is not an optimisation but the only implementation.

*(Note for the Softanza review: `stkBuffer.Write` is the 803 ms shape —
`left(@buffer, n) + data + right(...)`, O(n) per write.)*

### F-8. Where the pointer route **loses** — the honest half

Building 1.6 MB from 200,000 eight-byte chunks
([`bench/01_string_build.ring`](../bench/01_string_build.ring)):

| | ms |
|---|---:|
| `cOut += CHUNK` | **12** |
| `space()` + `memcpy` through a cached pointer | 340 |
| the same with `varptr` inside the loop | 415 |

**28× slower.** `ring_string_add2_gc` (`rstring.c:87`) grows capacity by
doubling, so Ring's `+=` is amortised O(1) and already excellent. The
memcpy route pays three C crossings per chunk to move eight bytes.

The crossover, building 4 MB
([`bench/09_inplace_patch.ring`](../bench/09_inplace_patch.ring)):

| chunk | concat | memcpy | ratio |
|---:|---:|---:|---:|
| 8 B | 31 ms | 155 ms | 5.0 |
| 64 B | 6 ms | 20 ms | 3.3 |
| **512 B** | 2 ms | 2 ms | **1.0** |
| 4 KB | 2 ms | 1 ms | 0.5 |
| 64 KB | 2 ms | 0 ms | ~0 |

**512 bytes is the break-even for sequential appends.** Below it, use
`+=`. Any Ring++ API that encourages small-chunk `memcpy` writing is a
performance regression wearing a systems-programming costume.

---

## Part 3 — Lists

### F-9. `ringvm_genarray` is worth ~95× — and one `+` destroys it

80,000-item list, 80,000 permuted reads
([`bench/03_lists.ring`](../bench/03_lists.ring)); two runs, 93× and 98×:

| | ms |
|---|---:|
| permuted read, no array | 1562–1579 |
| after `ringvm_genarray(a)` | **16–17** (~95×) |
| after **one** `a + 999999` | 1673–1724 |

`ring_list_newitembyitemsptr_gc` (`rlist.c:205`) calls
`ring_list_clearcache_gc` on every add past the first, and
`ring_list_clearcache_gc` (`rlist.c:176`) calls `ring_list_deletearray_gc`.
So a single append frees the items array. There is no way to ask a list
whether it currently has one.

### F-10. The break-even curve — Mahmoud's objection, quantified

80,000-item list, 300 rounds of *(one add + N permuted reads)*
([`bench/04_genarray_breakeven.ring`](../bench/04_genarray_breakeven.ring)):

| reads per add | plain | genarray each round | ratio |
|---:|---:|---:|---:|
| 1 | 4 ms | 65 ms | **16.2× worse** |
| 5 | 15 ms | 64 ms | **4.3× worse** |
| 20 | 53 ms | 32 ms | 0.60 |
| 50 | 134 ms | 38 ms | 0.28 |
| 100 | 297 ms | 35 ms | 0.12 |
| 400 | 1225 ms | 62 ms | 0.05 |

He was right, and the number is ~10–20 random reads per mutation at
N = 80,000. Below that, "just call genarray" costs up to 16×.

The design consequence is precise: **genarray is a property of a
*phase*, not of a list.** A Ring++ API that attaches it to a list object
and refreshes it eagerly reproduces exactly this regression. An API that
makes the programmer name a read-only region cannot.

### F-11. I could not reproduce a global cost from registered blocks

`ring_state_free` (`vmgc.c:819`) tries the pool first, then walks
`vPoolManager.pBlocks` linearly under a mutex for every pointer the pool
does not own — i.e. for every allocation over 512 bytes
(`pooldata.h:29`). `list(n)` for n > 6 registers two blocks
(`list_e.c:187` → `ringapi.c:520`).

So the mechanism Mahmoud described is real in the source. But at the
Ring level I could not make it bite
([`bench/05_registered_blocks.ring`](../bench/05_registered_blocks.ring)):
holding 5,000 block-allocated lists left a `space(4096)` churn at 63 ms,
identical to 5,000 append-built lists (65 ms) and to the control (65 ms).
The step from 7 ms to ~65 ms is heap warm-up, not the block scan —
arm B shows it at "0 held".

Reading this honestly: `list(n)`'s block registrations mostly do not
survive, because the result is copied into its destination and the
block-allocated original is freed. His objection was aimed at a
*proposed patch* that would have registered **items arrays** as blocks;
that would have made every large free O(live genarray'd lists). The
shipped code does not do that. `ringvm_genarray` called from Ring goes
through `ring_list_genarray` — the **non-`_gc`** variant
(`vminfo_e.c:371`) — so its array is a plain `malloc`/`free` outside the
pool entirely.

I record this as *not reproduced at the Ring level*, not as *wrong*.

**Where the cost actually was** (measured in the RingScript session, on
two builds, not by me — recorded here because it completes this finding).
The dominant cost of that proposed patch was never the free path. It was
`ring_list_clearcache_gc()` freeing the items array on *every* structural
mutation while a random read rebuilds it: add/read alternation pays a
`malloc` plus a full O(n) rebuild per iteration, measured at **1.7–2.3×
slower on mixed add/read, widening with n**.

Which is [F-9](#f-9) seen from the other side — and the same mechanism
[F-19](#f-19) and [F-23](#f-23) keep running into. Mahmoud's objection
was right, and the reason it was right is one line in `rlist.c`, not the
pool.

### F-12. `list(n)` versus appending

80,000 items ([`bench/03_lists.ring`](../bench/03_lists.ring)):

| | ms |
|---|---:|
| `a + i` × 80,000 | 3 |
| `list(N)` then `a[i] = i` | 6 |
| `list(R,5)` — 20,000 rows | **3** |
| `aR2 + [0,0,0,0,0]` — 20,000 rows | 18 |

For flat lists, appending wins; the received wisdom "preallocate" is
wrong in Ring. For **2D**, `list(rows, cols)` is 6× faster than pushing
sublists, because it uses the block allocator (`ringapi.c:545`). That is
a genuine, unadvertised idiom.

---

## Part 4 — The embedding API from inside Ring

### F-13. `ring_state_*` gives you a real second interpreter, and it is cheap

[`bench/06_substates.ring`](../bench/06_substates.ring):

- `ring_state_init()` + `ring_state_delete()`: **0.35 ms** each.
- **Isolation is real.** A sub-state assigning `gHost` does not touch the
  host's `gHost`. Verified.
- **A runtime error in the sub-state does not kill the host.** `? 1/0`
  inside a sub-state printed `Error (R1)` and execution continued in the
  host. `ringvm_hideerrormsg(1)` inside the sub-state silences even that.
- Values come back with `ring_state_findvar` (subject to F-3).
- `ring_state_stringtokens(st, cCode)` returns Ring's **token stream** as
  a list — a real scanner, callable from Ring, no extension.
- `ring_state_scannererror(st)` gives a **syntax verdict without
  running** the code.
- `ring_state_runcode` is 13 µs vs `eval`'s 10 µs — comparable.

What it is *not*: faster. The same 200,000-element build-and-sum took
42 ms in a fresh sub-state versus 24 ms in the host (cold pool), and
`ring_state_delete` of the whole thing took 5 ms versus 3 ms for
`callgc()` in the host. **Sub-states buy containment, not speed.** Their
honest uses are sandboxing untrusted or generated code, syntax-checking,
tokenising, and giving a risky computation a blast radius.

---

### F-28. A `.ringo` embeds everything `load` pulled in, and runs with no compiler

*Measured 2026-08-23, Ring 1.27. This is the finding the build half rests
on, so it was established before any of it was designed.*

`ring file.ring -go` writes a `.ringo` object file, and `ring file.ringo`
**executes it directly**. No C compiler is involved at any point.

**`load` is resolved at compile time and its target is absorbed into the
bytecode:**

| program | `.ringo` |
|---|---:|
| `? "hello"` — no `load` | **301 bytes** |
| the same plus `load "stdlib.ring"` | **221,794 bytes** |

That 737× is stdlib being *carried inside the object file*, not
referenced from it. The consequence is the useful one: **one `.ringo`
carries the whole Ring-source dependency tree of a program.**

**The runtime it needs is two files and 1.3 MB.** Verified by copying
`ring.exe` (0.60 MB) and `ring.dll` (0.63 MB) into an empty directory
with nothing else — no `libraries/`, no source — and running both object
files there. Both printed correct output and exited 0. The 477 MB Ring
install is not the runtime; 171 MB of it is Qt.

> **Refined 2026-08-24, phase B2.** Two files is what the *official*
> distribution ships. Compiling Ring's own VM source (`language/src/*.c`)
> directly with `zig cc` — no target flag, so the host is Windows —
> produces **one 512,000-byte `.exe` that needs no `ring.dll` at all**:
> verified by deleting `ring.dll` from the directory and re-running the
> same fixture, output unchanged. The official build links the VM as a
> separate DLL for its own reasons (likely a shared-load path across its
> own tool family); nothing requires it. **A self-built runtime is a
> smaller and stricter single-file claim than the vendored one**, and it
> is what phase B2 ships.

**What this does *not* cover, and the limits are the point:**

- **Native extensions cannot be embedded.** Anything reached by
  `loadlib` — the ~131 non-Qt `ring_*.dll` — is opened at run time and
  must ship beside the executable. A console or server program can be one
  file; a GUI or database program cannot.
- **Bytecode portability across architectures is UNMEASURED.** Every
  figure above is Windows x64. Whether a `.ringo` written here loads on
  Linux arm64 has not been tested, because no non-Windows Ring runtime
  was available on this machine. **Nothing may be claimed about
  cross-platform output until that is measured** — it is the first gate
  of the build half for exactly that reason.

**Why it matters.** Ring's own `ring2exe` generates a `.c` file and then
shells out to **Visual C++, GCC or Clang** (`tools/ring2exe/README.md`).
The bytecode route above reaches a runnable artefact with none of them.
That gap is the whole argument for the build half, and it is Ring's own
mechanism — not something added to it.

### F-29. Bytecode crosses platforms; a *failed* `loadlib` does not

*Measured 2026-08-23, phase B0. Gate: `tests/b0_bytecode.ps1`.*

**The bytecode format is portable.** A `.ringo` compiled by Ring 1.27 on
**Windows x64** and executed by a Ring 1.27 runtime cross-compiled for
**Linux x86_64-musl** produced **byte-identical output** across integer
arithmetic, float formatting (`1/3` → `0.33` on both), string case,
`ascii`/`char`, loop accumulation and list indexing.

The object file is **text**, and it carries its own version:

```
# Ring Object File
# OBJECT 1.25
```

**`OBJECT 1.25` while `ring.exe` reports 1.27.0** — the object format is
versioned *separately from the language*. That number is the thing to
watch: it, not the Ring version, is what would silently invalidate every
already-packaged program.

### The half that does not travel, and it is not the bytecode

A program whose only sin is `load "stdlib.ring"` behaves **differently on
the two platforms running the same bytes**:

| | Windows x64 | Linux x86_64 |
|---|---|---|
| `pure.ringo` (no `load`) | correct | **identical** |
| `lib.ringo` (`load "stdlib.ring"`) | correct, **exit 0** | **`Error (R38)`**, `libring_odbc.so` |

The cause is not the bytecode and not stdlib. It is that **a `loadlib`
that fails is silent on Windows and fatal on Linux.** `stdlib.ring`
reaches native extensions it does not need for `upper()`; on Windows the
missing library is shrugged off, on Linux it raises R38 and stops the
program.

Proved by isolation, both directions:

- an **empty directory** holding only `ring.exe` + `ring.dll` (1.3 MB, no
  `extensions/`, no `libraries/`, no `ring_*.dll`) runs `lib.ringo`
  correctly and exits **0** — so Windows genuinely does not need the
  extension;
- the same `lib.ringo` on Linux dies on `libring_odbc.so`, a library the
  program never calls.

**The consequence for packaging is the finding.** An executable built and
tested on Windows can fail on Linux *for a library it does not use*, and
the failure appears at run time in the user's hands, not at build time.
Any build half must therefore either resolve `loadlib` at package time or
carry the platform's extensions — the bytecode being portable is
necessary and **not sufficient**.

### What is still unmeasured

**arm64.** Everything above is x64→x64. Whether a `.ringo` loads on
`aarch64` is untested — it needs a device or an emulator, which is a
deliberate cost rather than a default. Until it is measured, the honest
claim is *"portable between x64 platforms"*, and nothing wider.

---

### F-30. A "complete" bundle can still crash with no diagnostic — Ring's Qt bridge

*Measured 2026-08-24, phase B3, while packaging a `guilib`-reaching
program to test `ringpp build` against a shape wider than F-29's database
extensions.*

`ringpp deps` names exactly one library for a program that
`load "guilib.ring"`s: `ringqt.dll` (or `ringqt_light`, `ringqt_core` —
the same family, reached the same way). `ringpp build`, given that name
under `--lib-dir`, copied it in and wrote a manifest with **no `MISSING`
line** — by every static measure this tool has, the package was
complete.

**It is not.** Copied to an isolated directory — the exe, the bytecode,
and `ringqt.dll`, nothing else — the packaged program does not print
`Error (R38)` the way F-29's database extensions do. It **crashes with no
diagnostic at all**: Windows exit code `0xC0000409`, zero bytes of
output.

**The cause is a layer B1's static analysis cannot see.** `ringqt.dll`
itself links against roughly 75 further Qt libraries (171 MB, measured in
F-28) at the **OS loader level** — a dependency the operating system's
loader resolves, not something Ring's `loadlib()` call ever names. B1
correctly reports everything Ring's *source* declares; it has no way to
see what the *resulting binary* itself requires, because that information
exists nowhere in a `.ring` file. A silent crash is a **worse** failure
mode than F-29's R38: at least R38 prints something before the program
stops.

**Not treated as a gap to close — treated as a boundary.** Per the
project's own dependency-free principle (Softanza's Ring foundations
depend on nothing but what they vendor and support themselves; Qt's
weight and complexity put it outside that), Ring++ does not attempt to
package Qt-reaching programs at all, rather than half-support one into a
manifest that lies by omission. `ringqt`, `ringqt_light` and
`ringqt_core` are named exclusions — not a heuristic, not a size
threshold, exactly the three entry points in
`libraries/guilib/{guilib,lightguilib,qtcore}.ring` — and both `ringpp
deps` and `ringpp build` refuse on sight:

```
ringpp build: this program reaches Ring's Qt bridge (ringqt), which
  Ring++ does not package — see DESIGN_BUILD.md sections 3 and 6.
```

Verified non-vacuous by removing the exclusion and re-running the gate:
without it, `ringpp build` exits 0 and writes a package — the exact
silent-crash artefact this finding is about.

**What this does not decide.** Every other native extension measured so
far (`ring_odbc`, `ring_mysql`, `ring_sqlite`, `ring_internet`,
`ring_openssl`, `ring_pgsql`) is a single self-contained file with no
sibling family — B3's bundle case packages all six correctly. The Qt
bridge is not excluded for being a native extension; it is excluded for
being one whose own transitive dependency surface Ring's source cannot
name and Ring++ will not guess at.

### F-31. `memcpy()` reads the **C view** of the source, so `"NULL"` is a prefix, not a value

F-14 recorded that `memcpy()` aborts the process when the source string
is the literal `"NULL"`, because `ring_vm_memcpy` uses `strcmp` to decide
whether an argument is a null pointer. The shape of that test was read
too narrowly here, and Ring++ carried the resulting hole for its whole
life until `tests/differential.ring` found it on 2026-08-25.

**`strcmp` sees a C string. A Ring string whose bytes begin `N U L L \0`
*is* `"NULL"` to `strcmp`, whatever its Ring length.**

Four lines kill the process, with no message and no line number:

```ring
oB = RppBuffer(16)
oB.Poke(0, "NULL")            # 4 bytes -- the old guard caught this
oB.Poke(4, RPP_NUL_BYTE)      # 1 byte  -- the old guard caught this too
oB.Grow(33)                   # <-- copies all 16 bytes as ONE source. Dead.
```

Neither write is dangerous. `Grow` is: it hands the whole buffer back to
`Poke` as a single source, and those 16 bytes now begin `NULL\0`. The old
guard —

```ring
if cBytes[1] = cRppNul or (nL = 4 and cBytes = "NULL")
```

— tests the Ring *value* for equality with `"NULL"`, which a 16-byte
string can never satisfy. The correct test is on the bytes: first four
are `NULL`, and either the length is 4 or the fifth byte is zero.

**Cost of the fix: +0.075 µs per `Poke`, ~3.7%** — 200,000 pokes of an
ordinary 8-byte payload, three alternating measurements of each build,
minima 423 ms fixed against 408 ms before. That is one string index,
which is exactly what F-6 prices `s[i]` at. A process-killing bug for
one index is not a trade worth thinking about.

**How it was found, and why it was not found earlier.** Every existing
gate checked that illegal accesses *raise* and that legal ones return the
right *length*. None compared the resulting **bytes** against what plain
Ring would have produced. The differential gate keeps an `RppBuffer` and
an ordinary Ring string side by side, applies the same operation to both,
and compares the whole buffer after every one. It needed a `"NULL"`
payload at offset 0, then a zero at offset 4, then a `Grow` — a
combination the fuzz reached by luck after ~13,000 operations. Luck is
not a regression test, so the shape is now a named case that runs before
any random one.

### F-47. Ring locals are born by assignment and die by typo — R24's semantics, verified, and the two false-positive classes the rule ate before shipping

Measured 2026-08-28 on Ring 1.27:

```
  ? x            never assigned                    R24, ships in dead code
  x += 1         compound assignment               R24 — the += READS first
  aL[1] = 5      subscript store, aL unassigned    R24 — the BASE is a read
  x++                                              R21, not R24
  v = myFn       a function name as a value        R24 — functions are not values
  g = 7 in MAIN SCOPE, read inside a func          fine — main scope is global
  g assigned in a LOADED file's main scope         fine — globals cross files
  read in a function, assigned LATER in it         R24 when the read runs first
```

The last two lines shape the rule (`rpp/uninitialized-variable`, `warn`).
Cross-file globals mean absence must be proven across the **whole checked
set's** main scopes, under the same universe gates as R3 (F-46). And
read-before-later-assign, though genuinely R24, is deliberately **not**
reported: the rule fires only when *no assignment to the name exists
anywhere in the function*, because branch-order guessing is where the
false positives live.

**Two false-positive classes were found by sweeping and killed before the
rule shipped — both are documented grammar/scope facts now:**

1. **The vendored grammar does not reliably nest post-class functions.**
   `rpp/idioms.ring`'s `func Applied` — a method by Ring's F-21 rule —
   sits at ROOT level in the tree, so the in-class flag missed it and the
   rule flagged its attribute reads. The fix is positional, exactly as
   `collectTopSigs` already does it: only functions whose row precedes
   the file's first `class` are checked. Two false positives in this
   project's own library, gone by construction.

2. **`new X { ... }` brace bodies are object scope.** Ring's shipped
   `arrayvector2.ring` writes `Sum Vectors` inside `new Vectors { ... }`,
   and `Sum` resolves against the object at runtime. One false positive
   in Ring's own samples, gone by construction — only the constructor
   *arguments* of a `new` expression are caller-scope reads.

After both fixes: **zero findings across six corpora** (four Ring sample
trees, this repository, and the probe suite), with the seeded typo still
caught. The fifteen variables `ring.exe` predefines (`vmvars.c`: `this`,
`true`, `false`, `nl`, `null`, `sysargv`, `stdin/stdout/stderr`, `tab`,
`cr`, `ccatcherror`, …) are suppressed by name.

### F-46. Only functions are bare-callable in Ring — five resolution facts, verified, and what it took to turn them into a zero-false-positive R3 rule

Measured 2026-08-28 on Ring 1.27, before any rule was written:

```
  noSuchFn() in an untaken branch      ships silently; R3 only when reached
  f = func {...}  then  f()            R3 — a variable is not callable;
                                       Ring wants `call f()`
  p = Point()  with class Point        R3 — a class name is not callable;
                                       Ring wants `new Point`
  helper() where func helper sits
  AFTER a class definition             R3 — F-21 quietly made it a method
  o { hello() }                        RESOLVES — a bare call inside a
                                       brace block reaches the OBJECT's
                                       methods at runtime
```

So Ring's bare-call namespace is exactly: top-level functions reachable in
the running program, plus the 258 builtins `ring.exe` registers
(`vendor`-independent; extracted from `RING_API_REGISTER` and snapshotted
in `src/builtins.zig`). Everything else raises R3 — including four shapes
that *look* callable.

**The rule, and the three humilities that made it honest.** The first
sweep of `rpp/undefined-function` produced **4,429 false positives in
Softanza alone**. The mechanism is worth naming because it is a general
truth about Ring libraries: *a library file's calls resolve at runtime
through whoever loads it, not through its own `load` lines.*
`stzString.ring` calls `StzRaise()` 421 times and never loads its
definition — the aggregator does. Per-closure absence proves nothing. The
shipped rule therefore speaks only when:

1. **the whole checked set parsed** — one unparsed file hides an unknown
   number of definitions, so any hole silences the rule everywhere;
2. **every `load` in the file's closure resolved and nothing in reach
   calls `loadlib`/`loadlibfile`/`eval`** — each can create callables the
   static view cannot see;
3. **the name is absent from every definition of any form in the entire
   set** — functions, methods, classes, load-reachable or not.

After the three gates: **zero findings across stzlib (6,020 files), Ring's
samples (1,605) and this repository** — each silenced by its own unparsed
files, which is the honesty gate doing its job — and on clean trees the
rule runs and catches seeded one-letter typos that F-18's case-insensitive
identifiers make invisible to review.

**The coverage deliberately given up, priced:** F-21 victims (a function
that became a method) go unreported, because their names exist as methods
and the suppression set is generous on purpose. One eval() in a closure
silences that closure. This is the standing trade: the front page says
0 false positives, and this rule keeps it true by saying nothing wherever
it cannot prove everything.

### F-45. Ring validates `exit` and `loop` placement only at runtime — so R9/R22/R10 ship silently in dead code, and `exit` never crosses a call

Measured 2026-08-28 on Ring 1.27, four behaviours pinned before any rule
was written:

```
  exit  in an untaken branch, no loop      runs clean; R9 only when reached
  loop  in an untaken branch, no loop      runs clean; R22 only when reached
  exit 9  one loop deep, untaken           runs clean; R10 only when reached
  exit 2  two loops deep                   LEGAL — depth must be counted
  class A from A                           caught at COMPILE time (C24) —
                                           Ring already owns this one; no
                                           checker rule needed
```

**And the boundary question that decides whether a rule is even sound:**
`exit` inside a function whose *caller* is looping still raises R9 — the
loop context is the executing function's own, not the dynamic caller's.
That makes the check purely lexical, which makes it the rare rule that can
promise **zero false positives**: a flagged statement raises in every
execution that reaches it.

Two rules shipped from this: `rpp/exit-outside-loop` (R9/R22) and
`rpp/exit-bad-depth` (literal N outside 1..depth, R10/R23), the depth
counted up to the enclosing function/anonymous-function/class boundary.

**First corpus run: one real bug, zero noise.** Across 7,625 files of
stzlib and Ring's own samples, one hit —
`samples/Algorithms/breath_first_search.ring`, `exit(1)` on queue
underflow. The C habit: the author meant "terminate the program"
(`shutdown(1)` in Ring). The one branch written to handle failure is the
one that will crash with the wrong error when failure finally happens —
and it is exactly the branch no test ever takes, which is why it shipped.

The general point is the template for a whole family: Ring's R-catalog
(`vm.h:573` — 55 numbered runtime errors) is a checklist of everything the
VM can refuse at runtime, and each entry can be asked one question: *is
there a syntactic shape that guarantees this error?* Where yes, a
zero-false-positive compile-time rule exists that Ring itself does not
perform. See docs/CHECKER-FRONTIER.md for the full triage.

### F-44. In Ring, a local assignment costs about as much as a builtin call — so "fewer function calls" is not an optimisation on its own

Measured 2026-08-28 on Ring 1.27, 5,000,000 iterations, minimum of 3,
reproduced twice within ±1 ns (`bench/11_unit_costs.ring`). Costs are per
iteration, with the 16 ns empty loop subtracted:

```
  y = 1                 20 ns    assignment
  y++                   17 ns    increment
  if k - j = 5          32 ns    arithmetic in a test
  if aX[3] = 5          36 ns    list read in a test
  if fabs(-5) = 5       53 ns    builtin call in a test
  y = aX[3]             41 ns    list read INTO a local
```

**A `fabs()` call is ~21 ns more than the equivalent arithmetic — and an
assignment is 20 ns.** They are the same price. That inverts the reflex
carried in from C: hoisting a repeated call into a local is not free, it
is a trade at par, and it *loses* whenever the call was already cheap or
short-circuited away.

**Found by being wrong three times.** While optimising a backtracking
N-Queens solver whose inner test ran 9,015,683 times with two `fabs()`
calls per pass, three textbook rewrites were tried: replace both calls
with comparisons, hoist the repeated list read into a local, and carry the
loop-invariant difference in a counter. **Each one made the program
slower.** The only change that helped removed a call and put *nothing* in
its place — `fabs(j-k)` became `k-j`, because the loop header already
guaranteed the sign. Every other change paid an assignment to save
something that cost the same or less.

**The rule this yields.** In a Ring hot loop, delete work — do not
relocate it. A call whose result is used once, over an argument that is
already a plain expression, is not worth a variable.

**And why the checker has no rule for it.** "Hoist this out of the loop"
is wrong about as often as it is right in Ring, and a rule that is wrong
half the time is worse than none. This stays a finding.

### F-43. for-in costs ~2× an indexed loop — and its loop variable writes through

Measured 2026-08-27 on Ring 1.27, 200,000 elements, same body either side:

```
                      for-in     indexed
  list read            24 ms      12 ms
  list write           22 ms      10 ms
  string read          28 ms      15 ms
```

A steady ~2× across reads and writes, lists and strings. Mansour had
noticed this by feel before it was measured; now it has a number and a
scope: 2× of nanoseconds is nothing, so this matters only in hot loops —
which is why the checker carries it as **advice** (`rpp/advise-forin`,
shown by `check --advise`) rather than as a default diagnostic.

The semantic half matters more than the speed: **for-in's variable is a
live reference.** `for x in aL x = 7` rewrites every element of the list —
verified by reading the list back (`aL[1]=7`, `aL[n]=7`). Converting a
writing for-in to an indexed loop therefore moves the assignment to
`aL[i] = ...`; a mechanical rewrite that keeps `x = ...` silently stops
writing to the list.

### F-42. Ring list indexing costs O(distance from the last access) — so binary search over a Ring list is O(n) per query, and F-39's last outlier has its mechanism

Measured 2026-08-27 on Ring 1.27, both architectures. This closes the
question F-39 left open with, by then, four dead hypotheses (dispatch,
scope size, allocator, header copies).

**The scaling test.** 100,000 list reads, same body; only the list size and
the access pattern change:

```
                 fixed middle index    binary-search-shaped jumps
     100 items         6 ms                    22 ms
   1 000 items         6 ms                    29 ms
   8 000 items         6 ms                    87 ms
  64 000 items         7 ms                   798 ms      <- scales with n
```

A *fixed* index is flat at any size: Ring keeps a cursor at the last
accessed position. A *jumping* access walks the links from that cursor, so
its cost is the distance jumped — and binary search's first probe jumps
half the list. `BinSearchAll` on 8,000 items was therefore running
O(n)-per-query while reading as O(log n): ~6.4 µs per inner iteration on
the phone, of which the arithmetic accounted for ~1.5 µs and the walk the
rest. This is the same VM fact behind `ringvm_genarray`'s 95× on permuted
reads (F-9) — seen now from the algorithm's side.

**The idiom answers it.** `RppIndexed` (genarray underneath) restores O(1)
access. Same searches, hits asserted equal, minima of three:

```
                     plain list    RppIndexed
  desktop              178 ms         22 ms      8.1x
  Infinix (arm64)      657 ms        131 ms      5.0x
```

Against Lua on the device, binary search moves from **105× behind to 21×**
— no longer a mystery, and the residue is ordinary per-iteration
interpreter cost on a loop whose every pass calls `floor()` and compares
twice. With this, every anomaly the cross-VM campaign surfaced is either
fixed or mechanistically explained: byte scan (F-40 × F-41), binary search
(this finding). The suite carries the pair as `binsearch` /
`binsearch-rpp` so a regression in either direction fails loudly.

**The rule of thumb it yields.** Sequential loops over Ring lists are fine
— the cursor moves one step. Any algorithm whose *access pattern jumps* —
binary search, heaps, hash-style probing — is running on the wrong data
representation unless the list is behind `RppIndexed` (and stays unmutated
while it is, F-10).

### F-41. `for i = 1 to len(s)` is O(n²): the loop header is re-evaluated every iteration, and each evaluation copies the whole string into len()

Measured 2026-08-27 on Ring 1.27, both architectures. Found by asking why a
byte scan was still 87% `memcpy` *after* F-40 removed the allocator tax —
the loop body copies nothing, so the copies had to be coming from somewhere
nobody reads twice: the header.

**The scaling test that proves it.** Same body, 20,000 iterations, only the
string size changes:

```
                       10 KB      1 MB       growth for 100x size
  bound hoisted         1 ms       4 ms       ~flat
  for i = 1 to len(s)   2 ms     701 ms       350x     <- O(n^2)
  while i <= len(s)     ~          5 194 ms   worse still (~260 us/pass)
```

Ring re-evaluates the `to` bound and the `while` condition on **every**
pass, and a string argument is copied onto the VM stack before `len()` sees
it — F-1's asymmetry, hidden in the header. Three neighbouring shapes are
fine and were checked, not assumed: `for c in s` walks without copying,
`for i = 1 to len(aList)` is cheap because lists pass by reference, and
`s[i]` itself is O(1) in every context tested (assignment, call argument,
arithmetic — flat from 10 KB to 1 MB).

**What it had been costing this project.** The benchmark suite's own
`ByteScan` used the trap, so the "byte access" row was measuring header
copies: 80,000 iterations × one 80 KB copy each = 6.4 GB of `memcpy`
presented as slow indexing. Hoisting one variable — same arithmetic, CHECK
values byte-identical — moved byte scan **123 → 13 ms on the desktop** and
**518 → 77 ms on the phone**. Combined with F-40, the phone's byte scan went
3 653 → 77 ms in two findings: **47×, without touching Ring**. The suite's
`StrSum` checksum had been silently moving ~40 GB per run the same way.
And the Lua comparison was structurally unfair on this row: Lua's numeric
`for` evaluates its bound **once** by language rule, so Ring was paying
80,000 string copies in a loop Lua enters with none. Post-fix, Ring's byte
scan sits 6.4× behind Lua — inside the normal interpreter band — and the
311× "outlier" of F-39 is fully decomposed: allocator (7.1×, F-40) ×
header trap (6.7×, this finding).

**The checker now catches it.** `rpp/len-in-loop-header` fires on `len()`
in a `for`-BOUND or a `while`/`do..again` condition — `.perf`, because for a
list the hoist merely deletes a needless call, so the advice is never wrong.
`ringpp why rpp/len-in-loop-header` explains it. The library's one
occurrence (`IsPlainName`, harmless on short identifiers) is hoisted anyway,
so nobody copies the trap out of Ring++ itself.

**Two corrections to this entry, both 2026-08-28.**

*The rule was too broad.* It first fired on `len()` anywhere in a `for`
header, including the START: `for i = len(s) to 1 step -1`. Ring evaluates
the start ONCE — measured at **1 ms** against **4,725 ms** for the
ascending `for i = 1 to len(s)` over the same 1 MB string. That was a false
positive, and it was 12 of the 30 hits (40%) in Softanza's string library.
The rule now compares byte offsets against the `to` token and fires only
past it. Found by reading the sites before telling their author to change
them.

*The corpus number was wrong.* This entry first said "149 hits across
Softanza". That count came from a run piped into `grep`, taken before the
broken-pipe defect was fixed — the process aborted partway and the count
was of a truncated report. Re-measured to a file, with the narrowed rule:
**675 across 6,020 files**, 633 of them outside archived copies. A number
read through a crashing pipe is not a measurement.

**What stays open.** The binary-search outlier (F-39) is *not* this: its
loop bounds are numbers. Four dead hypotheses now — dispatch, scope size,
allocator, header copies.

### F-40. The 22–29× mobile string tax was musl's allocator, not ARM — profiled to `mmap`/`munmap` under `malloc`, fixed by linking mimalloc, string workloads 3.6–7.7× faster with zero Ring changes

Measured 2026-08-27 on the same Infinix X6817. This finding overturns the
*explanation* in F-38 while keeping its measurements: the numbers were
right, the word "phone" in them was wrong.

**The suspicion.** F-38/F-39 left ~5 µs per binary-search iteration and a
311× byte-scan gap to Lua unexplained. Two candidate causes were tested
first and killed:

- **Dispatch.** Ring ships a computed-goto interpreter loop behind
  `RING_VM_COMPUTEDGOTO` (`vm.c:688`, `build/vmcgoto/`) that our stubs were
  not enabling. Enabled — Mahmoud's own door, opened with a `-D` and one
  extra translation unit, no source touched — it is worth a real but small
  **5–8%**. Dispatch is not where interpreters' reputations die.
- **Scope size.** Already refuted in F-39: 24 locals cost the same as 4.

**The profile.** `simpleperf` ships on the device (`/system/bin/simpleperf`,
API 31). Recording the byte-scan workload under the shipped stub:

```
  20.97%  [kernel]            60%+ of ALL cycles in kernel symbols
  20.45%  memcpy
   0.44%  ring_vm_execute     <-- the interpreter, nearly idle
   0.25%  __libc_malloc_impl
   0.21%  __mmap
   0.16%  __munmap
```

An interpreter running a string loop was spending less than half a percent
of the machine interpreting. `__mmap` and `__munmap` directly under musl's
`__libc_malloc_impl` is the mechanism: **musl's allocator (mallocng) serves
large allocations with a fresh `mmap` and returns them with `munmap`** —
chosen upstream for hardening, not speed, and it has no
`MALLOC_MMAP_THRESHOLD_` style knob to move. Every large-string copy Ring
makes (F-1: strings copy at every call boundary) therefore became two
syscalls plus a page-fault storm as `memcpy` walked freshly mapped, cold,
zero-on-demand pages. The desktop never pays this — MSVC's CRT recycles
those blocks in user space — which is why the same workloads sat at 4–8×
there and 22–29× on the phone. The tax was never ARM's.

**The fix.** Link mimalloc (v2.1.7, vendored with provenance in
`vendor/mimalloc/`, MIT) into the two musl stubs via `-DMI_MALLOC_OVERRIDE`
and its single-file `src/static.c`. Not one line of Ring source changes;
the user still receives one static binary. Cost: the stub grows 3.0 → 3.9 MB.

**Same device, same file, before → after:**

```
  byte scan            3 653 ms  ->    515 ms    7.1x
  substr(s,i,1) loop   2 945 ms  ->    383 ms    7.7x
  slice reads, raw     2 506 ms  ->    520 ms    4.8x
  patch buffer, raw    2 246 ms  ->    626 ms    3.6x
  sieve/matmul/fib     ~unchanged            (allocator was never their cost)
```

Total cycles for the profiled workload fell **5.7×** (322 → 56 G), kernel
time vanished from the profile, and what remains is 87% `memcpy` — the
actual copies, i.e. exactly the cost `RING_VM_STACK_PUSHCVAR` predicts and
exactly what the Ring++ library exists to avoid. Every CHECK value stayed
byte-identical through all of it, on both architectures, which is what made
the swap safe to ship the same day.

**The phone table is now uniform** — 2.0–7.4× across all fourteen rows, no
string outlier (the full table lives in `docs/ANDROID.md` §4). Against Lua
on the device, byte scan went from 311× behind to ~43× behind; the residue
is Ring's copy semantics and per-op interpreter work, not the platform.
Windows was checked for the same disease and does not have it: the win64
stub tracks the official MSVC build within 10–60% on compute and shows no
allocator pathology.

**The general lesson.** When an interpreter benchmark looks impossible,
profile before theorising — the interpreter was 0.44% of the problem. And a
"portability" choice (static musl) silently carries an allocator policy
with it; the carrier of the platform win (F-36) was also the carrier of the
platform tax.

### F-38. A phone is 4–8× slower than the desktop on compute and 22–29× slower on string copying — so Ring++'s wins roughly quadruple on mobile

> **Superseded in part by F-40 (2026-08-27):** the 22–29× string rows were
> musl's allocator, not the phone. With mimalloc in the stub the string tax
> falls to 4.0–6.3× — in line with compute — and the "wins quadruple on
> mobile" claim shrinks back to roughly desktop ratios. The measurements
> below were correct; the attribution to mobile hardware was not.

Measured 2026-08-26. Infinix X6817, `arm64-v8a`, Android 12 (API 31), against
this machine's x64 Windows build. Same source file both sides, minimum of
three runs. Reproduce with `tests\android_campaign.ps1`.

```
                            x64        arm64     phone is
  sieve of primes            84 ms      651 ms     7.8x slower
  matrix multiply            64 ms      460 ms     7.2x
  recursive fib              22 ms      176 ms     8.0x
  mergesort                 111 ms      562 ms     5.1x
  binary search             174 ms      655 ms     3.8x
  ------------------------------------------------------------
  byte scan over a string   128 ms    3 519 ms    27.5x slower
  patch a buffer, raw Ring  103 ms    2 256 ms    21.9x
  read slices, raw Ring     109 ms    2 902 ms    26.6x
  substr(s,i,1) in a loop    94 ms    2 705 ms    28.8x
```

**The two groups are not the same workload wearing different names.** The
first five are arithmetic, control flow and list indexing. The last four all
copy strings. The phone's CPU is a handful of times behind the desktop's; its
memory subsystem is four times further behind than that.

This project exists because of one fact — a Ring string is copied every time
it crosses a call boundary (`RING_VM_STACK_PUSHCVAR`) — and that turns out to
be exactly the axis a phone is worst on. The library's measured wins grow
accordingly:

```
                                     desktop     phone
  buffer patching -> RppBuffer         12.9x       49x
  slice reads     -> Peek              15.6x       66x
  substr(s,i,1)   -> s[i]              15.7x       61x
```

**And one goes the other way, which is why the rest are believable.**
`RppIndexed` is *worse* on the phone: 8.8× on the desktop, **2.8×** on ARM.
Raw list indexing is only 2.0× slower there — it is cache-friendly and copies
nothing — while the idiom's own overhead still pays the phone's general ~6×
tax. The technique that avoids **copying** wins bigger on mobile; the
technique that avoids **pointer chasing** wins smaller. A rule derived from
desktop numbers alone would have got this one backwards.

### F-39. Ring, Lua and Android's ART agree on every answer — and Ring is 9–16× behind Lua, with two outliers nobody has explained

> **Partially resolved by F-40 (2026-08-27):** the byte-scan outlier was
> mostly musl's allocator — 311× behind Lua collapsed to ~43× with mimalloc
> in the stub. The binary-search outlier survives the allocator fix almost
> untouched (~654 ms) and remains measured-but-unexplained.

Measured 2026-08-26 on the same phone, in the same session, six identical
algorithms, minimum of three runs.

```
                    Ring 1.27      Lua 5.4    ART (dalvikvm)
  sieve              636.92 ms     71.08 ms      2.48 ms
  matmul             463.93        28.37         1.86
  fib                182.68        13.38         1.39
  mergesort          572.19        49.54         5.19
  binary search      662.96         6.22         0.60
  byte scan        3 740.14        12.03         0.76
```

**All three produce identical results for all six**, and that is asserted by
the campaign rather than assumed — a neighbour that computes something else
makes its timings meaningless.

**The two columns answer different questions.** ART is an optimising compiler
with a JIT; beating a plain interpreter by 110–250× on compute is the
expected outcome, not a discovery. It is in the table because it is what the
device already runs, so it marks the ceiling of that hardware. **Lua is the
fair peer** — small, dynamically typed, register-based bytecode, no JIT,
1-indexed, embedded rather than hosted, same size class. Against Lua, Ring is
**9–16× behind on ordinary compute**. That is the honest number for "how does
Ring compare to other small languages", and it is a gap in interpreter
engineering rather than in language design.

**Two entries are far outside that band, and this file does not claim to know
why.**

- **byte scan: 311× behind Lua.** Ring's `s[i]` costs disproportionately more
  than Lua's `string.byte`, and the gap widens on ARM specifically (F-38).
- **binary search: 107× behind Lua.** The inner loop's parts were isolated on
  the device — an empty loop is 0.26 µs per iteration, `floor()` adds
  ~0.16 µs, one list index adds ~0.14 µs — which accounts for roughly 1.5 µs
  of a measured **6.41 µs** per iteration (77,347 iterations, 495.81 ms).
  **The remaining ~5 µs is unaccounted for.**

One hypothesis was formed and **refuted**: that Ring resolves variables by
name and pays for the number of them in scope. A function with 24 locals ran
the identical loop no slower than one with 4 (ratio 0.72, i.e. slightly
faster — noise). So it is not scope-lookup cost, and the guess is recorded
here as dead rather than left lying around to be rediscovered.

These stay as measurements without a mechanism. Publishing a plausible cause
that has not been demonstrated is how a wrong number gets quoted back for
years — and this file has already had to correct two conclusions (F-35, F-36)
that were reached exactly that way.

### F-37. `ring file.ring -go` compiles the program **and then runs it** — `ringpp build` was executing everything it packaged

Measured 2026-08-26 on Ring 1.27.

```
$ cat x.ring
write("MARKER.txt","ran")
? "side effect"

$ ring x.ring -go
side effect                 <-- it ran
$ ls
MARKER.txt  x.ring  x.ringo  <-- and its side effects landed

$ ring x.ring -go -norun
$ ls
x.ring  x.ringo              <-- compiled only
```

The two `.ringo` files are **byte-identical** (`cmp`, no differences), so
`-norun` costs nothing except the execution. Ring documents the flag in
its own usage banner — *"Don't run the program after compiling"* — and
`-go` simply does not imply it.

**Why this mattered here.** `ringpp build` shells out to Ring for
bytecode (`pack.zig`), and did so without `-norun` from the day phase B3
shipped. Every build therefore *ran the program it was packaging*: its
output went into the build log looking like build noise, and its side
effects — files written, directories created, and in principle anything
else a program does — happened for real, on the build machine, at build
time. A build tool that executes its input is not a build tool.

**How it was found.** Building the Android demo through the new
`--target android` path left a stray `report.txt` in the repository root.
The demo program writes `report.txt`; nothing in the build was supposed
to run it. The earlier hand-written Python script had *hidden* this by
running Ring with `cwd` set to `android/`, where the stray file landed
next to the demo and got silently added to `.gitignore` as though it were
a build artefact. It was not a build artefact. It was evidence.

**The general lesson.** A file appearing where no step claims to write
one is a finding, not litter. The `.gitignore` line that made it stop
being visible was written by an earlier session in this same repository —
which is how a symptom survives for as long as ignoring it is cheaper
than explaining it.

Fixed in `pack.zig`: the argv is now `{ring, entry, "-go", "-norun"}`.

### F-36. A Ring program runs on Android with no NDK, no Qt and no toolchain — because Ring's VM has no JIT

Measured 2026-08-26 on an Android 36 emulator (`x86_64`, ABI list
`x86_64,arm64-v8a`), hours after this same file concluded the opposite.

**The wrong conclusion, and how it was reached.** Earlier the same day,
three `zig cc` runs established that Ring's VM cannot be compiled for the
`aarch64-linux-android` triple — Zig does not bundle bionic — nor for
`aarch64-ios`. True, both, and still verifiable. The conclusion drawn from
them was that mobile needs the Android NDK. **That was an overreach in
exactly the shape of F-35: the measurement was sound and the sentence was
bigger than it.** Nobody had asked whether targeting Android's own libc is
*necessary*.

It is not. A **static musl** binary — the `linux-x64` and `linux-arm64`
runtime stubs this project already ships — runs on Android as it stands:

| what was run | result |
|---|---|
| `runtime/linux-x64/ring` + a `.ringo` | **ran**, exit 0 |
| a full `ringpp build` package, unmodified | **ran**, exit 0 |
| the same package renamed `libring.so` | **ran**, exit 0 |
| `runtime/linux-arm64/ring` + the same `.ringo` | **ran**, exit 0 (via `arm64-v8a`) |

The program was not a hello. It built lists, concatenated strings, **wrote
and read a file**, and used a class with methods. Output byte-correct in
every case.

**Why it works here and failed elsewhere, which is the transferable part.**
A sibling project measured (2026-08-20, real device) that a *musl* Node
binary on Android starts and is then **killed by the seccomp filter** when
V8 initialises — `SIGSYS`, exit 159, no diagnostic. The natural reading is
"musl does not work on Android". The precise reading is narrower:
**Android's seccomp filter objects to what a JIT does** — mapping memory
writable-then-executable — not to musl.

Ring's VM is a plain bytecode interpreter. It has no JIT, so it never makes
the call that gets the process killed. The property that makes Ring "slow"
in the benchmark sense is the same property that lets it run untouched on a
locked-down platform.

**What this does and does not establish.** It establishes that the packaging
mechanism reaches Android with nothing added — no NDK, no Qt, no Qt Creator,
no Gradle, and no change to the artefact. `libring.so` running proves the
naming rule an APK requires (Android extracts and marks executable only
`lib*.so`). It does **not** establish a shipped `.apk`: that still needs
`aapt2` + `javac` + `d8` + `apksigner`, all present in a standard Android
SDK and none requiring the NDK. And arm64 was verified under the emulator's
`arm64-v8a` translation, not on physical ARM hardware — real-device
confirmation is still owed before this is claimed anywhere public as
"works on your phone".

### F-35. Ring auto-runs `ring.ringo` from the working directory — before reading a single argument

Prompted 2026-08-26 by the author of Ring, who read the announcement and
pointed at the manual-distribution chapter of his own documentation.
Ring++ had published, in five places, *"Ring's binary does not auto-load
a same-named `.ringo` — measured directly."* The measurement was right;
the sentence was bigger than the measurement.

`ring_state_main` (`state.c:476`), before any argument is parsed:

```c
/* Check Startup files (ring.ring and ring.ringo) */
if (ring_general_fexists(RING_FILES_AUTOLOADSRC)) { ... }       /* "ring.ring"  */
else if (ring_general_fexists(RING_FILES_AUTOLOADOBJ)) { ... }  /* "ring.ringo" */
```

Measured on 1.27, four ways:

| shape | result |
|---|---|
| `ring.exe` copied to `myapp.exe`, beside `myapp.ringo`, no args | usage screen — a **same-named** file is genuinely not found |
| the same, bytecode renamed to `ring.ringo` | **runs it**, no arguments |
| invoked from a *different* directory | usage screen — the check is on the CWD, not the exe's folder |
| a `ringpp build` pair, bytecode copied to `ring.ringo`, `hello.exe` run bare | **runs it** — the stub is Ring's own entry point and inherits the behaviour |

Three consequences.

**One, the product could drop its argument.** `run with: hello.exe
hello.ringo` could become a double-click by naming the bytecode
`ring.ringo`. Not adopted yet — it costs the matched-pair naming, a gate,
and a binaries rebuild. Recorded as an option, not a promise.

**Two, a trap, found the hard way while measuring this.** Because the
check runs *before* argument parsing, a stray `ring.ringo` in the working
directory hijacks **every** invocation: `ring myfile.ring -go` with one
nearby runs the stray file and silently ignores everything typed.
Google-Group material, for Mansour to relay if he chooses.

**Three, a correction debt, paid.** CLI.md, DESIGN_BUILD.md §2,
PHASE_PLAN.md B3, `pack.zig`'s header and the "two files" post all said
or implied *"needs an explicit filename argument"* — each now carries a
dated correction. One detail kept for honesty: the author's note said the
*renamed exe's* name drives the lookup (`myapp.exe` → `myapp.ringo`);
1.27's source and the measurement say the name is the fixed literal
`ring.ringo`. Both parties were corrected by the measurement, which is
the house outcome.

Also recorded, unexplained rather than explained away: during one failed
build attempt in the scratch experiment, a `ring.ringo` appeared 46 ms
after the source file was written, through no path that could be
reproduced — clean replays of both the failing and the succeeding
pipelines produce only the correct `hello.ringo`.

### F-34. `ringpp check` reported a clean verdict on a file that does not exist

Found 2026-08-26 by pointing the CLI campaign at its own argument surface.

```
$ ringpp check typo.ring          # no such file
  0 error, 0 warn, 0 perf, 0 note   in 1 files (0.0 KB, 0 ms)
$ echo $?
0
```

**"in 1 files", about a file that is not there.** `collectFiles`
(`main.zig`) tried `openDir`, and on failure appended the path unseen if it
merely *ended in* `.ring`. The read then failed and was skipped by a bare
`catch continue`, while the path stayed in the count. Three separate shapes
produced the same false clean: an absent file, an absent directory, and a
target holding no `.ring` file at all.

This is the defect `deps.zig` already carries a comment about — *"the exact
failure that made `tests/fidelity.ps1` report a clean corpus for a year: an
answer that looks like a verdict and is actually a measure of what the tool
could not see."* `deps` was taught to say `NO VERDICT`. `check`, which is the
command people actually run, never was.

**Two more from the same pass.** `check` accepted and silently ignored any
argument it did not understand, so `ringpp check src/ --fix` reported a clean
run having done nothing of the kind. And a file carrying `rpp/unparsed` — a
rule whose text is literally *"no rules were applied to this file"* — was
still counted in the `in N files` headline, so twelve unparsed files read as
twelve files checked.

**Fixed:** absent paths and unreadable files are collected and named under a
`NO VERDICT` block with a non-zero exit; unknown options and extra arguments
are refused; the summary now states how many files no rule ran on. Twenty-one
adversarial cases are gated in `tests/cli_campaign.ps1`, verified non-vacuous
— reverting the repair fails six of them.

**What did not go wrong,** stated because the campaign looked for it: nothing
crashed. A 200 KB single line, 400-deep nesting, a NUL byte mid-string, a BOM,
CRLF, raw binary, circular `load`s, and an unterminated string all produced a
verdict rather than a crash, and two runs over the same tree are byte-identical.

### F-33. `ring_state_setvar` **assigns**; it cannot create, and neither can `ring_state_newvar`

Measured 2026-08-25 while extending the differential gate to `RppSandbox`:

| call | result |
|---|---|
| `ring_state_setvar(st, "cNew", "hello")` — name never seen | **`Error (R6) : Variable is required`** |
| the same after `ring_state_runcode(st, "cNew = ''")` | works |
| `ring_state_newvar(st, "cFresh")` | **the same R6** |

So the sub-state API can *assign to* a variable and cannot *introduce* one,
and the failure arrives as Ring's own R6 raised from inside the C function —
naming neither the variable nor the reason, from a place the caller cannot
see.

That collided with what `RppSandbox.SetVar` is **for**: the documented use is
"set a variable before running code that reads it", where absence is the
normal case, not an error. `SetVar` now declares the name first and then
assigns. Only the **name** travels through `runcode`, never the value, and
only after it is checked to be a plain identifier — so a crafted name cannot
smuggle in a statement, and a value never has to be escaped or quoted.

The reference page had promised this behaviour before the code could do it.
Nothing had caught that because no gate had ever called `SetVar`.

### F-32. Ring's `and` / `or` **do** short-circuit — and that protects an index

Not documented anywhere this project could find, and load-bearing for
F-31's fix:

```ring
nCalls = 0
if FALSE and Side() ok        # Side called 0 times
if TRUE  or Side() ok         # Side called 0 times

c = "abc"
if len(c) >= 5 and c[5] = "x" ok    # no error: c[5] is never evaluated
```

So a guard may test a length and then index past it in the same
expression, which is what lets F-31's replacement be one expression
rather than a flag assigned across nested `if`s. The flag version was
measured at **0.32 µs per call slower** — the extra local assignment and
branch cost four times what the extra index does.

---

## Part 5 — Safety, measured

Four programs, four separate processes
([`bench/safety/`](../bench/safety)):

| what | result |
|---|---|
| `ptr2str(p, 0, 4096)` on a 16-byte buffer | **returns 4096 bytes** of adjacent heap as a Ring string. No error. Exit 0. |
| `memcpy(p, space(4096), 4096)` into 16 bytes | **process dies.** Exit 1, no message, no line number, no Ring traceback. |
| read through a pointer to a local that went out of scope | **returns garbage** silently. Exit 0. |
| `setptr(q, 4096)` then `ptr2str(q, 0, 8)` | **process dies.** `try/catch` does **not** catch it. |

So the failure modes are: *silent wrong answer*, *silent information
disclosure*, and *instant death with no diagnostic*. Ring's `try/catch`
is useless here — it traps VM errors, not signals.

This settles the safety design: bounds checking must happen **in Ring,
before the primitive is called**, because after the call there is nothing
left to check. The cost is affordable — a few comparisons against a
stored length, on the order of the 97 ns the `memcpy` itself costs — and
Ring++ pays it everywhere except on explicitly named `…Unchecked` entry
points.

---

## Part 6 — Two things in the brief that did not survive contact

- **`vmmem.c` does not exist** in Ring 1.27. Memory lives in `vmgc.c`
  (allocators, pool manager, reference counting) and `vmstate.c`. The
  file list in the kickoff note is from an older tree.
- **`bytes2float` is registered** (`file_e.c:35`); it is missing from the
  raw-material list in the brief. `sysunset`, `ref`, `refcount` are
  registered too (`os_e.c`, `list_e.c:18-20`).

---

## The five numbers to keep

1. **≈2,200×** — passing 1 MB by value versus by handle to a Ring
   function.
2. **~140×** — `ptr2str` versus `substr` for a 10-byte slice of a
   500 KB string (12.5 µs → 0.09 µs), and it grows with the string.
3. **~95×** — `ringvm_genarray` on permuted reads (93–98× across runs).
4. **10–16×** — how much *worse* `ringvm_genarray` makes a write-heavy
   loop.
5. **512 bytes** — the chunk size below which `memcpy` loses to `+=`.

Numbers 4 and 5 are the ones that make the library honest. A design that
only knows numbers 1–3 will ship a regression.

## Measurement hygiene, learned the hard way in this session

- **Report minima over repetitions**, not single runs. Single-run
  numbers in this file swung 4× (F-6) and one of them survived into a
  first draft as a 4× over-claim.
- **Quote two significant figures.** "2,367×" invites a precision the
  measurement does not have; three runs spanned 2,206–2,367.
- **Guard divisions by a measured time.** `nA/nB` crashes when `nB`
  rounds to 0 ms — which is exactly what happens when the fast path
  wins big.
- Ring's `clock()` has **1 ms resolution** here, so any measurement
  under ~20 ms per repetition is a floor, not a value. Say "below the
  timer floor" rather than "0".
