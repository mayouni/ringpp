# The VALID test: call the name and see whether Ring raises R3,
# "Calling Function without definition". isfunction() cannot be used --
# it reports only USER-defined functions (isfunction('len') is 0).

aNames = ["regex", "match", "pcre", "preg_match", "regexmatch",
          "re_match", "regexp", "matchpattern", "pcre_match"]

for cName in aNames
    cCode = 'x = ' + cName + '("abc", "a")'
    try
        eval(cCode)
        ? "  " + cName + " : EXISTS (call succeeded)"
    catch
        cErr = cCatchError
        if substr(cErr, "without definition") > 0
            ? "  " + cName + " : does not exist (R3)"
        else
            ? "  " + cName + " : EXISTS, but errored -> " + cErr
        ok
    done
next

? ""
? "control -- a name that certainly exists, and one that certainly does not:"
try
    eval('x = len("abc")')
    ? "  len   : EXISTS (call succeeded)"
catch
    ? "  len   : " + cCatchError
done
try
    eval('x = zzznosuchfunction("abc")')
    ? "  zzznosuchfunction : EXISTS"
catch
    ? "  zzznosuchfunction : " + cCatchError
done
