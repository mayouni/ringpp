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

const Param = struct { ty: []const u8, name: []const u8 };

const Sig = struct {
    name: []const u8,
    params: []Param,
    row: u32,
};

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

    // 1. Signatures of functions that a plain unqualified call can reach.
    //
    //    Only the ones at file level and BEFORE the first class: every func
    //    after the first class is a method of it (FINDINGS F-21), and an
    //    unqualified call to a method resolves by different rules. Including
    //    them would produce arity errors on correct code.
    var sigs = std.StringHashMap(Sig).init(arena);
    var first_class_row: u32 = std.math.maxInt(u32);
    {
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
            const sig = Sig{
                .name = nm.text(),
                .params = try paramsOf(arena, n),
                .row = n.start().row,
            };
            const key = try lower(arena, nm.text());
            // A redefinition is Ring's problem, not ours; keep the first.
            if (!sigs.contains(key)) try sigs.put(key, sig);
        }
    }

    var w = Walker{
        .gpa = gpa,
        .arena = arena,
        .report = report,
        .file = file,
        .sigs = &sigs,
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
    sigs: *std.StringHashMap(Sig),
    loads_hints: bool,
    ctx: Ctx,

    fn visit(self: *Walker, n: ts.Node, in_class: bool) !void {
        const kind = n.kind();
        const now_in_class = in_class or isClass(n);

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

    fn checkCall(self: *Walker, n: ts.Node, in_class: bool) !void {
        const callee = calleeName(n);
        if (callee.len == 0) return;

        // Inside a class body an unqualified call finds a METHOD before
        // anything else (FINDINGS F-17), so a same-named global function is
        // not necessarily what runs. Arity and argument types are both
        // undecidable here without resolving the class, so neither is
        // reported. That is coverage given up to keep certainty.
        if (in_class) return;

        const key = lower(self.arena, callee) catch return;
        const sig = self.sigs.get(key) orelse return;

        // RULE 2. Arity. Ring DOES enforce this: R19 too few, R20 too many.
        const nargs = argCount(n);
        const nparams: u32 = @intCast(sig.params.len);
        if (nargs != nparams) {
            const code = if (nargs < nparams) "R19" else "R20";
            try self.report.add(self.gpa, self.file, n, .err, "rpp/type-arity", "{s}() takes {d} argument(s), called with {d} — Error ({s}) at run time", .{ sig.name, nparams, nargs, code }, "Ring checks arity even though it does not check types: R19 is 'Calling function with less number of parameters', R20 'with extra'. Ring has no default parameters, so the count is exact. The definition is in this file and before the first class, so this call cannot be reaching a different one.");
            return; // the argument types below would only add noise
        }

        // RULE 3. A literal argument that contradicts the parameter type.
        var i: u32 = 0;
        while (i < nparams) : (i += 1) {
            const p = sig.params[i];
            if (p.ty.len == 0) continue;
            const a = argAt(n, i) orelse continue;
            const lit = literalOf(a);
            const bad = switch (lit) {
                .text => isNumericType(p.ty),
                .number => isTextType(p.ty) or isAggregateType(p.ty),
                .none => false,
            };
            if (bad) {
                try self.report.add(self.gpa, self.file, a, .warn, "rpp/type-arg-mismatch", "{s}() declares '{s} {s}', called here with a literal {s}", .{ sig.name, p.ty, p.name, lit.word() }, "Ring accepts this: parameter annotations are parsed and thrown away, never checked. The call runs and the operators inside behave as the value's real type — Sum(\"a\",\"b\") on 'int x, int y' returns \"ab\", not 3. See FINDINGS F-24 and DESIGN_TOOLCHAIN section 3.");
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

test "a method is not arity-checked as a function (F-21, F-17)" {
    // Every func after the first class is a method, and an unqualified call
    // inside a class finds the method first. Both make arity undecidable.
    try expectRule(std.testing.allocator,
        \\class Thing
        \\    func Go
        \\        return Helper(1,2,3)
        \\    func Helper(a)
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
