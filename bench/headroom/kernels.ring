### Headroom kernels — interpreted Ring side
func main
     ? "--- K1 scalar loop, 20,000,000 iterations ---"
     N = 20000000
     b = 3
     t1=clock()
     s = 0
     for i = 1 to N
         s += i * b
     next
     t2=clock()
     ? "K1 ring : " + ((t2-t1)/clockspersecond()*1000) + " ms   s=" + s

     ? ""
     ? "--- K2 dot product over 1,000,000 doubles ---"
     M = 1000000
     a = list(M)  c = list(M)
     for i = 1 to M a[i] = i * 0.5  c[i] = i * 0.25 next
     t1=clock()
     d = 0
     for i = 1 to M
         d += a[i] * c[i]
     next
     t2=clock()
     ? "K2 ring : " + ((t2-t1)/clockspersecond()*1000) + " ms   d=" + d

     ? ""
     ? "--- K3 byte scan, count ',' in ~5 MB ---"
     cChunk = "1234,alpha,beta,gamma,42" + nl
     cBig = ""
     for i = 1 to 200000 cBig += cChunk next
     nL = len(cBig)
     ? "  bytes = " + nL
     t1=clock()
     n = 0
     for i = 1 to nL
         if cBig[i] = "," n++ ok
     next
     t2=clock()
     ? "K3 ring : " + ((t2-t1)/clockspersecond()*1000) + " ms   n=" + n
