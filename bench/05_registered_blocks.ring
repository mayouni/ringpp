### B6 — isolate: is the slowdown the pBlocks scan, or just heap pressure?

func Churn nIter
     for i = 1 to nIter
         c = space(4096)
         c = ""
     next

func Bench cLabel, nIter
     t1 = clock()
     Churn(nIter)
     t2 = clock()
     ? cLabel + " : " + ((t2-t1)/clockspersecond()*1000) + " ms"

func MakeByAppend n
     a = []
     for i = 1 to n a + 0 next
     return a

func main
     ITER = 40000

     ? "=== arm A: hold lists built by list(n)  (block-allocated) ==="
     Bench("  0 held      ", ITER)
     aA = []
     for k = 1 to 500 aA + list(50) next
     Bench("  500 held    ", ITER)
     for k = 1 to 4500 aA + list(50) next
     Bench("  5000 held   ", ITER)

     ? ""
     ? "=== arm B: same memory, lists built by append (NO blocks) ==="
     aB = []
     Bench("  0 held      ", ITER)
     for k = 1 to 500 aB + MakeByAppend(50) next
     Bench("  500 held    ", ITER)
     for k = 1 to 4500 aB + MakeByAppend(50) next
     Bench("  5000 held   ", ITER)

     ? ""
     ? "=== arm C: hold nothing, just churn again ==="
     Bench("  control     ", ITER)
