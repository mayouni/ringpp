# `ringpp` — the one CLI

*House style: `zin`. Banner box, scope line, grouped commands,
availability markers, shortcuts table, `doctor` / `info` /
`completions` / `grammar dump`. Written in Zig
(`src/main.zig` → `src/cli.zig` → dispatch), one command per file,
uniform handler shape `pub fn run(args, allocator) !u8`.*

---

## The design decision that makes this CLI different

Ring++ has **two altitudes of installation**, and the CLI must make that
visible instead of failing mysteriously:

| you have | you get |
|---|---|
| `ringpp.ring` + stock `ring.exe` | `check`, `why`, `fmt`, `info`, `bench`, `probe` |
| \+ any C compiler (tier 1/2/3) | `build`, `run --native`, `emit` |
| \+ vendored Zig (tier 3, 63 MB download) | `dist`, `targets` — cross-compilation |

So every command carries an availability marker, exactly as `zin` marks
`(needs project)`. Nothing is hidden; nothing silently degrades.

---

## `ringpp` with no arguments

```
+-------------------------------------+
|  Ring++ v0.1.0 -- Ring, two levels  |
+-------------------------------------+
Ring:   1.27.0 (stock, D:\ring127\bin\ring.exe)
Scope:  ledger  (D:\apps\ledger)          Toolchain: not installed

Analyse

  ringpp check [path]         Type-check and lint; no run, no build     (always available)
  ringpp why <rule|F-n|code>  Explain a diagnostic, or the Ring error   (always available)
  ringpp why <function>       Why a function is (not) compiled          (needs the toolchain)
  ringpp probe                Verify this Ring still satisfies Ring++   (always available)
  ringpp bench [path]         Run the measurement corpus on this build  (always available)

Build & Run

  ringpp run <file>           Run, compiling hot typed functions        (needs toolchain)
  ringpp build [target]       Compile ahead of time; native artifacts   (needs toolchain)
  ringpp emit <function>      Show the generated C for one function     (needs toolchain)
  ringpp dist                 Cross-compile for every shipped platform  (needs toolchain)
  ringpp targets              List available build targets              (needs toolchain)
  ringpp clean                Remove .ringpp/ artifacts and the cache   (needs project)

Project

  ringpp new <name>           Create a new Ring++ project               (always available)
  ringpp info                 Context-appropriate information           (always available)
  ringpp fmt [path]           Format Ring source                        (always available)
  ringpp test                 Run the project test suite                (needs project)

Toolchain

  ringpp vendor <sub>         install, status, remove, versions         (always available)
  ringpp doctor               Check environment, VM, toolchain, project (always available)

Meta

  ringpp version              Show version and the Ring it is bound to
  ringpp help <command>       Help with examples for one command
  ringpp completions <shell>  bash, zsh, fish, powershell
  ringpp grammar dump         Export the CLI grammar as JSON

Shortcuts:
  c=check        b=build        r=run          w=why
  doc=doctor     i=info         t=test         v=version      h=help

  Toolchain not installed -- 6 commands unavailable.
  Run 'ringpp vendor install' (downloads ~332 MB: Zig + the Ring VM source).
```

That last paragraph is the important one. It is the difference between a
tool that feels broken and a tool that tells you where you are.

---

## The commands that carry the design

### `ringpp check`

The highest-value command, and the one that needs nothing installed.

```
$ ringpp check base/system/

base/system/stkPointer.ring
  720:21  error   rpp/varptr-unknown-name
          varptr(:cBufferData) -- no variable 'cBufferData' in this scope
          (the local is '_cBufferData_'). This raises Error (R6), and the
          surrounding try/catch sets @pLowLevelPtr = NULL, so every
          low-level path below is dead.
  720:21  warn    rpp/varptr-to-local
          the target is a method-local; its buffer is freed on return.

base/system/stkBuffer.ring
  106:9   perf    rpp/string-rebuild-in-write
          left(@buffer,n) + data + right(...) rebuilds the whole string
          per write -- O(n). Measured 803 ms vs 1 ms for 2,000 patches
          of a 500 KB buffer (FINDINGS F-7). Consider RppBuffer.Poke.

  2 errors, 1 warning, 1 perf note in 27 files (0.4s)
```

Rule ids are namespaced `rpp/…` and every one traces to a finding with a
measurement. **No rule ships without a number behind it.**

#### Level 1 type checking

`check` also reads the type annotations Ring already accepts and reports
where they and the code disagree. **Runtime behaviour is unchanged** —
Ring parses parameter types and discards them, and Ring++ does not touch
that. What changes is that the annotation stops being a comment.

| rule | severity | |
|---|---|---|
| `rpp/type-hints-missing` | error | `int func F` is a *variable read*, not a declaration — `Error (R24)` unless `typehints.ring` is loaded |
| `rpp/type-arity` | error | Ring enforces arity exactly: R19 too few, R20 too many |
| `rpp/type-arg-mismatch` | warn | a literal argument contradicting the annotation |
| `rpp/type-return-mismatch` | warn | a returned literal contradicting the return type |
| `rpp/type-not-a-hint` | note | `bool` → `boolean`, and a short list like it |

The two error rules predict a specific Ring error code on a specific
line, so they were checked the only way that means anything: by running
the code. On its first real pass this found **99 latent R19/R20 crashes
in 46 functions** across Softanza, and one in Ring's own applications —
all dormant, mostly aliases that forgot to forward a parameter.

**Certainty is the design constraint.** Only *literals* are judged for
type, because anything computed is genuinely unknown in a dynamic
language; calls inside class bodies are not checked at all, because an
unqualified call there finds a method first (F-17); and functions after
the first class are not registered, because they are methods (F-21).
Each of those gives up real coverage to keep the checker from ever being
wrong about correct code — the same rule that governs `rpp/unparsed`.
`tests/fixtures/types_good.ring` exists to enforce exactly that, and
both fixtures are verified against Ring 1.27 rather than asserted.

### `ringpp why`

`why` answers two questions that turn out to be the same question at two
altitudes: *why did this happen*, and *why will this not compile*.

**Diagnostics — built, tier 0.** `check` has room for one line and one
paragraph; that is enough to obey and not enough to understand. `why`
takes whichever handle you have:

```
$ ringpp why R4

rpp/empty-catch
An empty catch block leaks one VM stack slot per caught error

  Symptom  Error (R4) : Stack Overflow, from code containing no recursion
           at all. It arrives after roughly 1,003 caught errors, so it
           survives every small test and fails in the loop that runs all day.

  Cause    Ring pops the raised value only when something in the handler
           consumes it. An empty handler leaves it on the VM stack, which
           is RING_VM_STACK_SIZE (1004) deep.

  Fix      Put any statement in the handler. One assignment is enough.

  Evidence bench/16_empty_catch_leak.ring — five arms, showing exactly
           which shape leaks

  Upstream ring-lang/ring#1644 — open.

  See      docs/FINDINGS.md F-16
```

Three ways in, because a user arrives with whatever they have: a rule
(`rpp/empty-catch`, or bare `empty-catch`), a finding (`F-16`), or **the
Ring error code they actually saw** (`R4`). The third is the one that
earns the command — `R4`, `R6` and `R20` name no cause, and each cost a
day here before it was understood. `ringpp why` alone lists everything.

Every entry carries an `Evidence` line naming the program that produces
its numbers, and a `Cost` line naming the pattern the fix makes worse.
A fix with no stated cost has not been measured, it has been believed.

Two tests keep this honest, and they are the reason the catalog can be
trusted: **no rule `check` can emit may be missing** from it (the rule
ids are scanned out of `check.zig` at compile time), and **no citation
may point at a `FINDINGS.md` heading that does not exist**. Both were
verified by breaking them on purpose.

**The compiler half — T4.** Once there is a compiler to report on, the
same command takes a function name. Asking today says so rather than
reporting a typo:

```
$ ringpp why SumColumn

SumColumn  (ledger.ring:214)          NOT COMPILED

  x  parameter 'aRows' has no annotation        inferred: list
  x  calls FormatMoney (ledger.ring:88)         not compilable
  ok nCol : int
  ok return : double
  ok loop induction 'i' : int

  Fix the two 'x' above and this function compiles.
  Its inner loop matches the K2 shape (bench/headroom): 96x measured,
  minus ~43 ns of call boundary per invocation.

  Runtime guard failures observed: 0
```

That last line matters (T4 in [DESIGN_TOOLCHAIN.md](DESIGN_TOOLCHAIN.md)):
a function can be compiled and still fall back every call because the
annotations lie. `why` must report what actually happened, not only what
the analyser believes.

### `ringpp doctor`

```
$ ringpp doctor

Environment
  ok  ring          1.27.0   D:\ring127\bin\ring.exe
  --  zig           not found                    (needed for: build, run --native)
  ok  ringpp.ring   0.1.0    D:\apps\ledger\lib\ringpp.ring

Conformance (probe.ring, 31 rows)
  ok  31/31 on Ring 1.27.0                                        0.6s
      varptr write-through .......... ok
      varptr address stability ...... ok
      genarray speedup + invalidation ok
      type annotation channel ....... ok   (stmt.c Support Type Identifier)
      bytecode listing shape ........ ok
      sub-state isolation ........... ok

Project  (ledger)
  ok  47 Ring files, 12 annotated functions
  --  3 functions annotated but not compilable   (ringpp why)
  ok  no rpp/ errors

  Toolchain not installed. Analysis is fully available; compilation is not.
```

### `ringpp vendor`

The command that prices the second altitude honestly.

```
$ ringpp vendor install

Current tier: 0 (library only). Kernels are interpreted.

  Tier 1  system compiler                       download 0 MB
          Not found. Looked for: cc, clang, gcc, cl.exe
          Would give: 30-3000x on this host, no cross-compilation.

  Tier 2  tiny C compiler (vendored)            download ~2 MB
          Would give: 22-72x on this host, fast compiles, no
          cross-compilation, no vectorisation.

  Tier 3  Zig 0.15.2, this host's targets       download 63 MB
          Unpacks to 210 MB in .ringpp/vendor/
          Would give: 25-3000x, and cross-compilation to Windows,
          Linux x64/arm64 and macOS x64/arm64 from this machine.
          Includes a one-time ~45 s cache warm-up per target.

  Ring VM source 1.27.0 (all tiers)             download 1.0 MB

Multiples are measured on bench/toolchain; your kernels will differ.
Every tier produces byte-identical results -- only the speed changes.

  ringpp vendor install --tier 2
  ringpp vendor install --tier 3

Proceed with which? [1/2/3/N]
```

The warm-up line is not politeness. A cold Zig cache makes the *first*
kernel compile cost **41–55 seconds** while it builds `compiler_rt` and
the target libc; warm, the same compile is 220 ms. `ringpp vendor
install` must absorb that by compiling a throwaway kernel per configured
target, so a user's first `ringpp run` never sits through it. No
compile-and-cache design survives a 45-second first call.

Three properties of that screen matter more than its wording: it names
the tier you are **on**, it prices each step in **download** rather than
on-disk bytes, and it quantifies the gain in measured multiples instead
of adjectives. A user in a bank deciding whether to pull 63 MB through a
change-controlled network deserves all three.

---

## House rules carried over from `zin`

- **One command per file**, uniform `pub fn run(args, allocator) !u8`,
  one `switch` in the dispatcher.
- **Shared modules over local duplication** — one `eql`, one `wp`, one
  colour module. `zin`'s `cli_utils.zig` exists because 28 copies of
  `eql` did.
- **ASCII only in console output.** No emoji, no box-drawing beyond
  `+-|`.
- **Colour is semantic**, not decorative: dim for command names, yellow
  for "unavailable here", green for "always available", red only for
  errors.
- **Never swallow errors on file writes**; console output is
  fire-and-forget.
- **`grammar dump`** so the CLI's own surface is machine-readable and
  can be diffed between releases — the CLI gets the same treatment as
  the compatibility surface.

---

## What `ringpp` deliberately does not do

- **It is not required to run Ring++ code.** Annotated source runs under
  stock `ring.exe`. If `ringpp` ever becomes mandatory, the loyalty-to-
  Ring property is gone (DESIGN_TOOLCHAIN §0).
- **It does not replace `ring2exe`** or Softanza's delivery plane. It
  contributes artifacts to them.
- **It does not manage packages.** `ringpm` exists.
- **It does not format opinionatedly.** `ringpp fmt` wraps Ring's own
  `ringfmt` where possible rather than inventing a second style.
