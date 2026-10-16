# find(aList, value, nColumn, cAttribute): Ring's FOURTH form searches a
# list of OBJECTS on one attribute (vendor/ring-vm/src/list_e.c:258 and
# rlist.c:1247). Ring++ refused it as "a builtin called with the wrong
# number of arguments", and Ring's own stdfunctions.ring calls it in
# std_find3. Every row taken from Ring 1.27 first.
#
# THE RULES, from the source and then measured: only a column above 0
# searches at all (0 answers 0); column 1 means each element IS the object,
# column N the N-th item of each sub-list; the attribute name is folded to
# lower case, the value is not (strcmp); a string needle only meets a
# string attribute and a number only a number; an element that is not an
# object is skipped; an object WITHOUT the attribute is an error at once.

o1 = new P { name = "a"  id = 1 }
o2 = new P { name = "b"  id = 2 }
o3 = new P { name = "c"  id = 3 }
aObjs = [o1, o2, o3]

? "01 by string: " + find(aObjs, "b", 1, "name")
? "02 by number: " + find(aObjs, 3, 1, "id")
? "03 column 0: " + find(aObjs, "b", 0, "name")
? "04 not found: " + find(aObjs, "z", 1, "name")
? "05 attribute name folded: " + find(aObjs, "c", 1, "NAME")
? "06 value is case-sensitive: " + find(aObjs, "B", 1, "name")
? "07 string needle, number attribute: " + find(aObjs, "2", 1, "id")
? "08 number needle, string attribute: " + find(aObjs, 1, 1, "name")
? "09 non-objects skipped: " + find([5, "x", [1], o2], "b", 1, "name")
aPairs = [ [10, o1], [20, o2], [30, o3] ]
? "10 column 2: " + find(aPairs, "c", 2, "name")
? "11 column past the end: " + find(aPairs, "c", 3, "name")
try ? "12 missing attribute: " + find(aObjs, "b", 1, "nope") catch ? "12 missing attribute: " + cCatchError done
try ? "13 attribute not a string: " + find(aObjs, "b", 1, 5) catch ? "13 attribute not a string: " + cCatchError done
? "14 empty list: " + find([], "b", 1, "name")
oq = new Q
try ? "15 an object missing it, before the match: " + find([oq, o2], "b", 1, "name") catch ? "15: " + cCatchError done
? "16 the match comes first: " + find([o2, oq], "b", 1, "name")

class P
	name = ""
	id = 0

class Q
	other = 0
