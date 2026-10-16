### T2 — pointer surface

cS = "HELLO WORLD"
p = varptr(:cS, "char *")
? "varptr type   : " + type(p)
? "ptr2str(p,0,5): [" + ptr2str(p, 0, 5) + "]"

n = getptr(p)
? "getptr        : " + n

q = nullptr()
setptr(q, n)
? "ptrcmp(p,q)   : " + ptrcmp(p, q)
? "q ptr2str     : [" + ptr2str(q, 0, 5) + "]"

### memcpy through a raw pointer to the SAME string
cT = space(16)
pt = varptr(:cT, "char *")
memcpy(pt, "ABCDEFGH", 8)
? "after ptr memcpy cT: [" + cT + "]"
? "len cT             : " + len(cT)

### memcpy pointer -> pointer
cU = space(8)
pu = varptr(:cU, "char *")
memcpy(pu, p, 5)
? "cU after ptr->ptr  : [" + cU + "]"
