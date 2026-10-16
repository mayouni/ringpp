### B1 — A/B: string building.  One thing differs: how bytes get written.

N = 200000          # number of 8-byte chunks -> 1.6 MB
CHUNK = "ABCDEFGH"

? "N = " + N + "  target = " + (N*8) + " bytes"

### A: ordinary Ring concatenation
t1 = clock()
cOut = ""
for i = 1 to N
    cOut += CHUNK
next
t2 = clock()
nA = (t2-t1) / clockspersecond() * 1000
? "A concat            : " + nA + " ms   len=" + len(cOut)

### B: preallocate + memcpy through varptr, pointer taken ONCE
t1 = clock()
cBuf = space(N*8)
p = varptr(:cBuf, "char *")
nOff = 0
for i = 1 to N
    memcpy2(p, nOff, CHUNK, 8)
    nOff += 8
next
t2 = clock()
nB = (t2-t1) / clockspersecond() * 1000
? "B space+memcpy      : " + nB + " ms   len=" + len(cBuf)
? "  equal?            : " + (cBuf = cOut)
? "  speedup           : " + (nA/nB) + "x"

### C: same but taking varptr INSIDE the loop (the naive way)
t1 = clock()
cBuf2 = space(N*8)
nOff = 0
for i = 1 to N
    memcpy2(varptr(:cBuf2, "char *"), nOff, CHUNK, 8)
    nOff += 8
next
t2 = clock()
nC = (t2-t1) / clockspersecond() * 1000
? "C varptr in loop    : " + nC + " ms   ratio vs B = " + (nC/nB) + "x"

### D: list-of-parts + join  (the usual Ring idiom)
t1 = clock()
aParts = []
for i = 1 to N
    aParts + CHUNK
next
cJoin = ""
for i = 1 to N
    cJoin += aParts[i]
next
t2 = clock()
? "D list + concat     : " + ((t2-t1)/clockspersecond()*1000) + " ms"

func memcpy2 pDest, nOffset, cSrc, nLen
     q = nullptr()
     setptr(q, getptr(pDest) + nOffset)
     memcpy(q, cSrc, nLen)
