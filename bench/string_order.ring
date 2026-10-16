# Ring has NO string ordering. `<` and `>` coerce both operands to
# numbers first, so a non-numeric string raises R41.
#
#     ring string_order.ring
#
#   "abc" > "abd"   -> Error (R41) : Invalid numeric string
#   "10"  > "9"     -> 1            NUMERIC, not lexicographic
#   "abc" = "abc"   -> 1            equality is fine
#
# Ring++ DIVERGES here: it orders strings lexicographically, so
# "abc" < "abd" is 1 and "10" < "9" is 1 (because "1" < "9").
#
# The divergence was not deliberate -- it arrived with the string
# comparison work and was found only when the 2019 operator-overloading
# thread sent me to look. It is kept because ordering strings is
# obviously wanted and §2.8 already rules that `=` is type-stable in
# Ring++; but "10" > "9" changes answer, and that is on the record.

? "--- equality works in both"
? '  "abc" = "abc" -> ' + ("abc" = "abc")

? "--- ordering: Ring coerces to number first"
try
    x = ("abc" > "abd")
    ? '  "abc" > "abd" -> ' + x
catch
    ? '  "abc" > "abd" -> ' + cCatchError
done

? "--- and numeric strings compare NUMERICALLY, not by text"
? '  "10" > "9"    -> ' + ("10" > "9") + "   (lexicographically it would be 0)"

? ""
? "--- the 2019 bug, fixed: an overload is dispatched before coercion"
o1 = new S("a long string that once overflowed the numeric conversion")
? "  (o1 > 'short') -> " + (o1 > "short")

class S
    @c = ""
    def init(p)
        @c = p
    def operator(cOp, p)
        if cOp = ">"
            return 1
        ok
        return 0
