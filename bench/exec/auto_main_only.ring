# A FILE THAT IS ONE FUNCTION IS A PROGRAM, because Ring calls Main().
#
# This shape is the one that needed more than the call itself. rnxc said
# "no top-level code in this file" and returned, because the entry it
# looked for was the synthetic @@main that holds top-level statements --
# and there are none here. Three things had to follow:
#
#   the entry trampoline is built for a user Main, not only for a prefix
#   `main_fn` -- the function the VM reports as "the top level" -- carries
#       a SENTINEL rather than 0, which in this file would name Main
#       itself and swallow the `In function main()` line below
#   the TRAMPOLINES belong to no function. The last function by address
#       used to own the code to the very end, trampolines included, so the
#       frame that calls Main reported `In function main()` where Ring
#       reports the file alone. It never showed while every program had a
#       top level, because the chain stops at @@main's frame first.
#
# `Called from line 1` is the `func Main` line, not the top of the file:
# auto_main.ring has its declaration further down and reports that row.

func Main
	? "a file that is one function is a program"
	? ""
	Boom()

func Boom
	raise("still reported as Ring reports it")
