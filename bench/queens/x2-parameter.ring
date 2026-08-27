# N-Queens — X2. The board as a parameter instead of a global. REJECTED.
#
# Ring passes a LIST across a call boundary by reference — that asymmetry
# with strings is the whole reason this project exists — so threading the
# board through every call should have cost nothing, and might have saved
# the global lookups in Place().
#
# It costs 13%. Place() is called 2,247,737 times, and every call now
# pushes one more argument; the per-call price of the extra parameter is
# larger than the per-read saving inside the function. Reference passing
# means no COPY, which is what F-1 claims and this file does not dispute.
# It does not mean free.
#
# Kept as the counter-example to an easy inference: "lists are free to
# pass" is about copying, not about argument count.

nMax = 11
if len(sysargv) >= 3
    nMax = number(sysargv[3])
ok

countPlace = 0
countQueen = 0
countSol   = 0
x = 1:nMax

nT = clock()
for n = 1 to nMax
    x = 1:n
    nQueen(1, n, x)
next
nMs = (clock() - nT) / clockspersecond() * 1000

? "CHECK sol " + countSol
? "CHECK place " + countPlace
? "CHECK queen " + countQueen
? "TIME  total " + nMs

func Place k, i, x
    countPlace++
    for j = 1 to k-1
        if x[j] = i or fabs(x[j]-i) = k - j
            return 0
        ok
    next
    return 1


func nQueen k, n, x
    countQueen++
    for i = 1 to n
        if place(k, i, x)
            x[k] = i
            if k = n
                countSol++
            else
                nQueen(k+1, n, x)
            ok
        ok
    next
