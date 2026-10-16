# Fixture for rpp/undefined-function (F-46). Self-contained ON PURPOSE:
# the rule only speaks when the whole definition universe is visible, so
# this file loads nothing, evals nothing, and parses clean.
#
# Every defect below is deliberate. Do not "fix" this file.

? "start"

# One-letter typo of the function defined below: guaranteed R3, and with
# case-insensitive identifiers (F-18) no eye catches it in review.
ProccessOrder("A-1001")

# NOT reported, and each silence is deliberate:

# helper() IS a real R3 — Ring silently made it a method of Audit (F-21) —
# but the rule stays quiet: its suppression set holds every name defined in
# ANY form, methods included, because a bare call to a sibling file's
# method-wrapper pattern was 4,429 false positives in Softanza. Coverage
# deliberately traded for certainty; recorded in F-46.
if 1 = 2
    helper()
ok
oA = new Audit           # class name via new
oA { Log("x") }          # brace block: resolves against oA at runtime
ProcessOrder("A-1002")   # the correctly spelled call

func ProcessOrder cId
    ? "processing " + cId

class Audit
    func Log cMsg
        ? cMsg

func helper
    ? "unreachable as a function — I belong to Audit now (F-21)"
