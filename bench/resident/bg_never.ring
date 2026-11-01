# RUNG 9: an admission started and never finished. The driver discards it before it admits anything else -- its compile
# waited for, the program as it was before it, and it is not admitted -- and says so. What this file itself defines stays.
? "never: start " + admitstart("admitcode", "forgotten", "func Forgotten" + nl + tab + "return 1" + nl)

func NeverKept x
	return "kept " + x
