# Ring's C-style file functions -- fopen, fwrite, fread, fclose and the rest
# -- as Softanza calls them (stzFile, stzDiagram, stzExterCode), probed on
# Ring 1.27 first. The handle is a C POINTER on Ring, and Softanza tests it
# with `if fp != ""` and `if fp = NULL`: on Ring a pointer never equals the
# empty string, so a failed open is found only when fclose raises on it.

fp = fopen("_stdio_probe.txt", "w")
? "01 type " + type(fp) + "  isPointer " + isPointer(fp) + "  isList " + isList(fp)
? "02 fp != '' " + (fp != "") + "  fp = NULL " + (fp = NULL)
? "03 fwrite " + fwrite(fp, "hello" + nl + "world")
? "04 fputs " + fputs(fp, "!")
? "05 fputc " + fputc(fp, "?")
? "06 fflush " + fflush(fp)
? "07 fclose " + fclose(fp)

fp = fopen("_stdio_probe.txt", "r")
? "08 fgetc " + fgetc(fp) + fgetc(fp)
? "09 ftell " + ftell(fp)
? "10 fgets [" + fgets(fp, 100) + "]"
? "11 fread [" + fread(fp, 3) + "]"
? "12 feof " + feof(fp)
x = fread(fp, 100)
? "13 fread to the end [" + x + "]"
? "14 fread past the end: " + type(fread(fp, 10)) + " " + fread(fp, 10)
? "15 fgetc at the end: " + type(fgetc(fp)) + " " + fgetc(fp)
? "16 feof " + feof(fp)
? "17 fseek to 0 " + fseek(fp, 0, 0) + "  ftell " + ftell(fp)
? "18 fseek from the end " + fseek(fp, -3, 2) + "  fgetc " + fgetc(fp)
rewind(fp)
? "19 after rewind " + fgetc(fp)
? "20 ungetc " + ungetc(fp, "Z") + "  then " + fgetc(fp)
? "21 ferror " + ferror(fp)
clearerr(fp)
? "22 fclose " + fclose(fp)

fp = fopen("_stdio_probe_missing_dir/x.txt", "r")
? "23 a failed open: type " + type(fp) + "  != '' " + (fp != "") + "  = NULL " + (fp = NULL)
try fclose(fp)  catch ? "24 fclose on it: " + cCatchError done
try fwrite(fp, "x")  catch ? "25 fwrite on it: " + cCatchError done

try fopen(5, "r")  catch ? "26 " + cCatchError done
try fwrite("notafile", "x")  catch ? "27 " + cCatchError done

fp = fopen("_stdio_probe.txt", "a")
fwrite(fp, "+more")
fclose(fp)
? "28 appended: " + read("_stdio_probe.txt")
remove("_stdio_probe.txt")
? "29 gone: " + fexists("_stdio_probe.txt")
