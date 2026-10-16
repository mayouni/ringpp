# The Ring peer of the code graph (stzRingCodeGraph, a name-based scan of Ring TEXT) run over a given list of files, and what it found written
# out as tab-separated lines for bench/graph.py to compare with `rnxc graph`. Run on the Ring++ package, which carries Softanza and its engine:
#
#     runtime/package/ringpp-win64/bin/rnxc.exe bench/codegraph_peer.ring <files.txt> <out-prefix>
#
# files.txt: one path a line, the unit's files in load order. The prefix names the three outputs:
#     <prefix>.classes   class <TAB> parent
#     <prefix>.methods   class <TAB> method <TAB> line
#     <prefix>.calls     class <TAB> method <TAB> callee        (CallEdges(): the name-based edges, resolved against the method names)
#     <prefix>.raw       class <TAB> method <TAB> callee <TAB> line   (RawCallEntries(): every identifier called in a method body)

load "stzlib.ring"

if len(sysargv) < 4
	? "usage: rnxc codegraph_peer.ring <files.txt> <out-prefix>"
	bye
ok

cList = read(sysargv[3])
cPrefix = sysargv[4]
acFiles = str2list(substr(cList, char(13), ""))

oG = new stzRingCodeGraph("")
nFiles = len(acFiles)
for i = 1 to nFiles
	cFile = trim(acFiles[i])
	if cFile != "" and fexists(cFile)
		oG.ScanSource(substr(read(cFile), char(13), ""), cFile)
	ok
next
oG.BuildGraph()
oG._ResolveCalls()

cOut = ""
aC = oG.Classes()
for i = 1 to len(aC)
	aP = oG.ParentsOf(aC[i])
	cParent = ""
	if len(aP) > 0
		cParent = aP[1]
	ok
	cOut += "" + aC[i] + tab + cParent + nl
next
write(cPrefix + ".classes", cOut)

cOut = ""
aM = oG.MethodsWithLines()
for i = 1 to len(aM)
	cOut += "" + aM[i][1] + tab + aM[i][2] + tab + aM[i][3] + nl
next
write(cPrefix + ".methods", cOut)

cOut = ""
aE = oG.CallEdges()
for i = 1 to len(aE)
	cOut += "" + aE[i][1] + tab + aE[i][2] + tab + aE[i][3] + nl
next
write(cPrefix + ".calls", cOut)

cOut = ""
aR = oG.RawCallEntries()
for i = 1 to len(aR)
	cOut += "" + aR[i][1] + tab + aR[i][2] + tab + aR[i][3] + tab + aR[i][4] + nl
next
write(cPrefix + ".raw", cOut)

? "peer: " + len(aC) + " classes, " + len(aM) + " methods, " + len(aE) + " call edges, " + len(aR) + " raw call sites in " + nFiles + " files"
