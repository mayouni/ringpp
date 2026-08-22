//! Level 1 type checking — `ringpp check`, the annotations Ring already
//! accepts, read and enforced statically. DESIGN_TOOLCHAIN.md section 3.
//!
//! Ring parses type annotations and discards them. That is deliberate, and
//! Ring++ does not change it: **runtime behaviour is identical with and
//! without this file**. What changes is that the annotation stops being a
//! comment and starts being checked.
//!
//! Measuring Ring first (bench/12_typehints_channel.ring, and the probes
//! rerun for this phase) turned up something the design had not accounted
//! for — the two halves of an annotation are not the same mechanism at all:
//!
//!   func Sum(int x, int y)      the parameter types are a PARSER feature.
//!                               stmt.c:1217 accepts and drops them. No
//!                               library needed, nothing evaluated, and
//!                               nothing enforced: Sum("a","b") returns "ab".
//!
//!   int func Sum(...)           the return type is NOT. It is an ordinary
//!                               expression statement reading a global named
//!                               `int`, which typehints.ring defines as
//!                               `int = :int`. Without that library it is
//!                               Error (R24): Using uninitialized variable.
//!                               `load "stdlib.ring"` does not supply it.
//!
//! So an annotated file that never loads typehints.ring does not merely lose
//! its hints — it fails at run time, on a line that looks like a declaration.
//! That is rule 1 below, and it is the one that pays for this file.
//!
//! Arity, unlike types, Ring *does* enforce: R19 with too few arguments,
//! R20 with too many. Both are decidable from the source, so both are
//! errors here rather than warnings.
//!
//! **Every rule is written to be certain.** A checker that cries wolf on
//! correct code is worse than no checker — the same reason `rpp/unparsed`
//! never blames the user's file. Where certainty was not available the rule
//! was narrowed until it was, and what that narrowing gives up is recorded
//! at each site.

const std = @import("std");
const ts = @import("ts.zig");
const chk = @import("check.zig");

/// What the whole run knows, as opposed to this one file. A project may load
/// typehints.ring once in an entry file and `load` the rest from there, so
/// "this file does not load it" is not on its own a verdict.
pub const Ctx = struct {
    typehints_loaded_in_scan: bool = false,

    /// Cross-file signatures visible from THIS file through its load graph
    /// (src/project.zig). A name here has exactly one definition across the
    /// closure — Ring's C22 guarantees no second live one (FINDINGS F-26) —
    /// so checking against it carries the same certainty as a local call.
    extern_sigs: ?*const std.StringHashMap(ExternSig) = null,

    /// Names with MORE than one definition in this file's closure. Checking
    /// against either would be arbitrary, so these are skipped — and the
    /// duplicate itself is reported once, at the join file, via `duplicates`.
    conflicted: ?*const std.StringHashMap(void) = null,

    /// Duplicates INTRODUCED by this file's own loads (the join point).
    /// Running this file is Error (C22) before its first line executes.
    duplicates: []const DupNote = &.{},
};

pub const ExternSig = struct {
    file: []const u8,
    sig: Collected,
};

pub const DupNote = struct {
    name: []const u8,
    file_a: []const u8,
    row_a: u32,
    file_b: []const u8,
    row_b: u32,
};

/// Ring's hint vocabulary, verbatim from libraries/typehints/typehints.ring.
/// typehints.ring also registers every class as a type at load time, via
/// Classes() and eval() — which is why an unrecognised name is not reported
/// as unknown here. It may well be a class in a file we were not given.
const hint_types = [_][]const u8{
    // low level
    "char",  "unsigned", "signed",   "int",  "short",     "long",
    "float", "double",   "void",     "byte", "boolean",
    // high level
    "string", "list",    "number",   "object",
    // modifiers, which share the same channel
    "public", "static",  "abstract", "protected", "override",
};

/// Names that are *not* Ring hints and are near-certainly meant as one. This
/// is deliberately a fixed list rather than an edit-distance guess: a name
/// that is not in the vocabulary is usually a class, and reporting classes
/// as unknown types would be exactly the false-positive flood this checker
/// exists to avoid. `bool` is on it because Ring's hint is `boolean` — and
/// because DESIGN_TOOLCHAIN section 3 itself writes `bool`.
const near_misses = [_]struct { wrong: []const u8, meant: []const u8 }{
    .{ .wrong = "bool", .meant = "boolean" },
    .{ .wrong = "integer", .meant = "int" },
    .{ .wrong = "str", .meant = "string" },
    .{ .wrong = "text", .meant = "string" },
    .{ .wrong = "real", .meant = "double" },
    .{ .wrong = "float64", .meant = "double" },
    .{ .wrong = "f64", .meant = "double" },
    .{ .wrong = "i32", .meant = "int" },
    .{ .wrong = "i64", .meant = "long" },
    .{ .wrong = "uint", .meant = "unsigned" },
    .{ .wrong = "num", .meant = "number" },
    .{ .wrong = "obj", .meant = "object" },
    .{ .wrong = "array", .meant = "list" },
    .{ .wrong = "dict", .meant = "list" },
    .{ .wrong = "map", .meant = "list" },
    .{ .wrong = "any", .meant = "" },
    .{ .wrong = "var", .meant = "" },
};

fn isHintType(t: []const u8) bool {
    for (hint_types) |h| if (std.ascii.eqlIgnoreCase(h, t)) return true;
    return false;
}

/// Types a numeric literal can inhabit. `char` is left out on purpose: it is
/// a C char, and both 65 and "A" are defensible for it.
fn isNumericType(t: []const u8) bool {
    const ns = [_][]const u8{ "int", "short", "long", "float", "double", "byte", "number", "signed", "unsigned" };
    for (ns) |n| if (std.ascii.eqlIgnoreCase(n, t)) return true;
    return false;
}

fn isTextType(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "string");
}

fn isAggregateType(t: []const u8) bool {
    return std.ascii.eqlIgnoreCase(t, "list") or std.ascii.eqlIgnoreCase(t, "object");
}

const Lit = enum {
    none,
    number,
    text,

    /// the word a Ring programmer would use, not the tag name
    fn word(self: Lit) []const u8 {
        return switch (self) {
            .none => "value",
            .number => "number",
            .text => "string",
        };
    }
};

fn literalOf(n: ts.Node) Lit {
    const k = n.kind();
    if (std.mem.eql(u8, k, "number")) return .number;
    if (std.mem.eql(u8, k, "string")) return .text;
    return .none;
}

pub const Param = struct { ty: []const u8, name: []const u8 };

/// One top-level function signature, every string arena-owned (safe to keep
/// after the source and the tree are gone — the project layer relies on it).
pub const Collected = struct {
    display: []const u8,
    lower: []const u8,
    params: []Param,
    /// the `int` of `int func F(...)`, or "" when unannotated
    ret: []const u8,
    row: u32,
};

/// A class as the checker needs it: its own methods, and its parent's name.
///
/// The grammar NESTS class_definition nodes — `class Child from Parent` is
/// parsed inside Parent's node, though Ring treats classes as siblings — so
/// a class's OWN methods are the function_definitions before any nested
/// class_definition, and nothing deeper.
pub const ClassInfo = struct {
    display: []const u8,
    lower: []const u8,
    /// "" when the class declares no parent
    parent_lower: []const u8,
    methods: []Collected,
};

/// Every class in a file, flattened out of the grammar's nesting.
pub fn collectClasses(arena: std.mem.Allocator, root: ts.Node) ![]ClassInfo {
    var out = std.ArrayList(ClassInfo){};
    try walkClasses(arena, root, &out);
    return out.toOwnedSlice(arena);
}

fn walkClasses(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList(ClassInfo)) !void {
    if (isClass(n)) {
        const nm = n.field("name");
        if (!nm.isNull()) {
            var parent: []const u8 = "";
            const p = n.field("parent");
            if (!p.isNull()) {
                // class_parent -> qualified_identifier -> identifier
                var q = p;
                while (q.namedChildCount() > 0) q = q.namedChild(0);
                parent = try lower(arena, q.text());
            }

            var methods = std.ArrayList(Collected){};
            var i: u32 = 0;
            while (i < n.namedChildCount()) : (i += 1) {
                const c = n.namedChild(i);
                if (isClass(c)) break; // a nested class ends THIS class's body
                if (!std.mem.eql(u8, c.kind(), "function_definition")) continue;
                const mn = c.field("name");
                if (mn.isNull()) continue;

                const raw = try paramsOf(arena, c);
                const params = try arena.alloc(Param, raw.len);
                for (raw, 0..) |pp, k| params[k] = .{
                    .ty = try arena.dupe(u8, pp.ty),
                    .name = try arena.dupe(u8, pp.name),
                };
                try methods.append(arena, .{
                    .display = try arena.dupe(u8, mn.text()),
                    .lower = try lower(arena, mn.text()),
                    .params = params,
                    .ret = if (returnAnnotation(c)) |a| try arena.dupe(u8, a.text()) else "",
                    .row = c.start().row,
                });
            }

            try out.append(arena, .{
                .display = try arena.dupe(u8, nm.text()),
                .lower = try lower(arena, nm.text()),
                .parent_lower = parent,
                .methods = try methods.toOwnedSlice(arena),
            });
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try walkClasses(arena, n.child(i), out);
}

/// Signatures a plain unqualified call can reach: file level, BEFORE the
/// first class — every func after the first class is a method of it
/// (FINDINGS F-21), and an unqualified call to a method resolves by
/// different rules. Including methods would report errors on correct code.
///
/// Keeps ALL definitions, duplicates included: the project layer needs to
/// SEE a duplicate to report it as the C22 it is (F-26).
pub fn collectTopSigs(arena: std.mem.Allocator, root: ts.Node) ![]Collected {
    var out = std.ArrayList(Collected){};
    var first_class_row: u32 = std.math.maxInt(u32);
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const n = root.namedChild(i);
        if (isClass(n)) {
            first_class_row = @min(first_class_row, n.start().row);
            continue;
        }
        if (!std.mem.eql(u8, n.kind(), "function_definition")) continue;
        if (n.start().row > first_class_row) continue;
        const nm = n.field("name");
        if (nm.isNull()) continue;

        const raw = try paramsOf(arena, n);
        const params = try arena.alloc(Param, raw.len);
        for (raw, 0..) |p, k| params[k] = .{
            .ty = try arena.dupe(u8, p.ty),
            .name = try arena.dupe(u8, p.name),
        };

        try out.append(arena, .{
            .display = try arena.dupe(u8, nm.text()),
            .lower = try lower(arena, nm.text()),
            .params = params,
            .ret = if (returnAnnotation(n)) |a| try arena.dupe(u8, a.text()) else "",
            .row = n.start().row,
        });
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------

pub fn check(
    gpa: std.mem.Allocator,
    root: ts.Node,
    file: []const u8,
    src: []const u8,
    report: *chk.Report,
    ctx: Ctx,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loads_hints = fileLoadsTypehints(src);

    var sigs = std.StringHashMap(Collected).init(arena);
    for (try collectTopSigs(arena, root)) |s| {
        // same-file redefinition: the project layer reports it as C22; for
        // local checking keep the first, matching what a reader sees first
        if (!sigs.contains(s.lower)) try sigs.put(s.lower, s);
    }

    // Duplicates INTRODUCED by this file's loads: running this file is C22
    // before its first line. Anchored at the first load statement, because
    // the loads are what join the two definitions.
    for (ctx.duplicates) |d| {
        const anchor = firstLoad(root) orelse root;
        try report.add(gpa, file, anchor, .err, "rpp/type-duplicate-func", "loading this file defines {s}() twice — Error (C22), the program cannot start", .{d.name}, "Ring rejects a duplicate function name at LOAD time: 'Function redefinition, function is already defined!'. The two definitions this file's loads bring together are named in the locations below; nothing after the load line ever runs. Remove one, or stop loading one of the two files. See FINDINGS F-26.");
        try report.add(gpa, file, anchor, .note, "rpp/type-duplicate-func", "{s}() is defined at {s}:{d} and again at {s}:{d}", .{ d.name, d.file_a, d.row_a + 1, d.file_b, d.row_b + 1 }, "");
    }

    var classes = std.StringHashMap(ClassInfo).init(arena);
    for (try collectClasses(arena, root)) |c| {
        // a redefined class is Ring's problem; keep the first, as with funcs
        if (!classes.contains(c.lower)) try classes.put(c.lower, c);
    }

    var w = Walker{
        .gpa = gpa,
        .arena = arena,
        .report = report,
        .file = file,
        .sigs = &sigs,
        .classes = &classes,
        .loads_hints = loads_hints,
        .ctx = ctx,
    };
    try w.visit(root, false);
}

const Walker = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    report: *chk.Report,
    file: []const u8,
    sigs: *std.StringHashMap(Collected),
    /// every class in this file, by lower-case name -- the parent chain is
    /// walked through this, and an absent link means we refuse to guess
    classes: *std.StringHashMap(ClassInfo),
    /// the class whose body we are inside, if any
    current_class: ?ClassInfo = null,
    loads_hints: bool,
    ctx: Ctx,

    /// Where a callable name resolves, in Ring's own order — a conflicted
    /// name resolves NOWHERE, because the program carrying both defs is C22.
    const Resolved = union(enum) {
        none,
        conflicted,
        local: Collected,
        remote: ExternSig,
    };

    fn resolve(self: *Walker, lowname: []const u8) Resolved {
        if (self.ctx.conflicted) |c| {
            if (c.contains(lowname)) return .conflicted;
        }
        if (self.sigs.get(lowname)) |s| return .{ .local = s };
        if (self.ctx.extern_sigs) |e| {
            if (e.get(lowname)) |x| return .{ .remote = x };
        }
        return .none;
    }

    fn visit(self: *Walker, n: ts.Node, in_class: bool) !void {
        const kind = n.kind();
        const now_in_class = in_class or isClass(n);

        // The grammar nests class_definition nodes, so entering one both
        // sets the current class AND must restore the previous on the way
        // out -- a nested Child would otherwise leak into Parent's tail.
        const saved_class = self.current_class;
        defer self.current_class = saved_class;
        if (isClass(n)) {
            const nm = n.field("name");
            if (!nm.isNull()) {
                if (lower(self.arena, nm.text())) |k| {
                    self.current_class = self.classes.get(k);
                } else |_| {}
            }
        }

        // Ring's brace block runs in the OBJECT's scope: inside
        // `StzCharQ("x") { ? Name() }` the call `Name()` resolves to the
        // object's method, never to a global function that happens to share
        // the name. The first version of this walker did not know that, and
        // reported 340+ false arity errors across Softanza's test suite —
        // every one a method call inside braces. The HEAD of the brace
        // expression (the object being entered) is still caller-scope and
        // still checked; only the body statements are method-land.
        if (std.mem.eql(u8, kind, "brace_expression")) {
            if (n.namedChildCount() > 0) try self.visit(n.namedChild(0), now_in_class);
            var i: u32 = 1;
            while (i < n.namedChildCount()) : (i += 1) try self.visit(n.namedChild(i), true);
            return;
        }
        // `new Thing(args) { body }` — same rule: the class name and the
        // constructor arguments are caller-scope, the body is object-scope.
        if (std.mem.eql(u8, kind, "new_expression")) {
            var i: u32 = 0;
            while (i < n.namedChildCount()) : (i += 1) {
                const c = n.namedChild(i);
                const ck = c.kind();
                const head = std.mem.eql(u8, ck, "qualified_identifier") or
                    std.mem.eql(u8, ck, "identifier") or
                    std.mem.eql(u8, ck, "arguments");
                try self.visit(c, now_in_class or !head);
            }
            return;
        }

        if (std.mem.eql(u8, kind, "function_definition")) try self.checkFunction(n);
        if (std.mem.eql(u8, kind, "call_expression")) try self.checkCall(n, now_in_class);

        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try self.visit(n.child(i), now_in_class);
    }

    fn checkFunction(self: *Walker, n: ts.Node) !void {
        // -- the parameter annotations ------------------------------------
        const params = try paramsOf(self.arena, n);
        for (params) |p| {
            if (p.ty.len == 0) continue;
            try self.checkNearMiss(n, p.ty);
        }

        // -- the return annotation ----------------------------------------
        const ann = returnAnnotation(n);
        if (ann) |a| {
            const t = a.text();
            try self.checkNearMiss(a, t);

            // RULE 1. The return annotation is a variable read. Without
            // typehints.ring it is Error (R24) at this line, every run.
            if (!self.loads_hints) {
                if (self.ctx.typehints_loaded_in_scan) {
                    try self.report.add(self.gpa, self.file, a, .note, "rpp/type-hints-missing", "'{s} func' needs typehints.ring, which this file does not load", .{t}, "The return annotation is not parsed away like the parameter types are — it is an ordinary read of a global that typehints.ring defines. This is only safe if the file is always loaded from one that has already loaded it. Another file in this run does load it, so this is advisory. See FINDINGS F-24.");
                } else {
                    try self.report.add(self.gpa, self.file, a, .err, "rpp/type-hints-missing", "'{s} func' raises Error (R24) — nothing here loads typehints.ring", .{t}, "Parameter annotations are parsed and discarded, so they need no library. A RETURN annotation is different: it is an ordinary expression reading a global of that name, which only typehints.ring defines. load \"stdlib.ring\" does not supply it. Add load \"typehints.ring\", or drop the return annotation. See FINDINGS F-24.");
                }
            }

            // RULE 4. A returned literal that contradicts the annotation.
            try self.checkReturns(n, t);
        }

        // RULE 6. An annotated parameter reassigned to a literal of a
        // contradicting category inside the body. The reassignment is a
        // certainty; the annotation declared otherwise; one of them lies.
        for (params) |p| {
            if (p.ty.len == 0) continue;
            if (!isNumericType(p.ty) and !isTextType(p.ty) and !isAggregateType(p.ty)) continue;
            try self.walkAssigns(n, n, p);
        }
    }

    fn walkAssigns(self: *Walker, n: ts.Node, owner: ts.Node, p: Param) !void {
        // brace/new bodies assign OBJECT attributes — `o { x = 5 }` touches
        // o's x, not the parameter x — so they are not this function's story
        if (!nodeEql(n, owner) and
            (std.mem.eql(u8, n.kind(), "function_definition") or isClass(n) or
                std.mem.eql(u8, n.kind(), "brace_expression") or
                std.mem.eql(u8, n.kind(), "new_expression"))) return;

        if (std.mem.eql(u8, n.kind(), "assignment_expression") and n.namedChildCount() >= 2) {
            const lhs = n.namedChild(0);
            if (std.mem.eql(u8, lhs.kind(), "identifier") and
                std.ascii.eqlIgnoreCase(lhs.text(), p.name))
            {
                const lit = literalOf(n.namedChild(1));
                const bad = switch (lit) {
                    .text => isNumericType(p.ty),
                    .number => isTextType(p.ty) or isAggregateType(p.ty),
                    .none => false,
                };
                if (bad) {
                    try self.report.add(self.gpa, self.file, n, .warn, "rpp/type-declared-conflict", "'{s}' is declared '{s} {s}' and reassigned here to a literal {s}", .{ p.name, p.ty, p.name, lit.word() }, "The parameter's annotation and this assignment contradict each other, and Ring enforces neither — the code runs with the literal's real type while every reader of the signature believes the annotation. Fix whichever is wrong. See FINDINGS F-24.");
                }
            }
        }
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try self.walkAssigns(n.child(i), owner, p);
    }

    /// Returns whose value is a literal of the wrong category. Only literals:
    /// anything computed is Ring-dynamic and genuinely unknowable here.
    fn checkReturns(self: *Walker, fn_node: ts.Node, ret_ty: []const u8) !void {
        try self.walkReturns(fn_node, fn_node, ret_ty);
    }

    fn walkReturns(self: *Walker, n: ts.Node, owner: ts.Node, ret_ty: []const u8) !void {
        // Do not descend into a nested definition — its returns are its own.
        if (!nodeEql(n, owner) and
            (std.mem.eql(u8, n.kind(), "function_definition") or isClass(n))) return;

        if (std.mem.eql(u8, n.kind(), "return_statement") and n.namedChildCount() > 0) {
            const v = n.namedChild(0);
            const bad = switch (literalOf(v)) {
                .text => isNumericType(ret_ty),
                .number => isTextType(ret_ty) or isAggregateType(ret_ty),
                .none => false,
            };
            if (bad) {
                try self.report.add(self.gpa, self.file, v, .warn, "rpp/type-return-mismatch", "declared '{s}', returns a literal {s}", .{ ret_ty, literalOf(v).word() }, "Ring does not enforce the annotation, so this runs and returns the literal. The annotation is then a comment that disagrees with the code — and the next reader believes the annotation. See DESIGN_TOOLCHAIN section 3, level 1.");
            }
        }
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try self.walkReturns(n.child(i), owner, ret_ty);
    }

    /// Resolve an unqualified call made INSIDE class `cls`, in the order
    /// Ring actually uses. Measured 2026-08-23, five reproducers, FINDINGS
    /// F-27: own method -> inherited method -> global function -> builtin.
    /// A method wins over a same-named global even when INHERITED.
    ///
    /// Returns null the moment the answer is not certain — an unknown
    /// parent class means an unknown method table, and guessing there is
    /// exactly the false positive this checker cannot afford.
    fn resolveInClass(self: *Walker, cls: ClassInfo, lowname: []const u8) ?Resolved {
        var cur = cls;
        var hops: u32 = 0;
        while (hops < 32) : (hops += 1) {
            for (cur.methods) |m| {
                if (std.mem.eql(u8, m.lower, lowname)) return .{ .local = m };
            }
            if (cur.parent_lower.len == 0) break; // no parent: the chain ends
            const nxt = self.classes.get(cur.parent_lower) orelse return null; // unknown parent
            cur = nxt;
        }
        if (hops >= 32) return null; // cycle or absurd depth: refuse to guess

        // No method anywhere up the chain, and every link was known, so the
        // name falls through to an ordinary function.
        return self.resolve(lowname);
    }

    fn checkCall(self: *Walker, n: ts.Node, in_class: bool) !void {
        const callee = calleeName(n);
        if (callee.len == 0) return;

        // `call draw(oGame, self)` invokes a function held in a VARIABLE --
        // Ring's dynamic-call keyword. The name is a variable read, not a
        // reference to any definition, so its arity says nothing about the
        // method or function of that name. Ring's own gameengine does this
        // constantly: `draw` is both an attribute holding a callback and a
        // method, and the first version of this rule reported three false
        // errors in ring127/libraries because of it.
        const parent = n.parent();
        if (!parent.isNull() and
            std.mem.eql(u8, parent.kind(), "call_keyword_expression")) return;

        const key = lower(self.arena, callee) catch return;

        // Inside a class body, resolution starts at the class (F-27). This
        // was previously abandoned entirely — coverage given up because a
        // method shadows a same-named global (F-17). It is recoverable when
        // the whole method chain is visible; when it is not, we still give
        // up, but now only in that case.
        if (in_class) {
            const cls = self.current_class orelse return;
            const r = self.resolveInClass(cls, key) orelse return;
            const sig: Collected, const from: []const u8 = switch (r) {
                .none, .conflicted => return,
                .local => |s| .{ s, "" },
                .remote => |x| .{ x.sig, x.file },
            };
            const nargs = argCount(n);
            const nparams: u32 = @intCast(sig.params.len);
            if (nargs != nparams) {
                const code = if (nargs < nparams) "R19" else "R20";
                if (from.len == 0) {
                    try self.report.add(self.gpa, self.file, n, .err, "rpp/type-arity", "{s}() takes {d} argument(s), called with {d} — Error ({s}) at run time", .{ sig.display, nparams, nargs, code }, "Inside a class body an unqualified call resolves to a method first — the class's own, then an inherited one — before any global of that name (FINDINGS F-27). The whole chain was visible here, so this is the definition that runs.");
                } else {
                    try self.report.add(self.gpa, self.file, n, .err, "rpp/type-arity", "{s}() takes {d} argument(s), called with {d} — Error ({s}) at run time (defined in {s})", .{ sig.display, nparams, nargs, code, from }, "No method of this name exists on the class or anywhere up its parent chain, so the call falls through to an ordinary function (FINDINGS F-27), reached through this file's load graph.");
                }
            }
            return;
        }

        const sig: Collected, const from: []const u8 = switch (self.resolve(key)) {
            .none, .conflicted => return,
            .local => |s| .{ s, "" },
            .remote => |x| .{ x.sig, x.file },
        };

        // RULE 2. Arity. Ring DOES enforce this: R19 too few, R20 too many.
        const nargs = argCount(n);
        const nparams: u32 = @intCast(sig.params.len);
        if (nargs != nparams) {
            const code = if (nargs < nparams) "R19" else "R20";
            if (from.len == 0) {
                try self.report.add(self.gpa, self.file, n, .err, "rpp/type-arity", "{s}() takes {d} argument(s), called with {d} — Error ({s}) at run time", .{ sig.display, nparams, nargs, code }, "Ring checks arity even though it does not check types: R19 is 'Calling function with less number of parameters', R20 'with extra'. Ring has no default parameters, so the count is exact. The definition is in this file and before the first class, so this call cannot be reaching a different one.");
            } else {
                try self.report.add(self.gpa, self.file, n, .err, "rpp/type-arity", "{s}() takes {d} argument(s), called with {d} — Error ({s}) at run time (defined in {s})", .{ sig.display, nparams, nargs, code, from }, "The definition is reached through this file's load graph, and it is the ONLY one: Ring rejects a second definition of the same name with Error (C22) at load time, so no program containing this call can be running a different definition of it. See FINDINGS F-26.");
            }
            return; // the argument types below would only add noise
        }

        // RULE 3. An argument whose type is KNOWN contradicting the declared
        // parameter type. Known means: a literal, or a call to a function
        // whose return annotation declares it. Anything else is Ring-dynamic
        // and left alone.
        var i: u32 = 0;
        while (i < nparams) : (i += 1) {
            const p = sig.params[i];
            if (p.ty.len == 0) continue;
            const a = argAt(n, i) orelse continue;

            const lit = literalOf(a);
            if (lit != .none) {
                const bad = switch (lit) {
                    .text => isNumericType(p.ty),
                    .number => isTextType(p.ty) or isAggregateType(p.ty),
                    .none => false,
                };
                if (bad) {
                    try self.report.add(self.gpa, self.file, a, .warn, "rpp/type-arg-mismatch", "{s}() declares '{s} {s}', called here with a literal {s}", .{ sig.display, p.ty, p.name, lit.word() }, "Ring accepts this: parameter annotations are parsed and thrown away, never checked. The call runs and the operators inside behave as the value's real type — Sum(\"a\",\"b\") on 'int x, int y' returns \"ab\", not 3. See FINDINGS F-24 and DESIGN_TOOLCHAIN section 3.");
                }
                continue;
            }

            // a nested call whose callee DECLARES its return type
            if (std.mem.eql(u8, a.kind(), "call_expression")) {
                const inner = calleeName(a);
                if (inner.len == 0) continue;
                const ikey = lower(self.arena, inner) catch continue;
                const iret = switch (self.resolve(ikey)) {
                    .none, .conflicted => continue,
                    .local => |s| s.ret,
                    .remote => |x| x.sig.ret,
                };
                if (iret.len == 0) continue;
                if (categoriesConflict(iret, p.ty)) {
                    try self.report.add(self.gpa, self.file, a, .warn, "rpp/type-declared-conflict", "{s}() declares '{s} {s}', but {s}() declares that it returns {s}", .{ sig.display, p.ty, p.name, inner, iret }, "Two declarations contradict each other: the parameter says one category, the return annotation of the call feeding it says another. One of them is lying — and Ring will not say which, because it enforces neither. Fix whichever declaration is wrong. See FINDINGS F-24.");
                }
            }
        }
    }

    fn checkNearMiss(self: *Walker, at: ts.Node, t: []const u8) !void {
        if (isHintType(t)) return;
        for (near_misses) |m| {
            if (!std.ascii.eqlIgnoreCase(m.wrong, t)) continue;
            if (m.meant.len > 0) {
                try self.report.add(self.gpa, self.file, at, .note, "rpp/type-not-a-hint", "'{s}' is not one of Ring's type hints — did you mean '{s}'?", .{ t, m.meant }, "Ring's vocabulary is fixed by libraries/typehints/typehints.ring. As a parameter type an unknown name is harmless — it is parsed and discarded. As a return type it is Error (R24). Names outside the list are not reported unless they are on this short near-miss list, because typehints.ring also registers every class as a type.");
            } else {
                try self.report.add(self.gpa, self.file, at, .note, "rpp/type-not-a-hint", "'{s}' is not one of Ring's type hints, and Ring has no 'any'", .{t}, "Every Ring value is dynamically typed already; leaving the parameter unannotated says the same thing and is what Ring expects.");
            }
            return;
        }
    }
};

// ---------------------------------------------------------------------------
// shape helpers

fn isClass(n: ts.Node) bool {
    const k = n.kind();
    return std.mem.eql(u8, k, "class_definition") or std.mem.eql(u8, k, "class_statement");
}

/// Two DECLARED types whose categories cannot both be true of one value.
/// Only pairs where both sides are in Ring's hint vocabulary and the
/// categories are disjoint — `char` and class names stay out of it.
fn categoriesConflict(a: []const u8, b: []const u8) bool {
    const aN = isNumericType(a);
    const aT = isTextType(a);
    const aG = isAggregateType(a);
    const bN = isNumericType(b);
    const bT = isTextType(b);
    const bG = isAggregateType(b);
    if (aN and (bT or bG)) return true;
    if (aT and (bN or bG)) return true;
    if (aG and (bN or bT)) return true;
    return false;
}

/// The first load statement of a file — the anchor for reports about what
/// the loads, together, cause.
fn firstLoad(root: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const n = root.namedChild(i);
        if (std.mem.eql(u8, n.kind(), "load_statement")) return n;
    }
    return null;
}

fn nodeEql(a: ts.Node, b: ts.Node) bool {
    return a.start().row == b.start().row and a.start().col == b.start().col and
        std.mem.eql(u8, a.kind(), b.kind());
}

fn paramsOf(arena: std.mem.Allocator, fn_node: ts.Node) ![]Param {
    const pl = fn_node.field("parameters");
    if (pl.isNull()) return &.{};
    const n = pl.namedChildCount();
    var out = try arena.alloc(Param, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const p = pl.namedChild(i);
        if (std.mem.eql(u8, p.kind(), "typed_parameter")) {
            const ty = p.field("type");
            const nm = p.field("name");
            out[i] = .{
                .ty = if (ty.isNull()) "" else ty.text(),
                .name = if (nm.isNull()) "" else nm.text(),
            };
        } else {
            out[i] = .{ .ty = "", .name = p.text() };
        }
    }
    return out;
}

/// The `int` of `int func Sum(...)`.
///
/// The grammar does not attach it to the function, and it is right not to:
/// to Ring it really is a separate statement that reads a global. So it is
/// the immediately preceding sibling — required to start on the SAME ROW, so
/// that a stray identifier on its own line is not mistaken for a declaration.
fn returnAnnotation(fn_node: ts.Node) ?ts.Node {
    const prev = fn_node.prevNamedSibling();
    const id = bareIdentifierStatement(prev, fn_node.start().row) orelse return null;

    // Guard 1: it must name something from Ring's fixed hint vocabulary.
    //
    // Ring's one-line class form puts attributes in exactly this position:
    //
    //     Class Point x y z func print see x + nl + y + nl + z + nl
    //
    // `z` is an attribute, and reading it as a return type reported R24 on
    // ring127/samples/AQuickStart/OOP/oop1.ring — correct code. Requiring a
    // known type name costs the ability to see `MyClass func Foo`, which is
    // also a variable read and also R24 without the library. Missing that is
    // the cheaper mistake by a wide margin.
    if (!isHintType(id.text()) and !isNearMiss(id.text())) return null;

    // Guard 2: a RUN of bare identifiers on the same row is an attribute
    // list, whatever the names happen to be. A real annotation is one
    // identifier, immediately before the `func`.
    if (bareIdentifierStatement(prev.prevNamedSibling(), fn_node.start().row) != null) return null;

    return id;
}

/// An `expression_statement` that is nothing but one identifier, starting on
/// `row`. Null for anything else, including a null node.
fn bareIdentifierStatement(n: ts.Node, row: u32) ?ts.Node {
    if (n.isNull()) return null;
    if (!std.mem.eql(u8, n.kind(), "expression_statement")) return null;
    if (n.namedChildCount() != 1) return null;
    const id = n.namedChild(0);
    if (!std.mem.eql(u8, id.kind(), "identifier")) return null;
    if (id.start().row != row) return null;
    return id;
}

fn isNearMiss(t: []const u8) bool {
    for (near_misses) |m| if (std.ascii.eqlIgnoreCase(m.wrong, t)) return true;
    return false;
}

/// A raw-text scan, on purpose: `load` takes a runtime expression, so the
/// tree cannot always answer this, and a false "not loaded" would be an
/// error reported on correct code.
fn fileLoadsTypehints(src: []const u8) bool {
    return std.mem.indexOf(u8, src, "typehints") != null;
}

fn calleeName(n: ts.Node) []const u8 {
    if (n.childCount() == 0) return "";
    const head = n.child(0);
    if (std.mem.eql(u8, head.kind(), "identifier")) return head.text();
    return "";
}

fn argCount(call: ts.Node) u32 {
    var k: u32 = 0;
    while (k < call.childCount()) : (k += 1) {
        const ch = call.child(k);
        if (std.mem.eql(u8, ch.kind(), "arguments")) return ch.namedChildCount();
    }
    return 0;
}

fn argAt(call: ts.Node, i: u32) ?ts.Node {
    var k: u32 = 0;
    while (k < call.childCount()) : (k += 1) {
        const ch = call.child(k);
        if (std.mem.eql(u8, ch.kind(), "arguments")) {
            if (i < ch.namedChildCount()) return ch.namedChild(i);
            return null;
        }
    }
    return null;
}

fn lower(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

// ---------------------------------------------------------------------------

const TestRun = struct {
    rep: chk.Report,
    fn has(self: TestRun, rule: []const u8) bool {
        for (self.rep.findings.items) |f| if (std.mem.eql(u8, f.rule, rule)) return true;
        return false;
    }
};

fn run(gpa: std.mem.Allocator, src: []const u8, ctx: Ctx) !chk.Report {
    const p = ts.Parser.init();
    defer p.deinit();
    const tree = p.parse(src).?;
    defer tree.deinit();
    var rep = chk.Report.init(gpa);
    try check(gpa, tree.root(), "t.ring", src, &rep, ctx);
    return rep;
}

fn expectRule(gpa: std.mem.Allocator, src: []const u8, rule: []const u8, want: bool) !void {
    var rep = try run(gpa, src, .{});
    defer rep.deinit(gpa);
    var hit = false;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, rule)) hit = true;
    }
    if (hit != want) {
        std.debug.print("rule {s}: wanted {}, got {} for:\n{s}\n", .{ rule, want, hit, src });
        for (rep.findings.items) |f| std.debug.print("  got: {s} — {s}\n", .{ f.rule, f.message });
        return error.WrongVerdict;
    }
}

test "a return annotation without typehints is an error" {
    try expectRule(std.testing.allocator,
        \\int func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-hints-missing", true);
}

test "loading typehints silences it" {
    try expectRule(std.testing.allocator,
        \\load "typehints.ring"
        \\int func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-hints-missing", false);
}

test "parameter annotations alone need no library" {
    try expectRule(std.testing.allocator,
        \\func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-hints-missing", false);
}

test "a one-line class attribute is not a return annotation (ring samples oop1)" {
    // Class Point x y z func print — `z` is an attribute. Reading it as a
    // return type reported R24 on correct code in Ring's own samples.
    try expectRule(std.testing.allocator,
        \\New point { x=10  y=20  z=30  print() }
        \\Class Point x y z func print see x + nl + y + nl + z + nl
        \\
    , "rpp/type-hints-missing", false);
}

test "an attribute that happens to be named like a type is still an attribute" {
    try expectRule(std.testing.allocator,
        \\Class Rec name string func Show see string
        \\
    , "rpp/type-hints-missing", false);
}

test "a stray identifier on its own line is not a return annotation" {
    try expectRule(std.testing.allocator,
        \\int
        \\func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-hints-missing", false);
}

test "too many arguments" {
    try expectRule(std.testing.allocator,
        \\? Sum(1,2,3)
        \\
        \\func Sum(x, y)
        \\    return x + y
        \\
    , "rpp/type-arity", true);
}

test "too few arguments" {
    try expectRule(std.testing.allocator,
        \\? Sum(1)
        \\
        \\func Sum(x, y)
        \\    return x + y
        \\
    , "rpp/type-arity", true);
}

test "the right number of arguments is silent" {
    try expectRule(std.testing.allocator,
        \\? Sum(1,2)
        \\
        \\func Sum(x, y)
        \\    return x + y
        \\
    , "rpp/type-arity", false);
}

test "a call inside a class IS checked against the class's own method" {
    // This test used to assert the opposite -- that arity inside a class was
    // undecidable -- and it was wrong. Ring raises R20 here (measured), and
    // the whole method chain is visible, so the checker can say so. F-27.
    try expectRule(std.testing.allocator,
        \\class Thing
        \\    func Go
        \\        return Helper(1,2,3)
        \\    func Helper a
        \\        return a
        \\
    , "rpp/type-arity", true);
}

test "a method wins over a same-named global, so the METHOD's arity applies" {
    // Helper the global takes 1 and would be satisfied; Helper the method
    // takes 2 and is what runs (measured). Reporting is therefore correct.
    try expectRule(std.testing.allocator,
        \\func Helper x
        \\    return x
        \\
        \\class Thing
        \\    func Go
        \\        return Helper(1)
        \\    func Helper a, b
        \\        return a
        \\
    , "rpp/type-arity", true);
}

test "an INHERITED method is found through the parent chain" {
    try expectRule(std.testing.allocator,
        \\class Parent
        \\    func Helper a, b
        \\        return a
        \\
        \\class Child from Parent
        \\    func Go
        \\        return Helper(1)
        \\
    , "rpp/type-arity", true);
}

test "an UNKNOWN parent class means we refuse to guess" {
    // Elsewhere may define Helper with any arity, or not at all. The chain
    // is broken, so nothing is reported -- coverage given up on purpose.
    try expectRule(std.testing.allocator,
        \\func Helper x
        \\    return x
        \\
        \\class Child from SomethingNotInThisFile
        \\    func Go
        \\        return Helper(1, 2, 3)
        \\
    , "rpp/type-arity", false);
}

test "with no method anywhere up a KNOWN chain, the global applies" {
    try expectRule(std.testing.allocator,
        \\func Helper a, b
        \\    return a
        \\
        \\class Base
        \\    func Other
        \\        return 1
        \\
        \\class Child from Base
        \\    func Go
        \\        return Helper(1)
        \\
    , "rpp/type-arity", true);
}

test "`call name(...)` is a dynamic call through a variable, never checked" {
    // Ring's gameengine: `draw` is BOTH an attribute holding a callback and
    // a method. `call draw(a, b)` invokes the callback, so the method's
    // arity is irrelevant. Three false errors in ring127/libraries came
    // from missing this.
    try expectRule(std.testing.allocator,
        \\class T
        \\    draw = ""
        \\    func draw oGame
        \\        call draw(oGame, self)
        \\
    , "rpp/type-arity", false);
}

test "a correct call inside a class stays silent" {
    try expectRule(std.testing.allocator,
        \\class Thing
        \\    func Go
        \\        return Helper(1, 2)
        \\    func Helper a, b
        \\        return a
        \\
    , "rpp/type-arity", false);
}

test "a string literal for an int parameter" {
    try expectRule(std.testing.allocator,
        \\? Sum("a","b")
        \\
        \\func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-arg-mismatch", true);
}

test "a number literal for a string parameter" {
    try expectRule(std.testing.allocator,
        \\? Greet(42)
        \\
        \\func Greet(string s)
        \\    return s
        \\
    , "rpp/type-arg-mismatch", true);
}

test "a matching literal is silent" {
    try expectRule(std.testing.allocator,
        \\? Sum(1,2)
        \\
        \\func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-arg-mismatch", false);
}

test "an unannotated parameter is never a mismatch" {
    try expectRule(std.testing.allocator,
        \\? Sum("a","b")
        \\
        \\func Sum(x, y)
        \\    return x + y
        \\
    , "rpp/type-arg-mismatch", false);
}

test "a computed argument is not guessed at" {
    try expectRule(std.testing.allocator,
        \\? Sum(cName, nCount)
        \\
        \\func Sum(int x, int y)
        \\    return x + y
        \\
    , "rpp/type-arg-mismatch", false);
}

test "returning a string from an int function" {
    try expectRule(std.testing.allocator,
        \\load "typehints.ring"
        \\int func Bad(int x)
        \\    return "nope"
        \\
    , "rpp/type-return-mismatch", true);
}

test "returning a computed value is not guessed at" {
    try expectRule(std.testing.allocator,
        \\load "typehints.ring"
        \\int func Fine(int x)
        \\    return x * 2
        \\
    , "rpp/type-return-mismatch", false);
}

test "bool is not a Ring hint" {
    try expectRule(std.testing.allocator,
        \\func Test(bool b)
        \\    return b
        \\
    , "rpp/type-not-a-hint", true);
}

test "a class name as a parameter type is not reported" {
    // typehints.ring registers every class as a type, and the class may live
    // in a file we were not given. Reporting it would be a false positive.
    try expectRule(std.testing.allocator,
        \\func Take(stzString oS)
        \\    return oS
        \\
    , "rpp/type-not-a-hint", false);
}

test "clean annotated code produces nothing at all" {
    const gpa = std.testing.allocator;
    var rep = try run(gpa,
        \\load "typehints.ring"
        \\? Sum(1,2)
        \\
        \\int func Sum(int x, int y)
        \\    return x + y
        \\
    , .{});
    defer rep.deinit(gpa);
    if (rep.findings.items.len != 0) {
        for (rep.findings.items) |f| std.debug.print("unexpected: {s} — {s}\n", .{ f.rule, f.message });
        return error.FalsePositive;
    }
}

test "a declared return feeding a contradicting declared parameter" {
    // GetCount declares it returns a number; Greet declares it takes a
    // string. Both are declarations; one of them is lying.
    try expectRule(std.testing.allocator,
        \\load "typehints.ring"
        \\? Greet(GetCount())
        \\
        \\number func GetCount()
        \\    return 42
        \\
        \\func Greet(string s)
        \\    return s
        \\
    , "rpp/type-declared-conflict", true);
}

test "a declared return matching the declared parameter is silent" {
    try expectRule(std.testing.allocator,
        \\load "typehints.ring"
        \\? Greet(GetName())
        \\
        \\string func GetName()
        \\    return "x"
        \\
        \\func Greet(string s)
        \\    return s
        \\
    , "rpp/type-declared-conflict", false);
}

test "an UNANNOTATED call result is never judged" {
    try expectRule(std.testing.allocator,
        \\? Greet(GetCount())
        \\
        \\func GetCount()
        \\    return 42
        \\
        \\func Greet(string s)
        \\    return s
        \\
    , "rpp/type-declared-conflict", false);
}

test "an annotated parameter reassigned to a contradicting literal" {
    try expectRule(std.testing.allocator,
        \\func F(int x)
        \\    x = "abc"
        \\    return x
        \\
    , "rpp/type-declared-conflict", true);
}

test "reassignment to a matching literal, or of an unannotated param, is silent" {
    try expectRule(std.testing.allocator,
        \\func F(int x, y)
        \\    x = 5
        \\    y = "abc"
        \\    return x
        \\
    , "rpp/type-declared-conflict", false);
}

test "a call inside a brace block is a METHOD call and is never checked" {
    // Show(p) exists as a global with 1 param; inside `o { Show() }` the
    // name resolves to o's method. 340+ false positives on Softanza's test
    // suite taught this rule.
    try expectRule(std.testing.allocator,
        \\o = new Thing
        \\o { Show() }
        \\StzCharQ("x") { ? Show() }
        \\
        \\func Show p
        \\    return p
        \\
        \\class Thing
        \\    func Show
        \\        return 1
        \\
    , "rpp/type-arity", false);
}

test "the HEAD of a brace expression is still caller scope, still checked" {
    try expectRule(std.testing.allocator,
        \\Wrap(1, 2) { ? Anything() }
        \\
        \\func Wrap p
        \\    return p
        \\
    , "rpp/type-arity", true);
}

test "a nested function's assignments belong to the nested function" {
    // inner G's own `x` is a different variable; F's annotated x untouched
    try expectRule(std.testing.allocator,
        \\func F(int x)
        \\    return x
        \\
        \\func G(x)
        \\    x = "abc"
        \\    return x
        \\
    , "rpp/type-declared-conflict", false);
}

test "cross-file: an extern signature is checked and named" {
    const gpa = std.testing.allocator;
    const p = ts.Parser.init();
    defer p.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ext = std.StringHashMap(ExternSig).init(arena);
    const params = try arena.alloc(Param, 2);
    params[0] = .{ .ty = "", .name = "a" };
    params[1] = .{ .ty = "", .name = "b" };
    try ext.put("helper", .{ .file = "lib.ring", .sig = .{
        .display = "Helper",
        .lower = "helper",
        .params = params,
        .ret = "",
        .row = 0,
    } });

    const src = "? Helper(1)\n";
    const tree = p.parse(src).?;
    defer tree.deinit();
    var rep = chk.Report.init(gpa);
    defer rep.deinit(gpa);
    try check(gpa, tree.root(), "app.ring", src, &rep, .{ .extern_sigs = &ext });

    var hit = false;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/type-arity") and
            std.mem.indexOf(u8, f.message, "lib.ring") != null) hit = true;
    }
    try std.testing.expect(hit);
}

test "cross-file: a conflicted name is skipped, and the duplicate reported" {
    const gpa = std.testing.allocator;
    const p = ts.Parser.init();
    defer p.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var conf = std.StringHashMap(void).init(arena);
    try conf.put("same", {});
    const dups = [_]DupNote{.{ .name = "Same", .file_a = "a.ring", .row_a = 0, .file_b = "b.ring", .row_b = 0 }};

    const src = "load \"a.ring\"\nload \"b.ring\"\n? Same(1,2,3)\n";
    const tree = p.parse(src).?;
    defer tree.deinit();
    var rep = chk.Report.init(gpa);
    defer rep.deinit(gpa);
    try check(gpa, tree.root(), "main.ring", src, &rep, .{ .conflicted = &conf, .duplicates = &dups });

    var dup_hit = false;
    var arity_hit = false;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/type-duplicate-func")) dup_hit = true;
        if (std.mem.eql(u8, f.rule, "rpp/type-arity")) arity_hit = true;
    }
    try std.testing.expect(dup_hit);
    try std.testing.expect(!arity_hit); // conflicted: checking either def would be arbitrary
}

test "the scan-wide load downgrades the error to a note" {
    const gpa = std.testing.allocator;
    var rep = try run(gpa,
        \\int func Sum(int x, int y)
        \\    return x + y
        \\
    , .{ .typehints_loaded_in_scan = true });
    defer rep.deinit(gpa);
    var sev: ?chk.Severity = null;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/type-hints-missing")) sev = f.severity;
    }
    try std.testing.expectEqual(chk.Severity.note, sev.?);
}
