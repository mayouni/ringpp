# Is `tree-sitter-ring` useful to Ring++?

**Yes — in one bounded role, and it is the missing piece for
`ringpp check`.** Evaluated August 11, 2026 against
[ysdragon/tree-sitter-ring](https://github.com/ysdragon/tree-sitter-ring)
(MIT, created 2026-03-31, last push 2026-08-06 — five days before this
evaluation).

## The gap it fills

Ring already hands Ring++ a great deal of its own front end
([`../13_bytecode_channel.ring`](../13_bytecode_channel.ring)), but there
is one thing it does not give:

| what Ring++ needs | Ring gives | good enough? |
|---|---|---|
| "is this valid Ring?" | `ring_state_scannererror` | **yes — authoritative** |
| "what does it compile to?" | `ringvm_codelist` | **yes — authoritative** |
| type annotations | `ring_state_stringtokens` | flat token stream, no structure |
| **a syntax tree with source spans** | — | **nothing.** Bytecode carries line numbers only; tokens carry no structure at all |

A linter that cannot say *line 720, column 21* is not a linter. That is
the hole, and tree-sitter fills exactly it.

## What was measured

Built with `zig cc -O2` against the tree-sitter runtime **already
vendored in Softanza** (`stzlib/engine/vendor/tree-sitter/runtime`, 0.7 MB):

| | |
|---|---|
| compile time (runtime + grammar + probe) | **4.4 s** |
| static binary, everything linked in | **2.68 MB** |
| parse speed | 42 KB in 19 ms; 14 KB in 2 ms |

2.68 MB links into the `ringpp` CLI binary, so **the user installs
nothing** — `ringpp check` stays a Tier 0 command.

### Type annotations come out with line *and* column

```
func Sum                       line 18
      TYPED  int        x                 (line 18, col 14)
      TYPED  int        y                 (line 18, col 21)
func Greet                     line 21
      TYPED  string     cName             (line 21, col 19)
```

The grammar exposes them as named fields —
`typed_parameter: seq(field("type", …), field("name", …))` — with a
comment in `grammar.js` that reaches the same conclusion this project
did independently: *"type is skipped by the Ring parser but kept here so
the structure is visible."* One tree-sitter query gets them:

```scheme
(typed_parameter type: (identifier) @type name: (identifier) @name)
```

### The leading return-type hint is recoverable

The README lists *"TypeHints-style declarations"* as unsupported, which
sounds fatal for `int func Sum(int x, int y)`. It is not. That form
parses cleanly, as:

```
(source_file
  (expression_statement (identifier))      <-- the "int"
  (function_definition name: … parameters: …))
```

— which is precisely what **Ring's own parser** does with it (the `int`
global evaluates and is discarded). So the return type is recoverable by
a query plus an adjacency rule: a bare `expression_statement` holding
one identifier, immediately preceding a `function_definition`, where the
identifier names a known type. **No grammar change needed.**

## Fidelity — the question that actually decides it

Swept with [`sweep.ps1`](sweep.ps1):

| corpus | files | size | clean | failures |
|---|---:|---:|---:|---:|
| **Ring 1.27's own test suite** | 978 | 21.0 MB | **967 (98.9%)** | 11 |
| Softanza `core/` | 33 | 182 KB | 28 | 5 |
| Softanza `base/system/` | 24 | 309 KB | **24 (100%)** | 0 |
| Ring++ `bench/` | 20 | 27 KB | **20 (100%)** | 0 |

Every single failure was then checked against Ring itself:

- **5** are `scripts/natural*` and `naturallib/` — the NaturalLib
  runtime DSL, documented as unsupported by design (a static grammar
  cannot follow syntax defined at runtime).
- **11** are files **Ring itself rejects**: `errormsg/call1`, `call3`,
  `missingexprinclassregion`, `test82`, `test114` (unterminated string),
  `ممتاز.ring`, and the five Softanza files.

So on this corpus the grammar's disagreement rate with Ring on *valid*
code is **zero**.

> **A correction worth recording.** I first reported four Softanza test
> files as "genuine disagreements", because my check for a Ring syntax
> error matched only `Error (C…)`. They are `Error (S2) : Unclosed
> comment` — a scanner class I had not matched. tree-sitter was right and
> my test was wrong.

### A free catch, from the tool being evaluated

Four Softanza test files —
`core/test/stkListTest.ring`, `stkPointerTest.ring`, `stkNumberTest.ring`,
`stkMemoryBufferPointerTest.ring` — contain **unclosed `/*` block
comments** (`/*----`, `/*===` used to disable a trailing section). Ring
refuses to run them: `Error (S2) : Unclosed comment`. They are dead test
files, and nothing was reporting it. That is the first real
`ringpp check` finding, produced by the candidate implementation before
a line of it was written.

## The rule that makes this safe

> **tree-sitter is a lens, not a judge.**

Ring++'s upgrade story rests on consuming *Ring's own* front end, so
adopting a second definition of Ring's syntax is exactly the risk the
design set out to avoid. The role must therefore be bounded:

| question | authority |
|---|---|
| Is this valid Ring? | `ring_state_scannererror` / `ring -norun` |
| What does it mean / compile to? | `ringvm_codelist`, `.ringo` |
| Where is it, and what shape is it? | **tree-sitter** |

The grammar is also, by its author's own account, *more permissive* than
Ring in places (counter-guarded keywords such as `ok`/`on`/`off` demote
in a superset of Ring's runtime-counter behaviour). A more permissive
parser can never be the authority on validity.

**Permanent gate**, in the house style: every file `ringpp check` parses
must get the same accept/reject verdict from `ring -norun`. A
disagreement is a bug in Ring++'s vendored grammar, never a diagnostic
shown to a user. That is the byte-exact-oracle discipline applied to a
new axis, and it is cheap — the sweep above runs in seconds.

## Reproducing

```powershell
zig cc -O2 -I <ts>/include -I <ts>/src -I <grammar>/src `
    <ts>/src/lib.c <grammar>/src/parser.c <grammar>/src/scanner.c tsprobe.c -o tsprobe.exe
```

```powershell
powershell -File sweep.ps1 -Root D:\ring127\language\tests -Label "Ring 1.27 tests"
```

[`tsprobe.c`](tsprobe.c) also takes `--sexp` to dump the tree and
`--quiet` to report only the summary line.

## Practical notes

- `src/parser.c` is **21.8 MB** of generated table — large in a repo, but
  it compiles in seconds and is regenerable from the 26 KB `grammar.js`.
  Vendor a pinned copy; never track master.
- The project has 2 stars and one maintainer. **Low bus factor** — which
  is an argument for vendoring, not for avoiding: MIT licence, and the
  grammar is regenerable from a file we can fork.
- `queries/locals.scm` ships scope information, which is most of the
  groundwork for the scope-aware rules in
  [DESIGN_TOOLCHAIN §5](../../docs/DESIGN_TOOLCHAIN.md).
