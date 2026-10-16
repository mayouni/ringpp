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
# Control: U+017E, the codepoint immediately BELOW the long s.

? "ž"
