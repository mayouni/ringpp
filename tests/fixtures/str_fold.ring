### Fixture for the F-55 fold. Run as-is it decodes at run time; run through
### `ringpp expand` the calls are gone and plain Ring does the same work. The
### gate is that the two produce BYTE-IDENTICAL output -- a fold that is fast
### and different is the one failure this feature must not have.
###
### The load path is relative to the repository root, which is where the T1
### section of run-all.ps1 runs.

load "rpp/str.ring"

func Main()
	? RppStr("He said \q5\q and left")
	? RppStr("tab:\there")
	? RppStr("all three: \q \s \g")
	? RppStr("C:\\GitHub\\ringpp")
	? RppStr("hex \x41\x62")
	? RppStr("codepoints \u00e9 \u4E2D \u{1F600}")
	? RppStr("arabic \u0645\u0631\u062D\u0628\u0627")
	? RppStr("plain, nothing to do")

	# NOT folded: the value is not known at build time, so the run-time
	# decoder stays and does the work.
	cVar = "x\qy"
	? RppStr(cVar)
