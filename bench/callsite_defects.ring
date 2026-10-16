# Four defects of the CALL SITE and the NAME, reproduced on Ring 1.27.
#
#     ring callsite_defects.ring
#
# 1. Ring forbids overloading on arity for USER functions (R20) and
#    practises it freely in its own builtins. `substr` has four arities
#    returning four different KINDS of thing. The ban is the right call;
#    exempting the core from it is the defect.
#
# 2. A nested list does not print as a structure. `?` erases every
#    bracket -- a list of pairs and a flat list print identically.
#
# 3. `list2code()` preserves the structure but is not a builtin (R3
#    until stdlib is loaded) and spends one line per atom.
#
# The named-parameter cost (4) is measured separately: it needs Softanza
# loaded, so it lives in the library tree, not here.

? "--- 1a. substr(): four arities, four kinds of answer (a C builtin)"
? "  substr(s, 3)          = [" + substr("hello world", 3) + "]        a suffix"
? "  substr(s, 3, 4)       = [" + substr("hello world", 3, 4) + "]             a section"
? "  substr(s, 'wor')      = [" + substr("hello world", "wor") + "]                   a NUMBER: a position"
? "  substr(s, 'o', '0')   = [" + substr("hello world", "o", "0") + "]      a replacement"

? "--- 1b. the same freedom, for a function you write"
? F1(1)
? "  next line raises R20: Calling function with extra number of parameters"
? F1(1, 2)

func F1 a
    return "  F1(1) = ok"

# Everything below is unreachable -- R20 above stops the program, which
# is itself the point being demonstrated. Run the display cases with:
#
#     ring callsite_defects_display.ring
