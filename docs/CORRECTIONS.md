# The corrections register

**Every place Ring++ deliberately behaves differently from Ring, with the
verdict, the measurement, and who decided.**

`docs/FINDINGS.md` records what Ring *does*. This file records what Ring++
does *instead*, and why that was chosen. A finding is an observation; a
correction is a decision, and decisions need an owner and a date.

The charter
(`softanza/memos/2026-08-30-ringpp-design-charter.md` §4) sets the
vocabulary, and compatibility is decided **per defect**, never as a blanket
promise:

| verdict | meaning |
|---|---|
| **keep** | Ring's behaviour reproduced exactly |
| **fix silently** | Ring's behaviour was a bug, and the corrected one cannot break correct code |
| **break, with a rule** | the behaviour is removed, and a checker rule finds every site that relied on it |
| **drop, with a constraint** | the feature does not exist in Ring++, and the estate is written not to use it |

A fifth shape exists and is named here because the first entry is one: a
**fix whose blast radius is not statically findable**. It cannot be
"silent", because it changes output that correct code produces; and it
cannot be "break, with a rule", because no rule can find the affected sites.
Those get a stated migration cost instead of a rule.

---

## C-1 · Exact ties round half-to-even, not half-away-from-zero

**Verdict: fix — IEEE correctness. Decided by Mansour, 2026-09-07.**
Finding: [F-57](FINDINGS.md). Blast radius: **not statically findable.**

```
                     Ring 1.27    Ring++
  decimals(2)
    0.125      ->      0.13        0.12
    1/8        ->      0.13        0.12
  decimals(0)
    0.5        ->      1           0
    2.5        ->      3           2
```

Ring's official build rounds a tie **away from zero**; Ring++ rounds it
**to even**, which is the IEEE 754 default and what glibc, musl and LLVM's
`printf` implement. Only *exact* ties differ — 0.135 and 0.145 are not
really ties in binary and both agree on them, which is why this reads as an
occasional disagreement rather than a rule.

**The arithmetic is identical.** Only the decimal *formatting* of a tie
differs.

**Why correctness won.** Half-to-even is the defined behaviour of the
floating-point standard the arithmetic already follows, it does not
accumulate bias across many roundings, and it is what every other
IEEE-conforming runtime a Softanza number will ever meet — a database, a
spreadsheet, another language's report — will do with the same value. Half
away from zero is an artefact of one C runtime, not a decision anyone made.

**What it costs, stated rather than minimised.** Any recorded output
containing a formatted exact tie changes. In the 90-file Softanza sweep that
found it, four files were affected — `hashlist/17_numberofklasses`,
`hashlist/26_content`, `hashlist/test_engine_hashlist`,
`stats/plot_engine_parity_narrated` — where class frequencies print
`0.13` on Ring and `0.12` on Ring++, from 1/8.

**No checker rule is possible for this**, and it is worth being exact about
why: whether a value is a tie is a property of the value at run time, not of
the source. A rule could flag every `decimals()` call or every numeric
format site, but that is thousands of places of which almost none are
affected — a rule that cries wolf is a rule people turn off. The migration
cost is therefore: **re-record the expected outputs that contain a
formatted tie**, found by running the suite on both and diffing, which is
how these four were found.

---

## C-2 · A bare name at the top level is a global

**Verdict: keep. Taken by the session for the first end-to-end run and
confirmed by Mansour, 2026-09-09.** Blast radius: none on Ring; on Ring++
it lifts a refusal. Guard: the `rnxc shadows` count — functions that
assign a bare name which also exists as a global, where Ring writes the
global and Ring++ makes a local — is pinned in the gate
(`bench/shadows.max`) and may only shrink. It read 44 on the morning of
2026-09-09, before C-2; C-2 made every top-level bare name a global and
the count rose to 57, of which 3 were the session's own migration
(`@n` → `n` in `CommonPath`, where `n` is a global — renamed to `_n_`, the
guard's first catch) and 7 are Ring's standard library assigning `n`
inside its own functions. Pinned at **54** -- and on 2026-09-11 the count
fell to **1**: the walk had been descending into SYMBOLS, so `:n` as a
hash key or an argument counted as a bare use of `$n` (35 of the 54 were
`:n` alone; `:none`, `:graph`, `:tab = "box"` were most of the rest). A
symbol is a string literal, never a variable; the walk stops at it now,
and the migration's attribute walk got the same guard. The one real site
left is `base/natural/stzChainOfTruth.ring:786`, `return _( result )` --
a function reading the migrated `$result` bare, a verdict for Mansour.
Pinned at **1**.

```
  o = new stzList([3, 1, 4])      top level, bare      Ring: global   Ring++: was REFUSED
  ? o.Min()                                                            now: the global
  func F()  return o              inside a function    Ring: global   Ring++: REFUSED (unchanged)
  func G()  o = 1                 inside a function    Ring: WRITES the global   Ring++: a local (unchanged)
```

Rule A's hazard was a function reaching a caller's variable by writing a
bare name (F-25, §2.7). That stays impossible: inside a function a bare
name is a local and nothing else. At the top level there is no caller to
reach, and `o = new stzList(...)` in a test file is the most ordinary Ring
there is — every one of Softanza's 5,121 test files begins that way, and
the very first end-to-end run refused its own line 6.

**What it costs.** Nothing on Ring. On Ring++, the migration list that the
refusal used to be ("975 bare and 250 `_x_` assignments, mechanically
fixable by prefixing `$`") is no longer needed for the *main program's*
top level; loaded library files' top levels get the same treatment, which
is also Ring's rule (`stdlib.rh`'s `C_SECONDSIZE = ClocksPerSecond()` is a
global on both). A function still cannot read such a global bare — that
refusal is the Rule A boundary and it is untouched.

Probe: `bench/exec/top_globals.ring`, six lines identical to the oracle.

---

**Noted 2026-09-21, the same rule from the other side.** On Ring, `$x = 42`
inside a function whose unit has no global `$x` creates a FUNCTION-LOCAL
named `$x`, and a read of `$x` at the top level afterwards is R24 -- the
`$` is only a character to Ring. Under Rule A `$x` IS the global wherever it
is written, so Ring++ answers 42. Kept: it is the rule, and it is the
behaviour every `$`-prefixed name in Softanza was written to have. Measured
on 1.27 as row 6 of the R24 probe, and left OUT of `bench/exec/r24_read.ring`
because it is a decided divergence, not a defect.

**Noted 2026-09-23 -- the guard named above did not count this rule's own
sites.** `rnxc shadows` matched only names defined with a `$`, where Ring
and Ring++ agree (`$g` and `g` are two names to Ring); a function, method or
lambda assigning a BARE top-level global -- the divergence this entry
accepts -- read 0. It reports those now: 0 on the base unit, and 71
"written for a reader" sites in 5 of 12 sampled test units (CLAUDE.md,
"C-2's GUARD NEVER SAW C-2"; `bench/shadows_bare.py`). **A second pin, at
0, decided by Mansour the same day**: `bench/shadows_bare.max`, gate step
`shadows bare (C-2)` -- the base unit's bare-global write sites, beside the
`$` count, which stays 1. **The verdict is unchanged**; the lambda question
is open.

## C-3 · `s[i]` on a string is a one-character string

**Verdict: keep Ring. Taken by the session and confirmed by Mansour,
2026-09-09.** Finding: [F-54](FINDINGS.md). Blast radius on Ring: none.

```
  s = "abc"        s[2]           Ring: "b"     Ring++: was 98 (the byte)   now: "b"
                   ascii(s[2])    Ring: 98      Ring++: 98 on both, always
```

The byte form was a *designed* advantage — F-39's bytescan row indexes
bytes with one opcode where Lua calls `string.byte` — and it was recorded
as a deliberate divergence (`bi:BI_IDX` in `ab-known.txt`). It broke the
first Softanza program to run here: `_cDir_[_i_] = "\"` in the engine
discovery never held, the path was rebuilt from numbers, and no engine was
found. The estate is the specification.

**What it costs, measured 2026-09-09.** The byte opcode survives only for
the exact shape `ascii(s[i])` on a string the compiler has *proved* — and
that proof is rare: a string built by `+=` is not proved, so both a proved
and a parameter string measured **15 ms per million indexes** (dynamic get
plus the `ascii` builtin), against **680 ms** for the same program on the
oracle. The hand-assembled bytescan kernel in `NOTES.md` still uses the
byte opcode and its numbers stand; a bytescan written in Ring source does
not get it unless the type-hint channel proves the string — which is what
that channel exists for. Each one-character string is interned (256 of
them, pinned), so no index allocates.

`bi:BI_IDX` is a CHECK now, not a known divergence.

---

## C-4 · Where a `load` looks

**Verdict: DECIDED 2026-09-11, all five lines as proposed -- Mansour
delegated ("take whatever options you think wise"). The root-file rule
is IMPLEMENTED: a file's own directory first for every file, the root
included, the launch directory only as the root's fallback (`src/rnxc.zig`
and the splice in `compile.zig`, one rule). `bench/exec/load_*.ring` still
agree with the oracle; the one shape Ring refuses and Ring++ runs -- a
root file launched from elsewhere -- is a named divergence, not a probe.
The leading-slash rule, the branch rule and the reported fallback are
checker rules and census lines, scheduled behind the engine.** Until then the compiler resolves exactly as Ring does
(`0d760c3`, gated by `bench/exec/load_order.ring` and `load_nested.ring`).
The full case, with every probe, is section 10.1 of
`softanza/memos/2026-08-30-ring-critical-analysis.md`.

Ring's rule, measured on both builds 2026-09-10:

```
  load "x.ring" in the ROOT file        looked for in the LAUNCH DIRECTORY
  load "x.ring" in a LOADED file        looked for beside THAT FILE
  load "/x.ring"                        <exefolder>/load/x.ring  (never the root)
  a bare name found nowhere above       <exefolder>/, then <exefolder>/load/, silently
  load "a.ring" + load "./a.ring"       C22, the program never starts (keyed on the spelling)
  load inside a branch never taken      definitions pulled in anyway; top level not run
```

Four decisions are proposed, each priced:

**Root file: fix silently.** Resolve every file's relative loads against
the file itself, root included; the launch directory becomes a fallback
for the root only. Nothing that works on Ring stops working. Softanza:
5,160 of 5,179 test files open with `load "../../stzBase.ring"` and today
run from one directory each; all become launchable from anywhere. **What
it costs:** the same name both beside the root file and in the launch
directory -- Ring took the launch directory's, Ring++ would take the
root's. It cannot be found statically (the launch directory is not in the
source), so it is named here, not hidden. A one-line change in
`src/rnxc.zig` (`is_root`) and its mirror in `compile.zig`'s
`loadTarget`; the existing `lr` probe (Ring: E9; Ring++: runs) becomes a
named divergence.

**Leading slash: break with a rule.** In program code `/x` is the root,
and `rnxc check` flags every leading-slash load. Softanza: 0 sites. The
67 vendored shims in `vendor/ring-stdlib/load/` keep the rewrite *by
location* -- a file that sits inside `<exefolder>/load/` -- so they stay
verbatim and their hashes stand. **What it costs:** any user program that
relied on the rewrite (none known) gets a diagnostic, not a silent change.

**Identity by spelling: fix silently.** Already the case -- the
already-loaded set is keyed on the resolved path (`NOTES.md` line 1078),
so a program Ring kills with C22 at load runs here. **What it costs:** a
library that *relied* on being loaded twice would behave differently;
none should, and none is known. Needs a probe of its own: `exec.py`
compares to the oracle, and the oracle dies, so it is a named divergence
like `bi:BI_IDX` was.

**Half-conditional load: keep, with a rule.** The definitions of a file
loaded under a branch are unconditional and its top level is not;
`rnxc check` says so at the site. Softanza: 0 loads under a branch.

**Fallback chain: keep, reported.** `load "stdlibcore.ring"` is line 6
of Softanza's loader and depends on the chain. What changes is that the
census lists every load that resolved past its first candidate, so a
misspelled local file that lands on a library file of the same name is
visible.

---

## C-5 · The range operator `a : b`

**Verdict: keep Ring where Ring is consistent; drop the rest with a
constraint. Taken by the session 2026-09-10; CONFIRMED 2026-09-11 by
delegation.**
Finding: the analysis's 2.15 (the range answers with the wrong type).
Blast radius on Ring: none for the kept shapes.

Every engine-less run of Softanza died on rnx at
`base/data/stzCharData.ring:884`, `$_acDecimalchars = "0" : "9"`, with a
VM panic ("expected a number") -- the range opcode read its operands as
integers only, and read `hi < lo` as empty. Measured on both builds:

```
  "0" : "9"     10 one-character STRINGs          "e" : "a"   5, e d c b a
  "A" : "z"     58 (by byte, 65..122)             5 : 1       [5,4,3,2,1]
  1.5 : 3.5     [1,2,3]   (start trunc(lo), step while within hi)
  3 : 1.5       [3,2]     2.7 : 5   [2,3,4,5]     -2 : 1      [-2,-1,0,1]
  1 : "5"       Bad parameter type!
```

**Kept, exactly:** numbers in either direction with the truncation rule
above; one-character strings by byte in either direction. Gated by
`bench/exec/range.ring`, twelve lines identical to the oracle.

**Dropped with a constraint -- the shapes Ring answers inconsistently:**

```
  "ab" : "cd"   ["a","b"]   (the LEFT operand's characters)
  "a"  : "zz"   ["a"]        "ab" : "ab"   ["a","b"]
  "abc" : "z"   Error (R34) : Variable is required for the assignment
  "x"  : 5      ["x"]        [1] : 3       one element
```

Ring++ raises `Bad parameter type!` on all of them -- Ring's own answer to
`1 : "5"`. **What it costs:** a program relying on `"ab":"cd"` being
`["a","b"]` raises here. Softanza has **0** such sites: the 32 quoted
`"x":"y"` pairs the grep finds are JSON text inside strings, a ternary,
and the documentation of `stzSmallFuncs.ring`'s own range parser (which
takes `"v1" : "v3"` as a STRING and is not the operator).

**Also in this unit, two builtins the estate depends on:** `type()` did
not exist in the VM (34 call sites); it does now, with Ring's names --
NUMBER for `1`, `1.5`, `true`; STRING for strings and NULL; LIST; OBJECT.
One shape differed and was named: an anonymous function is STRING on Ring
and was LIST here (closures are lists). Since 2026-09-24 the closure
vector is flagged at birth and `type()`, `isString`, `isList` and
`isFunction` answer for it as Ring answers for its lambda string --
STRING, 1, 0, 1 -- because that is how the estate guards a callback
(`isString(f) and isFunction(f)`, stzReactiveObject); its list shape stays
for `call`. `bench/exec/lambda_value.ring`. And `exefolder()` now ends with the
separator as Ring's does (`currentdir()` does not, on both) -- the 80
engine-discovery warnings differed between the oracle and rnx by exactly
that character. Both gated in `bench/exec/`.

---

## C-6 · `obj { ... }`, the object-scope block

**Verdict: keep Ring where Ring is consistent; one shape dropped with a
constraint. Taken by the session 2026-09-10; Mansour to confirm.**
Blast radius on Ring: none for the kept shapes. Softanza's four `app`
tests are written entirely in this form, and refused at the top level
until now; 0 sites of the construct remain refused in the base unit.

Measured on both builds (`bench/exec/brace.ring`, 16 lines identical):

```
  the value is the object          o = new K { x = 5 }  ->  o.x is 5
  inside the block, a name is      a LOCAL first ("x = x + 1" with a local x
                                   wrote the local, the attribute stayed 0),
                                   then the OBJECT's attribute, then a global
  `@x`                             the object's attribute (Softanza's spelling)
  a bare call                      the object's METHOD first, ahead of a global
                                   function of the same name
  blocks nest and chain            o { p { x } };  new K { x = 1 } { x = 2 }
  a braced call result             q = o.Q() { x = 9 } assigns, then runs the
                                   block on the value (the grammar hands the
                                   whole assignment as the receiver)
  `self` / `This` in a block       NOT the object: R13 / UNKNOWN on Ring
```

**How the attribute rule is decided here.** A receiver whose class is
PROVED -- `new K`, `This`, a local every assignment agrees on, and now a
top-level name every top-level assignment binds with `new K` (that is how
`oApp = new stzApp(...)` / `oApp { ... }` is proved) -- has its attribute
found by slot anywhere in its inheritance chain; a name the chain lacks
falls through to Ring's next rule, the global. An unproved receiver is
asked by NAME at run time.

**Dropped with a constraint:** on an UNPROVED receiver, a bare assignment
to a name the object turns out not to have. Ring creates a global at that
moment; Ring++ raises R12 (property not found) from the object. **What it
costs:** a block on a receiver the compiler cannot type, writing a fresh
global from inside it. The compiler cannot know statically that the name
is not an attribute, and a silent global from inside an object block is
§2.7's leak in another form. Softanza: not seen.

Two things the probe had to be written around, neither a brace defect:
Ring writes a function's bare `o = ...` to the GLOBAL o (C-2 / Rule A,
decided), and an attribute a method writes is `@h` here (a bare `h = p`
in a method is a local; `rnxc migrate` rewrites those sites).

---

## C-7 · A list or an object is COPIED at every transfer; a parameter is by reference

**Verdict: fix -- Ring's value model, exactly. Taken by the session
2026-09-11 after Mansour said "go with C-7"; the price is measured below.**
Blast radius on Ring: none.

What Ring does, measured 2026-09-10 on both builds (`bench/exec/copy.ring`,
13 lines identical to the oracle): a list or an object is copied, DEEPLY
(nested lists and nested objects included), at every transfer -- into a
variable, an attribute, an element, a list literal, `add()`, and a
method's `return` -- and passed BY REFERENCE to a parameter and as `this`.

**CORRECTED 2026-09-21: NOT at the return.** The probe above measured
`r = o.GetL()` -- an ASSIGNMENT -- and the copy it saw was the assignment's.
Isolated with no assignment anywhere (`bench/exec/return_ref.ring`, probed
on 1.27): `P().Bump()` on a `return $o` mutates the global, `o.Me().Bump()`
on a `return This` mutates o, and `zzAppend(q.L(), 99)` on a `return @l`
appends to the attribute. Ring copies at the assignment, never at the
return. Ring++ copied at the return from 2026-09-11 to 2026-09-21, so a
method called on a returned object acted on a throwaway -- Softanza's node
plane is a singleton reached only through `StzNodePlane().X()`, and every
Register, Ask and LastStatus of it was lost, which is what held
cluster/d3_supervision past 120 s. The copy now happens at the assignment
of a call's result, and `copyv` skips a value nothing else holds, so a
fresh result is never cloned. `x = P()` still copies, as it does on Ring.


What Ring++ did before this: two things, both wrong.

```
  o = new K; z = o; z.x = 5          Ring: o.x 0     Ring++: o.x 5   objects aliased
  a = [1,2]; f(a) with l[1] = 99     Ring: a[1] 99   Ring++: a[1] 1  the parameter was
  addOne(a) with add(l, 3) inside    Ring: len 3     Ring++: len 2   CLONED on write
```

The second is the worse one and it was NOTES.md's Decision 4 itself:
copy-on-write cloned a vector on the first write when `rc > 1`, and a
parameter register is a retained reference, so `rc` read 2 inside every
callee and the callee wrote a private copy that was thrown away. Every
Softanza helper that fills a list handed to it was silently a no-op. It
was invisible because no benchmark wrote through a parameter.

**Why not a better lazy rule.** Ring mixes value semantics (assignment)
with reference semantics (parameters, `this`), and identity matters: the
callee's `l` must BE the caller's `a` while an assignment-copy `b = a`
must diverge. No single clone-on-write choice satisfies both -- whichever
of `a`/`l` or `b` writes first would take the clone, and the one that
must keep identity is not always the writer. So the copy is made where
Ring makes it: at the transfer, eagerly (`copyv`, a deep clone emitted
after a read out of a variable-like place at each store site; a scalar or
a string passes through). A write never clones any more.

**What it costs, measured (ms, best of 5; the old binary built from
d73f41c in a worktree, same flags):**

```
                       old      new       Ring 1.27 (oracle)
  Sieve 1,000,000     57.5     55.5       --   no list assigned: noise
  MatMul 120          41.2     40.6       --
  Fib 27              10.8     10.9       --
  SortN 100,000      108.8    130.1     2,774   MergeSort RETURNS a list at
                                                every level: +20%, 21x under Ring
  AssignN 100,000      1.2    349.0    10,843   a 100K list assigned 1,000 times,
                                                the worst case on purpose:
                                                3.5 ns per element, 31x under Ring
  ParamN 100           1.15     1.14       16   a callee appending through its
                                                parameter -- correct now
```

**The pattern it hurts:** a function that returns a list variable, or
code that assigns whole lists in a loop, now pays a deep copy each time
-- as Ring does, and at 21-31x less. Decision 4's "costs nothing" was
measured on rows that never assign a list; AssignN is what it hid.
`-Dcow` stays in build.zig for the build names and changes nothing.

---

## C-8 · The runtime error report, and two things found while writing it

**Verdict: keep Ring's report, byte for byte; one Ring defect not
reproduced; the `+` divergence FIXED to match Ring. Taken by the session
2026-09-11; decided by delegation the same day.**

An uncaught error now prints exactly what Ring 1.27 prints (measured,
`bench/exec/err_func.ring`, `err_method.ring`, `err_loaded.ring`,
`err_caught.ring` -- all identical to the oracle):

```
                                        <- a blank line
  Line 7 Error (R1) : Can't divide by zero   <- trailing space
  In function c() in file err_func.ring     <- "In method m()" for a method; names lowercased
                                        <- blank
  Called from line 5 In function b() in file err_func.ring
                                        <- blank
  Called from line 3 In function a() in file err_func.ring
                                        <- blank
  Called from line 1 in file err_func.ring    <- the top level, last, trailing space, no newline
```

A loaded file is named as Ring names it: the real path of its directory,
`/`, its name -- `C:\...\sub/dep.ring`, mixed separators and all. The
root is named as typed. A caught error is the message alone. An
undefined callee is R3 and CATCHABLE (it used to print and exit). Every
instruction carries its source row, file and function now (three tables
in `Program`), which is what the chain is read from; the exit code is 1.

**Amended 2026-09-11: the line is the INSTRUCTION's, not the statement's.**
Measured on the oracle:

```
  x = Boom() +        Boom() raises -> "Called from line 2"  (the call's line)
      1 + 2
  x = 1 + 2 +         -> "Called from line 4"                (likewise)
      Boom()
  x = 1 /             R1 -> "Line 4": where the second operand sits
      0
  raise( "a" +        -> "Line 7": the closing paren, after the arguments
  "b" + "c"
  )
```

In every case it is the END row of the node that emitted the instruction,
so rows are set per expression node now, not once per statement -- a
multi-line statement used to report its first line, and stkProfiler's
five-line `raise(` came back as 33 where Ring says 37. A call re-sets the
row after its arguments compile, because the arguments are nodes too and
move it while they run.

**And `raise()` puts a frame of its own in front:** `In raise() In
function f() in file F`, and `In raise() in file F` at the top level.
Probes: `bench/exec/raise_multiline.ring`, `raise_top.ring`,
`err_midline.ring`, byte-identical to the oracle.

**Not reproduced, on purpose:** for an uncaught `Bad parameter type!`
Ring prints NOTHING and exits 0 (measured: `x = 1 : "5"` at the top
level). Ring++ reports it like every other error and exits 1. **What it
costs:** a program that relied on a silent exit 0 there -- none should.

**`1 + "abc"`, decided: match Ring.** Measured on both builds
(`bench/exec/plus_string.ring`, ten lines identical): number + numeric
string adds (`1 + "5"` is 6, `1 + " 7 "` is 8, `1 + ""` is 1, `1 + "1.5"`
is 2.50); number + anything else is R41 (`"abc"`, `"5abc"`); string +
number concatenates (`"5" + 1` is "51"); `-` and `*` take a numeric string
as a number too (`1 - " 7 "` is -6, `2 * " 3 "` is 6). Three things were
wrong here, none of them in `addSlow`'s rules: the compiler folded a LEFT
constant into the immediate form for `+` -- `1 + "5"` became `"5" + 1`,
which is a different operator on Ring -- so it folds only for a right
operand proved numeric now; `coerceNum` did not trim spaces or read the
empty string as 0; and `muli` raised `Bad parameter type!` on any
non-number instead of taking the slow path. Softanza cannot have relied
on the concatenation: on Ring it never ran.

**The same rule for `=`, `<` and `for`, 2026-09-23 -- the decision above,
extended.** Ring has one conversion (`ring_vm_stringtonum`), and Ring++ had
it for arithmetic only: `0 = ""` was false where Ring says TRUE, `5 < "6"`
panicked, and `for i = 1 to "3"` was `Bad parameter type!`. One function,
`ringNumText`, serves all four now, and the arithmetic side changed too:
`"   "` is R41, not 0, and a leading VT or FF is skipped as strtod does (F-67,
76 rows, `bench/exec/null_is_zero.ring`, `num_text.ring`, `num_order.ring`,
`for_text.ring`). **What it costs:** ~2.5 ns per number-against-string
comparison (+12%), nothing on the integer paths.

---

## C-9 · A name assigned only inside an `eval` string

**Verdict: drop with a constraint. Decided 2026-09-11 by delegation.**
Finding: the 51 sites classified 2026-09-09 (27 names), and the one the
shadows guard kept pointing at.

`stzChainOfTruth.ring:786`, in `def Nth(pcThing)`: the method builds
`_cCode_ = 'result = Nth' + pcThing ...`, runs `eval(_cCode_)`, and then
`return _( result )`. `result` is never assigned in the method's source;
the eval'd string assigns it into the running scope and the next line
reads it. The compiler cannot see inside a string, so the read is a bare
name with no definition: a refusal at compile time, an R24 if it ran.

**The constraint:** a name assigned inside an eval string is not a
variable the surrounding code can read. Where the value must come back
out, it comes back as a global -- `$result` on both sides of the eval --
or the eval goes: `Nth` is a dispatch by name, which `call` does without
a string. **What it costs:** one sigil per site that smuggles a value
out of an eval, 51 sites in the estate, a mechanical pass in Mansour's
tree (`rnxc migrate` lists them). Ring's behaviour -- an eval that
creates variables in its caller's scope -- is the analysis's 2.3, the
language redefinable from inside the program, and it is not carried.

**REVISED 2026-09-23, by delegation (Mansour: "take the decisions in my
place") -- eval runs in its CALLER'S scope, as on Ring.** The constraint
above was priced at 51 sites. Counted again across the library (tests,
future/ and archive excluded), there are **136 eval sites in 44 files**, and
the dominant shape is exactly the one it forbids: `_cCode_ = '_value_ =
pObject.' + cAttr` then `eval(_cCode_)` then a read of `_value_`
(stzFuncs.ring:699, stzCache.ring:149, stzList.ring:4019 and on). Carrying
C-9 means rewriting Softanza in 44 files to keep a rule whose point -- a
language that cannot be redefined from inside -- belongs to HARO, which is
where it will be kept. Ring++ is the bridge, and commitment 2 says the
estate keeps running. **So:** a function that calls `eval` gives its
locals, parameters and the names it reads without assigning a frame view;
the string is compiled at run time against the running program and binds
those names to the caller's own registers. **What it costs:** a function
that calls eval keeps every local boxed and visible (it loses integer
specialisation), and eval shuts the checker's absence rules for its unit,
as it already does. Measured when it lands.

**IMPLEMENTED 2026-09-25.** The string is compiled at run time by the same
compiler and bound to the calling frame: the caller's locals and
parameters by REGISTER, through a per-function locals table that the
compiled image and the library prefix both carry; its attributes and
methods by NAME on its receiver; globals through `global_names`; user
functions by name through the string-call path; classes by name. A name
the string spells in its literal prefix is declared in the caller at
compile time, so the caller's own code reads it afterwards -- written in
the call (`eval("x = ...")`) or a few lines above it (`_cCode_ = 'x = ' +
...` then `eval(_cCode_)`, the estate's dominant shape). A name no prefix
spells lives above the frame and is gone when the eval returns, so the
caller's read of it is R24, as it would be on Ring without the eval. An
error nothing inside catches is raised AT the `eval`, where the caller's
`try` catches it. A function or class defined inside eval is refused with
E1: no estate site does it, and Ring's answer (it is real) is recorded in
F-72. `bench/exec/eval_scope.ring` and `eval_cache.ring`, byte-identical
on the oracle and official 1.27.

**What it costs, measured** (minima of seven interleaved rounds):

    a function that contains an eval ANYWHERE, even one never run: every
      local boxed. 20,000,000 iterations of `s = s + i`: 0.122 s -> 0.155 s,
      1.27x. The pattern it hurts is a hot numeric loop in the same
      function as an eval; moving the eval into its own function buys it
      back.
    an eval whose (caller, string) was seen before: below this
      measurement's floor -- 20,000 of them add ~1 ms to a 9 ms loop.
      Ring pays 14 us each, re-parsing every time.
    an eval of a string NEVER seen before: 49 us, against Ring's 14. A
      loop that builds a different string per item pays that each time.
    the kernels, which call no eval: 0.98x-1.01x, spreads overlapping.

---

## C-13 · Reading `aHash[k]` does not insert it

**Verdict: fix, silently. Decided 2026-09-23 by delegation.** On Ring a
READ of a missing key in a hash list inserts `[k, ""]` (`hd:D1` in
bench/ab-known.txt, the correction that waited for a number). Ring++ reads
and leaves the list alone. A read that mutates is the analysis's
side-effect-on-read defect; no narrated test depends on the insertion
(the wide clock has no row for it), and Haro will not have it. **What it
costs:** code that counted on a read creating the key finds the list one
item shorter -- none known.

## C-14 · A top-level lambda's bare write reaches the top level's global

**Verdict: break with a rule -- lexical. Decided 2026-09-23 by delegation.**
C-2 keeps a named function's bare write local (Rule A: a function cannot
reach its caller's variable, F-25). A lambda is different: its free READ
of a top-level name already reads the global, since 2026-09-22, because
that is lexical scope -- the lambda's names are its DEFINING scope's names.
Its WRITE now follows the same rule: a bare assignment inside a lambda to
a name that is a top-level global of the unit (not a parameter, not a
capture) writes that global, as on Ring. It does not reopen F-25 -- the
lambda reaches the scope that DEFINED it, never its caller's. Found by
`rnxc shadows`: 7 sites in the 12 sampled tests, all top-level lambdas in
reactivehttp/01_http_setters (`func e { cWhy = "" + e }`). **What it
costs:** a lambda that meant a scratch local and shares a name with a
top-level global overwrites the global -- exactly Ring's behaviour, so no
estate code is newly exposed.

**Implemented 2026-09-24**, in one place: `topGlobal`, the question every
write site asks -- an assignment, `n++`, `aL + item`, `add(aL, x)`, a
subscript root -- answers yes inside a lambda whose defining scope is the
top level (`Func.encl`, walked through nested lambdas) for a name that is
a top-level global of the unit and neither a parameter nor a capture.
`bench/exec/lambda_write.ring`, five rows. reactiveobject/error_record,
r54_fix, 02_setters, reactivefunc/01, reactivestream/01_autoconclude and
reactivehttp/01_http_setters all agree with the oracle bar their timing
lines now; they had died on `nFires++`, `gGot = "" + v` and `cWhy = "" +
e` inside such lambdas.

## C-15 · `cCatchError` outside a handler is Ring's process-wide value

**Verdict: fix, with one row kept. Decided 2026-09-24 by delegation.** On
Ring `cCatchError` is one process-wide variable (F-68): `NULL` before any
catch, then the last caught message, readable from any function until the
next catch overwrites it -- and a handler's own read is overwritten by any
catch a CALLEE runs. Ring++ bound the caught value to the handler's own
register (§2.17) and REFUSED every read outside a catch body. Softanza
reads it through a function, `CatchError()` in stkRingFuncs.ring, from
inside its handlers, so every reactive watcher and computed attribute died
on that refusal once the reflection family let them run. Now: inside a
catch body `cCatchError` is still the handler's own binding; anywhere else
-- a function, the top level, a `try` body -- it is the VM's last caught
error, recorded at every handler landing, `NULL` before the first.
`bench/exec/catch_error_global.ring`, nine rows. **What is kept**, the one
row where the two rules differ: `raise("outer")`, then a callee that
catches "inner" -- Ring's handler then reads "inner", Ring++'s reads
"outer", while `CatchError()` reads "inner" on both. The §2.17 improvement
survives for the direct read and only there. **What it costs:** a program
that relied on the refusal to find such reads at compile time loses it --
none in the estate, which reads the value on purpose. Two census refusals
gone (278 -> 276).

## C-16 · An attribute a class body CREATES by reading it is listed last

**Verdict: keep, silently. Decided 2026-09-24 by delegation.** F-70: an
unknown name read in a class body makes Ring create an attribute of that
name, NULL, and Ring lists it in `attributes()` WHERE the read happened
(`x`, `$nope`, `y` for `x = $nope` followed by `y = 1`). Ring++ creates it
too (`ggeta`, the prologue's global read, over the per-object attribute
list `addattribute` uses) and lists it after the declared ones. The value,
the method read and the top-level R24 all match; only the order differs.
**What it costs:** code that indexes `attributes(o)` by position around
such an attribute -- none known; Softanza's one case is a typo'd
`$cDefaultDiagramOutputFormat` nothing lists.

---

## C-17 · A whole double of 128 characters or more prints in Zig's shape

**Verdict: keep, silently. Decided 2026-09-26 by delegation.** F-75: Ring
prints a whole double past +/-(2^53-1) through "%.Nf" -- its exact
expansion -- and Ring++ does the same since 2026-09-26. Ring's buffer is
RING_MEDIUMBUF, 128 bytes (`ring.h:160`), and when the expansion does not
fit, Ring prints "%.90e" instead (`general.c:359`). Ring++ answers there
with Zig's decimal rendering. **What it costs:** a number near 1e125 or
beyond prints differently. None is known in the estate; reproducing
"%.90e" exactly means ninety-one correctly rounded digits, which is not
worth writing for a case nothing reaches.

---

## C-18 · Ring's stdlib is shipped with its Rule A migration applied

**Verdict: fix, in our copy. Decided 2026-09-27 by delegation.** Ring's
`stdlib.rh` defines nine globals at its top level and `stdlibcore.ring`'s
functions read them BARE -- Sleep() reads C_SECONDSIZE, List2Code() keeps
its indent in List2CodeTabsCounter, RandomList() raises
C_ERROR_EXPECTLIST. Under Rule A a bare name in a function is that
function's local, so Ring++ refused eight functions of Ring's own library,
and `sleep()` and `list2code()` -- about twenty live Softanza sites --
raised. `rpp/stdlib/` holds the two files with the seventeen reads made `$`
and each constant defined under both names on its own line (the program
keeps the bare one); every line number is Ring's. build.zig installs them
in place of the vendored pair for rnxc only; the vendored files stay for
the ORACLE, the precedent `rpp/ringzip/ziplib.ring` set. Ring itself gives
the same eleven answers on the copies as on its own files
(`bench/exec/stdlib_core.ring`). **What it costs:** two files that follow
Ring's by hand; a new vendored stdlib means re-applying the migration
(scripted, seventeen sites asserted). The alternative -- relaxing Rule A
for reads of a top-level global -- is a language decision this does not
take.

---

## C-19 · `new` of a class nobody defines compiles to Ring's R11

**Verdict: match Ring. Decided 2026-09-27 by delegation, reversing the
refusal.** The compiler refused `new K` when the unit defines no class K,
and said why: most such sites are typos (`stzEnity`), and catching them
statically is commitment 4. But the refusal did harm Ring does not: at the
top level a refused statement stopped the program inside its own `try`,
and Ring raises R11 only where the line runs, catchably, before the
constructor's arguments (F-78). F-63's verdict decides it -- a refusal is
the safe answer only when the alternative is a WRONG one, and this one is
Ring's. **What it costs, and what keeps the benefit:** a typo no longer
stops compilation. `rnxc check` reports it statically (rpp/unknown-class,
F-48), and the census counts every such site apart -- `new` of a class the
unit does not define: N site(s) -- and lists each under `--all`: 42 in the
base unit on the day, 30 of them max-layer classes the base unit cannot
see, 2 in files it does not load (stzStringView, stzStorage in future/),
and 10 that exist nowhere in the tree.

---

## C-20 · A member of `new K(args)` is the new object's

**Verdict: fix silently. Decided 2026-09-27 by delegation.** F-82: Ring
raises R13 for `new K(1).M()` and runs `(new K(1)).M()`; the two differ
only in parentheses Ring's grammar needs and a reader does not. Ring++
compiles both as the second, as it always has -- this records a behaviour
that was never decided. The estate WROTE the shape sixteen times in live
code, each expecting it to work, and each fails on Ring when it runs:
Ring++ gives those lines the answer their authors meant. **What it costs:**
a program that relies on that R13 -- catching it -- would differ; none is
known. A test through one of the sixteen reads R13 on the oracle and runs
on here, so the wide clock counts it as a difference in Ring++'s favour,
the "runs longer" kind. The sixteen are listed for Mansour; on Ring they
are fixed by the parentheses or by the Q-constructors (`StzListQ(x)`).

---

## C-21 · Leaving a `try` leaves its handler, from a function too

**Verdict: fix silently. Decided 2026-10-01 by delegation.** F-90: Ring
cuts its try list back when a METHOD returns and at `exit` and `loop`, and
does not when a plain FUNCTION returns from inside a `try` -- after which a
`raise()` ends Ring with exit 1 and no message at all. Ring++ leaves the
handler at every `return`, `exit N` and `loop N` that crosses a `try` body
(one `pend` each, emitted by the compiler), which is Ring's method rule
applied to functions as well. No program can depend on the silent exit:
it prints nothing and runs nothing after it. **What it costs:** a
`raise()` after a function's return-from-try is caught (or reported) by
Ring++ where Ring dies in silence, so a test through that shape prints
MORE here -- the "runs longer" kind. At run time one `pend` per jump that
leaves a `try`; code without a `try` compiles to the same bytecode
(bench/kernels.ring disassembles byte-identically before and after).

---

## C-22 · An engine C pointer is a number

**Verdict: keep, with a rule. Decided 2026-10-03 by delegation.** F-97: on
Ring a value a bridge hands back through `ring_vm_api_retcpointer` is a C
pointer -- `type()` answers its C type's name (`HtmlDoc`), `isPointer` 1,
`isNumber` 0. Ring++ carries every engine handle as its address in a number
(since 2026-09-12, when a handle stopped being a table id), so `type()`
answers NUMBER, `isPointer` 0, `isNumber` 1. 535 return sites in 25 of
Softanza's bridges use the C-pointer form -- every string, list and matrix
handle -- and nothing in the library type-tests one: its only `isPointer`
is on a LoadLib handle, which Ring++ answers as Ring does. Making them C
pointers would change 535 return paths, and with them what every handle
comparison, copy and print does, to win one assertion. **The rule:** test
an engine handle by what it answers, or by `!= NULL` -- 1 for a live handle
on both runtimes -- never by its type. **What it costs:**
file/52_html_dom_engine's `isPointer(pDoc)`, one assertion of Ring's 6,073
passes in the 432, changed in his tree to `pDoc != NULL` (the assertion's
own words are "the parse handle is non-zero"); and any estate code that
type-tests an engine handle, of which none is known. `isPointer` never
caught a failed parse on Ring either: an empty document is still an
`HtmlDoc`, with no elements.

---

## C-23 · A statement that begins with a unary `+` or `-` is compiled over the whole rest, and it is kept

**Verdict: kept, not reproduced; a fix deferred until an estate site exists. Decided 2026-10-05 by delegation** ("take whatever decision you
think is wiser on my behalf"). HF-79: the grammar reads a statement that BEGINS with a unary `+` or `-` as that operator over everything
after it whenever the rest holds a binary `+` or `-` (`-a * b - c` is `-(a * b - c)`); Ring reads the unary as binding tighter than any
binary operator, `((-a) * b) - c`. rnxc compiles the grammar's tree, so the two differ in WHEN the operators run -- `-o - 3` on an object
whose `operator` prints its name calls `-` then `neg` here and `neg` then `-` on Ring (oracle and official 1.27 agree). The statement's value
is discarded, so nothing but an overloaded operator can tell. **Why it is kept:** the estate has no site -- one file in 6,275 holds the shape,
`bench/exec/newline_rule.ring`, written to pin the newline rule, and none of Softanza's 6,061 Ring files under 400 KB -- and a clean fix
touches the type inference (`exprClass`, `operandReg`, `borrowOperand`) or re-reads the statement with its leftmost operand parenthesized,
either of which risks a silent change to code that is right today, for a shape no one writes. **What it costs:** a program that overloads
`neg` and begins a statement with it, followed by an additive operator whose overload has an effect, runs those two calls in the other
order. **The guard:** `rnxc fmt` reads the statement Ring's way (v18 fixture 23, judged by the oracle), so formatting never moves the
divergence; `haro/spike/v18/probes/unary_stmt.ring` is the six-row probe, and the first estate site changes this verdict to **fix
silently** -- the shape is syntactic, so a checker rule can find every site before it does.

## C-24 · An object from a list as an operator's right operand is dispatched

**Verdict: fix silently. Decided 2026-10-08 by delegation** ("do my tasks on my behalf then go ahead"). F-100: on
Ring 1.27 `o + aF[1]` -- an object read from a list, as the right operand of an overloaded operator -- ends the
program with exit 1 and no message, uncatchable, on both builds. Ring++ dispatches it to `operator` like any other
operand and answers. **Why:** an exit with no message is not a behaviour any program relies on, and the same
expression through a variable answers on Ring too, so the answer Ring++ gives is the one Ring gives one statement
later. **What it costs:** a program that died silently on Ring runs on here, and so differs from the oracle from
that line on; the one estate site, base/test/duration/11, now takes the operand out of the list first (stzlib
b9d5cd1e4) and agrees on all three runtimes. **The guard:** none needed on our side -- the dispatch is the general
path; F-100's rows are the probe, in the finding.

---

## C-25 · A load that names a file nobody can open: the program is refused, as on Ring

**Verdict: match Ring. Decided 2026-10-09 by Mansour** ("refuse missing loads like Ring"). F-101: Ring 1.27 reports
an unopenable load while PARSING -- E9 with the path as written, C27 at the load's line in the loading file, each
file's error count, a loaded file's errors costing its parent a C27 too -- runs nothing, not even the lines above the
load, and exits 1; all on stdout. rnxc printed a note and ran the program without the file. It refuses now, with
Ring's report in Ring's order (a depth-first walk of the loads; `refuseMissingLoads` in src/rnxc.zig), and `rnxc
prefix` refuses to build a library with a hole in it. **Why:** running on hid a defect that made Softanza unusable on
a real Linux disk -- the 2026-09-28 package check passed with stzJsonFuncs.ring missing -- and a program missing a
file it names is not a program anyone means to run. **What it costs:** a program that ran here with a file missing
stops now, exactly where Ring stops. NOT reproduced: a load nested inside a block, which Ring reports as C3 ("'ok' is
missing") and the loader does not follow at all; Softanza has none (C-4). **The guard:** bench/exec/load_missing.ring
-- a missing load in the root, in a loaded file and in a file that one loads -- 11 lines identical to the oracle on
Windows and to the Linux oracle under WSL; the build before printed the line above the loads and ran on. Gate PASSED.

---

## C-26 · A trace frame names the file its code is in, whether or not its call site ran before

**Verdict: fix silently. Decided 2026-10-13 by Mansour**, on the recommendation in the session that measured it ("go ahead, record
C-26 and C-27"). F-112: Ring prints each frame of a trace with the file its call recorded. The first time a call instruction runs, that
is the callee's own file; Ring then rewrites the instruction into a cached form (`ICO_LOADFUNCP` for a function, vmfuncs.c:909;
`ICO_LOADMETHODP` for `o.m()` while the class is the one cached, vmoop.c:382-390; `ICO_LOADBRACEMETHODP` inside braces), and the cached
form records the file that is CURRENT and leaves it current (vmperf.c:174-178, vmoop.c:460-462). From a call site's second run on, the
frame names its caller's file -- `Called from line 1813 In method edgeproperty() in file .../stzGraphPlanner.ring`, where line 1813 is in
stzGraph.ring. Ring++ names the file the code is in, always. **Why:** the line and the file of such a frame disagree, so Ring's answer is
wrong rather than different; it depends on how many times a call has run, which no program can rely on; it shows only in the trace of an
error nobody caught (`cCatchError` carries no file); and reproducing it would put a per-call-site state, and a class cache for methods, on
every call the estate makes -- commitment 3 traded for trace lines. **What it costs:** eight rows of the wide suite differ for ever on one
trace line (graphplanner/28-30, table/173, 176, 177 and 216, extercode/test_extercode_regression); no assertion, so parity is untouched.
**The guard:** `bench/why432.py` classifies a row whose every differing line is a trace frame differing only in its file as `decided
(C-26)`, apart from the rows that differ; six probes in the finding run each call site once and agree with Ring.

## C-27 · After `if a or <operand ending in a literal>`, the body's first statement reports its own line

**Verdict: fix silently. Decided 2026-10-13 by Mansour**, as C-26. F-113: when the right operand of a condition's last `or` ends in
anything but an identifier, Ring's parser has passed the newline after it, and emitted the next line's line marker, before it emits
`ICO_OR`; the `or`'s short-circuit jump (`ICO_JUMPONE2`, taken when the left side is true) lands past that marker, so the first statement
of the body reports the line of the `if`. Ring++ reports the statement's own line. **Why:** the same three reasons as C-26 -- the line is
wrong, it depends on which side of the `or` decided, it shows only in an uncaught error's trace -- and reproducing it would put a
line-clearing instruction on every `or` that does not short-circuit, the common case in a condition. **What it costs:** two to four rows of
the wide suite differ on one trace line (table/173's `Called from line 5832` among them). Its static half -- a condition ending in a literal
reports its comparison on the body's line, one row (listofstrings/08) -- is NOT decided here: it is named under F-114, not done.
**The guard:** `bench/why432.py` classifies a row whose every differing line is such a line -- Ring's line an `if`, `but` or `elseif` whose
condition holds an `or`, Ring++'s a later line -- as `decided (C-27)`; 27 shapes in the finding.

## C-28 · Ring's features that only Ring's own programs use are not reproduced, and they stay loud

**Verdict: drop with a constraint. Decided 2026-10-14 by Mansour** ("go ahead with all four"), after he stated that Ring is retired from
all his projects and that RingServ, RingScript and MicroRing are test projects for Ring++ and bases for Haro's own -- never products to
maintain on Ring. Ring++ carries Softanza and the customers on it; a feature of Ring that no Softanza code uses is not built for its own
sake. RingServ's sweep found them in Ring's samples and documentation (CLAUDE.md "RINGSERV ON RING++"):

    packages              `package` and `import` are refused; ispackage, ispackageclass, packageclasses, packagename and importpackage
                          are R3; a class named inside a package is R11 (7 sweep rows)
    syntax-changing       ChangeRingKeyword, ChangeRingOperator, LoadSyntax, EnableHashComments, DisableHashComments are refused
      commands            (`scanner_command`)
    Ring's implicit       `ringsyntax.ring` beside any file Ring reads, `startup.ring` beside the first, and `ring.ring` / `ring.ringo`
      files               in the current folder, which Ring runs INSTEAD of the program named: the program is REFUSED, naming the file
                          (new, `implicitAtStart` and `loadUnit` in src/rnxc.zig) -- Ring++ used to ignore them and run a different
                          program from Ring's, saying nothing (Ring's SyntaxFiles sample: `proc` read as a variable, R24)
    NULL, TRUE and FALSE  are variables on Ring (`NULL = "x"`, `TRUE = 0`); assigning one is refused (the design charter's first hazard)
      as variables
    the VM inside the VM  ring_state_* (16 names: a Ring VM embedded in a Ring program) and ringvm_* (24: Ring's own call list, memory
      and its tracer      list, tracer and code list): R3. Softanza's one caller is max/test/stzStateSystemTest, a test OF Ring's
                          embedding API; `ringvm_fileslist` appears once more, as a name in a list in stzFuncs.ring

**Why:** each is Ring's machinery or Ring's hazard, not Softanza's need, and Haro will not have them in this shape; building them would
spend the bridge's effort on the platform being left. **The constraint is that each stays LOUD** -- a refusal at compile time or R3/R11
when the line runs -- so a program that uses one learns it at once and never runs on with a different answer. Measured that way for every
row above (scratch probes, 2026-10-14); the implicit files were the one silent case, and are closed. **What it costs:** Ring code that uses
one of these does not run on Ring++, by design; Softanza's library uses none of them -- no package or import (searched), no syntax
command, no implicit file, no assignment to NULL, TRUE or FALSE (the census refuses none), no ring_state_* or ringvm_* call (the
census's natives list). **NOT in this correction, because Softanza uses them -- each looked Ring-only and is not:**
`ref()`'s rule that a referenced list or object is SHARED by later plain assignments -- Softanza's stkMemory relies on it
(`_oBuffer_ = @aBuffers[id]`, then mutating it), so it is a defect to fix (FIXED 2026-10-14, F-118, `bench/exec/ref_share.ring`); and THE POINTER FAMILY (varptr, nullptr, getptr, setptr,
memcpy, ptr2str, ptrcmp, object2pointer and their aliases), which is Softanza's own buffer layer: core/system/stkBuffer.ring and
stkPointer.ring, about 25 sites, loaded into every program by stzCore.ring. It is R3 today -- core/test/stkBufferTest stops at its 7th
line, `nullptr` in stkBuffer's init, where Ring prints 102 -- and what that layer runs on under Ring++ was decided as C-31 (not built,
loud; the engine is the route if Softanza needs buffers). Nor the other loud gaps the sweep found -- the reflection builtins, print(), input()
and the rest: left loud, built when Softanza-shaped code needs them. **The guard:** `bench/implicit_files.py` (four shapes refused on rnxc and read on the oracle, and a control); the build before fails
four of five.

## C-29 · A parameter holding a list or an object is rebound by an assignment, and the caller's variable is left alone

**Verdict: fix silently. Decided 2026-10-14 by Mansour** ("go ahead with all four"), on the recommendation of the session that measured
it. F-116: on Ring a parameter holding a list or an object IS the caller's variable for the whole call -- `p = [9, 9]`, `p = NULL` or
`p = new P` rewrites what the caller holds, whether it passed a variable, a list element or an attribute, and the parameter stays the
caller's after the assignment (`p = [7]` then `add(p, 3)` leaves the caller `[7, 3]`). Ring++ keeps C-7's model: the parameter starts as a
reference -- every write THROUGH it (`p[1] = 99`, `add(p, 3)`, `p.x = 5`) reaches the caller, as on Ring -- and an assignment TO it
rebinds the local. **Why:** an assignment to a local name reaching into the caller is the hazard Rule A exists to remove (F-25, the
analysis's 2.7), one level down; it is the rule Haro will have; and the estate shows no dependence on Ring's: every one of the 8,540
assertions Ring passes passes on Ring++. **What it costs:** Ring code that reassigns a list or object parameter and expects the caller to
see it gets the caller's old value, silently -- Ring's samples sortFirst and sortSecond (`aList = sort(aList, 1)` inside a function) and
doc snippet usingref-09. In Softanza's library a line scan finds 148 functions, 169 sites, assigning to a parameter named for a list or an
object, most of them `paList = paList[2]`, the named-argument unwrap, whose caller passes a temporary; none is known to need the write.
**The guard:** none yet that can fail on the estate; the 11 rows of F-116 are the record. A site that needs Ring's answer writes through
the parameter instead (`del`/`add`/indexing), which both runtimes agree on.

---

## C-30 · A numeric `for` reads its bound once

**Verdict: break, with a rule -- the bound is evaluated once, before the loop, as Lua does by rule. Decided 2026-10-14 by the session
on Mansour's delegation ("close those on my behalf").** F-120: Ring re-evaluates the `to` bound on every turn, so a body that changes the
variable a bound reads, or the list a `len()` bound measures, changes how long the loop runs, and a call in the bound runs once per turn.
Ring++ evaluates it once. **Why:** a loop whose length changes under it is almost always a defect, and the census says so -- of the 8,954
numeric loops in Softanza's library (through rnxc's lossless export), none grows or shrinks what its bound reads, five of the six that
reassign a bound variable leave or restore it before another turn, and the sixth, `stzTable.FindCellsCS`, was a defect Ring's rule made
real: its inner `_nLen_ = len(_aTemp_)` overwrote the outer bound, so on Ring `FindCells(["sara", "ali", "paris"])` searched one value
of three. Fixed in his tree (e77bab17d, pushed 2026-10-15): the inner count is `_nLenTemp_`, and official Ring now answers all four cells, as Ring++
did. And the once-read bound is F-41's whole performance point -- `for i = 1 to len(s)` re-copied the string every turn on Ring. **What it
costs:** Ring code that grows a list inside `for i = 1 to len(aL)` and expects to walk the new items stops at the old length, silently --
the worklist shape; a body that deletes from the list it walks by `len()` reads past the end (R2) where Ring stops early; a bound with
side effects runs them once. **The guard:** the F-120 census, repeatable through `rnxc dump --json`; `while` and `do ... again` re-test
their conditions every turn on both runtimes, and are the spelling for a loop whose limit moves.

---

## C-31 · Ring's pointer family is not built, and stays loud

**Verdict: drop with a constraint. Decided 2026-10-14 by the session on Mansour's delegation ("close those on my behalf").** `varptr`,
`nullptr`, `getptr`, `setptr`, `memcpy`, `ptr2str`, `ptrcmp`, `object2pointer`, `pointer2object` and their aliases, with `space()`
whose only callers fill buffers for them, are R3 on Ring++ and remain so. C-28 had left them out of its Ring-only list because Softanza
calls them; the census says how: **the calls sit in one self-contained layer** -- core/system/stkMemory.ring, stkBuffer.ring and
stkPointer.ring, wrapped by base/system/stzPointer.ring -- and nothing else in the library uses that layer: outside it there are two
`load` lines, a list of Ring's function names in stzFuncs.ring, and one method, stzObject's `return object2pointer(This.Object())`. Its
only users are its own four tests in core/test (stkBufferTest, stkMemoryTest, stkPointerTest, stkMemoryBufferPointerTest). **Why:** a
faithful version hands Ring code raw access to Ring++'s heap -- `varptr` on a value that may sit unboxed in a register, `memcpy` into a
string's bytes that other holders share by reference (C-7) -- which is unsound in this VM's value model and the opposite of commitment
4; Ring's own pointers are a C extension's convenience, not a language need, and Haro will not have them. **What it costs:** Softanza's
raw-memory API (stkMemory and its pointers, stzPointer, stzObject's object pointer) runs on Ring only; a program using it stops at the
first such call with R3 naming the function, so nothing runs on with a wrong answer. **If Softanza needs buffers on Ring++**, the route is
its ENGINE -- a Zig domain with typed handles, the way every other native resource in the estate is held (C-22) -- not raw pointers in the
VM. That is Softanza's design work, in his tree, and nothing here blocks it. **The guard:** core/test/stkBufferTest and its three
siblings stop with R3 on Ring++, loudly, as recorded in the RingServ section of CLAUDE.md.

---

## C-10 · `decimals(n)` is a process-global, and it is kept

**Verdict: keep. Taken by the session 2026-09-11 (delegated).** The
analysis's 2.10 -- rounding is a mutable process-global -- stands as a
critique; the estate SETS it at load (`StzDecimals(2)`, stzNumber.ring:91)
and the library did not load without it, so Ring++ has it.

Measured on both builds (`bench/exec/decimals.ring`, eleven lines
identical): default 2; the setting governs `?`, a concatenation and
`string()`; a whole number prints without a point at any setting --
WITHIN +/-(2^53-1), Ring's own bound (F-75, 2026-09-26: past it Ring prints
"%.Nf", so 2^53 is `9007199254740992.00` under decimals(2)); 0..90,
else `Error (R33) : Bad decimals number (correct range >= 0 and <= 90)`;
`decimals(20)` prints the exact expansion (`0.33333333333333331483`).

**Rounding, and C-1 made exact.** Zig's `std.fmt.float.render` at a
precision rounds the shortest decimal STRING half up: 2.5 -> 3, 0.125 ->
0.13, 2.675 -> 2.68. Ring (glibc `printf`) rounds the exact binary value
half to even: 2, 0.12, 2.67 (2.675 is 2.67499999999999982...). The digits
come from the exact expansion now (`fmtDecimals`: the double as m * 2^-k,
the fraction by repeated *10 over a u128 remainder, the rest of the
remainder deciding up, down, or an exact tie to even), so every tie and
every near-tie prints what the oracle prints. `string()` went through
`numOf`, which panicked on a float; it prints a number as `?` does now.

---

## C-11 · The loop variable is scoped to its loop

**Verdict: break, with a rule. Raised by Mansour upstream years ago and
declined there; decided here 2026-09-11.** Finding: the analysis's 2.12.
Blast radius on Softanza, measured over 116,271 statements: **0 reads
after a loop**, and **2 real bugs found**.

Ring leaves four different values behind, measured on both builds:

```
  for i = 1 to 5      next      i = 6    a value the stated range never contains
  for i = 1 to 5 step 2 next    i = 7    likewise
  for i = 5 to 1 step -1 next   i = 0    likewise
  for i = 1 to 5  ... exit ...  i = 3    the last value actually taken
  for i = 1 to 0      next      i = 1    the start, from an iteration that never ran
  for i = 1.5 to 3.5  next      i = 4.50
  for x in aList      next      x = ""   nothing at all
```

Four constructs that look identical leave four kinds of value. Lua scopes
the variable to the loop so the question cannot be asked; Python leaves
the last value that actually occurred and raises NameError for a loop
that never ran; Ring is alone in yielding a number from outside the range.
**Ring++ takes Lua's answer**: after the loop the name is not a variable,
and reading it is a compile-time refusal naming this correction.

**What it does NOT do, stated plainly.** The loop variable is still an
ordinary frame local with one register, as Ring has one scope: the name
stops answering *reads placed after the loop*, it does not get a private
register. So a nested loop on the same name still shares it. Giving each
loop its own register was built and measured first, and it cost Sieve 55
-> 87 ms: the classify pass types locals BY NAME before any code exists,
and a per-loop variable is invisible to it. The refusal below catches the
case that matters instead, at its cause.

**Two rules, and what each costs:**

- **a read after the loop** is refused. Cost on Softanza: 0 sites. An
  assignment REBINDS the name -- after its loop it is an ordinary
  variable again, as Python and Lua allow -- which is what most of the
  31 sites the first draft flagged were doing (`_i_ = _aMembers_[_k_][_j_]`
  after a `for _i_` loop, then reads).
- **a loop that reuses the variable of a loop it sits inside** is
  refused. Cost on Softanza: 2 sites, and both are bugs:
  `stzFolder.ring:3553` (`SearchInFolder`) and `:3721`
  (`DeepSearchInFolder`) run `for i = 1 to _nLen_` over a directory's
  entries and, inside it, `for i = 1 to _nLenL_` over a file's lines. On
  Ring these are ONE variable: the inner loop destroys the outer index,
  the outer loop then walks the wrong range, and
  `_acResults_ + [_aEntries_[i][1], ...]` afterwards names an entry that
  is not the one searched. Shipping code, found by this rule on its first
  run. A refusal, not a rename: which loop the author meant is not the
  compiler's to guess.

**Measured cost in speed: none.** Sieve 55.4 -> 55.5 ms, MatMul 41.3 ->
41.3, Fib 11.8 -> 11.9 (best of 5, two passes, against the previous
build). Gated by `bench/exec/loops.ring` and `bench/exec/forin.ring`,
both identical to the oracle.

**Found while implementing it, and fixed:** `for i = 1.5 to 3.5` HUNG --
the counter was stepped as an integer bit pattern; a `forprep` opcode
normalises the bounds once at entry, so the loop still checks one tag per
iteration. And `for x in c` was not compiled at all: `forStmt` read the
body's first statement as the loop's bound. It is compiled now, with
Ring's semantics -- x IS the element (assigning it writes the list, a
nested row writes through), the container is re-measured every iteration
so an append during the loop is iterated, a string iterates by character.

---

## C-12 · A bare name a class DECLARES is that attribute

**Verdict: keep Ring -- this finishes Rule A rather than bending it.
Taken by the session 2026-09-11 (delegated).** Blast radius on Softanza:
108 refusals lifted, and a silent wrong answer removed.

Ring resolves a bare name inside a method **local -> attribute ->
global**. Step one was implemented; step two was promised in a comment
and never written. The cost was not only refusals:

```
  class K                         Ring          Ring++ before      after
    cTP = "start"
    def Fetch()  return cTP       "start"       REFUSED            "start"
    def Store(v) cTP = v          attr = v      a LOCAL, silently  attr = v
```

The write is the serious half: `o.Store("xyz")` then `o.cTP` is `xyz` on
Ring and stayed `"start"` here, **with no error** -- a wrong answer the
census could not see, which is the one outcome this project's rules
forbid outright. It reached the estate: `stzTraceContext` declares
`cTP = ""` and every one of its methods reads it bare, so a stopwatch's
trace id came back empty and the failure surfaced three frames away as
`R21` inside `stzLog.Where()`.

**Why this does not weaken Rule A.** Rule A exists because a bare
assignment in a function could reach a CALLER's variable (F-25, the
analysis's 2.7). That hazard is untouched: a name the class does not
declare is still refused. Step two is *provable*, not a guess -- the
class being compiled is known and the name is in its own declaration
list or an ancestor's. A local still wins: a parameter shields an
attribute (probed on 1.27), and so does an earlier assignment.

**Measured, before -> after:** Softanza's census 423 -> **315** refusals;
the bare-name refusals 196 -> **85**; usable functions 52% (23,739). The
34 assertion tests stay at 13 byte-identical, but the ones that differ
run far further -- `perf/labels` 4 -> 69 lines, `perf/judgment` 4 -> 46,
`common/log` 4 -> 37 -- and most now stop at a timing measurement no two
runs share. Gated by `bench/exec/attr_bare.ring` (read, write, compound,
parameter shielding, inheritance), identical to the oracle.

**What is left of the 85:** names no class declares -- eval-assigned
locals (C-9), `@`-less attributes on classes the unit does not define,
and genuine typos. Those stay refused.

---

## Where `ab-known.txt` is

`docs/FINDINGS.md` refers three times to divergences "registered in
`bench/ab-known.txt`" — `map:M10` and `map:M11` at line 2151, `bi:BI_IDX` at
line 2438, and "29 of them" at line 2211. That file is **not in this
repository**. It is `rnx-spike/bench/ab-known.txt` — 66 lines, in the
private repository that holds the new VM and the `rnxc` compiler, which
FINDINGS.md names by that repository name in the same findings.

It is the compiler's list of functions the prototype does not yet run,
each with a reason, plus entries marked `DIVERGENCE` for behaviour built
differently on purpose — `hd:D1`, for one: Ring inserts a key when you read
a missing one; Ring++ reads and leaves the list alone. Those `DIVERGENCE`
entries are corrections in everything but name, and belong here as `C-n`
entries with verdicts. They are not copied yet; when they are, each needs
its cost stated, which `ab-known.txt` does not record.

*(An earlier version of this note said the file was gone, descoped with the
2026-08-23 compiled-kernel design. Wrong on both counts: the file exists,
and `rnx-spike` began on 2026-08-29, six days after that descoping, as a
different thing. Left visible because the register should show its own
corrections.)*
