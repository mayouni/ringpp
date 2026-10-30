# ringvm_classeslist(), ringvm_cfunctionslist() and cfunctions(): Ring's VM reflection.
# A row per class: name, position, parent, methods, 0, package; a method:
# name, position, file, private. Positions and counts are each VM's own.
aC = ringvm_classeslist()
? len(aC)
for r in aC
	? "" + len(r) + " " + r[1] + " [" + r[3] + "] " + len(r[4]) + " " + type(r[2]) + " " + r[5] + " [" + r[6] + "]"
	for m in r[4]
		? "   " + m[1] + " " + len(m) + " " + type(m[2]) + " " + type(m[3]) + " " + m[4]
	next
next
aF = ringvm_cfunctionslist()
? type(aF) + " " + type(aF[1])
? find(aF, "len") > 0
? find(aF, "classes") > 0
? find(cfunctions(), "upper") > 0

class K
	def A return 1
	def B return 2
class L from K
	def C return 3
class M from L
