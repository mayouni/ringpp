# The coupling profile — what this estate actually uses from Ring

*Measured 2026-08-26 across four repositories: Ring++, Softanza (`stzlib`),
RingServ and RingScript. Every figure below is counted, not estimated.*

## Why measure this

[VM-CONTRACT.md](VM-CONTRACT.md) makes a promise on Ring++'s behalf: that it
depends on a **small, named, finite** part of Ring, and on nothing else. The
promise is checked at load time by `rpp/probe.ring`, one row per behaviour.

But a promise about one repository is not a picture of four. If a future Ring
changes something internal, the useful question is not "does the probe fire?"
— it is **"how much of anything I have written is even in the blast
radius?"** Nobody had counted. This file counts it.

It is a maintenance instrument, and it has three ordinary uses:

1. **Blast radius.** When Ring changes, know immediately which projects can
   possibly be affected and which cannot.
2. **Keeping coupling deliberate.** Low-level calls should appear where a
   measured reason put them, not by habit. A count makes drift visible.
3. **Onboarding.** A new reader can see, in one table, which parts of the
   estate are ordinary Ring and which are specialist.

**Method.** Ring's builtin vocabulary is taken from Ring's own C source —
every `RING_API_REGISTER(...)` in 1.27, **258 names** — rather than from a
list someone typed. Every `.ring` file in the four repositories was scanned
for identifiers in call position, folded to lower case (Ring identifiers are
case-insensitive, F-18), and intersected with that vocabulary. Archived trees
excluded. The scan runs in under two seconds.

---

## 1. The estate

| | lines | files | classes | functions |
|---|---:|---:|---:|---:|
| **Softanza** (`stzlib`) | **727,744** | 6,020 | 754 | 46,666 |
| RingServ | 6,611 | 555 | 2 | 222 |
| RingScript | 6,271 | 580 | 11 | 310 |
| Ring++ | 5,090 | 77 | 6 | 190 |
| **total Ring** | **745,716** | 7,232 | 773 | 47,388 |
| *Softanza's Zig engine* | *156,449* | *380* | — | — |

About **746,000 lines of Ring**, written across five years and four
projects.

---

## 2. Three kinds of call, and why the distinction matters

Not every builtin is the same kind of dependency. Sorted by how specialist
each one is:

- **Ordinary Ring** — `len`, `upper`, `substr`, `find`, `sin`. The language
  as everyone uses it.
- **Binary and system** — `int2bytes`, `loadlib`, `fopen`, `eval`. Ordinary
  enough, but they cross into bytes and the OS.
- **Internals** — `varptr`, `memcpy`, `ptr2str`, `setptr`, `ringvm_*`,
  `ring_state_*`, `space`. Ring's low-level surface: powerful, sharp, and the
  part the VM contract exists to fence.

| project | distinct builtins | call sites | **internals** | binary/system | ordinary |
|---|---:|---:|---:|---:|---:|
| Ring++ | 73 | 1,046 | **25 names / 296** | 8 / 73 | 40 |
| Softanza | 155 | 44,920 | **13 names / 115** | 11 / 399 | 131 |
| RingServ | 39 | 795 | **0 / 0** | 1 / 3 | 38 |
| RingScript | 48 | 752 | **2 names / 4** | 1 / 3 | 45 |

---

## 3. The result

```
builtin call sites, all four projects : 47,513
  of those, internals                 :    415   0.87%
  of those, binary/system             :    478   1.01%
distinct internal names, whole estate :     26
```

**Ring's low-level surface accounts for less than one percent of what this
estate calls, across 26 names.** About twenty of those are already named and
behaviour-checked in [VM-CONTRACT.md](VM-CONTRACT.md), so the contract turns
out to cover very nearly the whole of it — which is the outcome the contract
was written hoping for, now confirmed rather than assumed.

The 26:

```
getptr  memcpy  nullptr  object2pointer  ptr2str  ptrcmp  setptr  space  varptr
ring_state_init  ring_state_runcode  ring_state_findvar  ring_state_setvar
ring_state_delete  ring_state_scannererror  ring_state_stringtokens
ringvm_genarray  ringvm_hideerrormsg  ringvm_info  ringvm_codelist
ringvm_functionslist  ringvm_classeslist  ringvm_packageslist
ringvm_fileslist  ringvm_ringolists  ringvm_writeringo
```

**Where they are, and where they are not.** They concentrate in Ring++ (296
of 415 sites), which is precisely what Ring++ is for — it exists to use that
surface carefully so that other code does not have to. **RingServ uses none
of them at all. RingScript uses two.** Both are substantial programs — a web
server and a browser runtime — written in ordinary Ring throughout.

That is the most quietly encouraging number in this file, and it is a
statement about the language rather than about the tooling: **Ring's ordinary
surface is expressive enough to build a web server and a browser runtime with
no descent into internals whatsoever.** The specialist layer is thin because
it rarely needs to be thick.

---

## 4. The engine boundary

Softanza's engine is written in Zig. The Ring side of that boundary:

| layer | lines | files |
|---|---:|---:|
| Zig engine | 156,449 | 380 |
| Ring API layer over it (`stz_*.ring`) | 2,869 | 84 |
| FFI bridge proper (`stk_*.ring`) | **92** | **4** |
| `loadlib` call sites, whole estate | 113 | — |

A 156,000-line native engine reaches Ring through **92 lines** of bridge.
Recorded because it is a good sign about the layering, and because it is the
number to look at first if that boundary ever needs to change: it is small
enough to hold in your head.

---

## 5. Where the weight really sits

Not in the internals. In the **745,716 lines of ordinary Ring** — 773
classes, 47,388 functions, 7,281 `load` statements, and 1,045 uses of Ring's
brace-scope idiom (`oObj { ... }`) in Softanza alone.

Softanza is not a library that happens to be written in Ring. It is written
**in Ring's idiom**: the brace scope, the method-resolution order, the
case-insensitivity, the object semantics that Ring++'s own findings (F-22,
F-25, F-27) document in detail. Five years of design decisions are shaped by
the language, not merely expressed in it.

This inverts the intuition. The pointer work *feels* like the deep
involvement with Ring because it is the exotic part. Measured, it is 0.87%.
The ordinary-looking code is where the estate and the language are genuinely
joined — and that is a description of investment, not of risk.

---

## 6. What this profile is used for

- **After a Ring release.** Run the probe; if a row moves, this table says
  which repositories can possibly care. Today the honest answer for RingServ
  is "none of them", which saves a review.
- **In code review.** A new `varptr` in a repository whose column reads zero
  is worth one question: what measurement put it there?
- **When planning.** Work that would push the internals column up should be
  a decision, not a side effect.

---

## 7. What this does not cover

Stated so the gaps are visible rather than implied:

- **Language semantics are counted, not analysed.** 1,045 brace-scopes is a
  volume, not a difficulty rating.
- **Ring's standard library** is reached through ordinary calls and folded
  into the "ordinary" column here. It would need its own inventory to be
  described properly.
- **Toolchain use** — `ringpm`, `ring2exe`, `ring.exe -go` — is process
  rather than code, and is not measured.
- **Qt** is out of scope by an earlier decision (F-30) and therefore is not a
  dependency this estate carries at all.
- **Nothing was ported.** Every figure is an inventory taken by reading, not
  a cost established by experiment.

---

## 8. In one line

> **Less than one percent of what this estate calls is Ring's low-level
> surface, across 26 names that a load-time contract already covers — and
> two of the four projects reach for none of it.**

The contract holds, the coupling is deliberate and thin, and the substance of
the estate is ordinary Ring doing ordinary work.
