# Two defects, reproduced on Ring 1.27. Run under Ring:
#
#     ring loop_and_switch.ring
#
# 1. `switch` takes ONE value per `on`. Give it two and Ring accepts the
#    syntax, matches nothing, reports nothing, and routes the value to
#    `other`. Not a refusal -- a silent wrong answer.
#
# 2. The loop variable after the loop follows FOUR different rules,
#    depending on how the loop ended and which `for` was used. The first
#    is the one Mansour raised upstream: `for i = 1 to 5` states a range,
#    and 6 is not in it.
#
# Expected on 1.27:
#     fell to other
#     i = 6      <- outside the stated range
#     j = 3      <- the actual last value: a different rule
#     k = 1      <- the start value, though no iteration ran
#     m =        <- nothing at all: for/in is a separate mechanism

? "--- 1. switch with two values in one on"
v = 2
switch v
on 1, 2
    ? "matched 1-or-2"
on 3
    ? "matched 3"
other
    ? "fell to other"
off

? "--- 2. the loop variable afterwards"

for i = 1 to 5
next
? "i = " + i

for j = 1 to 5
    if j = 3 exit ok
next
? "j = " + j

for k = 1 to 0
next
? "k = " + k

aL = [10, 20, 30]
for m in aL
next
? "m = " + m
