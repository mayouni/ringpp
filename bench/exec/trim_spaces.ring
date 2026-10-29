# trim() removes SPACES only (genlib_e.c:788): a tab, a CR or a newline at either end stays. Ring++ removed " \t\r\n"
# until 2026-10-28 (F-139), so `nl + tab + "a" + nl` trimmed to 1 byte where Ring keeps 4 -- and Ring's own stdlibcore,
# whose endswith, startswith and split trim first, answered differently: endswith("abc" + nl, "c") is 0 on Ring.
# Found measuring F-137: a multi-line literal that begins LF TAB, 9,892 bytes on Ring and 9,889 here after trim().
load "stdlibcore.ring"
cr = char(13)
tab = char(9)
aT = [ nl + tab + "a" + nl,
       "  a  ",
       cr + nl + " a " + tab,
       " " + nl + " ",
       "   ",
       "",
       tab + " ",
       " " + tab + " x " + tab + " ",
       char(0) + " " ]
aN = [ "NL TAB a NL", "2 a 2", "CR NL _a_ TAB", "_ NL _", "3 spaces", "empty", "TAB _", "_ TAB _x_ TAB _", "NUL _" ]
for k = 1 to len(aT)
	? aN[k] + " -> " + Codes(trim(aT[k]))
next
? "endswith " + endswith("abc" + nl, "c")
? "startswith " + startswith(tab + "abc", "a")
? "split " + len(split(" a b " + tab, " "))
try
	trim(5)
catch
	? "number: " + cCatchError
done
try
	trim([1])
catch
	? "list: " + cCatchError
done

func Codes s
	c = "(" + len(s) + ")"
	for i = 1 to len(s)
		c += " " + ascii(substr(s, i, 1))
	next
	return c
