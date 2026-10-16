# A NAME ASSIGNED NOWHERE IS R24 WHERE RING READS IT -- NOT A REFUSAL.
#
# Every row was taken from Ring 1.27 first, on the oracle and on the
# official build, which agree on all of them (2026-09-27). Rule A refuses a
# bare name in a function that is not a local, because on Ring it would
# reach a GLOBAL of that name. When there is no global of that name
# anywhere in the unit, there is nothing for the read to be confused with:
# Ring raises R24 at the read, catchable, and ONLY IF THE LINE RUNS. Ring's
# own stdlibcore has `if elementcount < 1 then return ok` -- `then` is not
# a keyword -- and refusing it took Permutation() down on every list, where
# Ring fails only on an empty one (row 07 is that shape).
#
# THE FORM OF THE MESSAGE IS RING'S AND IT IS NOT UNIFORM: a read, `x + v`,
# add, insert and del name the variable; a SUBSCRIPTED root (`x[1] = 5`,
# `x[1] + v`, `x[1]++`, `x[1] += v`) does not. A method finds an attribute
# the object gained (addattribute) before it raises, as Ring does.
#
# AND A GLOBAL ASSIGNED SOMEWHERE BUT NOT YET is the same error, raised by
# ggetw at run time: it was a nil handed to vset or vpush, which answered
# "Bad parameter type!" (rows G1-G9, at the top level, which runs before
# Main). A global assigned NOWHERE was a compile-time refusal, "$global
# never assigned", which stopped the top level dead (rows G6-G8).
#
# LEFT OUT, both named in CLAUDE.md: `xx += 1` on a name nothing assigns
# (Ring R24; Ring++ runs on -- the uninitialised LOCAL is not checked at the
# read) and `xx++` (Ring R21; still refused).

try $zz[1] = 5 catch ? "G1 $zz[1] = 5: " + cCatchError done
try $zz + 1 catch ? "G2 $zz + 1: " + cCatchError done
try $zz[1] += 1 catch ? "G3 $zz[1] += 1: " + cCatchError done
try $zz[1] + 2 catch ? "G4 $zz[1] + 2: " + cCatchError done
try $zz[1]++ catch ? "G5 $zz[1]++: " + cCatchError done
try yy[1] = 5 catch ? "G6 yy[1] = 5: " + cCatchError done
try yy + 1 catch ? "G7 yy + 1: " + cCatchError done
try yy[1]++ catch ? "G8 yy[1]++: " + cCatchError done
try add($ww, 5) catch ? "G9 add($ww, 5): " + cCatchError done
try insert($ww, 1, 5) catch ? "G10 insert($ww, 1, 5): " + cCatchError done
try del($ww, 1) catch ? "G11 del($ww, 1): " + cCatchError done
$zz = [1, 2]
$zz + 3
? "G12 once set, the append works: " + len($zz)

func main
	try f01() catch ? "01 read: " + cCatchError done
	try f02() catch ? "02 x[1] = 5: " + cCatchError done
	try f03() catch ? "03 x + 1 statement: " + cCatchError done
	try f04() catch ? "04 x[1] + 2: " + cCatchError done
	try f05() catch ? "05 x[1]++: " + cCatchError done
	try f06() catch ? "06 x[1][2] = 5: " + cCatchError done
	try ? "07 in an untaken branch: " + f07([1]) catch ? "07: " + cCatchError done
	try ? "08 in a taken branch: " + f07([]) catch ? "08: " + cCatchError done
	o = new K
	try o.m1() catch ? "09 method read: " + cCatchError done
	addattribute(o, "added")
	o.added = "from the object"
	try ? "10 method read of an added attribute: " + o.m2() catch ? "10: " + cCatchError done
	try ? "11 mixed case: " + f11() catch ? "11: " + cCatchError done
	try ? "12 y = x + 1: " + f12() catch ? "12: " + cCatchError done
	try f13() catch ? "13 x[1] += 5: " + cCatchError done
	try f14() catch ? "14 fn $qq[1] = 5: " + cCatchError done
	try f15() catch ? "15 fn $qq + 1: " + cCatchError done
	try f16() catch ? "16 fn add($vv, 5): " + cCatchError done
	try ? "17 type of the read: " + f17() catch ? "17: " + cCatchError done
	? "18 ran on"
	top()

func top
	? "19 --"

func f01
	? xx
func f02
	xx[1] = 5
func f03
	xx + 1
func f04
	xx[1] + 2
func f05
	xx[1]++
func f06
	xx[1][2] = 5
func f07 a
	n = len(a)
	if n < 1 then return "early" ok
	return "late"
func f11
	return MixedCaseName
func f12
	y = xx + 1
	return y
func f13
	xx[1] += 5
func f14
	$qq[1] = 5
func f15
	$qq + 1
func f16
	add($vv, 5)
func f17
	then
	return type(then)

class K
	def m1
		? xx
	def m2
		return added
