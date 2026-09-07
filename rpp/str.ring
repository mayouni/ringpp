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
#     \xNN        any BYTE, two hex digits, either case
#     \uNNNN      any CODEPOINT up to FFFF, as UTF-8 bytes
#     \u{N...}    the same, one to six digits, the whole range to 10FFFF
#
# BYTE and CODEPOINT are different questions, and Ring answers only the
# first. A Ring string is a byte string -- measured on 1.27, the literal
# e-acute is 2 bytes, CJK is 3, an emoji is 4 -- and char() is byte-wise
# and TRUNCATES SILENTLY: char(0x4E2D) returns byte 45, an ASCII hyphen,
# for the CJK character that was asked for. There is no way to write a
# codepoint in Ring. \u is that way, and it produces bytes indistinguishable
# from the literal: RppStr of a backslash-u-4E2D escape compares EQUAL to a
# pasted 中, and the same holds for the e-acute, emoji and Arabic cases.
#
# A surrogate half (D800-DFFF) is REFUSED rather than encoded. It is not a
# character -- it exists only inside UTF-16 -- and encoding one produces
# UTF-8 that nothing downstream can read back.
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

		but cRppE = "u"
			# A CODEPOINT, not a byte -- and Ring gives no other way to
			# write one. char() is byte-wise and TRUNCATES without a word:
			# measured on 1.27, char(0x4E2D) returns byte 45, an ASCII
			# hyphen, for the CJK character the author asked for.
			nRppJ = nRppI + 2
			nRppCp = 0

			if nRppJ <= nRppLen and pcText[nRppJ] = "{"
				# \u{H...H} -- one to six digits, the whole range
				nRppK = nRppJ + 1
				nRppD = 0

				while nRppK <= nRppLen and pcText[nRppK] != "}"
					nRppH = RppHexDigit(pcText[nRppK])
					if nRppH < 0
						raise("rpp string: " + cRppBS + "u{...} takes hex " +
						      "digits, and [" + pcText[nRppK] + "] at position " +
						      nRppK + " is not one.")
					ok
					nRppCp = nRppCp * 16 + nRppH
					nRppD++
					nRppK++
				end

				if nRppK > nRppLen
					raise("rpp string: " + cRppBS + "u{ at position " + nRppI +
					      " is never closed with }.")
				ok
				if nRppD = 0 or nRppD > 6
					raise("rpp string: " + cRppBS + "u{...} takes one to six " +
					      "hex digits, not " + nRppD + ", at position " +
					      nRppI + ".")
				ok

				nRppI = nRppK + 1
			else
				# \uNNNN -- exactly four, the familiar spelling
				if nRppJ + 3 > nRppLen
					raise("rpp string: " + cRppBS + "u needs four hex digits " +
					      "or {...}, and the string ends first, at position " +
					      nRppI + ".")
				ok

				for nRppQ = nRppJ to nRppJ + 3
					nRppH = RppHexDigit(pcText[nRppQ])
					if nRppH < 0
						raise("rpp string: " + cRppBS + "u takes four hex " +
						      "digits, and [" + pcText[nRppQ] + "] at position " +
						      nRppQ + " is not one. For a codepoint past FFFF " +
						      "write " + cRppBS + "u{...}.")
					ok
					nRppCp = nRppCp * 16 + nRppH
				next

				nRppI = nRppJ + 4
			ok

			cRppOut += RppUtf8(nRppCp)
			loop

		else
			raise("rpp string: unknown escape " + cRppBS + cRppE +
			      " at position " + nRppI + ". Known: " + cRppBS + cRppBS +
			      " " + cRppBS + "n " + cRppBS + "t " + cRppBS + "r " +
			      cRppBS + "0 " + cRppBS + "q " + cRppBS + "s " + cRppBS +
			      "g " + cRppBS + "xNN " + cRppBS + "uNNNN " + cRppBS +
			      "u{N...}. Write " + cRppBS + cRppBS + cRppE +
			      " if you meant a backslash followed by " + cRppE + ".")
		ok

		nRppI += 2
	end

	return cRppOut

# One codepoint as UTF-8 bytes.
#
# Ring strings are BYTE strings: measured on 1.27, the literal "e-acute" is
# 2 bytes, CJK is 3, an emoji is 4, and char(0xC3) + char(0xA9) compares
# EQUAL to the literal. So a codepoint is written by producing its bytes,
# and there is no other way -- char() is byte-wise and truncates silently.
#
# `ringpp expand` folds \u at build time and must produce these same bytes,
# so this encoder and the one in src/cache.zig are the same function written
# twice. The T1 fold gate runs both paths and compares the output, which is
# what keeps them honest.
func RppUtf8(nCp)
	if nCp < 0 or nCp > 0x10FFFF
		raise("rpp string: U+" + upper(hex(nCp)) + " is not a codepoint -- " +
		      "the range ends at 10FFFF.")
	ok

	# D800-DFFF are surrogate halves. They are not characters, they exist
	# only inside UTF-16, and encoding one produces invalid UTF-8 that
	# nothing downstream will read back. Refused rather than emitted.
	if nCp >= 0xD800 and nCp <= 0xDFFF
		raise("rpp string: U+" + upper(hex(nCp)) + " is a surrogate half, " +
		      "not a character. Write the codepoint itself with \u{...}.")
	ok

	if nCp < 0x80
		return char(nCp)
	ok

	if nCp < 0x800
		return char(0xC0 | (nCp >> 6)) +
		       char(0x80 | (nCp & 0x3F))
	ok

	if nCp < 0x10000
		return char(0xE0 | (nCp >> 12)) +
		       char(0x80 | ((nCp >> 6) & 0x3F)) +
		       char(0x80 | (nCp & 0x3F))
	ok

	return char(0xF0 | (nCp >> 18)) +
	       char(0x80 | ((nCp >> 12) & 0x3F)) +
	       char(0x80 | ((nCp >> 6) & 0x3F)) +
	       char(0x80 | (nCp & 0x3F))

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
