# The system builtins Softanza calls and Ring++ lacked until 2026-09-23 --
# dir, date, time, timelist, adddays, diffdays, sysget/sysset/sysunset,
# tempname, chdir, exefilename, getpathtype, windowsnl, system, rename --
# each probed on Ring 1.27 first. Found by `rnxc census --natives`: a name
# nobody defines compiles to a native call and fails only when it RUNS.
#
# Values that move with the clock or the machine are printed by SHAPE
# (digits blanked) or checked against each other, never printed raw.

aD = dir("dir_fixture")
? "01 dir: " + len(aD) + " entries"
for e in aD  ? "   " + e[1] + " " + e[2]  next
try dir("no_such_folder_here")  catch ? "02 " + cCatchError done
try dir(5)  catch ? "03 " + cCatchError done

cDate = date()
? "04 date " + shape(cDate)
aT = timelist()
? "05 timelist has " + len(aT) + " items"
? "06 date() = day/month/year of timelist: " + (cDate = aT[6] + "/" + aT[10] + "/" + aT[19])
? "07 time " + shape(time())
? "08 the hour, minutes, seconds: " + shape(aT[7]) + " " + shape(aT[11]) + " " + shape(aT[13])
? "09 day and month names are words: " + isalpha(aT[1]) + isalpha(aT[2]) + isalpha(aT[3]) + isalpha(aT[4])

? "10 adddays 28/02/2024 +1  " + adddays("28/02/2024", 1)
? "11 adddays 31/12/2023 +1  " + adddays("31/12/2023", 1)
? "12 adddays 01/03/2023 -1  " + adddays("01/03/2023", -1)
? "13 adddays 15/06/2023 +365 " + adddays("15/06/2023", 365)
? "14 diffdays 01/03/2024 28/02/2024 " + diffdays("01/03/2024", "28/02/2024")
? "15 diffdays 01/01/2023 01/01/2024 " + diffdays("01/01/2023", "01/01/2024")
try adddays("2024-02-28", 1)  catch ? "16 " + cCatchError done

? "17 sysset " + sysset("RPP_PROBE_VAR", "abc")
? "18 sysget " + sysget("RPP_PROBE_VAR")
? "19 sysunset " + sysunset("RPP_PROBE_VAR")
? "20 sysget after unset [" + sysget("RPP_PROBE_VAR") + "]"
? "21 sysget of nothing [" + sysget("RPP_SURELY_NOT_SET_7431") + "]"

cTmp = tempname()
? "22 tempname is a non-empty string: " + (isString(cTmp) and len(cTmp) > 0)

? "23 getpathtype file " + getpathtype("dir_fixture/a.txt")
? "24 getpathtype dir  " + getpathtype("dir_fixture")
? "25 getpathtype none " + getpathtype("dir_fixture/nothing.txt")

cNL = windowsnl()
? "26 windowsnl " + len(cNL) + " " + ascii(cNL[1]) + " " + ascii(cNL[2])
? "27 exefilename ends in .exe: " + (lower(right(exefilename(), 4)) = ".exe")

write("_rename_probe_a.txt", "x")
? "28 rename " + rename("_rename_probe_a.txt", "_rename_probe_b.txt")
? "29 renamed: " + fexists("_rename_probe_a.txt") + fexists("_rename_probe_b.txt")
remove("_rename_probe_b.txt")
? "30 rename of nothing " + rename("_rename_probe_none.txt", "_rename_probe_c.txt")

? "31 system exit 3: " + system("exit 3")

cHere = currentdir()
? "32 chdir to a folder " + chdir("dir_fixture")
? "33 now inside it: " + (right(currentdir(), 11) = "dir_fixture")
? "34 chdir back " + chdir(cHere)
? "35 chdir to nothing " + chdir("no_such_folder_here")

# Ring puts every statement after the first func INSIDE it (F-21), so the
# one helper is last.
func shape c
	s = ""
	for i = 1 to len(c)
		ch = substr(c, i, 1)
		if isdigit(ch) s += "#" else s += ch ok
	next
	return s
