# F-106. `?` on a LIST prints its items a line each -- a nested list's in
# place -- and then ends the list with its own newline: a BLANK line after
# it. `see` adds none; `? []` is that newline alone. An OBJECT prints as its
# attributes, `name: value` a line each, lower-cased, parent first, a list
# attribute as `[This Attribute Contains A List]`, an object one as
# `Object...`, and `?` adds the blank line there too. Ring++ dropped the
# blank line and printed `<object>`; exec.py compared lines with the blank
# ones dropped, so it could not see the first half until it stopped doing so.
? [1, 2]
? "after a list"
? [[1, 2], 3]
? []
? [[], 1]
see [1, 2]
? "after see"
o = new C
? o
see o
? [o, 5]
? "end"

class P
	pa = 1
class C from P
	n = 2.5
	s = "two"
	aL = [3, 4]
	inner = new P
