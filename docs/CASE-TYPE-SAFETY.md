# What the checker found — a case study

*Ring++'s type checking exists because a bank engineering team, after
testing Ring and being impressed by it, named type safety as the one
concern that remained before using it on their larger projects. This
document is the answer to "does it actually find anything?", written from
one afternoon's runs on two real codebases.*

*It also records what the checker got **wrong**, and what that cost,
because a page that lists only finds is marketing.*

---

## The headline: two functions in Ring's own standard library have never worked

`libraries/stdlib/stdsecurity.ring`:

```ring
Func encrypt_ex cString,cKey,cIV,cCipher
    return std_encrypt(cString,cKey,cIV,cCipher)     # 4 arguments
```

`std_encrypt` takes **three** parameters. `std_encrypt_ex` — right next to
it in `stdfunctions.ring` — takes four. The `_ex` wrapper calls the
non-`_ex` function, so it is dead on every call. `decrypt_ex` has the same
defect.

Not inferred. Run:

```ring
load "stdlib.ring"
x = new security
? x.encrypt_ex("secret", "key1234567890123", "iv12345678901234", "AES-256-CBC")
```

```
Error (R20) : Calling function with extra number of parameters
```

This is shipped Ring 1.27, in the standard library, in the security
module. It survived because **nothing ever called it** — and nothing
static was looking.

*(Written up in [`upstream/stdlib-encrypt-ex/`](../upstream/stdlib-encrypt-ex/NOTE.md).
Not sent: findings go to the Ring Google Group and Mansour posts them.)*

## Why the checker can be certain, and not merely suspicious

A cross-file arity claim is only worth making if it cannot be wrong. Three
measured Ring behaviours make it safe:

| measured | why it matters |
|---|---|
| **[F-26](FINDINGS.md)** — a duplicate function name is `C22` at **load** time; the program never starts | within one load graph a resolving name has **exactly one** live definition, so "defined in another file" is not a guess |
| **[F-27](FINDINGS.md)** — inside a class: own method → inherited → global → builtin, arity enforced at every step | a call inside a class body is decidable whenever the method chain is visible |
| **[F-24](FINDINGS.md)** — parameter annotations are parsed and discarded; a *return* annotation is a variable read needing `typehints.ring` | the checker knows which half of an annotation Ring actually evaluates |

Each was established with reproducers before a single rule was written.
Where certainty is not available the checker **refuses**: an unknown parent
class, a file that did not parse, a name with two definitions.

## The score, on two real codebases

**Ring's own tree — 1,959 files** (`libraries`, `applications`, `samples`):

| | |
|---|---:|
| errors reported | **3** |
| real | **3** |
| false positives | **0** |

`encrypt_ex`, `decrypt_ex`, and `DrawDividendChart()` called with no
argument against a one-parameter definition.

**Softanza's library tree — 6,014 files, 922,964 lines, 25.5 MB, 43
seconds** (minimum of three runs; the path is `stzlib/libraries`, and it
is named because the repository root also holds 5,368 generated `.ring`
files under `.claude` that are tooling scratch, not the project — counting
those would inflate every number on this page):

| | |
|---|---:|
| duplicate definitions (`C22`, file cannot load) | **13 names** |
| cross-file arity | **11** |
| method-resolution arity | **99** |

Of the 99, **97 are in dead archive files** and 2 in a stub the author had
already marked `#TODO`. That distribution is itself the finding: the live
library was in far better shape than the raw number suggests, and saying so
matters more than a big count.

## Two live bugs, and what they looked like

**A builtin shadowed by a method.** `stzNumber.ring` called `decimals(n)`
— Ring's builtin for display precision — inside a class defining a
0-parameter `Decimals()`. The method wins (F-27), so the call raised R20
and killed the whole rounding branch on every invocation.

Fixing it exposed two more defects that only a *running* path could show:
a memorised rounding value that was never restored (the branch had never
reached its own end), and `cFractionalSep` — a variable **never assigned
anywhere in the file** — three lines further on. The checker cannot see
that one; it is a variable, not a call. Executing the repaired path is
what found it.

**A global shadowed by a method.** `stzListNamedParams.ring` called
`IsThisNamedParam(This.Content(), cKeyword)`. That two-parameter global
exists and the call was written correctly — but the class defines its own
0-parameter `IsThisNamedParam()`, and the method shadows it. Switching to
the un-shadowed canonical name fixed it with no API change.

Both are the same shape, and it is a shape no reviewer reliably catches:
**the call site looks right, and the definition it means exists.** What is
wrong is invisible unless you know which of the two Ring will pick.

## What it got wrong — three false positives in one afternoon

Every one was a Ring **scoping rule** the checker did not know, and not one
would have been caught by a unit test written from imagination. All three
were caught by running the corpora.

| the invention | the reality | cost |
|---|---|---|
| 344 arity errors across Softanza's tests | `StzCharQ("x") { ? Name() }` — a **brace block** runs in the object's scope, so `Name()` is a method | would have buried the real findings 30:1 |
| `SortLists()` "called with 0" | it sits inside a `/* block comment */` in a file that did not parse; tree-sitter's error recovery invented the call | reported into a file already marked `rpp/unparsed` |
| 3 errors in Ring's gameengine | `call draw(oGame, self)` — Ring's `call` keyword invokes the function held in a **variable** | took Ring's own libraries from 0 errors to 5 |

The second one mattered most, because it was a **broken promise**:
`rpp/unparsed` says *"no rules were applied to this file"*, and the
cross-file layer was applying them anyway. Files that fail to parse are now
excluded from cross-file checking entirely — in both directions, exporting
nothing and receiving nothing.

**That fix has a price, and it is paid knowingly:** it also discards 12
genuine duplicate definitions in a specification sketch that cannot parse.
A true finding in a file that never runs costs less than one false finding
in a file that does.

## The rule underneath all of it

> A checker's only asset is that it is never wrong about correct code.

Everything above follows from that. Rules are narrowed until they are
certain; where they cannot be, they refuse and say so. The refusals are
listed at each rule's site and in [`ringpp why`](CLI.md), because coverage
given up silently is indistinguishable from coverage that never existed.

```
ringpp why rpp/type-arity
```

## Reproducing this

```bash
ringpp check <your-project>
```

No compiler, no toolchain, no configuration. One shipped binary, and Ring.

## Credit

Every finding on this page was read through
**[`tree-sitter-ring`](https://github.com/ysdragon/tree-sitter-ring)**, the
Ring grammar by **Youssef Saeed ([`@ysdragon`](https://github.com/ysdragon))**,
vendored here under its MIT licence. It was adopted rather than written
from scratch for a reason worth stating: it had independently arrived at
the same reading of Ring's type annotations that the measurements in
[FINDINGS F-24](FINDINGS.md) reached — *"type is skipped by the Ring parser
but kept here"* — and two parties reaching one conclusion separately is the
strongest evidence available that the conclusion is right. Grammar defects
found here go back to him as
[issues](https://github.com/ysdragon/tree-sitter-ring/issues), never as
patches routed around him.

## Postscript — fixed upstream, 2026-08-25

One day after Ring++'s announcement reached the Ring group, both dead
functions were repaired in Ring's own repository:
[`7890ea5`](https://github.com/ring-lang/ring/commit/7890ea5) — *"Update
libraries/stdlib/stdsecurity.ring - Revise encrypt_ex() and decrypt_ex() -
Reported by Mansour Ayouni"*. Verified through the GitHub API, 2026-08-26.

The route this project committed to — a finding, posted by the maintainer
himself, never a pull request — closed in a day. A closed PR is not the
outcome; the commit is, and this is the commit.
