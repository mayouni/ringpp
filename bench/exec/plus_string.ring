# `+`, `-` and `*` with a string operand, as Ring 1.27 answers them
# (measured 2026-09-11 on both builds, C-8): number + numeric string adds
# (spaces around it ignored, the empty string is 0, "1.5" prints 2.50);
# number + anything else is R41; string + number concatenates; `-` and `*`
# read a numeric string as a number. Every case is caught so one file
# holds them all. Before this, `1 + "5"` was "51" here: the compiler folded
# the left constant into `"5" + 1`, a different operator on Ring.
try ? "A 1 + '5' = " + (1 + "5") catch ? "A err " + cCatchError done
try ? "B 1 + 'abc' = " + (1 + "abc") catch ? "B err " + cCatchError done
try ? "C 1 + '5abc' = " + (1 + "5abc") catch ? "C err " + cCatchError done
try ? "D 1 + '' = " + (1 + "") catch ? "D err " + cCatchError done
try ? "E 1 + ' 7 ' = " + (1 + " 7 ") catch ? "E err " + cCatchError done
try ? "F 1 + '1.5' = " + (1 + "1.5") catch ? "F err " + cCatchError done
try ? "G '5' + 1 = " + ("5" + 1) catch ? "G err " + cCatchError done
try ? "H 1.5 + 'x' = " + (1.5 + "x") catch ? "H err " + cCatchError done
try x = 1  x += "abc"  ? "I += = " + x catch ? "I err " + cCatchError done
try ? "J 1 - 'abc' = " + (1 - "abc") catch ? "J err " + cCatchError done
x = 1 + "5"
? "K standalone: " + x
try ? "M 1 - ' 7 ' = " + (1 - " 7 ") catch ? "M err " + cCatchError done
try ? "N 1 - '' = " + (1 - "") catch ? "N err " + cCatchError done
try ? "O 2 * ' 3 ' = " + (2 * " 3 ") catch ? "O err " + cCatchError done
