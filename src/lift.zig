//! RING'S `not`, AS RING READS IT (C-32, F-130).
//!
//! Ring binds `not` and `!` LOOSER than every comparison and arithmetic operator and TIGHTER than `and` and `or`: `not a = b` is
//! `not (a = b)`, `not a + b` is `not (a + b)`, `not a < b and c` is `(not (a < b)) and c` (measured on the oracle and the official 1.27,
//! bench/exec/not_precedence.ring). tree-sitter-ring binds them like a unary minus, tighter than every binary operator -- its table names
//! PREC.NOT = 4 and never uses it -- so `not a = b` arrives as `(not a) = b` and compiled to another program: a silent wrong answer.
//!
//! The tree cannot be edited, and the compiler reads the shape of a chain in some thirty places (the classes, the element classes, the
//! append idiom, the condition jumps), so the fix is made where the tree is made: a `not` that is the leftmost operand of a chain of
//! tighter binary operators gets parentheses round the chain, in the text the compiler is handed, and the text is parsed again. What the
//! compiler reads is then what Ring reads, in every place at once, and a file with no such `not` is untouched -- the same tree, the same
//! bytes. A `not` under parentheses is its own operand and is left alone; `and`/`or` end the chain; a `not` that is the RIGHT operand
//! of a tighter operator (`a = not b`) is Ring's error C28 and is not touched.
//!
//! The text the compiler holds is therefore not always the file's. Whoever needs the file's bytes -- the image stamps, a byte offset
//! printed for an applier -- takes them from the original (rnxc.zig, `Unit.origs`).

const std = @import("std");
const ts = @import("ts.zig");
const c = ts.c;

/// What the estate costs, for the census: the `not`s lifted, the files that held one, the nanoseconds spent looking.
pub var sites: u32 = 0;
pub var files: u32 = 0;
pub var ns: u64 = 0;
/// the part of `ns` spent parsing the rewritten text
pub var ns_reparse: u64 = 0;
/// RNXC_LIFT_TRACE=1: every site, as file:line and the chain it covers, on stderr (set by rnxc.zig)
pub var trace: bool = false;
var file_name: []const u8 = "";

pub const Lifted = struct { tree: ts.Tree, src: []const u8 };

const Edit = struct { pos: u32, close: bool };

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn sameNode(a: ts.Node, b: ts.Node) bool {
    return c.ts_node_eq(a.raw, b.raw);
}

/// `not x` and `!x`, by the operator token the compiler tests (compile.zig, `opText`).
fn isNot(n: ts.Node) bool {
    if (!eq(n.kind(), "unary_expression")) return false;
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        const ch = n.child(i);
        if (ch.isNamed()) continue;
        const k = ch.kind();
        return eq(k, "not") or eq(k, "!");
    }
    return false;
}

/// A node whose operator binds tighter than `not`: every binary operator but `and`/`or`, and the `=` the grammar calls an assignment
/// where a value is wanted (an equality, there). The compound assignments are statements and are not a chain.
fn isChain(n: ts.Node) bool {
    const k = n.kind();
    const binary = eq(k, "binary_expression");
    if (!binary and !eq(k, "assignment_expression")) return false;
    if (n.namedChildCount() < 2) return false;
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        const ch = n.child(i);
        if (ch.isNamed()) continue;
        const op = ch.kind();
        if (binary) return !(eq(op, "and") or eq(op, "or") or eq(op, "&&") or eq(op, "||"));
        return eq(op, "=");
    }
    return false;
}

/// `and`, `or`, `&&`, `||`: the operators that end a chain
fn isLogic(n: ts.Node) bool {
    if (!eq(n.kind(), "binary_expression")) return false;
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        const ch = n.child(i);
        if (ch.isNamed()) continue;
        const op = ch.kind();
        return eq(op, "and") or eq(op, "or") or eq(op, "&&") or eq(op, "||");
    }
    return false;
}

/// The first named child that is not a comment (a comment can stand among an expression's operands).
fn firstOperand(n: ts.Node) ?ts.Node {
    var i: u32 = 0;
    const cnt = n.namedChildCount();
    while (i < cnt and i < 8) : (i += 1) {
        const ch = n.namedChild(i);
        if (!eq(ch.kind(), "comment")) return ch;
    }
    return null;
}

/// The last byte of what a chain's last operand really ends in: a trailing comment may be a child of the expression and must stay outside
/// the parenthesis it would swallow.
fn lastByte(n_in: ts.Node) u32 {
    var n = n_in;
    while (eq(n.kind(), "binary_expression") or eq(n.kind(), "assignment_expression") or eq(n.kind(), "unary_expression")) {
        var i = n.namedChildCount();
        var last: ?ts.Node = null;
        while (i > 0) {
            i -= 1;
            const ch = n.namedChild(i);
            if (!eq(ch.kind(), "comment")) {
                last = ch;
                break;
            }
        }
        n = last orelse break;
    }
    return n.endByte();
}

/// Is there an `=` in the chain that Ring's parser may read as an ASSIGNMENT?
fn hasEquals(n: ts.Node, depth: u32) bool {
    if (depth > 64) return true;
    const k = n.kind();
    if (eq(k, "assignment_expression")) return true;
    if (!eq(k, "binary_expression")) return false;
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        const ch = n.child(i);
        if (!ch.isNamed()) {
            if (eq(ch.kind(), "=")) return true;
        } else if (hasEquals(ch, depth + 1)) return true;
    }
    return false;
}

/// Does only blank stand before `n` on its line?
fn startsLine(n: ts.Node) bool {
    var i = n.startByte();
    while (i > 0) {
        i -= 1;
        const ch = n.src[i];
        if (ch == '\n') return true;
        if (ch != ' ' and ch != '\t' and ch != '\r') return false;
    }
    return true;
}

/// Where the chain `t` ends. The grammar reads a statement-initial `x = y or z` as the ASSIGNMENT x = (y or z), its right side taking the `or`
/// and everything after; Ring reads `(x = y) or z`. So when the chain is such an assignment, it ends where the first `and`/`or` on the left
/// spine of its right side begins -- what stands tighter than the `or` is the `=`'s right operand, `= c` and `+ d` included.
fn chainEnd(t: ts.Node) u32 {
    if (!eq(t.kind(), "assignment_expression")) return lastByte(t);
    var i = t.namedChildCount();
    var r: ?ts.Node = null;
    while (i > 0) {
        i -= 1;
        const ch = t.namedChild(i);
        if (!eq(ch.kind(), "comment")) {
            r = ch;
            break;
        }
    }
    var n = r orelse return lastByte(t);
    while (isLogic(n)) n = firstOperand(n) orelse return lastByte(t);
    return lastByte(n);
}

/// Every `not` that leads a chain: the parentheses go round the operand of the `not` and the chain it leads.
fn findSites(alloc: std.mem.Allocator, root: ts.Node, out: *std.ArrayListUnmanaged(Edit)) !void {
    var cur = c.ts_tree_cursor_new(root.raw);
    defer c.ts_tree_cursor_delete(&cur);
    // the ancestors of the node under the cursor, the root first
    var path = std.ArrayListUnmanaged(ts.Node){};
    defer path.deinit(alloc);
    while (true) {
        const raw = c.ts_tree_cursor_current_node(&cur);
        const node = ts.Node{ .raw = raw, .src = root.src };
        if (node.isNamed() and path.items.len > 0 and isNot(node) and !node.hasError()) try site(alloc, node, path.items, out);
        if (c.ts_tree_cursor_goto_first_child(&cur)) {
            try path.append(alloc, node);
            continue;
        }
        while (!c.ts_tree_cursor_goto_next_sibling(&cur)) {
            if (!c.ts_tree_cursor_goto_parent(&cur)) return;
            _ = path.pop();
        }
    }
}

fn site(alloc: std.mem.Allocator, u: ts.Node, path: []const ts.Node, out: *std.ArrayListUnmanaged(Edit)) !void {
    // the chain starts where this `not` is its parent's FIRST operand...
    var top = path.len - 1;
    if (!isChain(path[top])) return;
    const first = firstOperand(path[top]) orelse return;
    if (!sameNode(first, u)) return;
    // ...and goes up as long as each node is the first operand of a chain node: that is where Ring's `not` ends
    while (top > 0) {
        const g = path[top - 1];
        if (!isChain(g)) break;
        const f = firstOperand(g) orelse break;
        if (!sameNode(f, path[top])) break;
        top -= 1;
    }
    const t = path[top];
    if (t.hasError()) return;
    // A STATEMENT that begins its line is the one place Ring's parser still has its assignment flag up (lAssignmentFlag, expr.c): there an
    // identifier followed by `=` is an ASSIGNMENT, whatever stands before it -- `not a = b` sets a to b, `not a = b and c` sets it to
    // `b and c`, `not Id(a) = b` is R34 (measured on the oracle and the official 1.27). Every other place that holds an expression (the
    // arguments, the conditions, `return`, `?`, the right of an assignment) clears it, and `=` is the comparison. rnxc refuses the
    // statement, loudly, and a lift would turn that refusal into a quiet comparison: so it is left as it is. A `return` the grammar cut
    // from its value does not begin its line.
    if (top > 0 and eq(path[top - 1].kind(), "expression_statement") and startsLine(t) and hasEquals(t, 0)) return;
    const x = firstOperand(u) orelse return;
    const open = x.startByte();
    const close = chainEnd(t);
    if (close <= open) return;
    if (trace) {
        const text = t.src[t.startByte()..close];
        std.debug.print("lift: {s}:{d}: {s}\n", .{ file_name, t.start().row + 1, if (text.len > 100) text[0..100] else text });
    }
    try out.append(alloc, .{ .pos = open, .close = false });
    try out.append(alloc, .{ .pos = close, .close = true });
}

fn order(_: void, a: Edit, b: Edit) bool {
    if (a.pos != b.pos) return a.pos < b.pos;
    return a.close and !b.close; // a parenthesis closes before the next one opens
}

/// `tree` is the parse of `src`. Returns the tree the compiler should read and the text its offsets index: the same two when no `not`
/// leads a chain, and the parse of the rewritten text when one does. The old tree is freed when it is replaced.
pub fn apply(alloc: std.mem.Allocator, parser: ts.Parser, tree_in: ts.Tree, src_in: []const u8, name: []const u8) Lifted {
    file_name = name;
    var t0 = std.time.Timer.start() catch return .{ .tree = tree_in, .src = src_in };
    defer ns += t0.read();
    var tree = tree_in;
    var src = src_in;
    // `not` and `!` are the only words that matter, and most files hold neither
    if (std.ascii.indexOfIgnoreCase(src, "not") == null and std.mem.indexOfScalar(u8, src, '!') == null)
        return .{ .tree = tree, .src = src };

    var lifted_here: u32 = 0;
    // a `not not` chain gains one level of parentheses a pass; Ring refuses that shape (C28), so the bound only has to be finite
    var pass: u32 = 0;
    while (pass < 4) : (pass += 1) {
        var edits = std.ArrayListUnmanaged(Edit){};
        defer edits.deinit(alloc);
        findSites(alloc, tree.root(), &edits) catch break;
        if (edits.items.len == 0) break;
        std.mem.sort(Edit, edits.items, {}, order);
        const text = alloc.alloc(u8, src.len + edits.items.len) catch break;
        var w: usize = 0;
        var r: usize = 0;
        for (edits.items) |e| {
            const n = e.pos - r;
            @memcpy(text[w .. w + n], src[r .. r + n]);
            w += n;
            r += n;
            text[w] = if (e.close) ')' else '(';
            w += 1;
        }
        @memcpy(text[w .. w + (src.len - r)], src[r..]);
        var tr = std.time.Timer.start() catch break;
        const again = parser.parse(text) orelse break;
        ns_reparse += tr.read();
        // a rewrite that breaks a file that parsed is no fix: keep the grammar's reading, and say nothing worse than before
        if (again.root().hasError() and !tree.root().hasError()) {
            again.deinit();
            break;
        }
        tree.deinit();
        tree = again;
        src = text;
        lifted_here += @intCast(edits.items.len / 2);
    }
    if (lifted_here > 0) {
        sites += lifted_here;
        files += 1;
    }
    return .{ .tree = tree, .src = src };
}
