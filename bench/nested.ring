# Nested path assignment -- the shape kernels.ring had to avoid.
# MatMul here is written the way algorithms.ring writes it: aA[i][j] = v.

func MatMul2 nN
    aA = list(nN)
    aB = list(nN)
    for i = 1 to nN
        aA[i] = list(nN)
        aB[i] = list(nN)
        for j = 1 to nN
            aA[i][j] = (i + j) % 7
            aB[i][j] = (i * j) % 5
        next
    next
    nAcc = 0
    for i = 1 to nN
        aRow = aA[i]
        for j = 1 to nN
            nS = 0
            for k = 1 to nN
                nS += aRow[k] * aB[k][j]
            next
            nAcc = (nAcc + nS * (i + j)) % 1000000007
        next
    next
    return nAcc

# Does a write through a COPY reach the original, two levels down?
func NestAlias
    aRow = list(3)
    aA = []
    add(aA, aRow)
    aB = aA
    aB[1][2] = 99
    return aA[1][2]
