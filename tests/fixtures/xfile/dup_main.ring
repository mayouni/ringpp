# The JOIN file: loading both defs of Same() is Error (C22) before the
# first line runs. The duplicate is reported HERE, not in dup_a or dup_b,
# which are each innocent alone.
load "dup_a.ring"
load "dup_b.ring"
? Same()
