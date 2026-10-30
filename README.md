<p align="center"><img src="ringpp-logo.jpg" alt="Ring++" width="160"></p>

# Ring++

**The bridge to Haro.** Ring++ is a register VM and a compiler from Ring source to its bytecode, in one 5 MB Zig binary.
It keeps the code that already exists running -- the 300,000 lines of [Softanza](https://github.com/mayouni/stzlib), written in
the Ring language, and the applications built on them -- with no Ring underneath, on Windows and Linux, while that code moves to
**Haro**, the language that comes next. It is also the test bed where each phase of that migration is measured. Softanza's main
branch is written for Ring++ and ships with it, and Ring 1.27 stays here only as the reference every answer is measured against.

| | measured 2026-10-17 |
|---|---|
| Softanza's checks that pass on Ring and pass on Ring++ | **12,924 of 13,008** (Windows), **12,170 of 12,255** (Linux) -- [the rest, named](https://mayouni.github.io/ringpp/how.html#parity) |
| Softanza's main branch, compiled whole (2026-10-29) | **136,346** statements in 697 files, every one compiled |
| Ring programs compared with Ring, line by line | **5,112** |
| faster than Ring 1.27 on the same programs | **4x to 2,030x** ([the table](https://mayouni.github.io/ringpp/issues.html#speed)) |
| what it needs | one binary: no Ring, no C compiler |

**[Why Ring++ left Ring](https://mayouni.github.io/ringpp/why.html)** -- the technical and the governance reasons, with the
record behind each. **[Ring's issues, solved](https://mayouni.github.io/ringpp/issues.html)** -- every issue run on Ring 1.27
and on Ring++, side by side. **[Start here](https://mayouni.github.io/ringpp/start.html)** --
the package and the first program.

## Build it

With Zig 0.15.2 and nothing else:

```
zig build -Doptimize=ReleaseFast -j2 -Dmi=true -Drc=true -Dtyped=true -Dcow=true
zig-out/bin/rnxc program.ring
```

`python bench/gate.py` is the gate every change passes: the vendored trees' hashes, A/B against the oracle, the Softanza census,
166 exec probes in two build modes, the checker, the native interface, the formatter and the graph.

## The tree

```
src/        the VM (main.zig), the compiler (compile.zig), the CLI (rnxc.zig), the checker, the native interface
bench/      every measurement and every gate: probes in bench/exec, the clocks (why432.py), the gate (gate.py)
vendor/     Ring 1.27's VM and standard library (the ORACLE, never shipped), tree-sitter and its Ring grammar, mimalloc
docs/       FINDINGS.md (what Ring's VM does, measured), CORRECTIONS.md (every place Ring++ differs, decided)
site/       the website
```

## Credit

Ring is the work of Mahmoud Fayed, under the MIT licence; its 1.27 VM and standard library are vendored here unchanged, as
the oracle Ring++ is measured against. The Ring grammar Ring++ parses with is Youssef Saeed's. mimalloc is Microsoft's.

The library era of Ring++ (August 2026: a library and a CLI that ran inside Ring) is archived, read-only, at
[mayouni/ringpp-old](https://github.com/mayouni/ringpp-old).

Ring++ &copy; 2026 Mansour Ayouni, under the MIT licence -- a [Softanza](https://mayouni.github.io/stzsite/) project,
towards Haro.
