# Findings for the Ring community — draft text

> **SUPERSEDED — see [`upstream/`](../upstream/README.md).**
>
> Every item here has been turned into a ready-to-send artifact, one folder
> per finding, each with a concise PR body and a verified patch where a fix
> is clear. This file is kept as the longer reasoning behind them.
>
> | this file | now lives in |
> |---|---|
> | Draft 0 | [`upstream/memcpy-nul-source/`](../upstream/memcpy-nul-source/) — **sent**, [#1643](https://github.com/ring-lang/ring/pull/1643) |
> | Drafts 1 + 4 | [`upstream/pointer-api-docs/`](../upstream/pointer-api-docs/PR_BODY.md) |
> | Draft 2 | **DO NOT SEND** — already applied upstream, see below |
> | Draft 3 | withdrawn, duplicate of RingScript's item 5 (merged as #1642) |
> | Draft 5 | defers to RingScript's item 3 |
> | *new* | [`upstream/empty-catch-stack/`](../upstream/empty-catch-stack/PR_BODY.md) |


**Not sent. No pull request, no issue, ever.** These go to the Ring
Google Group, posted by Mansour, when and if he judges them ready.

Findings in the order I would post them: **the crash first** — a real
bug with a one-line fix — then the traps, then the documentation gaps,
then the design question.

> **Checked for duplication against the RingScript session, August 12,
> 2026** (`ringscript/docs/upstream/`). Result: **Draft 3 is a duplicate
> and is withdrawn** — `ringvm_genarray` was already carried by their
> item 5, merged as #1642. **Draft 5 defers** to their item 3, which is
> drafted and not yet sent. Everything else here is new.
>
> Their `upstream/README.md` also records two facts worth repeating:
> `ring-lang/ring` **has issues and discussions disabled**, so the only
> channels are PRs and the Google Group; and Mahmoud develops Ring in
> **PWCT**, so *a finding travels better than a patch*.
>
> **And one discrepancy to settle.** That README states the no-PR channel
> decision as permanent — *"it does not expire and it is not reopened by
> a finding that feels important enough"* — and calls #1642 *"the last PR
> to this project"*. PR
> [#1643](https://github.com/ring-lang/ring/pull/1643) was opened from
> this session on Mansour's explicit instruction. Both records cannot
> stand; whichever he keeps, the two repositories should say the same
> thing.

Every claim below was reproduced on stock **Ring 1.27.0**
(`D:\ring127\bin\ring.exe`, Windows 11 x64) with the programs in
[`bench/`](../bench). Line references are to `D:\ring127\language\src`.

---

## Draft 0 — `memcpy()` crashes when the source string starts with a zero byte

*Post this one first, and on its own. It is the only item here that is a
crash, and the fix is one line.*

> **Subject:** memcpy() aborts the process when the source string begins
> with a 0 byte (Ring 1.27)
>
> Hello Mahmoud, hello everyone,
>
> I ran into a hard crash — no error message, no line number, and
> `try`/`catch` does not catch it — while writing binary data through
> `memcpy()`. It reproduces in five lines on stock Ring 1.27:
>
> ```ring
> cBuf = space(64)
> p = varptr(:cBuf, "char *")
>
> memcpy(p, int2bytes(7),   4)     # 07000000  -> fine
> memcpy(p, int2bytes(256), 4)     # 00010000  -> process dies
> ```
>
> Also fatal: `double2bytes(1.5)` (`000000000000f83f`), the literal
> string `"NULL"`, and even `char(0)` copied as a single byte. It dies
> whatever the destination is — including when the destination is a
> plain string, which is the case where `memcpy()` otherwise does
> nothing at all.
>
> Reading the source, I think the path is this. In
> `ring_vm_generallib_memcpy()` (`genlib_e.c`):
>
> ```c
> if (RING_API_ISSTRING(2))   { pSrc = (const void *) RING_API_GETSTRING(2); }
> if (RING_API_ISCPOINTER(2)) { pList = RING_API_GETLIST(2);
>                               pSrc  = (const void *) ring_list_getpointer(pList, RING_CPOINTER_POINTER); }
> ...
> memcpy(pDest, pSrc, nNum);
> ```
>
> and `RING_API_ISCPOINTER(2)` reaches `ring_vm_api_ispointer()`
> (`ringapi.c:118`), which contains the convenience branch:
>
> ```c
> if (RING_API_ISSTRING(nPara)) {
>     /* Treat NULL Strings as NULL Pointers - so we can use NULL instead of NULLPOINTER() */
>     if ((strcmp(RING_API_GETSTRING(nPara), RING_CSTR_EMPTY) == 0) ||
>         (strcmp(RING_API_GETSTRING(nPara), RING_CSTR_NULL)  == 0)) {
>         ...
>         ring_vm_api_setptr(pPointer, nPara, pList, RING_OBJTYPE_VARIABLE);
>         ring_list_addpointer_gc(pVM->pRingState, pList2, NULL);
>         return RING_TRUE;
> ```
>
> `strcmp()` cannot tell an empty string from a binary string that
> merely *starts* with a zero byte, even though the VM knows the real
> length. So the argument is reclassified as a NULL pointer, the stack
> slot is rewritten, and the second `if` in `memcpy` overwrites the good
> `pSrc` with `NULL`.
>
> Two predictions I made from that reading, and both hold:
> `int2bytes(256)` dies while `int2bytes(7)` lives; `"NULL"` dies while
> `"NULX"` lives.
>
> Nothing else is affected — `len()`, `str2hex()`, `bytes2double()`,
> `left()` and `murmur3hash()` all handle the same string perfectly,
> because they use the recorded size.
>
> **Suggested fix**, which I believe preserves the intended behaviour:
> use the size the VM already has for the empty case, rather than
> `strcmp`:
>
> ```c
> if (RING_API_ISSTRING(nPara)) {
>     if ((RING_API_GETSTRINGSIZE(nPara) == 0) ||
>         ((RING_API_GETSTRINGSIZE(nPara) == 4) &&
>          (strcmp(RING_API_GETSTRING(nPara), RING_CSTR_NULL) == 0))) {
> ```
>
> This still lets a caller write `NULL` where a pointer is expected, and
> it stops a binary payload being mistaken for one. I have not opened an
> issue or a pull request; I am happy to prepare a test case in whatever
> form is most useful.
>
> A workaround for anyone hitting this today: pass the source as a
> pointer rather than a string —
> `setptr(q, getptr(varptr(:cVal, "char *")))` and then
> `memcpy(pDest, q, n)`. That round-trips correctly.

---

## Draft 1 — `memcpy()` with a string destination silently does nothing

> **Subject:** memcpy() into a Ring string is a silent no-op — worth a
> note in the docs?
>
> Hello Mahmoud, hello everyone,
>
> While studying Ring's low-level surface I ran into something that
> costs a while to diagnose, and I thought it was worth sharing in case
> others meet it.
>
> ```ring
> cDest = space(16)
> memcpy(cDest, "ABCDEFGH", 8)
> ? cDest        # ---> unchanged, and no error
> ```
>
> The same operation through a pointer works exactly as expected:
>
> ```ring
> cDest = space(16)
> memcpy(varptr(:cDest, "char *"), "ABCDEFGH", 8)
> ? cDest        # ---> "ABCDEFGH        "
> ```
>
> Reading the source, the reason is clear and is not a bug:
> `ring_vm_generallib_memcpy()` (`genlib_e.c:1457`) accepts a string as
> parameter 1 and uses `RING_API_GETSTRING(1)` as the destination, but a
> string argument reaches a C function through
> `RING_VM_STACK_PUSHCVAR` (`vm.h:230`), which copies the bytes onto the
> VM stack. The `memcpy` writes the copy, and the copy goes away.
>
> Both calls look like working code; one does nothing. Would it make
> sense either to document the pointer form as the only correct one, or
> to raise an error when parameter 1 is a string? I am happy to prepare
> either a doc patch or a test case if that helps.

---

## Draft 2 — `ring_state_findvar()` needs a lower-case name, and reports absence as `0`

> ## DO NOT SEND — 2026-08-14
>
> **This is fixed in Ring master and credited.** Mahmoud applied it as
> [`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094)
> with a test in
> [`ed69e68`](https://github.com/ring-lang/ring/commit/ed69e6824652025651638e6ee7d7262b2accba08),
> credited to Mansour Ayouni and Youssef Saeed. Posting this now would
> report a solved problem.
>
> It also came out **wider than this draft**: four functions, not one —
> `varptr`, `ring_state_findvar`, `ring_state_setvar` and
> `ring_state_newvar`. See [FINDINGS F-3](FINDINGS.md) for the table and
> for why folding the name yourself is correct on every version.
>
> The text below is kept only as the reasoning that led there.

> **Subject:** ring_state_findvar() — name case, and "not found" vs a
> variable holding 0
>
> Two small things about the embedding API called from Ring itself,
> which I have been exploring and enjoying a lot.
>
> ```ring
> st = ring_state_init()
> ring_state_runcode(st, "nTotal = 7")
> ? ring_state_findvar(st, "nTotal")   # ---> 0
> ? ring_state_findvar(st, "ntotal")   # ---> the variable list
> ```
>
> Ring is case-insensitive and folds identifiers to lower case when
> storing them, so a caller who writes the variable exactly as it
> appears in their own source gets a silent miss. Would it be reasonable
> for `ring_state_findvar()` to fold the name before the lookup, the way
> the rest of the language does?
>
> Related: `ring_vm_generallib_state_findvar()` (`genlib_e.c:1581`)
> returns the number `0` when the variable is absent, which a caller
> cannot distinguish from a variable whose value is `0`. Everything else
> in Ring uses `NULL` for this. Would returning `NULL` be acceptable, or
> would it break existing users?

---

## Draft 3 — **DUPLICATE. DO NOT SEND.**

> Checked against the RingScript session's upstream material on
> August 12, 2026. This ground is already covered by
> `ringscript/docs/upstream/proposal-5-list-random-access.md`, which
> names `ringvm_genarray(aList)` as the opt-in answer, carries the
> 962 ms → 20.6 ms measurement, and **was merged as
> [ring-lang/ring#1642](https://github.com/ring-lang/ring/pull/1642)**
> on August 10 — the `sort()` half accepted, the accessor half rejected
> with reasons that measured out correct.
>
> Re-raising it would be pressure, not help. The break-even curve below
> is still worth keeping *here*, as the evidence behind
> `RPP_INDEX_MIN_READS` and the `rpp/genarray-in-loop` rule — it is just
> not something to send.

<details><summary>kept for the record</summary>

### (not for sending) `ringvm_genarray()` documentation and its break-even

> **Subject:** ringvm_genarray() — measurements, including where it
> makes things worse
>
> `ringvm_genarray()` is, I think, one of the most valuable functions in
> Ring that almost nobody knows about. On a list of 80,000 items read in
> a permuted order:
>
> | | ms |
> |---|---:|
> | permuted read, no array | 1562–1579 |
> | after `ringvm_genarray(a)` | 16–17 |
>
> **~95×** (93–98× across runs). But it is opt-in for a good reason, and
> I want to publish the other half of the measurement rather than only
> the flattering one. On the same list, 300 rounds of *(one append + N
> permuted reads)*:
>
> | reads per append | plain | genarray each round | ratio |
> |---:|---:|---:|---:|
> | 1 | 3–4 ms | 30–65 ms | **10–16× worse** |
> | 5 | 14–15 ms | 47–64 ms | **3–4× worse** |
> | 20 | 53 ms | 32–74 ms | 0.6–1.4 (the crossover) |
> | 100 | ~300 ms | 35–77 ms | 0.12–0.26 |
>
> The break-even is around 10–20 random reads per mutation at this size,
> because `ring_list_newitembyitemsptr_gc()` (`rlist.c:205`) clears the
> cache — and therefore frees the items array — on every append past the
> first.
>
> This is exactly why making the array automatic would be the wrong
> move, and why the opt-in design is right. But because the invalidation
> is invisible from Ring, a user can call `ringvm_genarray()` and get a
> 16× regression with nothing to tell them why.
>
> Two questions, both genuine:
>
> 1. Would a documentation entry — the ~95×, the 10–16×, and "one append
>    drops the array" — be welcome? I can write it.
> 2. Would a read-only predicate (something like
>    `ringvm_hasgenarray(aList)`) be acceptable? It would let a library
>    detect that the array is gone and stop pretending. It changes no
>    behaviour and costs nothing when unused. I have no strong view; the
>    documentation alone may be enough.

---

</details>

## Draft 4 — `ptr2str()` reads past the end without complaint

> **Subject:** ptr2str() and out-of-range lengths
>
> ```ring
> cB = space(16)
> p  = varptr(:cB, "char *")
> c  = ptr2str(p, 0, 4096)   # ---> returns 4096 bytes, exit code 0
> ```
>
> `ring_vm_generallib_pointer2string()` (`genlib_e.c:1392`) range-checks
> both numbers against `UINT_MAX` but cannot know the real length, so
> the result is 4 KB of adjacent heap arriving as an ordinary Ring
> string, with no error.
>
> I do not think there is a fix at that level — the length genuinely is
> not knowable from a `char *`. But it may deserve a sentence in the
> documentation saying so explicitly, because the function is otherwise
> extremely useful: on a 500 KB string, `ptr2str(p, n, 10)` costs
> 0.09 µs where `substr(cBig, n, 10)` costs 12.5 µs, since `substr`
> receives a copy of the whole string. That is ~140× at this size, and
> the gap widens with the string.

---

## Draft 5 — the string-argument copy (defer to the RingScript case)

Already drafted with better numbers in
`D:\GitHub\ringscript\docs\UPSTREAM_CASE.md` (5,000× on native 1.27 for
20,000 `len()` calls on a 1 MB string). My independent measurement here
is consistent: **3,000 calls passing a 1 MB string to a one-line Ring
function cost ≈2,200 ms; the same 3,000 calls passing a pointer handle
cost 1 ms.** Lists already cross by reference; only strings pay.

**Recommendation: do not post this separately.** One case, one thread,
one set of numbers. Add the ≈2,200× as a second data point to the
existing draft if it helps, and leave the borrowed / copy-on-write
proposal where it is.

---

## What is deliberately not in any draft

- No proposal to change `RING_VM_STACK_PUSHCVAR` semantics from here.
  That is a language-semantics decision, it is already drafted
  elsewhere, and duplicating it would split the discussion.
- No proposal to make items arrays automatic, or to register them as
  memory blocks. The measurement in Draft 3 is the argument *against*
  it, and it is Mahmoud's argument, restated with numbers.
- Nothing about Ring++ itself. These are findings about Ring. If the
  library is worth announcing, that is a different post, later, with a
  working thing attached.
