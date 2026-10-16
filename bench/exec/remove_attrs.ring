write("tmp_a.txt", "hi")
? "A exists before: " + fexists("tmp_a.txt")
r = remove("tmp_a.txt")
? "B return: [" + r + "] type=" + type(r)
? "C exists after: " + fexists("tmp_a.txt")
try r2 = remove("no_such_file_xyz.txt") ? "D missing returns: [" + r2 + "] type=" + type(r2) catch ? "D err " + cCatchError done
try r3 = remove(5) ? "E remove(5): [" + r3 + "]" catch ? "E err " + cCatchError done
o = new K
aL = attributes(o)
s = ""
for i = 1 to len(aL) s = s + aL[i] + " " next
? "F attributes order: " + s
p = new Child
aC = attributes(p)
s2 = ""
for i = 1 to len(aC) s2 = s2 + aC[i] + " " next
? "G child order: " + s2
e = new Empty
try ? "H empty class: len=" + len(attributes(e)) catch ? "H err " + cCatchError done
class K
	x = 1
	cName = "n"
class Child from K
	z = 3
class Empty
