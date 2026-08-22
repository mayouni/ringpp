//! `ringpp check` — the rules from docs/FINDINGS.md, applied to real source.
//!
//! Every rule traces to a measurement. No rule ships without a number behind
//! it, and every diagnostic names the finding it came from.

const std = @import("std");
const ts = @import("ts.zig");
const types = @import("types.zig");

pub const Severity = enum {
    err,
    warn,
    perf,
    note,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warn",
            .perf => "perf",
            .note => "note",
        };
    }
};

pub const Finding = struct {
    file: []const u8,
    row: u32,
    col: u32,
    severity: Severity,
    rule: []const u8,
    message: []const u8, // owned
    detail: []const u8, // owned, may be empty
};

pub const Report = struct {
    findings: std.ArrayList(Finding) = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Report {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        self.findings.deinit(gpa);
        self.arena.deinit();
    }

    pub fn add(
        self: *Report,
        gpa: std.mem.Allocator,
        file: []const u8,
        n: ts.Node,
        sev: Severity,
        rule: []const u8,
        comptime fmt: []const u8,
        args: anytype,
        detail: []const u8,
    ) !void {
        const a = self.arena.allocator();
        const p = n.start();
        try self.findings.append(gpa, .{
            .file = file,
            .row = p.row + 1,
            .col = p.col + 1,
            .severity = sev,
            .rule = rule,
            .message = try std.fmt.allocPrint(a, fmt, args),
            .detail = detail,
        });
    }

    pub const Counts = struct { err: usize = 0, warn: usize = 0, perf: usize = 0, note: usize = 0 };

    pub fn counts(self: Report) Counts {
        var r: Counts = .{};
        for (self.findings.items) |f| switch (f.severity) {
            .err => r.err += 1,
            .warn => r.warn += 1,
            .perf => r.perf += 1,
            .note => r.note += 1,
        };
        return r;
    }
};

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// The callee name of a call_expression, or "" when it is not a plain name.
fn calleeName(n: ts.Node) []const u8 {
    if (n.childCount() == 0) return "";
    const head = n.child(0);
    if (std.mem.eql(u8, head.kind(), "identifier")) return head.text();
    return "";
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

/// `:name` -> "name", `"name"` -> "name", otherwise null.
fn nameFromArg(n: ts.Node) ?[]const u8 {
    const k = n.kind();
    if (std.mem.eql(u8, k, "symbol")) {
        if (n.namedChildCount() > 0) return n.namedChild(0).text();
        const t = n.text();
        if (t.len > 1 and t[0] == ':') return t[1..];
        return null;
    }
    if (std.mem.eql(u8, k, "string")) {
        const t = n.text();
        if (t.len >= 2) return t[1 .. t.len - 1];
        return null;
    }
    return null;
}

fn insideLoop(n: ts.Node) bool {
    var cur = n.parent();
    var depth: u32 = 0;
    while (!cur.isNull() and depth < 64) : (depth += 1) {
        const k = cur.kind();
        if (std.mem.eql(u8, k, "for_statement") or
            std.mem.eql(u8, k, "while_statement") or
            std.mem.eql(u8, k, "do_again_statement")) return true;
        if (std.mem.eql(u8, k, "source_file")) return false;
        cur = cur.parent();
    }
    return false;
}

/// Functions whose result is a binary string that routinely begins with a
/// zero byte — the source shape that kills the process (FINDINGS F-14).
fn producesBinary(name: []const u8) bool {
    const names = [_][]const u8{ "double2bytes", "int2bytes", "float2bytes", "hex2str", "char" };
    for (names) |nm| if (eqIgnoreCase(name, nm)) return true;
    return false;
}

const Names = struct {
    known: std.StringHashMap(void),
    stringish: std.StringHashMap(void),
    pointerish: std.StringHashMap(void),

    fn init(gpa: std.mem.Allocator) Names {
        return .{
            .known = std.StringHashMap(void).init(gpa),
            .stringish = std.StringHashMap(void).init(gpa),
            .pointerish = std.StringHashMap(void).init(gpa),
        };
    }

    fn deinit(self: *Names, gpa: std.mem.Allocator) void {
        freeKeys(gpa, &self.known);
        freeKeys(gpa, &self.stringish);
        freeKeys(gpa, &self.pointerish);
    }
};

fn freeKeys(gpa: std.mem.Allocator, m: *std.StringHashMap(void)) void {
    var it = m.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    m.deinit();
}

/// Calls whose result is a C pointer. A name assigned one of these is never
/// a memcpy-into-a-string mistake.
fn producesPointer(name: []const u8) bool {
    const names = [_][]const u8{ "varptr", "nullptr", "obj2ptr", "ptr2obj", "getpointer", "fopen", "tempfile" };
    for (names) |nm| if (eqIgnoreCase(name, nm)) return true;
    return false;
}

/// Calls whose result is a Ring string.
fn producesString(name: []const u8) bool {
    const names = [_][]const u8{ "space", "copy", "char", "str2hex", "hex2str", "ptr2str", "left", "right", "substr", "read", "string", "lower", "upper", "trim" };
    for (names) |nm| if (eqIgnoreCase(name, nm)) return true;
    return false;
}

const Walker = struct {
    gpa: std.mem.Allocator,
    report: *Report,
    file: []const u8,
    known: *std.StringHashMap(void),
    stringish: *std.StringHashMap(void),
    pointerish: *std.StringHashMap(void),
    unparsed_reported: bool = false,
    in_class: bool = false,

    /// A class shadows a builtin harmfully only when it defines a method with
    /// that name AND calls the name unqualified with a different arity.
    fn checkShadowing(self: *Walker, class_node: ts.Node) !void {
        var methods = std.StringHashMap(u32).init(self.gpa);
        defer {
            var it = methods.keyIterator();
            while (it.next()) |k| self.gpa.free(k.*);
            methods.deinit();
        }
        try collectMethods(self.gpa, class_node, &methods);
        try self.findArityClash(class_node, &methods);
    }

    fn findArityClash(self: *Walker, n: ts.Node, methods: *std.StringHashMap(u32)) !void {
        if (std.mem.eql(u8, n.kind(), "call_expression")) {
            const callee = calleeName(n);
            if (callee.len > 0 and shadowsBuiltin(callee)) {
                const key = lowerBuf(callee);
                if (methods.get(key)) |nparams| {
                    const nargs = argCount(n);
                    if (nargs != nparams) {
                        try self.report.add(self.gpa, self.file, n, .warn, "rpp/method-shadows-builtin", "{s}() here resolves to this class's own method '{s}' ({d} parameter(s)), not the builtin — called with {d}", .{ callee, callee, nparams, nargs }, "Inside a class, an unqualified call finds a method before the builtin. This fails with Error (R20) 'Calling function with extra number of parameters', naming neither the method nor the builtin. Rename the method, or qualify the call. See FINDINGS F-17.");
                    }
                }
            }
        }
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try self.findArityClash(n.child(i), methods);
    }

    fn visit(self: *Walker, n: ts.Node) !void {
        const kind = n.kind();

        // A parse failure is NEVER reported as an error about the user's code.
        // tree-sitter is a lens, not a judge (docs/DESIGN_TOOLCHAIN.md Â§5): the
        // grammar can be wrong, and when it is, saying "your file is invalid"
        // would be a false positive. Ring's own scanner is the authority.
        // We say only what is true: rules were not applied here.
        if (n.isError() and !self.unparsed_reported) {
            self.unparsed_reported = true;
            try self.report.add(self.gpa, self.file, n, .note, "rpp/unparsed", "could not parse from here — no rules were applied to this file", .{}, "Either the file is not valid Ring, or the vendored grammar is behind Ring. Run `ring <file> -norun` to find out which. If Ring accepts it, that is a grammar bug for us to fix, not a problem with your code.");
        }

        if (std.mem.eql(u8, kind, "call_expression")) {
            const callee = calleeName(n);

            if (eqIgnoreCase(callee, "varptr")) {
                if (argAt(n, 0)) |a0| {
                    if (nameFromArg(a0)) |nm| {
                        if (!self.known.contains(lowerBuf(nm))) {
                            try self.report.add(self.gpa, self.file, a0, .err, "rpp/varptr-unknown-name", "varptr(:{s}) — no variable '{s}' is assigned anywhere in this file", .{ nm, nm }, "varptr resolves the name in the current scope, then globals. An unknown name raises Error (R6), which a surrounding try/catch will swallow silently — leaving a NULL pointer and a dead code path. See FINDINGS F-2.");
                        }
                    }
                }
                if (insideLoop(n)) {
                    try self.report.add(self.gpa, self.file, n, .perf, "rpp/varptr-in-loop", "varptr() inside a loop", .{}, "varptr costs ~790 ns per call — 12x an ordinary function call — because it does a name lookup and builds a C-pointer list. Take the pointer once, outside the loop. See FINDINGS F-4.");
                }
            }

            if (eqIgnoreCase(callee, "memcpy")) {
                if (argAt(n, 0)) |dst| {
                    // Only when the name is known to hold a STRING and is never
                    // assigned a pointer. A bare identifier is not enough: it may
                    // hold a varptr() result, which is the correct usage.
                    if (std.mem.eql(u8, dst.kind(), "identifier")) {
                        const nm = lowerBuf(dst.text());
                        if (self.stringish.contains(nm) and !self.pointerish.contains(nm)) {
                            try self.report.add(self.gpa, self.file, dst, .err, "rpp/memcpy-string-dest", "memcpy() into '{s}' does nothing — it holds a string, not a pointer", .{dst.text()}, "A string argument is copied onto the VM stack, so memcpy writes the copy and it is discarded. No error is raised. Write through a pointer instead: memcpy(varptr(:name, \"char *\"), ...). See FINDINGS F-1.");
                        }
                    }
                }
                if (argAt(n, 1)) |src| {
                    if (std.mem.eql(u8, src.kind(), "call_expression")) {
                        const sn = calleeName(src);
                        if (producesBinary(sn)) {
                            try self.report.add(self.gpa, self.file, src, .warn, "rpp/memcpy-nul-source", "memcpy() source {s}() may start with a zero byte", .{sn}, "On Ring <= 1.27 this aborts the process with no message, and try/catch cannot trap it: strcmp() in ring_vm_api_ispointer mistakes leading-zero binary data for a NULL pointer. Pass the source as a pointer instead. See FINDINGS F-14 and ring-lang/ring#1643.");
                        }
                    }
                }
            }

            if (eqIgnoreCase(callee, "ringvm_genarray") and insideLoop(n)) {
                try self.report.add(self.gpa, self.file, n, .note, "rpp/genarray-in-loop", "ringvm_genarray() inside a loop", .{}, "Worth it only when random reads outnumber mutations by roughly 10-20x; below that it costs up to 16x. One append frees the array, so it is rebuilt every round. See FINDINGS F-9 and F-10.");
            }

            if (eqIgnoreCase(callee, "substr") and insideLoop(n)) {
                try self.report.add(self.gpa, self.file, n, .perf, "rpp/substr-in-loop", "substr() inside a loop", .{}, "substr copies the WHOLE string before taking the slice: 12.5 us per call on a 500 KB string, and it grows with the string. ptr2str() through a cached pointer is ~0.09 us. See FINDINGS F-6.");
            }
        }

        // FINDINGS F-16: `try ... catch done` with nothing in the handler
        // leaks one VM stack slot per caught raise; ~1003 in a row is
        // Error (R4) Stack Overflow, from code with no recursion at all.
        if (std.mem.eql(u8, kind, "try_statement")) {
            if (emptyCatchAt(n)) |cn| {
                try self.report.add(self.gpa, self.file, cn, .warn, "rpp/empty-catch", "empty catch — this leaks a VM stack slot per caught error", .{}, "Ring pops the raised value only when something follows to consume it. About 1003 consecutive empty-catch raises abort with Error (R4) Stack Overflow. Put any statement in the handler — even one assignment. See FINDINGS F-16.");
            }
        }

        // FINDINGS F-17: inside a class, an unqualified call resolves to a
        // METHOD before the builtin. A method named `Copy` is fine on its own;
        // it only bites when the SAME class also calls copy() unqualified with
        // a different argument count — that is the Error (R20). Fire on the
        // collision, never on the name.
        if (std.mem.eql(u8, kind, "class_definition")) try self.checkShadowing(n);

        const was_in_class = self.in_class;
        if (std.mem.eql(u8, kind, "class_definition")) self.in_class = true;
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try self.visit(n.child(i));
        self.in_class = was_in_class;
    }
};

fn argCount(call: ts.Node) u32 {
    var k: u32 = 0;
    while (k < call.childCount()) : (k += 1) {
        const ch = call.child(k);
        if (std.mem.eql(u8, ch.kind(), "arguments")) return ch.namedChildCount();
    }
    return 0;
}

fn paramCount(fn_node: ts.Node) u32 {
    const pl = fn_node.field("parameters");
    if (pl.isNull()) return 0;
    return pl.namedChildCount();
}

fn collectMethods(gpa: std.mem.Allocator, n: ts.Node, out: *std.StringHashMap(u32)) !void {
    if (std.mem.eql(u8, n.kind(), "function_definition")) {
        const nm = n.field("name");
        if (!nm.isNull() and shadowsBuiltin(nm.text())) {
            const key = try gpa.alloc(u8, nm.text().len);
            for (nm.text(), 0..) |ch, i| key[i] = std.ascii.toLower(ch);
            if (out.contains(key)) {
                gpa.free(key);
            } else {
                try out.put(key, paramCount(n));
            }
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectMethods(gpa, n.child(i), out);
}

/// The catch clause of a try_statement, when its body is empty.
fn emptyCatchAt(n: ts.Node) ?ts.Node {
    var i: u32 = 0;
    var seen_catch = false;
    var body_nodes: u32 = 0;
    var catch_node: ts.Node = undefined;
    while (i < n.childCount()) : (i += 1) {
        const ch = n.child(i);
        const t = ch.text();
        if (!seen_catch and (std.ascii.eqlIgnoreCase(t, "catch") or std.ascii.eqlIgnoreCase(t, "but"))) {
            seen_catch = true;
            catch_node = ch;
            continue;
        }
        if (seen_catch) {
            if (std.ascii.eqlIgnoreCase(t, "done") or std.ascii.eqlIgnoreCase(t, "off")) break;
            if (tsc.ts_node_is_named(ch.raw)) body_nodes += 1;
        }
    }
    if (seen_catch and body_nodes == 0) return catch_node;
    return null;
}

const tsc = ts.c;

/// Builtins a method name would shadow inside its own class.
fn shadowsBuiltin(name: []const u8) bool {
    const names = [_][]const u8{
        "len",   "copy",   "left",   "right", "find",  "sort",  "type",  "space",
        "read",  "write",  "list",   "add",   "del",   "insert", "lower", "upper",
        "trim",  "substr", "number", "string", "reverse", "max", "min",  "sum",
    };
    for (names) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

var lower_scratch: [256]u8 = undefined;
fn lowerBuf(s: []const u8) []const u8 {
    const n = @min(s.len, lower_scratch.len);
    for (s[0..n], 0..) |ch, i| lower_scratch[i] = std.ascii.toLower(ch);
    return lower_scratch[0..n];
}

fn firstLine(s: []const u8) []const u8 {
    const n = @min(s.len, 60);
    const cut = std.mem.indexOfAny(u8, s[0..n], "\r\n") orelse n;
    return s[0..cut];
}

/// Every identifier that is assigned, declared as a parameter, or named as a
/// class attribute. Approximate on purpose: it exists to answer "does this
/// name exist at all in this file", which is what catches a typo'd varptr.
fn collectKnown(gpa: std.mem.Allocator, n: ts.Node, names: *Names) !void {
    const out = &names.known;
    const kind = n.kind();
    if (std.mem.eql(u8, kind, "assignment_expression")) {
        if (n.childCount() > 0) {
            const lhs = n.child(0);
            const is_name = std.mem.eql(u8, lhs.kind(), "identifier") or
                std.mem.eql(u8, lhs.kind(), "member_expression");
            if (std.mem.eql(u8, lhs.kind(), "identifier")) try put(gpa, out, lhs.text());
            if (is_name and n.childCount() >= 3) {
                const rhs = n.child(n.childCount() - 1);
                const target = lhs.text();
                if (std.mem.eql(u8, rhs.kind(), "string")) {
                    try put(gpa, &names.stringish, target);
                } else if (std.mem.eql(u8, rhs.kind(), "call_expression")) {
                    const cn = calleeName(rhs);
                    if (producesPointer(cn)) try put(gpa, &names.pointerish, target);
                    if (producesString(cn)) try put(gpa, &names.stringish, target);
                } else if (std.mem.eql(u8, rhs.kind(), "binary_expression")) {
                    // string concatenation is the common case for `a = b + c`
                    try put(gpa, &names.stringish, target);
                }
            }
        }
    } else if (std.mem.eql(u8, kind, "typed_parameter")) {
        const nm = n.field("name");
        if (!nm.isNull()) try put(gpa, out, nm.text());
    } else if (std.mem.eql(u8, kind, "param_list")) {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const p = n.namedChild(i);
            if (std.mem.eql(u8, p.kind(), "identifier")) try put(gpa, out, p.text());
        }
    } else if (std.mem.eql(u8, kind, "expression_statement")) {
        // A bare identifier statement inside a class body declares an attribute.
        if (n.namedChildCount() == 1) {
            const only = n.namedChild(0);
            if (std.mem.eql(u8, only.kind(), "identifier")) try put(gpa, out, only.text());
        }
    } else if (std.mem.eql(u8, kind, "for_statement")) {
        const v = n.field("variable");
        if (!v.isNull()) try put(gpa, out, v.text());
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectKnown(gpa, n.child(i), names);
}

fn put(gpa: std.mem.Allocator, out: *std.StringHashMap(void), name: []const u8) !void {
    const buf = try gpa.alloc(u8, name.len);
    for (name, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    if (out.contains(buf)) {
        gpa.free(buf);
        return;
    }
    try out.put(buf, {});
}

pub fn checkSource(
    gpa: std.mem.Allocator,
    parser: ts.Parser,
    file: []const u8,
    src: []const u8,
    report: *Report,
) !void {
    return checkSourceCtx(gpa, parser, file, src, report, .{});
}

pub fn checkSourceCtx(
    gpa: std.mem.Allocator,
    parser: ts.Parser,
    file: []const u8,
    src: []const u8,
    report: *Report,
    tctx: types.Ctx,
) !void {
    const tree = parser.parse(src) orelse return;
    defer tree.deinit();

    var names = Names.init(gpa);
    defer names.deinit(gpa);

    // Names Ring always provides.
    for ([_][]const u8{ "self", "this", "true", "false", "null", "nl" }) |b| try put(gpa, &names.known, b);
    try collectKnown(gpa, tree.root(), &names);

    var w = Walker{
        .gpa = gpa,
        .report = report,
        .file = file,
        .known = &names.known,
        .stringish = &names.stringish,
        .pointerish = &names.pointerish,
    };
    try w.visit(tree.root());

    // Level 1 type checking (DESIGN_TOOLCHAIN section 3). Kept in its own
    // module because it reasons about signatures across the whole file,
    // while the rules above are local to a node.
    try types.check(gpa, tree.root(), file, src, report, tctx);
}

test "flags a varptr on a name that does not exist" {
    const gpa = std.testing.allocator;
    const p = ts.Parser.init();
    defer p.deinit();
    var rep = Report.init(gpa);
    defer rep.deinit(gpa);

    const src =
        \\func InitLowLevel
        \\     _cBufferData_ = "abc"
        \\     pLow = varptr(:cBufferData, :char)
        \\
    ;
    try checkSource(gpa, p, "t.ring", src, &rep);

    var hit = false;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/varptr-unknown-name")) hit = true;
    }
    try std.testing.expect(hit);
}

test "does not flag a varptr on a name that exists" {
    const gpa = std.testing.allocator;
    const p = ts.Parser.init();
    defer p.deinit();
    var rep = Report.init(gpa);
    defer rep.deinit(gpa);

    const src =
        \\func Ok
        \\     cBuf = space(64)
        \\     p = varptr(:cBuf, "char *")
        \\
    ;
    try checkSource(gpa, p, "t.ring", src, &rep);
    for (rep.findings.items) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.rule, "rpp/varptr-unknown-name"));
    }
}

test "flags memcpy into a string variable" {
    const gpa = std.testing.allocator;
    const p = ts.Parser.init();
    defer p.deinit();
    var rep = Report.init(gpa);
    defer rep.deinit(gpa);

    const src =
        \\cDest = space(16)
        \\memcpy(cDest, "ABCDEFGH", 8)
        \\
    ;
    try checkSource(gpa, p, "t.ring", src, &rep);
    var hit = false;
    for (rep.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/memcpy-string-dest")) hit = true;
    }
    try std.testing.expect(hit);
}
