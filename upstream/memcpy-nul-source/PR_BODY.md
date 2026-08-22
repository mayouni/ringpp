# memcpy() aborts when the source string starts with a zero byte

## Reproduce

```ring
cBuf = space(64)
p = varptr(:cBuf, "char *")

memcpy(p, int2bytes(7),   4)     # 07000000  -> fine
memcpy(p, int2bytes(256), 4)     # 00010000  -> process aborts
memcpy(p, double2bytes(1.5), 8)  # -> aborts
memcpy(p, char(0), 1)            # -> aborts, copying one byte
```

No message, no line number, and `try`/`catch` cannot trap it. The
destination does not matter, so it is the source parameter.

## Root cause

`ring_vm_api_ispointer()` — `language/src/ringapi.c:127` — decides with
`strcmp()` whether a string argument is a NULL pointer. `strcmp()` stops at
the first zero byte, so binary data that merely *starts* with one compares
equal to `""`, and the argument is reclassified as a NULL pointer.

`ring_vm_generallib_memcpy()` then re-reads parameter 2 as a C pointer and
copies from address 0.

The VM already records the real string size, which is why `len()`,
`str2hex()`, `bytes2double()` and `murmur3hash()` all handle the same
string correctly.

## Possible fix

Using the recorded size for the empty case is enough, if that suits you:

```c
if ((RING_API_GETSTRINGSIZE(nPara) == 0) ||
    ((RING_API_GETSTRINGSIZE(nPara) == 4) &&
     (strcmp(RING_API_GETSTRING(nPara), RING_CSTR_NULL) == 0))) {
```

The patch is attached. `"NULL"` keeps working; a binary payload that
happens to be `4E 55 4C 4C` would still be misread.

## Checked

Only strings reach the changed branch, and there are four classes of them.
Built `language/` twice with `zig cc -O2`, identical but for the patch:

| string argument | stock | patched |
|---|---|---|
| `""` | NULL pointer | same |
| `"NULL"` | NULL pointer | same |
| any normal string | not a pointer | same |
| starts with a zero byte | NULL pointer → abort | not a pointer |

Output of `isnull`, `nullptr`, `ptrcmp`, `ptr2str` and `getptr` across those
classes is character-identical on both builds; the only difference anywhere
is that the `memcpy` calls above now complete. The five tests in
`language/tests/scripts/null/` are byte-identical too.

Test included: `tests/scripts/null/cptrbinary.ring` with
`tests/correct/null_cptrbinary.txt`.
