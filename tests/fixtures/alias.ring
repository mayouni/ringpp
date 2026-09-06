# `#rpp: named X as A, B` -- a parameter reachable by readable KEYWORDS, not
# only by its own name.
#
# Measured over Softanza's library, that is the idiom it already uses by
# hand: :ReturnedAs at 81 sites, :Using at 47, :Of and :Sections at 45, with
# several aliases per parameter. They are decorative English chosen for how
# the call reads. Keying only on the parameter's own name would have made
# ClassifyQRT(:pcReturnType = ...) the only supported form -- worse than the
# hand-written unwrapping it was meant to replace.
#rpp: named pcReturnType as ReturnedAs, ReturnAs
func ClassifyQRT(pcReturnType)
	return pcReturnType

func main
	? ClassifyQRT(:ReturnedAs = :stzList)
	? ClassifyQRT(:ReturnAs = :stzHashList)
	? ClassifyQRT(:pcReturnType = :stzList)
	? ClassifyQRT(:stzList)
