### B10 — the one structural win: never pass a big value by value

func Consume cText
     return len(cText)

func ConsumeP p, nLen
     return nLen

func main
     cBig = space(1048576)
     K = 3000

     ? "=== 1 MB string, " + K + " calls to a Ring function ==="
     t1=clock() for i=1 to K x = Consume(cBig) next t2=clock()
     nByVal = (t2-t1)/clockspersecond()*1000
     ? "  by value          : " + nByVal + " ms"

     p = varptr(:cBig, "char *")
     nLen = len(cBig)
     t1=clock() for i=1 to K x = ConsumeP(p, nLen) next t2=clock()
     nByPtr = (t2-t1)/clockspersecond()*1000
     if nByPtr = 0
        ? "  by pointer handle : below timer resolution (<1 ms)  --> speedup > " +
          floor(nByVal) + "x"
     else
        ? "  by pointer handle : " + nByPtr + " ms   speedup=" + (nByVal/nByPtr) + "x"
     ok

     ? ""
     ? "=== same, with a LIST instead of a string ==="
     aBig = list(100000)
     for i=1 to 100000 aBig[i] = i next
     t1=clock() for i=1 to K x = ConsumeList(aBig) next t2=clock()
     ? "  100k list by value: " + ((t2-t1)/clockspersecond()*1000) + " ms  <-- lists are by reference"

     ? ""
     ? "=== realistic: scan 1 MB of CSV for a delimiter count ==="
     cCsv = ""
     for i = 1 to 20000
         cCsv += "" + i + ",alpha,beta,gamma,42" + nl
     next
     ? "  csv bytes = " + len(cCsv)

     t1=clock()
     n1 = 0
     nL = len(cCsv)
     for i = 1 to nL
         if cCsv[i] = ","  n1++ ok
     next
     t2=clock()
     ? "  A char loop       : " + ((t2-t1)/clockspersecond()*1000) + " ms  (" + n1 + ")"

     t1=clock()
     aLines = str2list(cCsv)
     n2 = 0
     for cLine in aLines
         nLL = len(cLine)
         for j = 1 to nLL
             if cLine[j] = "," n2++ ok
         next
     next
     t2=clock()
     ? "  B str2list + scan : " + ((t2-t1)/clockspersecond()*1000) + " ms  (" + n2 + ")"

     t1=clock()
     aSplit = str2list(cCsv)
     t2=clock()
     ? "  C str2list only   : " + ((t2-t1)/clockspersecond()*1000) + " ms  (" + len(aSplit) + " lines)"

func ConsumeList aL
     return len(aL)
