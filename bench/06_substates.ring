func Probe st, cName
     v = ring_state_findvar(st, cName)
     if isnumber(v)
        ? "  findvar('" + cName + "') -> NOT FOUND"
     else
        ? "  findvar('" + cName + "') -> " + v[3]
     ok

func main
     st = ring_state_init()
     ring_state_runcode(st, "nTotal = 7")
     Probe(st, "nTotal")
     Probe(st, "ntotal")
     Probe(st, "NTOTAL")

     ? ""
     ? "=== scanner as a service ==="
     aTok = ring_state_stringtokens(st, "x = 1 + 2")
     ? "  type=" + type(aTok) + " count=" + len(aTok)
     for t in aTok ? "   " + list2str(t) next

     ? ""
     ? "=== syntax check without running ==="
     st2 = ring_state_init()
     ? "  good code err: " + ring_state_scannererror(st2)
     aT2 = ring_state_stringtokens(st2, "x = 'unterminated")
     ? "  bad code err : " + ring_state_scannererror(st2)
     ring_state_delete(st2)

     ? ""
     ? "=== can the host silence sub-state errors? ==="
     st3 = ring_state_init()
     ring_state_runcode(st3, "ringvm_hideerrormsg(1)" + nl + "? 1/0" + nl + "? 'after'")
     ? "  host alive"
     ring_state_delete(st3)

     ring_state_delete(st)

     ? ""
     ? "=== eval() vs ring_state_runcode() cost ==="
     K = 2000
     t1=clock() for i=1 to K eval("zz = 1 + 1") next t2=clock()
     ? "  eval()            : " + ((t2-t1)/clockspersecond()*1000) + " ms for " + K

     s4 = ring_state_init()
     t1=clock() for i=1 to K ring_state_runcode(s4, "zz = 1 + 1") next t2=clock()
     ? "  state_runcode()   : " + ((t2-t1)/clockspersecond()*1000) + " ms for " + K
     ring_state_delete(s4)
