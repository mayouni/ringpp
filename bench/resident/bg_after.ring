# RUNG 9: after the discard, nothing of it is in the program -- this file defines the name it brought -- and everything
# before it is; and the last file starts one too, which is not admitted
? "after: Forgotten() " + Forgotten() + ", NeverKept(7) " + NeverKept(7) + ", functions " + len(functions())
? "after: start another " + admitstart("admitcode", "last", "func Last" + nl + tab + "return 1" + nl)

func Forgotten
	return "this file's"
