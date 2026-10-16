# tree-sitter runtime, vendored

The tree-sitter C runtime (`include/` and `src/`, MIT), language ABI
version 15 per `include/tree_sitter/api.h`. The exact release it was
copied from was not recorded when it was vendored on 2026-08-23; the
hashes in `SHA256SUMS` fix what is here, which is what the gate needs.

Built by `build.zig` into `rnxc` with `-std=c11 -w -fno-sanitize=undefined`
and a POSIX level for non-Windows targets; see the comment there.
