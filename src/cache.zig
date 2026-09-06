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

pub fn run(gpa: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const src = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024 * 1024) catch {
        try w.print("ringpp cache: cannot read {s}\n", .{path});
        return 1;
    };
    defer gpa.free(src);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parser = ts.Parser.init();
    defer parser.deinit();
    const tree = parser.parse(src) orelse {
        try w.print("ringpp cache: {s} did not parse\n", .{path});
        return 1;
    };
    defer tree.deinit();
    const root = tree.root();
    if (root.hasError()) {
        // The same NO VERDICT principle the checker applies: a file whose
        // shape is uncertain is not one to rewrite.
        try w.print("ringpp cache: {s} did not parse cleanly -- refusing to rewrite it\n", .{path});
        return 1;
    }

    var anchors = std.AutoHashMap(u32, []const u8).init(arena);
    try collectAnchors(root, &anchors);
    if (anchors.count() == 0) {
        try w.print("{s}", .{src});
        return 0;
    }

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
    defer out.deinit(gpa);
    var cursor: usize = 0;
    var n_done: usize = 0;

    var i: u32 = 0;
    while (i < root.childCount()) : (i += 1) {
        const fn_node = root.child(i);
        if (!std.mem.eql(u8, fn_node.kind(), "function_definition")) continue;
        const row = fn_node.start().row;
        const verb = anchors.get(row) orelse
            (if (row > 0) anchors.get(row - 1) else null) orelse continue;
        if (!std.mem.eql(u8, verb, "cache")) continue;

        if (row >= first_class_row) {
            try w.print("ringpp cache: {s}:{d}: #rpp: cache on a method is not supported yet -- a method's key would have to carry the object's identity\n", .{ path, row + 1 });
            return 1;
        }
        if (types.impurityOf(arena, fn_node)) |imp| {
            try w.print("ringpp cache: {s}:{d}: refusing -- the function {s}\n", .{ path, row + 1, imp.why });
            return 1;
        }

        // child() walks ANONYMOUS nodes too, so child(0) is the `func`
        // keyword and not the name. The first draft of this read child(0),
        // found a keyword, and silently emitted the file unchanged.
        const name_node = fn_node.field("name");
        if (name_node.isNull()) continue;
        const name = name_node.text();

        var params = std.ArrayList([]const u8){};
        try paramsOf(arena, fn_node, &params);

        const start: usize = fn_node.startByte();
        const end: usize = start + fn_node.text().len;

        try out.appendSlice(gpa, src[cursor..start]);

        // the wrapper
        try out.writer(gpa).print("func {s}(", .{name});
        for (params.items, 0..) |pname, k| {
            if (k > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, pname);
        }
        try out.appendSlice(gpa, ")\n");
        try out.writer(gpa).print("\t_kRpp_ = \"{s}\"", .{name});
        for (params.items) |pname| {
            try out.writer(gpa).print(" + char(31) + RppK({s})", .{pname});
        }
        try out.appendSlice(gpa, "\n\t_hRpp_ = RppMemoGet(_kRpp_)\n");
        try out.appendSlice(gpa, "\tif isList(_hRpp_) return _hRpp_[1] ok\n");
        try out.writer(gpa).print("\treturn RppMemoPut(_kRpp_, {s}__rpp_impl(", .{name});
        for (params.items, 0..) |pname, k| {
            if (k > 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, pname);
        }
        try out.appendSlice(gpa, "))\n\n");

        // the original, renamed: everything after the name is reproduced
        // byte for byte, so the body is never reformatted or reinterpreted
        try out.writer(gpa).print("func {s}__rpp_impl", .{name});
        const after_name = name_node.startByte() + name.len;
        try out.appendSlice(gpa, src[after_name..end]);

        cursor = end;
        n_done += 1;
    }
    try out.appendSlice(gpa, src[cursor..]);

    if (n_done == 0) {
        try w.print("{s}", .{src});
        return 0;
    }
    try w.print("{s}", .{out.items});
    return 0;
}
