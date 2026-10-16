# What the numeric builtins do with a FLOAT, and with something that is not
# a number at all. Every row measured on Ring 1.27 before the code changed.
#
# `numOf` answered for an int and for a numeric string and PANICKED on
# everything else, so a float crashed the process -- 19 of the 432 tests in
# the wide clock -- and a list crashed it where Ring raises. It also
# returned an integer, so fabs(-1.5) would have been 1 even had it lived.
#
# THE TWO HALVES ARE NOT THE SAME RULE, which is why both are pinned here:
# fabs, max, min and number KEEP a fraction, while char, left, right and
# copy TRUNCATE it. And a numeric STRING is not a number to any of them
# except `number` -- fabs("1.5") is "Bad parameter type!" on 1.27.

? "-- a fraction survives --"
? "fabs(-1.5)         = " + fabs(-1.5)
? "fabs(1.5)          = " + fabs(1.5)
? "max(1.5, 2.5)      = " + max(1.5, 2.5)
? "min(1.5, 2.5)      = " + min(1.5, 2.5)
? "number('3.7')      = " + number("3.7")
? "number(3.7)        = " + number(3.7)

? ""
? "-- and here it is truncated --"
? "char(65.9)         = " + char(65.9)
? "left('hello',2.9)  = " + left("hello", 2.9)
? "right('hello',2.9) = " + right("hello", 2.9)
? "copy('ab',2.9)     = " + copy("ab", 2.9)

? ""
? "-- an integer stays an integer --"
? "fabs(-3)           = " + fabs(-3)
? "max(1, 2)          = " + max(1, 2)
? "number(3)          = " + number(3)
? "number('')         = " + number("")

? ""
? "-- not a number: Bad parameter type! --"
try ? "fabs('abc')        = " + fabs("abc")        catch ? "fabs('abc')        RAISED: " + cCatchError done
try ? "fabs('1.5')        = " + fabs("1.5")        catch ? "fabs('1.5')        RAISED: " + cCatchError done
try ? "fabs([1,2])        = " + fabs([1,2])        catch ? "fabs([1,2])        RAISED: " + cCatchError done
try ? "max([1,2], 3)      = " + max([1,2], 3)      catch ? "max([1,2], 3)      RAISED: " + cCatchError done
try ? "min('1', 2)        = " + min("1", 2)        catch ? "min('1', 2)        RAISED: " + cCatchError done
try ? "char('65')         = " + char("65")         catch ? "char('65')         RAISED: " + cCatchError done
try ? "char('abc')        = " + char("abc")        catch ? "char('abc')        RAISED: " + cCatchError done
try ? "left('hello','2')  = " + left("hello","2")  catch ? "left('hello','2')  RAISED: " + cCatchError done
try ? "left('hello',[1])  = " + left("hello",[1])  catch ? "left('hello',[1])  RAISED: " + cCatchError done
try ? "copy('ab','2')     = " + copy("ab","2")     catch ? "copy('ab','2')     RAISED: " + cCatchError done
try ? "number([1,2])      = " + number([1,2])      catch ? "number([1,2])      RAISED: " + cCatchError done

? ""
? "-- except number(), where a bad string is R41 --"
try ? "number('abc')      = " + number("abc")      catch ? "number('abc')      RAISED: " + cCatchError done
