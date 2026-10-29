# str2list: a piece ends at each newline; a carriage return just before it is dropped; what follows the LAST newline is
# a piece only if it is not empty. So "a\nb\n" is two lines, "" is none, and CRLF text gives clean lines (genlib_e.c:525).
# Before 2026-10-23 this VM split on the newline alone: one extra empty piece after a final newline (and one for the
# empty string), and every CRLF line kept its carriage return -- `len(str2list(read(f)))` read one high on any file
# ending in a newline. Found by a guard that counted the lines of AGENTS.md: 131 on Ring, 132 here.
cr = char(13)
aT = [ "a" + nl + "b",
       "a" + nl + "b" + nl,
       nl,
       "",
       "a",
       "a" + nl + nl + "b" + nl + nl,
       nl + "a",
       "a" + cr + nl + "b" + cr + nl,
       cr + nl,
       cr,
       "x" + cr,
       "a" + cr + cr + nl + "b",
       nl + nl + nl,
       cr + nl + cr + nl + "z" ]
aN = [ "a/b", "a/b/", "/", "empty", "a", "a//b//", "/a", "a CRLF b CRLF", "CRLF", "CR", "x CR", "a CR CRLF b", "///", "CRLF CRLF z" ]
for k = 1 to len(aT)
	aL = str2list(aT[k])
	cOut = aN[k] + " -> " + len(aL) + " ["
	for j = 1 to len(aL)
		cOut += " (" + len(aL[j]) + ")" + substr(aL[j], cr, "<CR>")
	next
	? cOut + " ]"
next
