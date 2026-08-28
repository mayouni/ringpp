# Google Group draft — a latent crash in a shipped sample, found by static analysis

> **Status: DRAFTED, NOT SENT.** Mansour posts it, if and when he judges it
> ready. Same channel rule as every other item in `upstream/`.

---

Subject: **small find in samples/Algorithms/breath_first_search.ring — its error handler crashes when it finally runs**

Hello Mahmoud and all,

While testing a static-analysis rule over Ring's own samples, one real
defect surfaced, and it is a nice illustration of a Ring trap worth
knowing generally.

In `samples/Algorithms/breath_first_search.ring`, `delete_queue()` guards
against underflow like this:

    Func delete_queue()
        size = len(queue)
        if size = 0
            See "Queue Underflow"+nl
            exit(1)
        ok

`exit(1)` here is the C habit — "terminate the program with code 1". In
Ring, `exit` is the LOOP-BREAK command, and `exit 1` means "leave one
enclosing loop". There is no loop here, so the moment this branch runs it
raises:

    Error (R9) : Using exit command outside loops

Two things make it worth a note rather than a silent patch:

1. **It has always shipped, because Ring checks exit placement at
   runtime.** The sample runs fine on its normal path; only the underflow
   branch — the one written to handle failure — crashes, and with a
   different error than the author intended. Verified on 1.27: an `exit`
   outside a loop inside an untaken branch loads and runs silently.

2. **The intended behaviour is one word away:** `shutdown(1)` terminates
   the program with a status code, which is what the C reflex reaches for.

The general trap, for anyone coming from C: `exit` in Ring never
terminates the program and never crosses a function boundary — a function
whose body is a bare `exit` raises R9 even when its caller is inside a
loop (also verified on 1.27).

Found with `ringpp check`, which now flags exit/loop placement statically;
across Ring's 1,605 sample files this was the only occurrence, which says
good things about the samples.

Best,
Mansour

---

## Notes for the maintainer of this repo (not part of the post)

- Evidence chain: FINDINGS **F-45** (the five verified placement
  behaviours, including the function-boundary one) and the rule pair
  `rpp/exit-outside-loop` / `rpp/exit-bad-depth`.
- Deliberately framed as a *sample* fix plus a *general trap*, not as a
  criticism of the runtime check — Ring catching this at compile time
  would be a language change and is Mahmoud's call, not the post's ask.
- If he engages, the natural follow-up is the F-46 material: only
  functions are bare-callable, and the four look-callable shapes that
  raise R3.
