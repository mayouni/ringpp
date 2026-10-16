# F-119. `for x in c step n`. The grammar gives the step as the loop's third
# child and the body began there, so the step was compiled as the body's
# first STATEMENT: a literal was discarded, a variable refused, and every
# element visited. Ring evaluates the step ONCE before the loop, starts the
# index at 1, re-measures the container every turn, and leaves when the step
# is 0 -- or negative with the index below the length, or positive with it
# above (vmjump.c ring_vm_jumpfor) -- so `step -1` over two or more elements
# runs nothing and over one runs once. A fractional step reads the element at
# the index's integer part. Row 13 is the numeric loop: its step of 0 ran for
# ever here and runs nothing on Ring, by the same test. Measured on both 1.27
# builds 2026-10-14, every row the same on both.

aL = 1:10
s = ""
for x in aL step 2
	s += " " + x
next
? "1 step 2:" + s
s = ""
for x in aL step 3
	s += " " + x
next
? "2 step 3:" + s
n = 4
s = ""
for x in aL step n
	s += " " + x
next
? "3 step n=4:" + s
s = ""
for c in "abcdefg" step 2
	s += c
next
? "4 string step 2: " + s
aM = [1, 2, 3, 4, 5, 6]
for x in aM step 2
	x = x * 10
next
? "5 write-back step 2: " + list2str(aM)
for x in aL step 2
	if x > 5 exit ok
next
? "6 exit at " + x
s = ""
for x in aL step -1
	s += " " + x
	if len(s) > 30 exit ok
next
? "7 step -1:" + s
s = ""
for x in aL step 1.5
	s += " " + x
	if len(s) > 60 exit ok
next
? "8 step 1.5:" + s
s = ""
for x in aL step 2
	if x = 5 loop ok
	s += " " + x
next
? "9 loop in step 2:" + s
s = ""
for x in aL step 20
	s += " " + x
next
? "10 step 20:" + s
k = 0
for x in aL step 2
	k++
	if k > 20 exit ok
	if x = 3 add(aL, 99) ok
next
? "11 add while iterating: k=" + k + " len=" + len(aL)
s = ""
k = 0
for x in [1, 2, 3] step 0
	s += " " + x
	k++
	if k > 5 exit ok
next
? "12 step 0:" + s
s = ""
k = 0
for i = 1 to 3 step 0
	s += " " + i
	k++
	if k > 5 exit ok
next
? "13 numeric step 0:" + s
s = ""
for x in [5] step -1
	s += " " + x
next
? "14 [5] step -1:" + s
s = ""
for x in [5, 6] step -1
	s += " " + x
next
? "15 [5,6] step -1:" + s
n = 2
s = ""
for x in 1:8 step n
	n = 3
	s += " " + x
next
? "16 step read once:" + s
try
	for x in [1, 2] step "a"
		? x
	next
catch
	? "17 step 'a': " + cCatchError
done
try
	for x in [1, 2] step [1]
		? x
	next
catch
	? "18 step [1]: " + cCatchError
done
s = ""
for x in [1, 2, 3, 4] step "2"
	s += " " + x
next
? "19 step '2':" + s
zz()
aR = [[1, 2], [3, 4], [5, 6]]
for r in aR step 2
	r[1] = 0
next
? "21 rows written through: " + aR[1][1] + aR[2][1] + aR[3][1]
s = ""
try
	for x in [] step -1
		s += " " + x
	next
	? "22 [] step -1:" + s
catch
	? "22 [] step -1 raised: " + cCatchError
done

func zz
	for x in [10, 20, 30, 40, 50] step 2
		? "20 in a function " + x
	next
