# Grammar findings for `ysdragon/tree-sitter-ring`

> **SENT** — [ysdragon/tree-sitter-ring#2](https://github.com/ysdragon/tree-sitter-ring/issues/2),
> August 12, 2026. Filed as an issue, not a PR: no grammar fix attached,
> and that project has issues enabled.

Found by running `ringpp check` (which vendors this grammar) over 5,566
Softanza files and Ring 1.27's own corpus, then asking `ring <file> -norun`
to adjudicate every disagreement.

**Measured disagreement rate: ~0.16%** — 9 files out of 5,566. That is a
very good grammar; the note below is the residue.

## The finding, as filed

A **digit-leading identifier is rejected when the call appears as an
argument to another call**. Ring accepts all four of these; the grammar
rejects only the last:

| | grammar |
|---|---|
| `? 3Copies("x")` — statement level | accepts |
| `? 3Copies(:of = "x")` — named-argument form | accepts |
| `? Wrap(Copies(:of = "x"))` — nested, no leading digit | accepts |
| **`? Wrap(3Copies("x"))` — nested, leading digit** | **rejects** |

## How the reproducer was narrowed — worth recording

My first draft of this report claimed the rule was simply *"identifiers may
begin with a digit"*, with `? 3Copies("x")` as the reproducer. **It does not
reproduce** — both Ring and the grammar accept it. Filing that would have
sent the maintainer chasing a case that works.

The real file that failed was
`stzlib/base/test/string/112_repeatedntimes.ring` at 13:45, inside
`Then("...", 3Copies(:of = "♥"), "♥♥♥")`. Bisecting that line across five
variants produced the table above: the trigger is *digit-leading identifier
+ call + argument position*, and the `:of =` form is not involved at all.

**Check that a minimal reproducer actually reproduces before sending it.**

## The other direction

One file that Ring **rejects** and the grammar **accepts**
(`stzlib/core/temp/tempo.ring`) — consistent with the counter-guarded
keyword superset the README already documents. Not a problem for Ring++,
which keeps Ring's own scanner as the authority on validity and uses the
grammar only for structure and source spans.

## The thank-you, since it is true

The `typed_parameter` rule — keeping the type even though Ring's parser
discards it — is what makes `ringpp check` able to read type annotations at
all. The comment in `grammar.js` saying the type is *"kept here so the
structure is visible"* reached the same conclusion this project did
independently, and it is the reason the grammar was adopted rather than a
hand-written parser.
