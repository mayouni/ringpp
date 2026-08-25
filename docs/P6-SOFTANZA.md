# P6 — Softanza adoption: a finding and a proposal

*Written 2026-08-25. **This is not a patch.** Nothing in `stzlib` has been
changed. It is the reading that has to happen before anything is, because
half of what P6 asked for turned out to be done already and the other half
turned out to be worse than "not done".*

Read [PHASE_PLAN.md § P6](PHASE_PLAN.md) for the original framing. It said:

> Reimplement `stkBuffer.Write` and `stkPointer` on `RppBuffer`. **Gate.**
> Softanza's own memory-framework tests pass unchanged, and the
> `stkBuffer.Write` benchmark drops from the 803 ms shape (F-7) to the
> in-place shape. Also: `stkPointer.InitializeLowLevelAccess` either works
> or is deleted — it must not go on silently returning `NULL`.

Both halves need restating. One is finished; one is broken in a way the
plan did not anticipate.

---

## 1. `stkBuffer.Write` — already done, and done by the doctrine, not the library

`libraries/stzlib/core/system/stkBuffer.ring:88` no longer has the 803 ms
shape. It carries an in-place fast path, and every decision in it lands on a
number Ring++ measured independently:

| what `stkBuffer` does | the finding it matches |
|---|---|
| `@nInPlaceMin = 512` — below this, rebuild instead of `memcpy` | **F-8**, the 512-byte crossover for sequential writes |
| takes the address **fresh every call**, with a comment saying a cached one would go stale when `Prepend`/`Insert`/`Resize` reallocate | **F-22**, an address cached inside an object becomes dangling |
| routes a source whose first byte is zero, or the literal `"NULL"`, through a pointer instead of handing the string to `memcpy` | **F-14** / [ring-lang/ring#1643](https://github.com/ring-lang/ring/issues/1643) |
| reads `@nSize` rather than `len(@buffer)`, with a comment that the call copies the whole buffer | **F-5**, the by-value tax applies to builtins too |
| `varptr("@buffer", "char *")` — the attribute's real name includes the `@` | **F-2**, `varptr` takes a runtime name |

**It does this without loading Ring++.** The only occurrence of the string
`ringpp` in the whole library is a comment on line 17 citing
`ringpp/bench/workload/` as the source of the 512.

That is worth saying plainly, because it changes what P6 is for. **The
findings transferred; the dependency did not.** For two projects that both
claim to be dependency-free, that is the good outcome, not a gap. Five
separate decisions converged on the same numbers from a different codebase —
which is the strongest evidence available that the numbers are right.

**So the `stkBuffer` half of P6 is closed on performance grounds.** What
remains is a consolidation question, and it is genuinely open in both
directions:

- **For adopting `RppBuffer`:** one audited implementation instead of two.
  The bounds checks, the `Grow` discipline and the NUL routing are written
  once and gated once, in a repository whose whole job is to keep them
  correct against a moving VM.
- **Against:** `stkBuffer` would take a dependency it does not have today,
  to replace working, measured, commented code with equivalent working code.
  The pointer discipline is already correct here. Rewriting it buys
  maintenance consolidation and risks a regression in a core type.

**Recommendation: do not rewrite `stkBuffer.Write` for P6.** Revisit only if
a third implementation of the same pointer discipline appears in the estate —
*that* is the duplication worth paying to remove.

---

## 2. Finding S-1 — `stkPointer`'s low-level access has never once worked

`libraries/stzlib/core/system/stkPointer.ring:720`:

```ring
def InitializeLowLevelAccess()
    try
        _oBuffer_ = @oMemory.GetBufferById(@cBufferId)
        if not IsNull(_oBuffer_)
            _cBufferData_ = _oBuffer_.Content()
            if len(_cBufferData_) > 0
                @pLowLevelPtr = varptr(:cBufferData, :char)     # <-- the local is _cBufferData_
                @nBaseAddress = getptr(@pLowLevelPtr)
            ok
        ok
    catch
        @pLowLevelPtr = ""
        @nBaseAddress = 0
    done
```

The local is `_cBufferData_`. The `varptr` asks for `cBufferData`, which
exists nowhere in the file — grepped, one occurrence, this line.

**Measured, not reasoned about.** On Ring 1.27:

```
varptr(:cLocal, :char) where the local is named _cLocal_
  --> RAISED: Error (R6) : Variable is required
```

That raise is caught by the `catch` directly beneath it, which sets
`@pLowLevelPtr = ""`. The class then guards every low-level path on exactly
that value — `GetMemoryAddress` (:456), `GetViewAddress` (:464),
`ComparePointers` (:479), `IsNullPointer` (:487), the offset arithmetic
(:138–145), `MoveTo` (:501). **All of them have taken the fallback branch
since the file was written.** The feature is not intermittent; it is dead,
and it fails silently by construction because the `catch` is the designed
path.

This is the same shape as the `encrypt_ex` defect `ringpp check` found in
Ring's own standard library: a function that cannot ever have run, sitting
in shipped code, with nothing static looking at it.

### Why fixing the typo would make it worse

Correcting `:cBufferData` to `:_cBufferData_` produces a **working pointer
into a dead string**. `Content()` returns a copy; `_cBufferData_` is a local
that dies when the method returns; the address is then cached in
`@pLowLevelPtr` and `@nBaseAddress` and used by six other methods.

That is **F-22** exactly — the failure that does not raise, does not print,
and vanishes the process once the allocator reuses the block. It survived a
100,000-access fuzz for days in Ring++'s own testing before it fired.

**A dead feature would become a memory-corruption feature.** The one-line
fix is the dangerous one.

### What to do instead

`stkPointer` needs a live buffer it does not own, addressable by offset, with
the address re-derived per access rather than cached. That is `RppBuffer`
plus `RppView`, and it is the one place in this proposal where adopting
Ring++ is the straightforward answer rather than a consolidation argument.

**First, a distinction the plan's "works or is deleted" does not make.** The
dead machinery is private; the methods standing on it are **public**, and
they do not fail — they return constants:

| method | returns today, always |
|---|---|
| `GetRawPointer()` | `""` |
| `GetMemoryAddress()` | `0` |
| `GetViewAddress()` | `0` |
| `ComparePointer(oOther)` | `0` |
| `IsNullPointer()` | `TRUE` |

`IsNullPointer()` is the one to look at twice: it answers **true, always**,
and it is not wrong — there is no pointer. It is a correct answer to a
question the class can no longer really ask.

So "delete it" splits into two different acts:

1. **Rebuild on `RppBuffer`/`RppView`.** `stkPointer` holds a view; every
   accessor goes through it; no address is stored on the object. The five
   methods above start returning real values for the first time.
2. **Remove the private machinery, keep the five methods.** Honest, but
   barely a change: they already return those constants. Worth it only as
   bookkeeping, and the comments must then say the class has no low-level
   access rather than implying it might.
3. **Remove the methods.** This is an **API break** — `stkPointer`'s public
   surface loses five names. Nothing in the estate calls them today, but that
   is a fact about today, and it is the maintainer's call, not a session's.

**Recommendation: 1 if anything needs the address, 3 if nothing does — and 3
is a decision to be taken deliberately, not as a side effect of tidying.**
Nothing in the estate needs it today, which is exactly why nobody noticed for
as long as they did not.

---

## 2b. Finding S-2 — `stkBuffer.Write` carries the `"NULL"`-prefix hole too

*Added 2026-08-25, after the finding above was written. It does not change
§1's recommendation to leave `stkBuffer.Write` alone — it adds one line to
it.*

`libraries/stzlib/core/system/stkBuffer.ring:144`:

```ring
if _cData_[1] = @cNulByte or (_nLenData_ = 4 and _cData_ = "NULL")
```

That is, character for character, the guard Ring++ shipped until today —
and it has the same hole, for the same reason. **[F-31](FINDINGS.md)**:
`ring_vm_memcpy` decides "is this argument a null pointer?" with `strcmp`,
so it reads the **C view** of the source. A string whose bytes begin
`N U L L \0` *is* `"NULL"` to `strcmp` whatever its Ring length. The test
above compares the Ring *value* against `"NULL"`, which only a 4-byte
string can ever satisfy.

**The trigger here is narrower than it was in Ring++**, which is why it has
not fired: `stkBuffer.Write` only reaches that `memcpy` on its in-place path
— buffer at least `@nInPlaceMin` (512) and the write landing entirely inside
the existing bytes — and the source is the *caller's* data, never the whole
buffer. Ring++'s `Grow` fed itself the entire buffer as one source, which is
what made the shape reachable by accident there.

So the exposure is: **any caller writing five or more bytes that begin
`"NULL"` followed by a zero, into a buffer of 512 bytes or more.** Binary
records, a serialised field holding the text `NULL`, a length-prefixed value
— none of these are exotic in a buffer type.

**The fix is one expression**, and Ring++'s is measured: on the bytes rather
than the value, written as a single condition because Ring's `and`/`or`
short-circuit (**F-32**), which costs **+0.075 µs per write, ~3.7%** — one
string index. `rpp/core.ring` `Poke` carries the working version to copy.

**This is a genuine defect, not a style note, and it is the one place in this
proposal that argues for changing `stkBuffer` after all** — a two-line guard
repair, not the rewrite §1 recommends against.

---

## 3. The architectural frame — where Ring++ applies now that the engine is Zig

The Softanza Engine is Zig, loaded through a thin FFI bridge
(`libraries/stzlib/engine/stk_*.ring`: `LoadLib` a `.dll`/`.so`, the Zig side
registers its functions natively, Ring calls them by name). That changes
where Ring++ can matter, and it is worth stating as three zones rather than
one blanket answer.

| zone | what it is | does Ring++ apply |
|---|---|---|
| **Inside the engine** | Zig, compiled, native | **No.** Nothing to add. A pointer discipline for Ring's VM is irrelevant to code that is not running on it |
| **The bridge** | the Ring↔Zig crossing, `stk_*.ring` and the `RING_API` functions behind them | **Yes, and this is the unexamined one** |
| **Pure Ring** | everything above the engine — most of a 300,000-line library | **Yes, directly.** This is what `stkBuffer` already demonstrates |

### The bridge is where the tax is still paid

**F-5** is explicit that the by-value tax is not a property of user
functions: *"it is `RING_VM_STACK_PUSHCVAR`, so every built-in that takes the
string as an argument pays it too."* A registered extension function is a
builtin from the VM's point of view.

So handing a 1 MB payload to a Zig function copies 1 MB onto the VM stack
**before Zig starts**. The engine's own speed is unaffected and irrelevant:
the cost is spent on the Ring side of the boundary, and no amount of Zig
removes it.

**This is predicted, not yet measured at the bridge** — F-5 measured Ring
functions, not registered extension functions. Measuring it is gate 1 below,
and if it does not reproduce, this whole section is wrong and should be
struck rather than softened.

If it does reproduce, the consequence is concrete: a bridge function that
takes bytes should be able to take a **handle** — an `RppBuffer` address plus
a length — rather than a Ring string, for payloads above the crossover.
The bytes never move; Zig writes into memory Ring already owns.

### The strategic half: "move it to the engine for speed" is no longer automatic

This is the part worth thinking twice about, and it is a change in the
decision, not just a refinement.

Before Ring++, the reasoning was short: *this is slow in Ring, so it belongs
in the engine.* That reasoning is now incomplete, because a slow Ring path
has two possible causes, and only one of them is fixed by rewriting in Zig:

- the work itself is genuinely compute-bound → the engine is right
- the work is fast but the **data movement** around it is not → the engine
  may not help at all, because the copy happens at the boundary either way,
  and Ring++ removes it without leaving Ring

And each engine module has a standing cost the Ring path does not: a native
artifact to build, ship and support for five platforms, and a dependency that
must exist on the target machine. **F-30** is the estate's own expensive
lesson about what a native dependency can hide — Ring's Qt bridge names one
library and needs ~75, producing a package that reports itself complete and
then crashes with no diagnostic. Ring++'s entire build half exists because
that failure mode is real.

**Proposed rule, for the record rather than for enforcement:**

> Before adding an engine module whose **only** justification is performance,
> measure the Ring++ path first. If pure Ring with `RppBuffer` reaches the
> target, the module is a permanent native dependency bought to solve a
> problem that had a portable answer.
>
> This does not apply to modules that exist for capability — a codec, a
> crypto primitive, a GPU path, anything Ring genuinely cannot express. Those
> are not performance decisions and this rule has nothing to say about them.

That rule cuts both ways honestly: **F-8** and **F-15** are the cases where
Ring++ loses. Small-chunk appends are 28× *slower* through `memcpy`, and a
packed numeric buffer loses to a plain Ring list until the loop itself is
native. If a measurement says the engine, the answer is the engine.

---

## 4. What to provision `stzlib` with

Each item carries the gate that decides whether it worked.

| # | work | gate |
|---|---|---|
| **1** | **Measure the bridge.** A registered extension function taking a 1 MB string, against the same function taking a pointer and a length. Minima over repetitions, both paths returning identical results | a number, either way. If the copy does not reproduce, strike §3 |
| **2** | **`stkPointer`: report, then let the maintainer choose.** The three options in §2 differ in whether the public surface changes; a session must not pick between them alone | `stkPointerTest.ring` (247 lines) passes unchanged. Whichever option: it passes *because nothing used the feature* — the finding restated as a test result |
| **3** | **Do not *rewrite* `stkBuffer.Write`** — but do repair its guard, §2b | a test that writes `"NULL" + char(0) + ...` into a buffer of 512+ and survives. Before the repair it kills the process with no message |
| **4** | **If gate 1 reproduces:** a handle-taking form for the bridge functions that carry bulk bytes | the same payload through both forms, byte-identical output, with the crossover stated — the size below which the string form still wins |

Items 1 and 2 are independent and can run in either order. Item 2 needs no
measurement at all: the finding is already verified twice, by reading and by
running.

---

## 5. What this proposal does not claim

- **That `stkBuffer` should adopt `RppBuffer`.** It should not, today. The
  code is correct, measured and commented, and rewriting a core type to
  remove duplication that has not yet hurt anyone is a poor trade.
- **That the bridge is slow.** It is *predicted* to pay the copy, from a
  finding measured elsewhere. Gate 1 exists because that is not the same as
  knowing.
- **That the engine is over-used.** No audit of engine modules was done here,
  and none is implied. The rule in §3 is for the next decision, not a verdict
  on past ones.
- **That anything here is urgent.** `stkPointer`'s dead feature has been dead
  since it was written and has broken nothing, precisely because nothing
  depends on it. The reason to fix it is that a silently-failing pointer path
  in a memory framework is a trap laid for whoever eventually uses it.
