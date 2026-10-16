# Numeric loops in the shapes Ring 1.27 and Ring++ agree on (measured
# 2026-09-11): a float range steps by one from a float start (this HUNG
# here: the counter was stepped as an integer bit pattern), step 2, a
# negative step, a loop that never runs, an exit, a one-iteration loop, a
# name reused by a later loop. Not here: reading the variable AFTER its
# loop -- Ring leaves 6 after `for i = 1 to 5`, Ring++ scopes it (C-11).
s = ""
for i = 1.5 to 3.5 s = s + i + " " next
? "A float range: " + s
s = ""
for i = 1 to 5 step 2 s = s + i + " " next
? "B step 2: " + s
s = ""
for i = 5 to 1 step -1 s = s + i + " " next
? "C step -1: " + s
n = 0
for i = 1 to 0 n++ next
? "D never runs: " + n
s = ""
for i = 1 to 5 if i = 3 exit ok s = s + i + " " next
? "E exit at 3: " + s
n = 0
for i = 1 to 1 n++ next
? "F one iteration: " + n
s = ""
for i = 1 to 2 s = s + i next
for i = 5 to 6 s = s + i next
? "G a name reused by a later loop: " + s
s = ""
for i = 0.5 to 2 step 0.5 s = s + i + " " next
? "H float step: " + s
