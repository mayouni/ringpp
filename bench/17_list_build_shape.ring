### 17 — How a list was BUILT decides its random-access cost (FINDINGS F-19)
###
### Two warnings about measuring this, both of which fooled me first:
###
### 1. An index sequence like ((i*7919) % N) + 1 is locally ASCENDING, and
###    Ring's list cursor serves it almost free. It looks like random access
###    and is not. Use a real shuffle.
### 2. An LCG with a 2^31 multiplier overflows the double mantissa and
###    degenerates. Park-Miller (16807, 2^31-1) stays inside 2^53.

func Ms t1,t2  return (t2-t1)/clockspersecond()*1000

func Shuffled n, nReads
     a = list(nReads)
     nS = 12345
     for i = 1 to nReads
         nS = (nS * 16807) % 2147483647
         a[i] = floor((nS / 2147483647) * n) + 1
     next
     return a

func main
     N = 60000
     R = 20000
     aIdx = Shuffled(N, R)
     ? "list of " + N + " items, " + R + " truly random reads"
     ? "  index sample: " + aIdx[1] + ", " + aIdx[2] + ", " + aIdx[3] + ", " + aIdx[4]
     ? ""

     a = list(N)
     for i = 1 to N a[i] = i next
     t1=clock() s=0 for i=1 to R s += a[aIdx[i]] next t2=clock()
     nBlock = Ms(t1,t2)
     ? "  A  list(N)  -- block-allocated   : " + nBlock + " ms"

     b = []
     for i = 1 to N b + i next
     t1=clock() s=0 for i=1 to R s += b[aIdx[i]] next t2=clock()
     nAppend = Ms(t1,t2)
     ? "  B  built by append               : " + nAppend + " ms"

     ringvm_genarray(b)
     t1=clock() s=0 for i=1 to R s += b[aIdx[i]] next t2=clock()
     nGen = Ms(t1,t2)
     ? "  C  append-built + genarray       : " + nGen + " ms"

     ? ""
     if nBlock > 0 ? "  append is " + (nAppend/nBlock) + "x slower than list(N)" ok
     if nGen   > 0 ? "  genarray recovers " + (nAppend/nGen) + "x" ok
     ? ""
     ? "  list(n) allocates its Items in ONE contiguous block"
     ? "  (ringapi.c ring_vm_api_newlistusingblocks), so the cursor walk is a"
     ? "  linear scan through contiguous memory. An append-built list chases"
     ? "  pointers across pool slots. Same O(n) walk, ~200x the constant."
     ? ""
     ? "  So: ringvm_genarray is the fix for APPEND-BUILT lists. For a list"
     ? "  you control, building it with list(n) may make it unnecessary."
