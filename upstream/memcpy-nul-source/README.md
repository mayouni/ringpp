# PR: binary strings starting with a zero byte detected as NULL pointers

> ## STATUS: SENT — [ring-lang/ring#1643](https://github.com/ring-lang/ring/pull/1643)
>
> Opened August 11, 2026 by `mayouni`, on explicit instruction, from
> branch `mayouni:fix-binary-string-null-pointer` → `master`.
> 3 files, +40/−3.
>
> *This was a one-time authorisation. The standing rule is unchanged:
> nothing goes to `ring-lang/ring` unless Mansour asks explicitly, after
> reviewing it himself.*

## What this is

The fix for [FINDINGS F-14](../../docs/FINDINGS.md) — `memcpy()` kills the
process when the source string's first byte is `0x00`, because
`ring_vm_api_ispointer()` uses `strcmp()` where the VM already knows the
real string size.

| file | what it is |
|---|---|
| [`PR_BODY.md`](PR_BODY.md) | the pull-request description |
| [`fix.patch`](fix.patch) | the change: one condition in `language/src/ringapi.c` |
| [`tests/scripts/null/cptrbinary.ring`](tests/scripts/null/cptrbinary.ring) | new test, in Ring's own convention, beside the existing `cptrnull.ring` |
| [`tests/correct/null_cptrbinary.txt`](tests/correct/null_cptrbinary.txt) | its expected output |

## How it was verified

Ring 1.27's `language/` builds from source with `zig cc -O2` in **6.2 s**
(44 `.c` files, `ringw.c` excluded — it is the Windows GUI entry point).
Two binaries were built from identical sources except the patch.

**1. The reproducer.**

| | stock | patched |
|---|---|---|
| `memcpy(p, int2bytes(7), 4)` | ok | ok |
| `memcpy(p, int2bytes(256), 4)` | **process dies** | `00010000` |
| `memcpy(p, double2bytes(1.5), 8)` | **process dies** | `1.50` |
| `memcpy(p, char(0), 1)` | **process dies** | ok |

**2. Exhaustive over the blast radius.** The patch changes exactly one
function, `ring_vm_api_ispointer()`, which is only reached when a **string**
argument is tested with `ISPOINTER` / `ISCPOINTER`. There are four classes
of string, and three must not move:

| string argument | stock | patched |
|---|---|---|
| `""` (size 0) | NULL pointer | same |
| `"NULL"` (size 4) | NULL pointer | same |
| any normal string | not a pointer | same |
| **starts with a zero byte** | NULL pointer → abort | not a pointer |

`t_matrix.ring` exercises all four through `isnull`, `nullptr`, `ptrcmp`,
`ptr2str`, `getptr` and `memcpy`. The two builds are **character-identical
except for the three lines stock never reaches** — the `memcpy` calls that
used to abort.

**3. The existing tests.** All five in `language/tests/scripts/null/` —
`cptrnull`, `null`, `null2`, `null3`, `null4` — byte-identical on both.

*A full 978-file sweep of `language/tests/scripts/` was started and then
abandoned: it is the wrong instrument. The case analysis above is
exhaustive over what the patch can touch, and a sweep that mostly exercises
code the patch cannot reach would be slower and prove less.*

## Known limitation, deliberate

The literal 4-byte string `"NULL"` is still treated as a NULL pointer, so
`memcpy(p, "NULL", 4)` still traps. That is the documented convenience the
branch exists for and the patch preserves it. A binary payload whose bytes
happen to be `4E 55 4C 4C` will still be misread. Removing that would change
documented behaviour, so it is left alone and stated plainly in the PR body.

## If it is ever sent

The repository is `ring-lang/ring`; the patch applies to
`language/src/ringapi.c`. Ring's test harness lives in `language/tests/`
(`scripts/<category>/<name>.ring` with `correct/<category>_<name>.txt`), so
the two test files drop straight in.

Ring++ itself does **not** depend on this being fixed — it works around the
bug by passing binary sources as pointers rather than strings, which is what
`RppBuffer.Poke` does internally.
