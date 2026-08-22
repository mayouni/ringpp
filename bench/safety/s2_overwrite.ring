### S2 — write past the end of a buffer
cB = space(16)
cGuard = space(16)
p = varptr(:cB, "char *")
? "writing 4096 bytes into a 16-byte buffer..."
memcpy(p, space(4096), 4096)
? "SURVIVED the write"
? "len(cB)     = " + len(cB)
? "len(cGuard) = " + len(cGuard)
a = []
for i = 1 to 1000 a + i next
? "allocator still works, sum=" + len(a)
? "DONE"
