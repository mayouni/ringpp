# decimals(n), Ring's process-global for how many places a non-whole
# number prints with -- in `?`, in a concatenation, in string() (measured
# 2026-09-11 on both builds, C-10). Default 2; a whole number prints without
# a point at any setting; 0..90, else R33. Softanza sets it at load
# (StzDecimals(2) in stzNumber.ring:91), which is why the VM has it at all.
? "A default: " + (1/3)
? 1/3
decimals(4)
? "B after decimals(4): " + (1/3)
? 1/3
? "C string(): " + string(1/3)
? "D whole: " + 2.0
? "E 2.5: " + 2.5
decimals(0)
? "F decimals(0) 2.5: " + 2.5 + " 0.125: " + 0.125
decimals(2)
? "G back: " + (1/3)
try decimals(20) ? "H decimals(20): " + (1/3) catch ? "H err " + cCatchError done
try decimals(-1) ? "I decimals(-1): " + (1/3) catch ? "I err " + cCatchError done
