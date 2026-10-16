### Can Ring see its own bytecode, from Ring?

func Hot nA, nB
     nS = 0
     for i = 1 to nA
         nS += i * nB
     next
     return nS

func main
     ? "Hot(3,4) = " + Hot(3,4)

     aCode = ringvm_codelist()
     ? "codelist entries : " + len(aCode)
     ? "first 12 instructions:"
     for i = 1 to 12
         ? "   " + list2str(aCode[i])
     next

     ? ""
     ? "functions list   : " + len(ringvm_functionslist())
     for f in ringvm_functionslist()
         ? "   " + f[1] + "  pc=" + f[2] + "  file=" + f[3]
     next

     ? ""
     ? "=== writing and reading a .ringo object file ==="
     aFiles     = ringvm_fileslist()
     aFunctions = ringvm_functionslist()
     aClasses   = ringvm_classeslist()
     aPackages  = ringvm_packageslist()
     ringvm_writeringo("probe.ringo", [aFiles, aFunctions, aClasses, aPackages, aCode])
     ? "wrote probe.ringo, bytes = " + len(read("probe.ringo"))

     aBack = ringvm_ringolists(read("probe.ringo"))
     ? "read back, sections = " + len(aBack)
     ? "  files=" + len(aBack[1]) + " funcs=" + len(aBack[2]) +
       " classes=" + len(aBack[3]) + " packages=" + len(aBack[4]) +
       " code=" + len(aBack[5])
     remove("probe.ringo")
