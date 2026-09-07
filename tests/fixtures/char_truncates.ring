### Fixture for rpp/char-truncates (FINDINGS F-56).
###
### Three must fire and three must stay silent. The silent half is what makes
### the rule usable: Softanza's base/ holds 618 char(NNN) calls with a
### three-digit literal and not one is above 255 -- they are UTF-8 bytes
### assembled by hand, on purpose.

func Main()
	# REPORTED: a codepoint, delivered as byte 45 -- an ASCII hyphen.
	? char(0x4E2D)

	# REPORTED: an emoji, delivered as byte 0. A NUL is what F-14 turns
	# into a process death the moment it reaches memcpy.
	? char(128512)

	# REPORTED: negatives wrap too -- this is byte 255.
	? char(-1)

	# NOT reported: a byte, meant as a byte. This is how the 618 calls in
	# Softanza are written, three of them to one character.
	? char(226) + char(148) + char(128)

	# NOT reported: in range.
	? char(0xFF)

	# NOT reported: computed. It may well be a byte, and guessing would be
	# wrong on every one of those 618.
	n = 300
	? char(n)
