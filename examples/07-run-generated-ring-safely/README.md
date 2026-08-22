# 07 — Running generated Ring safely

**The task:** run Ring code your program did not write. A rule from a config
file. A formula a user typed. Code your own generator emitted.

**This example measures nothing worth bragging about.** `RppSandbox` is
*slower* than `eval()`, and says so. What it buys is that the snippet cannot
reach you.

---

## The obvious tool shares your variables

`eval()` runs in the **host's** scope. Anything the snippet assigns lands in
your program:

```ring
nTotal = 100
cName  = "HOST OWNS THIS"

eval("nTotal = 7 * 6" + nl + "cName = 'from the snippet'")

? nTotal    # --> 42
? cName     # --> from the snippet
```

Nothing warns you. Not at parse time, not at run time, not in the result. The
program continues with a different number.

The snippet did nothing hostile — it used `nTotal`, a name chosen by someone
who has never seen your code. (This is the same failure shape as
[FINDINGS F-25](../../docs/FINDINGS.md), where Ring++'s own attributes were
clobbering *its* callers. Name collision is a recurring hazard in Ring, not a
one-off.)

```ring
oBox = RppSandbox()
oBox.Run(cSnippet)

? nTotal              # --> 100   untouched
? oBox.Var("nTotal")  # --> 42    readable, over there
```

`ring_state_init()` creates a **real second interpreter** — its own globals,
its own functions, its own error state ([FINDINGS
F-13](../../docs/FINDINGS.md)).

## Errors stay over there too

```ring
oBox.Run("this is not valid Ring at all {{{")
```

The host keeps running. `eval()` on the same text raises into *your* call
stack.

## The cost, measured both ways

| | 200 snippets | |
|---|---:|---|
| `eval()` in the host | **3 ms** | — |
| **one** sandbox, reused | **7 ms** | **2.3×** |
| a **fresh** sandbox per snippet | **659 ms** | **219×** |

**The gap between those last two lines is `ring_state_init()`**, paid 200
times instead of once. **Reuse the sandbox** unless the snippets must be
isolated from each other as well as from you.

The first draft of this example measured only the fresh-sandbox case, got
**193×**, and still called it *"as expected, ~1.75× per F-13"*. Those are two
different things. F-13's figure describes work running in an *existing*
sub-state — 2.3× here — and the creation cost is a separate, much larger term
that the advice depends on. The example now measures both.

## Where this loses — the honest half

- **Slower than `eval()` either way.** If the code is yours and you trust it,
  `eval()` is faster and simpler.
- **`Quiet()` does not silence everything.** A snippet that fails to *parse*
  still prints its `C18` from inside the sub-state. `ringvm_hideerrormsg(1)`
  suppresses runtime errors, not the scanner. The host survives regardless,
  which is the part that matters.
- **A sandbox is not a security boundary.** The snippet still runs with your
  process's file and network access. It contains **accidents** — a name
  collision, a bad formula, a syntax error — **not attackers.** Anyone who
  reads this as a way to run hostile code has been misled, and that would be
  this example's fault, so it is stated twice.

## Two traps the raw API has, closed here

From [FINDINGS F-3](../../docs/FINDINGS.md):

- `ring_state_findvar` needs the name **folded to lower case**, or it silently
  misses. `Var()` folds it.
- **Absence is reported as the number `0`** — indistinguishable from a
  variable holding 0. `Var()` raises instead, and `Has()` answers the question
  properly.

Those were fixed upstream on 2026-08-14 (commit
[`b6aea3d`](https://github.com/ring-lang/ring/commit/b6aea3d58fce7b544bd2381f7c1b27655ce2c094),
credited to Mansour Ayouni and Youssef Saeed) and it turned out to be four
functions, not one. Folding the name yourself is correct on every version,
which is why `RppSandbox` still does it.

## Run it

```bash
ring examples/07-run-generated-ring-safely/example.ring
```
