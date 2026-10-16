# F-108. An eval string that does not parse is Ring's compile report --
# `eval Line (N) Error (Cxx) : ...` for each line with an error, then the
# count -- and then R42, `Error in eval() function`, catchable, raised from
# inside eval() (`In eval()` in front of the frame). An unclosed structure
# is reported at the string's LAST line; an unclosed literal is the
# scanner's own form. Ring++ raised an E1 of its own. Uncaught at the end.
Try1("x = = 1")
Try1("x = 1" + nl + "y = = 2")
Try1("x = = 1" + nl + "y = = 2")
Try1("x = 1" + nl + "if x" + nl + "? 2")
Try1("while 0 ? 1")
Try1("for i = 1 to 3 ? i")
Try1("x = (1 + 2")
Try1("x = [1, 2")
Try1("f = func { return 1")
Try1("try ? 1")
Try1("switch 1 on 1 ? 1")
Try1("x = 'abc")
Try1("x = 1 $$ 2")
f()

func Try1 cCode
	try
		eval(cCode)
	catch
		? "caught: " + cCatchError
	done

func f
	eval("y = = 3")
