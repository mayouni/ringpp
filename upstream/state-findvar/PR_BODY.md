# `ring_state_findvar()`: name case, and "not found" vs a variable holding 0

Two small things about the embedding API called from Ring itself, which I
have been using a lot and enjoying.

## 1. The name must already be lower case

```ring
st = ring_state_init()
ring_state_runcode(st, "nTotal = 7")

? ring_state_findvar(st, "nTotal")   # ---> 0     (silent miss)
? ring_state_findvar(st, "ntotal")   # ---> the variable
```

Ring is case-insensitive and folds identifiers when storing them, so a
caller who writes the name exactly as it appears in their own source gets
nothing back. Would folding the name inside `ring_state_findvar()` be
reasonable — the way the rest of the language does?

## 2. Absence is reported as the number `0`

`ring_vm_generallib_state_findvar()` (`language/src/genlib_e.c`) returns
`RING_API_RETNUMBER(0)` when the variable is missing, which a caller cannot
tell apart from a variable whose value is `0`. Everything else in Ring uses
`NULL` for this.

Returning `NULL` would make it checkable — but it is a behaviour change, so
it is a question rather than a proposal: would that break existing users?

## Checked

The patch covers (1) only, since it is the one with no downside. Built
`language/` twice with `zig cc -O2`, identical but for the patch:

| `ring_state_findvar(st, ...)` after `nTotal = 7` | stock | patched |
|---|---|---|
| `"nTotal"` | not found | **7** |
| `"NTOTAL"` | not found | **7** |
| `"ntotal"` | 7 | 7 |
| `"missing"` | not found | not found |

All six tests under `language/tests/scripts/` that use `ring_state_*` are
byte-identical on both builds.

Reproduces on stock Ring 1.27.
