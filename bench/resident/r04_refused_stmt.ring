# Refused whole: Bad04 reads a top-level name bare (Rule A).
nGlobal04 = 5
? "r04: this line must never print"

func Good04
	return 4

func Bad04
	return nGlobal04
