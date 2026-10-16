# A `for` loop given TEXT or a LIST, probed on Ring 1.27, the official build
# and the oracle. Ring++ answered `Bad parameter type!` for every row until
# 2026-09-23; these are Ring's own answers:
#
#   the START must already be a number   text, even "1", is R29 (02, 08)
#   the BOUND converts like any operand  "3" is 3, "" is 0, " 2 " is 2, a
#                                        non-number is R41 (01, 03-05, 09)
#   so does the STEP                     "2" is 2, "abc" is R41 (06, 11, 12)
#   a LIST                               R29 as a start or a bound, R28 as a
#                                        step (13-15)
#
# And the conversion does not reach the variable the bound was read from:
# after `for i = 1 to cTo`, cTo is still the STRING "2" (row 16). Ring++
# converts the bound in the temporary the loop holds it in.
run("01 1 to '3'       ", 1, "3", "none")
run("02 '1' to 3       ", "1", 3, "none")
run("03 1 to ''        ", 1, "", "none")
run("04 1 to ' 2 '     ", 1, " 2 ", "none")
run("05 1 to 'abc'     ", 1, "abc", "none")
run("06 1 to 5 step '2'", 1, 5, "2")
run("07 1 to '3.5'     ", 1, "3.5", "none")
run("08 'x' to 3       ", "x", 3, "none")
run("09 1 to '   '     ", 1, "   ", "none")
run("10 0 to ''        ", 0, "", "none")
run("11 1 to 3 step 'abc'", 1, 3, "abc")
run("12 3 to 1 step '-1' ", 3, 1, "-1")
try for i = 1 to [3]  ? i  next catch ? "13 1 to [3]: " + cCatchError done
try for i = [1] to 3  ? i  next catch ? "14 [1] to 3: " + cCatchError done
try for i = 1 to 3 step [1]  ? i  next catch ? "15 step [1]: " + cCatchError done
cTo = "2"
for i = 1 to cTo  next
? "16 the bound variable after the loop: " + cTo + "/" + type(cTo)

func run cWhat, cFrom, cTo, cStep
	s = cWhat + ":"
	try
		if cStep = "none"
			for i = cFrom to cTo  s += " " + i + "/" + type(i)  next
		else
			for i = cFrom to cTo step cStep  s += " " + i + "/" + type(i)  next
		ok
		s += "  after " + i
	catch
		s += " " + cCatchError
	done
	? s
