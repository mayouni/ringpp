### S4 — a wild address. Expect a hard crash with no Ring-level trace.
? "setting a pointer to address 4096 and reading it..."
q = nullptr()
setptr(q, 4096)
try
    c = ptr2str(q, 0, 8)
    ? "read ok?! len=" + len(c)
catch
    ? "caught: " + cCatchError
done
? "SURVIVED"
