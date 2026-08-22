# The VM contract — what Ring++ needs from Ring, and nothing more

*Ring++ builds on Ring's internals, and internals may change. This document
is the abstract interface between the two: the **complete, finite list** of
what Ring++ consumes, stated as observable behaviours rather than as
implementation details, and machine-checked by [`rpp/probe.ring`](../rpp/probe.ring)
on every load. If a future Ring changes one of these behaviours, the probe
names the row that moved — the user is told honestly, instead of finding out
through corruption.*

*The long-term intent (§4) is a contract both parties agree on: a small
surface Mahmoud blesses as observable-and-stable, in exchange for Ring++
promising to depend on nothing outside it. Anything not named here is his to
change freely, forever, without asking anyone.*

---

## 1. The consumed surface — every name, grouped

Ring++'s library half calls **exactly these registered functions** and no
others. This list is the dependency; the C code behind it is not.

| group | names | what Ring++ assumes |
|---|---|---|
| **pointers** | `varptr`, `getptr`, `setptr`, `nullptr` | `varptr(:name, "char *")` yields a pointer to the live bytes of the named string variable, resolved in the current scope then globals; folded name accepted as a string |
| **raw memory** | `memcpy`, `ptr2str`, `space` | `memcpy(dst, src, n)` copies n bytes through pointers; `ptr2str(p, off, n)` returns n bytes from `p+off` as a new string; `space(n)` allocates n writable bytes |
| **packing** | `int2bytes`, `bytes2int`, `double2bytes`, `bytes2double`, `float2bytes`, `bytes2float` | exact round-trip at native width and byte order |
| **list acceleration** | `ringvm_genarray` | builds an O(1) items array for a list; any structural mutation may free it (that fragility is *accepted*, and `RppIndexed` is designed around it) |
| **sub-states** | `ring_state_init`, `ring_state_runcode`, `ring_state_findvar`, `ring_state_setvar`, `ring_state_delete` | a genuinely isolated second interpreter; names folded to lower case by the caller (correct on every version — F-3) |
| **tokens** | `ring_state_stringtokens`, `ring_state_scannererror` | the scanner's own token stream, including type annotations verbatim |
| **error control** | `ringvm_hideerrormsg` | suppresses *runtime* error printing in a sub-state (not scanner errors — measured, example 07) |

## 2. The behavioural rows — checked at every load

Each row is a **claim about behaviour**, not about code. `rpp/probe.ring`
verifies all of them in a few microseconds when `ringpp.ring` loads.

| row | policy | the claim |
|---|---|---|
| `varptr-write-through` | **HARD** | a write through `varptr`'s pointer lands in the variable's own bytes |
| `varptr-address-stable` | **HARD** | the address does not move while the string is neither grown nor reassigned |
| `ptr2str-slice` | **HARD** | `ptr2str(p, off, n)` returns exactly the n bytes at offset |
| `pack-int32` | **HARD** | `bytes2int(int2bytes(x)) = x` |
| `pack-double` | **HARD** | `bytes2double(double2bytes(x)) = x` |
| `genarray` | **soft** | `ringvm_genarray` accelerates random access |
| `substate` | **soft** | a sub-state is isolated and survives errors |
| `memcpy-nul-source-fixed` | info | whether this Ring still kills the process on a zero-byte source (≤ 1.27 does — F-14; Ring++ routes around it either way) |
| `byte-order` | info | recorded, consumed by the packing helpers |

**Policies.** A failed **HARD** row makes the facility unavailable — using it
raises immediately with the row's name, because a wrong pointer is worse than
no pointer. A failed **soft** row degrades to a slower pure-Ring path and
`RppReport()` says so. **info** rows are recorded and change behaviour only
internally (e.g. which `memcpy` route `Poke` takes).

This is the upgrade story: Ring 1.28 or 1.35 arrives, the probe runs, and
either everything still holds — or the user is told *which claim* broke, in
words, before any pointer is handed out.

## 3. What Ring++ deliberately does NOT depend on

Stated so a future reader knows these are free to change without notice:

- **struct layouts** — `Item`, `List`, `String` internals; Ring++ never casts
  a Ring value to a C struct
- **the pool manager** — block sizes, thresholds, free-list behaviour
- **the cursor cache** — its existence is *exploited knowledge*
  (FINDINGS F-19 explains the cost model) but nothing breaks if it changes;
  the genarray row is soft
- **bytecode layout, instruction set, `ringvm_codelist` internals** — read
  only by diagnostics, never load-bearing
- **source line numbers, error message wording** — never matched
- **`ring_list_*` / `ring_string_*` C entry points** — Ring++ has no C half
  in the library; everything goes through registered functions

The one *semantic* dependency that cannot be probed cheaply: **strings cross
call boundaries by copy, lists by reference** (`RING_VM_STACK_PUSHCVAR`).
If that ever inverts, Ring++'s reason to exist changes with it — that is a
thesis-level event, not a compatibility break, and the examples' A/B numbers
would announce it loudly (FINDINGS F-23 records exactly such a case: a
patched VM made one idiom worthless, and the gate said so).

## 4. The proposal — a contract both parties could sign

*Drafted for the Ring Google Group. **Not sent** — the standing rule: Mansour
posts findings himself, after review.*

> Ring's internals are Mahmoud's to change, and Ring++ wants to keep it that
> way. The proposal is therefore deliberately small:
>
> **The ~20 registered functions in §1, with the 9 observable behaviours in
> §2, treated as a compatibility surface** — meaning only that a change to
> one of them is *mentioned in release notes*, not that it is forbidden.
> Nothing about implementations, layouts, or performance is asked for.
>
> In exchange, Ring++ commits to: no C patches, no fork, no dependence on
> anything outside the named surface, and a probe that verifies each release
> honestly instead of assuming.
>
> Most of this surface is documented API already; the contract mostly
> *names* what is currently implicit. If any row is one Mahmoud considers
> free to change silently, that row moves to soft/info in the probe and
> Ring++ carries the fallback — the point is to know which is which.

## 5. Why this is a schoolcase, not just plumbing

The probe embodies the pattern this project wants to teach: **build on
someone's internals only through claims you can check, degrade honestly when
a claim fails, and keep the list of claims small enough to read in one
sitting.** That is also how Ring itself treats C — a small, opinionated
surface over something vast — which is the design culture Ring++ is trying
to learn from, not merely use.
