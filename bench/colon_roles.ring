# The colon does three jobs at once, and one of them destroys data.
#
#     ring colon_roles.ring
#
#   1. an atom literal      :Hello  is a STRING
#   2. a pair constructor   [:Name = "Ali"]  is  [["name", "Ali"]]
#   3. an implicit lowercase -- and this one buys NOTHING, because
#      lookup already folds case by itself.

? "=== 1. a symbol does not equal the text you wrote"
x = :Hello
? "  :Hello -> type " + type(x) + ", value [" + x + "]"
? '  :Hello = "Hello" -> ' + (x = "Hello") + "     <-- the written form is gone"
? '  :Hello = "hello" -> ' + (x = "hello")

? ""
? "=== 2. a pair is a two-element list, indistinguishable from data"
a = [ :Name = "Ali" ]
b = [ [ "Name", "Ali" ] ]
? "  type(a) = " + type(a) + "   type(b) = " + type(b)
? "  a[1][1] = [" + a[1][1] + "]   <-- lowercased at construction"
? "  b[1][1] = [" + b[1][1] + "]   <-- kept, because no colon was used"

? ""
? "=== 3. and the lowercasing serves no lookup purpose"
c = [ ["Name", "Ali"], ["CamelKey", 7] ]
? '  keys stored WITH case; c["name"] = ' + c["name"]
? '                         c["NAME"] = ' + c["NAME"]
? '                     c["camelkey"] = ' + c["camelkey"]
? "  -- so folding at construction only loses the written form"

? ""
? "=== what it costs: the key IS data"
d = [ :FirstName = "Ali", :DateOfBirth = "1974" ]
? "  written : FirstName, DateOfBirth"
? "  stored  : " + d[1][1] + ", " + d[2][1]
? "  a CSV header or JSON document written from these loses its casing"
