# A `return` that ends its line is Ring's BARE return, and what follows on a
# later row is a statement of its own that never runs. Ring's parser reads
# the very next token after `return` and, finding the end of the line, returns
# NULL (vendor/ring-vm/src/stmt.c:931). rnxc rejoined a bare return with the
# next expression statement from ANY row, to repair the one case where the
# grammar really does cut `return <expr>` in two -- on the SAME row -- so
# `return`, `end`, `5` answered 5 where Ring answers the empty string, and a
# comment between them was refused outright. Measured on the oracle and on the
# official 1.27, which agree on every row.
#
# The rows that must STILL be joined are the same-row cut: a method of a
# class, where the grammar hands back `return` and `7` side by side.

? "[" + F() + "]"
? "[" + G() + "]"
? "[" + H() + "]"
? "[" + K() + "]"
? "[" + eval("return" + nl + "9") + "]"
? "[" + eval("return 9") + "]"
o = new A
? "[" + o.M() + "]"
? "[" + o.N() + "]"
? "[" + o.P() + "]"

func F()
	return
end
	5

func G()
	return
	6

func H()
	return
endfunc
	7

func K()
	return   # a comment, then a value on the next row
	8

class A
	x = 1
	func M()
		return 7
	func N()
		return
		8
	func P()
		return
end
		9
