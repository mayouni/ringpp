# stzlib's stzCodeGraph -- the index every language peer feeds -- fed the line protocol `rnxc graph` prints, UNCHANGED, and asked what it holds.
# Run on the Ring++ package, which carries Softanza and its engine; bench/graph.py --ingest reads what it writes:
#
#     runtime/package/ringpp-win64/bin/rnxc.exe bench/codegraph_ingest.ring <graph.lines> <out.txt> <callee> <class>
#
# The stream is cut into its FILE blocks, each block goes to the index as the engine's tree-sitter peers' output does (_IngestAstLines(text,
# file)), and the counts and one query come back as `key TAB value` lines.

load "stzlib.ring"

if len(sysargv) < 6
	? "usage: rnxc codegraph_ingest.ring <graph.lines> <out.txt> <callee> <class>"
	bye
ok

acLines = str2list(substr(read(sysargv[3]), char(13), ""))
cOut = sysargv[4]
cCallee = sysargv[5]
cClass = sysargv[6]

oG = new stzCodeGraph("")
cFile = ""
cBlock = ""
nLines = len(acLines)
for i = 1 to nLines
	cL = acLines[i]
	if left(cL, 5) = "FILE|"
		if cFile != ""
			oG._IngestAstLines(cBlock, cFile)
		ok
		cFile = substr(cL, 6, len(cL) - 5)
		cBlock = ""
	else
		cBlock += cL + nl
	ok
next
if cFile != ""
	oG._IngestAstLines(cBlock, cFile)
ok
oG.BuildGraph()

cR = ""
cR += "classes" + tab + oG.NumberOfClasses() + nl
cR += "methods" + tab + oG.NumberOfMethods() + nl
cR += "functions" + tab + oG.NumberOfFunctions() + nl
cR += "calls" + tab + len(oG.CallEdges()) + nl
cR += "imports" + tab + oG.NumberOfImports() + nl
cR += "callers" + tab + len(oG.CallersOf(cCallee)) + nl
aChain = oG.AncestryOf(cClass)
cChain = ""
for k = 1 to len(aChain)
	if k > 1
		cChain += ">"
	ok
	cChain += aChain[k]
next
cR += "ancestry" + tab + cChain + nl
write(cOut, cR)
? "ingested: " + oG.NumberOfClasses() + " classes, " + oG.NumberOfMethods() + " methods, " + len(oG.CallEdges()) + " call edges"
