# F-137: a multi-line string literal in a CRLF file. Ring opens every source file in text mode (state.c:163, "r"), so on
# Windows the C runtime turns each CR LF into LF before the scanner reads a byte, and a literal that spans lines holds LF
# only; on Linux "r" is "rb" and the CR stays, on Ring as here. THIS FILE IS CRLF ON PURPOSE (.gitattributes keeps it
# -text): Windows answers 8 and LF for the first row, Linux 10 and CR LF, and each platform's oracle is the expectation.
# Before 2026-10-28 Ring++ kept the CR on Windows too: `8 : 97 98 10 99 100 10 101 102` on Ring, `10 : 97 98 13 10 ...`
# here. An eval'd string is not a file, so its CR LF stays on both runtimes and both platforms (the last-but-one row).
s = "ab
cd
ef"
? Codes(s)
? Codes('one
two')
? Codes(`x

y`)
? Codes("end
")
? s = "ab" + nl + "cd" + nl + "ef"
aL = [ "p
q", "r" ]
? Codes(aL[1])
eval("t = 'x" + char(13) + nl + "y'")
? Codes(t)
? Codes(Inner())

func Codes s
	c = "" + len(s) + " :"
	for i = 1 to len(s)
		c += " " + ascii(substr(s, i, 1))
	next
	return c

func Inner
	return "in
fn"
