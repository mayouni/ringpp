# What the Ring VM actually does — measured

*Session of August 10–11, 2026. Every number here comes from a program in
[`bench/`](../bench) run against `D:\ring127\bin\ring.exe` (Ring 1.27.0,
Windows 11, x64). Every claim about the VM cites a line in the stock
1.27 source at `D:\ring127\language\src`, not the vendored RingScript
tree (which carries an experimental `rlist.h` patch and would have
lied to me).*

Read this before the design. The design is downstream of it, and two of
these findings killed the design I would otherwise have written.

This file records what Ring **does**. Where Ring++ deliberately does
something else, the decision — verdict, owner, date and cost — is in
[CORRECTIONS.md](CORRECTIONS.md).

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

**An inherited method shadows just as well** — measured 2026-09-05. The
class doing the shadowing need not be the class you are reading:

```ring
class stzHashList from stzList
     def InsertAfter(_n_, paPair)
          insert( This.HashList(), _n_, paPair )   # R20
```

`stzList`, the parent, defines `def Insert(pItem, pWhere)`. Nothing in
`stzHashList` names `Insert`, and nothing at the call site suggests the
three-argument builtin will not be reached.

Both of Softanza's hash-list inserts are dead this way, and **three
independent defects sit on that one line**: it was written `This.HashList`
without parentheses ([F-52](#f-52)), so it raised R12 first; with the
parentheses restored it raises R20, this finding; and were the arity right,
`HashList()` returns `This.Content()` — the attribute **by value** — so the
insert would mutate a copy and the method would silently do nothing. Each
layer hides the next, and only the first raises an error a reader trusts.

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

### F-48. `new` accepts only classes, and a missing parent is the quiet failure — R11/R15 semantics, and the fragment-file lesson that made every absence gate set-global

Measured 2026-08-28 on Ring 1.27:

```
  new Ghost  in an untaken branch      ships silently; R11 when reached
  new X  where X is a FUNCTION         R11 — functions do not satisfy new
  cN = "Real"  then  new cN            R11 on "cn" — the variable's OWN
                                       name is looked up, not its value
  class A from Missing, never used     LOADS AND RUNS, no error at all
  new A  (first instantiation)         R15 — the parent is only resolved now
  new P.X  (package-qualified)         resolves; never checked statically
  import NoSuchPackage                 R25 at runtime — same family, queued
```

The fourth line is the finding worth underlining: **a class with a missing
parent is a bomb that does not even tick.** The file loads, the program
runs, every test that never instantiates that class passes — and the first
`new` raises R15, possibly months later. `rpp/unknown-class` flags both
shapes at check time, suppressed by a **class-names-only** set: the
generous all-definitions set would silence `new X` over a function, which
is a real R11 the narrower set catches.

**The false-positive class this rule found, and what it changed for every
rule.** First sweep: 17 hits in `ring127/applications`, all Qt classes
(`QUrl`, `QByteArray`…) used in **fragment files** — `webapi.ring` never
loads `guilib.ring`; the MAIN app does, and load edges point the wrong way
for a per-closure gate to see the fragment's runtime universe. A fragment
file's world is defined by *whoever loads it*, which is exactly what a
static pass cannot know. So the loadlib/eval/unresolved-load gates moved
from per-closure to **set-global**, joining the parse gate that was
already there: one dynamic anything in the checked tree silences every
absence-based rule (R3, R24, R11/R15) for the whole tree. After the move:
zero findings across eleven corpora, seeded typos still caught.

**R25 joined the family the same day** (`rpp/unknown-package`): `import`
of a missing package ships silently in dead code, raises inside functions
when they run, and matches the FULL dotted name — `import Sys.Web` needs a
package declared exactly `Sys.Web`. First sweep: zero findings across
eight corpora, no new false-positive class — the set-global gates this
family already paid for protect it from birth.

That is now the fourth pre-ship save in four rules — R3 (4,429), the
len-header start position (40%), R24 (own library + Ring's samples), and
this — and the pattern is the point: **sweep real corpora, read every hit,
fix the mechanism, only then ship.**

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

### F-49. A keyed read inserts, and a positional write leaves Ring's key index stale — the two hash-list defects the map type was built against

Measured 2026-09-02 on Ring 1.27 (`scratchpad/hash.ring`, `scratchpad/stale.ring`):

```
  h = [ :name = "ali" ]
  v = h[:missing]                 returns "", and len 1 -> 2: the READ INSERTED
  h7 = [ 1, 2, 3 ];  w = h7["k"]  "" and len 3 -> 4: it inserts on a PLAIN list too

  h = twelve pairs k1..k12
  h[3] = [ "zz", 99 ]             positional write of a pair
  h["zz"]                         ""   -- the NEW key is invisible: the index is stale
  h["k3"]                         99   -- the OLD key answers with the NEW pair's value,
                                         unverified: the index maps k3 -> slot 3 and
                                         returns whatever slot 3 now holds
  len(h)                          13   -- and the failed read of "zz" inserted a pair
```

Two defects, one mechanism. Ring keeps a hash index beside a list used as
a hash (`HashTable`/`HashItem` in Mahmoud's own structure table — this is
why keyed lookup is flat at 0.15 µs from 10 to 5,000 entries, F-earlier).
The index is keyed by position and is **not touched by a positional
write**, so after `h[3] = [...]` the old key still points at slot 3 and
the new key points nowhere. The read of the nowhere key then **inserts**,
which is §2.2's insert-on-read: an existence test is a write, a typo grows
the data, and the second read of the same wrong key "succeeds".

**What Ring++ does instead** (charter §6.7, commit e89d14f in rnx-spike):
the hash list stays a vector of pairs — `m[i][1]` and `m[i][2]` keep
working for the 3,429 positional sites — with an open-addressing index
beside it that is **dropped by any positional write or delete** and
**re-checks the key on every hit**, so a stale slot can only miss. And a
read never writes: a missing key is `""` and the list is left alone. Both
differences are registered in `bench/ab-known.txt` as `map:M10` and
`map:M11`, not hidden.

**Measured against the charter's own gates, same probe on both sides:**

```
                                 Ring 1.27      Ring++
  build 200,000 pairs             140 ms        18 ms
  memory, build only             96.3 MB      32.7 MB    target < 20, withdraw > 40
  lookup-only loop, 1M           1.08 µs      0.32 µs    target < 0.10
```

Memory: 2.9× less than Ring, under the withdrawal line, over the target —
the claim stands as measured and the target is missed. Lookup: 3.4×
faster and the 0.10 µs target is missed; the loop still carries an indexed
read and two arithmetic operations per iteration and the pure lookup was
not isolated, so **the speed claim is dropped rather than defended**, as
the charter said it would be.

**The rule.** `rpp/keyed-read-inserts` (`note`) names every keyed read —
a subscript with a symbol or string-literal index that is not an
assignment target — because the charter makes naming the sites a
precondition of changing their meaning. It is deliberately broad: it
cannot know whether the key is present, and says so. First sweep of the
whole Softanza tree: **7,474 sites**. The charter's earlier figure of 592
counted reads of keys that *may be absent*; this counts every keyed read,
which is the honest scope for a rule that cannot see presence.

---

### F-50. Ring++ skipped the statements it could not compile — and the call still returned the right answer

Measured 2026-09-04 on Ring 1.27 and Ring++ (`rnx-spike/bench/refusal.ring`),
while looking for what to build next. It is the one place this project did
what its own discipline forbids: skipping a gate without saying so.

```
  $acc = 0                            Ring 1.27      Ring++ (before)
  $v = Total(2, 3)
  ? "returned: "   + $v               5              5        <- the SAME
  ? "arithmetic: " + ($v + 10)        15             15       <- the SAME
  ? "acc is now: " + $acc             1              0        <- the side effect, gone
                                                     TOP LEVEL RAN TO COMPLETION
  func Total(a, b)
      $acc++        <- refused by Ring++ (++ on a global)
      return a + b
```

**Nothing at the call site looked wrong.** The return value was right, and
arithmetic on it was right; only the statement Ring++ could not compile had
quietly not happened. The function was not a no-op and was not skipped as a
whole — it ran, minus the parts that failed to compile.

The information existed the whole time. `census` reported `1 refused`, and
`rnxc exec` printed a note saying the top level calls functions that did not
compile. Neither was consulted at run time. In `emitOne` a statement whose
codegen returned `Error.Unsupported` was counted, the function was marked
poisoned, and the loop ran `continue` — the statement simply left a hole.

**Why the A/B harness could not catch it.** Refused functions are
named-and-skipped by design (29 of them in `ab-known.txt`), so the one
comparison that would have shown Ring saying 1 and Ring++ saying 0 was never
made. The harness was honest about what it skipped; the binary was not. On
Softanza that is **934 refused statements out of 108,790** — 934 places where
a clean-looking run could have omitted work.

**What Ring++ does instead** (rnx-spike `2555d6a`): the refused statement
becomes a **raise where it stood**, naming the construct that was refused,
its text, its line and its file —

```
Error: Ring++ refused this statement (identifier `nBreachSeen`, line 185
of judgment_narrated.ring) and did not compile it -- running past it would
give a wrong answer
```

It named the ENCLOSING STATEMENT until 2026-09-12, which is a different
construct in a different place and twice sent a session to read the wrong
code: `while_statement, line 1108` for an eval-assigned local seventeen
lines further down, and a method in `stzPerfSentinel.ring` for a lambda in
the test file that happened to share a line number.

— so `rnxc exec`, which exists to run a program and hit the wall, now hits it
loudly and in the right place. **In place, not at the call**, deliberately:
the statements before it did run and their effects are real, and a refusal on
a branch never taken must not break a function that otherwise works. Whatever
the failed statement half-emitted is rolled back first — code and call fixups
together, since a partly-emitted `if` can leave a forward jump that is never
patched.

Nothing else moved: census identical at 107,856 compiled / 934 refused on both
builds, A/B 0 differing, contract gate 7.2 six of six pairs. The `refusal
raises` gate step keeps it out, and was checked to **fail** on the regression
shape — which is exactly what Ring 1.27 prints, since Ring runs the probe to
the end.

**The general lesson, worth more than the fix.** A tool that reports what it
cannot do at *compile* time, and then runs anyway at *run* time, is telling
the truth in one channel and not the other. The census had the number; the
binary needed to act on it.

---

### F-51. `+=` is not `+`: Ring appends a list with one and raises R21 with the other — FIXED

Measured 2026-09-04 on Ring 1.27 while giving Ring++ compound assignment
on elements (`rnx-spike/bench/cmpd.ring`):

```
  $x = [1, 2]
  $y = $x + 9          len 3   -- `+` APPENDS one item to a list (F-earlier)
  $x += 9              R21     -- `+=` REFUSES it: "operator with values of
                                  incorrect type"
  $s = "ab"
  $s += "cd"           "abcd"  -- but on a STRING `+=` concatenates, like `+`
```

So Ring's `+=` is **not** sugar for `x = x + y`. It carries the string
behaviour of `+` and drops the list behaviour. The same holds on an
element: `a[2] += 9` where `a[2]` is a list raises R21 too, so it is a
property of the operator and not of the place.

**Ring++ diverges here, in every place kind, and did so before elements
were supported at all**: it compiles every compound assignment through the
polymorphic `add`, so `+=` on a list APPENDS where Ring raises. The
divergence is therefore older than the element support that exposed it,
and it is in the dangerous direction -- Ring stops, Ring++ carries on with
a changed list. Registered in `bench/cmpd.ring` as `C8`, which cannot be
an A/B case because Ring produces no output to compare: it raises.

**Closed 2026-09-04 (`rnx-spike 186dc00`), and it needed no new opcode.**
`add` never used its `d` field and `addi` never used its `c`, so a compound
assignment marks the instruction and `addSlow` refuses a vector when the
mark is set. Plain `+` and the constant-folded `x + 5` leave the mark at
zero and keep appending.

**`++` diverged the same way and was not in this finding.** The postfix
path compiles to `addi` — four sites — and `$x++` on a list appended where
Ring raises. Found by checking the shapes *next to* the one written down,
which is the habit this file keeps earning.

**And two probes that could not be tested now are.** `cmpd:C8` sat in
`bench/` uncalled, with a comment explaining that Ring raised so there was
no output to compare. Now that both runtimes raise, `try`/`catch` makes the
raise itself the answer — both return `"raised"` — so it is an ordinary
gated case, `C9` covers `++`, and `C10` guards the append that must
survive. A divergence closes by becoming testable, not by being argued.

---

### F-52. `This.Name` is a property, never a bare call — and a mistyped `def` is silently not a method

Measured 2026-09-04 on Ring 1.27 while sampling the refusal table, after I
had proposed building "bare calls" as a feature. There is no such feature.

```ring
class K
    @v = 7
    def Val()
        return 42
    def ViaThis()
        return This.Val        # <-- Val is a METHOD
```

```
  Line 9 Error (R12) : Error in property name, property not found: val
  In method viathis()
```

`This.Name` is a **property access**. Ring does not fall back to calling a
method of that name; it raises R12. So a site like
`insert(This.HashList, n, pair)` — where `HashList` is `def HashList()` —
is a **latent bug**: the file loads, and the line raises only when it runs.
Ring++ refused these sites already; since 2026-09-04 it names them
(`This.Name is a METHOD, not a property — Ring raises R12; write
This.Name()`), which turns a refusal into a bug report. **3 sites** in
Softanza — not the 107 the `member_expression` count suggested, which was
the third time a refusal category turned out to be several unrelated
things.

**And a second, quieter one, from the same sweep.** A mistyped definition
keyword is not an error:

```ring
    ded IsNotMultipleOf2()     # `ded`, not `def`
        return This.IsOdd()
```

Ring loads the file without complaint and the method **does not exist** —
calling it raises `R14 : Calling Method without definition`. Nothing at
load time says so, so a typo in a definition keyword survives until
something calls the method. One is in Softanza today
(`stzNumber.ring`, `IsNotMultipleOf2`).

Both belong to the same family as F-50: Ring is quiet where it could speak,
and the information exists earlier than the failure does.

---

### F-53. A string refcount goes negative when a screen loop also builds an HTML tree — Ring++, FIXED

**Fixed 2026-09-04 (`rnx-spike b1c2151`), and the cause was nowhere near
where the symptom was.** Left in full because the search is the useful
part: what follows is what was written while it was open, with the answer
added at the end.

Measured 2026-09-04 (`rnx-spike/bench/webloop.ring`, which fails in
seconds): RingPad's shell loop driven by the **scripted** browser
renderer — no socket, no console — with `RppWebHtml()` called once per
screen. On the second screen:

```
thread panic: integer overflow
  main.zig:815  in release    <- o.rc -= 1 on a STRING whose rc is already 0
  main.zig:1041 in freeVec    <- releasing a vector's elements, recursing
```

A string is released more often than it was retained, and the frees
recurse through nested vectors until a count goes below zero.

**What it is not.** Each ruled out separately, each clean:

| suspected | result |
|---|---|
| the socket | the repro never opens one |
| `web_wait`'s nested list | copying the form into plain Ring strings first changes nothing |
| `RppWebEsc` / `RppWebText` / `RppWebOptions` | 200 rounds each, clean |
| `RppWebHtml` on a rebuilt tree | 200 rounds, clean |
| the shell loop *without* the HTML frame | clean — and it is what `examples/12` gates on every run |

It needs **the screen loop and the HTML frame together**, which is why the
terminal renderers never show it: they draw with `see` and build no tree of
strings. The single-screen browser example
(`examples/13-a-text-to-edit/web_live.ring`) is unaffected and runs, because
it never goes round twice.

The refcounting in the builtin itself matches `str2list` exactly — `newVec`
and `newStr` are both born at rc 0 and `vecPushB` takes the reference.

**THE ANSWER.** It was not in any renderer. `exprClass`'s identifier branch
returned `.int` for a name it could not resolve — a `$global`, or a local
not yet defined — and `.int` is the **one class that switches refcounting
off**. `Choice(cName, aItems)`, called as `Choice(:file, $files)`, took a
global argument, classified the parameter as an int, and put its register
outside the boxed mask; `move` then copied a live vector without retaining
it, and a string three frees later went to rc −1.

`Menu` — the same signature one line below `Choice` — was correct all
along, only because it happens to write `aItems[1]`, which proves the
parameter is a list. The disassembly showing the two together is where it
broke:

```
Choice ... ; r1 = aItems (int)      <- a list at run time
Menu   ... ; r1 = aItems (list)
```

**How it was found, since reduction failed.** Every deletion from the
repro made it pass, which says the shape is allocation-sensitive rather
than logical — reduction was the wrong tool. Building with
`-Dtyped=false` made it pass too, which put the fault in the boxed-mask
path in a single command. A temporary check inside `setRegB`/`vecPushB`
for *an unboxed store of a heap value* then named the opcodes, and the
program counter mapped them to the functions.

**The rule worth keeping:** a default class must never be the one that
disables safety. `.int` was a reasonable guess for an unknown name and a
catastrophic one, because every other wrong guess is merely slow.

---

### F-54. `s[i]` on a string is a character on Ring and a CODE on Ring++ — and every probe hid it

Measured 2026-09-04, after it silently turned `amina` into `9710910511097`
inside `rpp/tui.ring`:

```
  s = "abc"        Ring 1.27      Ring++
  s[2]             b              98
  ascii(s[2])      98             98
```

Indexing a string yields a **one-character string** on Ring and the
**character code** on Ring++ (`dget` on a string returns the byte). Both
agree the moment `ascii()` is wrapped around it — and that is the whole
reason this survived so long unregistered. Every string-indexing probe in
`bench/` was written as `ascii(s[i])`, because that is what the kernels
needed, so the naked form was never once compared.

**The failure is silent and it is in the dangerous direction.** A loop
that builds a string character by character — the most ordinary thing in
the world — produces text on one runtime and a run of numbers on the
other, with no error on either. It cost one gate run to find and would
have cost a user an afternoon.

Registered as `bi:BI_IDX` in `ab-known.txt`, with a probe that does NOT
wrap it, so the divergence is now reported by name on every A/B run. The
portable idiom is `substr(s, i, 1)` for a character, or `ascii(s[i])` for
a code; `rpp/tui.ring` uses `substr`'s four-argument replacement form
instead of indexing at all.

**What it says about the probe suite.** A divergence is invisible to a
harness whose every probe happens to normalise it away. The suite was not
wrong — `ascii(s[i])` is what the kernels measure — but a shape used in
exactly one way is a shape tested in exactly one way, and the other way
was ordinary Ring.

**And it had already cost something before it was found.** The browser
shell's menu never worked: `RppWebColon` searched for a colon with
`if cStr[i] = ":"`, which on Ring++ compares a code against a string and
is never true, so a menu pick wrote to an empty key and every screen
reported the menu's *first* item whatever was clicked. That was written
before F-54 existed, and it was blamed on the socket, on the redirect and
on a race before the finding explained it. The terminal renderers never
call that function, which is why nothing else showed it — and the fix is
`substr(cStr, ":")`, which means the same thing on both runtimes.

### F-55. Ring has no string escapes at all, and `\"` fails without saying so

Measured 2026-09-05 on Ring 1.27. A string literal has **no escape
processing of any kind**, in any of the three delimiters:

```
  "a\nb"     len 4     a, backslash, n, b
  "a\tb"     len 4
  "a\\b"    len 4     backslashes are not collapsed either
```

The backslash is never special. What each delimiter can hold:

```
  "..."   holds ' and ` and \        cannot hold "
  '...'   holds " and `              cannot hold '
  `...`   holds " and ' and a REAL newline, and spans lines
```

So exactly two kinds of string cannot be written as a literal: one that
needs all three quote characters, and one that needs a control character
other than a newline.

**And the failure is silent in the dangerous direction.** `\"` does not
escape the quote — the quote closes the literal and the backslash stays
inside it — but it does not reliably raise either:

```
  c = "a\" + "b\"        -->  c is  a\b\
```

Two literals, `a\` and `b\`, concatenated. It parses, it runs, it
raises nothing, and it is not the string anyone wrote. The sibling shape
`? "say \"hi\""` splits one statement into three and reaches R24 on an
identifier `hi\` — loud, but only once that line runs.

Ring++ answers it in `rpp/str.ring`: `RppStr()` decodes `\\`, `\n`, `\t`,
`\r`, `\0`, `\q` `\s` `\g` (the three quote characters, named, for when
the delimiter itself cannot be typed) and `\xNN`, and **raises on an
unknown escape** rather than leaving it in the string.

**And a codepoint, which Ring cannot write at all** — `char()` is byte-wise
and wraps modulo 256 in silence, which is **F-56** and has its own entry.
`\uNNNN` takes four hex digits, `\u{N...}` one to six, to 10FFFF; a
surrogate half (D800–DFFF) is **refused**, because it is not a character and
encoding one produces UTF-8 nothing downstream can read back. Each case is
gated against the PASTED character, so the gate fails the day the encoder
and a source file disagree, and `ringpp expand` folds `\u4E2D` to a literal
中 — both correct and readable, where `char(228) + char(184) + char(173)` is
only correct.

It is a function and not a new literal form on purpose: a file using it
still loads and still works under plain `ring.exe`, and `ringpp expand`
folds it into a plain concatenation so the tool removes the cost without
being required for the meaning.

Cost, `bench/str.ring`, 100,000 evaluations, minima of 3:

```
  plain literal                  5 ms      0.05 us per call
  hand-written concatenation    12 ms      0.12 us   <- what expand folds to
  RppStr(), with escapes       800 ms      7.9  us
  RppStr(), nothing to decode   85 ms      0.85 us   <- the early out
  RppStr(), two \u escapes    2000 ms     20    us   <- a codepoint costs most
```

Two significant figures, and deliberately so: across runs the escape arm
measured 798-854 ms and the codepoint arm 1939-2005, a spread of about 7%.
Anything finer would be reporting noise.

**Where it loses:** 7.9 us a call is a hot loop's whole budget -- and a
codepoint is 20, because it is parsed as hex and THEN encoded -- so RppStr
is for strings built once and the fold is for the rest. The obvious
optimisation was tried and rejected: collecting runs in a list and
joining once measured 7.52 us against 6.65 for the plain character loop
on a 22-character string, and won only 1.13x (161 vs 182 us) at 880
characters. Not worth the shape.

`ringpp check` reports the two detectable shapes as `rpp/string-escape`:
an identifier carrying a backslash, and two literals in one expression
each ending in an odd run of them. It deliberately says nothing about
`"line1\nline2"` — very probably a wanted newline, silently a backslash
and an n, and indistinguishable from the path `"C:\new"`. Measured over
530 files and 11.6 MB of Softanza: zero reports.

### F-56. `char()` is byte-wise and takes its argument modulo 256, silently

Measured 2026-09-06 on Ring 1.27, while adding `\u` to `RppStr()`.

```
  char(65)       byte 65     A
  char(255)      byte 255
  char(256)      byte 0      <- not 255: it WRAPS, it does not clamp
  char(257)      byte 1
  char(511)      byte 255
  char(512)      byte 0
  char(0x4E2D)   byte 45     the CJK character, delivered as an ASCII hyphen
  char(0x1F600)  byte 0      an emoji, delivered as a NUL
  char(-1)       byte 255    negatives wrap too
  char(65.7)     byte 65     the fraction is dropped
```

**No error, no warning, no truncation notice.** The emoji case is the worst
of them: `char(0x1F600)` is byte **0**, and a NUL is exactly what F-14 turns
into a process death the moment it reaches `memcpy`. A codepoint that looked
like a character becomes a crash three files away.

`ascii()` is loud where `char()` is silent, which is the asymmetry that hides
this. `ascii("中")` does not return 20013 and does not return 228 either --
it RAISES, *Bad parameters value, error in length!*, because the string is 3
bytes and it wants 1. So the round trip does not close and cannot be made to:

```
  ascii(char(0x4E2D))  =  45        wanted 20013
```

**There is no way to write a codepoint in Ring.** A Ring string is a byte
string -- the literal e-acute is 2 bytes, CJK is 3, an emoji is 4, and
`char(0xC3) + char(0xA9)` compares EQUAL to the literal. Softanza's own code
already knows this: of **618** `char(NNN)` calls with a three-digit literal
in `base/`, **zero** are above 255, and the commonest values are 226, 148 and
240 -- UTF-8 lead and continuation bytes, assembled by hand, three calls to a
character. That is not an accident, it is what people do after being bitten
once.

Ring++ answers it with `\uNNNN` and `\u{N...}` in `RppStr()` (F-55), which
encode UTF-8 properly and refuse a surrogate half. The bytes are
indistinguishable from a pasted character -- the gate compares them against
pasted literals for e-acute, CJK, emoji and Arabic. `ringpp expand` folds
the call to the character itself.

**What it costs:** a `\u` escape is the dearest thing `RppStr()` does --
20 us per call against 7.9 for the plain escapes and 0.12 for the folded
form (`bench/str.ring`, 100,000 evaluations, minima of 3). Hex parsing plus
UTF-8 encoding on every evaluation. Which is the argument for the fold, not
against the escape.

`ringpp check` reports a LITERAL argument outside 0..255 as
`rpp/char-truncates`, naming the byte it actually produces. A computed
`char(n)` is not reported: it may well be in range, and guessing would be
wrong on all 618 of those deliberate byte calls. Measured over 530 files and
11.7 MB of Softanza: zero reports -- which is the finding, not a failure of
the rule. Nobody writes `char(0x4E2D)` twice.

### F-57. Our VM rounds exact ties the other way from Ring's official build

Measured 2026-09-07, running Softanza on `runtime/win64/ring.exe` -- the VM
Ring++ builds from `vendor/ring-vm/` -- beside Ring's own libraries, against
Ring 1.27's official `bin/ring.exe`. Same source, same library files, two
compilers.

```
                     official      ours
  decimals(2)
    0.125      ->      0.13        0.12
    1/8        ->      0.13        0.12
    0.135      ->      0.14        0.14
    0.145      ->      0.14        0.14
  decimals(0)
    0.5        ->      1           0
    1.5        ->      2           2
    2.5        ->      3           2
```

**Only EXACT ties differ.** 0.125, 0.5 and 2.5 are exactly representable in
binary, and the two C runtimes break the tie by different rules: Ring's
official build rounds **half away from zero**, ours rounds **half to even**
-- the IEEE default that glibc, musl and LLVM's `printf` implement. 0.135
and 0.145 are not really ties in binary, so both builds agree on them, which
is why this hides: it looks like an occasional disagreement rather than a
rule.

**This is a rounding difference, not a computation difference.** The
arithmetic is identical; only the decimal formatting of a tie differs. But
it reaches output, and the domains this project targets are banking and
government, where a half-cent rule is not a detail.

**How it surfaced.** `hashlist/17_numberofklasses.ring` prints class
frequencies: `[ 0.25, 0.38, 0.25, 0.13 ]` on Ring, `[ ..., 0.12 ]` on ours.
One value in four, from 1/8.

**The scale of the divergence, measured over 90 Softanza test files run on
both VMs:**

```
  53   byte-identical output, raw
  37   differed -- and of those:
       30   also differ from THEMSELVES on the official VM (timings)
       12   match once timing numbers are normalised
       25   still differ: 21 in perf/ (measured rates and latencies --
            838.65 /s vs 690.52 /s, noise of the same kind), and FOUR
            in hashlist/ and stats/, which is this finding.
```

**The lesson about the metric, which cost more than the finding.** Comparing
program output between two VMs is worthless until the output's own
determinism is known. The first pass reported 53/90 and `perf 1/25`, which
read as a serious divergence; running the OFFICIAL VM against ITSELF showed
30 of the 37 were not reproducible at all. **Establish the noise floor
before attributing a difference to the thing you changed.**

It is the first place where "compatible with the old Ring" and "better
than the old Ring" actually conflict. **Decided 2026-09-07 by Mansour:
keep IEEE correctness** -- half to even, and re-record the handful of
expected outputs that contain a formatted tie. Recorded as **C-1** in
[CORRECTIONS.md](CORRECTIONS.md), with what the choice costs.


### F-58. The grammar cuts the last statement of a method out of its class -- three ways



Measured 2026-09-08 with `rnxc poison` over Softanza (593 files, 44,427

functions and methods): **one construct held 19,398 of the 21,823 unusable

functions**, and the construct was a parse, not a language feature.



Inside a `class`, the grammar (`vendor/tree-sitter-ring`) does not reliably keep

the last statement of a `def` inside it. Probed with `rnxc dump`, three shapes:



```

  def E5()   return a + b + c            -> the whole return falls out, to

                                            FILE level, and the class body

                                            closes there (every def after

                                            it is parsed outside the class)

  def E3()   return "" + a + "b"         -> a BARE return inside the def,

                                            the expression outside

  def E()    return "" + @a + "b"        -> return keeps a PARTIAL value,

                                            `""`, and `+ @a + "b"` becomes a

                                            second statement: a unary plus

```



The cut lands at a different `+` from one line to the next: after the first

parenthesis in `stzTime.ring:502`, after `_cMid_` in `stzString.ring:5746`, at the

very start in `stzComplex.ring:70`. That is what a GLR tie-break looks like from

outside; the same lines parse whole inside a `func` at file level. The first

two shapes the compiler already repaired by position (F-21 is Ring's own

rule: a function owns everything up to the next `func`). The third it refused,

and the refusal poisoned everything downstream of `Content()`.



**And the grammar errs the other way as well.** `x = "a"` on one line and `+ "b"`

on the next come back JOINED as `x = "a" + "b"`. Ring does not join them:



```

  x = "a"        y = 10        t = "a"            ? "Q1 " + 1

  + "b"          - 3           + "b" + "c"        + 5

  ? x  -> a      ? y -> 10     ? t  -> a          -> Q1 1, then nothing

```



Ring's rule is the newline: it ends the statement unless the line is

unfinished -- a trailing operator, a comma, an open bracket (`"a" +` then

`"b"` gives `ab`). A line that begins with `+` or `-` is a statement of its own,

evaluated and discarded; `* 5` at line start is a syntax error; and a newline

before `+` INSIDE parentheses is an error too (C8). All probed on the oracle.



**What Ring++ does instead** (`rereadSpan` in `src/compile.zig`, 2026-09-08). The

compiler re-reads the span the way Ring reads it: the statement's text plus

every same-row tail the grammar cut off, cut again at every newline that

follows a finished term and precedes a leading `+`/`-`, each piece parsed

alone inside a `func` and compiled as the statement Ring sees. A piece that

does not come back as one statement leaves the original refusal standing,

named -- never a guess. Refusals inside a re-read piece report the source

line, not row 2 of a snippet.



```

  Softanza census        before          after

    refused              802             725

    usable functions     22,604 (50%)    22,724 (51%)

```



Usable moved one point, not forty: the 19,398 are held by several roots at

once, and this was one of them. `rnxc poison`'s by-construct list now names the

next -- 56 `binary_expression` sites, which read as three things: **bitwise

operators** (`& | << >>`, ~22 sites, none in the VM yet), **append chains as

statements** (`aList + x + y` appends both on Ring, ~10 sites), and **operator

methods on objects** (`_oScripts_ - [...]` -- on a plain list that is R21).



**Two things found on the way, for Softanza rather than for Ring++.**

`stzNumber.ring:494` has `_cMax_ - "_"` as a statement; on Ring a string minus a

string raises R41 whether or not the value is used, so that line is either

unreached or a live error. And the grammar defect itself belongs upstream

(`ysdragon/tree-sitter-ring`): the probe files are in this session's record, and

the report is Mansour's to send, never this project's.

### F-59. Ring has NAMED PARAMETERS, and `:Name = value` is a two-element list

`:Name = value` does not compare. Wherever a value is wanted, Ring builds the
list `["name", value]`. Measured on 1.27, eight rows:

```
  f( :From = 3 )        the callee receives ["from", 3]
  f( :From = 1 + 2 )    the value is EVALUATED first -- ["from", 3]
  y = ( :From = 3 )     outside a call too
  if :From = 3          TRUE -- not a comparison; the LIST is truthy
  [ :From = 3 ]         a pair inside a list literal
  f( "from" = 3 )       0 -- a STRING on the left is a comparison
  f( x = 3 )            0 -- and so is a variable
  f( :From )            "from" -- a bare symbol is its string (already C-?)
```

So the rule is the SYMBOL on the left, not the shape of the line.

**Softanza spells about a thousand arguments this way**, and Ring++ compiled
every one of them as an equality, so each arrived as `0`. That is silent: the
callee's `isList(pnStart)` is false, its unwrapping never runs, and the value
it uses is a number nobody passed. `StzListParserQ().Parse` then ran

```
  for i = pnStart to pnEnd step pnStep      with pnStep = 0
```

which appends for ever -- the last `panic: oom` in the wide clock, 2026-09-19.
The OOM was never a memory defect; it was this.

**The fix is written and NOT landed, deliberately.** The grammar hands the
construct over as a `binary_expression` whose left child is a `symbol`, and
only the list-literal path (where it arrives as a `hash_pair`) ever built the
pair; teaching `expr` and `cond` the same rule is about fifty lines and makes
all eight rows above identical to Ring.

**What stopped it** is what a thousand newly-correct call sites do: they run
library code that has never executed here. The wide pass went from ~8 minutes
for 430 tests to **35 tests in 75 minutes**, most of them hitting the 120 s
cap. A change that makes the suite unmeasurable in an afternoon is not ready
to land, however right its own rows are.

**And it uncovered a defect that wants its own hunt.** With TWO OR MORE named
pairs in one call, this segfaults at address 0xc under ReleaseFast and passes
under ReleaseSafe -- corruption, not logic:

```
  zzP( :From = 3, :To = 9, :Step = 3 )

  func zzP pnStart, pnEnd, pnStep
      if isList(pnStart) and
         ( IsStartingAtNamedParamList(pnStart) or
           IsFromNamedParamList(pnStart) )
          ...
      ok
```

One pair is fine; three list LITERALS in the same positions are fine; the same
condition with a literal list is fine. It needs the pairs and the parameter
count together, which is why it reads as register pressure rather than as the
construct. Reproduced on the day, with the rule applied.

---

### F-60. Ring calls `Main()` after the top level, and the rule has eight parts

Measured on 1.27, twelve programs, in `scratchpad/mainp`. Ring runs a file's
top level and THEN, if the program defines a plain function named `main`,
calls it with no arguments.

```
  a file that is only `func Main`        Main ran
  top-level code and a Main              the TOP LEVEL first, then Main
  func main / func Main / func MAIN      all three called -- names fold
  Main defined in a LOADED file          called just the same
  a METHOD named Main                    NOT called
  two Mains, one loaded, one not         C22 Function redefinition (compile)
  an uncaught raise in the top level     Main never runs
  func Main p  (it declares a parameter) called with NONE:
                Line 1 Error (R19) : Calling function with less number
                of parameters / in file m7.ring
```

THE CALL SITE RING REPORTS IS THE `func Main` LINE, in Main's own file, and
not the top of the file. Two programs settle it: one whose `func Main` is at
line 1 answers `Called from line 1`, and one whose top level is line 1 and
whose `func Main` is line 2 answers `Called from line 2`. The R19 above is
reported at that same site.

And the frame is a real one: an error inside Main prints `In function
main()`, with the chain continuing to `Called from line N in file f.ring`,
the bare form Ring uses for the top level.

```
  Line 3 inside main
  In raise() In function main() in file m11.ring

  Called from line 1 in file m11.ring
```

ONE MORE ROW, taken while checking that one: `In raise()` is printed for
Ring's own `raise()` and for NOTHING else. An R19 from an ordinary call of
the wrong arity reports `in file m13.ring` alone.

---

### F-61. A call's result is a PLACE: Ring writes through it to the original

Ring copies at the ASSIGNMENT and not at the return (C-7), so what a call
hands back is the original container. Four shapes measured on 1.27, and all
four mutate what the callee returned:

```
  q.L()[1] = 99          a METHOD's result, subscript-assigned
  add(q.L(), 99)         appended to the object's own list
  G()[1] = 77            a plain function returning $g
  add(G(), 88)           appended to $g
```

And the same holds for another object's attribute reached by name:
`o.aL[1] = 99` and `add(o.aL, 99)` both write through. `del` and `insert`
behave the same way; a nested path under one (`o.M()[1][2] = 66`) does too.

THE BOUNDARY IS THE ASSIGNMENT, and it is what makes this safe rather than
alarming: `aCopy = o.L()` then `aCopy[1] = 1000` leaves the object alone,
because C-7's copy happens there. The reference is a place only while it
is not being bound to a name.

A call returning a FRESH list is appended to and dropped, silently, on Ring
as anywhere else. That is the cost of the rule, not an exception to it.

---

### F-62. `do <body> again <cond>` is a POST-test loop, and `loop` re-tests

Ring's only loop whose test is the LAST child rather than the first. Five
rows measured on 1.27:

```
  do / i++ / again i < 3         repeats while the condition is TRUE
  j = 10 / do / j++ / again j<3  the body runs at least ONCE -- prints 11
  exit inside it                 leaves the loop
  loop inside it                 jumps to the RE-TEST, not to the top
                                 -- WRONG, corrected by F-125: it restarts
                                 the body; this row's condition was true
  nested                         each level keeps its own exit
```

The fourth row is the one that could not be reasoned out: a post-test loop
could send `loop` either to the top of the body or to the condition, and
both are defensible. Ring re-tests.

**Ring's own standard library uses it twice**, in `Split()`
(`libraries/stdlib/stdlibcore.ring`), which the estate loads on every
program -- so it is not a corner of the language, it is on the path.

---

### F-63. A property the class does not have is R12 at the READ, catchable

```
  Error (R12) : Error in property name, property not found: x
```

The name folded to lower case, the program running on. Measured on 1.27 for
four shapes, and the first is the one that matters to the estate:

```
  @x declared, read as This.x    R12 -- the sigil is part of the NAME
  a METHOD of the class, This.M  R12 -- not a bare call
  a name that is nothing         R12
  o.nope on another object       R12, the same text
```

A name the class declares BARE still reads as that attribute (C-12); the
sigil row is its exact opposite, and the two together are why `@x` and `x`
cannot be treated as one name.

`StzFileOverwriterQ().PreserveAndModify` reads `This.cOriginalContent` where the
attribute is declared `@cOriginalContent` -- a one-line latent bug in the
estate that Ring reports when the line runs.

---

### F-64. `n++` as a VALUE is a PRE-increment: it yields the NEW value

The syntax is postfix; the semantics are not. Measured on 1.27:

```
  n = 5 / x = n++        x is 6 and n is 6 -- BOTH the new value
  m = 5 / ? m++          prints 6
  k = 5 / (k++) + 1      7
  j = 5 / j++ + j++      13 -- which is 6 + 7, so it pins the ORDER too
  e = 5 / Show(e--)      4
```

`j++ + j++` is the row that settles it: no post-increment reading produces
13. A statement `n++` is the same increment with the value discarded, so
the two forms never disagree about the variable, only about what they
hand back.

---

### F-65. RING HAS NO ONE-LINE `if cond: stmt ok` -- the `:` is a RANGE

```ring
  if _bUp_: _nConnections_++ ok
```

reads as a guarded increment and is nothing of the kind. `a : b` is Ring's
range operator, which builds a LIST; it is evaluated eagerly, so the
increment happens WHATEVER the condition is, and the list is truthy, so the
(empty) `if` body always runs. Measured on 1.27:

```
  bUp = 0 / n = 0 / if bUp: n++ ok       n is 1 -- the condition was FALSE
  c = 1 / m = 0 / if c = 1: m = 5 ok     m is 0 -- `m = 5` is a COMPARISON
  1:4                                    a LIST of 4
  if 0: k++ ok                           k is 1
  if c: ? "hi" ok                        C28, Expression is expected
```

The second row is the other half of the trap: inside an expression `m = 5`
compares, so the would-be one-line `if` does not even do the thing it looks
like it does. The last row is where the illusion ends -- a `?` is not an
expression, and the `:` wanted one.

**`stzSurfacePlot.ring:697-700` has four of these in a row**, so
`_nConnections_` counts 4 every time instead of counting the true ones.
Ring++ reproduces it: the defect is the estate's, and a compiler that
guessed what was meant would be a worse tool than one that is faithful.

---

### F-66. A function with no `return` yields NULL -- the empty STRING

Not 0. Measured on 1.27, for a function and a method alike:

```
  func F  x = 1          F() is type STRING, isNull 1, len 0, F() = "" TRUE
  func F  return         the same -- a BARE return is NULL too
  if n = 1 return ok     the same, from an early return in a branch
  a method, either way   the same
```

A function that returns a value on some paths and falls off its end on
others therefore returns TWO types: `Pos(5)` is the NUMBER 5 and `Pos(-1)`
is the STRING "", so `Pos(-1) + "x"` concatenates. A compiler that types
such a function by its explicit returns alone calls it an integer and is
wrong on every path that falls off.


### F-67. A string is a number by ONE rule, and `""` is 0 -- for `=`, `<` and `for` alike

Ring converts a string to a number in one function, `ring_vm_stringtonum`
(vmexpr.c:892), and arithmetic, `=`/`!=`, `<`/`<=`/`>`/`>=` and a `for`
bound or step all go through it. Measured on 1.27, official build and our
oracle agreeing on every row (`bench/exec/null_is_zero.ring`,
`num_text.ring`, `num_order.ring`, `for_text.ring`, 76 rows):

```
  ""            is 0 -- "Support converting NULL to Zero". 0 = "" is TRUE,
                0 = NULL is TRUE, switch 0 on "" matches
  "   "         is NOT 0: strtod converts nothing. 0 = "   " is false,
                1 - "   " and "   " < 1 are R41
  " 5", "5 "    are 5 -- leading whitespace by strtod's set (VT and FF
                too), trailing only space/CR/LF/tab (ring_general_looksempty)
  "abc"         converts to 0 but is not a number: 0 = "abc" is false
                (vmexpr.c:319 guards exactly that), "abc" < 5 is R41
  "1_000"       is not a number: strtod stops at the `_`
  5 < "6"       is 1 -- ordering converts like arithmetic
  for i = 1 to "3"        runs 1, 2, 3; a text bound or step converts
  for i = "1" to 3        R29 -- the START must already be a number
  a list start or bound   R29; a list step R28
```

The estate meets row one through its engine handles: a failed compile hands
back the handle 0, and `stzMathFunction` refuses a bad expression with
`if @pProg = ""`.

### F-68. `aList + v` appends IN PLACE wherever it stands, and `cCatchError` is process-wide

Two rules measured on 1.27, official build and oracle agreeing on every
row, both because a compiler rule needed them.

**`aList + v` is an append to `aList` itself, in every position** -- not
only as a statement (`bench/exec/elem_sound.ring`'s companion probe,
2026-09-24):

```
  aL = [1]   x = aL + 2         len(aL) is 2, and len(x) is 2
  aM = [1]   ? len(aM + 3)      prints 2, and len(aM) is 2 afterwards
  aN = [1]   if len(aN + 4) = 2 the condition holds and len(aN) is 2
```

So an expression that merely READS `aL + v` has written to `aL`. For a
type table that tracks what a list holds, a nested `+` is an unobserved
write.

**`cCatchError` is one process-wide variable** (`bench/exec/
catch_error_global.ring`): the string `NULL` before any catch has run;
after a catch, the last caught message, readable from ANY function and
from the top level until the next catch overwrites it; and inside a
handler it is overwritten by any catch a CALLEE runs -- `raise("outer")`,
then a callee that catches "inner", leaves the handler reading "inner"
(the defect Ring++'s §2.17 removes; C-15 records what is kept of each).
Softanza reads it through a function, `CatchError()` in
`stkRingFuncs.ring`, from inside its handlers.

### F-69. Operator overloading: every operator on an object calls `operator(cOp, x)`, the right side with an "r"

Measured on 1.27, official build and oracle agreeing on every one of 40
rows (`bench/exec/operator.ring`), because Ring++ had no dispatch at all
and a fifth of the assertion passes it lacked were this one feature --
Softanza's stzList, stzString, stzHashList and stzDuration all define it.

```
  o + 5   o - 3   o * 2   o / 2   o % 3   o & 1   o ^ 2      operator("+", 5) ... the
                                                             operator's own TEXT, the
                                                             right operand as given
  o[3]    o[:key]                                            operator("[]", 3) -- a
                                                             subscript is an operator
  o = 10  o != 10  o < 20                                    dispatched too, and the
                                                             method's answer IS the
                                                             expression's value:
                                                             Show(o = 10) prints the
                                                             string the method returned
  -o                                                         operator("neg", 0)
  o + o   o + "ab"   o + [1,2]                               the argument as given
  o + 100 as a STATEMENT                                     dispatched, answer dropped
  5 + o   5 - o   5 * o   5 / o   5 & o   5 < o   5 >= o     operator("r+", 5) -- the
  "a" + o                                                    object on the RIGHT gets
                                                             the operator with "r" in
                                                             front, the left operand
                                                             as the argument
  [1] + o                                                    NO dispatch: a list on the
                                                             left appends the object
  5 = o   5 != o                                             NO dispatch: 0 and 1, a
                                                             plain comparison
  if o < 3 ... with operator returning This                  truthy -- an object is true
  if z < 3 ... with operator returning 0                     falsy
  a class with NO operator:  p + 1   p[1]   p < 1            Error (R50) : Object does
                                                             not support operator
                                                             overloading -- catchable
                             p = 1   p != 1                  plain: 0 and 1
  r = q + 1 where operator returns This, then r.n = 100      q.n unchanged -- the
                                                             assignment COPIES the
                                                             returned object
  o[1] = 7                                                   Error (R34) : Variable is
                                                             required for the assignment
                                                             operation -- not an operator
```

And a list's `+` in an expression: `x = aL + 2` appends to `aL` in place
and gives x its OWN copy (`add(x, 3)` leaves aL at 2 items).

### F-70. In a class body, reading an unknown name CREATES that attribute

Measured on 1.27, both builds (`bench/exec/class_unknown.ring`):

```
  class K            x = $nope         o.x is "NULL" (the string), and
                                       attributes(o) lists x, $nope -- in
                                       that order: the attribute is created
                                       WHERE the read happened
  class L            y = zzunknown     the same for a bare name: y "NULL",
                                       zzunknown an attribute
  ? $nope            at the top level  Error (R24) : Using uninitialized
  return $nope       in a function     variable: $nope -- the class-body
                                       read created no global
  def M return $nope in a method of K  "NULL": a method resolves local ->
                                       attribute -> global and finds it
  x = $set           with $set = "svg" "svg": a global that IS set reads
                                       as itself
```

Softanza depends on it by accident: `stzDiagram.ring:612` reads
`$cDefaultDiagramOutputFormat` in its class body, a name the tree never
assigns (`stzDotCode.ring:30` defines `$cDefaultDotOutputFormat`), so
every diagram's `@cOutputFormat` is NULL and three tests pass on that.
Ring++ answered R24 there until 2026-09-24. Ring++ lists the created
attribute AFTER the declared ones, where Ring lists it where the read
happened -- a recorded difference of order, nothing else.

### F-71. Three shapes of a call, measured because Ring++ refused or misread each

All on 1.27, both builds agreeing (`bench/exec/call_binary.ring`,
`brace_fallback.ring`, `chain_lines.ring`):

```
  call f(3) = 6            the keyword binds the CALL; the operator applies
  call f(4) + 1            to its answer -- 1 or 0 for a comparison, the
  x = call f(5) = 10       value for an arithmetic. The grammar hands the
                           keyword a binary whose left side is the call.
  obj { Then(...) }        a bare call inside a brace is the object's method
                           when its class has one, and otherwise the global
                           FUNCTION of that name -- `StzLocaleQ(...) {
                           Then(...) }` reaches the harness's Then. Ring++
                           raised R14 for an unproved receiver.
  o.A(1).                  a line ending in `.` is unfinished: the chain
      A(2).                continues on the next line, one statement. The
      A(3)                 grammar cut it into `o.A(1)` and a bare `A(2)`,
                           R3 -- the capstone's `oBrain.Know(...).` newline
                           `Know(...)` stopped there.
```

### F-72. `eval` runs in its CALLER'S scope, creates variables there, and answers "" unless it returns

Measured on 1.27, official build and oracle agreeing on all 18 rows,
because C-9's revision says "eval runs in the caller's scope" and the
implementation needs every edge. `bench/exec/eval_scope.ring` pins every
row of the table below byte-identical since the implementation landed
(2026-09-25), plus a call by name and an object built inside eval -- all
but the two rows that define a function or a class inside eval, which
the first version refuses with E1. No estate site does either.

```
  x = 1  eval("x = x + 41")            the top level's variable: 42
  eval("y = 7")  ? y                   a NEW top-level name: 7
  eval("z = 5")                        the VALUE of eval is "" (STRING)
  r = eval("return 6")                 ...unless the code returns: 6
  func F  a = 5  eval("a = a * 2")     a function's LOCAL: 10
  func G(p)  eval("p = p + 1")         a PARAMETER: written
             eval("fresh = p * 2")     a NEW local, read afterwards by the
             return fresh              function's own code: 22
  def M  eval("n = n + 10")            a bare attribute: written (111 after
         eval("This.n = This.n + 100") both); `t = extra()` calls a method
  try eval("bad = 1 / 0") catch        caught by the CALLER's try: R1
  eval("nosuchfunc()")                 R3, caught the same way
  eval("func Made(a) return a * 3")    a function defined by eval is real
  eval("class Q  v = 9")               so is a class
  eval("p = 1" nl "p = p + 1" nl ...)  several statements
  eval("if x > 40 ... ok")             control flow
  eval("aL + 3")                       an append to the caller's list
  eval("? eval('1 + 1')")              nested: the inner answers ""
```

And what the estate asks of it, censused from the library sources (205
sites in 44 files, archive copies included): 112 are `<name> = <expr>`
with the name spelled in the string's LITERAL prefix (70 of them with a
call in the expression), 48 evaluate a code string built elsewhere, 14
call a method by name on This, 5 are `if` statements, one is a `load`.

### F-73. Ring calls a class's `get<name>()` and `set<name>(v)` on every dot access but `This`'s

Measured on 1.27, official build and oracle agreeing on every row
(`bench/exec/getset.ring`, 29 rows; `getset_compound.ring`, 8), with a
class whose `getx()` answers 42 and whose `setx(v)` stores `v * 2`:

```
  o.x                          42 -- the getter's answer, not the slot
  o.x = 7                      setx(7): the slot holds 14, nothing else
  o.y2 with only gety2()       R12, property not found: the ATTRIBUTE
                               must exist; the accessor is not a property
  This.x, bare x, in a method  the slot (14) -- `This` is exempt
  q.x on ANOTHER instance      42, even inside a method of the same class
  F(This) from a method, and   42 -- the exemption is the method's own
    F reads p.x                   `This`, and a plain function has none
  o { x }, o { x = 3 }         through the accessor, from outside
  brace inside a method of
    the object's own class     the slot -- callmethodinsideclass
  o.x += 1                     getter 42, + 1, setter(43): slot 86
  o.aL[1] = 55 with getaL()    written into the GETTER'S answer; the slot
                               is untouched
  This.x += 1                  43 -- a compound through `This` READS
  This.x *= 2                  84    THROUGH THE GETTER and writes the slot
  This.x = This.x + 1          6  -- written out, it reads the slot
  bare x += 1                  6
  This.y += 1, setter only     2  -- never the setter through `This`
  o.y += 1 from outside        102 -- the setter
  getattribute / setattribute  the slot, no accessor
  an attribute addattribute    through its accessor, like a declared one
    gave the object
```

The source says the same (`vendor/ring-vm/src/vmvars.c:226-283`,
`vmoop.c:770-921`): `ring_vm_oop_setget` runs on every property access
through the dot unless the object is the current `This`, and on a brace
access unless the brace sits inside a method of the object's own class.

The estate's use is small and central. Softanza's base library pairs an
attribute with a getter in three classes, eleven getters, no setter:
stzChainOfTruth's six -- `_`, `_@`, `@`, `Q`, `AtTheSameTime`,
`AmongOthers` -- which is how `_(x).Is("Number")._` answers 1 or 0 at all;
stzChainOfValue's three; and a C#-emitter helper's two.

### F-74. `exit N` leaves N loops and `loop N` continues the Nth

Measured on 1.27, both builds agreeing (`bench/exec/exit_levels.ring`):

```
  for i  for j  if j = 2 exit 2      [11 ], and i stays 1 -- both loops left
  ...exit 1                          [11 21 31 ]
  ...loop 2                          [11 21 31 ] -- the inner loop abandoned,
                                     the outer continued, `s += "|"` skipped
  exit 2 from a for inside a while   the while is left too
  exit 3 from three nested fors      [111 ]
  exit 2 from two nested for-ins     the same rule
```

Ring++ read the number and ignored it until 2026-09-26: every `exit 2`
left one loop. Softanza's natural-language layer is written with it --
StzNaturalEngineQ().ProcessObjectCreation stops at the first literal with `exit 2`
-- so "Create a string with 'ring' called first Create a string with 'zig'
called second Use first Uppercase it" built 'zig' first, and six
assertions of natural/semantic_resolver failed.

### F-75. Ring's numbers are doubles past 2^53, in arithmetic and in print

Measured on 1.27, both builds agreeing (`bench/exec/big_int.ring`, 20 rows):

```
  2147483647 * 1103515245            2369780942852698624  (the double; the
                                     exact product ends ...515)
  (that + 12345) % 2147483648        1043980800
  seventy doublings of z*2+1         1180591620717411303424
  2^62 + 2^62                        9223372036854775808  -- the exact value
                                     of the double, not its shortest digits
  9007199254740991, 2^53 - 1         prints as an integer
  2^53 under decimals(2)             9007199254740992.00
  a*b above under decimals(2)        2369780942852698624.00
```

Two rules, both in `vendor/ring-vm/src/general.c:343`: every number is a
double, and a whole double prints as an integer only within
+/-9007199254740991 (RING_LONGLONG_HIGHVALUE, `ring.h:120`) -- past that it
prints through "%.Nf", its exact expansion with decimals() places.
Ring++'s integers are exact 64-bit: they agreed with Ring below 2^53 and
nowhere above it, and wrapped past 2^63 (seventy doublings gave -1). A
32-bit LCG written in plain Ring arithmetic -- `nS = (nS * 1103515245 +
12345) % 2147483648`, the shape Softanza's tests generate data with --
therefore produced a different sequence, and number/numeric_embedding a
different dataset: seven layout assertions failed on a correct engine.

### F-76. The grammar cuts a nine-call chain in statement position

`IsQ().TheQ().LengthQ().OfQ("Ring").TheSameAsQ().TheQ().LengthQ().
OfQ("Ruby").OrNot()` on a line of its own parses as TWO statements,
`IsQ().` and a bare `TheQ()...`. Eight calls parse whole, and so do nine
as an assignment's value (`bench/exec/chain_long.ring`). Wrapped in
parentheses the chain cannot be cut. Ring runs it as one chain; Ring++
bound the bare `TheQ()` to the global function `TheQ(p)` and raised R19
(natural/nnl_narrated.ring:298).

### F-77. A name assigned nowhere is R24 at the read, and its form depends on the shape

Measured 2026-09-27 on the oracle and official 1.27, which agree on every
row (`bench/exec/r24_unknown.ring`, 31 lines). A bare name that no statement
assigns and that is no global -- in a function, a method or the top level
-- raises `Error (R24) : Using uninitialized variable: <name>` WHEN THE LINE
RUNS, catchable; a branch that does not run raises nothing. The message
NAMES the variable, lower-cased with its sigil, for a read, for `x + v`,
and for add/insert/del on it; it names NOTHING for a subscripted root --
`x[1] = 5`, `x[1] + v`, `x[1]++`, `x[1] += v`. The same holds for a `$`
global nothing has assigned yet. A method finds an attribute the object
gained (addattribute) before it raises. Two shapes differ: `x++` is R21,
and `x += 1` is R24. Ring's own stdlibcore depends on the first rule --
`if elementcount < 1 then return ok` in Permutation(), where `then` is not
a keyword, fails only on an empty list.

### F-78. `new K` of a class nobody defines is R11 before the arguments

`Error (R11) : Error in class name, class not found: <name lower-cased>`,
catchable, raised where the line runs and not before: a `new` in an untaken
branch costs nothing. The constructor's arguments are NOT evaluated -- a
call among them prints nothing. The same for `new K`, `new K(args)`, `new K
{ }`, `new K()` alone as a statement and `new K` as a value. Ten rows,
`bench/exec/new_absent.ring`, both builds.

### F-79. `find` has a fourth form: a list of objects, on one attribute

`find(aList, value, nColumn, cAttribute)` (list_e.c:258, rlist.c:1247).
Only a column above 0 searches (0 answers 0); column 1 means each element
IS the object, column N the N-th item of each sub-list; the attribute name
is folded to lower case, the value is compared exactly (strcmp, or `==` on
numbers); a string needle meets only a string attribute and a number only
a number; an element that is not an object is skipped; an object WITHOUT
the attribute is `Error (R12) : Error in property name, property not
found` at once, even before a later match. Ring's stdfunctions.ring calls
it in std_find3. Sixteen rows, `bench/exec/find_attr.ring`.

### F-80. A comment may stand inside an expression

Ring's scanner drops a comment wherever a newline may stand: between the
lines of a `+` continuation, among a call's arguments, inside a list
literal, as `#`, `//` or `/* */` (`bench/exec/comment_in_expr.ring`, six
rows, both builds). The tree-sitter grammar keeps it as a NODE where it
falls, so it becomes a named child of the expression.
StzUiDocumentQ().ToFixture has eight `#` lines inside one `+` chain.

### F-81. `F() = v` runs both sides, then raises R34 unless the result is a list

A call on the left of `=` in a statement: Ring runs the call, then the
right side, then raises `Error (R34) : Variable is required for the
assignment operation`, catchable -- for a number, a string or NULL. A list
or an object is taken SILENTLY, because the assignment writes THROUGH the
result: `o.Me() = 5`, with Me returning This, replaces o itself, and the
next `o.x` is R13. Both builds, `bench/exec/call_assign.ring` (the
write-through row left out). max/string/stzSringConstraints.ring:55 has
`This.VerifyConstraint(cConstraintName) = 0`, so VerifyConstraints raises
R34 on Ring whenever that line runs (fixed in his tree 2026-09-28, e971da011).

### F-82. A member of `new K(args)` is R13 on Ring; in parentheses it works

`x = new K(1).M()`, `? new K(1).M()`, `new K(1).v` and a return of the
same shape all raise `Error (R13) : Object is required` on both builds;
`(new K(1)).M()` answers. `new K.M()` is `R11 ... class not found: k.m` --
the dot joins a qualified class name. Sixteen live library lines have the
first shape (stzStringFunc's Titlecased and three siblings, four in
stzTable, two in stzStringInserter, stzListOfNumbers, stzListOfLists and
two timeline files), so each fails on Ring whenever it runs. Ring++ runs
them (C-20).

### F-83. A Ring built on musl answers `0 = 'abc'` with R41; glibc and Windows answer 0

`ring_vm_stringtonum` (vmexpr.c:892) calls `strtod`, then reads "the
result is 0 AND errno is set" as an invalid numeric string. musl's strtod
sets errno when nothing converts; glibc's and the Windows C runtime's do
not. So a number compared with a non-numeric string -- `0 = ' '`, `1.5 =
'abc'`, a string on the left of a named-argument pair -- raises `Error (R41)
: Invalid numeric string` on a musl-built Ring and answers 0 everywhere
else, from the same source. Found 2026-09-28 by the first Linux run of the
exec probes, on an oracle built static-musl: three probes stopped at R41.
Rebuilt on glibc, as Ring's own Linux build is, all three agree with
Windows. The phone targets (linux-arm64) are still musl, so a Ring there
answers differently from every other Ring. The same static-musl oracle
could not dlopen at all, so it had never loaded its own zip extension --
nor, therefore, run any Softanza program.

### F-84. `clock()` is C's clock(): wall time on Windows, CPU time on Linux

Ring's `clock()` returns C's `clock()` and `clockspersecond()` its
CLOCKS_PER_SEC. On Windows' C runtime that is wall time since the process
started, in milliseconds, with 1 ms steps (both Ring builds and Ring++,
twenty samples each); on glibc it is the process's CPU time in
microseconds, so a 120 ms `syssleep` reads 125 units on the Windows
oracle and 0 on the Linux one. A program timing work with clock() -- 391
Softanza sites do -- measures a different thing per platform.

### F-85. Ring's maths builtins are the C library's, and the last digit is the platform's

`sin`, `cos`, `tan`, the inverse and hyperbolic functions, `exp`, `log`,
`log10` and `pow` call the C runtime (math_e.c). Two correct libraries
need not agree in the last bit: at 17 decimals `exp(1.8326)` is
6.25008906842049772 on glibc and ...683 from Zig's implementation, and
`pow(1.1, 7.3)` differs between the Windows runtime and Zig. A
computation that AMPLIFIES a last bit shows it: number/numeric_embedding
trains a small network for 400 epochs on data made with sin and cos, and
"a place between two rows inverts to a plausible row" passed on the Linux
oracle and failed on Ring++ three runs of three (2026-09-28). And on
Linux the names alone do not reach glibc from a Zig binary: its
compiler-rt defines exp, sin and log inside the binary, so the link used
those and imported only pow. `bench/exec/libm_digits.ring` pins it on both
platforms.

### F-86. The Linux oracle crashes at exit after running Softanza

With the Softanza engine loaded, `runtime/linux-x64/ring` (Ring 1.27 on
glibc) prints the whole of a program's output and then exits with code 11
(SIGSEGV) -- the smoke test prints "All smoke tests passed!" and dies.
Ring++ exits 0 on the same program. The clock compares output, not exit
codes, so it measures through this. Not investigated: most likely a
library's destructors running after Ring has torn down the state they
use. Named, not chased.

### F-87. A function nobody defines is R3 BEFORE its arguments, on the callee's line

Ring looks a called name up when it READS it (LOADFUNC), and the arguments
come after. So a call to a name nothing defines raises R3 without
evaluating a single argument -- `zzNope(zzSay("one"), zzSay("two"))` prints
neither -- and reports the line the NAME is on, where the arguments span
several: `Line 7` for a call whose arguments close on line 9. Both 1.27
builds, 2026-09-29. An error raised INSIDE a function that exists is
reported where the call closes instead -- `left(5,` NL `2)` is Line 8, the
second line -- because the C function runs at CALL, after the arguments,
and the trace then names it: `In left() in file ...`. Found on Linux, where
six http tests stop at a missing engine domain on both runtimes and
differed on that line alone (327 against 328 in StzHttpClientQ()._Perform).

### F-88. Ring counts a METHOD's arguments at the call, as it counts a function's

A method called with too few arguments raises `Error (R19) : Calling
function with less number of parameters`, with too many `Error (R20) :
Calling function with extra number of parameters` -- catchable, and the
method is never entered. It holds for a receiver of known class and one
found by name, for `init` through `new K(...)`, for `super.M(...)`, and for
a brace hook (`BraceEnd(z)` declares a parameter the brace never passes:
R19). Both 1.27 builds, 2026-09-30; `bench/exec/method_arity.ring`. Found
through Softanza's `StzStringQ().FromHex()`, which calls
`StzStringEncoderQ().FromHex(cHex)` with no argument -- R19 on Ring whenever
it runs, while Ring++ entered the method with its parameter missing.

## F-89. A LOCAL read where nothing has assigned it is R24 on Ring, at the read

A local exists on Ring only once something assigns it. Reading it on a
path where no assignment ran -- the branch that would have set it was not
taken, a `for` body never ran, a `while` never entered, the `try` body was
left before it -- raises `Error (R24) : Using uninitialized variable: <name>`
with the name lower-cased, catchable, the moment the read runs. A `for`
counter is always assigned (the start value is stored before the first
test). Both 1.27 builds, 2026-09-30; `bench/exec/r24_local.ring`, thirteen
rows. Ring++ checked globals and attributes at the read (2026-09-21) and
never a local: the register held whatever it held -- nil, or a value an
earlier frame left there -- and the program ran on. Softanza's largest
remaining line class in the wide suite was this shape: StzListQ().operator()
reads `_bTheseQ` and `_bAsObject` in branches where only another branch
resets them, a Rule A migration leftover that fails on Ring too.

## F-90. Ring cuts its try list back at a METHOD's return, at `exit` and at `loop` -- not at a FUNCTION's

`try return x catch ... done` leaves its function with the try still
recorded. Ring restores the try list's size at a method's return
(`ring_vm_restorestateformethods`, vendor/ring-vm/src/vmstate.c:248) and
at `exit`/`loop` out of a try inside a loop, so a later error is caught by
the handler that is really around it. At a plain FUNCTION's return it does
not, and the stale entry decides what happens next: a `raise()` raised
after such a return -- inside the caller's own `try`, or uncaught -- ends
Ring with exit code 1 and NOTHING printed, on both builds; a runtime error
(R21) in the same place is caught where it should be. 2026-10-01,
`bench/exec/try_return.ring` (the rows where Ring is right) and C-21.
Ring++ cut it back NOWHERE: only a try body that fell through emitted
`pend`, and `ret` never touches the handler stack -- so an error after any
such return, exit or loop unwound into the catch of a frame that had
already gone, and 256 of them overflowed the stack, a panic. Found through
Softanza's `@IsStzObject`, which is `try return p.IsStzObject() catch
return 0 done`: the R24 that StzListQ().operator raises next (F-89) was caught
by that dead handler, whose `return 0` resumed the operator on a false
answer, so `Q(1:5) - Q(3)` returned a list where Ring raises.

## F-91. `x = new K(args)` holds the object BEFORE its arguments run; a `$` parameter is a parameter

Ring stores the new object into the assignment's target first, then
evaluates the constructor's arguments and runs init. So `o = new K([1] +
o)` appends the new object itself -- Softanza's list/191 writes exactly
that and expects the object to be dropped as a non-scalar -- and `q = new
K(q)` hands init the object, where a plain self-read (`y = "a" + y`) is
R24. Separately, `func pvtMax(n1, $n2)` declares a parameter NAMED `$n2`:
the `$` is part of the name on Ring and the parameter is the innermost
binding, read and written as such (P(3, 7) answers 7). Ring++ raised R24
on the first and read the never-assigned global on the second -- the
second is what stopped string/288-290 in StzListOfSectionsQ().pvtMax. Both
1.27 builds, 2026-10-02; `bench/exec/new_target.ring`, ten lines.

## F-92. A bare call in eval resolves on the RECEIVER; a call by name reaches functions only

Inside a method, `eval("x = (Size() > 2)")` calls the method of the
object the method was called ON -- a subclass's own `Size()` -- not of the
class that defines the method holding the eval. And `call "Size"()` where
only methods carry that name is R3: a call by name never reaches a
method. Softanza's StzObjectQ().IfQ is that shape ('NumberOfItems() > 2' on a
stzList). Ring++ bound eval to the defining class, found no such method
there, and then took a METHOD of that name from any class through its
function-by-name map, running it with no receiver: "Bad parameter type!"
in stzIntSeq (string/338). Both 1.27 builds; `bench/exec/eval_receiver.ring`.

## F-93. F-59 holds inside a list literal: only a `:symbol` key builds a pair

`[ :name = "M" ]` is `[ ["name", "M"] ]`; `[ "name" = "M" ]` is `[ 0 ]`,
`[ x = 3 ]` with x at 3 is `[ 1 ]` -- a string, a variable or a number on
the left of `=` compares, in a list as everywhere (F-59 measured the call
argument and the plain value). The grammar hands every `k = v` in a list
over as one node kind, and Ring++ built a pair from each. Softanza's
list/391_hashlist_syntax_key_value states the rule in its own comment.
Both 1.27 builds; `bench/exec/list_pair_key.ring`, seven rows.

## F-94. `aList + v` appends a COPY of a list or an object

On Ring, a list or an object appended with `+` -- as a statement, `a + b`,
or inside an expression, `c = a + b` -- is copied into the list: changing
the original afterwards leaves the appended one as it was, nested lists
included, exactly as `add()` and `insert()` already did here. Softanza
builds every CombinationsXT tuple in one working list (`_aResult_ +
_aCurrent_`, then `del(_aCurrent_, ...)`) and every History() step from the
current content; Ring++ appended the list itself, so the tuples came back
empty and the history steps overwritten. A closure is appended as it is:
on Ring a lambda is a string. Both 1.27 builds, 2026-10-02;
`bench/exec/append_copies.ring`, eight lines.

## F-95. Two reactors spawning at once hand each other their pipes (Windows)

Softanza's reactor spawns through libuv, and on Windows `uv_spawn` creates
the child's ends of its stdio pipes INHERITABLE, calls `CreateProcessW`
with `bInheritHandles = TRUE`, and closes them again, all inside the one
call. Every reactor runs its loop on its own thread, so a second reactor
spawning inside that window gives ITS child the first child's stdout end
too. A spawn job is ready only once its process has exited AND its pipe has
reached EOF, so the first job then waits for the OTHER child to exit.
Measured with `bench/spawn_race.ring`: a child that exits at once is ready
in 38-86 ms alone, and in ~3,050 ms -- the moment a 3 s child spawned on a
second reactor exits -- in 8 of 8 trials, on the oracle, on official Ring
1.27 and on Ring++ alike, each with its own build of the engine. It is the
engine's, not a runtime's: cluster/d3_supervision's supervisor never saw
its killed child die while the test's watcher, spawned on another reactor
just before it, was alive, and the test passes on Ring only because Ring's
interpreter takes long enough between the two spawns. Fixed in Mansour's
engine (`reactor.zig`, one process-wide lock around `uv_spawn`): 0 of 8 on
all three, d3 10 of 10 three runs of three on Ring++ (1.6-2.2 s, from
35.7). What it costs: a spawn that overlaps another waits for the other's
`CreateProcessW` -- the same child ready in 51-98 ms when another is being
spawned. POSIX libuv opens its pipes close-on-exec and is not affected.

## F-96. The oracle hosting Softanza's engine mapped the official ring.dll

A Windows library must NAME the module its imports come from. Mansour's
engine is built against an installation's `ring.lib`, which names
`ring.dll`; the oracle is one binary, `runtime/win64/ring.exe`, with no
`ring.dll` beside it -- so loading an engine library it resolved `ring.dll`
through the PATH and mapped `D:\Ring127\bin\ring.dll` into the process
(listed from a running oracle). Every engine call Softanza makes on the
oracle ran Ring's API out of the official installation, and with
`D:\Ring127` off the PATH the oracle could not load the engine at all: R38.
The zip extension was never affected -- `tests/b2_runtimes.ps1` links it
against the oracle's own import library, which names `ring.exe`.
`bench/engine_copy.py --oracle` builds the engine that way on Windows now;
that build loads with `D:\Ring127` off the PATH and maps nothing of it.
The oracle's cached transcripts were all taken the old way; moving the
oracle onto that build is a change of instrument, and lands with a refill.

## F-97. An engine C pointer answers to its C type's name

A value a bridge returns through `ring_vm_api_retcpointer` is a C pointer on
Ring: `type()` answers the C type the bridge named (`HtmlDoc` for
`StzEngineHtmlParse`), `isPointer` 1, `isNumber` 0, and `!= 0`, `!= NULL` and
`not isNull()` all answer 1. An empty document is still a pointer -- the
parse of "" is an `HtmlDoc` with no elements -- so `isPointer` says nothing
about whether a parse worked. 535 return sites in 25 of Softanza's bridges
use this form, every string, list and matrix handle among them. Both 1.27
builds, 2026-10-03: the oracle on the snapshot with no Ring installation on
its PATH, and official Ring from his tree. Ring++'s answer is C-22.

## F-98. A number plus the newline alone is TEXT

`ring_vm_sum` (vendor/ring-vm/src/vmexpr.c:27, "string/number + nl --->
string"): with a number on the left and a string on the right, `+` converts
the string and adds -- unless the string is exactly "
", when the answer is
the number's text followed by the newline. `5 + nl` is the STRING "5
",
`2.5 + nl` is "2.50
" (decimals() applies), `10 / 4 + nl` "2.50
"; `5 + "3"`
and `5 + " 3"` are 8; `5 + ("3" + nl)` is 8 too, the conversion taking a
trailing newline; `5 + " "`, `5 + char(9)` and `5 + (" " + nl)` are R41. Only
`+`: `y += nl` on a number is R41 -- the second place `+` and `+=` part
(F-51). Both 1.27 builds, 2026-10-05, `bench/exec/plus_nl.ring`. Softanza
writes `? n + NL` across its suite; Ring++ raised R41 on every one.

## F-99. random() is C's rand(), seeded from the clock in seconds

Ring seeds C's generator once as it starts, `srand(time(NULL))` (state.c:532),
and `random(n)` is `rand() % (n + 1)` with n cut toward zero
(math_e.c:463): rand() is drawn FIRST, so a call that then raises has used a
number up. `random(0)` is 0, `random(-5)` the NEGATED draw `-(rand() % 6)`,
`random()` the raw draw, a bound past the int range or NaN "Bad parameters
value, error in range!", a string "Bad parameter type!". `srandom(n)` is
`srand(n)` for 0 <= n <= 4294967295 and the same range error otherwise, and
answers NULL. So two runs of an unseeded program in the same second draw the
same numbers, and different ones a second later (on the oracle: 11, 42, 51
on two runs inside one second). After `srandom(n)` the draw is the C runtime's sequence for n:
on Windows the oracle (zig cc, mingw) and the official build (MSVC) agree on
it -- 41, 85, 72 for random(100) after srandom(1). Both 1.27 builds,
2026-10-05, `bench/exec/random_c.ring`.

## F-100. An object read from a list, as the RIGHT operand of an overloaded operator, ends Ring with no message

`o + aF[1]`, where `aF[1]` is an object whose class (or o's) has `operator`, ends Ring 1.27 with exit code 1 and
NOTHING on either stream -- no error, so no `try` catches it and Ring's tracer sees no error event: the last trace
event is the instruction before. Both builds, the oracle and official, measured 2026-10-08 (`0x00000001`, empty
stderr). It is the operand's SHAPE: `o - aF[1]`, `aF[1] + aF[1]` and `o + (aF[1])` die too; `y = aF[1]` then
`o + y`, the list's object on the LEFT (`aF[1] + o`), an object read from an attribute (`o + oH.p`) and a NUMBER
from a list (`o + aN[1]`) all answer. The operand reaches the generated call to `operator` as a pointer to a list
ITEM in `ring_settemp_var` (vendor/ring-vm/src/vmoop.c:1125), where a variable takes the other branch; the line
that ends the process is not traced. Softanza met it in base/test/duration/11 (`oTotal + aTask[2]`); Ring++
answers -- C-24.

## F-101. A load whose file cannot be opened stops Ring before anything runs; Ring++ ran on without it

`load "LIBB.ring"` where only `libB.ring` exists, on a case-sensitive Linux disk: Ring 1.27 (the Linux oracle)
prints `Error (E9) : Can't open file LIBB.ring`, then `Line (1) Error (C27) : Syntax Error!` and the error count,
and exits 1 having run NOTHING. rnxc printed `note: could not read LIBB.ring (FileNotFound)` on stderr, compiled the
rest, ran it, and stopped later with R3 on the first function the missing file would have defined. Measured
2026-10-09 under WSL. It was a divergence of Ring++'s, and the cost of the leniency was already known --
the Linux package check of 2026-09-28 ("relocated into WSL's own /tmp, a program in a third folder answers a sort,
a string call and an eval'd calculated row") passed with base/file/stzJsonFuncs.ring missing, because the load that
names it spelt it `stzjsonfuncs.ring` and rnxc ran on. Ring would have refused that program outright. DECIDED 2026-10-09 (C-25): Ring++ refuses it the same way now.

## F-102. An error inside a C function names it first; an error inside an eval'd string is reported at the eval

Ring prints `In <name>() ` for every C function frame on the call stack before the Ring frames
(vendor/ring-vm/src/vmerror.c:155), and a builtin holds that frame while it runs. So an uncaught error a builtin
raises reads `In find() In method m() in file F`, and `In left() in file F` at the top level. It is the name the
function was CALLED by, lower-cased: `reference(5)` reports `In reference()`, not `ref`. An error before the call
gets none -- R3 at the name, R24 at an argument -- and neither does an operator's (`1 + [1]` is R21 with no prefix).
Twenty-six builtins measured, every one gets it: left, substr, find, sqrt, number (R41), lower, upper, assert (R48),
del, insert, add, classname, list (the range error), dir, sort, getattribute and setattribute (R12), char, read
(R35), fread (NULL pointer), hex2str, copy, trim inside stdlibcore's split(), and a caught error followed by an
uncaught one. EVAL IS THE EXCEPTION, and it decides the second half: Ring compiles the string and runs it after
eval() has returned, so no `eval()` frame is ever shown, and every line of the string -- the third line of a
three-line string included -- is reported at the line of the eval CALL, inside the caller's function; a function
the string calls reports `Called from` that same line. An eval inside an eval's string is reported at the outer
call. The only `In eval()` is eval's own failure to compile: Ring prints the string's C27 lines, then R42 `Error in
eval() function` In eval(). Both 1.27 builds agree; 39 probes, 2026-10-09. Ring++ printed no builtin frame at all,
and reported eval'd code as `Line 0`, `in file F`, every frame below it lost: eval'd code sits past the line table.
`bench/exec/cfn_*.ring` and `eval_line*.ring`.

## F-103. A C function's error is an ordinary Ring error -- a bridge's included

When a C function raises -- a builtin through RING_API_ERROR, an extension's bridge through `ring_vm_error` -- Ring
reports the text exactly as the function wrote it, `Line N <text>`, with the function's frame in front (F-102), and
a `try` catches it like any other. `read()` of a file that will not open is `Error (R35) : Can't create/open the
file` (vendor/ring-vm/src/file_e.c:494); `write()` into a folder that does not exist is the same R35 (:532), and
`write()` of a text that is not a string is "Bad parameter type!" (:539), checked before the file is opened, so no
file is made. Softanza's engine raises the same way: an expression `FindAllW` cannot compile reports `Line 5022 W:
the expression does not compile -- refused, not answered empty` `In stzenginelistfindallw() In method
findallitemsw()` (base/test list/546, list/595, string/83; list/339 through `StzEngineListMapExpr`). Ring++ ended
the process on all of them -- `Error: Can't create/open the file`, `Error: native call failed: StzEngineListFindAllW`
-- uncatchable, the engine's text lost, and panicked on the third `write()`. Both 1.27 builds, 2026-10-09,
`bench/exec/read_missing.ring` and the bridge check in `bench/bridge.ring`.

## F-104. A comment inside a statement moves no line Ring reports

Ring's scanner drops a comment where it stands, so a statement's instructions report the lines they are on whether or not a `#` sits
inside it: in `o {` / `M(5)` / `? C()` / `#--> 1` / `}`, an error inside M reports `Called from line` M's own line, exactly as it does
without the comment. Ring++ compiles a statement holding such a comment from a re-read copy (F-80), and every instruction of that copy
reported the statement's FIRST line -- the brace's. 17 brace shapes measured on the oracle, 2026-10-10: the three with a comment inside the
brace differed, the fourteen without agreed. Softanza's base/test/list/546_removew is the shape (`RemoveW(...)` then `? Content()` then a
`#-->` line), `Called from line 17` where Ring says 18. `bench/exec/brace_comment_line.ring`.

## F-105. len() and `for x in` ask an object; a for-in over a number is R29 at its own line

`len(o)` on an object calls the class's `operator("len", 0)` and answers what it returns (genlib_e.c:1098); `for x in o` calls
`operator("len", 0)` before every turn and `operator("[]", i)` for each item, a final `"len"` ending the loop, and writes nothing back into
the object (vmstack.c:794). Without an `operator` both are R50 -- len()'s with `In len()` in front. A for-in over a number is `Error (R29) :
Using bad data type in for loop`, catchable, reported at the `for` line; over a string it walks the characters, over NULL it runs zero times.
`ref()`/`reference()` take a list or an object and are "Bad parameter type!" otherwise (list_e.c:737); `refcount()` of anything that is not
a list is 1 (:757). Ring++ answered "Bad parameter type!" for all of the object shapes, raised the for-in's error a line late (the bound is
tested after the body), handed `ref()` any value back, and answered a string constant's refcount as 1,073,741,825 -- the VM's pin. Both
1.27 builds, 2026-10-10, `bench/exec/forin_object.ring`, `len_object_noop.ring`.

## F-106. `?` ends a list with a blank line, and prints an object as its attributes

`? aList` prints the items a line each, a nested list's in place, and then the newline of the `?` itself -- a BLANK line after the list;
`see aList` adds none, and `? []` prints that newline alone. An object prints as its attributes, `name: value` a line each in the object's
order (the parent's first, then the class's, then any addattribute() added), the name lower-cased, a number as `?` prints one, a list
attribute as `[This Attribute Contains A List]`, an object one as `Object...`; `?` adds the blank line after an object too, and an object in
a list prints its attributes in place. Ring++ dropped the closing blank line and printed `<object>`. **No instrument could see the first
half**: exec.py, clock34 and why432 all compared lines with the blank ones dropped. Compared with them kept, 180 rows of the wide suite
stopped agreeing on the cached output of the build before -- 3,505 -> 3,326 -- most of them a `? aList` before the harness's timing line.
Both 1.27 builds, 2026-10-11, `bench/exec/print_list.ring`.

## F-107. A name an eval assigns is a variable of the frame it runs in -- a global at the top level

`eval(cName + " = 7")` in a function, the name built at run time and declared nowhere, makes a variable of that FRAME: a later
`eval("? " + cName)` prints 7, the function's own code reads it, `+=`, `al + 2` and `add(al, 3)` work on it. A callee does not see it
(R24 there), and each call starts fresh -- a read before any assignment is R24 naming it. At the top level it is a GLOBAL that every
function reads. Ring++ took only a name spelt in the eval string's literal prefix (F-72's pre-declaration): any other was an E1 refusal, or,
in a function, a register of the eval's own that died with it; and a pre-declared one read before an assignment in a later call gave NULL.
Kept as it was, under C-2: an eval in a function assigning a name the TOP LEVEL has makes a local here, where Ring writes the global.
Both 1.27 builds, 2026-10-11, nine rows; `bench/exec/eval_dyn.ring`. Softanza's StzForEachObjectQ().Exec builds such names from a list of
variable names, which is how base/test/global/21_pr met it.

## F-108. An eval string that does not parse is Ring's compile report, then R42 from inside eval()

`eval("x = = 1")` prints `eval Line (1) Error (C27) : Syntax Error!` and `eval errors count : 1 ` -- each on a line that a newline opens
-- and raises `Error (R42) : Error in eval() function`, catchable; uncaught, the report has `In eval()` in front of the frame, since the
error comes from inside the C function (unlike an error in eval'd code, F-102). One line per error line, in order (two bad lines are two
and a count of 2). An unclosed structure is reported at the string's LAST line, where the parser ran out of input -- C3 'ok', C4 'end',
C5 next, C14 catch, C17 OFF, C18 a brace -- and C8 `)`, C7 a list's `]` at their own line. An unclosed literal is the scanner's error and
its own form: `Error (S1) In file: eval `, `In Line (1) Literal not closed `, `Called from other source code file` with no newline after,
and no count. And `$$` is a NAME to Ring, so `x = 1 $$ 2` is R24 for `$$`, not a syntax error. Ring++ raised an E1 of its own for every
one. Both 1.27 builds, 2026-10-11, sixteen rows; `bench/exec/eval_syntax.ring`.

## F-109. A file Ring's scanner cannot finish refuses the program before anything runs

A literal (`"`, `'` or a backtick, which only the same character closes, across lines and with no escapes) or a `/*` comment with no
`*/`, still open at the end of a file, is the SCANNER's error, and Ring runs nothing of the program -- not the lines above, not the root's
own first statement. The root: `Error (S2) In file: <name as typed> ` and `In Line (N) Unclosed comment ` (S1 and `Literal not closed` for
a literal), N the line where it OPENED, exit 1. A loaded file: the same two lines, naming it as a load names it, then `Called from other
source code file` with no newline, then the loading file's C27 at its load line and its error count, as for a missing load (C-25). A quote
in a `#` or `//` comment and a comment marker inside a literal are nothing. Ring++ compiled what the grammar could read and RAN it -- 26
programs of Softanza's base and max suites hold such a file, most of them work in progress with a comment never closed. Both 1.27 builds,
2026-10-12, eight shapes; `bench/exec/scan_bad.ring`.

## F-110. After `if ... else ... ok`, the next statement reports the line of the `but`/`else` its path came through

Ring's line is the last NEWLINE instruction it ran, and a newline that comes straight after another is MERGED into it
(`ring_parser_icg_newline`, codegen.c:134). The `ok` label is taken after the else body's last NEWLINE, so the next statement's newline
is merged into that one -- and every earlier branch's end-jump lands past it. Reached from the first branch or a `but`, the statement
(its first line only: a newline inside it is a marker of its own) reports the line of the `but`/`else` that ended the branch, in an error
and in a `Called from line` alike; from the else body, its own line. An if without else, a one-line if/else, `switch`, `try` and the
loops end with an instruction after the label and have no such case. A branch whose last statement is such an if passes on that if's
line, its jump landing on the enclosing jump. 36 shapes, both 1.27 builds, 2026-10-12; `bench/exec/else_line*.ring`. It is what 24 of the
wide suite's rows differed on: the harness's closing `pf()` written after an if/else.

## F-111. A report names a loaded file by the folder its load was resolved against and the load as written

`load "b.ring"` in `lib/a.ring` is reported as `<...>\lib\b.ring`; `load "sub/deep/c.ring"` as `<...>\lib\sub/deep/c.ring`;
`load "../up/u.ring"` as `<...>\lib\../up/u.ring` -- the folder as the process sees it after changing into it (an 8.3 short name
kept short, `..` in it resolved), the platform's separator, and the literal unnormalised, in the case it was written. The same rule
C-25's refusal report follows. Ring++ printed the real path of the file's own folder, `/` and its name: the same string only for a
load that names one folder and a file, which is how it was measured first. Both 1.27 builds, 2026-10-12; `bench/exec/load_names.ring`.
Softanza's `base/file/stzJson.ring` loads `stzJsonFuncs.ring` bare, so every trace through `listtojson()` named it.

## F-112. A frame's FILE depends on whether its call site has run before -- not reproduced, a decision pending

A trace frame prints `pFuncCall->cNewFileName`. The first time a call instruction runs, Ring finds the callee by name, makes the
callee's own file current and records it (vmfuncs.c:65-68). Then it REWRITES the instruction into a cached form -- `ICO_LOADFUNCP` for a
function (vmfuncs.c:909), `ICO_LOADMETHODP` for `o.m()` while the object's class stays the one cached (vmoop.c:382-390),
`ICO_LOADBRACEMETHODP` for a method called inside braces -- and the cached forms record the file that is CURRENT and leave it current
(vmperf.c:174-178, vmoop.c:460-462). So from a call site's second run on, the callee's frame names its caller's file, and so does every
frame below it reached the same way: `In method edgeproperty() in file .../stzGraphPlanner.ring` for a method of stzGraph, with the line
number of stzGraph.ring. Six probes that run each call site once all agree with Ring++; the estate's eight rows that differ this way --
graphplanner/28-30, table/173, 176, 177 and 216, extercode/test_extercode_regression -- reach their failing call sites repeatedly.
Ring++ names the file the code is in. Reproducing Ring's would put a per-call-site state, and a class cache for methods, on every call.
DECIDED 2026-10-13 by Mansour: keep Ring++'s name -- C-26, fix silently. 2026-10-12.

## F-113. After `if a or <operand ending in a literal>`, a true `a` leaves the body's first statement on the `if` line -- not reproduced

When the right operand of the last `or` in a condition ends in anything but an identifier -- a number, a string, `)`, `]` -- Ring's parser
has already passed the newline after it, and emitted the next line's NEWLINE, before it emits `ICO_OR`; the `or`'s short-circuit jump
(`ICO_JUMPONE2`, taken when the left side is true, expr.c:12-27) lands past that marker, so the first statement of the body reports the
line of the `if`. `if a or b` (an identifier last), `and` (whose jump is taken only when the body is skipped), and a body whose first
statement is not on the next line show nothing. 27 shapes on both 1.27 builds, 2026-10-12. Two to four of the wide suite's rows differ on
it (table/173's `Called from line 5832`). Reproducing it would put a line-clearing instruction on every `or` that does not short-circuit.
DECIDED 2026-10-13 by Mansour: keep Ring++'s line -- C-27, fix silently.

## F-114. A statement ending in a postfix construct is finished on the line of the next token

After `a[i]`, `f()`, `(x)` or `o.v` Ring's parser looks past the newline for a `.` that would continue the chain, and passing the
newline emits the next line's NEWLINE -- before the operators that complete the statement. So `x = 0 + aL[1]`, with aL[1] a string, is
R41 at the line of the next token: the next statement, or the `ok`, `else`, `next` or `func` after it, blank lines and comments passed,
or the line after a final newline; and an `operator` method called by that `+` is `Called from` that line. A literal, an identifier or a
list literal last does nothing, nor a next token on the same line, nor an operator inside a call's arguments. In a CONTROL STRUCTURE's
condition a literal ending does it too (so a brace may follow on the next line): `if _n1_ > 0`, with _n1_ a string, is R41 at the body's
first line -- NOT reproduced here, one row (listofstrings/08); its dynamic half is F-113. 28 statement shapes on both 1.27 builds,
2026-10-13; `bench/exec/tail_line.ring`, `tail_line_op.ring`. Five cluster workers spawned standalone die on `0 + sysargv[len(sysargv)]`.

## F-115. A `for` checks its step first, then its bound, then its start

A list step is R28 and a step that is text and no number R41, before anything else; then a bound that is text and no number R41 (a list
bound R29); then a start that is not a number R29. So `for i = :FirstRow to :LastRow` is R41, from the bound, where Ring++ raised R29,
from the start, which it checked first. 17 combinations on both 1.27 builds, 2026-10-13; `bench/exec/for_order.ring`. StzTableQ().Section
is that loop when its corners are symbols, which three table tests reach through Cells().

## F-116. A parameter holding a list or an object IS the caller's variable, through every assignment

`func f p` then `p = [9, 9]`: the caller's `x` is `[9, 9]` after `f(x)`. `p = NULL` leaves the caller holding the string `NULL`, a
different type; `p = new P { v = 42 }` replaces the caller's object. The same when the caller passed a list ELEMENT (`f(aL[1])`) or an
ATTRIBUTE (`f(o.aQ)`), and it lasts: `p = [7]` then `add(p, 3)` leaves the caller with `[7, 3]`. A number or a string parameter is a
copy, and assigning to it changes nothing outside; a literal argument is a temporary, so nothing is seen. So on Ring a list or object
parameter is not a local that starts as a reference -- C-7 measured the writes THROUGH it (`p[1] = 99`, `add(p, 3)`), never an assignment
TO it. Ring++ rebinds the local and leaves the caller alone. 11 rows on both 1.27 builds, 2026-10-13, every one the same on both. Found by
Ring's own samples in RingServ's sweep: ProblemSolving/Lists/sortFirst and sortSecond sort the caller's list with `aList = sort(aList, 1)`
inside the function, and doc snippet usingref-09 nulls it. In Softanza's library a line scan (archive copies and tests excluded) finds
148 functions, 169 sites, assigning to a parameter named for a list or an object -- most `paList = paList[2]`, the named-argument unwrap,
whose caller passes the `:Name = value` pair as a temporary -- and 1,673 sites on other parameters, which may hold anything; the 8,540
assertions Ring passes all pass on Ring++, so none of them depends on the write. NOT DECIDED: reproduce, or correct with a rule.

## F-117. Assigning to a character of a string writes it

`s = "abc"` then `s[1] = "X"` leaves `s` as `Xbc`, on both 1.27 builds, 2026-10-13; Ring++ raises `Bad parameter type!`. Ring's samples
capitalise a name that way (AQuickStart/Strings/strindex3, doc snippet strings-09). Not yet probed: a replacement longer than one
character, an index past the end, and a string held in a list or an attribute.

## F-118. After `ref()`, every copy of a list or an object shares it -- while it has a second named holder

Ring 1.21's references. `b = ref(a)` makes `a` a reference, and from then on every place Ring would COPY it shares it instead: an
assignment from a variable, a list item or a call's result (`x = aL[1][2]`, `w = g.Fetch()`), a list literal's item, `+`, add(), an
indexed store, and a sublist met while copying an enclosing list -- Ring's `ring_list_isref_gc` test at each copy site (vmstack.c:252,
vmlists.c:103/120/404/530, vmexpr.c:1226, vmfuncs.c:628). It lasts while the value has a second NAMED holder -- a variable, a list item,
an attribute; a parameter is not one, and neither is a temporary. With one holder left the flag lapses (vmgc.c:429-433) and an
assignment copies again: `r = ref(q)`, `r = NULL`, `s = q` gives `s` its own list. `refcount()` is that count of named holders, plus one
(vmgc.c:677): `k = 1:10`, `k2 = ref(k)` reads 2 for both. A list or object never passed to `ref()` is copied as always.

One shape leaves the count one high for good: a reference that goes through `+` inside a list LITERAL -- `aL + [id, ref(o)]`, as a
statement or inside an expression, at any depth of the literal. `add(aL, [id, ref(o)])` does not, nor a literal held in a variable first.
After it the value is shared at every copy even once its other holders have gone. Softanza's stkMemory is written against exactly that:
it registers a buffer with `@aBuffers + [cId, ref(_oBuffer_)]`, and later does `_oBuffer_ = @aBuffers[cId]` then
`_oBuffer_.ReleaseWritePointer()` -- on Ring the registry's buffer is released, because the local shares it.

Ring++ shared only at the `ref()` call itself and copied at every later assignment, so that local was a copy and the release was lost,
silently. Ten rows on both 1.27 builds, every one the same on both, 2026-10-14: `bench/exec/ref_share.ring`; the build before differs on
seven of them. Found through RingServ's sweep, and fixed rather than dropped because Softanza depends on it (C-28 names it as the one
sweep feature that is not Ring-only): doc snippets usingref-02, -04, -07, -11 and -12 agree with the oracle since (-07, a linked list
of references, was a copy walking its cycle until the 25 s cap). usingref-14 does not, and is not this: `a = [[ref(a), ...]]` reads
`a` inside its own definition, which is R24 here, and Ring prints the cycle as `[...] (RC:3)`.

## F-119. `for x in c step n` steps; and a step of 0 runs nothing, in either kind of `for`

Ring evaluates a for-in's step ONCE, before the loop (its code is inserted ahead of the loop's label, stmt.c `ring_parser_step`),
starts the index at 1, re-measures the container every turn, and leaves when the step is 0, or when it is negative and the index is
below the length, or positive and above it (vmjump.c `ring_vm_jumpfor`). So `for x in 1:10 step 2` visits 1 3 5 7 9, a string steps by
character, `step -1` over two or more elements runs nothing and over one element runs once, `[] step -1` is R2, and a fractional step
keeps a fractional index and reads the element at its integer part (`step 1.5` visits 1 2 4 5 7 8 10). A step that is text converts;
one that is a list is R28 and text that is no number R41. The numeric `for` uses the same test, so `for i = 1 to 3 step 0` runs nothing.

Ring++ compiled the step as the body's first STATEMENT -- the grammar gives it as the loop's third child and the body began there --
so a literal step was discarded and every element visited, and a variable step was refused; and a numeric step of 0 looped for ever.
22 rows on both 1.27 builds, 2026-10-14, every one the same on both: `bench/exec/forin_step.ring`. Found through RingServ's sweep (Ring's
sample stepinforinloop.ring, doc snippets controlstructures-14 and controlstructures3-14).

## F-120. A numeric `for` re-evaluates its bound on every turn

F-41 measured this for speed; it is also a rule. `n = 3`, `for i = 1 to n`, `n = 5` in the body: Ring runs to 5; lowered to 2, it stops
at 2. `for i = 1 to len(aL)` follows the list as the body grows or shrinks it, and a call as the bound is made once per turn plus once
more (4 calls for 3 turns). The step is read once (inserted before the loop, as for F-119). 8 rows on both 1.27 builds, 2026-10-14.
Ring++ evaluates the bound once, as Lua does by rule, so a body that changes it gives another answer -- and a body that deletes from the
list it walks by `len()` raises R2 here where Ring stops early.

**In Softanza it is one loop, and there Ring's answer is the library's defect.** A census of every numeric `for` in the library through
rnxc's lossless export (654 files, tests and archives excluded): 8,954 loops; no body adds to, deletes from or increments what its bound
reads; 72 write an ELEMENT of the bound's list (no length changes); 44 bounds call something other than `len()`, every one a pure
function or a count the body does not change (read); six bodies reassign a bound variable, and five of them either leave both loops
right after or restore the same value. The sixth is `StzTableQ().FindCellsCS`: its outer `for i = 1 to _nLen_` walks the values, and the
inner `_nLen_ = len(_aTemp_)` overwrites that bound with the number of cells found for the current value -- so on Ring the walk stops
once i passes that count, and the cells of the later values are never searched. Ring++ visits every value. Run on the library itself,
a three-row table where "sara" fills one cell: `FindCells(["sara", "ali", "paris"])` answers sara's one cell on official Ring 1.27
and all four cells on Ring++. (`FindCell` of a NUMBER raises on Ring, inside StzFindAllCS's argument check -- another of the library's,
not measured further.) DECIDED 2026-10-14 as C-30 (the bound is read once), and FindCellsCS fixed in his tree (e77bab17d).

## F-121. A class region runs whole at every `new`, and every name it assigns is an attribute

Ring runs the whole class region at each `new`, in order, before init: a `?`, a call, a loop, an `if`, `AddAttribute(self, ...)`. Every
name the region assigns becomes an attribute of the object -- inside an `if` too, and a numeric loop's variable, which holds the value
that ended the loop (`for i = 1 to 3` leaves `i` = 4) -- and attributes() lists them in that order. A parent's region runs before the
child's. Ring++ took only the region's assignments and bare declarations and dropped everything else without a word: `total` stayed 0
after a loop that sums into it, a name set inside an `if` did not exist (R12 at the read). 15 rows on both 1.27 builds, 2026-10-14,
every one the same on both: `bench/exec/class_region.ring`. Softanza has ONE such statement, counted by a traced build over the base
and max units: `vr(:say)` in stzExtinPerl's class say, which never ran. Found through RingServ's sweep (ringclasses, oop-35,
metaprog-49, scope-04, scope-20 to -24, dynamicattributes, oop-25, the playground's call-methods-braces).

## F-122. Two lambda values are equal when they name one function

On Ring a lambda IS the string of its generated name, so `f3 = f1` then `f1 = f3` is 1, `f1 != f3` is 0, `find([f2, f1], f1)` is 2,
two different `func { }` are never equal, and two calls of a function returning one `func` give equal values. Ring++'s lambda is the
vector [id + bias, captures...], the assignment copies it, and lists compare by identity -- so every one of those answered the other
way. 14 rows on both 1.27 builds, 2026-10-14: `bench/exec/lambda_eq.ring`. **Softanza depends on it**: `StzGraphQ()._GetFunctionName` names
a rule's function by comparing it with `DerivationFunc_Transitivity()` and its siblings, each a function returning one lambda. On
official Ring `_GetFunctionName(DerivationFunc_Symmetry())` answers `DerivationFunc_Symmetry`; on the package's Ring++ every built-in
rule was `CustomFunction`. Found through RingServ's sweep (doc snippet on lambda values).

## F-123. A string between backticks is its content

Ring has three string delimiters, `"`, `'` and the backtick, each closed only by itself. The constant table stripped the first two and
KEPT the backticks, so `` `x` `` was three characters with its delimiters in it -- silently: lengths, concatenations, `switch`, a list
item and the code handed to `eval` all carried them. 11 rows on both 1.27 builds, 2026-10-14: `bench/exec/backtick.ring`. Ring's
samples write strings that way (AQuickStart/Strings/stringliterals.ring, doc snippet strings-01); Softanza's library has none and its
tests 84, counted with Ring's scanner rules.

## F-124. Inside a brace the object scope is the brace object's

In `obj { ... }` Ring resolves a bare name as a local or as the BRACE OBJECT's attribute, a bare call as that object's method or a
global function, and `self` as the brace object, while `This` stays the method's own object. The enclosing method's attributes and
methods are not visible there: inside a method of Host, `new Pt { x = 100 }` makes a new local x and leaves self.x alone, reading
Host's `y` is R24, `Hello()` calls the global function though Host has a method of that name, `Hello2()` (Host's only) is R3, and
`classname(self)` is pt where `classname(This)` is host. A top-level or function brace sees `self` the same way. Ring++ put the
enclosing class first for all of these -- a brace in a method wrote the object's own attribute, read one where Ring raises, called
the class's method instead of the function -- and read `self` as This. 10 rows on both 1.27 builds, 2026-10-14:
`bench/exec/brace_scope.ring`. **Softanza has no site of any of these shapes**, counted by a traced build over the base and max units
(an enclosing-attribute read or write, an own-method call, or `self`, inside a brace). Found through RingServ's sweep (scope-07,
scope2-01, scope2-02, scope-26).

Not reproduced, and named: a brace's bare write to an attribute ADDED at run time (addattribute) -- Ring writes it, Ring++ makes a
local (metaprog-50; Softanza's library writes such attributes with setattribute); Ring's `BraceError()` (called on an error inside a
brace, the program resuming after the failed instruction -- Ring++ raises the error, the louder side; stzReactiveObject defines one);
and `braceExprEval()`/`braceNewLine()`, which Ring calls after every expression statement and at every new line inside a brace whose
object defines them (Ring's natural-language samples are built on them; Softanza defines neither) -- silent here, and not built.

## F-125. `loop` inside `do ... again` restarts the body without the test

F-62 recorded `loop` there as jumping to the re-test, from a probe whose condition was still true at the `loop`, where both readings
give the same answer. With the condition false: `do x++ if x < 10 loop ok ... again x < 5` runs the body until x is 10 on Ring and
stops at 5 with a re-test. Ring's parser sets the loop mark to the body's own label (stmt.c, `nMark1`). Both 1.27 builds, 2026-10-14;
row 4b of `bench/exec/do_again.ring`. Neither Ring's `Split()` nor Softanza's library has a `loop` inside one.

## F-126. An indexed assignment reads its index before its right-hand side

`i = 1  aL[i] = i++` writes aL[1] (with 2, the pre-increment of F-64) and leaves aL[2] alone; `aL[i] = eval("i = 3 return 7")` writes
aL[1]; `aL[i] += i++` with i at 2 adds 3 to aL[2]. So whatever the right-hand side does to the index, the element written is the one
the index named before it ran. Ring++ always matched, because it copied the index into a temporary first. The rule became a constraint
on 2026-10-15, when a local index began to be read in place (to drop that copy): `vset` reads its index after the right-hand side, so
the index is read in place only when that side can move no local -- no `++`, no `eval`, no brace, no `new`. Both 1.27 builds; rows
r3, r4 and r6 of `bench/exec/index_inplace.ring`, which fail on a build that reads the index in place regardless.

## F-127. A rooted load is tried as written first -- on Linux, an absolute path is itself

Ring resolves `load "/x.ring"` in three steps (vendor/ring-vm/src/stmt.c:290-302): the path AS WRITTEN, then `<exefolder>` plus
it, then `<exefolder>load/` plus it. On Windows `/x.ring` names the root of the current drive, where nothing usually is, so the load
folder answers -- that is the measurement of 2026-09-10 (C-4's table, "`<exefolder>/load/x.ring`, never the root"), and it is how
the stdlib shims reach `/../../libraries/stdlib`. On Linux `/x.ring` is an ABSOLUTE path and step one finds it. rnxc read every
leading `/` as the load folder, so on Linux no absolute load was ever found: the program was refused (C-25), and every node and
worker script Softanza generates -- stzNodeApp, stzAppCluster, stzAppBackend load the library by an absolute path -- died at birth.
Nine wide-suite tests passed 782 of the Linux oracle's 862 assertions for it; 860 now. The loader, the name it reports
(`ringLoadName`) and the splice (`loadTarget`) take the three steps in Ring's order. The guard is Linux only, in
bench/exec_wsl.py: a root loading a library by its absolute path, which loads another the same way; the released v2.0.0 rnxc
refuses it, the oracle and the fix print the same seven lines.

## F-128. A `load` inside a block runs its file's top level where it stands, each time it is reached

Both 1.27 builds, bench/exec/load_block.ring: a load inside an `if` that is taken runs the loaded file's top level right there
(a global it sets is read on the next line); a load inside an `if` never taken runs nothing, yet the file's functions are
defined; a load inside a three-turn `for` runs the file's top level three times. A load inside a block that names a missing
file refuses the whole program, nothing running: E9, then the innermost block reported unclosed -- `if` C3 'ok', `while`
C4 'end', `for` C5 next -- and a cascade of error-recovery lines that depends on the nesting. Ring++ followed top-level loads
only: a nested load's file was never in the unit (R24 at the read, R3 at the call). The loader follows every load outside a
function or a class, in source order; such a file's top level stays in @@main's statement list, so every pass before code
generation sees it, and code generation emits it at the nested load instead (`nested_stmts`, `nested_skip`). A missing
nested load prints E9 and the innermost block's C-line, exit 1 -- the cascade after that is NOT reproduced line for line. The
estate's one site, neural/neural_backbone (`load "bert_parity_expected.ring"` under `if fexists(...)`), now passes its 14
checks; it stopped at the first.

## F-129. `floor(a / b)` is the floor of the REAL quotient

`floor(14.15 / 1.9)` is 7 on both 1.27 builds; `floor(-7 / 2)` is -4, `floor("9" / 2)` is 4, and a zero divisor is R1
`Can't divide by zero`, catchable. Ring++ compiled every `floor(a / b)` to its integer-division opcode, which reads both
operands as integers -- 14 / 1 -- so Softanza's spectrum plot (StzSoundPlotQ().DrawSpectra, `floor(_pw_ * (log10(_hz_) -
_lf_) / (_lt_ - _lf_))`) put every column at twice its pixel and drew 154 points of Ring's 442, silently. The opcode is
emitted only when both sides are proved integers now, and the VM floors the real quotient should anything else reach it.
bench/exec/floor_div.ring, which v2.0.1 gets wrong on three rows and stops at the fourth; ten million integer floor
divisions 0.136 s before and 0.131 s after, minima of seven.

## F-130. A `not` binds below a comparison and arithmetic, above `and` and `or` -- and a statement's first `=` is an assignment

Both 1.27 builds, bench/exec/not_precedence.ring (71 lines) and not_precedence_objects.ring: with `a = 0` and `b = 5`, `? not a = b`
is 1, `? not a + b` 0, `? not a < b` 0, `? not a * b` 1, `? !a = b` 1, `? 1 and not a = b` 1, and `if not a = b` takes its
branch -- `not` takes the whole chain of operators as tight as `=` or tighter, and `and`/`or` end it (`not a and b` is
`(not a) and b`). Ring's own parser says so (vendor/ring-vm/src/expr.c): `Expr -> LogicAnd {or LogicAnd}`, `LogicAnd -> LogicNot {and
LogicNot}`, `LogicNot -> [not] EqualOrNot`, where `EqualOrNot -> Compare {=|!= Compare}` -- the rule does not recurse, so `not not a`
and `a = not b`, `a + not b`, `- not a` are the error C28 `Expression is expected`, and the parenthesized forms (`(not a) = b`,
`a = (not b)`) are fine. tree-sitter-ring binds `not` and `!` like a unary minus, tighter than every binary operator (its table
names PREC.NOT = 4 and never uses it), so rnxc, the formatter and the graph read `(not a) = b` and answered 0, 6, 1, 5, 0 and
0 where Ring answers 1, 0, 0, 1, 1 and 1: a silent wrong answer. **The estate holds 35 sites in 21 of the 612 files of Softanza's
unit** (20 with `=`, 12 with `>`, 2 with `>=`, 1 with `<`; `not` is the left operand in every one), one of them in Ring's own
stdlibcore.ring (`Not sNthElementType = sElementType`): `if NOT len(pacStr) > 1` in StzStringsAreEqualCS raises on Ring for one
string and never did here; `if NOT _nLen_ = 2` in IsCaseSensitiveNamedParam and `if NOT len(paList) = 2` in IsTree are the same
guard. **The one exception is a statement.** A plain expression statement is parsed with Ring's assignment flag up
(`lAssignmentFlag`, expr.c; `if`, `elseif`, `while`, `for`, `return`, `?`, an argument, the right of an assignment and a
parenthesis clear it): there an identifier followed by `=` is an ASSIGNMENT wherever the `not` stands. On a line of its own
`not a = b` sets `a` to `b` (`a` is 5 afterwards), `not a = b and c` sets it to `b and c`, and `not Id(a) = b` is R34 `Variable is
required for the assignment operation`; `not a + b = c` assigns `b`. rnxc refuses such a statement, loudly, as before.
Separate, found on the way and not touched: `not o` on an OBJECT calls the class's `operator("not")` and answers its result on
Ring (`? not o` answers 7 from an `operator` that returns 7); rnxc negates the object's truth and calls nothing.
Correction: C-32.

## F-131. `new K()` on a class with no `init` makes the object on Ring++ and raises R3 on Ring

Both builds, `haro/spike/v22/scratch/probe_new.py`: `o = new K()` where class K declares no `init` -- Ring 1.27 (the oracle) answers `Line 1 Error (R3) : Calling Function without definition: init`
(the parentheses ask for the constructor call, and there is none); **rnxc makes the object and the program goes on**. Without parentheses (`new K`) both make it and neither calls `init`; with an `init`,
`new K()` and `new K(1)` call it on both. So Ring++ is **more permissive** at the one shape: a program that runs on Ring never meets the difference (Ring stops there), and a Ring++ program that
relies on it does not run on Ring. Found by the K4 study, whose face writes `new(Name)` (the constructor call) and which a model reaches for on a class with no `init`; the cloud models' rows rose from 19 to 20 of 20
when the baseline moved from the oracle to rnxc for this alone. **Decided 2026-10-21 as C-33: keep** (the permissive side cannot fail a program that passes on Ring), and let Haro refuse it loudly -- its `new(Name)` is the constructor call (D24: one exact spelling, refuse loudly).

## F-132. `rnxc check` read the right of an assignment by its children: a member name was an unassigned variable, a lone name was never read

`x = $oBox.nHits` in a function was reported `rpp/uninitialized-variable` -- "nHits is read here, and nothing anywhere assigns it -- Error (R24) the moment this line runs" -- on a program
that runs and prints (`tests/fixtures/uninit_member.ring`: the oracle runs it clean). `$oBox.nHits = 5` and `f($oBox.nHits)` did the same, and `x = y.z` reported `z` as well as `y`. And the
opposite: `x = nTypo`, a lone name on the right that nothing assigns, was **never looked at** -- a real R24 (`tests/fixtures/uninit_rhs.ring`: Ring stops there, `Using uninitialized variable:
ntypo`) that no check reported, while `x = nTypo + 1` was. The walk of an assignment (`walkReads`, `src/types.zig`) handed each non-target child to `walkReads`, which reads that node's
CHILDREN: for a member expression that skipped the member rule (the head is a read, the property is an attribute name), and for a bare identifier it read nothing at all. One function now
reads one child (`readChild`) and both the loop and the assignment use it. Found by the body gate's adversarial court (`haro/spike/v20/agent/bypass_court.py`): the derivation stage refused
the body `x = $oBox.secret`, and the refusal was for the wrong reason -- so the direct getter read looked safe until the mistake was fixed. **Fixed, not decided** (a checker false positive is
a defect): both fixtures fail on the build before and pass after, held to the oracle (`uninit_member` as clean, `uninit_rhs` as the line Ring stops on); the checker gate is 20 fixtures and
38 rules; `rnxc check` on Softanza's 612 files reads the same (16 errors, 23 warnings, 930 perf, 5,315 notes, before and after -- the rule is shut on that unit, which loads a library and
evals). Cost: none at run time; the checker only.

## F-133. `rnxc check` never reported a builtin's name, or a name the program defines, read as a variable

`nR = floor + 0.5` in a function: Ring raises `Error (R24) : Using uninitialized variable: floor` on the oracle and on rnxc; `rnxc check` said nothing. The rule (`rpp/uninitialized-variable`, F-47) exempted every BUILTIN's name and every name the unit
DEFINES -- functions, methods, classes -- though F-47's own pinned semantics say "a function name is not a value". Measured on 1.27: a function's name read bare, a class's name read bare, the function's own name indexed (`zerolist[x] = 0`
inside `func ZeroList`): R24 each. The defined-names exemption was doing a second job, found by removing it: the walk hands a definition's OWN name to the read rule (`func F` reported as a read of F), and the grammar's misreading of
`return func t { ... }` -- a bare return and a braced definition named `t`, the shape the compiler learned to absorb on 2026-10-05 -- makes the lambda's parameter look like a read of that definition's name. Both are skipped by position now, and neither set
exempts a read. Found by a model: Qwen2.5-Coder-1.5B, told `floor()` was not allowed, wrote `floor + 0.5`, and rung 5's gate -- whose derivation stage is this check -- admitted it (HF-120). **Fixed, not decided** (a false negative
of a rule that claims a runtime error is a defect): `src/types.zig`; fixtures `uninit_builtin_name` and `uninit_def_name`, held to the oracle and failing on the build before; 477 Ring files of the repository give no new finding
(two did on the first version -- the lambda shape above -- and none after); the checker gate 22 fixtures, 41 rules, 9 confirmed by the oracle; gate PASSED. **Not covered, and not chased:** a method's name read bare inside its own class
(R24 on Ring; the checker silent before and after). Cost: none at run time.

## F-134. A native library's handle outlived its object -- on Ring, and on Ring++ in a second way

stzlib-security, reading PHP2Shell (CVE-2026-109618/9) against Softanza on 2026-10-22 (SECURITY-R16): a Ring copy of a destroyed engine object read freed, reused memory with no error -- the copy of a
destroyed ledger answered 1, then 0 once the memory was reused. On Ring that is the nature of `retcpointer`: it hands out a real pointer and every copy of the value keeps it. **On Ring++ it was a
second hole of the same shape.** The engine backend (`bench/ring_api_rpp.zig`) made a handle the raw ADDRESS, carried in the f64 the ABI already uses (2026-09-12, so an id would cross engine DLLs --
each DLL had its own table and id 5 of one was another object in the next); nothing could retire an address, so every copy of the number read the memory after its owner freed it. **Not the hole the report
named:** `cptr_tab` in `src/main.zig` is rnxc's own C-pointer family (`fopen` and its siblings). A native never receives one -- a `cptr` crosses the ABI as nil -- and it retires itself at `fclose`
(Ring NULLs the pointer, all copies share the index). The ledger the report measured went through the backend's handles. Found, in passing, that stzlib's security branch could not have built on Ring++ at all: its bridges call
`retHandleOnce`, `releaseParam` and `getHandleOrRaise`, which the backend did not export. **Fixed, and decided as C-34:** the host keeps one handle table (`src/handles.zig`), offered through the
HostApi (ABI 3: `handle_store`, `handle_resolve`, `handle_state`, `handle_release`, `handle_retire`), and the backend's handles are its ids. An id is `generation * 2^32 + slot + 1`, the same encoding stzlib's own
table uses; a release bumps the slot's generation so every copy is stale, a stale release is ignored, a library that frees a pointer without holding the id retires it by address. Proved: 9 unit tests (`zig test src/handles.zig`);
31 checks in `bench/bridge.ring` over two engine DLLs and a deliberately too-new third, each made to fail by three mutations of the backend; stzlib-security's own guard `stale_handle_narrated.ring` 13 of 13 on rnxc against a Ring++ build of its
engine (`bench/sec_guard.py`), and 10 of 13 when the host's release is made to retire nothing -- the three stale-copy assertions are the ones that fail.

