# The same rule when the call is an assignment's right-hand side.
zzGo()
func zzGo
    x = zzBoom("a" +
               "b" +
               "c")
    ? x
func zzBoom p
    raise("from a three-line call on the RHS")
