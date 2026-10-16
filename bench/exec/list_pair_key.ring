# F-59 inside a LIST LITERAL, measured on both 1.27 builds: only a :symbol
# key builds the pair ["k", v]. A string or a variable on the left of `=`
# is a comparison there too, so [ "name" = "Mansour" ] is [ 0 ] -- the rule
# Softanza's list/391_hashlist_syntax_key_value states in its own comment.
# Ring++ built a pair for every `k = v` in a list literal.

x = 3
? "1 :k = v      : " + Show([ :name = "Mansour", :age = 45 ])
? "2 'k' = v     : " + Show([ "name" = "Mansour", "age" = 45 ])
? "3 equal       : " + Show([ "a" = "a", 'b' = "b" ])
? "4 var = v     : " + Show([ x = 3, x = 4 ])
? "5 number = v  : " + Show([ 1 = 1, 2 = 3 ])
? "6 mixed       : " + Show([ :k = 1, "k" = 1, 7 ])
? "7 nested      : " + Show([ [ :a = 1 ], [ "a" = 1 ] ])

func Show(v)
	if isList(v)
		s = "["
		for i = 1 to len(v)
			if i > 1  s += ", "  ok
			s += Show(v[i])
		next
		return s + "]"
	ok
	if isString(v)  return '"' + v + '"'  ok
	return "" + v
