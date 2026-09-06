# `#rpp:` anchors, all six directions in one file.
#
# The anchor is a COMMENT so that this file stays ordinary Ring: it loads
# and runs under plain ring.exe, just without whatever the anchor adds.
# That is the compatibility contract, and it is also why a misspelled verb
# has to be an error -- nothing else will ever mention it.

#rpp: cache
func Pure(n)
	if n < 2 return n ok
	return Pure(n-1) + Pure(n-2)

func SameLine(a)   #rpp: cache
	return a * 2

#rpp: cache
func Prints(n)
	? n
	return n

#rpp: cache
func WritesGlobal(n)
	$gCount = $gCount + 1
	return n

#rpp: cache
func ReadsClock(n)
	return n + clock()

#rpp: bogus
func Unknown(n)
	return n

# No anchor: impure and perfectly legal. Purity is only a question once
# something has asked for a cache.
func NoAnchor(n)
	? n
	return n
