### B2 — the unit costs that decide everything

M = 300000

? "=== per-call unit costs (" + M + " iterations) ==="

t1=clock() for i=1 to M next t2=clock()
nLoop = (t2-t1)/clockspersecond()*1000
? "empty for-loop      : " + nLoop + " ms   (baseline)"

t1=clock() for i=1 to M x = len("abc") next t2=clock()
? "len('abc')          : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

t1=clock() for i=1 to M x = NoOp() next t2=clock()
? "ring func call      : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

t1=clock() for i=1 to M x = nullptr() next t2=clock()
? "nullptr()           : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

cV = space(64)
t1=clock() for i=1 to M x = varptr(:cV, "char *") next t2=clock()
? "varptr()            : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

p = varptr(:cV, "char *")
t1=clock() for i=1 to M x = getptr(p) next t2=clock()
? "getptr()            : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

t1=clock() for i=1 to M memcpy(p, "ab", 2) next t2=clock()
? "memcpy(2 bytes)     : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

t1=clock() for i=1 to M x = ptr2str(p, 0, 8) next t2=clock()
? "ptr2str(8 bytes)    : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

t1=clock() for i=1 to M x = substr(cV, 1, 8) next t2=clock()
? "substr(64B str)     : " + ((t2-t1)/clockspersecond()*1000 - nLoop) + " ms net"

? ""
? "=== the string-argument copy tax (PUSHCVAR) ==="
K = 20000
for nSize in [16, 1024, 65536, 1048576]
    cBig = space(nSize)
    t1=clock() for i=1 to K x = len(cBig) next t2=clock()
    ? "len() on " + nSize + " bytes, " + K + "x : " + ((t2-t1)/clockspersecond()*1000) + " ms"
next

? ""
? "=== reading bytes out of a big string ==="
cBig = space(1048576)
pB = varptr(:cBig, "char *")
K2 = 100000
t1=clock() for i=1 to K2 x = cBig[i] next t2=clock()
? "cBig[i]  x" + K2 + "        : " + ((t2-t1)/clockspersecond()*1000) + " ms"
t1=clock() for i=1 to K2 x = ptr2str(pB, i, 1) next t2=clock()
? "ptr2str(pB,i,1) x" + K2 + " : " + ((t2-t1)/clockspersecond()*1000) + " ms"

func NoOp
     return 0
