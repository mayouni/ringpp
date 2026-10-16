# What using a Qt binding from Ring is actually like.
#
#     ring qt_binding_ux.ring        (loads guilib.ring / Qt)
#
# 1. The reference lists C++ signatures. It does NOT say whether a
#    result arrives in Ring as a value or as a Qt object -- and both
#    happen. QString results are converted; other Qt types are not. That
#    rule is nowhere in the documentation.
#
# 2. So FOLLOWING the documentation fails and ignoring it works: a
#    programmer who knows Qt reads "QString at(int)" and writes the
#    correct C++ idiom, .toUtf8().data(), and gets R13.
#
# 3. Errors name internal concepts, not requirements: neither R50 nor
#    R19 says how many parameters are expected, or of what type.

load "guilib.ring"

oList = new QStringList()
oList.append("alpha")
oList.append("beta")

? "=== documented 'QString at(int)' and 'QString join(QString)'"
? "  at(0)     -> type " + type(oList.at(0)) + "  [" + oList.at(0) + "]"
? "  join('-') -> type " + type(oList.join("-")) + "  [" + oList.join("-") + "]"

? ""
? "=== the correct C++ idiom for the SAME documented signature"
try
    ? "  at(0).toUtf8().data() -> " + oList.at(0).toUtf8().data()
catch
    ? "  at(0).toUtf8().data() -> " + cCatchError
    ? "  (at(0) already returned a Ring string; the more Qt you know,"
    ? "   the more wrong your first attempt is)"
done

? ""
? "=== but QDate is NOT converted -- same-looking documentation"
oToday = (new QDate()).currentDate()
? "  currentDate() -> type " + type(oToday)
try
    ? "  ? oDate -> " + oToday
catch
    ? "  ? oDate               -> " + cCatchError
done
try
    ? "  oDate.toString()      -> " + oToday.toString()
catch
    ? "  oDate.toString()      -> " + cCatchError
done
? "  oDate.toString(fmt)   -> " + oToday.toString("yyyy-MM-dd")
? ""
? "  neither error says HOW MANY parameters, nor of WHAT TYPE."
