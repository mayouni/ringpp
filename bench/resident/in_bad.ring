# Refused whole: Bad reads a top-level name bare (Rule A); BadGood never arrives.
nBadGlobal = 1

func BadGood
	return 1

func Bad
	return nBadGlobal
