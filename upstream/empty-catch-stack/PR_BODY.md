# An empty `catch` block grows the VM stack, and ~1003 of them abort

## Reproduce

```ring
for i = 1 to 2000
    try  raise("x")  catch  done
next
# --> Error (R4) : Stack Overflow
```

No recursion, no nesting. `ringvm_info()[18]` is `pVM->nSP`, and it rises
by exactly one per caught error. `RING_VM_STACK_SIZE` is 1004, which is
where it stops.

## Only an EMPTY catch

300 iterations per arm:

| | nSP before → after |
|---|---|
| `try raise("x") catch done` | 1 → **301** |
| `try raise("x") catch nSink++ done` | 1 → 1 |
| `try raise("x") catch c = cCatchError done` | 1 → 1 |
| empty catch, then one statement after the try | 1 → 1 |

## Cause

`ring_vm_catch()` restores `nSP` correctly — I instrumented it, and the
value is right on exit. The extra slot appears *after* that, and any
statement absorbs it: each statement ends by freeing the stack, so an
empty `Catch` block never cleans up.

```
[TRY   ] nSP=0        [TRY   ] nSP=1        [TRY   ] nSP=2
[CATCH ] nSP=0  <- restored correctly, then +1 before the next try
```

## Possible fix

Emit `ICO_FREESTACK` on entry to the Catch block, in `ring_parser_stmt()`.
A non-empty block is unaffected — its first statement already frees the
stack. The patch is attached, if that shape suits you.

## Checked

Built `language/` twice with `zig cc -O2`, identical but for the patch:

- the loop above aborts on the control build and prints on the patched one;
- `nSP` growth over 2000 empty catches: **300 → 0**;
- `cCatchError` and the error texts are unchanged;
- **102 of the 103 tests under `language/tests/scripts/` that use
  `try` are byte-identical** on both builds (the one skipped reads stdin
  and blocks).

Test included: `tests/scripts/trycatch/emptycatchloop.ring` with
`tests/correct/trycatch_emptycatchloop.txt`.

## Why it is worth fixing

`try ... catch done` is the ordinary way to write "ignore this error", and
a validation or probe loop does it thousands of times. It also affects
RingScript, which wraps every `eval()` in a try/catch shim — a page that
evaluates a thousand failing snippets would hit R4 in the browser.
