# Bitwise operators, A/B'd against the oracle (bits_run.ring).
#
# Ring reads both operands as numbers truncated to an integer: 2.5 & 1 is
# 0, "6" & 3 is 2, 1 << 32 is 4294967296, -1 >> 1 is -1, ~5 is -6 -- all
# probed on 1.27 (F-58's session, 2026-09-08). `^` is XOR; power is `**`.

func BAnd(a, b)
	return a & b

func BOr(a, b)
	return a | b

func BXor(a, b)
	return a ^ b

func BShl(a, b)
	return a << b

func BShr(a, b)
	return a >> b

func BNot(a)
	return ~a

func BStr(a)
	return "6" & a

func BFloat(a)
	return 2.5 & a

func BMix(a, b)
	return ((a << 8) | b) & 65535
