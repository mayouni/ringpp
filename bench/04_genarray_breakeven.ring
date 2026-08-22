### B4 — find the pattern where genarray LOSES (the honest half of the A/B)

N = 80000
ROUNDS = 300
READS  = 5          # few reads per add -> array cost not amortised

a = list(N)
for i=1 to N a[i] = i next
aIdx = list(READS)
for i=1 to READS aIdx[i] = ((i*7919) % N) + 1 next

? "list " + N + " items, " + ROUNDS + " rounds of (1 add + " + READS + " permuted reads)"

t1=clock()
for r = 1 to ROUNDS
    a + r
    s = 0
    for i = 1 to READS s += a[aIdx[i]] next
next
t2=clock()
nPlain = (t2-t1)/clockspersecond()*1000
? "plain               : " + nPlain + " ms"

b = list(N)
for i=1 to N b[i] = i next
t1=clock()
for r = 1 to ROUNDS
    b + r
    ringvm_genarray(b)
    s = 0
    for i = 1 to READS s += b[aIdx[i]] next
next
t2=clock()
nArr = (t2-t1)/clockspersecond()*1000
? "genarray every add  : " + nArr + " ms   ratio = " + (nArr/nPlain) + "x"

### sweep READS to find the break-even
? ""
? "reads-per-add sweep (N=" + N + ", " + ROUNDS + " rounds)"
for nR in [1, 5, 20, 50, 100, 400]
    c = list(N)
    for i=1 to N c[i] = i next
    aI = list(nR)
    for i=1 to nR aI[i] = ((i*7919) % N) + 1 next

    t1=clock()
    for r = 1 to ROUNDS
        c + r
        s = 0
        for i = 1 to nR s += c[aI[i]] next
    next
    t2=clock()
    nP = (t2-t1)/clockspersecond()*1000

    d = list(N)
    for i=1 to N d[i] = i next
    t1=clock()
    for r = 1 to ROUNDS
        d + r
        ringvm_genarray(d)
        s = 0
        for i = 1 to nR s += d[aI[i]] next
    next
    t2=clock()
    nG = (t2-t1)/clockspersecond()*1000
    ? "  reads=" + nR + "  plain=" + nP + " ms  genarray=" + nG + " ms  ratio=" + (nG/nP)
next
