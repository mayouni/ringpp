# isNull() is a Ring builtin, and it was R3 here. The estate never tripped
# on it because stzFuncs.ring defines its own, so it bit only a program that
# loads no library -- 98 call sites in 37 files were all going through
# Softanza's. Measured on 1.27, every row:
#
#   the empty string, and the string "NULL" in ANY case  -> 1
#   0, " ", "abc", [], [1], an object                    -> 0
#
# NULL itself is the empty STRING (type STRING, len 0, and NULL = "" holds).
# A bare declaration in a class body -- `x` alone -- is the four-byte
# string "NULL", which is why isNull answers 1 for it too.

? "isNull('')      = " + isNull('')
? "isNull('NULL')  = " + isNull('NULL')
? "isNull('null')  = " + isNull('null')
? "isNull(NULL)    = " + isNull(NULL)
? "isNull(0)       = " + isNull(0)
? "isNull(' ')     = " + isNull(' ')
? "isNull('abc')   = " + isNull('abc')
? "isNull([])      = " + isNull([])
? "isNull([1])     = " + isNull([1])
o = new K
? "isNull(object)  = " + isNull(o)
? "type(NULL)      = " + type(NULL) + "  len " + len(NULL)
? "NULL = ''       = " + (NULL = '')
? o.Show()

class K
    x
    def Show()
        return "bare-declared x = <" + x + "> len " + len(x) + " isNull " + isNull(x)
