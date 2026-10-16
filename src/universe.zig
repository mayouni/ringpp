//! The DEFINITION UNIVERSE for `rnxc check` -- what the absence rules need
//! to know about everything the load unit defines.
//!
//! Four rules can only speak when they can see EVERYTHING a program could
//! reach, because each one reports an absence as a certainty:
//!
//!     rpp/undefined-function    a bare call nothing defines   -> R3  (F-46)
//!     rpp/uninitialized-variable a read nothing assigns       -> R24 (F-47)
//!     rpp/unknown-class         `new X` / `from X`, no class X -> R11/R15 (F-48)
//!     rpp/unknown-package       `import P`, no package P      -> R25 (F-48)
//!
//! types.zig has consumed this through `types.Ctx` all along. What was
//! missing since 2026-09-08 is the PRODUCER: the library-era CLI built it
//! from src/project.zig, and both went with the library half (52ed663).
//! `rnxc check` passed `.{}`, every map was null, and the four rules sat
//! silent for fourteen days on a gate that said so and counted them.
//!
//! WHAT CHANGED IN THE PORT, and it is the one thing that is not a copy.
//! The old tool scanned a TREE of files and had to discover which of them
//! were programs. `rnxc check <file>` takes one ROOT and walks its loads the
//! way Ring does (src/rnxc.zig, loadUnit), so the unit it hands over IS the
//! program: the root and everything it can reach. That makes the maps below
//! the program's own universe rather than a union over unrelated programs.
//!
//! WHAT DID NOT CHANGE, and each line of it was paid for once already:
//!
//!   the maps are UNIT-WIDE, never per-file. The per-closure version shipped
//!       first in the old tool and produced 17 false R11s in
//!       ring127/applications -- a fragment's own loads point the wrong way
//!       to show it its runtime world, which whoever LOADS it defines.
//!
//!   ONE HOLE ANYWHERE SILENCES THE RULES FOR THE WHOLE UNIT. A file that did
//!       not parse hides an unknown number of definitions; a load that could
//!       not be read hides a whole file; loadlib() registers natives nobody
//!       can see; eval() can define anything. A rule that says "R3 the moment
//!       this line runs" may not speak over a universe with a hole in it.
//!       NO VERDICT BEATS A WRONG ONE.
//!
//!   VARIABLES HAVE A WEAKER GATE THAN FUNCTIONS. loadlib cannot create a
//!       Ring variable, and an eval whose target is written as a literal --
//!       `eval("_bOk_ = (" + c + ")")` -- has already named what it assigns.
//!       Only an eval whose target cannot be read ends variable reasoning.
//!       So a unit that loads a native library can still have its R24s.
//!
//!   The textual probes (loadlib/eval) are deliberately generous: a match
//!       inside a comment or a string SUPPRESSES a rule, it never asserts
//!       one, so over-matching costs coverage and can never cost a false
//!       positive.

const std = @import("std");
const ts = @import("ts.zig");
const types = @import("types.zig");

/// What one file contributes. Scanned once, from the tree the loader already
/// parsed -- nothing here re-reads or re-parses a file.
const FileScan = struct {
    parsed_ok: bool,
    has_dynamic: bool,
    has_opaque_eval: bool,
    eval_names: []const []const u8,
    defnames: []const []const u8,
    globalnames: []const []const u8,
    classnames: []const []const u8,
    packagenames: []const []const u8,
    loads_typehints: bool,
};

pub const Universe = struct {
    /// The function gate: every file parsed, every load read, and nothing
    /// anywhere calls loadlib()/loadlibfile()/eval().
    complete: bool,
    /// The variable gate: every file parsed, every load read, and no eval
    /// whose target cannot be read. Holds wherever `complete` does.
    complete_vars: bool,
    typehints: bool,

    all_defined: std.StringHashMap(void),
    all_globals: std.StringHashMap(void),
    all_classes: std.StringHashMap(void),
    all_packages: std.StringHashMap(void),
    all_defined_vars: std.StringHashMap(void),
    all_globals_vars: std.StringHashMap(void),

    /// Why a gate is shut, for the one line `rnxc check` prints about it.
    /// A rule that stays silent must be able to say why, or silence reads as
    /// a clean bill of health.
    reason: []const u8,

    /// Build it from the loader's own trees. `missing` is how many `load`
    /// targets the loader could not read -- each one a whole file this pass
    /// cannot see.
    pub fn build(
        arena: std.mem.Allocator,
        roots: []const ts.Node,
        missing: u32,
    ) !Universe {
        var u = Universe{
            .complete = true,
            .complete_vars = true,
            .typehints = false,
            .all_defined = std.StringHashMap(void).init(arena),
            .all_globals = std.StringHashMap(void).init(arena),
            .all_classes = std.StringHashMap(void).init(arena),
            .all_packages = std.StringHashMap(void).init(arena),
            .all_defined_vars = std.StringHashMap(void).init(arena),
            .all_globals_vars = std.StringHashMap(void).init(arena),
            .reason = "",
        };
        if (missing > 0) {
            u.complete = false;
            u.complete_vars = false;
            u.reason = "a loaded file could not be read";
        }
        // A UNIT THAT RUNS NOTHING IS A LIBRARY, AND A LIBRARY IS NOT A
        // PROGRAM. With no top level and no Main anywhere, Ring runs it by
        // defining functions and stopping -- so "R3 the moment this line
        // runs" cannot be true of it: nothing runs. Its lines run only when
        // something ELSE loads it, and that something's universe is not in
        // this unit. Silence is exact here, not cautious.
        //
        // THE UNIT, NOT THE ROOT. The first version asked the root alone, and
        // the Softanza aggregator exposed it: stzLib.ring is a single `load`,
        // so its own file has no top level -- yet running it runs every loaded
        // file's top level AT its load, and a Main in a loaded file is called
        // too (F-60, measured). Asking the root called a runnable program a
        // library. The rule is only exact when it asks what Ring runs.
        //
        // Measured before it was written: checked ALONE, stkRingFuncs.ring
        // reported 26 undefined functions and stzCalendar.ring 26 unknown
        // classes and 3 uninitialised reads -- `split` and `EvenOrOdd` live in
        // Ring's stdlibcore, which the aggregator loads and a lone fragment
        // does not. Every one of the six fixtures has an entry point, so none
        // of them is touched by this.
        var runnable = false;
        for (roots) |r| {
            if (hasEntryPoint(r)) {
                runnable = true;
                break;
            }
        }
        if (roots.len > 0 and !runnable) {
            u.complete = false;
            u.complete_vars = false;
            if (u.reason.len == 0) u.reason = "nothing in this unit runs -- no top level and no Main, " ++
                "so it is a library, and a library's calls resolve through whoever " ++
                "loads it; check the program that does";
        }

        const scans = try arena.alloc(FileScan, roots.len);
        for (roots, 0..) |r, i| {
            scans[i] = try scan(arena, r);
            const s = scans[i];
            if (s.loads_typehints) u.typehints = true;
            if (!s.parsed_ok) {
                u.complete = false;
                u.complete_vars = false;
                if (u.reason.len == 0) u.reason = "a loaded file did not parse";
            }
            if (s.has_dynamic and u.complete) {
                u.complete = false;
                if (u.reason.len == 0) u.reason = "the unit calls loadlib() or eval()";
            }
            if (s.has_opaque_eval and u.complete_vars) {
                u.complete_vars = false;
            }
        }

        if (u.complete) {
            for (scans) |s| {
                for (s.defnames) |n| try u.all_defined.put(n, {});
                for (s.globalnames) |n| try u.all_globals.put(n, {});
                for (s.classnames) |n| try u.all_classes.put(n, {});
                for (s.packagenames) |n| try u.all_packages.put(n, {});
            }
        }
        // Built separately, because the variable gate opens in units where
        // the function gate stays shut -- anything that loads a native.
        if (u.complete_vars) {
            for (scans) |s| {
                for (s.defnames) |n| try u.all_defined_vars.put(n, {});
                for (s.globalnames) |n| try u.all_globals_vars.put(n, {});
                // a transparent eval defines its target as surely as an
                // assignment does
                for (s.eval_names) |n| try u.all_globals_vars.put(n, {});
            }
        }
        return u;
    }

    /// The context one file is checked under. The maps are shared, not
    /// copied: they are the same universe for every file of the unit.
    pub fn ctx(self: *const Universe) types.Ctx {
        return .{
            .typehints_loaded_in_scan = self.typehints,
            .assert_undefined = self.complete,
            .assert_undefined_vars = self.complete_vars,
            .all_defined = if (self.complete) &self.all_defined else null,
            .all_globals = if (self.complete) &self.all_globals else null,
            .all_classes = if (self.complete) &self.all_classes else null,
            .all_packages = if (self.complete) &self.all_packages else null,
            .all_defined_vars = if (self.complete_vars) &self.all_defined_vars else null,
            .all_globals_vars = if (self.complete_vars) &self.all_globals_vars else null,
        };
    }
};

fn scan(arena: std.mem.Allocator, root: ts.Node) !FileScan {
    const src = root.src;
    var s = FileScan{
        .parsed_ok = !root.hasError(),
        .has_dynamic = hasCallTo(src, "loadlib") or hasCallTo(src, "loadlibfile") or
            hasCallTo(src, "eval"),
        .has_opaque_eval = false,
        .eval_names = &.{},
        .defnames = &.{},
        .globalnames = &.{},
        .classnames = &.{},
        .packagenames = &.{},
        .loads_typehints = std.mem.indexOf(u8, src, "typehints") != null,
    };
    // A file that did not parse contributes NOTHING: tree-sitter's recovery
    // invents call shapes that are not in the source (a `SortLists()` inside
    // a block comment was reported once, in Softanza). It still closes the
    // gates, above -- a hole is a hole.
    if (!s.parsed_ok) return s;

    var ev = std.ArrayList([]const u8){};
    s.has_opaque_eval = scanEvals(arena, src, &ev) catch true;
    s.eval_names = try ev.toOwnedSlice(arena);

    var dn = std.ArrayList([]const u8){};
    try collectDefNames(arena, root, &dn);
    s.defnames = try dn.toOwnedSlice(arena);
    var gn = std.ArrayList([]const u8){};
    try collectGlobalNames(arena, root, &gn);
    s.globalnames = try gn.toOwnedSlice(arena);
    var cn = std.ArrayList([]const u8){};
    try collectClassNames(arena, root, &cn);
    s.classnames = try cn.toOwnedSlice(arena);
    var pn = std.ArrayList([]const u8){};
    try collectPackageNames(arena, root, &pn);
    s.packagenames = try pn.toOwnedSlice(arena);
    return s;
}

/// Would Ring RUN this file -- does it have a top level, or a Main (F-60)?
///
/// POSITION, not nesting, and that is the whole difficulty. The grammar does
/// not reliably keep a function's body inside the function: statements after
/// the first one can surface as siblings at FILE level (F-21, F-58), so a
/// walk that counted file-level statements would find "top-level code" in
/// every library there is. Ring's own rule is positional -- a function owns
/// everything up to the next `func` -- so a statement is top-level only when
/// it comes BEFORE the first definition. That is the rule the compiler
/// reconstructs too, and the two cannot disagree.
///
/// A `func main` counts only before the first class: after one, F-21 makes
/// it a METHOD, and a method named Main is not called (F-60, measured).
/// `load` is a directive, not code, and a comment is nothing; an `import`
/// IS code -- it resolves at run time and can raise R25.
fn hasEntryPoint(root: ts.Node) bool {
    var seen_def = false;
    var seen_class = false;
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const c = root.namedChild(i);
        const k = c.kind();
        if (std.mem.eql(u8, k, "comment") or std.mem.eql(u8, k, "load_statement")) continue;
        if (std.mem.eql(u8, k, "function_definition")) {
            if (!seen_class) {
                const nm = c.field("name");
                if (!nm.isNull() and std.ascii.eqlIgnoreCase(nm.text(), "main")) return true;
            }
            seen_def = true;
            continue;
        }
        if (std.mem.eql(u8, k, "class_definition") or std.mem.eql(u8, k, "package_definition")) {
            seen_def = true;
            seen_class = true;
            continue;
        }
        if (!seen_def) return true;
    }
    return false;
}

fn lower(arena: std.mem.Allocator, t: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, t.len);
    for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

/// Every function_definition and class_definition name, lower-cased. The
/// GENEROUS set, on purpose: a library's calls resolve at runtime through
/// whoever loaded it, so the first sweep without this breadth produced 4,429
/// false positives in Softanza alone.
fn collectDefNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition")) {
        const nm = n.field("name");
        if (!nm.isNull()) try out.append(arena, try lower(arena, nm.text()));
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectDefNames(arena, n.child(i), out);
}

/// Top-level write targets -- assignment LHS identifiers, for-variables and
/// give-targets -- WITHOUT descending into functions, classes, anonymous
/// functions or brace blocks, which are other scopes. In Ring these are
/// GLOBALS, visible inside every function of every file the program loaded
/// (verified cross-file on 1.27).
fn collectGlobalNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "function_definition") or
        std.mem.eql(u8, k, "class_definition") or
        std.mem.eql(u8, k, "anonymous_function") or
        std.mem.eql(u8, k, "brace_expression")) return;
    if (std.mem.eql(u8, k, "assignment_expression") or
        std.mem.eql(u8, k, "for_statement") or
        std.mem.eql(u8, k, "give_statement"))
    {
        if (n.namedChildCount() > 0) {
            const c = n.namedChild(0);
            // a member or subscript target is not a plain name
            if (std.mem.eql(u8, c.kind(), "identifier"))
                try out.append(arena, try lower(arena, c.text()));
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectGlobalNames(arena, n.child(i), out);
}

/// Class names only, at any depth (packages nest them). `new X` and `from X`
/// accept nothing else -- verified on 1.27: a FUNCTION named X raises R11 --
/// so this, and not the generous defnames, is the right suppression set.
fn collectClassNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, n.kind(), "class_definition")) {
        const nm = n.field("name");
        if (!nm.isNull()) try out.append(arena, try lower(arena, nm.text()));
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectClassNames(arena, n.child(i), out);
}

/// Package names, dotted parts joined and lower-cased: `import` matches the
/// FULL dotted name (verified on 1.27).
fn collectPackageNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, n.kind(), "package_definition")) {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const q = n.namedChild(i);
            if (std.mem.eql(u8, q.kind(), "qualified_identifier")) {
                if (try dottedLower(arena, q)) |name| try out.append(arena, name);
                break;
            }
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectPackageNames(arena, n.child(i), out);
}

/// "Sys" "Web" -> "sys.web"; null if any part is not a plain identifier.
fn dottedLower(arena: std.mem.Allocator, q: ts.Node) !?[]const u8 {
    var buf = std.ArrayList(u8){};
    var i: u32 = 0;
    while (i < q.namedChildCount()) : (i += 1) {
        const part = q.namedChild(i);
        if (!std.mem.eql(u8, part.kind(), "identifier")) return null;
        if (i > 0) try buf.append(arena, '.');
        for (part.text()) |c| try buf.append(arena, std.ascii.toLower(c));
    }
    if (buf.items.len == 0) return null;
    return try buf.toOwnedSlice(arena);
}

/// A case-insensitive `name(` probe. Textual on purpose -- see the header.
fn hasCallTo(src: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len < src.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(src[i .. i + needle.len], needle)) {
            var j = i + needle.len;
            while (j < src.len and (src[j] == ' ' or src[j] == 9)) j += 1;
            if (j < src.len and src[j] == '(') return true;
            i = j;
        }
    }
    return false;
}

/// The name a chunk of eval source assigns, when it OPENS with `name =`.
/// `'_bOk_ = (' + c + ')'` names _bOk_ whatever is appended, because the
/// target is fixed before the first concatenation. Anything else is opaque.
fn evalTargetOf(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == 9)) i += 1;
    if (i >= text.len or (text[i] != '"' and text[i] != '\'')) return null;
    const quote = text[i];
    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == 9)) i += 1;
    const start = i;
    if (i < text.len and (text[i] == '$' or text[i] == '@')) i += 1;
    if (i >= text.len or !(std.ascii.isAlphabetic(text[i]) or text[i] == '_')) return null;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    const name = text[start..i];
    while (i < text.len and (text[i] == ' ' or text[i] == 9)) i += 1;
    if (i >= text.len or text[i] != '=') return null;
    if (i + 1 < text.len and text[i + 1] == '=') return null; // a comparison
    if (std.mem.indexOfScalar(u8, name, quote) != null) return null;
    return name;
}

/// Classify every eval(): a transparent one gives up its target, one opaque
/// one ends variable reasoning for the whole unit. Returns whether any eval
/// was opaque.
fn scanEvals(arena: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !bool {
    var opaque_found = false;
    var i: usize = 0;
    while (i + 4 < src.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(src[i .. i + 4], "eval")) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(src[i - 1]) or src[i - 1] == '_')) continue;
        var j = i + 4;
        while (j < src.len and (src[j] == ' ' or src[j] == 9)) j += 1;
        if (j >= src.len or src[j] != '(') continue;
        j += 1;
        const rest = src[j..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (evalTargetOf(rest[0..end])) |nm| {
            try out.append(arena, try lower(arena, nm));
        } else {
            opaque_found = true;
        }
        i = j;
    }
    return opaque_found;
}
