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
    src_in: []const u8,
    defaults: *const DefaultsMap,
) !?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parser = ts.Parser.init();
    defer parser.deinit();
    const tree1 = parser.parse(src_in) orelse {
        try w.print("ringpp expand: {s} did not parse\n", .{path});
        return Refused.CacheRefused;
    };
    defer tree1.deinit();
    if (tree1.root().hasError()) {
        // The same NO VERDICT principle the checker applies: a file whose
        // shape is uncertain is not one to rewrite.
        try w.print("ringpp expand: {s} did not parse cleanly -- refusing to rewrite it\n", .{path});
        return Refused.CacheRefused;
    }

    // PASS 1 -- defaults: rewrite short call sites. The text changes, so
    // the cache pass re-parses; every offset from tree1 is stale after this.
    var src: []const u8 = src_in;
    var owned: ?[]u8 = null;
    if (try applyDefaults(gpa, w, path, tree1.root(), src_in, defaults)) |t| {
        owned = t;
        src = t;
    }
    var tree2: ?ts.Tree = null;
    defer if (tree2) |t| t.deinit();
    var root = tree1.root();
    if (owned != null) {
        tree2 = parser.parse(src) orelse {
            try w.print("ringpp expand: {s}: the default-parameter rewrite produced text that does not parse -- a ringpp bug, please report it\n", .{path});
            return Refused.CacheRefused;
        };
        root = tree2.?.root();
    }

    // PASS 2 -- cache
    var anchors = std.AutoHashMap(u32, []const u8).init(arena);
    try collectAnchors(root, &anchors);
    var any_cache = false;
    var it = anchors.valueIterator();
    while (it.next()) |v| {
        if (std.mem.eql(u8, v.*, "cache")) any_cache = true;
    }
    if (!any_cache) return owned;

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

    if (n_done == 0) {
        out.deinit(gpa);
        return owned;
    }
    const result = try out.toOwnedSlice(gpa);
    if (owned) |o| gpa.free(o);
    return result;
}

/// `ringpp cache <file>` -- print the transform, write nothing.
pub fn run(gpa: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const src = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024) catch {
        try w.print("ringpp cache: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(src);
    // A single file can only honour defaults it DECLARES; one declared in
    // a file it loads is invisible here. `ringpp build` sees the closure.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var defaults = DefaultsMap.init(arena_state.allocator());
    {
        const parser = ts.Parser.init();
        defer parser.deinit();
        if (parser.parse(src)) |t| {
            defer t.deinit();
            if (!t.root().hasError()) try collectDefaults(arena_state.allocator(), t.root(), &defaults);
        }
    }
    const out = transform(gpa, w, path, src, &defaults) catch return 1;
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
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var defaults = DefaultsMap.init(arena_state.allocator());
    {
        const parser = ts.Parser.init();
        defer parser.deinit();
        for (files) |f| {
            const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
            defer gpa.free(src);
            if (std.mem.indexOf(u8, src, "#rpp:") == null) continue;
            any = true;
            // pass 1: every default declared ANYWHERE in the closure, before
            // any file is rewritten -- the call and the declaration are
            // usually in different files
            if (parser.parse(src)) |t| {
                defer t.deinit();
                if (!t.root().hasError()) try collectDefaults(arena_state.allocator(), t.root(), &defaults);
            }
        }
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
        const out = transform(gpa, w, f, src, &defaults) catch return Refused.CacheRefused;
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

// ------------------------------------------------------------ defaults
//
// `func F(a, b, c)   #rpp: default b = 2, c = "x"`
//
// Ring has strict arity: no overloading, no defaults, and a same-named
// second definition is C22 at load time. So the DECLARATION cannot change.
// What changes is every CALL SITE with fewer arguments than parameters --
// `F(1)` becomes `F(1, 2, "x")` -- which is only possible because
// `ringpp build` stages the whole load closure and can see every call the
// program will ever make. The declarations are collected over ALL files
// first, then each file is rewritten; a call in app.ring to a function
// declared in lib.ring is the ordinary case, not the edge.

pub const Alias = struct { name: []const u8, slot: usize };
pub const FnDefaults = struct {
    nparams: usize,
    by_pos: []const []const u8,
    params: []const []const u8,
    /// Readable keywords a caller may use instead of the parameter's own
    /// name: `#rpp: named pcReturnType as ReturnedAs, ReturnAs`.
    ///
    /// Softanza's own idiom is exactly this and NOT the parameter name --
    /// measured over its library, the keywords are :ReturnedAs (81 sites),
    /// :Using (47), :Of (45), :Sections (45) -- decorative English chosen
    /// for how the call READS, with several aliases per parameter. Keying
    /// only on the parameter's own name would have made every such call
    /// read worse than the hand-written unwrapping it replaced.
    aliases: []const Alias,
};
pub const DefaultsMap = std.StringHashMap(FnDefaults);

/// Pass 1: every function in this tree that carries a `default` anchor.
pub fn collectDefaults(arena: std.mem.Allocator, root: ts.Node, map: *DefaultsMap) !void {
    var anchors = std.AutoHashMap(u32, []const u8).init(arena);
    try collectAnchors(root, &anchors);
    try collectDefaultsIn(arena, root, &anchors, map);
}

fn collectDefaultsIn(arena: std.mem.Allocator, n: ts.Node, anchors: *const std.AutoHashMap(u32, []const u8), map: *DefaultsMap) !void {
    if (std.mem.eql(u8, n.kind(), "function_definition")) {
        const row = n.start().row;
        const verb = anchors.get(row) orelse (if (row > 0) anchors.get(row - 1) else null);
        if (verb) |v| {
            // `#rpp: named` opts a function in with NO defaults: its callers may
            // use :name = value. Opt-in is not optional -- a function written to
            // RECEIVE the [name, value] pair Ring passes for :name = value (every
            // one of Softanza\'s 215 unwrap sites) would break if its calls were
            // made positional behind its back.
            const is_named = std.mem.startsWith(u8, v, "named");
            if (is_named or std.mem.startsWith(u8, v, "default")) {
                const name_node = n.field("name");
                if (!name_node.isNull()) {
                    var params = std.ArrayList([]const u8){};
                    try paramsOf(arena, n, &params);
                    var defs = std.ArrayList(types.DefaultArg){};
                    var alias_list = std.ArrayList(Alias){};
                    const body = if (is_named)
                        std.mem.trim(u8, v["named".len..], " \t")
                    else
                        std.mem.trim(u8, v["default".len..], " \t");
                    // `X as A, B` declares aliases; `X = expr` declares a
                    // default. One anchor may carry either.
                    if (std.mem.indexOf(u8, body, " as ")) |_| {
                        try parseAliases(arena, body, params.items, &alias_list);
                    } else if (!is_named) {
                        try types.parseDefaults(arena, body, &defs);
                    }
                    const by_pos = try arena.alloc([]const u8, params.items.len);
                    for (params.items, 0..) |pn, k| {
                        by_pos[k] = "";
                        for (defs.items) |d| {
                            // DUPE, do not slice. d.expr points into the file text,
                            // and in stageClosure that text is freed at the end of
                            // its loop iteration -- the map outlives it, and the
                            // first version wrote seven bytes of garbage into a call.
                            if (std.ascii.eqlIgnoreCase(pn, d.name)) by_pos[k] = try arena.dupe(u8, d.expr);
                        }
                    }
                    const key = try std.ascii.allocLowerString(arena, name_node.text());
                    const pnames = try arena.alloc([]const u8, params.items.len);
                    for (params.items, 0..) |pn, k| pnames[k] = try arena.dupe(u8, pn);
                    try map.put(key, .{ .nparams = params.items.len, .by_pos = by_pos, .params = pnames, .aliases = try alias_list.toOwnedSlice(arena) });
                }
            }
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectDefaultsIn(arena, n.child(i), anchors, map);
}


/// `pcReturnType as ReturnedAs, ReturnAs` -- one parameter, several readable
/// keywords. Several such clauses may be separated by ';'.
fn parseAliases(arena: std.mem.Allocator, body: []const u8, params: []const []const u8, out: *std.ArrayList(Alias)) !void {
    var clauses = std.mem.splitScalar(u8, body, ';');
    while (clauses.next()) |raw| {
        const clause = std.mem.trim(u8, raw, " \t");
        if (clause.len == 0) continue;
        const at = std.mem.indexOf(u8, clause, " as ") orelse continue;
        const pname = std.mem.trim(u8, clause[0..at], " \t");
        var slot: ?usize = null;
        for (params, 0..) |pn, pi| {
            if (std.ascii.eqlIgnoreCase(pn, pname)) slot = pi;
        }
        const si = slot orelse continue;
        var names = std.mem.splitScalar(u8, clause[at + 4 ..], ',');
        while (names.next()) |nraw| {
            const a = std.mem.trim(u8, nraw, " \t:");
            if (a.len == 0) continue;
            try out.append(arena, .{ .name = try std.ascii.allocLowerString(arena, a), .slot = si });
        }
    }
}
/// Does the tree contain a dynamic `call x(...)`? Such a call resolves its
/// target at run time, so no call-site rewrite can reach it -- a program
/// that uses one cannot have defaults honoured soundly, and is refused
/// rather than half-served.
fn hasDynamicCall(n: ts.Node) bool {
    if (std.mem.eql(u8, n.kind(), "call_keyword_expression")) return true;
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) if (hasDynamicCall(n.child(i))) return true;
    return false;
}

/// The `arguments` node of a call, found by KIND. It is not a grammar field
/// -- field("arguments") is always null -- and it is optional, so a
/// zero-argument call has none at all. The first draft asked for the field,
/// found nothing on every call, and rewrote nothing while reporting success.
fn argsOf(call: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (i < call.namedChildCount()) : (i += 1) {
        const c = call.namedChild(i);
        if (std.mem.eql(u8, c.kind(), "arguments")) return c;
    }
    return null;
}
/// A named argument in a call: `:name = expr`. Ring parses it as a
/// binary_expression whose left side is a symbol -- and at run time passes
/// the PAIR [name, expr] in whatever position it sits, which is why this
/// has to be rewritten rather than left to Ring.
const NamedArg = struct { name: []const u8, expr: []const u8 };

fn namedArgOf(n: ts.Node) ?NamedArg {
    if (!std.mem.eql(u8, n.kind(), "binary_expression")) return null;
    if (n.namedChildCount() < 2 or n.childCount() < 3) return null;
    const lhs = n.namedChild(0);
    if (!std.mem.eql(u8, lhs.kind(), "symbol")) return null;
    if (!std.mem.eql(u8, n.child(1).text(), "=")) return null;
    if (lhs.namedChildCount() < 1) return null;
    return .{ .name = lhs.namedChild(0).text(), .expr = n.namedChild(1).text() };
}

/// Pass 2: rewrite every call to an opted-in function that is SHORT or
/// uses a NAMED argument, into a full positional call. Returns null when
/// nothing changed. Splices by byte in source order.
///
/// Placement is by SLOT. Positional arguments fill slots in order; a named
/// one goes to its parameter's slot; every slot still empty is filled from
/// the defaults. Four things are refused, each a wrong program that Ring
/// would otherwise accept and misrun: a positional argument after a named
/// one, a name that is not a parameter, a slot filled twice, and a slot
/// with neither an argument nor a default.
pub fn applyDefaults(gpa: std.mem.Allocator, w: anytype, path: []const u8, root: ts.Node, src: []const u8, map: *const DefaultsMap) !?[]u8 {
    if (map.count() == 0) return null;
    // A dynamic `call x(...)` cannot be rewritten -- its target is a string
    // decided at run time. This used to REFUSE the file, and that was too
    // strong: measured on 1.27, a dynamic short call raises R19 loudly, which
    // is exactly the behaviour that existed before the feature. It does not
    // produce a wrong answer.
    //
    // So the two anchors part company here, and the rule is the project's own:
    // REFUSE what is silently wrong, WARN what is loudly incomplete. A bad
    // cache key returns the first call's answer forever with nothing raised;
    // a default that misses a dynamic call raises R19 at that call, as it
    // always did. Refusing it cost every program that uses `call` anywhere --
    // 49 files in Softanza's library alone -- the whole feature.
    if (hasDynamicCall(root)) {
        try w.print("ringpp expand: {s}: note -- this file uses `call x(...)`; a default or named argument cannot be filled in at a call whose target is chosen at run time, and such a call still raises R19 exactly as it does today. Every other call in the file is rewritten.\n", .{path});
    }
    var sites = std.ArrayList(ts.Node){};
    defer sites.deinit(gpa);
    try collectRewritableCalls(gpa, root, map, &sites);
    if (sites.items.len == 0) return null;

    var out = std.ArrayList(u8){};
    errdefer out.deinit(gpa);
    var cursor: usize = 0;
    for (sites.items) |call| {
        const name_node = call.child(0);
        const key = try std.ascii.allocLowerString(gpa, name_node.text());
        defer gpa.free(key);
        const fd = map.get(key) orelse continue;
        const row = call.start().row + 1;

        const slots = try gpa.alloc([]const u8, fd.nparams);
        defer gpa.free(slots);
        for (slots) |*sl| sl.* = "";
        var seen_named = false;
        var pos: usize = 0;
        if (argsOf(call)) |args| {
            var ai: u32 = 0;
            while (ai < args.namedChildCount()) : (ai += 1) {
                const a = args.namedChild(ai);
                if (namedArgOf(a)) |na| {
                    seen_named = true;
                    var slot: ?usize = null;
                    for (fd.params, 0..) |pn, pi| {
                        if (std.ascii.eqlIgnoreCase(pn, na.name)) slot = pi;
                    }
                    // a declared keyword alias resolves to the same slot
                    if (slot == null) {
                        for (fd.aliases) |al| {
                            if (std.ascii.eqlIgnoreCase(al.name, na.name)) slot = al.slot;
                        }
                    }
                    const si = slot orelse {
                        try w.print("ringpp expand: {s}:{d}: refusing -- :{s} is not a parameter of {s}()\n", .{ path, row, na.name, name_node.text() });
                        return Refused.CacheRefused;
                    };
                    if (slots[si].len > 0) {
                        try w.print("ringpp expand: {s}:{d}: refusing -- {s}() gets its {s} twice\n", .{ path, row, name_node.text(), na.name });
                        return Refused.CacheRefused;
                    }
                    slots[si] = na.expr;
                } else {
                    if (seen_named) {
                        try w.print("ringpp expand: {s}:{d}: refusing -- a positional argument after a named one has no position to go to\n", .{ path, row });
                        return Refused.CacheRefused;
                    }
                    if (pos >= fd.nparams) {
                        // more positional arguments than parameters: Ring's
                        // own R20 says it better than this tool can
                        pos += 1;
                        continue;
                    }
                    slots[pos] = a.text();
                    pos += 1;
                }
            }
        }
        for (slots, 0..) |*sl, si| {
            if (sl.*.len == 0) {
                if (fd.by_pos[si].len == 0) {
                    try w.print("ringpp expand: {s}:{d}: refusing -- {s}() is missing {s}, which has no default\n", .{ path, row, name_node.text(), fd.params[si] });
                    return Refused.CacheRefused;
                }
                sl.* = fd.by_pos[si];
            }
        }

        // replace everything after the callee name with the rebuilt list
        const after_name: usize = name_node.startByte() + name_node.text().len;
        const call_end: usize = call.startByte() + call.text().len;
        try out.appendSlice(gpa, src[cursor..after_name]);
        try out.appendSlice(gpa, "(");
        for (slots, 0..) |sl, si| {
            if (si > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, sl);
        }
        try out.appendSlice(gpa, ")");
        cursor = call_end;
    }
    try out.appendSlice(gpa, src[cursor..]);
    return try out.toOwnedSlice(gpa);
}

/// Every call to an opted-in function that is short OR carries a named
/// argument, in source order. A complete positional call is left exactly
/// as written -- the output must not churn code that needed nothing.
fn collectRewritableCalls(gpa: std.mem.Allocator, n: ts.Node, map: *const DefaultsMap, out: *std.ArrayList(ts.Node)) !void {
    if (std.mem.eql(u8, n.kind(), "call_expression") and n.childCount() > 0) {
        const head = n.child(0);
        if (std.mem.eql(u8, head.kind(), "identifier")) {
            const key = try std.ascii.allocLowerString(gpa, head.text());
            defer gpa.free(key);
            if (map.get(key)) |fd| {
                var given: usize = 0;
                var any_named = false;
                if (argsOf(n)) |args| {
                    given = args.namedChildCount();
                    var ai: u32 = 0;
                    while (ai < args.namedChildCount()) : (ai += 1) {
                        if (namedArgOf(args.namedChild(ai)) != null) any_named = true;
                    }
                }
                if (any_named or given < fd.nparams) try out.append(gpa, n);
            }
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectRewritableCalls(gpa, n.child(i), map, out);
}
