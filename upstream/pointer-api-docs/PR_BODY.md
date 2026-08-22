# Document two behaviours of the low level pointer functions

Two notes for `documents/source/lowlevel.txt`. Neither is a bug — both
cost real time to diagnose because the failure is silent.

## 1. `memcpy()` with a string destination does nothing

```ring
cDest = space(16)
memcpy(cDest, "ABCDEFGH", 8)
? cDest        # ---> unchanged, no error

memcpy(varptr(:cDest, "char *"), "ABCDEFGH", 8)
? cDest        # ---> "ABCDEFGH        "
```

`ring_vm_generallib_memcpy()` accepts a string as parameter 1, but a
string argument reaches a C function through `RING_VM_STACK_PUSHCVAR`,
which copies the bytes onto the VM stack — so the write lands on the copy.

The existing example in the documentation already uses a pointer, which is
correct; the note just says why the other form must not be used.

## 2. `ptr2str()` has no bounds check

```ring
cB = space(16)
p  = varptr(:cB, "char *")
c  = ptr2str(p, 0, 4096)   # ---> 4096 bytes of adjacent memory, exit code 0
```

The length is not knowable from a `char *`, so there is nothing to fix in
the code — but the page says `pointer2String() return another copy of the
data`, and a reader can reasonably assume the copy is bounded.

Worth saying, because the function is otherwise excellent: on a 500 KB
string `ptr2str(p, n, 10)` costs 0.09 µs where `substr(cBig, n, 10)` costs
12.5 µs, since `substr` receives a copy of the whole string.

Both reproduce on stock Ring 1.27. Documentation only — 8 lines added, no
code touched.
