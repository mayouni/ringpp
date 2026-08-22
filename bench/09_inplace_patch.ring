### B12 — random-access WRITE into a big buffer: Ring has no in-place option
func main
     N = 500000
     K = 2000

     ? "buffer " + N + " bytes, " + K + " patches of 8 bytes at random offsets"

     ### A: the only pure-Ring way -- rebuild the string
     cA = space(N)
     t1=clock()
     for i = 1 to K
         nOff = ((i * 7919) % (N-16)) + 1
         cA = left(cA, nOff-1) + "PATCHED!" + substr(cA, nOff+8)
     next
     t2=clock()
     ? "  A rebuild        : " + ((t2-t1)/clockspersecond()*1000) + " ms"

     ### B: in-place through a stable pointer
     cB = space(N)
     p  = varptr(:cB, "char *")
     nBase = getptr(p)
     q = nullptr()
     t1=clock()
     for i = 1 to K
         nOff = ((i * 7919) % (N-16)) + 1
         setptr(q, nBase + nOff - 1)
         memcpy(q, "PATCHED!", 8)
     next
     t2=clock()
     ? "  B in-place       : " + ((t2-t1)/clockspersecond()*1000) + " ms"
     ? "  identical?       : " + (cA = cB)

     ### C: chunked bulk write -- find the crossover vs concat
     ? ""
     ? "bulk build 4 MB, varying chunk size"
     for nChunk in [8, 64, 512, 4096, 65536]
         nRep = 4194304 / nChunk
         cPiece = space(nChunk)

         t1=clock()
         cX = ""
         for i = 1 to nRep cX += cPiece next
         t2=clock()
         nCat = (t2-t1)/clockspersecond()*1000

         cY = space(4194304)
         py = varptr(:cY, "char *")
         nB2 = getptr(py)
         qy = nullptr()
         t1=clock()
         nOff = 0
         for i = 1 to nRep
             setptr(qy, nB2 + nOff)
             memcpy(qy, cPiece, nChunk)
             nOff += nChunk
         next
         t2=clock()
         nMem = (t2-t1)/clockspersecond()*1000
         ? "  chunk=" + nChunk + "  concat=" + nCat + " ms  memcpy=" + nMem + " ms  ratio=" + (nMem/nCat)
     next
