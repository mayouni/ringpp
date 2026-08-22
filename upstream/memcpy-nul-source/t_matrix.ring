### Blast radius of the patch, exhaustively.
### It only changes ring_vm_api_ispointer(), which is only reached when a
### STRING argument is tested with ISPOINTER / ISCPOINTER. Four input
### classes cover every possible string; three must be unchanged.

func Show cLabel, f
     try
         ? "  " + cLabel + " -> " + call f()
     catch
         ? "  " + cLabel + " -> ERROR: " + trim(cCatchError)
     done

func main
     cEmpty  = ""                       # size 0        -> NULL ptr (unchanged)
     cNull   = "NULL"                   # size 4 "NULL" -> NULL ptr (unchanged)
     cPlain  = "hello"                  # normal        -> not a ptr (unchanged)
     cZero4  = char(0) + "ABC"          # size 4, lead 0 -> WAS ptr, NOW not
     cZeroN  = int2bytes(256)           # size 4, lead 0 -> WAS ptr, NOW not
     cZero8  = double2bytes(1.5)        # size 8, lead 0 -> WAS ptr, NOW not

     ? "=== isnull() ==="
     ? "  ''      : " + isnull(cEmpty)
     ? "  'NULL'  : " + isnull(cNull)
     ? "  'hello' : " + isnull(cPlain)

     ? "=== nullptr / ptrcmp (the branch's real purpose) ==="
     ? "  type(nullptr())      : " + type(nullptr())
     ? "  ptrcmp(null,null)    : " + ptrcmp(nullptr(), nullptr())

     ? "=== ptr2str with each string class as the POINTER argument ==="
     for a in [ ["''", cEmpty], ["'NULL'", cNull], ["'hello'", cPlain] ]
         try
             x = ptr2str(a[2], 0, 1)
             ? "  " + a[1] + " accepted as pointer, read len=" + len(x)
         catch
             ? "  " + a[1] + " rejected: " + trim(cCatchError)
         done
     next

     ? "=== getptr with each string class ==="
     for a in [ ["''", cEmpty], ["'NULL'", cNull], ["'hello'", cPlain] ]
         try
             ? "  " + a[1] + " getptr = " + getptr(a[2])
         catch
             ? "  " + a[1] + " rejected: " + trim(cCatchError)
         done
     next

     ? "=== memcpy source, the four classes ==="
     cBuf = space(32)
     p = varptr(:cBuf, "char *")
     memcpy(p, cPlain, 5)
     ? "  'hello'  copied -> [" + ptr2str(p, 0, 5) + "]"
     memcpy(p, cZero4, 4)
     ? "  0x00ABC  copied -> " + str2hex(ptr2str(p, 0, 4))
     memcpy(p, cZeroN, 4)
     ? "  i2b(256) copied -> " + str2hex(ptr2str(p, 0, 4))
     memcpy(p, cZero8, 8)
     ? "  d2b(1.5) copied -> " + bytes2double(ptr2str(p, 0, 8))
     ? "DONE"
