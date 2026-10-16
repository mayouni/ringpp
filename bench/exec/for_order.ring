# F-115: Ring checks a `for` loop's STEP first, then its bound, then its
# start: a list step is R28 and a step that is text and no number R41, before
# anything else; then a bound that is text and no number R41; then a start
# that is not a number at all R29. So `for i = :FirstRow to :LastRow` is R41,
# from the bound, where Ring++ said R29, from the start. W a word, N a
# number, L a list, T numeric text -- start, bound, step.
vals = [ :W = "w", :N = 1, :L = [1], :T = "2" ]
for c in [ "WNW", "NWW", "WWW", "LWN", "WLN", "NWL", "NLW", "WNL", "LNW",
           "TWN", "WTN", "TTW", "NNW", "NNL", "LLN", "TNN", "NTN" ]
	a = vals[c[1]]  b = vals[c[2]]  s = vals[c[3]]
	try
		for i = a to b step s
			exit
		next
		? c + " runs"
	catch
		? c + " " + cCatchError
	done
next
