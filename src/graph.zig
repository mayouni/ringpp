//! `rnxc graph <root.ring>` -- the RESOLVED graph (L2) of a load unit, as the shared code-graph line protocol.
//!
//! haro/CODEGRAPH.md, rung 4. stzlib's stzCodeGraph ingests five kinds of line -- `CLASS|name|bases`, `METHOD|class|name|line`,
//! `FUNC|name|line`, `IMPORT|module`, `CALL|caller|callee` -- that its Python and JavaScript peers get from a real parse, and that its Ring
//! peer (stzRingCodeGraph) builds from a line-by-line text scan: a call is "an identifier before a `(`" whose name some class defines. This
//! prints the same protocol from what the COMPILER resolved while it emitted code (compile.zig, `graphData`), which no text scan can know:
//! which function a call is bound to, and which calls can only be dispatched by name.
//!
//!   FILE|<path>                          one block per file of the unit, in load order
//!   CLASS|<name>|<parent>|<line>         the parent is `from X`, empty when there is none
//!   METHOD|<class>|<name>|<line>         a function inside a class (`def` and `func` alike: Ring reads them alike)
//!   FUNC|<name>|<line>                   a function outside any class
//!   IMPORT|<module>                      a `load`, as written
//!   CALL|<caller>|<callee>|static        the compiler bound the call to ONE function: a plain call, or a method whose receiver it proved.
//!                                        A name is `Class.method` for a method and `name` for a function; `<top>` is a file's own statements
//!   CALL|<caller>|<name>|dynamic|<n>     a method call it could only dispatch by name; n is how many methods of the unit carry the name --
//!                                        an over-approximation, and the number says how large
//!   UNFINISHED|<function>                the compiler could not finish this function: its edges are MISSING, which is not the same as absent
//!
//! The extra fields are ignored by stzCodeGraph's ingestion (it reads fields 2 and 3), so the stream is still its protocol. A lambda's calls
//! are its enclosing function's. A statement the compiler could not compile poisons its function and contributes no edges -- the statements
//! before and after it do -- and the function is named in an UNFINISHED record and counted on stderr, never hidden. Names keep the spelling they were written in; Ring folds case, so compare them folded.
const std = @import("std");
const ts = @import("ts.zig");
const co = @import("compile.zig");

const Alloc = std.mem.Allocator;
const Lines = std.ArrayListUnmanaged(Rec);

const Rec = struct { key: u32, text: []const u8 };

pub const Stats = struct {
    files: usize = 0,
    classes: usize = 0,
    methods: usize = 0,
    functions: usize = 0,
    static_edges: usize = 0,
    dynamic_edges: usize = 0,
    poisoned: usize = 0,
};

fn isSynthetic(name: []const u8) bool {
    return name.len >= 2 and name[0] == '@' and name[1] == '@';
}

fn lessRec(_: void, a: Rec, b: Rec) bool {
    if (a.key != b.key) return a.key < b.key;
    return std.mem.lessThan(u8, a.text, b.text);
}

pub fn print(a: Alloc, d: co.GraphData, roots: []const ts.Node, paths: []const []const u8, w: *std.Io.Writer) !Stats {
    var st = Stats{ .files = roots.len };

    // which file a node belongs to: the root whose source it points into
    var by_src = std.AutoHashMapUnmanaged(usize, usize){};
    for (roots, 0..) |r, i| try by_src.put(a, @intFromPtr(r.src.ptr), i);
    const fileOf = struct {
        fn f(m: *const std.AutoHashMapUnmanaged(usize, usize), n: ts.Node) usize {
            return m.get(@intFromPtr(n.src.ptr)) orelse 0;
        }
    }.f;

    const decls = try a.alloc(Lines, roots.len);
    const calls = try a.alloc(Lines, roots.len);
    const imports = try a.alloc(Lines, roots.len);
    const unfinished = try a.alloc(Lines, roots.len);
    for (decls, calls, imports, unfinished) |*x, *y, *z, *u| {
        x.* = .{};
        y.* = .{};
        z.* = .{};
        u.* = .{};
    }

    // the calls: a lambda's are its enclosing function's
    const real = struct {
        fn f(fs: []const co.Func, start: usize) usize {
            var i = start;
            var guard: u32 = 0;
            while (fs[i].lambda_at != null and guard < 64) : (guard += 1) {
                i = fs[i].encl orelse break;
            }
            return i;
        }
    }.f;
    const disp = struct {
        fn f(al: Alloc, dd: co.GraphData, i: usize) ![]const u8 {
            const fn_ = dd.funcs[i];
            if (isSynthetic(fn_.name)) return "<top>";
            if (fn_.owner) |o| if (o < dd.classes.len) return std.fmt.allocPrint(al, "{s}.{s}", .{ dd.classes[o].name, fn_.name });
            return fn_.name;
        }
    }.f;

    // how many methods of the unit carry each name (the width of a dynamic call)
    var fan = std.StringHashMapUnmanaged(u32){};
    for (d.funcs) |f| {
        if (f.owner == null or isSynthetic(f.name)) continue;
        const k = try std.ascii.allocLowerString(a, f.name);
        const g = try fan.getOrPut(a, k);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }

    for (d.classes) |c| {
        const fi = fileOf(&by_src, c.node);
        st.classes += 1;
        const line = c.node.start().row + 1;
        try decls[fi].append(a, .{ .key = c.node.startByte(), .text = try std.fmt.allocPrint(a, "CLASS|{s}|{s}|{d}", .{ c.name, c.parent_name, line }) });
    }
    for (d.funcs, 0..) |f, fidx| {
        if (isSynthetic(f.name) or f.lambda_at != null) continue;
        const fi = fileOf(&by_src, f.node);
        if (f.poisoned_own) {
            st.poisoned += 1;
            // its calls are MISSING, not absent: a consumer must be able to tell the two apart
            try unfinished[fi].append(a, .{ .key = f.node.startByte(), .text = try std.fmt.allocPrint(a, "UNFINISHED|{s}", .{try disp(a, d, fidx)}) });
        }
        const line = f.node.start().row + 1;
        if (f.owner) |o| {
            if (o >= d.classes.len) continue;
            st.methods += 1;
            try decls[fi].append(a, .{ .key = f.node.startByte(), .text = try std.fmt.allocPrint(a, "METHOD|{s}|{s}|{d}", .{ d.classes[o].name, f.name, line }) });
        } else {
            st.functions += 1;
            try decls[fi].append(a, .{ .key = f.node.startByte(), .text = try std.fmt.allocPrint(a, "FUNC|{s}|{d}", .{ f.name, line }) });
        }
    }

    // the loads, as written
    for (roots, 0..) |r, fi| {
        var i: u32 = 0;
        while (i < r.namedChildCount()) : (i += 1) {
            const ch = r.namedChild(i);
            if (!std.mem.eql(u8, ch.kind(), "load_statement") or ch.namedChildCount() == 0) continue;
            var lit = ch.namedChild(ch.namedChildCount() - 1).text();
            if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'' or lit[0] == '`')) lit = lit[1 .. lit.len - 1];
            try imports[fi].append(a, .{ .key = ch.startByte(), .text = try std.fmt.allocPrint(a, "IMPORT|{s}", .{lit}) });
        }
    }

    var seen = std.StringHashMapUnmanaged(void){};
    for (d.funcs, 0..) |f, from_raw| {
        const from = real(d.funcs, from_raw);
        const caller = try disp(a, d, from);
        const fi = fileOf(&by_src, d.funcs[from].node);
        // static: the compiler's own bindings -- fixups name the caller and the target of each call it patched, and a method it proved
        // but dispatched by name is in calls_static
        for (f.calls_static.items) |t| try staticEdge(a, d, &seen, &calls[fi], &st, caller, t);
        // dynamic: by name
        for (f.calls_named.items) |ni| {
            if (ni >= d.names.len) continue;
            const name = d.names[ni];
            const n = fan.get(try std.ascii.allocLowerString(a, name)) orelse 0;
            const key = try std.fmt.allocPrint(a, "{s}|{s}|dynamic", .{ caller, name });
            const g = try seen.getOrPut(a, key);
            if (g.found_existing) continue;
            st.dynamic_edges += 1;
            try calls[fi].append(a, .{ .key = 0, .text = try std.fmt.allocPrint(a, "CALL|{s}|{s}|dynamic|{d}", .{ caller, name, n }) });
        }
    }
    for (d.fixups) |fx| {
        if (fx.from >= d.funcs.len) continue;
        const from = real(d.funcs, fx.from);
        const caller = try disp(a, d, from);
        const fi = fileOf(&by_src, d.funcs[from].node);
        try staticEdge(a, d, &seen, &calls[fi], &st, caller, fx.fidx);
    }

    for (roots, 0..) |_, fi| {
        try w.print("FILE|{s}\n", .{if (fi < paths.len) paths[fi] else "?"});
        std.mem.sort(Rec, decls[fi].items, {}, lessRec);
        for (decls[fi].items) |r| try w.print("{s}\n", .{r.text});
        for (imports[fi].items) |r| try w.print("{s}\n", .{r.text});
        for (unfinished[fi].items) |r| try w.print("{s}\n", .{r.text});
        std.mem.sort(Rec, calls[fi].items, {}, lessRec);
        for (calls[fi].items) |r| try w.print("{s}\n", .{r.text});
    }
    return st;
}

fn staticEdge(a: Alloc, d: co.GraphData, seen: *std.StringHashMapUnmanaged(void), out: *Lines, st: *Stats, caller: []const u8, target: usize) !void {
    if (target >= d.funcs.len) return;
    const t = d.funcs[target];
    if (isSynthetic(t.name) or t.lambda_at != null) return;
    const callee = if (t.owner) |o| (if (o < d.classes.len) try std.fmt.allocPrint(a, "{s}.{s}", .{ d.classes[o].name, t.name }) else t.name) else t.name;
    const key = try std.fmt.allocPrint(a, "{s}|{s}|static", .{ caller, callee });
    const g = try seen.getOrPut(a, key);
    if (g.found_existing) return;
    st.static_edges += 1;
    try out.append(a, .{ .key = 0, .text = try std.fmt.allocPrint(a, "CALL|{s}|{s}|static", .{ caller, callee }) });
}
