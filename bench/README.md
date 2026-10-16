# The evidence

Every number in [`../docs/FINDINGS.md`](../docs/FINDINGS.md) comes from a
program here. Run them with Ring **1.27**:

```bash
D:\ring127\bin\ring.exe bench\07_by_value_tax.ring
```

All eleven programs in this folder exit 0.

| program | answers |
|---|---|
| `01_string_build.ring` | Does building a string through a buffer beat `+=`? (**No** — 28× worse at 8-byte chunks.) |
| `02_unit_costs.ring` | What does each primitive cost per call? Which are secretly expensive? (`varptr` 790 ns, `nullptr` 520 ns.) |
| `03_lists.ring` | `list(n)` vs append; `ringvm_genarray`'s ~95×; that one `+` destroys the array; the 6× 2D idiom. |
| `04_genarray_breakeven.ring` | Where `ringvm_genarray` **loses**, and by how much. The reads-per-mutation sweep. |
| `05_registered_blocks.ring` | Do many live block-allocated lists slow every large free? (**Not reproducible at the Ring level** — it is heap warm-up.) |
| `06_substates.ring` | `ring_state_*`: name folding, tokens, syntax check, error containment, cost vs `eval`. |
| `07_by_value_tax.ring` | The headline: 1 MB by value vs by handle. Lists cross by reference. |
| `08_string_ops_tax.ring` | Which core string ops pay the copy tax. Repeats 7× and reports **minima** — single runs swing 4×. |
| `09_inplace_patch.ring` | In-place patching (803 ms → 1 ms) and the 512-byte append crossover. |
| `10_pointer_reach.ring` | `varptr`/`getptr`/`setptr`/`ptr2str`/`memcpy` round trips, and the silent no-op. |
| `11_varptr_scope.ring` | What `varptr` can reach: attributes, globals, a caller's variable by computed name; address stability. |
| `12_typehints_channel.ring` | That `int func Sum(int x, int y)` runs on stock Ring, and that the annotations survive into `ring_state_stringtokens`. |
| `13_bytecode_channel.ring` | That Ring exposes its own bytecode, symbol table, and `.ringo` round trip — from Ring, with no extension. |
| `14_numeric_array.ring` | A packed numeric buffer is **2.2× slower** than a Ring list when read from interpreted Ring. It is a compiled-half data structure. |
| `15_memcpy_nul_source.ring` | **A crash reproducer.** `memcpy()` dies when the source string's first byte is NUL. Six arms; four are fatal by design — edit `nARM` and run one at a time. |
| `16_empty_catch_leak.ring` | An **empty** catch block leaks one VM stack slot per caught raise; ~1003 in a row is `Error (R4) Stack Overflow`. Five arms show what does and does not drain it. |
| `17_list_build_shape.ring` | **219×** — a list built with `list(n)` is block-allocated and reads randomly at array speed; one built by appending does not. Corrects F-9/F-12. |

## `headroom/`

The interpreted-vs-native ceiling, identical algorithms both sides.

```bash
D:\ring127\bin\ring.exe bench\headroom\kernels.ring
zig cc -O2 bench\headroom\kernels.c -o kernels.exe
.\kernels.exe
```

Measured: 64× (scalar loop), 96× (dot product), ~3000× (byte scan — the
C compiler vectorises it). These are the numbers the toolchain half is
built on; see [`../docs/DESIGN_TOOLCHAIN.md`](../docs/DESIGN_TOOLCHAIN.md) Â§1.

## `treesitter/`

Is [`tree-sitter-ring`](https://github.com/ysdragon/tree-sitter-ring)
useful to Ring++? Measured, not assumed: fidelity against Ring's own
978-file test suite, type-annotation extraction with line and column,
build cost, and the bounding rule that keeps it safe. See
[`treesitter/README.md`](treesitter/README.md).

## `safety/`

Four programs demonstrating the failure modes. **Two kill the process on
purpose** — run each in its own shell.

| program | expected |
|---|---|
| `s1_oob.ring` | exit **0**, returns 4096 bytes of adjacent heap from a 16-byte buffer, no error |
| `s2_overwrite.ring` | exit **1**, process dies, **no message at all** |
| `s3_dangling.ring` | exit **0**, silent garbage from a freed local |
| `s4_wild.ring` | exit **1**, process dies; `try/catch` does **not** catch it |

If any of these four changes behaviour on a future Ring, that is a
finding worth recording — it means the safety envelope moved.

## Reading these numbers

- `clock()` has **1 ms resolution** here. Anything under ~20 ms per
  repetition is a floor, not a value.
- Report **minima over repetitions**. Noise only ever adds time.
- Two significant figures. Every ratio in the docs is a range across
  runs, not a single measurement.
- One machine, one OS, one build: Windows 11, x64, Ring 1.27.0. The
  512-byte crossover in particular is an allocator and cache artefact
  and is expected to move on Linux, ARM, and WASM — that is what
  [`PHASE_PLAN.md`](../docs/PHASE_PLAN.md) P4 is for.
