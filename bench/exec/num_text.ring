# WHICH TEXTS ARE NUMBERS, probed on Ring 1.27, the official build and the
# oracle -- arithmetic and `=` together, because on Ring they are ONE rule
# (ring_vm_stringtonum, vendor/ring-vm/src/vmexpr.c:892) and Ring++ had it
# twice, differently.
#
#   ""          is 0 ("Support converting NULL to Zero")
#   "   "       is NOT: strtod converts nothing, and only the truly empty
#               string is NULL -- R41 in arithmetic (row 02). Ring++ read it
#               as 0 until 2026-09-23.
#   leading     strtod's own whitespace set, VT and FF included (04, 06, 19,
#               21)
#   trailing    only ring_general_looksempty's set -- space, CR, LF, tab --
#               so a trailing VT is not a number (05, 20)
#   "1_000"     not a number: strtod stops at the `_`, where Zig's
#               parseFloat takes it as a digit separator (07, 17)
#
# Every row is caught, so each error prints and the run goes on.
try ? "01 1 - ''          " + (1 - "")               catch ? "01 " + cCatchError done
try ? "02 1 - '   '       " + (1 - "   ")            catch ? "02 " + cCatchError done
try ? "03 1 - ' 7 '       " + (1 - " 7 ")            catch ? "03 " + cCatchError done
try ? "04 1 - VT+'7'      " + (1 - (char(11) + "7")) catch ? "04 " + cCatchError done
try ? "05 1 - '7'+VT      " + (1 - ("7" + char(11))) catch ? "05 " + cCatchError done
try ? "06 1 - FF+'7'      " + (1 - (char(12) + "7")) catch ? "06 " + cCatchError done
try ? "07 1 - '1_000'     " + (1 - "1_000")          catch ? "07 " + cCatchError done
try ? "08 1 - '.5'        " + (1 - ".5")             catch ? "08 " + cCatchError done
try ? "09 1 - '5.'        " + (1 - "5.")             catch ? "09 " + cCatchError done
try ? "10 1 - '0x10'      " + (1 - "0x10")           catch ? "10 " + cCatchError done
try ? "11 1 - '+5'        " + (1 - "+5")             catch ? "11 " + cCatchError done
try ? "12 1 - '1e2'       " + (1 - "1e2")            catch ? "12 " + cCatchError done
try ? "13 1 - '1e'        " + (1 - "1e")             catch ? "13 " + cCatchError done
try ? "14 1 - '-'         " + (1 - "-")              catch ? "14 " + cCatchError done
try ? "15 0.5 = '.5'      " + (0.5 = ".5")           catch ? "15 " + cCatchError done
try ? "16 5 = '5.'        " + (5 = "5.")             catch ? "16 " + cCatchError done
try ? "17 1000 = '1_000'  " + (1000 = "1_000")       catch ? "17 " + cCatchError done
try ? "18 5 = '+5'        " + (5 = "+5")             catch ? "18 " + cCatchError done
try ? "19 5 = VT+'5'      " + (5 = char(11) + "5")   catch ? "19 " + cCatchError done
try ? "20 5 = '5'+VT      " + (5 = "5" + char(11))   catch ? "20 " + cCatchError done
try ? "21 5 = FF+'5'      " + (5 = char(12) + "5")   catch ? "21 " + cCatchError done
try ? "22 5 = '5 5'       " + (5 = "5 5")            catch ? "22 " + cCatchError done
try ? "23 1 - '0x'        " + (1 - "0x")             catch ? "23 " + cCatchError done
try ? "24 5 < '5.'        " + (5 < "5.")             catch ? "24 " + cCatchError done
