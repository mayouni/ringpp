st = ring_state_init()
ring_state_runcode(st, "nTotal = 7")
ring_state_runcode(st, "cName = 'ok'")

v1 = ring_state_findvar(st, "nTotal")
v2 = ring_state_findvar(st, "ntotal")
v3 = ring_state_findvar(st, "NTOTAL")
v4 = ring_state_findvar(st, "cName")
v5 = ring_state_findvar(st, "missing")

? "nTotal  : " + iff(isnumber(v1), "NOT FOUND", "" + v1[3])
? "ntotal  : " + iff(isnumber(v2), "NOT FOUND", "" + v2[3])
? "NTOTAL  : " + iff(isnumber(v3), "NOT FOUND", "" + v3[3])
? "cName   : " + iff(isnumber(v4), "NOT FOUND", "" + v4[3])
? "missing : " + iff(isnumber(v5), "NOT FOUND (correct)", "found?!")
ring_state_delete(st)

func iff b, x, y
     if b return x else return y ok
