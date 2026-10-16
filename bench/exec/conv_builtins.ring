# The small conversion builtins Softanza calls and Ring++ lacked until
# 2026-09-23 -- the C character tests, hex2str, list2str, assert, the byte
# conversions, unsigned, and list/newlist in both arities -- each probed on
# Ring 1.27 first (`rnxc census --natives` found them).

? "01 isspace " + isspace(" " + tab) + isspace("") + isspace("a ")
? "02 isgraph " + isgraph("a!") + isgraph("a b")
? "03 ispunct " + ispunct("!?.") + ispunct("a!")
? "04 iscntrl " + iscntrl(char(1) + char(31)) + iscntrl("a")
? "05 isprint " + isprint("a b~") + isprint(tab)
? "06 isxdigit " + isxdigit("0aF9") + isxdigit("0g")
try isspace(5)  catch ? "07 " + cCatchError done

? "08 hex2str " + hex2str("414243")
try hex2str("414")  catch ? "09 " + cCatchError done
try hex2str("4G")  catch ? "10 " + cCatchError done

? "11 list2str [" + list2str(["a", "b"]) + "]"
? "12 list2str from 2 [" + list2str(["a", "b", "c"], 2) + "]"
? "13 list2str 1 to 2 [" + list2str(["a", "b", "c"], 1, 2) + "]"
? "14 list2str with a number [" + list2str(["a", 7, "c"]) + "]"
try list2str(["a"], 3)  catch ? "15 " + cCatchError done
try list2str("x")  catch ? "16 " + cCatchError done

assert(1)
assert("x")
? "17 assert passed twice"
try assert(0)  catch ? "18 " + cCatchError done
try assert("")  catch ? "19 " + cCatchError done
try assert([])  catch ? "20 " + cCatchError done

? "21 int2bytes " + len(int2bytes(1)) + "  round trip " + bytes2int(int2bytes(123456)) + " " + bytes2int(int2bytes(-5))
try bytes2int("abc")  catch ? "22 " + cCatchError done
try int2bytes(30000000000)  catch ? "23 " + cCatchError done
? "24 double2bytes " + len(double2bytes(2)) + "  round trip " + bytes2double(double2bytes(1.5))
? "25 float2bytes " + len(float2bytes(2)) + "  round trip " + bytes2float(float2bytes(0.25))

? "26 unsigned & " + unsigned(5, 3, "&") + "  << " + unsigned(1, 4, "<<") + "  / " + unsigned(10, 3, "/")
? "27 unsigned < " + unsigned(3, 5, "<") + "  | " + unsigned(4, 1, "|") + "  ^ " + unsigned(6, 3, "^")
# (Ring has no exponent literal: `1e19` reads as an uninitialised NAME, R24.)
nBig = 10000000000 * 1000000000
? "28 unsigned ~ is past 1e19: " + (unsigned(0, "~") > nBig)
? "29 unsigned 2 - 3 wraps past 1e19: " + (unsigned(2, 3, "-") > nBig)
try unsigned(1, 0, "/")  catch ? "30 " + cCatchError done
try unsigned(1, 64, "<<")  catch ? "31 " + cCatchError done
try unsigned(1, 2, "??")  catch ? "32 " + cCatchError done

a2 = list(2, 3)
? "33 list(2,3): " + len(a2) + " rows of " + len(a2[1]) + ", first " + a2[1][1]
n3 = newlist(3)
? "34 newlist(3): " + len(n3) + " items, " + n3[3]
n22 = newlist(2, 2)
? "35 newlist(2,2): " + len(n22) + " x " + len(n22[2])
try x = list(0)  catch ? "36 list(0): " + cCatchError done
