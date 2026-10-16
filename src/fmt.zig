//! `rnxc fmt <file.ring>` -- the canonical text of a Ring file, and what the code-graph memo (haro/CODEGRAPH.md) calls the printer of a face.
//!
//!     text --parser--> concrete tree --abstract--> program graph (L1) --print--> canonical text
//!
//! The graph keeps what a program SAYS and drops how it is laid out: every identifier, number, string and comment as written, every
//! parenthesis the author wrote, the order of everything -- and none of the layout, the `;` and `,` between statements, or the grammar's
//! alternative spellings of one construct (func/def/function, ok/end/endif, `?`, keyword case, `!` for `not`). The printer gives each
//! construct ONE spelling, a tab a level and a statement a line, so `fmt` is idempotent and the two programs compile alike.
//!
//! THIS IS A PORT. The reference is haro/spike/v18/l1.py (rung 18 of the Haro spike) and its fixtures; `bench/fmt.py` judges this file
//! against it, program by program, and then judges the canonical text against the source it came from. Where the reference is
//! right because Ring says so -- `end` and `}` after a function close nothing, a `return` that ends its line is bare, the parser cuts a
//! statement at a `+` where Ring does not -- the same rules are here, with the comment that says where they were measured. The reference
//! reads the parse through the lossless export of src/dumpjson.zig; so does this, by reading the tree itself.
//!
//! LINE ENDINGS. The code it prints ends its lines with LF; the text of a string or a comment is kept byte for byte, so a CRLF file comes
//! back with LF between its statements and whatever it had inside a literal or a block comment. A comment on a line of a CRLF file loses the
//! carriage return the grammar counts as part of it.
//!
//! WHAT IT REFUSES. A file the parser reports an error in (a formatter that guessed would change programs), and a shape the graph has
//! no node for -- both are named, never papered over. `fmt` prints the whole file or nothing.
const std = @import("std");
const ts = @import("ts.zig");

const Alloc = std.mem.Allocator;
pub const Err = error{ Shape, Unsupported, Unprintable, TooDeep } || Alloc.Error;

/// What was wrong, when an `Err` came back: a sentence for the person who ran it.
pub var why: []const u8 = "";

fn tooDeep() error{TooDeep} {
    why = "nested deeper than 60,000 levels";
    return error.TooDeep;
}

/// Recursion depth the tree, the abstraction and the printer all accept (a chain of 1,500 `+` is 1,500 deep). The work runs on a thread with
/// a stack made for it, so this is a cap on a pathological file, not a guess at the stack.
const max_depth: u32 = 60_000;

// ---- the concrete tree ------------------------------------------------------------------------------------------------------------

const CN = struct {
    kind: []const u8,
    start: u32,
    end: u32,
    kids: []*CN,
    text: ?[]const u8, // a leaf's text; an interior node has none
};

fn buildTree(a: Alloc, n: ts.Node, depth: u32) Err!*CN {
    if (depth > max_depth) return tooDeep();
    const cn = try a.create(CN);
    const cc = n.childCount();
    cn.* = .{ .kind = n.kind(), .start = n.startByte(), .end = n.endByte(), .kids = &.{}, .text = if (cc == 0) n.text() else null };
    if (cc == 0) return cn;
    const kids = try a.alloc(*CN, cc);
    var cur = ts.c.ts_tree_cursor_new(n.raw);
    defer ts.c.ts_tree_cursor_delete(&cur);
    if (!ts.c.ts_tree_cursor_goto_first_child(&cur)) return error.Shape;
    var i: usize = 0;
    while (i < cc) {
        const child = ts.Node{ .raw = ts.c.ts_tree_cursor_current_node(&cur), .src = n.src };
        kids[i] = try buildTree(a, child, depth + 1);
        i += 1;
        if (!ts.c.ts_tree_cursor_goto_next_sibling(&cur)) break;
    }
    cn.kids = kids[0..i];
    return cn;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn textIs(t: ?[]const u8, s: []const u8) bool {
    return if (t) |x| std.mem.eql(u8, x, s) else false;
}

fn lowerIs(t: ?[]const u8, word: []const u8) bool {
    return if (t) |x| std.ascii.eqlIgnoreCase(x, word) else false;
}

fn oneOf(kind: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |n| {
        if (std.mem.eql(u8, kind, n)) return true;
    }
    return false;
}

// ---- the graph --------------------------------------------------------------------------------------------------------------------

const K = enum {
    file, package, class, private, func, param,
    expr, ret, say, see, give,
    if_, elif, while_, for_, dowhile, switch_, case, try_, catch_,
    load, import, exit, loop, bye, scanner, comment,
    assign, bin, un, post, call, callkw, member, index, brace, new, lambda, paren, list, pair,
    id, num, str, sym, self_, super_, bool_, null_,
};

const List = std.ArrayListUnmanaged(*G);

/// One node of the graph. A field the reference leaves out when it holds its default is null here, or false, or an empty list --
/// except where "present but empty" and "absent" differ in what is printed (`else`, `other`, `finally`, the parentheses of a
/// `new`, the braces of a `call {}`), and there a list that was never made is the absent one.
const G = struct {
    k: K,
    pos: u32 = 0, // where the grammar had it: the graph puts a class beside the one it was nested in, in source order
    text: ?[]const u8 = null, // id num str sym comment scanner
    name: ?[]const u8 = null, // func class param; the variable of a `for`; the binding of a `catch`
    ty: ?[]const u8 = null, // a param's type
    op: ?[]const u8 = null, // an operator; the mode of a `load`
    qname: ?[]const []const u8 = null, // the dotted name of a package, an import, a `new`
    parent: ?[]const []const u8 = null, // the `from` of a class
    from: bool = false, // `new from X`
    amp: bool = false, // `return & x`
    bval: bool = false, // a boolean's value
    in_loop: bool = false, // `for x in list` (else `for x = a to b`)
    e: ?*G = null, // the one expression of an expr/return/say/see/give(target)/exit/loop/un/post/paren/callkw
    l: ?*G = null,
    r: ?*G = null,
    a: ?*G = null,
    b: ?*G = null,
    step: ?*G = null,
    cond: ?*G = null,
    callee: ?*G = null,
    obj: ?*G = null,
    prop: ?*G = null,
    idx: ?*G = null,
    key: ?*G = null,
    val: ?*G = null,
    subject: ?*G = null,
    path: ?*G = null, // a load's string
    catch_: ?*G = null,
    trail: ?*G = null, // the comment after a statement, on its line
    items: ?*List = null,
    then: ?*List = null,
    elifs: ?*List = null,
    params: ?*List = null,
    args: ?*List = null,
    cases: ?*List = null,
    values: ?*List = null,
    else_: ?*List = null,
    finally_: ?*List = null,
    other: ?*List = null,
};

fn sl(l: ?*List) []*G {
    return if (l) |x| x.items else &.{};
}

fn isDef(k: K) bool {
    return k == .func or k == .class or k == .package;
}

/// Statements and definitions carry the comment after them on their line (`trail`); a comment inside an expression has nowhere to stay in
/// a layout-free text, so the graph moves it to an item of its own after the statement it sat in.
fn isCarrier(k: K) bool {
    return switch (k) {
        .package, .class, .private, .func, .expr, .ret, .say, .see, .give, .if_, .while_, .for_, .dowhile, .switch_, .try_, .load, .import, .exit, .loop, .bye, .scanner => true,
        else => false,
    };
}

fn lastDef(items: []*G) ?*G {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (isDef(items[i].k)) return items[i];
    }
    return null;
}

/// Where the statements written after definition d run: the function at its physical end, else d itself.
fn tailTarget(d: *G) *G {
    if (d.k == .func) return d;
    if (lastDef(sl(d.items))) |last| return tailTarget(last);
    return d;
}

fn eachChild(g: *G, a: Alloc, out: *List) Alloc.Error!void {
    inline for (.{ "e", "l", "r", "a", "b", "step", "cond", "callee", "obj", "prop", "idx", "key", "val", "subject", "path", "catch_", "trail" }) |f| {
        if (@field(g, f)) |c| try out.append(a, c);
    }
    inline for (.{ "items", "then", "elifs", "params", "args", "cases", "values", "else_", "finally_", "other" }) |f| {
        if (@field(g, f)) |l| try out.appendSlice(a, l.items);
    }
}

fn itemsOf(a: Alloc, g: *G) Alloc.Error!*List {
    if (g.items) |l| return l;
    const l = try a.create(List);
    l.* = .{};
    g.items = l;
    return l;
}

fn newList(a: Alloc, from: []const *G) Alloc.Error!*List {
    const l = try a.create(List);
    l.* = .{};
    try l.appendSlice(a, from);
    return l;
}

// ---- finish: Ring's flow, applied to the graph ----------------------------------------------------------------------------------------
// Measured on the oracle (haro/spike/v18/probes/closers.py, fall.py): `end`, `endfunc` and `}` after a function are inert -- a statement written
// after a definition runs as part of the LAST FUNCTION's flow, up to the next definition -- and a `return` that ends its line is BARE
// (vendor/ring-vm/src/stmt.c:931), so what stands on a later row is a statement of its own that never runs. The parser's tree shows neither
// reliably, so the graph is built from the tree and then settled by these rules, in this order.

/// Statements after a definition belong to the last function the definition holds, up to the next definition; the comments that head the
/// next definition, or end the file, stay where they are.
fn absorb(a: Alloc, items: []*G) Alloc.Error![]*G {
    var out = List{};
    var i: usize = 0;
    while (i < items.len) {
        const it = items[i];
        try out.append(a, it);
        i += 1;
        if (!isDef(it.k)) continue;
        var j = i;
        while (j < items.len and !isDef(items[j].k) and items[j].k != .private) j += 1;
        const chunk = items[i..j];
        var n = chunk.len;
        while (n > 0 and chunk[n - 1].k == .comment) n -= 1;
        if (n > 0) {
            const tgt = tailTarget(it);
            const l = try itemsOf(a, tgt);
            try l.appendSlice(a, chunk[0..n]);
        }
        try out.appendSlice(a, chunk[n..]);
        i = j;
    }
    return out.items;
}

/// A comment after the last statement of a definition is the parser's: it belongs to what holds the definition. Bottom up.
fn popComments(a: Alloc, items: []*G) Alloc.Error![]*G {
    var out = List{};
    for (items) |it| {
        if (isDef(it.k)) {
            if (it.k != .func) {
                const l = try itemsOf(a, it);
                l.items = try popComments(a, l.items);
            }
            var cut = sl(it.items).len;
            while (cut > 0 and sl(it.items)[cut - 1].k == .comment) cut -= 1;
            const total = sl(it.items).len;
            try out.append(a, it);
            if (cut < total) {
                const l = it.items.?;
                try out.appendSlice(a, l.items[cut..total]);
                l.items.len = cut;
            }
        } else try out.append(a, it);
    }
    return out.items;
}

/// Bottom up: a class settles what follows its own functions before the file settles what follows the class.
fn settleAbsorb(a: Alloc, g: *G, depth: u32) Err!void {
    if (depth > max_depth) return tooDeep();
    var kids = List{};
    try eachChild(g, a, &kids);
    for (kids.items) |c| try settleAbsorb(a, c, depth + 1);
    if (g.k == .file or g.k == .package or g.k == .class) {
        const l = try itemsOf(a, g);
        l.items = try absorb(a, l.items);
    }
}

/// `private` is a keyword on Ring, so a bare `private` the parser read as an expression (it does, after a comment that follows a top-level
/// statement and precedes a class -- v18/probes/priv7.ring) is the marker, and what follows it is the class's, not the function's flow
/// it was parked in.
fn liftPrivate(a: Alloc, g: *G, depth: u32) Err!void {
    if (depth > max_depth) return tooDeep();
    var kids = List{};
    try eachChild(g, a, &kids);
    for (kids.items) |c| try liftPrivate(a, c, depth + 1);
    if (g.k == .file or g.k == .package or g.k == .class) {
        var out = List{};
        for (sl(g.items)) |it| {
            try out.append(a, it);
            if (it.k == .func) {
                const fi = sl(it.items);
                var at: ?usize = null;
                for (fi, 0..) |y, n| {
                    if (y.k == .private) {
                        at = n;
                        break;
                    }
                }
                if (at) |p| {
                    try out.appendSlice(a, fi[p..]);
                    it.items.?.items.len = p;
                }
            }
        }
        const l = try itemsOf(a, g);
        l.items = out.items;
    }
}

/// A comment on the line where a definition ends trails the last statement that line holds, whichever node the parser hung it on.
fn pushTrails(items: []*G) void {
    for (items) |it| {
        if (!isDef(it.k)) continue;
        pushTrails(sl(it.items));
        if (it.trail) |t| {
            var tgt = it;
            while (isDef(tgt.k)) {
                const li = sl(tgt.items);
                if (li.len > 0 and isCarrier(li[li.len - 1].k)) tgt = li[li.len - 1] else break;
            }
            if (tgt != it and tgt.trail == null) {
                tgt.trail = t;
                it.trail = null;
            }
        }
    }
}

fn finish(a: Alloc, g: *G) Err!void {
    try liftPrivate(a, g, 0);
    try settleAbsorb(a, g, 0);
    const l = try itemsOf(a, g);
    l.items = try popComments(a, l.items);
    pushTrails(l.items);
}

// ---- abstraction: the concrete tree to the graph ----------------------------------------------------------------------------------------

const SK = enum { expression, ret, see, give, if_, for_, while_, switch_, try_, do_again, exit, loop, bye, load, import };
const stmt_kinds = std.StaticStringMap(SK).initComptime(.{
    .{ "expression_statement", .expression }, .{ "return_statement", .ret },     .{ "see_statement", .see },
    .{ "give_statement", .give },             .{ "if_statement", .if_ },         .{ "for_statement", .for_ },
    .{ "while_statement", .while_ },          .{ "switch_statement", .switch_ }, .{ "try_statement", .try_ },
    .{ "do_again_statement", .do_again },     .{ "exit_statement", .exit },      .{ "loop_statement", .loop },
    .{ "bye_statement", .bye },               .{ "load_statement", .load },      .{ "import_statement", .import },
});

const XK = enum {
    identifier, number, string, symbol, self_, super_, boolean, null_, qualified, parens, assignment, binary, unary, postfix, call,
    call_keyword, member, subscript, brace, new, anonymous, list_literal, hash_pair,
};
const expr_kinds = std.StaticStringMap(XK).initComptime(.{
    .{ "identifier", .identifier },       .{ "number", .number },                   .{ "string", .string },
    .{ "symbol", .symbol },               .{ "self", .self_ },                      .{ "super", .super_ },
    .{ "boolean", .boolean },             .{ "null", .null_ },                      .{ "qualified_identifier", .qualified },
    .{ "parenthesized_expression", .parens }, .{ "assignment_expression", .assignment }, .{ "binary_expression", .binary },
    .{ "unary_expression", .unary },      .{ "postfix_expression", .postfix },      .{ "call_expression", .call },
    .{ "call_keyword_expression", .call_keyword }, .{ "member_expression", .member }, .{ "subscript_expression", .subscript },
    .{ "brace_expression", .brace },      .{ "new_expression", .new },              .{ "new_with_parens", .new },
    .{ "anonymous_function", .anonymous }, .{ "list_literal", .list_literal },      .{ "hash_pair", .hash_pair },
});

/// `!` and `not` compile to the same code on rnxc and Ring, so they print one way; `&&` and `||` keep the spelling they were written in.
fn keywordOp(kind: []const u8) []const u8 {
    return if (eq(kind, "!")) "not" else kind;
}

fn isStatementKind(kind: []const u8) bool {
    return stmt_kinds.has(kind);
}

fn isDefKind(kind: []const u8) bool {
    return oneOf(kind, &.{ "function_definition", "class_definition", "package_definition" });
}

/// `isalnum` as the reference reads it: a character of a text decoded as Latin-1, so a byte is a code point and a few above 0x7f are letters.
fn isAlnumL1(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        0xaa, 0xb2, 0xb3, 0xb5, 0xb9, 0xba, 0xbc, 0xbd, 0xbe => true,
        0xc0...0xd6, 0xd8...0xf6, 0xf8...0xff => true,
        else => false,
    };
}

fn termEnd(c: u8) bool {
    return isAlnumL1(c) or std.mem.indexOfScalar(u8, "_\"'`)]}", c) != null;
}

/// The length of the keyword a statement leads with when its payload is one expression: the statements the parser cuts at a `+`.
fn leadingKeyword(piece: []const u8) ?usize {
    if (piece.len > 0 and piece[0] == '?') return 1;
    inline for (.{ "return", "see", "give" }) |kw| {
        if (piece.len > kw.len and std.ascii.eqlIgnoreCase(piece[0..kw.len], kw) and (piece[kw.len] == ' ' or piece[kw.len] == '\t')) return kw.len;
    }
    return null;
}

/// A statement the parser cut off the line above: an expression that begins, down its left spine, with a unary `+` or `-`.
fn isSplitTail(n: *CN) bool {
    if (!eq(n.kind, "expression_statement") or n.kids.len != 1) return false;
    var e = n.kids[0];
    while (eq(e.kind, "binary_expression") and e.kids.len > 0) e = e.kids[0];
    return eq(e.kind, "unary_expression") and e.kids.len > 0 and (textIs(e.kids[0].text, "+") or textIs(e.kids[0].text, "-"));
}

fn allBare(kids: []*CN) bool {
    for (kids) |c| {
        if (!eq(c.kind, "return") and !eq(c.kind, "&")) return false;
    }
    return true;
}

const Reread = struct { items: []*G, consumed: usize };
const Cont = struct { items: List = .{}, ends: std.ArrayListUnmanaged(u32) = .{}, nested: List = .{} };
const Exr = struct { g: *G, next: usize };
const Clause = struct { k: *CN, kids: []*CN };
const Split = struct { head: []*CN, clauses: []Clause };

fn byPos(_: void, x: *G, y: *G) bool {
    return x.pos < y.pos;
}

const Abs = struct {
    a: Alloc,
    parser: ts.Parser,
    src: []const u8,
    nl: []u32, // the byte offset of every newline
    inner: List = .{}, // the comments met inside the statement being read: items of their own after it
    depth: u32 = 0,
    last_reread: ?Reread = null,

    fn init(a: Alloc, parser: ts.Parser, src: []const u8) Alloc.Error!Abs {
        var nl = std.ArrayListUnmanaged(u32){};
        for (src, 0..) |c, i| {
            if (c == '\n') try nl.append(a, @intCast(i));
        }
        return .{ .a = a, .parser = parser, .src = src, .nl = nl.items };
    }

    // -- positions
    fn line(self: *Abs, pos: u32) usize {
        var lo: usize = 0;
        var hi: usize = self.nl.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.nl[mid] < pos) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn text(self: *Abs, n: *CN) []const u8 {
        const s: usize = @min(n.start, self.src.len);
        const e: usize = @min(@max(n.end, n.start), self.src.len);
        return self.src[s..e];
    }

    fn mk(self: *Abs, k: K) Alloc.Error!*G {
        const g = try self.a.create(G);
        g.* = .{ .k = k };
        return g;
    }

    fn comment(self: *Abs, raw: []const u8) Alloc.Error!*G {
        var t = raw;
        // a line comment ends at the newline; on a CRLF file the carriage return is the line ending's, not the comment's
        if ((t.len == 0 or t[0] != '/' or (t.len >= 2 and t[1] == '/')) and t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
        const g = try self.mk(.comment);
        g.text = t;
        return g;
    }

    fn one(self: *Abs, g: *G) Alloc.Error![]*G {
        const s = try self.a.alloc(*G, 1);
        s[0] = g;
        return s;
    }

    fn kid(n: *CN, i: usize) Err!*CN {
        if (i >= n.kids.len) return error.Shape;
        return n.kids[i];
    }

    fn leaf(n: *CN) Err![]const u8 {
        return n.text orelse error.Shape;
    }

    fn tail(kids: []*CN, from: usize) []*CN {
        return if (from >= kids.len) kids[0..0] else kids[from..];
    }

    // -- the file
    fn file(self: *Abs, root: *CN) Err!*G {
        const c = try self.container(root.kids, false);
        const g = try self.mk(.file);
        g.items = try newList(self.a, c.items.items);
        try finish(self.a, g);
        return g;
    }

    // -- a list of statements, definitions and comments

    /// Ring's flow, in the tree. A statement written after a function runs as part of that function, up to the next definition; a function
    /// or a statement written after a class is the class's -- every `func` after the first `class` is a method of the latest one (F-21) --
    /// and `end` and `}` close nothing (v18/probes/fall.py, nest.ring). The parser leaves them beside the definition, or hands them to the
    /// OUTER class of a nested pair, so they are moved into the definition before anything is read: which is also what lets a `return` and
    /// the tail the parser cut off it meet again.
    fn absorbKids(self: *Abs, kids_in: []*CN) Err![]*CN {
        const kids = try self.foldLambdas(kids_in);
        var out = std.ArrayListUnmanaged(*CN){};
        var i: usize = 0;
        while (i < kids.len) {
            const k = kids[i];
            try out.append(self.a, k);
            i += 1;
            if (!isDefKind(k.kind)) continue;
            const is_fn = eq(k.kind, "function_definition");
            const is_cls = eq(k.kind, "class_definition");
            var j = i;
            while (j < kids.len) {
                const kk = kids[j].kind;
                const stop = if (is_fn)
                    isDefKind(kk) or eq(kk, "private_section")
                else if (is_cls)
                    eq(kk, "class_definition") or eq(kk, "package_definition")
                else
                    eq(kk, "package_definition");
                if (stop) break;
                j += 1;
            }
            const chunk = kids[i..j];
            var n = chunk.len;
            while (n > 0 and eq(chunk[n - 1].kind, "comment")) n -= 1;
            if (n > 0) {
                const nk = try self.a.alloc(*CN, k.kids.len + n);
                @memcpy(nk[0..k.kids.len], k.kids);
                @memcpy(nk[k.kids.len..], chunk[0..n]);
                k.kids = nk;
                k.end = @max(k.end, chunk[n - 1].end);
            }
            if (!is_fn) k.kids = try self.absorbKids(k.kids);
            try out.appendSlice(self.a, chunk[n..]);
            i = j;
        }
        return out.items;
    }

    /// `return func t { ... }`, one parameter and no parentheses, at the head of a function's own statement list: the grammar reads a BARE `return`
    /// and, on the same row, a FUNCTION DEFINITION named `t` (it cannot tell the two apart there; `return func(t) {`, `return func a, b {` and the
    /// same line inside an `if` it reads right). Ring reads a lambda. The definition is folded back into the return as the lambda it is (the compiler
    /// does the same, `Compiler.absorbed`), and what the grammar hung after its closing brace stays where the return is. The return is either the last
    /// statement of the function before it or, after an `if`, a statement the grammar left beside it: both are met.
    fn foldLambdas(self: *Abs, kids: []*CN) Err![]*CN {
        var out = std.ArrayListUnmanaged(*CN){};
        var i: usize = 0;
        while (i < kids.len) {
            const cur = kids[i];
            try out.append(self.a, cur);
            i += 1;
            if (i >= kids.len) break;
            var ret: ?*CN = null;
            var owner: ?*CN = null;
            if (eq(cur.kind, "return_statement")) {
                ret = cur;
            } else if (eq(cur.kind, "function_definition") and cur.kids.len > 0 and eq(cur.kids[cur.kids.len - 1].kind, "return_statement")) {
                ret = cur.kids[cur.kids.len - 1];
                owner = cur;
            }
            const nxt = kids[i];
            const rt = ret orelse continue;
            if (!allBare(rt.kids) or !eq(nxt.kind, "function_definition") or nxt.kids.len < 3) continue;
            const ident = nxt.kids[1];
            if (!eq(ident.kind, "identifier")) continue;
            var e: usize = ident.end;
            while (e < self.src.len and (self.src[e] == ' ' or self.src[e] == '\t')) e += 1;
            if (e >= self.src.len or self.src[e] != '{' or self.line(nxt.start) != self.line(if (rt.end > 0) rt.end - 1 else 0)) continue;
            var close: ?usize = null;
            for (nxt.kids, 0..) |c, n| {
                if (eq(c.kind, "}")) close = n;
            }
            const ci = close orelse continue;
            const plist = try self.a.create(CN);
            const pk = try self.a.alloc(*CN, 1);
            pk[0] = ident;
            plist.* = .{ .kind = "param_list", .start = ident.start, .end = ident.end, .kids = pk, .text = null };
            const lk = try self.a.alloc(*CN, ci + 1);
            lk[0] = nxt.kids[0];
            lk[1] = plist;
            @memcpy(lk[2..], nxt.kids[2 .. ci + 1]);
            const lam = try self.a.create(CN);
            lam.* = .{ .kind = "anonymous_function", .start = nxt.start, .end = nxt.kids[ci].end, .kids = lk, .text = null };
            const rk = try self.a.alloc(*CN, rt.kids.len + 1);
            @memcpy(rk[0..rt.kids.len], rt.kids);
            rk[rt.kids.len] = lam;
            rt.kids = rk;
            rt.end = @max(rt.end, lam.end);
            const rest = nxt.kids[ci + 1 ..];
            if (owner) |ow| {
                if (rest.len > 0) {
                    const nk = try self.a.alloc(*CN, ow.kids.len + rest.len);
                    @memcpy(nk[0..ow.kids.len], ow.kids);
                    @memcpy(nk[ow.kids.len..], rest);
                    ow.kids = nk;
                }
                ow.end = @max(ow.end, nxt.end);
            } else {
                try out.appendSlice(self.a, rest);
            }
            i += 1;
        }
        return out.items;
    }

    /// -> the items, where each ends, and the classes the grammar nested inside this class's members: siblings in the graph.
    fn container(self: *Abs, kids_in: []*CN, cls: bool) Err!Cont {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return tooDeep();
        const kids = try self.absorbKids(kids_in);
        var c = Cont{};
        const a = self.a;
        var i: usize = 0;
        while (i < kids.len) {
            const k = kids[i];
            const kind = k.kind;
            i += 1;
            if (eq(kind, "comment") and cls and c.nested.items.len > 0) {
                const cm = try self.comment(self.text(k)); // after a nested class: between it and the next, so beside them, in order
                cm.pos = k.start;
                try c.nested.append(a, cm);
            } else if (eq(kind, "comment")) {
                try self.commentInto(&c, k);
            } else if (eq(kind, "class_definition")) {
                const defs = try self.classDef(k);
                if (cls) {
                    try c.nested.appendSlice(a, defs);
                } else for (defs) |it| try self.add(&c, it, k.end);
            } else if (eq(kind, "private_section") and cls) {
                try self.add(&c, try self.mk(.private), k.start + 7);
                const sub = try self.container(tail(k.kids, 1), true);
                try c.items.appendSlice(a, sub.items.items);
                try c.ends.appendSlice(a, sub.ends.items);
                try c.nested.appendSlice(a, sub.nested.items);
            } else if (eq(kind, "package_definition")) {
                for (try self.packageDef(k)) |it| try self.add(&c, it, k.end);
            } else if (eq(kind, "function_definition")) {
                try self.add(&c, try self.funcDef(k), k.end);
            } else if (eq(kind, "expression_statement") and k.kids.len == 1 and eq(k.kids[0].kind, "identifier") and lowerIs(k.kids[0].text, "private")) {
                try self.add(&c, try self.mk(.private), k.end);
            } else if (eq(kind, "expression_statement") and k.kids.len == 1 and eq(k.kids[0].kind, "identifier") and
                (lowerIs(k.kids[0].text, "end") or lowerIs(k.kids[0].text, "endfunc")))
            {
                // a closer the parser read as a name: on Ring `end` and `endfunc` after a function close nothing (closers.py)
            } else if (oneOf(kind, &.{ "return_statement", "expression_statement", "see_statement" }) and (try self.reread(kids, i - 1)) != null) {
                const rr = self.last_reread.?;
                const stop = kids[i + rr.consumed - 2].end;
                for (rr.items) |it| try self.add(&c, it, stop);
                i += rr.consumed - 1;
            } else if (isStatementKind(kind)) {
                for (try self.stmts(k)) |it| try self.add(&c, it, k.end);
            } else if (eq(kind, "scanner_command")) {
                const g = try self.mk(.scanner);
                g.text = self.text(k);
                try self.add(&c, g, k.end);
            }
            // anything else is punctuation or a terminator: `,`, `end`, `ok`, `{`, `}` ...
        }
        std.sort.block(*G, c.nested.items, {}, byPos);
        return c;
    }

    fn add(self: *Abs, c: *Cont, g: *G, end: u32) Alloc.Error!void {
        try c.items.append(self.a, g);
        try c.ends.append(self.a, end);
    }

    // -- a statement the parser cut where Ring does not, or did not cut where Ring does (the port of compile.zig's rereadSpan)

    /// Ring reads a line greedily: on one row `return E1 + E2` is one expression, and a line that begins with `+` or `-` after a finished term
    /// is a statement of its own. The parser does neither reliably, so the text of the statement and of every same-row tail it cut off is read
    /// again alone, in a function, where the parser keeps it whole. -> null when the tree already says what Ring says; else it sets
    /// last_reread to (items, statements consumed).
    fn reread(self: *Abs, kids: []*CN, i: usize) Err!?Reread {
        const a = self.a;
        const st = kids[i];
        const bare = eq(st.kind, "return_statement") and allBare(st.kids);
        var j = i + 1;
        // a line that ends in `.` is unfinished on Ring, so the next statement, on any row, continues the chain the parser cut at the dot
        while (j < kids.len and (eq(kids[j].kind, "expression_statement") or eq(kids[j].kind, "see_statement"))) {
            const pe = kids[j - 1].end;
            const dot = pe >= 1 and pe <= self.src.len and self.src[pe - 1] == '.';
            const same_row = self.line(kids[j].start) == self.line(if (pe > 0) pe - 1 else 0);
            if (dot or (same_row and (isSplitTail(kids[j]) or (j == i + 1 and bare)))) j += 1 else break;
        }
        const s_a = st.start;
        const s_b = kids[j - 1].end;
        if (s_a > s_b or s_b > self.src.len) return null;
        const buf = try a.dupe(u8, self.src[s_a..s_b]);
        var hoisted = List{};
        var comments = std.ArrayListUnmanaged(*CN){};
        {
            var stack = std.ArrayListUnmanaged(*CN){};
            try stack.appendSlice(a, kids[i..j]);
            while (stack.pop()) |n| {
                if (eq(n.kind, "comment")) try comments.append(a, n) else try stack.appendSlice(a, n.kids);
            }
        }
        const has_nl = std.mem.indexOfScalar(u8, buf, '\n') != null;
        if (comments.items.len > 0 and (j > i + 1 or has_nl)) {
            std.sort.block(*CN, comments.items, {}, struct {
                fn f(_: void, x: *CN, y: *CN) bool {
                    return x.start < y.start;
                }
            }.f);
            for (comments.items) |cm| {
                try hoisted.append(a, try self.comment(self.text(cm)));
                if (cm.start < s_a) continue;
                var p: usize = cm.start - s_a;
                const pend: usize = @min(cm.end - s_a, buf.len);
                while (p < pend) : (p += 1) {
                    if (buf[p] != '\r' and buf[p] != '\n') buf[p] = ' ';
                }
            }
        } else comments.items.len = 0;
        var starts = std.ArrayListUnmanaged(usize){};
        try starts.append(a, 0);
        var line_start: usize = 0;
        for (buf, 0..) |ch, p| {
            if (ch != '\n') continue;
            var q = p;
            while (q > line_start and (buf[q - 1] == ' ' or buf[q - 1] == '\t' or buf[q - 1] == '\r')) q -= 1;
            const finished = q > line_start and termEnd(buf[q - 1]);
            var r = p + 1;
            while (r < buf.len and (buf[r] == ' ' or buf[r] == '\t' or buf[r] == '\r')) r += 1;
            if (finished and r < buf.len and (buf[r] == '+' or buf[r] == '-')) try starts.append(a, r);
            line_start = p + 1;
        }
        if (j == i + 1 and starts.items.len == 1 and comments.items.len == 0) return null;
        var items = List{};
        for (starts.items, 0..) |s0, n| {
            const s1 = if (n + 1 < starts.items.len) starts.items[n + 1] else buf.len;
            const piece = std.mem.trim(u8, buf[s0..s1], " \t\r\n");
            if (piece.len == 0) continue;
            const got = (try self.parsePiece(piece)) orelse return null;
            try items.appendSlice(a, got);
        }
        try items.appendSlice(a, hoisted.items);
        self.last_reread = .{ .items = items.items, .consumed = j - i };
        return self.last_reread;
    }

    /// One statement's text alone -> its items, or null.
    fn parsePiece(self: *Abs, piece: []const u8) Err!?[]*G {
        const a = self.a;
        if (try self.parseSnippet(piece)) |got| return got;
        if (leadingKeyword(piece)) |kw| {
            const rest = std.mem.trim(u8, piece[kw..], " \t\r\n");
            if (rest.len == 0) return null;
            const wrapped = try std.fmt.allocPrint(a, "{s} ({s})", .{ piece[0..kw], rest });
            const got = (try self.parseSnippet(wrapped)) orelse return null;
            if (got.len != 1 or !(got[0].k == .ret or got[0].k == .say or got[0].k == .see or got[0].k == .give)) return null;
            if (got[0].e) |e| {
                if (e.k == .paren) got[0].e = e.e orelse return null;
            }
            return got;
        }
        const wrapped = try std.fmt.allocPrint(a, "({s})", .{piece});
        if (try self.parseSnippet(wrapped)) |got| {
            if (got.len == 1 and got[0].k == .expr) {
                if (got[0].e) |e| {
                    if (e.k == .paren) {
                        if (e.e) |inner| {
                            if (inner.k == .call) {
                                got[0].e = inner;
                                return got;
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    fn parseSnippet(self: *Abs, piece: []const u8) Err!?[]*G {
        const a = self.a;
        const text_ = try std.fmt.allocPrint(a, "func __reread()\n{s}\n", .{piece});
        const tree = self.parser.parse(text_) orelse return null;
        defer tree.deinit();
        if (tree.root().hasError()) return null;
        const root = try buildTree(a, tree.root(), 0);
        var found = std.ArrayListUnmanaged(*CN){};
        for (root.kids) |top| {
            if (eq(top.kind, "function_definition")) {
                for (tail(top.kids, 2)) |c| {
                    if (isStatementKind(c.kind)) try found.append(a, c);
                }
            } else if (isStatementKind(top.kind)) try found.append(a, top);
        }
        if (found.items.len == 0) return null;
        var sub = try Abs.init(a, self.parser, text_);
        const want: u32 = @intCast(text_.len - 1);
        if (found.items[0].end == want) return try sub.stmts(found.items[0]);
        if (found.items.len == 2 and eq(found.items[0].kind, "return_statement") and allBare(found.items[0].kids) and
            eq(found.items[1].kind, "expression_statement") and found.items[1].end == want)
        {
            const ret = try sub.stmts(found.items[0]);
            const stray = try sub.stmts(found.items[1]);
            const f0e = found.items[0].end;
            if (sub.line(found.items[1].start) != sub.line(if (f0e > 0) f0e - 1 else 0)) {
                return try concat(a, ret, stray); // a later row: Ring's bare return, then a statement of its own
            }
            if (ret.len == 0 or stray.len == 0) return error.Shape;
            var e = stray[0].e orelse return error.Shape;
            if (e.k == .assign and textIs(e.op, "=")) {
                const b = try self.mk(.bin); // the value of a return is an expression: its `=` compares
                b.op = "=";
                b.l = e.l;
                b.r = e.r;
                e = b;
            }
            const joined = try self.mk(.ret);
            joined.e = e;
            joined.amp = ret[0].amp;
            var out = List{};
            try out.append(a, joined);
            try out.appendSlice(a, ret[1..]);
            try out.appendSlice(a, stray[1..]);
            return out.items;
        }
        return null;
    }

    fn concat(a: Alloc, x: []*G, y: []*G) Alloc.Error![]*G {
        const out = try a.alloc(*G, x.len + y.len);
        @memcpy(out[0..x.len], x);
        @memcpy(out[x.len..], y);
        return out;
    }

    /// A comment on the line where the previous item ends trails it; any other is an item where it stands.
    fn commentInto(self: *Abs, c: *Cont, k: *CN) Alloc.Error!void {
        const cm = try self.comment(self.text(k));
        const n = c.items.items.len;
        if (n > 0) {
            const prev = c.items.items[n - 1];
            const pe = c.ends.items[n - 1];
            if (isCarrier(prev.k) and prev.trail == null and self.line(k.start) == self.line(if (pe > 0) pe - 1 else 0)) {
                prev.trail = cm;
                return;
            }
        }
        try self.add(c, cm, k.end);
    }

    // -- definitions
    fn qname(self: *Abs, n: *CN) Alloc.Error![]const []const u8 {
        var out = std.ArrayListUnmanaged([]const u8){};
        for (n.kids) |k| {
            if (eq(k.kind, "identifier")) try out.append(self.a, k.text orelse "");
        }
        return out.items;
    }

    fn packageDef(self: *Abs, n: *CN) Err![]*G {
        const g = try self.mk(.package);
        g.qname = try self.qname(try kid(n, 1));
        const c = try self.container(tail(n.kids, 2), false);
        var flat = List{};
        var nested = List{};
        for (c.items.items) |it| {
            if (it.k == .package) try nested.append(self.a, it) else try flat.append(self.a, it);
        }
        g.items = try newList(self.a, flat.items);
        var out = List{};
        try out.append(self.a, g);
        try out.appendSlice(self.a, nested.items);
        return out.items;
    }

    fn classDef(self: *Abs, n: *CN) Err![]*G {
        const g = try self.mk(.class);
        g.name = try leaf(try kid(n, 1));
        var i: usize = 2;
        if (i < n.kids.len and eq(n.kids[i].kind, "class_parent")) {
            const cp = n.kids[i];
            if (cp.kids.len == 0) return error.Shape;
            g.parent = try self.qname(cp.kids[cp.kids.len - 1]);
            i += 1;
        }
        const c = try self.container(tail(n.kids, i), true);
        g.items = try newList(self.a, c.items.items);
        g.pos = n.start; // the grammar nests a class in the one before it; the graph puts them side by side, in source order
        var out = List{};
        try out.append(self.a, g);
        try out.appendSlice(self.a, c.nested.items);
        return out.items;
    }

    fn funcDef(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.func);
        g.name = try leaf(try kid(n, 1));
        var i: usize = 2;
        if (i < n.kids.len and eq(n.kids[i].kind, "param_list")) {
            g.params = try self.params(n.kids[i]);
            i += 1;
        }
        const c = try self.container(tail(n.kids, i), false);
        g.items = try newList(self.a, c.items.items);
        return g;
    }

    fn params(self: *Abs, n: *CN) Err!*List {
        var out = List{};
        for (n.kids) |k| {
            if (eq(k.kind, "identifier")) {
                const p = try self.mk(.param);
                p.name = k.text orelse return error.Shape;
                try out.append(self.a, p);
            } else if (eq(k.kind, "typed_parameter")) {
                const p = try self.mk(.param);
                p.name = try leaf(try kid(k, 1));
                p.ty = try leaf(try kid(k, 0));
                try out.append(self.a, p);
            }
        }
        return newList(self.a, out.items);
    }

    // -- statements

    /// A statement and, after it, the comments that sat inside it (the graph keeps them, as items of their own).
    fn stmts(self: *Abs, n: *CN) Err![]*G {
        const saved = self.inner;
        self.inner = .{};
        const item = try self.stmtOf(n);
        const hoisted = self.inner;
        self.inner = saved;
        return concat(self.a, item, hoisted.items);
    }

    fn stmtOf(self: *Abs, n: *CN) Err![]*G {
        const sk = stmt_kinds.get(n.kind) orelse return error.Unsupported;
        return switch (sk) {
            .expression => self.one(try self.sExpression(n)),
            .ret => self.sReturn(n),
            .see => self.one(try self.sSee(n)),
            .give => self.one(try self.sGive(n)),
            .exit => self.one(try self.sExitLoop(n, .exit)),
            .loop => self.one(try self.sExitLoop(n, .loop)),
            .bye => self.one(try self.mk(.bye)),
            .load => self.one(try self.sLoad(n)),
            .import => self.one(try self.sImport(n)),
            .if_ => self.one(try self.sIf(n)),
            .while_ => self.one(try self.sWhile(n)),
            .for_ => self.one(try self.sFor(n)),
            .do_again => self.one(try self.sDoAgain(n)),
            .switch_ => self.one(try self.sSwitch(n)),
            .try_ => self.one(try self.sTry(n)),
        };
    }

    fn body(self: *Abs, kids: []*CN) Err!*List {
        const c = try self.container(kids, false);
        return newList(self.a, c.items.items);
    }

    /// The expression at kids[i], skipping comments (they become the statement's inner comments); -> (graph, next index).
    fn ex(self: *Abs, kids: []*CN, i_in: usize) Err!Exr {
        var i = i_in;
        while (i < kids.len and eq(kids[i].kind, "comment")) {
            try self.inner.append(self.a, try self.comment(self.text(kids[i])));
            i += 1;
        }
        if (i >= kids.len) return error.Shape;
        return .{ .g = try self.expr(kids[i]), .next = i + 1 };
    }

    /// Split a statement's kids into the part before its first clause and one part per clause: a comment after a clause's last statement is a
    /// sibling of the clause in the tree, and belongs to the clause above it.
    fn sections(self: *Abs, kids: []*CN, comptime clause_kinds: []const []const u8) Alloc.Error!Split {
        var head = std.ArrayListUnmanaged(*CN){};
        var ks = std.ArrayListUnmanaged(*CN){};
        var lists = std.ArrayListUnmanaged(std.ArrayListUnmanaged(*CN)){};
        for (kids) |k| {
            if (oneOf(k.kind, clause_kinds)) {
                try ks.append(self.a, k);
                var l = std.ArrayListUnmanaged(*CN){};
                try l.appendSlice(self.a, k.kids);
                try lists.append(self.a, l);
            } else if (lists.items.len > 0) {
                try lists.items[lists.items.len - 1].append(self.a, k);
            } else try head.append(self.a, k);
        }
        const cl = try self.a.alloc(Clause, ks.items.len);
        for (ks.items, 0..) |k, n| cl[n] = .{ .k = k, .kids = lists.items[n].items };
        return .{ .head = head.items, .clauses = cl };
    }

    fn sExpression(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.expr);
        g.e = try self.liftStatementUnary((try self.ex(n.kids, 0)).g);
        return g;
    }

    /// The grammar reads a statement that BEGINS with a unary `+` or `-` as that operator over the WHOLE rest whenever the rest holds a binary
    /// `+` or `-` -- `-a * b - c` is unary(((a * b) - c)) -- and Ring reads the unary as binding tighter than any binary operator, `((-a) * b) - c`
    /// (measured on the oracle and the official 1.27 with an object whose `operator` prints its name: haro/spike/v18/probes/unary_stmt.ring,
    /// v18 fixture 23). Everywhere else the grammar agrees with Ring, and so it does for `-a * b`; only a statement is cut this way, so only a
    /// statement is put right: the operator goes down the left spine of the binary chain to the leftmost operand. `!a - b` stays what the
    /// grammar says -- `not` is below the arithmetic on Ring too. rnxc still compiles the grammar's tree (CLAUDE.md, rnxc fmt).
    fn liftStatementUnary(self: *Abs, e: *G) Alloc.Error!*G {
        if (e.k != .un or !(textIs(e.op, "+") or textIs(e.op, "-"))) return e;
        const chain = e.e orelse return e;
        if (chain.k != .bin) return e;
        var parent: ?*G = null;
        var cur = chain;
        while (cur.k == .bin) {
            const l = cur.l orelse break;
            parent = cur;
            cur = l;
        }
        const p = parent orelse return e;
        const u = try self.mk(.un);
        u.op = e.op;
        u.e = cur;
        p.l = u;
        return chain;
    }

    fn sReturn(self: *Abs, n: *CN) Err![]*G {
        const a = self.a;
        var amp = false;
        var rest = std.ArrayListUnmanaged(*CN){};
        for (n.kids, 0..) |k, i| {
            if (eq(k.kind, "&")) amp = true;
            if (i >= 1 and !eq(k.kind, "&")) try rest.append(a, k);
        }
        var first: ?*CN = null;
        for (rest.items) |k| {
            if (!eq(k.kind, "comment")) {
                first = k;
                break;
            }
        }
        if (first) |f| {
            const ke = (try kid(n, 0)).end;
            if (self.line(f.start) > self.line(if (ke > 0) ke - 1 else 0)) {
                // the grammar reads a newline as an extra and hangs the NEXT row's expression on the `return`; Ring's `return` that ends its
                // line is bare, and that expression is a statement of its own, dead, which the graph keeps because the text has it
                for (rest.items) |k| {
                    if (eq(k.kind, "comment")) try self.inner.append(a, try self.comment(self.text(k)));
                }
                const dead: []*G = (try self.parseSnippet(self.text(f))) orelse blk: {
                    const x = try self.mk(.expr);
                    x.e = try self.expr(f);
                    break :blk try self.one(x);
                };
                const r = try self.mk(.ret);
                r.amp = amp;
                return concat(a, try self.one(r), dead);
            }
        }
        const r = try self.mk(.ret);
        r.amp = amp;
        if (rest.items.len > 0) r.e = (try self.ex(rest.items, 0)).g;
        return self.one(r);
    }

    fn sSee(self: *Abs, n: *CN) Err!*G {
        // measured on the oracle: `?` prints a line, `see` and `put` (any case) print without one
        const g = try self.mk(if (textIs((try kid(n, 0)).text, "?")) .say else .see);
        g.e = (try self.ex(n.kids, 1)).g;
        return g;
    }

    fn sGive(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.give);
        g.e = (try self.ex(n.kids, 1)).g;
        return g;
    }

    fn sExitLoop(self: *Abs, n: *CN, k: K) Err!*G {
        const g = try self.mk(k);
        if (n.kids.len > 1) g.e = (try self.ex(n.kids, 1)).g;
        return g;
    }

    fn sLoad(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.load);
        var i: usize = 1;
        const k1 = try kid(n, 1);
        if (eq(k1.kind, "package") or eq(k1.kind, "again")) {
            g.op = k1.kind;
            i = 2;
        }
        const p = try self.mk(.str);
        p.text = self.text(try kid(n, i));
        g.path = p;
        return g;
    }

    fn sImport(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.import);
        g.qname = try self.qname(try kid(n, 1));
        return g;
    }

    fn sIf(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.if_);
        const c = try self.ex(n.kids, 1);
        g.cond = c.g;
        const sp = try self.sections(tail(n.kids, c.next), &.{ "elseif_clause", "else_clause" });
        var elifs = List{};
        for (sp.clauses) |cl| {
            if (eq(cl.k.kind, "elseif_clause")) {
                const e = try self.mk(.elif);
                const cc = try self.ex(cl.kids, 1);
                e.cond = cc.g;
                e.items = try self.body(tail(cl.kids, cc.next));
                try elifs.append(self.a, e);
            } else g.else_ = try self.body(tail(cl.kids, 1));
        }
        g.then = try self.body(sp.head);
        g.elifs = try newList(self.a, elifs.items);
        return g;
    }

    fn sWhile(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.while_);
        const c = try self.ex(n.kids, 1);
        g.cond = c.g;
        g.items = try self.body(tail(n.kids, c.next));
        return g;
    }

    fn sFor(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.for_);
        g.name = try leaf(try kid(n, 1));
        var i: usize = 2;
        if (eq((try kid(n, i)).kind, "=")) {
            const x = try self.ex(n.kids, i + 1);
            g.a = x.g;
            const y = try self.ex(n.kids, x.next + 1); // past the `to`
            g.b = y.g;
            i = y.next;
        } else {
            g.in_loop = true;
            const x = try self.ex(n.kids, i + 1);
            g.a = x.g;
            i = x.next;
        }
        if (i < n.kids.len and eq(n.kids[i].kind, "step")) {
            const s = try self.ex(n.kids, i + 1);
            g.step = s.g;
            i = s.next;
        }
        g.items = try self.body(tail(n.kids, i));
        return g;
    }

    fn sDoAgain(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.dowhile);
        var again: ?usize = null;
        for (n.kids, 0..) |k, i| {
            if (eq(k.kind, "again")) again = i;
        }
        const ag = again orelse return error.Shape;
        g.cond = (try self.ex(n.kids, ag + 1)).g;
        g.items = try self.body(if (ag >= 1) n.kids[1..ag] else n.kids[0..0]);
        return g;
    }

    fn sSwitch(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.switch_);
        const s = try self.ex(n.kids, 1);
        g.subject = s.g;
        const sp = try self.sections(tail(n.kids, s.next), &.{ "case_clause", "other_clause" });
        var cases = List{};
        for (sp.clauses) |cl| {
            if (eq(cl.k.kind, "case_clause")) {
                const cg = try self.mk(.case);
                cg.values = try self.exprs((try kid2(cl.kids, 1)).kids);
                cg.items = try self.body(tail(cl.kids, 2));
                try cases.append(self.a, cg);
            } else g.other = try self.body(tail(cl.kids, 1));
        }
        g.cases = try newList(self.a, cases.items);
        return g;
    }

    fn kid2(kids: []*CN, i: usize) Err!*CN {
        if (i >= kids.len) return error.Shape;
        return kids[i];
    }

    fn sTry(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.try_);
        const sp = try self.sections(tail(n.kids, 1), &.{ "catch_clause", "finally_clause" });
        for (sp.clauses) |cl| {
            if (eq(cl.k.kind, "catch_clause")) {
                const cg = try self.mk(.catch_);
                var rest = tail(cl.kids, 1);
                if (rest.len > 0 and eq(rest[0].kind, "(")) {
                    cg.name = try leaf(try kid2(rest, 1));
                    rest = tail(rest, 3);
                }
                cg.items = try self.body(rest);
                g.catch_ = cg;
            } else g.finally_ = try self.body(tail(cl.kids, 1));
        }
        g.items = try self.body(sp.head);
        return g;
    }

    // -- expressions
    fn expr(self: *Abs, n: *CN) Err!*G {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return tooDeep();
        const xk = expr_kinds.get(n.kind) orelse {
            why = n.kind;
            return error.Unsupported;
        };
        return switch (xk) {
            .identifier => self.textNode(.id, n.text orelse return error.Shape),
            .number => self.textNode(.num, n.text orelse return error.Shape),
            .string => self.textNode(.str, self.text(n)),
            .symbol => self.textNode(.sym, self.text(n)),
            // `self` is kept as written (text "self"): inside a brace it is the brace object and `This` the method's (F-124),
            // so they are no longer one construct; `This` and `this` stay one spelling
            .self_ => blk: {
                const g = try self.mk(.self_);
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, self.text(n), " \t\r\n"), "self")) g.text = "self";
                break :blk g;
            },
            .super_ => self.mk(.super_),
            .boolean => blk: {
                const g = try self.mk(.bool_);
                g.bval = std.ascii.eqlIgnoreCase(self.text(n), "true");
                break :blk g;
            },
            .null_ => self.mk(.null_),
            .qualified => blk: {
                const names = try self.qname(n);
                break :blk self.textNode(.id, try std.mem.join(self.a, ".", names));
            },
            .parens => self.xParen(n),
            .assignment => self.xBinaryLike(n, .assign),
            .binary => self.xBinaryLike(n, .bin),
            .unary => blk: {
                const g = try self.mk(.un);
                g.op = keywordOp((try kid(n, 0)).kind);
                g.e = (try self.ex(n.kids, 1)).g;
                break :blk g;
            },
            .postfix => blk: {
                const g = try self.mk(.post);
                const x = try self.ex(n.kids, 0);
                g.e = x.g;
                g.op = (try kid(n, x.next)).kind;
                break :blk g;
            },
            .call => self.xCall(n),
            .call_keyword => blk: {
                const g = try self.mk(.callkw);
                const k = try kid(n, 1);
                if (eq(k.kind, "brace_block")) g.items = try self.body(k.kids) else g.e = try self.expr(k);
                break :blk g;
            },
            .member => blk: {
                const g = try self.mk(.member);
                const o = try self.ex(n.kids, 0);
                g.obj = o.g;
                g.prop = (try self.ex(n.kids, o.next + 1)).g;
                break :blk g;
            },
            .subscript => blk: {
                const g = try self.mk(.index);
                const o = try self.ex(n.kids, 0);
                g.obj = o.g;
                g.idx = (try self.ex(n.kids, o.next)).g;
                break :blk g;
            },
            .brace => self.xBrace(n),
            .new => self.xNew(n),
            .anonymous => self.xLambda(n),
            .list_literal => self.xList(n),
            .hash_pair => self.xPair(n),
        };
    }

    fn textNode(self: *Abs, k: K, t: []const u8) Alloc.Error!*G {
        const g = try self.mk(k);
        g.text = t;
        return g;
    }

    fn exprs(self: *Abs, kids: []*CN) Err!*List {
        var out = List{};
        for (kids) |k| {
            if (eq(k.kind, "comment")) {
                try self.inner.append(self.a, try self.comment(self.text(k)));
            } else if (!eq(k.kind, ",")) try out.append(self.a, try self.expr(k));
        }
        return newList(self.a, out.items);
    }

    fn xParen(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.paren);
        for (n.kids) |k| {
            if (eq(k.kind, "comment")) {
                try self.inner.append(self.a, try self.comment(self.text(k)));
            } else if (!eq(k.kind, "(") and !eq(k.kind, ")")) g.e = try self.expr(k);
        }
        return g;
    }

    fn xBinaryLike(self: *Abs, n: *CN, k: K) Err!*G {
        const g = try self.mk(k);
        const l = try self.ex(n.kids, 0);
        g.l = l.g;
        const opk = (try kid(n, l.next)).kind;
        g.op = if (k == .bin) keywordOp(opk) else opk;
        g.r = (try self.ex(n.kids, l.next + 1)).g;
        return g;
    }

    fn xCall(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.call);
        const c = try self.ex(n.kids, 0);
        g.callee = c.g;
        for (tail(n.kids, c.next)) |k| {
            if (eq(k.kind, "arguments")) {
                g.args = try self.exprs(k.kids);
            } else if (eq(k.kind, "comment")) try self.inner.append(self.a, try self.comment(self.text(k)));
        }
        return g;
    }

    fn xBrace(self: *Abs, n: *CN) Err!*G {
        const o = try self.ex(n.kids, 0);
        const items = try self.body(tail(n.kids, o.next));
        if (o.g.k == .assign and textIs(o.g.op, "=")) {
            // `o = F(x) { ... }`: the brace belongs to the value (Ring's parser attaches it to the factor), and the parser sometimes hangs it on
            // the whole assignment instead. An assignment's value is what it assigned, so the two do the same; the graph keeps the first, which
            // also prints as a statement of its own, where `(o = F(x)) { }` would join the call on the line above
            const br = try self.mk(.brace);
            br.obj = o.g.r;
            br.items = items;
            const g = try self.mk(.assign);
            g.op = "=";
            g.l = o.g.l;
            g.r = br;
            return g;
        }
        const g = try self.mk(.brace);
        g.obj = o.g;
        g.items = items;
        return g;
    }

    fn xNew(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.new);
        var qi: ?usize = null;
        for (n.kids, 0..) |k, i| {
            if (eq(k.kind, "from")) g.from = true;
            if (qi == null and eq(k.kind, "qualified_identifier")) qi = i;
        }
        const q = qi orelse return error.Shape;
        g.qname = try self.qname(n.kids[q]);
        const after = tail(n.kids, q + 1);
        if (after.len > 0 and eq(after[0].kind, "(")) {
            var args: ?*List = try newList(self.a, &.{});
            for (after) |k| {
                if (eq(k.kind, "arguments")) args = try self.exprs(k.kids);
            }
            g.args = args;
        } else if (after.len > 0 and eq(after[0].kind, "{")) {
            g.items = try self.body(after);
        }
        return g;
    }

    fn xLambda(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.lambda);
        var rest = std.ArrayListUnmanaged(*CN){};
        for (n.kids) |k| {
            if (eq(k.kind, "param_list")) g.params = try self.params(k) else try rest.append(self.a, k);
        }
        g.items = try self.body(rest.items);
        return g;
    }

    fn xList(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.list);
        var items = List{};
        for (n.kids) |k| {
            if (eq(k.kind, "comment")) {
                try self.inner.append(self.a, try self.comment(self.text(k)));
            } else if (eq(k.kind, "hash_pair")) {
                try items.append(self.a, try self.xPair(k));
            } else if (!oneOf(k.kind, &.{ "[", "]", "," })) try items.append(self.a, try self.expr(k));
        }
        g.items = try newList(self.a, items.items);
        return g;
    }

    fn xPair(self: *Abs, n: *CN) Err!*G {
        const g = try self.mk(.pair);
        const k = try self.ex(n.kids, 0);
        g.key = k.g;
        g.val = (try self.ex(n.kids, k.next + 1)).g;
        return g;
    }
};

// ---- the printer -------------------------------------------------------------------------------------------------------------------

fn binPrec(op: []const u8) u8 {
    const T = struct { op: []const u8, p: u8 };
    const table = [_]T{
        .{ .op = "or", .p = 2 },  .{ .op = "||", .p = 2 }, .{ .op = "and", .p = 3 }, .{ .op = "&&", .p = 3 }, .{ .op = "=", .p = 5 },
        .{ .op = "!=", .p = 5 },  .{ .op = "<", .p = 6 },  .{ .op = ">", .p = 6 },   .{ .op = "<=", .p = 6 },  .{ .op = ">=", .p = 6 },
        .{ .op = "|", .p = 7 },   .{ .op = "^", .p = 7 },  .{ .op = "&", .p = 9 },   .{ .op = "<<", .p = 10 }, .{ .op = ">>", .p = 10 },
        .{ .op = "+", .p = 11 },  .{ .op = "-", .p = 11 }, .{ .op = "*", .p = 12 },  .{ .op = "/", .p = 12 },  .{ .op = "%", .p = 12 },
        .{ .op = "**", .p = 12 }, .{ .op = "^^", .p = 12 }, .{ .op = ":", .p = 13 },
    };
    for (table) |t| {
        if (std.mem.eql(u8, t.op, op)) return t.p;
    }
    return 11;
}

const unary_prec: u8 = 14;
const postfix_prec: u8 = 15;
const atom_prec: u8 = 99;

fn precOf(n: *G) u8 {
    return switch (n.k) {
        .bin => binPrec(n.op orelse ""),
        .assign => 1,
        .un => unary_prec,
        .post, .call, .member, .index, .brace, .callkw => postfix_prec,
        else => atom_prec,
    };
}

/// Every line is written as a newline and then its text, so the last line of whatever was written is still open: a trailing comment is
/// appended where it ends, and the file's first newline is the only one dropped at the end.
const Printer = struct {
    a: Alloc,
    out: std.ArrayListUnmanaged(u8) = .{},
    depth: u32 = 0,

    fn w(self: *Printer, s: []const u8) Alloc.Error!void {
        try self.out.appendSlice(self.a, s);
    }

    fn tabs(self: *Printer, d: u32) Alloc.Error!void {
        try self.out.appendNTimes(self.a, '\t', d);
    }

    fn line(self: *Printer, d: u32) Alloc.Error!void {
        try self.out.append(self.a, '\n');
        try self.tabs(d);
    }

    fn req(x: ?*G) Err!*G {
        return x orelse error.Shape;
    }

    fn e(self: *Printer, n: *G, d: u32) Err!void {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return tooDeep();
        switch (n.k) {
            .id, .num, .str, .sym => try self.w(n.text orelse return error.Shape),
            .self_ => try self.w(if (n.text != null) "self" else "This"),
            .super_ => try self.w("super"),
            .null_ => try self.w("NULL"),
            .bool_ => try self.w(if (n.bval) "true" else "false"),
            .paren => {
                try self.w("(");
                if (n.e) |x| try self.e(x, d);
                try self.w(")");
            },
            .assign => {
                try self.e(try req(n.l), d);
                try self.w(" ");
                try self.w(n.op orelse return error.Shape);
                try self.w(" ");
                try self.e(try req(n.r), d);
            },
            .bin => {
                const op = n.op orelse return error.Shape;
                const p = binPrec(op);
                try self.operand(try req(n.l), p, false, d);
                if (eq(op, ":")) {
                    try self.w(":");
                } else {
                    try self.w(" ");
                    try self.w(op);
                    try self.w(" ");
                }
                try self.operand(try req(n.r), p, true, d);
            },
            .un => {
                const op = n.op orelse return error.Shape;
                if (eq(op, "not")) {
                    try self.w("not ");
                    try self.operand(try req(n.e), unary_prec, false, d);
                } else {
                    try self.w(op);
                    const at = self.out.items.len;
                    try self.operand(try req(n.e), unary_prec, false, d);
                    if (op.len == 1 and (op[0] == '-' or op[0] == '+') and self.out.items.len > at and self.out.items[at] == op[0])
                        try self.out.insert(self.a, at, ' ');
                }
            },
            .post => {
                try self.operand(try req(n.e), postfix_prec, false, d);
                try self.w(n.op orelse return error.Shape);
            },
            .call => {
                try self.operand(try req(n.callee), postfix_prec, false, d);
                try self.w("(");
                try self.commaList(sl(n.args), d);
                try self.w(")");
            },
            .callkw => {
                try self.w("call ");
                if (n.items != null) try self.block(sl(n.items), d) else try self.e(try req(n.e), d);
            },
            .member => {
                try self.operand(try req(n.obj), postfix_prec, false, d);
                try self.w(".");
                try self.e(try req(n.prop), d);
            },
            .index => {
                try self.operand(try req(n.obj), postfix_prec, false, d);
                try self.w("[");
                try self.e(try req(n.idx), d);
                try self.w("]");
            },
            .brace => {
                try self.operand(try req(n.obj), postfix_prec, false, d);
                try self.w(" ");
                try self.block(sl(n.items), d);
            },
            .new => {
                try self.w("new ");
                if (n.from) try self.w("from ");
                try self.dotted(n.qname orelse &.{});
                if (n.args != null) {
                    try self.w("(");
                    try self.commaList(sl(n.args), d);
                    try self.w(")");
                } else if (n.items != null) {
                    try self.w(" ");
                    try self.block(sl(n.items), d);
                }
            },
            .lambda => {
                try self.w("func(");
                try self.paramList(sl(n.params));
                try self.w(") ");
                try self.block(sl(n.items), d);
            },
            .list => {
                try self.w("[");
                try self.commaList(sl(n.items), d);
                try self.w("]");
            },
            .pair => {
                try self.e(try req(n.key), d);
                try self.w(" = ");
                try self.e(try req(n.val), d);
            },
            else => {
                why = @tagName(n.k);
                return error.Unprintable;
            },
        }
    }

    fn commaList(self: *Printer, xs: []*G, d: u32) Err!void {
        for (xs, 0..) |x, i| {
            if (i > 0) try self.w(", ");
            try self.e(x, d);
        }
    }

    fn dotted(self: *Printer, names: []const []const u8) Alloc.Error!void {
        for (names, 0..) |s, i| {
            if (i > 0) try self.w(".");
            try self.w(s);
        }
    }

    /// An operand, parenthesized when its own precedence would let the text read as another graph (operators associate left).
    fn operand(self: *Printer, n: *G, parent_prec: u8, right: bool, d: u32) Err!void {
        const p = precOf(n);
        const wrap = p < parent_prec or (p == parent_prec and right and n.k == .bin);
        if (wrap) try self.w("(");
        try self.e(n, d);
        if (wrap) try self.w(")");
    }

    fn paramList(self: *Printer, ps: []*G) Err!void {
        for (ps, 0..) |p, i| {
            if (i > 0) try self.w(", ");
            if (p.ty) |t| {
                try self.w(t);
                try self.w(" ");
            }
            try self.w(p.name orelse return error.Shape);
        }
    }

    /// `{ ... }` with its statements one level in from d; the closing brace at d.
    fn block(self: *Printer, xs: []*G, d: u32) Err!void {
        try self.w("{");
        try self.items(xs, d + 1);
        try self.line(d);
        try self.w("}");
    }

    /// The lines of a list of items at depth d. A definition is set apart by a blank line; none is closed, because nothing closes one: `end`
    /// after a function is inert on Ring, and what follows a definition is its own (see `finish`).
    fn items(self: *Printer, xs: []*G, d: u32) Err!void {
        const flags = try self.a.alloc(bool, xs.len);
        @memset(flags, false);
        for (xs, 0..) |it, i| {
            if (!isDef(it.k)) continue;
            var j = i;
            while (j > 0 and xs[j - 1].k == .comment) j -= 1;
            if (j > 0) flags[j] = true;
            if (i + 1 < xs.len) flags[i + 1] = true;
        }
        for (xs, 0..) |it, i| {
            if (flags[i]) try self.w("\n");
            try self.item(it, d);
        }
    }

    fn item(self: *Printer, it: *G, d: u32) Err!void {
        if (it.k == .comment) {
            try self.line(d);
            try self.w(it.text orelse return error.Shape);
            return;
        }
        try self.stmt(it, d);
        if (it.trail) |t| {
            try self.w("  ");
            try self.w(t.text orelse return error.Shape);
        }
    }

    fn body(self: *Printer, xs: []*G, d: u32) Err!void {
        try self.items(xs, d + 1);
    }

    fn stmt(self: *Printer, it: *G, d: u32) Err!void {
        switch (it.k) {
            .expr => {
                try self.line(d);
                try self.e(try req(it.e), d);
            },
            .ret => {
                try self.line(d);
                if (it.e) |x| {
                    try self.w("return ");
                    if (it.amp) try self.w("& ");
                    try self.e(x, d);
                } else try self.w("return");
            },
            .say => {
                try self.line(d);
                try self.w("? ");
                try self.e(try req(it.e), d);
            },
            .see => {
                try self.line(d);
                try self.w("see ");
                try self.e(try req(it.e), d);
            },
            .give => {
                try self.line(d);
                try self.w("give ");
                try self.e(try req(it.e), d);
            },
            .exit, .loop => {
                try self.line(d);
                try self.w(if (it.k == .exit) "exit" else "loop");
                if (it.e) |x| {
                    try self.w(" ");
                    try self.e(x, d);
                }
            },
            .bye => {
                try self.line(d);
                try self.w("bye");
            },
            .scanner => {
                try self.line(d);
                try self.w(it.text orelse return error.Shape);
            },
            .load => {
                try self.line(d);
                try self.w("load ");
                if (it.op) |m| {
                    try self.w(m);
                    try self.w(" ");
                }
                try self.w((try req(it.path)).text orelse return error.Shape);
            },
            .import => {
                try self.line(d);
                try self.w("import ");
                try self.dotted(it.qname orelse &.{});
            },
            .private => {
                try self.line(d);
                try self.w("private");
            },
            .if_ => {
                try self.line(d);
                try self.w("if ");
                try self.e(try req(it.cond), d);
                try self.body(sl(it.then), d);
                for (sl(it.elifs)) |el| {
                    try self.line(d);
                    try self.w("but ");
                    try self.e(try req(el.cond), d);
                    try self.body(sl(el.items), d);
                }
                if (it.else_ != null) {
                    try self.line(d);
                    try self.w("else");
                    try self.body(sl(it.else_), d);
                }
                try self.line(d);
                try self.w("ok");
            },
            .while_ => {
                try self.line(d);
                try self.w("while ");
                try self.e(try req(it.cond), d);
                try self.body(sl(it.items), d);
                try self.line(d);
                try self.w("end");
            },
            .for_ => {
                try self.line(d);
                try self.w("for ");
                try self.w(it.name orelse return error.Shape);
                if (it.in_loop) {
                    try self.w(" in ");
                    try self.e(try req(it.a), d);
                } else {
                    try self.w(" = ");
                    try self.e(try req(it.a), d);
                    try self.w(" to ");
                    try self.e(try req(it.b), d);
                }
                if (it.step) |s| {
                    try self.w(" step ");
                    try self.e(s, d);
                }
                try self.body(sl(it.items), d);
                try self.line(d);
                try self.w("next");
            },
            .dowhile => {
                try self.line(d);
                try self.w("do");
                try self.body(sl(it.items), d);
                try self.line(d);
                try self.w("again ");
                try self.e(try req(it.cond), d);
            },
            .switch_ => {
                try self.line(d);
                try self.w("switch ");
                try self.e(try req(it.subject), d);
                for (sl(it.cases)) |c| {
                    try self.line(d + 1);
                    try self.w("on ");
                    try self.commaList(sl(c.values), d);
                    try self.items(sl(c.items), d + 2);
                }
                if (it.other != null) {
                    try self.line(d + 1);
                    try self.w("other");
                    try self.items(sl(it.other), d + 2);
                }
                try self.line(d);
                try self.w("off");
            },
            .try_ => {
                try self.line(d);
                try self.w("try");
                try self.body(sl(it.items), d);
                if (it.catch_) |c| {
                    try self.line(d);
                    try self.w("catch");
                    if (c.name) |b| {
                        try self.w("(");
                        try self.w(b);
                        try self.w(")");
                    }
                    try self.body(sl(c.items), d);
                }
                if (it.finally_ != null) {
                    try self.line(d);
                    try self.w("finally");
                    try self.body(sl(it.finally_), d);
                }
                try self.line(d);
                try self.w("done");
            },
            .func => {
                try self.line(d);
                try self.w("func ");
                try self.w(it.name orelse return error.Shape);
                try self.w("(");
                try self.paramList(sl(it.params));
                try self.w(")");
                try self.body(sl(it.items), d);
            },
            .class => {
                try self.line(d);
                try self.w("class ");
                try self.w(it.name orelse return error.Shape);
                if (it.parent) |p| {
                    try self.w(" from ");
                    try self.dotted(p);
                }
                try self.body(sl(it.items), d);
            },
            .package => {
                try self.line(d);
                try self.w("package ");
                try self.dotted(it.qname orelse &.{});
                try self.body(sl(it.items), d);
            },
            else => {
                why = @tagName(it.k);
                return error.Unprintable;
            },
        }
    }
};

// ---- the entry points --------------------------------------------------------------------------------------------------------------

/// The canonical text of `src`, or an error (and `why`). Null when the parser reports an error in the file: that is not a failure of this
/// formatter, it is a file that is not Ring yet.
pub fn format(a: Alloc, parser: ts.Parser, src: []const u8) Err!?[]const u8 {
    why = "";
    const tree = parser.parse(src) orelse {
        why = "the parser gave nothing";
        return null;
    };
    defer tree.deinit();
    const root = tree.root();
    if (root.hasError()) {
        why = "the parser reports an error in the file";
        return null;
    }
    const cn = try buildTree(a, root, 0);
    var ab = try Abs.init(a, parser, src);
    const g = try ab.file(cn);
    var p = Printer{ .a = a };
    try p.items(sl(g.items), 0);
    if (p.out.items.len == 0) return "";
    // the first newline is the one before the first line; every line has one before it, so the last has none, and the text ends with one
    try p.w("\n");
    return p.out.items[1..];
}

const Job = struct {
    alloc: Alloc,
    argv: []const []const u8,
    code: u8 = 1,
};

fn runJob(job: *Job) void {
    job.code = runIt(job.alloc, job.argv) catch |e| blk: {
        std.debug.print("rnxc fmt: {s}{s}{s}\n", .{ @errorName(e), if (why.len > 0) ": " else "", why });
        break :blk 1;
    };
}

fn usage() u8 {
    std.debug.print("usage: rnxc fmt <file.ring>              print the canonical text\n       rnxc fmt --write <file.ring>...   rewrite each file with it (replaced whole, or not at all)\n       rnxc fmt --check <file.ring>...   exit 1 if any file is not canonical\n", .{});
    return 2;
}

fn runIt(alloc: Alloc, argv: []const []const u8) !u8 {
    var write = false;
    var check = false;
    var paths = std.ArrayListUnmanaged([]const u8){};
    for (argv) |a| {
        if (eq(a, "--write")) write = true else if (eq(a, "--check")) check = true else try paths.append(alloc, a);
    }
    if (paths.items.len == 0 or (write and check)) return usage();
    if (paths.items.len > 1 and !write and !check) return usage(); // printing says nothing about which file a text came from
    const parser = ts.Parser.init();
    defer parser.deinit();
    var code: u8 = 0;
    for (paths.items) |p| {
        // an arena of its own per file: a tree of thousands of files must not keep every graph it has printed
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const fa = file_arena.allocator();
        const src = std.fs.cwd().readFileAlloc(fa, p, 256 << 20) catch |e| {
            std.debug.print("rnxc fmt: could not read {s} ({s})\n", .{ p, @errorName(e) });
            code = 1;
            continue;
        };
        const res = format(fa, parser, src) catch |e| {
            std.debug.print("rnxc fmt: {s}: {s}{s}{s}\n", .{ p, @errorName(e), if (why.len > 0) ": " else "", why });
            code = 1;
            continue;
        };
        const out = res orelse {
            std.debug.print("rnxc fmt: {s}: {s}; nothing printed\n", .{ p, why });
            code = 1;
            continue;
        };
        if (check) {
            if (!std.mem.eql(u8, out, src)) {
                std.debug.print("rnxc fmt: {s} is not canonical\n", .{p});
                code = 1;
            }
        } else if (write) {
            if (std.mem.eql(u8, out, src)) continue;
            // the whole new text beside the file, flushed, and then renamed over it: a power cut leaves the old file or the new one
            const tmp = try std.fmt.allocPrint(fa, "{s}.fmt-tmp", .{p});
            {
                const f = try std.fs.cwd().createFile(tmp, .{});
                defer f.close();
                try f.writeAll(out);
                try f.sync();
            }
            try std.fs.cwd().rename(tmp, p);
        } else {
            var buf: [64 * 1024]u8 = undefined;
            var wr = std.fs.File.stdout().writer(&buf);
            try wr.interface.writeAll(out);
            try wr.interface.flush();
        }
    }
    return code;
}

/// `rnxc fmt ...`. The work runs on a thread with a stack made for a chain of thousands of operands.
pub fn run(alloc: Alloc, argv: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var job = Job{ .alloc = arena.allocator(), .argv = argv };
    const t = std.Thread.spawn(.{ .stack_size = 512 << 20 }, runJob, .{&job}) catch {
        runJob(&job);
        return job.code;
    };
    _ = alloc;
    t.join();
    return job.code;
}
