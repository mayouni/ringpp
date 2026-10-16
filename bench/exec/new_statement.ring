# `new K(p)` ON A LINE OF ITS OWN, its value discarded.
#
# The estate writes its type tests exactly this way -- the CONSTRUCTION is
# the test and the object is thrown away:
#
#     func IsTable(paTable)
#         try
#             new stzTable(paTable)
#             return 1
#         catch
#             return 0
#         done
#
# Six sites in Softanza (stzTable.IsTable, stzEntity.IsEntity,
# stzSection.IsSection, stzHashList.NumberOfPairsQ and two
# _normalizeDateTime), every one refused, and each took its whole function
# with it. `init` runs and may raise either way, which is the entire point
# of the idiom.
#
# Found by reading the estate's refusal census rather than by hitting it:
# `new_expression` was 6 of 297 and read like a missing feature, which it
# was -- an expression statement whose value nobody wants.

? "-- 1. the try/new/catch type test, both ways --"
? "  IsK(1)     : " + IsK(1)
? "  IsK('no')  : " + IsK("no")

? ""
? "-- 2. init still RUNS, and its side effect is kept --"
$nBuilt = 0
new C
new C
? "  two bare `new C` built : " + $nBuilt

? ""
? "-- 3. and the object really is discarded, not bound to anything --"
new C
? "  still : " + $nBuilt

? ""
? "done"

func IsK(p)
	try
		new K(p)
		return 1
	catch
		return 0
	done

class K
	def init(p)
		if isString(p)
			raise("not a K")
		ok

class C
	def init()
		$nBuilt++
