# Ring STOPS a runaway recursion and TELLS the program; it does not die.
#
# `Error (R4) : Stack Overflow` is an ordinary catchable error. Ring's guard
# sits on its operand stack -- RING_VM_STACK_CHECKOVERFLOW, 1000, in
# vendor/ring-vm/include/vm.h:11 -- and every row below was measured on 1.27
# before a line of Ring++ changed: 998 frames entered, the same for a plain
# function, for mutual recursion and for a method, the program running on
# after the catch, and able to recurse again.
#
# Ring++ had NO limit. It recursed until Windows took the process down, with
# no message at all -- and 34 of the 432 tests in the wide clock died that
# way, every one of them counted as "printed nothing and said nothing".
#
# The SECOND half of this file is what got them there. `_These_ = This` in
# Softanza's constructors stored a REFERENCE where Ring stores a COPY, so
# the object held itself, and the next copy of it walked that cycle for
# ever. Ring's answer is here too: `o.mine` is an object and `o.mine.mine`
# is not, because the copy was taken of the object as it stood.

$nMax = 0  $nMax2 = 0  $nMax3 = 0

? "-- a runaway recursion is CAUGHT, and the program goes on --"
try
    ? "  unreachable: " + down(100000)
catch
    ? "  raised: " + cCatchError
done
? "  still running after the catch"

? ""
? "-- and it is the same depth however it recurses --"
try  x = counted(0)     catch ? "  plain : " + cCatchError done
? "  deepest frame entered: " + $nMax

try  x = ping(0)        catch ? "  mutual: " + cCatchError done
? "  deepest frame entered: " + $nMax2

o = new diver
try  x = o.dive(0)      catch ? "  method: " + cCatchError done
? "  deepest frame entered: " + $nMax3

? ""
? "-- and once caught, it can go again --"
$nMax = 0
try  x = counted(0)     catch ? "  raised again: " + cCatchError done
? "  and reached the same depth: " + $nMax

? ""
? "-- `attr = This` stores a COPY, so the object does not hold itself --"
b = new box("hello")
? "  b.mine is an object          : " + isObject(b.mine)
? "  b.mine.mine is an object     : " + isObject(b.mine.mine)
? "  and the copy kept the content: " + b.mine.content
c = b
? "  copying the whole thing by assignment is finite: " + c.content

func down n
    if n = 0 return 0 ok
    return down(n - 1) + 1

func counted n
    if n > $nMax  $nMax = n ok
    return counted(n + 1)

func ping n
    if n > $nMax2  $nMax2 = n ok
    return pong(n + 1)

func pong n
    return ping(n + 1)

class diver
    def dive n
        if n > $nMax3  $nMax3 = n ok
        return this.dive(n + 1)

class box
    content
    mine

    def init(c)
        content = c
        mine = This
