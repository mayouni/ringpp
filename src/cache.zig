//! `ringpp cache <file>` — the source transform behind `#rpp: cache`.
//!
//! WHY A TRANSFORM AND NOT A RUNTIME WRAPPER. Ring refuses to redefine an
//! existing function: `eval("func F() ...")` on an F that already exists is
//! C22, "Function redefinition", at load time. Verified on 1.27. So a cache
//! can never be installed around F while the program runs — the wrapper has
//! to exist in the source before Ring reads it. That is this file.
//!
//! WHAT IT EMITS. The body moves to `F__rpp_impl` and `F` becomes a wrapper:
//!
//!     func F(a, b)
//!         _kRpp_ = "F" + char(31) + RppK(a) + char(31) + RppK(b)
//!         _hRpp_ = RppMemoGet(_kRpp_)
//!         if isList(_hRpp_) return _hRpp_[1] ok
//!         return RppMemoPut(_kRpp_, F__rpp_impl(a, b))
//!
//!     func F__rpp_impl(a, b)
//!         <the original body>
//!
//! Recursive calls inside the body still name F, so they re-enter the
//! WRAPPER. That is not incidental: it is what turns exponential fib into
//! linear, and it is the reason the impl is renamed rather than the caller.
//!
//! IT WRITES NOTHING. The transformed source goes to stdout, so the result
//! is inspectable and redirectable, and a mistake costs a re-run rather than
//! a file. Wiring it into `ringpp build` is a separate decision.

const std = @import("std");
const ts = @import("ts.zig");
const types = @import("types.zig");

fn collectAnchors(n: ts.Node, out: *std.AutoHashMap(u32, []const u8)) !void {
    if (std.mem.eql(u8, n.kind(), "comment")) {
        const t = n.text();
        if (std.mem.startsWith(u8, t, "#rpp:")) {
            try out.put(n.start().row, std.mem.trim(u8, t[5..], " \t"));
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectAnchors(n.child(i), out);
}

/// The parameter names of a function_definition, in order.
fn paramsOf(arena: std.mem.Allocator, fn_node: ts.Node, out: *std.ArrayList([]const u8)) !void {
    var i: u32 = 0;
    while (i < fn_node.childCount()) : (i += 1) {
        const c = fn_node.child(i);
        if (!std.mem.eql(u8, c.kind(), "param_list")) continue;
        var j: u32 = 0;
        while (j < c.namedChildCount()) : (j += 1) {
            const pnode = c.namedChild(j);
            if (std.mem.eql(u8, pnode.kind(), "identifier"))
                try out.append(arena, pnode.text());
        }
        return;
    }
}

/// The transformed text of `src`, or null when the file has no `#rpp:`
/// cache anchor to act on. Refusals are printed and reported as an error
/// so that a build stops rather than quietly shipping an uncached binary.
pub const Refused = error{CacheRefused};

pub fn transform(
    gpa: std.mem.Allocator,
    w: anytype,
    path: []const u8,
    src: []const u8,
) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parser = ts.Parser.init();
    defer parser.deinit();
    const tree = parser.parse(src) orelse {
        try w.print("ringpp cache: {s} did not parse\n", .{path});
        return Refused.CacheRefused;
    };
    defer tree.deinit();
    const root = tree.root();
    if (root.hasError()) {
        // The same NO VERDICT principle the checker applies: a file whose
        // shape is uncertain is not one to rewrite.
        try w.print("ringpp cache: {s} did not parse cleanly -- refusing to rewrite it\n", .{path});
        return Refused.CacheRefused;
    }

    var anchors = std.AutoHashMap(u32, []const u8).init(arena);
    try collectAnchors(root, &anchors);
    if (anchors.count() == 0) return null;

    // The row of the first class: every func at or after it is a METHOD
    // (F-21), and a method is not transformed. Its key would have to carry
    // the object's identity and its purity would have to account for
    // attributes, neither of which is settled -- so it is refused by name
    // rather than transformed on a guess.
    var first_class_row: u32 = std.math.maxInt(u32);
    var ci: u32 = 0;
    while (ci < root.childCount()) : (ci += 1) {
        const c = root.child(ci);
        if (std.mem.eql(u8, c.kind(), "class_definition") or
            std.mem.eql(u8, c.kind(), "class_statement"))
        {
            first_class_row = c.start().row;
            break;
        }
    }

    var out = std.ArrayList(u8){};
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    var n_done: usize = 0;

    // Source order matters: `cursor` only ever moves forward, so root
    // children are walked in order and a class is descended into where it
    // sits. Methods are children of the CLASS node, not of the file -- the
    // first version looped over root only and never saw one.
    var i: u32 = 0;
    while (i < root.childCount()) : (i += 1) {
        const top = root.child(i);
        const tk = top.kind();
        if (std.mem.eql(u8, tk, "class_definition") or std.mem.eql(u8, tk, "class_statement")) {
            var j: u32 = 0;
            while (j < top.childCount()) : (j += 1) {
                if (!std.mem.eql(u8, top.child(j).kind(), "function_definition")) continue;
                if (try emitOne(gpa, w, arena, src, root, top, j, &anchors, &out, &cursor, first_class_row)) n_done += 1;
            }
            continue;
        }
        if (!std.mem.eql(u8, tk, "function_definition")) continue;
        if (try emitOne(gpa, w, arena, src, root, root, i, &anchors, &out, &cursor, first_class_row)) n_done += 1;
    }
    try out.appendSlice(gpa, src[cursor..]);

    if (n_done == 0) return null;
    return try out.toOwnedSlice(gpa);
}

/// `ringpp cache <file>` -- print the transform, write nothing.
pub fn run(gpa: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const src = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024) catch {
        try w.print("ringpp cache: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(src);
    const out = transform(gpa, w, path, src) catch return 1;
    if (out) |t| {
        defer gpa.free(t);
        try w.print("{s}", .{t});
    } else try w.print("{s}", .{src});
    return 0;
}

/// Mirror a program's load closure into `stage_dir`, transforming every
/// file that carries a `#rpp: cache` anchor, and return the staged entry.
/// Returns null when no file in the closure carries one -- the caller then
/// builds the originals and nothing has been copied.
///
/// THE LAYOUT IS THE WHOLE DESIGN. Files are mirrored by ABSOLUTE path with
/// the drive and leading separator folded away, so a closure spread over
/// several directories keeps every relative offset it had. `load "../x.ring"`
/// in a staged file resolves to the staged ../x.ring. Flattening the
/// closure, or staging only the annotated files, would silently break
/// exactly those loads.
///
/// The user's own tree is never written to. That was the alternative --
/// transform in place, compile, restore -- and it is a build that edits the
/// files you are editing, which is not a trade worth taking for a shorter
/// implementation.
pub fn stageClosure(
    gpa: std.mem.Allocator,
    w: anytype,
    files: []const []const u8,
    entry: []const u8,
    stage_dir: []const u8,
    runtime_src: ?[]const u8,
) !?[]const u8 {
    var any = false;
    for (files) |f| {
        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        if (std.mem.indexOf(u8, src, "#rpp:") != null) { any = true; break; }
    }
    if (!any) return null;

    var staged_entry: ?[]const u8 = null;
    for (files) |f| {
        const abs = std.fs.cwd().realpathAlloc(gpa, f) catch continue;
        defer gpa.free(abs);
        const rel = mirrorRel(abs);
        const dest = try std.fs.path.join(gpa, &.{ stage_dir, rel });
        if (std.fs.path.dirname(dest)) |d| std.fs.cwd().makePath(d) catch {};

        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        const out = transform(gpa, w, f, src) catch return Refused.CacheRefused;
        if (out) |t| {
            defer gpa.free(t);
            try std.fs.cwd().writeFile(.{ .sub_path = dest, .data = t });
        } else {
            try std.fs.cwd().writeFile(.{ .sub_path = dest, .data = src });
        }

        const abs_entry = std.fs.cwd().realpathAlloc(gpa, entry) catch continue;
        defer gpa.free(abs_entry);
        if (std.mem.eql(u8, abs, abs_entry)) staged_entry = dest else gpa.free(dest);
    }

    const se = staged_entry orelse {
        try w.print("ringpp build: could not stage the entry point for #rpp: cache\n", .{});
        return Refused.CacheRefused;
    };

    // The generated wrappers call RppMemoGet/RppMemoPut/RppK, so the store
    // has to be loaded before them. It is copied beside the staged entry and
    // loaded by bare name, which is the one path that cannot go wrong
    // wherever the entry itself ended up in the mirror.
    if (runtime_src) |rt| {
        const rt_bytes = std.fs.cwd().readFileAlloc(gpa, rt, 8 * 1024 * 1024) catch {
            try w.print("ringpp build: cannot read the cache runtime at {s}\n", .{rt});
            return Refused.CacheRefused;
        };
        defer gpa.free(rt_bytes);
        const dir = std.fs.path.dirname(se) orelse stage_dir;
        const rt_dest = try std.fs.path.join(gpa, &.{ dir, "rpp_memo.ring" });
        defer gpa.free(rt_dest);
        try std.fs.cwd().writeFile(.{ .sub_path = rt_dest, .data = rt_bytes });

        const entry_src = try std.fs.cwd().readFileAlloc(gpa, se, 64 * 1024 * 1024);
        defer gpa.free(entry_src);
        var joined = std.ArrayList(u8){};
        defer joined.deinit(gpa);
        try joined.appendSlice(gpa, "load \"rpp_memo.ring\"\n");
        try joined.appendSlice(gpa, entry_src);
        try std.fs.cwd().writeFile(.{ .sub_path = se, .data = joined.items });
    }
    return se;
}

/// An absolute path as a mirror-relative one: drive letter and colon gone,
/// leading separators gone, separators normalised.
fn mirrorRel(abs: []const u8) []const u8 {
    var i: usize = 0;
    if (abs.len > 2 and abs[1] == ':') i = 2;
    while (i < abs.len and (abs[i] == '/' or abs[i] == '\\')) i += 1;
    return abs[i..];
}

/// The class_definition that encloses `row`, if any.
fn enclosingClass(root: ts.Node, row: u32) ?ts.Node {
    var found: ?ts.Node = null;
    var i: u32 = 0;
    while (i < root.childCount()) : (i += 1) {
        const c = root.child(i);
        const k = c.kind();
        if ((std.mem.eql(u8, k, "class_definition") or std.mem.eql(u8, k, "class_statement")) and c.start().row <= row) found = c;
    }
    return found;
}

/// Does the method starting at child `idx` read object state anywhere in
/// its SPAN? A method body is not a subtree inside a class -- the grammar
/// keeps only the first statement and emits the rest as siblings -- so the
/// span is the node plus every following sibling up to the next method or
/// class. Checking the subtree alone would clear a method on the strength
/// of its first line.
fn readsStateInSpan(
    arena: std.mem.Allocator,
    parent: ts.Node,
    idx: u32,
    attrs: *const std.StringHashMap(void),
) ?[]const u8 {
    var j: u32 = idx;
    while (j < parent.childCount()) : (j += 1) {
        const c = parent.child(j);
        if (j > idx) {
            const k = c.kind();
            if (std.mem.eql(u8, k, "function_definition") or
                std.mem.eql(u8, k, "class_definition") or
                std.mem.eql(u8, k, "class_statement")) break;
        }
        if (types.readsObjectState(arena, c, attrs)) |r| return r;
    }
    return null;
}

/// Emit one anchored function or method. Returns true when it rewrote one.
///
/// `parent` is the file for a function and the CLASS for a method, because
/// a method's body is not its subtree: inside a class the grammar keeps
/// only the first statement under function_definition and emits the rest as
/// siblings. So the impl is taken from the whole SPAN -- the node plus every
/// following sibling up to the next method or class.
fn emitOne(
    gpa: std.mem.Allocator,
    w: anytype,
    arena: std.mem.Allocator,
    src: []const u8,
    root: ts.Node,
    parent: ts.Node,
    idx: u32,
    anchors: *const std.AutoHashMap(u32, []const u8),
    out: *std.ArrayList(u8),
    cursor: *usize,
    first_class_row: u32,
) !bool {
    const fn_node = parent.child(idx);
    const row = fn_node.start().row;
    // FINDINGS F-21 and the grammar's own inconsistency: a function after the
    // first class is a METHOD whether or not the tree nested it there. Asking
    // the parent node gets this wrong on any file that has functions before
    // its first class, which is most of them.
    const is_method = row >= first_class_row;
    const verb = anchors.get(row) orelse
        (if (row > 0) anchors.get(row - 1) else null) orelse return false;
    if (!std.mem.eql(u8, verb, "cache")) return false;

    // ONE byte range for everything below. Sibling-walking cannot find a
    // method's body: the grammar emits it as a sibling of the class, and at
    // the end of a file as a sibling of the FILE, escaping the class node
    // entirely. The extent is bytes, ending where the next definition starts.
    const start: usize = fn_node.startByte();
    const end: usize = types.nextDefBoundary(root, start, src.len);

    if (is_method) {
        var attrs = std.StringHashMap(void).init(arena);
        if (enclosingClass(root, row)) |cls| try types.classAttrs(arena, cls, &attrs);
        if (types.readsObjectStateInRange(arena, root, start, end, &attrs)) |what| {
            try w.print("ringpp cache: {d}: refusing -- the method reads {s}, and an object cannot be part of a cache key: list2str() returns the empty string for every object, so all instances would share one entry\n", .{ row + 1, what });
            return Refused.CacheRefused;
        }
    }

    // impurity over the whole span, for the same reason
    {
        var j: u32 = idx;
        while (j < parent.childCount()) : (j += 1) {
            const c = parent.child(j);
            if (j > idx and isBoundary(c)) break;
            if (types.impurityOf(arena, c)) |imp| {
                try w.print("ringpp cache: {d}: refusing -- it {s}\n", .{ row + 1, imp.why });
                return Refused.CacheRefused;
            }
        }
    }

    const name_node = fn_node.field("name");
    if (name_node.isNull()) return false;
    const name = name_node.text();

    var params = std.ArrayList([]const u8){};
    try paramsOf(arena, fn_node, &params);

    const kw = if (is_method) "def" else "func";
    const ind = if (is_method) "\t" else "";

    try out.appendSlice(gpa, src[cursor.*..start]);
    try out.writer(gpa).print("{s} {s}(", .{ kw, name });
    for (params.items, 0..) |pn, k| {
        if (k > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, pn);
    }
    try out.appendSlice(gpa, ")\n");
    try out.writer(gpa).print("{s}\t_kRpp_ = \"{s}\"", .{ ind, name });
    for (params.items) |pn| try out.writer(gpa).print(" + char(31) + RppK({s})", .{pn});
    try out.writer(gpa).print("\n{s}\t_hRpp_ = RppMemoGet(_kRpp_)\n", .{ind});
    try out.writer(gpa).print("{s}\tif isList(_hRpp_) return _hRpp_[1] ok\n", .{ind});
    try out.writer(gpa).print("{s}\treturn RppMemoPut(_kRpp_, {s}__rpp_impl(", .{ ind, name });
    for (params.items, 0..) |pn, k| {
        if (k > 0) try out.appendSlice(gpa, ", ");
        try out.appendSlice(gpa, pn);
    }
    try out.appendSlice(gpa, "))\n\n");
    try out.writer(gpa).print("{s}{s} {s}__rpp_impl", .{ ind, kw, name });
    // The anchor must not travel onto the impl. In the same-line form it
    // sits between the name and the body, and leaving it there would make a
    // second `ringpp cache` wrap the wrapper.
    var after_name = name_node.startByte() + name.len;
    {
        const line_end = std.mem.indexOfScalarPos(u8, src, after_name, '\n') orelse src.len;
        if (std.mem.indexOfPos(u8, src[0..line_end], after_name, "#rpp:")) |a| {
            try out.appendSlice(gpa, src[after_name..a]);
            after_name = line_end;
        }
    }
    try out.appendSlice(gpa, src[after_name..end]);
    cursor.* = end;
    return true;
}

fn isBoundary(n: ts.Node) bool {
    const k = n.kind();
    return std.mem.eql(u8, k, "function_definition") or
        std.mem.eql(u8, k, "class_definition") or
        std.mem.eql(u8, k, "class_statement");
}
