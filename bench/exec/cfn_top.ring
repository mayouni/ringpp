# F-102. An error raised INSIDE a builtin names it in front of the first
# frame -- Ring's C function holds a frame of its own while it runs
# (vmerror.c:155) -- so at the top level the report reads `In left() in
# file F`, where Ring++ printed `in file F` alone. Uncaught on purpose.
? "before"
? left(5, "a")
