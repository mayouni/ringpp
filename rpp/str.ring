# Ring++ -- string escapes, which Ring does not have.
#
# MEASURED ON RING 1.27: a string literal has NO escape processing of any
# kind. "a\nb" is FOUR characters -- a, backslash, n, b. So is "a\\b". The
# backslash is never special, in any of the three delimiters.
#
#     "..."   can hold ' and ` and \      cannot hold "
#     '...'   can hold " and `            cannot hold '
#     `...`   can hold " and ' and a real newline, and spans lines
#
# So two kinds of string cannot be written as a literal at all: one that
# needs all three quote characters, and one that needs a control character
# other than a newline.
#
# AND ONE OF THEM IS SILENT. `\"` does not escape anything, but it does not
# reliably fail either. Measured:
#
#     c = "a\" + "b\"      -->   c is  a\b\
#
# Two literals, `a\` and `b\`, concatenated. It parses, it runs, it raises
# nothing, and it is not the string anyone meant to write. That is F-55,
# and `ringpp check` reports it as rpp/string-escape.
#
# THE WAY OUT, and why it is a function and not a syntax. Because Ring
# passes the backslash through untouched, the escape sequence survives to
# run time exactly as it was typed. So it can be decoded there:
#
#     ? RppStr("He said \q5\q and left")     -->   He said "5" and left
#
# A new literal form (e"...") would have been shorter to type and would
# have stopped the file loading under plain ring.exe. This runs under plain
# Ring, with only this file loaded. `ringpp expand` then folds any
# RppStr() whose argument is a literal into a plain Ring expression --
#
#     "He said " + char(34) + "5" + char(34) + " and left"
#
# -- so the tool removes the cost without being required for the meaning.
# That is the whole shape of it: correct without ringpp, free with it.
#
# WHAT IT COSTS, measured (bench/str.ring, minima of 3): see that file.
#
# THE ESCAPES:
#
#     \\          backslash
#     \n \t \r    newline (10), tab (9), carriage return (13)
#     \0          NUL. Ring carries an embedded zero byte through
#                 concatenation and len() correctly -- measured -- but see
#                 F-14 before passing one to memcpy.
#     \q \s \g    "  '  `      named, for when the delimiter itself
#                              cannot be typed in the literal you are in
#     \" \' \`    the same three, spelled the familiar way, for when it can
#     \xNN        any byte, two hex digits, either case
#
# Anything else raises and names itself. An unknown escape is a typo, and a
# typo that silently leaves `\z` in the string is the defect this file
# exists to remove.

func RppStr(pcText)
	if NOT isString(pcText)
		raise("rpp string: RppStr() takes a string.")
	ok

	cRppBS = char(92)
	nRppLen = len(pcText)			# hoisted: F-41

	# Nothing to do, and this is the common case. Returning early keeps a
	# string with no escapes at the cost of one scan instead of a rebuild.
	if nRppLen = 0 return "" ok
	if substr(pcText, cRppBS) = 0 return pcText ok

	cRppOut = ""
	nRppI = 1

	while nRppI <= nRppLen
		cRppC = pcText[nRppI]		# s[i], never substr(): F-41

		if cRppC != cRppBS
			cRppOut += cRppC
			nRppI++
			loop
		ok

		if nRppI = nRppLen
			raise("rpp string: a lone " + cRppBS + " ends the string at " +
			      "position " + nRppI + ". Write " + cRppBS + cRppBS +
			      " for a literal backslash.")
		ok

		cRppE = pcText[nRppI + 1]

		if cRppE = cRppBS		cRppOut += cRppBS
		but cRppE = "n"			cRppOut += char(10)
		but cRppE = "t"			cRppOut += char(9)
		but cRppE = "r"			cRppOut += char(13)
		but cRppE = "0"			cRppOut += char(0)

		but cRppE = "q" or cRppE = char(34)	cRppOut += char(34)
		but cRppE = "s" or cRppE = char(39)	cRppOut += char(39)
		but cRppE = "g" or cRppE = char(96)	cRppOut += char(96)

		but cRppE = "x"
			if nRppI + 3 > nRppLen
				raise("rpp string: " + cRppBS + "x needs two hex digits, " +
				      "and the string ends first, at position " + nRppI + ".")
			ok

			nRppH = RppHexPair(pcText[nRppI + 2], pcText[nRppI + 3])
			if nRppH < 0
				raise("rpp string: " + cRppBS + "x" + pcText[nRppI + 2] +
				      pcText[nRppI + 3] + " at position " + nRppI +
				      " is not two hex digits.")
			ok

			cRppOut += char(nRppH)
			nRppI += 4
			loop

		else
			raise("rpp string: unknown escape " + cRppBS + cRppE +
			      " at position " + nRppI + ". Known: " + cRppBS + cRppBS +
			      " " + cRppBS + "n " + cRppBS + "t " + cRppBS + "r " +
			      cRppBS + "0 " + cRppBS + "q " + cRppBS + "s " + cRppBS +
			      "g " + cRppBS + "xNN. Write " + cRppBS + cRppBS + cRppE +
			      " if you meant a backslash followed by " + cRppE + ".")
		ok

		nRppI += 2
	end

	return cRppOut

# -1 when either character is not a hex digit. Ring 1.27 has no hex2dec()
# -- measured, R3 -- and a package that promises to need nothing but Ring
# does not get to borrow one.
func RppHexPair(cHi, cLo)
	nHi = RppHexDigit(cHi)
	nLo = RppHexDigit(cLo)

	if nHi < 0 or nLo < 0
		return -1
	ok

	return nHi * 16 + nLo

func RppHexDigit(cC)
	nC = ascii(cC)

	if nC >= 48 and nC <= 57  return nC - 48 ok		# 0-9
	if nC >= 97 and nC <= 102 return nC - 87 ok		# a-f
	if nC >= 65 and nC <= 70  return nC - 55 ok		# A-F

	return -1
