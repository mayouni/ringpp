# dec() is C's sscanf(s, "%llx") on Ring (genlib_e.c:326), F-141: white space skipped, an optional sign and 0x, hex digits up
# to the first other character, a minus wrapping the unsigned value, saturation past 64 bits, and E7 when no digit is read.
# Ring++ parsed the whole string strictly and answered 0 for every row it could not read: dec("0x41") was 0, not 65.
# Found re-running the Softanza site's examples on Ring++: StzCharQ(dec("0x10481")).Content() printed nothing.

aRows = [ "0x41", "0X41", "  ff", "ff zz", "12zz", "1f.5", "FF", "+ff", "10481", "0x10481", "0x1g", "0",
          "-1", "-ff", "ffffffffffffffff", "10000000000000000", "fffffffffffffffff",
          "", "zz", "0x", "x41", "0xg" ]
for cRow in aRows
	try
		? "[" + cRow + "] " + dec(cRow)
	catch
		? "[" + cRow + "] error:" + cCatchError
	done
next

? dec(char(9) + "1a")
try
	? dec(5)
catch
	? "number: " + cCatchError
done
