### 15 — memcpy() dies when the SOURCE string's first byte is NUL
###
### This program is expected to CRASH (exit 1, no message). Each arm is
### commented with what it proves. Run the arms one at a time by editing
### nARM, because the process does not survive the failing ones.
###
### Mechanism (ringapi.c:118-147, ring_vm_api_ispointer):
###   RING_API_ISCPOINTER(2) -> ISLISTORNULL(2) -> ISPOINTER(2), which does
###       if (RING_API_ISSTRING(nPara)) {
###           if ((strcmp(GETSTRING(nPara), "") == 0) || (strcmp(..., "NULL") == 0)) {
###               ... ring_vm_api_setptr(...)              <- REWRITES the stack slot
###               ring_list_addpointer_gc(..., pList2, NULL);   <- pointer is NULL
###               return RING_TRUE;
###   strcmp() cannot tell "" from a binary string that merely STARTS with a
###   zero byte -- even though the VM knows the real size. memcpy() then does
###       if (ISSTRING(2))   pSrc = GETSTRING(2);      // real bytes
###       if (ISCPOINTER(2)) pSrc = getpointer(...);   // now NULL
###       memcpy(pDest, pSrc, n);                      // copy from address 0
###
### Workaround, verified in arm 6: pass the source as a POINTER, never as a
### string. This is what RppBuffer.Poke must do internally, always.

nARM = 1        # <-- 1..6

cBuf = space(64)
p = varptr(:cBuf, "char *")

switch nARM

on 1    # SAFE: first byte is not zero
        c = int2bytes(7)                 # 07000000
        ? "arm 1  int2bytes(7)   = " + str2hex(c)
        memcpy(p, c, 4)
        ? "arm 1  survived (expected)"

on 2    # CRASH: first byte is zero
        c = int2bytes(256)               # 00010000
        ? "arm 2  int2bytes(256) = " + str2hex(c)
        memcpy(p, c, 4)
        ? "arm 2  survived (NOT expected)"

on 3    # CRASH: double2bytes of an ordinary value
        c = double2bytes(1.5)            # 000000000000f83f
        ? "arm 3  double2bytes(1.5) = " + str2hex(c)
        memcpy(p, c, 8)
        ? "arm 3  survived (NOT expected)"

on 4    # CRASH: the literal string "NULL" -- the second strcmp in the branch
        ? "arm 4  source = 'NULL'"
        c = "NULL"
        memcpy(p, c, 4)
        ? "arm 4  survived (NOT expected)"

on 5    # CRASH: even copying ONE byte, and even when the destination is a
        # plain string (the known no-op path). The fault is entirely on the
        # source side.
        ? "arm 5  one NUL byte, string destination"
        c = char(0)
        memcpy(cBuf, c, 1)
        ? "arm 5  survived (NOT expected)"

on 6    # SAFE: the workaround -- source passed as a pointer
        c = double2bytes(1.5)
        q = nullptr()
        setptr(q, getptr(varptr(:c, "char *")))
        memcpy(p, q, 8)
        ? "arm 6  pointer source survived (expected)"
        ? "arm 6  read back = " + bytes2double(ptr2str(p, 0, 8))

off

### Not affected: every other consumer of the same string is correct,
### because they use the VM's recorded size rather than strcmp.
c = double2bytes(1.5)
? ""
? "same value through other functions (all correct):"
? "  len        = " + len(c)
? "  str2hex    = " + str2hex(c)
? "  bytes2dbl  = " + bytes2double(c)
? "  murmur3    = " + murmur3hash(c, 0)
