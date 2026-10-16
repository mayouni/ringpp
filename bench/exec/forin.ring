# `for x in c`, as Ring 1.27 runs it (measured 2026-09-11 on both builds):
# x IS the element -- assigning it writes the list, a nested row writes
# through -- an append during the loop is iterated, a string iterates by
# character, an empty container runs nothing, a hash iterates its pairs.
# Not here: reading x AFTER the loop (Ring leaves "" after a full loop and
# the element after an exit; Ring++ scopes the variable -- C-11).
a = [1, 2, 3]
for x in a
	x = x * 10
next
? "A body assigns x -> list changes? " + a[1] + " " + a[3]
b = [1, 2]
n = 0
for x in b
	n++
	if n < 5 add(b, 9) ok
next
? "B appended during the loop: iterations " + n + " len " + len(b)
m = [ [1, 2], [3, 4] ]
for row in m
	row[1] = 0
next
? "D nested by reference: " + m[1][1] + " " + m[2][1]
s = ""
for ch in "abc"
	s = ch + s
next
? "E over a string: " + s
e = []
k = 0
for x in e
	k++
next
? "F empty: " + k
h = [ :a = 1, :b = 2 ]
t = ""
for p in h
	t = t + p[1] + "=" + p[2] + " "
next
? "G over a hash: " + t
c = [5, 6, 7]
found = 0
for x in c
	if x = 6 found = x exit ok
next
? "H exit: found " + found
