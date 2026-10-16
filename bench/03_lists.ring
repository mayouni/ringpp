### B3 — lists: what actually decides speed

N = 80000
? "N = " + N

### ---- construction ----
t1=clock()
a1 = []
for i = 1 to N a1 + i next
t2=clock()
? "append  aL + i      : " + ((t2-t1)/clockspersecond()*1000) + " ms"

t1=clock()
a2 = list(N)
for i = 1 to N a2[i] = i next
t2=clock()
? "list(N) + a2[i]=i   : " + ((t2-t1)/clockspersecond()*1000) + " ms"

### ---- sequential read (cursor cache friendly) ----
t1=clock() s=0 for i=1 to N s += a1[i] next t2=clock()
? "sequential read     : " + ((t2-t1)/clockspersecond()*1000) + " ms"

### ---- permuted read WITHOUT genarray ----
aIdx = list(N)
for i = 1 to N aIdx[i] = ((i * 7919) % N) + 1 next

t1=clock() s=0 for i=1 to N s += a1[aIdx[i]] next t2=clock()
nNoArr = (t2-t1)/clockspersecond()*1000
? "permuted, no array  : " + nNoArr + " ms"

### ---- permuted read WITH genarray ----
ringvm_genarray(a1)
t1=clock() s=0 for i=1 to N s += a1[aIdx[i]] next t2=clock()
nArr = (t2-t1)/clockspersecond()*1000
? "permuted, genarray  : " + nArr + " ms   speedup=" + (nNoArr/nArr) + "x"

### ---- does ONE add destroy the array? ----
a1 + 999999
t1=clock() s=0 for i=1 to N s += a1[aIdx[i]] next t2=clock()
? "after ONE add       : " + ((t2-t1)/clockspersecond()*1000) + " ms  <-- array gone?"

### ---- the pattern genarray HURTS: mixed add/read ----
? ""
? "=== mixed add + permuted read, 2000 rounds ==="
M = 4000
b1 = list(M)
for i=1 to M b1[i] = i next
aI2 = list(M)
for i=1 to M aI2[i] = ((i*7919) % M) + 1 next

t1=clock()
for r = 1 to 300
    b1 + r
    s = 0
    for i = 1 to 200 s += b1[aI2[i]] next
next
t2=clock()
? "mixed, plain        : " + ((t2-t1)/clockspersecond()*1000) + " ms"

t1=clock()
for r = 1 to 300
    b1 + r
    ringvm_genarray(b1)
    s = 0
    for i = 1 to 200 s += b1[aI2[i]] next
next
t2=clock()
? "mixed, genarray/add : " + ((t2-t1)/clockspersecond()*1000) + " ms  <-- the trap"

### ---- lists of lists: rows ----
? ""
? "=== 2D ==="
R = 20000
t1=clock()
aR = list(R, 5)
t2=clock()
? "list(R,5)           : " + ((t2-t1)/clockspersecond()*1000) + " ms"

t1=clock()
aR2 = []
for i=1 to R aR2 + [0,0,0,0,0] next
t2=clock()
? "R x [0,0,0,0,0]     : " + ((t2-t1)/clockspersecond()*1000) + " ms"

t1=clock() s=0 for i=1 to R s += aR[i][4] next t2=clock()
? "read col 4 (blocks) : " + ((t2-t1)/clockspersecond()*1000) + " ms"
