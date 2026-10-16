# Open defects in the vendored tree-sitter-ring grammar (v1.1.1).
# Ring accepts every file in this directory. `ringpp check` does not
# accept the xfail_* ones -- that is the defect being tracked.
#
# xfail_* : the grammar REJECTS this today. If one starts parsing, the
#           gate fails on purpose: upstream fixed it, update the notes.
# ok_*    : near neighbours that MUST keep parsing, so a future fix
#           cannot be scored without checking what it cost.
# See upstream	ree-sitter-ring-notes.md.
#
# U+212A KELVIN SIGN, inside a string. Folds to 'k'. Same defect as
# the long s; these two are the only non-ASCII codepoints in Unicode
# that simple-case-fold to an ASCII letter.

? "K"
