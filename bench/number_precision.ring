# A number cannot carry its own precision in Ring, and the default
# formatting hides float error rather than fixing it.
#
#     ring number_precision.ring
#
# This is why stzNumber stores every number AS A STRING: the moment a
# literal becomes a NUMBER, its precision is a property of the process
# (decimals()) rather than of the value. The class header says so.
#
# Measured cost of that workaround: see number_precision_cost.ring
# -- 7.4x for a minimal parse/format round-trip per operation.

x = 12.203
? "=== the written precision is not recoverable from the value"
? "  x = 12.203"
? "  string(x), decimals(2) default : [" + string(x) + "]"
decimals(5)
? "  after decimals(5)              : [" + string(x) + "]"
decimals(0)
? "  after decimals(0)              : [" + string(x) + "]"
decimals(2)
? "  x never changed. A PROCESS-GLOBAL did."

? ""
? "=== the default hides float error, it does not fix it"
? "  0.1 + 0.2                      = " + (0.1 + 0.2)
decimals(20)
? "  the same sum, decimals(20)     = " + (0.1 + 0.2)
decimals(2)
? "  the error was there the whole time; only the display changed."

? ""
? "=== fixed since 2020: the 14-digit ceiling"
aTry = [ "123456789.123450", "1234567890.123456" ]
for c in aTry
    try
        eval("n = " + c)
        ? "  " + c + " -> accepted (C19 Numeric Overflow in 2020)"
    catch
        ? "  " + c + " -> " + cCatchError
    done
next
