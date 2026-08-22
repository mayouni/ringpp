### T3 — where can varptr reach?

o = new Buf
o.Init(32)
o.Poke("HELLO")
? "attr after poke : [" + o.cData + "]"

? "--- global reach from inside a func ---"
gBuf = space(16)
TouchGlobal()
? "global after    : [" + gBuf + "]"

? "--- pointer stability across a re-read ---"
cB = space(16)
p1 = getptr(varptr(:cB, "char *"))
for i = 1 to 5
    x = cB          # push copies, should not move the original
next
p2 = getptr(varptr(:cB, "char *"))
? "stable          : " + (p1 = p2)

? "--- what reassignment does ---"
cB = space(16)
p3 = getptr(varptr(:cB, "char *"))
? "same after reassign : " + (p1 = p3)

? "--- ref parameter ---"
cC = space(16)
PokeRef(:cC)
? "cC via name     : [" + cC + "]"

func TouchGlobal
     memcpy(varptr(:gBuf, "char *"), "GLOBAL!!", 8)

func PokeRef cName
     # varptr resolves in the CALLER scope, so this must fail or find nothing
     try
         p = varptr(cName, "char *")
         memcpy(p, "REFPOKE!", 8)
     catch
         ? "PokeRef error: " + cCatchError
     done

class Buf
     cData

     func Init n
          cData = space(n)

     func Poke cVal
          p = varptr(:cData, "char *")
          memcpy(p, cVal, len(cVal))
