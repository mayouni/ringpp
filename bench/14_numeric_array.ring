### 14 — Numeric arrays: a packed buffer, or a Ring list?
###
### Ring++ targets data-intensive work (ledgers, records, optimisation,
### ML/AI kernels), so the dense-numeric representation decides much of
### the surface. The question is not "is a packed buffer better" but
### "better read by whom".
###
### NOTE: the write loop passes its source as a POINTER, not as a string.
### Passing double2bytes() output directly to memcpy() kills the process
### (see 15_memcpy_nul_source.ring). RppBuffer.Poke must always do this.

func main
     N = 200000
     REPS = 5

     ### ---- representation A: an ordinary Ring list ----
     aList = list(N)
     for i = 1 to N aList[i] = i * 0.5 next

     ### ---- representation B: 8 bytes per double in one buffer ----
     cBuf  = space(N * 8)
     p     = varptr(:cBuf, "char *")
     nBase = getptr(p)
     q     = nullptr()
     qSrc  = nullptr()
     for i = 1 to N
         cVal = double2bytes(i * 0.5)
         setptr(qSrc, getptr(varptr(:cVal, "char *")))   # pointer, never string
         setptr(q, nBase + (i-1)*8)
         memcpy(q, qSrc, 8)
     next

     ? "N = " + N + " doubles, " + REPS + " repetitions, minima reported"
     ? ""

     nBest = -1
     for r = 1 to REPS
         t1=clock()
         s = 0
         for i = 1 to N s += aList[i] next
         t2=clock()
         nT = (t2-t1)/clockspersecond()*1000
         if nBest = -1 or nT < nBest nBest = nT ok
     next
     nA = nBest
     ? "A  Ring list, read from interpreted Ring     : " + nA + " ms   sum=" + s

     nBest = -1
     for r = 1 to REPS
         t1=clock()
         s2 = 0
         for i = 1 to N
             s2 += bytes2double(ptr2str(p, (i-1)*8, 8))
         next
         t2=clock()
         nT = (t2-t1)/clockspersecond()*1000
         if nBest = -1 or nT < nBest nBest = nT ok
     next
     nB = nBest
     ? "B  packed buffer, read from interpreted Ring : " + nB + " ms   sum=" + s2
     ? "   same result?                              : " + (s = s2)
     ? "   ratio B/A                                 : " + (nB/nA) + "x"
     ? ""
     ? "C  packed buffer, read from COMPILED code    : see bench/headroom"
     ? "     K2 dot product, 1,000,000 doubles: Ring 92 ms vs native 0.96 ms"
     ? ""
     ? "Conclusion: a packed numeric buffer is a COMPILED-half data"
     ? "structure. Read from interpreted Ring it LOSES to a plain Ring"
     ? "list, because every element costs two C calls (~200 ns) against"
     ? "the list's single indexed read (~60 ns). It only pays when the"
     ? "loop around it is native."
