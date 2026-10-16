# The empty string EQUALS 0, and spaces around a number are allowed -- `=`,
# `!=` and `switch`, probed on Ring 1.27, the official build and the oracle.
#
# Ring converts a string to a number with ONE rule, ring_vm_stringtonum
# (vendor/ring-vm/src/vmexpr.c:892), and its first line is "Support
# converting NULL to Zero": "" is 0. So `0 = ""` is TRUE, and so is
# `0 = NULL`. Ring++ answered FALSE for all of them until 2026-09-23 -- its
# equality read a string with Zig's parseFloat, which rejects "" and spaces,
# while arithmetic had had Ring's rule since 2026-09-11.
#
# THE ESTATE DEPENDS ON ROW 22. An engine handle is a number, a failed
# compile hands back the handle 0, and stzMathFunction / stzObjective test
# `if @pProg = ""` to refuse a bad expression. Answered false, every bad
# expression built an object, and numeric_autodiff and numeric_optimizer
# failed each assertion that a refusal HAPPENED.
#
# Row 12 is the case vmexpr.c:319 guards: "abc" converts to 0 but is not a
# number, so `0 = "abc"` is false.
? "01 0 = ''          " + (0 = "")
? "02 '' = 0          " + ("" = 0)
? "03 0 != ''         " + (0 != "")
? "04 '' != 0         " + ("" != 0)
? "05 0 = NULL        " + (0 = NULL)
? "06 0.0 = ''        " + (0.0 = "")
? "07 1 = ''          " + (1 = "")
? "08 0 = ' '         " + (0 = " ")
? "09 5 = ' 5'        " + (5 = " 5")
? "10 5 = '5 '        " + (5 = "5 ")
? "11 5 = ' 5 '       " + (5 = " 5 ")
? "12 0 = 'abc'       " + (0 = "abc")
? "13 16 = '0x10'     " + (16 = "0x10")
? "14 1000 = '1e3'    " + (1000 = "1e3")
? "15 5 = '5abc'      " + (5 = "5abc")
? "16 0.5 = ''        " + (0.5 = "")
? "17 5 = '5' + nl    " + (5 = "5" + nl)
? "18 5 = tab + '5'   " + (5 = tab + "5")
? "19 0 = '0'         " + (0 = "0")
? "20 -0 = ''         " + (-0 = "")
x = 0
? "21 x = ''          " + (x = "")
p = 0
if p = ""
	? "22 a null handle reads as NULL"
else
	? "22 a null handle does NOT read as NULL"
ok
switch 0
on ""
	? "23 switch 0 on '' matches"
other
	? "23 switch 0 on '' does not match"
off
switch ""
on 0
	? "24 switch '' on 0 matches"
other
	? "24 switch '' on 0 does not match"
off
