# A `load` inside a block: Ring runs the loaded file's top level where the
# load stands, when it is reached -- and defines its functions either way.
? "before"
if fexists("load_block_lib/a.ring")
	load "load_block_lib/a.ring"
	? "after a, AGlobal = " + AGlobal
ok
if 0
	load "load_block_lib/b.ring"
ok
? AFunc()
? BFunc()
nCRuns = 0
for i = 1 to 3
	load "load_block_lib/c.ring"
next
? "c ran " + nCRuns + " time(s)"
? "after"
