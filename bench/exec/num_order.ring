# ORDERING a number against a string, probed on Ring 1.27, the official
# build and the oracle. The string converts by the same rule as arithmetic
# and `=` (see num_text.ring) and a text that is not a number is R41.
#
# ROW 01 KILLED THE PROCESS until 2026-09-23, inside a `try`: cmpCheck let a
# numeric string through and valCmp then reached `@panic("comparison:
# unsupported operand types")`. A panic is not an error a program can catch,
# so no row after it ran either. Rows 12 and 13 are the same comparison
# where the estate would meet it -- an `if`, and a `for` bound.
try ? "01 5 < '6'         " + (5 < "6")       catch ? "01 " + cCatchError done
try ? "02 '6' > 5         " + ("6" > 5)       catch ? "02 " + cCatchError done
try ? "03 '' < 1          " + ("" < 1)        catch ? "03 " + cCatchError done
try ? "04 0 <= ''         " + (0 <= "")       catch ? "04 " + cCatchError done
try ? "05 ' 5' < 6        " + (" 5" < 6)      catch ? "05 " + cCatchError done
try ? "06 6 >= '6 '       " + (6 >= "6 ")     catch ? "06 " + cCatchError done
try ? "07 'abc' < 5       " + ("abc" < 5)     catch ? "07 " + cCatchError done
try ? "08 5 > '5abc'      " + (5 > "5abc")    catch ? "08 " + cCatchError done
try ? "09 1.5 < '2.5'     " + (1.5 < "2.5")   catch ? "09 " + cCatchError done
try ? "10 ' ' < 1         " + (" " < 1)       catch ? "10 " + cCatchError done
try ? "11 5 < ' 6 '       " + (5 < " 6 ")     catch ? "11 " + cCatchError done
x = "7"
if x > 3 ? "12 '7' > 3 in an if" else ? "12 '7' not > 3" ok
for i = 1 to "3"
	? "13 for to '3': " + i
next
