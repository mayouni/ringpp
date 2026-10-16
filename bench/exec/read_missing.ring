# F-103. read() of a file that will not open is Ring's R35, raised inside
# the C function and CATCHABLE (vendor/ring-vm/src/file_e.c:494); write()
# into a folder that does not exist is the same R35 (:532), and write() of a
# text that is not a string is "Bad parameter type!" (:539). Ring++ ended the
# process on the first two with an `Error:` line no try could see, and
# panicked on the third. Uncaught at the end, so the report prints.
try
	? read("no_such_file_here.txt")
catch
	? "caught: " + cCatchError
done
try
	write("no_such_folder_here/x.txt", "text")
catch
	? "caught: " + cCatchError
done
try
	write("read_missing_out.txt", 5)
catch
	? "caught: " + cCatchError
done
? "still running"
f()

func f
	? read("no_such_file_here.txt")
