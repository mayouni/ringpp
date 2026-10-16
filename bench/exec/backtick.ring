# F-123. A string written between backticks is its CONTENT, as one between
# double or single quotes is. The constant table stripped `"` and `'` and
# kept the backticks, so `x` was three characters with its delimiters in
# it -- silently: lengths, concatenations, `switch` and the code an `eval`
# was handed all carried them. Ring's samples write `Yet "another" 'string'`
# that way, and so do 84 literals in Softanza's tests (none in the library).
# Measured on both 1.27 builds 2026-10-14, every row the same on both.

c1 = `Yet "another" 'string' ! `
? "1 [" + c1 + "] len " + len(c1)
c2 = `two
lines`
? "2 [" + c2 + "] len " + len(c2)
? "3 " + `inline`
c3 = ``
? "4 empty len " + len(c3)
? "5 type " + type(`x`)
c4 = "a" + `b` + 'c'
? "6 " + c4
? "7 eval: " + eval(`return 1 + 2`)
switch `k`
on "k" ? "8 switch on a backtick string"
off
aL = [`p`, `q`]
? "9 list " + aL[2]
eval(`cE = "quoted"`)
? "10 eval with quotes inside: " + cE
? "11 a backtick inside double quotes stays: " + "`kept`"
