# P6 — the prompt handed to the `stzlib` session

*Written 2026-08-25, alongside [P6-SOFTANZA.md](P6-SOFTANZA.md), which is the
finding it refers to. Kept here because a handoff you cannot re-read is a
handoff you cannot check afterwards — if the session comes back with something
unexpected, the first question is whether it was asked for.*

**It authorises no edit.** Item A is investigation and ends in `STOP`; item B
is a benchmark. The one decision in reach — whether `stkPointer` loses five
public methods — is the maintainer's, and the prompt says so.

Copy from inside the fence.

```
Read D:\GitHub\ringpp\docs\P6-SOFTANZA.md in full before doing anything. It is
a finding and a proposal from the Ring++ session, dated 2026-08-25. Nothing in
stzlib has been changed by it.

Two independent work items, in either order. Item A needs no measurement — the
finding behind it is already verified twice. Item B is a measurement whose only
job is to tell us whether a section of that document is true.

--- A. stkPointer: report, then stop ---

libraries/stzlib/core/system/stkPointer.ring:720, InitializeLowLevelAccess()
calls varptr(:cBufferData) where the local is named _cBufferData_. That raises
Error (R6) into the catch directly beneath it, which sets @pLowLevelPtr = "".
The feature has never once initialised. Confirm this yourself — do not take it
on trust — then establish two things I do not know:

  1. Does anything in stzlib actually call GetRawPointer, GetMemoryAddress,
     GetViewAddress, ComparePointer or IsNullPointer? Search the whole library
     including tests. Report call sites, not a yes/no.

  2. Does stkPointerTest.ring (247 lines) pass right now, unchanged? Run it and
     paste the real output.

Then write up which of the three options in §2 of the document you recommend
and why, and STOP. Do not implement. Option 3 removes five public methods and
that is Mansour's call, not yours.

Do NOT "fix the typo". Read §2 first: correcting :cBufferData to :_cBufferData_
turns a dead feature into a memory-corruption feature, because Content()
returns a copy that dies at return while its address stays cached on the
object. That is the F-22 failure — no raise, no message, the process vanishes
once the allocator reuses the block.

--- A2. stkBuffer.Write: repair one guard (this one you DO implement) ---

libraries/stzlib/core/system/stkBuffer.ring:144 has, character for character,
the guard Ring++ shipped until 2026-08-25:

    if _cData_[1] = @cNulByte or (_nLenData_ = 4 and _cData_ = "NULL")

It has the same hole. Ring's memcpy asks strcmp whether the source is a null
pointer, so it reads the C view: any string whose bytes begin "NULL" followed
by a zero IS "NULL" to strcmp, whatever its Ring length. Comparing the Ring
value against "NULL" only ever catches a 4-byte string.

Reproduce it first, in stzlib, before changing anything: write
"NULL" + char(0) + something into a buffer of 512 bytes or more, at an offset
where the write lands inside the existing bytes so the in-place path is taken.
The process should die with no message and no line number. If it does not,
say so and stop — the trigger may be narrower than predicted and I want to
know that rather than have the guard widened on my say-so.

Then port the fix from ringpp/rpp/core.ring's Poke: test the bytes, not the
value, in one expression. Ring's and/or short-circuit (FINDINGS F-32), so the
fifth byte is safe to name after the length test. Measured cost in Ring++:
+0.075 us per write, about 3.7%, which is one string index.

Gate: the reproduction above survives, and stkBufferTest.ring still passes.

--- B. Measure the Ring-to-Zig bridge ---

Gate 1 of the document. The claim is that a string argument to a registered
extension function is copied onto the VM stack before the Zig side starts,
because that copy is RING_VM_STACK_PUSHCVAR and applies to builtins too
(ringpp FINDINGS F-5). This is predicted from a measurement taken on Ring
functions, NOT on extension functions. It may be wrong.

Write an A/B against one existing engine bridge function that takes bulk bytes
— libraries/stzlib/engine/stk_string.ring and its Zig side are the obvious
place. Compare passing a large Ring string against passing a pointer and a
length. Both paths must return identical results, asserted before any timing is
printed. Report minima over repetitions, never a single run, and state the
payload size at which the two cross over.

If the copy does not reproduce, say so plainly. The document says to strike
that section rather than soften it, and I mean it.

--- Constraints ---

- Change no code in item A. Item A2 is the one repair authorised here, and only
  after you have reproduced the crash. Item B is a benchmark; it does not
  modify stkString or the engine.
- Do not REWRITE stkBuffer.Write onto RppBuffer. §1 explains why: it already
  carries the in-place path and reached every one of Ring++'s numbers
  independently. A2 repairs one guard inside it; that is the whole mandate.
- Ring 1.27 at D:\ring127\bin\ring.exe.
- Never background a build or a scan, and cap any native build at -j2. This
  machine has 2 GB of page file and has frozen three times under load.
- Stage by explicit path. Report what you ran and what it printed, not a
  summary of what you believe happened.

Report back with: the call sites from A1, the real test output from A2, your
recommendation for A, and the numbers from B — including the crossover, and
including the case where Ring++ loses, if it does.
```
