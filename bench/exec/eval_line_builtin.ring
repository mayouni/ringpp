# F-102, both halves at once: a builtin raising inside an eval'd string is
# reported at the eval's own line, inside the caller, with the builtin's
# frame in front -- `In lower() In function f()`. Through an eval
# nested in an eval as well: the inner string's line is the outer call's.
f()

func f
	eval("eval(" + char(34) + "? lower(5)" + char(34) + ")")
