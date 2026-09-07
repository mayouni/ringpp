### Gate: RppStr() decodes the escapes Ring does not have.
###
### FINDINGS F-55. Ring performs NO escape processing in a string literal --
### "a\nb" is four characters on 1.27 -- so the sequences survive to run time
### exactly as typed and can be decoded there. This gate pins the vocabulary
### and, just as importantly, pins what must RAISE: an unknown escape left
### silently in the string is the defect the whole thing exists to remove.

load "../rpp/str.ring"

func Main()
	nFail = 0

	# the three quote characters, named -- the case no literal can express
	nFail += Chk("He said \q5\q",  "He said " + char(34) + "5" + char(34))
	nFail += Chk("it\ss fine",     "it" + char(39) + "s fine")
	nFail += Chk("a \g b",         "a " + char(96) + " b")
	nFail += Chk("\q\s\g",         char(34) + char(39) + char(96))

	# the familiar spellings, for when the delimiter IS typable
	nFail += Chk('say \"hi\"',     "say " + char(34) + "hi" + char(34))
	nFail += Chk("it\'s",          "it" + char(39) + "s")

	# control bytes. Ring carries an embedded NUL through concatenation and
	# len() correctly -- measured -- but see F-14 before it meets memcpy.
	nFail += Chk("a\nb", "a" + char(10) + "b")
	nFail += Chk("a\tb", "a" + char(9)  + "b")
	nFail += Chk("a\rb", "a" + char(13) + "b")
	nFail += Chk("a\0b", "a" + char(0)  + "b")

	# backslashes are not collapsed by Ring, so \\ is ours to collapse
	nFail += Chk("a\\b",               "a" + char(92) + "b")
	nFail += Chk("C:\\GitHub\\ringpp", "C:" + char(92) + "GitHub" + char(92) + "ringpp")

	# any byte at all
	nFail += Chk("\x41\x62",     "Ab")
	nFail += Chk("\x4a\x4A",     "JJ")
	nFail += Chk("\x22\x27\x60", char(34) + char(39) + char(96))
	nFail += Chk("\x00",         char(0))

	# CODEPOINTS. Ring gives no other way to write one: char() is byte-wise
	# and truncates silently -- char(0x4E2D) is byte 45, an ASCII hyphen.
	# Each of these is compared against the PASTED character, so the gate
	# fails if the UTF-8 encoder and the source file ever disagree.
	nFail += Chk("\u00e9",     "é")
	nFail += Chk("\u4E2D",     "中")
	nFail += Chk("\u{1F600}",  "😀")
	nFail += Chk("\u{41}",     "A")
	nFail += Chk("\u0645\u0631\u062D\u0628\u0627", "مرحبا")
	nFail += Chk("\u{0}",      char(0))

	# untouched when there is nothing to decode: the early-out path
	nFail += Chk("plain text", "plain text")
	nFail += Chk("", "")

	# and what must raise rather than pass something wrong through
	nFail += Bad("a\zb",            "unknown escape")
	nFail += Bad("ends" + char(92), "lone")
	nFail += Bad("\xZZ",            "hex digits")
	nFail += Bad("\x4",             "ends first")
	# a surrogate half is not a character -- it exists only inside UTF-16,
	# and encoding one produces UTF-8 nothing can read back
	nFail += Bad("\uD800",         "surrogate")
	nFail += Bad("\u{110000}",     "not a codepoint")
	nFail += Bad("\u12",           "four hex digits")
	nFail += Bad("\uZZZZ",         "is not one")
	nFail += Bad("\u{12",          "never closed")
	nFail += Bad("\u{}",           "one to six")
	nFail += Bad("\u{1234567}",    "one to six")

	? ""
	? "" + nFail + " failed"

func Chk(cIn, cWant)
	try
		cGot = RppStr(cIn)
	catch
		? "  FAIL  " + Vis(cIn) + " raised: " + cCatchError
		return 1
	done

	if cGot = cWant and len(cGot) = len(cWant)
		return 0
	ok

	? "  FAIL  " + Vis(cIn) + " -> " + Vis(cGot) + "  wanted " + Vis(cWant)
	return 1

func Bad(cIn, cWantIn)
	try
		cGot = RppStr(cIn)
		? "  FAIL  " + Vis(cIn) + " should raise, gave " + Vis(cGot)
		return 1
	catch
		if substr(cCatchError, cWantIn) = 0
			? "  FAIL  " + Vis(cIn) + " raised the wrong thing: " + cCatchError
			return 1
		ok
		return 0
	done

# Control bytes as <n>, so a NUL in the output is readable in a diff.
func Vis(c)
	cR = ""
	nL = len(c)
	for i = 1 to nL
		n = ascii(c[i])
		if n < 32
			cR += "<" + n + ">"
		else
			cR += c[i]
		ok
	next
	return "[" + cR + "]"
