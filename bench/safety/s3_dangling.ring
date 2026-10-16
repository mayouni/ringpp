### S3 — pointer to a local that has gone out of scope
func MakePtr
     cLocal = "SECRET-VALUE-HERE"
     return getptr(varptr(:cLocal, "char *"))

func main
     n = MakePtr()
     # churn the pool so the freed slot is reused
     for i = 1 to 50
         c = "0123456789ABCDEF0123456789ABCDEF"
     next
     q = nullptr()
     setptr(q, n)
     ? "dangling read: [" + ptr2str(q, 0, 17) + "]"
     ? "SURVIVED"
