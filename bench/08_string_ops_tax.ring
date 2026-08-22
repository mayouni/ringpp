### 08 — which core string operations pay the by-value copy tax?
###
### Each measurement is repeated REPS times and the MINIMUM is reported.
### Minimum is the right statistic here: noise (scheduling, turbo, page
### faults) only ever adds time, so the floor is the honest cost.

REPS = 7
K    = 2000

func Report cLabel, aTimes
     nMin = aTimes[1]  nMax = aTimes[1]
     for t in aTimes
         if t < nMin nMin = t ok
         if t > nMax nMax = t ok
     next
     ? "  " + cLabel + "  min=" + nMin + " ms  max=" + nMax + " ms  (" +
       (nMin*1000/K) + " us/call at the floor)"

func main
     cBig = ""
     for i = 1 to 20000
         cBig += "" + i + ",alpha,beta,gamma,42" + nl
     next
     nL = len(cBig)
     ? "string = " + nL + " bytes,  " + K + " calls per measurement, " +
       REPS + " repetitions"
     ? ""

     p = varptr(:cBig, "char *")

     aLen=[] aIdx=[] aSub=[] aLeft=[] aFind=[] aPtr=[]

     for r = 1 to REPS
         t1=clock() for i=1 to K x = len(cBig)            next t2=clock()
         aLen  + ((t2-t1)/clockspersecond()*1000)

         t1=clock() for i=1 to K x = cBig[1000]           next t2=clock()
         aIdx  + ((t2-t1)/clockspersecond()*1000)

         t1=clock() for i=1 to K x = substr(cBig,1000,10) next t2=clock()
         aSub  + ((t2-t1)/clockspersecond()*1000)

         t1=clock() for i=1 to K x = left(cBig,10)        next t2=clock()
         aLeft + ((t2-t1)/clockspersecond()*1000)

         t1=clock() for i=1 to K x = substr(cBig,"gamma") next t2=clock()
         aFind + ((t2-t1)/clockspersecond()*1000)

         t1=clock() for i=1 to K x = ptr2str(p,1000,10)   next t2=clock()
         aPtr  + ((t2-t1)/clockspersecond()*1000)
     next

     ? "PAYS THE COPY TAX (argument is the whole string):"
     Report("len(cBig)          ", aLen)
     Report("substr(cBig,n,10)  ", aSub)
     Report("left(cBig,10)      ", aLeft)
     Report("substr(cBig,'gamma')", aFind)
     ? ""
     ? "DOES NOT (the VM reaches the variable in place):"
     Report("cBig[n]            ", aIdx)
     Report("ptr2str(p,n,10)    ", aPtr)

     ? ""
     ? "control: the same operations on a 64-byte string"
     cSmall = space(64)
     aS=[] aS2=[]
     for r = 1 to REPS
         t1=clock() for i=1 to K x = len(cSmall)             next t2=clock()
         aS  + ((t2-t1)/clockspersecond()*1000)
         t1=clock() for i=1 to K x = substr(cSmall,10,10)    next t2=clock()
         aS2 + ((t2-t1)/clockspersecond()*1000)
     next
     Report("len(64B)           ", aS)
     Report("substr(64B,10,10)  ", aS2)
