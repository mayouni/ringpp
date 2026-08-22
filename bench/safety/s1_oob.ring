### S1 — read past the end of a buffer
cB = space(16)
p = varptr(:cB, "char *")
? "16-byte buffer, reading 4096 bytes through the pointer..."
c = ptr2str(p, 0, 4096)
? "returned len = " + len(c)
? "SURVIVED"
