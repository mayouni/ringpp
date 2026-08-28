//! The project layer — cross-file type checking through the LOAD GRAPH.
//!
//! Until this module, `ringpp check` saw one file at a time: a call in
//! `app.ring` to a function defined in `lib.ring` was never checked, which
//! is precisely backwards for the large business projects the checker is
//! for — there, almost every call crosses a file.
//!
//! The soundness argument, and it rests on a measured Ring behaviour
//! (FINDINGS F-26): **a duplicate function name is C22, "Function
//! redefinition", at load time — the program never starts.** Therefore,
//! within one load graph, a name that resolves has EXACTLY ONE live
//! definition. So:
//!
//!   * a call in F to a name defined once across F's load closure is
//!     checked against that definition with the same certainty as a
//!     same-file call — no other definition can exist in a program that
//!     runs;
//!   * a name defined MORE than once inside one closure is itself the
//!     defect: that program dies with C22 before its first line. Reported
//!     as `rpp/type-duplicate-func`, at the JOIN file — the file whose
//!     loads first bring the two definitions together — not at every file
//!     downstream of it;
//!   * conflicted names are excluded from arity/type checking (the report
//!     would be against an arbitrary one of the two).
//!
//! What keeps it honest on a tree of INDEPENDENT programs (an examples/
//! directory, a tests/ directory): files are only related through `load`
//! edges they actually contain. Two files that both define `Mine()` but
//! never load each other are two programs; nothing is reported, nothing
//! is cross-checked. The scan root is not a program — the load graph is.
//!
//! Edges the scan cannot resolve — `load` of a computed expression, of a
//! library outside the scanned tree (`stdlib.ring`), of a missing file —
//! are simply absent. A missing edge means missing signatures, which means
//! FEWER checks, never wrong ones.

const std = @import("std");
const ts = @import("ts.zig");
const types = @import("types.zig");

pub const FileInfo = struct {
    /// the path as the walker produced it — used in messages
    path: []const u8,
    /// normalized (lower-case, forward slashes, . and .. folded) — identity
    norm: []const u8,
    /// normalized directory, for resolving this file's load targets
    sigs: []types.Collected,
    /// normalized resolved load targets (only ones that MAY be in the tree)
    loads: [][]const u8,
    loads_typehints: bool,
    /// Did tree-sitter parse this file completely?
    ///
    /// A file that did NOT is excluded from the project layer entirely --
    /// it exports no signatures and receives no cross-file findings. The
    /// reason is measured, not theoretical: on a partially-parsed file the
    /// recovery invented call shapes that are not in the source. Softanza's
    /// stzListOfPairsTest.ring produced an arity report for `SortLists()`
    /// sitting inside a BLOCK COMMENT, and tempo.ring one for a method call
    /// `Q("x").IsNumberInString()` that is not a global call at all. Both
    /// files already carry `rpp/unparsed`, whose promise is exactly "no
    /// rules were applied to this file" -- the cross-file layer was
    /// breaking that promise.
    ///
    /// The cost is real and is accepted: genuine findings in unparsed files
    /// are lost. A false positive in a clean file costs more.
    parsed_ok: bool,
    /// Does this file call loadlib()/loadlibfile() or eval() anywhere?
    /// Either one can add callable functions the static view cannot see —
    /// loadlib registers native functions at runtime, eval can define Ring
    /// ones — so their presence anywhere in a file's closure silences the
    /// undefined-function rule for that file. Softanza measures the cost of
    /// gating on eval: 26 eval() calls in base/string alone.
    has_dynamic: bool = false,
    /// Set by Project.build: some `load` target was NOT found in the checked
    /// set. Whatever that file defines is invisible here, so absence of a
    /// definition proves nothing.
    has_unresolved_load: bool = false,
    /// EVERY name this file defines in any form — top-level functions,
    /// methods inside classes, class names — lower-cased. This is the
    /// suppression set for rpp/undefined-function, and it is deliberately
    /// broader than what a bare call can legally reach: a library file's
    /// calls resolve at runtime through whoever loaded it, not through its
    /// own load lines, so the first sweep without this produced 4,429
    /// false positives in Softanza alone (StzRaise() etc., defined in
    /// sibling files the AGGREGATOR loads). Absence across the whole
    /// checked set is the only absence that proves anything.
    defnames: [][]const u8 = &.{},
    /// Names assigned at the TOP LEVEL of this file — main-scope code,
    /// outside any function or class. In Ring those are GLOBALS, visible
    /// inside every function of every file the running program loaded
    /// (verified cross-file on 1.27). Lower-cased. This is the
    /// suppression set for rpp/uninitialized-variable: a read inside a
    /// function is only reportable when no file's main scope could have
    /// supplied the name.
    globalnames: [][]const u8 = &.{},
    /// Class names ONLY, lower-cased, anywhere in the file (packages
    /// included). `new X` and `from X` accept nothing else -- verified on
    /// 1.27: a FUNCTION named X raises R11, a VARIABLE holding "X" raises
    /// R11 on the variable's own name -- so this narrower set is the
    /// semantically correct suppression for rpp/unknown-class, where the
    /// generous defnames would silence real errors.
    classnames: [][]const u8 = &.{},
};

/// Case-insensitive substring probe for the three calls that can create
/// functions invisibly (see FileInfo.has_dynamic). Textual on purpose: a
/// match inside a comment or string suppresses a rule (coverage lost), it
/// never asserts anything (no false positive possible from over-matching).
fn hasDynamicCall(src: []const u8) bool {
    for ([_][]const u8{ "loadlib", "loadlibfile", "eval" }) |needle| {
        var i: usize = 0;
        while (i + needle.len < src.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(src[i .. i + needle.len], needle)) {
                // require it to look like a CALL: next non-space is '('
                var j = i + needle.len;
                while (j < src.len and (src[j] == ' ' or src[j] == 9)) j += 1;
                if (j < src.len and src[j] == '(') return true;
                i = j;
            }
        }
    }
    return false;
}

/// Parse one file, extract what the project layer needs, FREE the tree.
/// Constant memory over the scan: the price is parsing twice (once here,
/// once in the check pass), which trades time for never holding two trees
/// at once — this machine has taught that lesson three times.
pub fn scanFile(
    arena: std.mem.Allocator,
    parser: ts.Parser,
    path: []const u8,
    src: []const u8,
) !FileInfo {
    var info = FileInfo{
        .path = try arena.dupe(u8, path),
        .norm = try normPath(arena, "", path),
        .sigs = &.{},
        .loads = &.{},
        .loads_typehints = std.mem.indexOf(u8, src, "typehints") != null,
        .parsed_ok = false,
    };

    const tree = parser.parse(src) orelse return info;
    defer tree.deinit();

    if (tree.root().hasError()) return info; // no signatures, no edges
    info.parsed_ok = true;
    info.has_dynamic = hasDynamicCall(src);
    info.sigs = try types.collectTopSigs(arena, tree.root());
    var dn = std.ArrayList([]const u8){};
    try collectDefNames(arena, tree.root(), &dn);
    info.defnames = try dn.toOwnedSlice(arena);
    var gn = std.ArrayList([]const u8){};
    try collectGlobalNames(arena, tree.root(), &gn);
    info.globalnames = try gn.toOwnedSlice(arena);
    var cn = std.ArrayList([]const u8){};
    try collectClassNames(arena, tree.root(), &cn);
    info.classnames = try cn.toOwnedSlice(arena);

    const dir = dirOf(path);
    var loads = std.ArrayList([]const u8){};
    try collectLoads(arena, tree.root(), dir, &loads);
    info.loads = try loads.toOwnedSlice(arena);
    return info;
}

/// Every function_definition and class_definition name in the tree,
/// lower-cased — see FileInfo.defnames for why this is the generous set.
fn collectDefNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition")) {
        const nm = n.field("name");
        if (!nm.isNull()) {
            const t = nm.text();
            const buf = try arena.alloc(u8, t.len);
            for (t, 0..) |c, i| buf[i] = std.ascii.toLower(c);
            try out.append(arena, buf);
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectDefNames(arena, n.child(i), out);
}

/// Top-level write targets: assignment LHS identifiers, for-variables and
/// give-targets, WITHOUT descending into functions, classes, anonymous
/// functions or brace blocks — those are other scopes.
fn collectGlobalNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "function_definition") or
        std.mem.eql(u8, k, "class_definition") or
        std.mem.eql(u8, k, "anonymous_function") or
        std.mem.eql(u8, k, "brace_expression")) return;
    var target: ?ts.Node = null;
    if (std.mem.eql(u8, k, "assignment_expression") or
        std.mem.eql(u8, k, "for_statement") or
        std.mem.eql(u8, k, "give_statement"))
    {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const c = n.namedChild(i);
            if (std.mem.eql(u8, c.kind(), "identifier")) {
                target = c;
                break;
            }
            break; // member/subscript target: not a plain name
        }
    }
    if (target) |t| {
        const txt = t.text();
        const buf = try arena.alloc(u8, txt.len);
        for (txt, 0..) |ch2, ix2| buf[ix2] = std.ascii.toLower(ch2);
        try out.append(arena, buf);
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectGlobalNames(arena, n.child(i), out);
}

/// class_definition names only, at any depth (packages nest them).
fn collectClassNames(arena: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, n.kind(), "class_definition")) {
        const nm = n.field("name");
        if (!nm.isNull()) {
            const t = nm.text();
            const buf = try arena.alloc(u8, t.len);
            for (t, 0..) |ch3, ix3| buf[ix3] = std.ascii.toLower(ch3);
            try out.append(arena, buf);
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectClassNames(arena, n.child(i), out);
}

fn collectLoads(
    arena: std.mem.Allocator,
    n: ts.Node,
    dir: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (std.mem.eql(u8, n.kind(), "load_statement")) {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const c = n.namedChild(i);
            if (!std.mem.eql(u8, c.kind(), "string")) continue; // computed: unresolvable
            const t = c.text();
            if (t.len < 2) continue;
            const target = t[1 .. t.len - 1];
            try out.append(arena, try normPath(arena, dir, target));
        }
        return;
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try collectLoads(arena, n.child(i), dir, out);
}

pub fn dirOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return "";
    return path[0..i];
}

/// Lexical normalization: join, forward slashes, fold "." and "..",
/// lower-case (Windows-style identity — the corpora this runs on live
/// there, and a false split on case would MISS checks, not invent them).
pub fn normPath(arena: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    const absolute = (rel.len >= 2 and rel[1] == ':') or
        (rel.len >= 1 and (rel[0] == '/' or rel[0] == '\\'));

    var segs = std.ArrayList([]const u8){};
    defer segs.deinit(arena);

    if (!absolute and base.len > 0) {
        var it = std.mem.tokenizeAny(u8, base, "/\\");
        while (it.next()) |s| try pushSeg(arena, &segs, s);
    }
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |s| try pushSeg(arena, &segs, s);

    var total: usize = 0;
    for (segs.items) |s| total += s.len + 1;
    var buf = try arena.alloc(u8, if (total == 0) 0 else total - 1);
    var pos: usize = 0;
    for (segs.items, 0..) |s, i| {
        if (i > 0) {
            buf[pos] = '/';
            pos += 1;
        }
        for (s) |c| {
            buf[pos] = std.ascii.toLower(c);
            pos += 1;
        }
    }
    return buf[0..pos];
}

fn pushSeg(arena: std.mem.Allocator, segs: *std.ArrayList([]const u8), s: []const u8) !void {
    if (std.mem.eql(u8, s, ".")) return;
    if (std.mem.eql(u8, s, "..")) {
        if (segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
            _ = segs.pop();
            return;
        }
    }
    try segs.append(arena, s);
}

// ---------------------------------------------------------------------------

pub const Project = struct {
    arena: std.mem.Allocator,
    files: []FileInfo,
    /// norm path -> index into files
    index: std.StringHashMap(u32),
    /// resolved load edges, files[i] -> indices it loads
    edges: [][]u32,
    /// transitive closure per file, EXCLUDING the file itself
    closures: [][]u32,
    /// MEMOIZED per file: names defined >1 times across own+closure.
    ///
    /// Computed once at build. The first version recomputed this for every
    /// DIRECT CHILD of every file inside viewFor — a hub file loaded by
    /// thousands of others was rescanned thousands of times, and the run
    /// against a 5,949-file tree took 303 s and then died OutOfMemory,
    /// because every intermediate map also lived in the run-long arena.
    conflicts: []std.StringHashMap(void),

    pub fn build(arena: std.mem.Allocator, files: []FileInfo) !Project {
        var index = std.StringHashMap(u32).init(arena);
        for (files, 0..) |f, i| try index.put(f.norm, @intCast(i));

        const edges = try arena.alloc([]u32, files.len);
        for (files, 0..) |f, i| {
            var e = std.ArrayList(u32){};
            for (f.loads) |t| {
                if (index.get(t)) |j| {
                    if (j != i) try e.append(arena, j);
                } else {
                    // A load whose target is outside the checked set: its
                    // definitions are invisible, so nothing downstream may
                    // claim a name is undefined (see View.assert_undefined).
                    files[i].has_unresolved_load = true;
                }
            }
            edges[i] = try e.toOwnedSlice(arena);
        }

        const closures = try arena.alloc([]u32, files.len);
        var seen = try arena.alloc(u32, files.len); // generation-stamped visited set
        @memset(seen, std.math.maxInt(u32));
        for (files, 0..) |_, i| {
            var out = std.ArrayList(u32){};
            var stack = std.ArrayList(u32){};
            defer stack.deinit(arena);
            const gen: u32 = @intCast(i);
            seen[i] = gen;
            for (edges[i]) |j| try stack.append(arena, j);
            while (stack.pop()) |j| {
                if (seen[j] == gen) continue;
                seen[j] = gen;
                try out.append(arena, j);
                for (edges[j]) |k| try stack.append(arena, k);
            }
            closures[i] = try out.toOwnedSlice(arena);
        }

        // The memoized conflict sets, one closure scan per file, exactly once.
        const conflicts = try arena.alloc(std.StringHashMap(void), files.len);
        var scratch_state = std.heap.ArenaAllocator.init(arena);
        defer scratch_state.deinit();
        for (files, 0..) |_, i| {
            _ = scratch_state.reset(.retain_capacity);
            const scratch = scratch_state.allocator();
            var counts = std.StringHashMap(u32).init(scratch);
            try countDefs(&counts, files, @intCast(i), closures[@intCast(i)]);
            conflicts[i] = std.StringHashMap(void).init(arena);
            var it = counts.iterator();
            while (it.next()) |e| {
                // keys reference sig.lower strings owned by `arena`, so they
                // outlive the scratch reset
                if (e.value_ptr.* > 1) try conflicts[i].put(e.key_ptr.*, {});
            }
        }

        return .{ .arena = arena, .files = files, .index = index, .edges = edges, .closures = closures, .conflicts = conflicts };
    }

    fn countDefs(counts: *std.StringHashMap(u32), files: []FileInfo, i: u32, closure: []u32) !void {
        for (files[i].sigs) |s| {
            const g = try counts.getOrPut(s.lower);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        for (closure) |j| {
            for (files[j].sigs) |s| {
                const g = try counts.getOrPut(s.lower);
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
            }
        }
    }

    const DefSite = struct { file: u32, sig: u32 };

    pub const View = struct {
        extern_sigs: std.StringHashMap(types.ExternSig),
        conflicted: std.StringHashMap(void),
        duplicates: []types.DupNote,
        /// True only when this file's WHOLE definition universe is visible:
        /// every `load` in its closure resolved into the checked set, and
        /// no file in the closure calls loadlib()/loadlibfile()/eval().
        /// Only then may a bare call with no definition be reported as the
        /// guaranteed R3 it is — anything less and the honest answer is
        /// silence, on the same NO VERDICT principle the CLI already
        /// applies to files it could not read.
        assert_undefined: bool = false,
    };

    /// What file `i`'s check pass may rely on. Allocates into `scratch`,
    /// which the CALLER owns and frees after the file is checked — a view
    /// must never outlive its file, or 6,000 of them accumulate and the
    /// process dies OutOfMemory (measured, 2026-08-23).
    ///
    /// Strings inside the view (names, paths, signature types) reference the
    /// project arena and stay valid; only the maps and slices are scratch.
    pub fn viewFor(self: *Project, scratch: std.mem.Allocator, i: u32) !View {
        // A file that did not parse gets an EMPTY view: no extern signatures,
        // no conflicts, no duplicates. `rpp/unparsed` already promises "no
        // rules were applied to this file", and this is what keeps that
        // promise true now that a cross-file layer exists. See FileInfo.
        if (!self.files[i].parsed_ok) {
            return .{
                .extern_sigs = std.StringHashMap(types.ExternSig).init(scratch),
                .conflicted = std.StringHashMap(void).init(scratch),
                .duplicates = &.{},
            };
        }

        var first = std.StringHashMap(DefSite).init(scratch);
        var second = std.StringHashMap(DefSite).init(scratch);
        try collectSites(&first, &second, self.files, i);
        for (self.closures[i]) |j| try collectSites(&first, &second, self.files, j);

        var extern_sigs = std.StringHashMap(types.ExternSig).init(scratch);
        var conflicted = std.StringHashMap(void).init(scratch);
        var dups = std.ArrayList(types.DupNote){};

        var it = first.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (second.get(name)) |b| {
                try conflicted.put(name, {});
                // A conflict already present in one DIRECT child belongs to
                // that child or deeper; reporting it again here would repeat
                // it at every file downstream. Memoized, so this is a lookup.
                var inherited = false;
                for (self.edges[i]) |c| {
                    if (self.conflicts[c].contains(name)) {
                        inherited = true;
                        break;
                    }
                }
                if (!inherited) {
                    const a = e.value_ptr.*;
                    try dups.append(scratch, .{
                        .name = self.files[a.file].sigs[a.sig].display,
                        .file_a = self.files[a.file].path,
                        .row_a = self.files[a.file].sigs[a.sig].row,
                        .file_b = self.files[b.file].path,
                        .row_b = self.files[b.file].sigs[b.sig].row,
                    });
                }
                continue;
            }
            const site = e.value_ptr.*;
            if (site.file == i) continue; // local: the per-file pass has it
            try extern_sigs.put(name, .{
                .file = self.files[site.file].path,
                .sig = self.files[site.file].sigs[site.sig],
            });
        }

        // The whole definition universe must be visible before absence
        // proves anything: the file itself and every file its loads reach,
        // each fully parsed, each load resolved, none of them calling
        // loadlib/loadlibfile/eval.
        var can_assert = self.files[i].parsed_ok and
            !self.files[i].has_dynamic and
            !self.files[i].has_unresolved_load;
        if (can_assert) {
            for (self.closures[i]) |j| {
                if (!self.files[j].parsed_ok or
                    self.files[j].has_dynamic or
                    self.files[j].has_unresolved_load)
                {
                    can_assert = false;
                    break;
                }
            }
        }

        return .{
            .extern_sigs = extern_sigs,
            .conflicted = conflicted,
            .duplicates = try dups.toOwnedSlice(scratch),
            .assert_undefined = can_assert,
        };
    }

    fn collectSites(
        first: *std.StringHashMap(DefSite),
        second: *std.StringHashMap(DefSite),
        files: []FileInfo,
        j: u32,
    ) !void {
        for (files[j].sigs, 0..) |s, k| {
            const g = try first.getOrPut(s.lower);
            if (!g.found_existing) {
                g.value_ptr.* = .{ .file = j, .sig = @intCast(k) };
            } else if (!second.contains(s.lower)) {
                try second.put(s.lower, .{ .file = j, .sig = @intCast(k) });
            }
        }
    }
};

// ---------------------------------------------------------------------------

test "an unparsed file neither exports signatures nor receives findings" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    const p = ts.Parser.init();
    defer p.deinit();

    // `/*` opens a block comment that swallows the rest -- tree-sitter
    // recovers by inventing shapes, and one of those inventions produced a
    // real false positive on Softanza (SortLists() INSIDE a comment).
    const broken = "func Real a, b\n    return a\n\n/*======= SortLists()\n";
    const info = try scanFile(al, p, "broken.ring", broken);
    try std.testing.expect(!info.parsed_ok);
    try std.testing.expectEqual(@as(usize, 0), info.sigs.len); // exports nothing

    const good = "func Fine x\n    return x\n";
    const ginfo = try scanFile(al, p, "good.ring", good);
    try std.testing.expect(ginfo.parsed_ok);
    try std.testing.expectEqual(@as(usize, 1), ginfo.sigs.len);

    var files = [_]FileInfo{ info, ginfo };
    var proj = try Project.build(al, &files);
    const v = try proj.viewFor(al, 0); // the unparsed one
    try std.testing.expectEqual(@as(u32, 0), v.extern_sigs.count());
    try std.testing.expectEqual(@as(usize, 0), v.duplicates.len);
}

test "normPath folds dots and case" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();
    try std.testing.expectEqualStrings("d:/x/lib.ring", try normPath(al, "D:\\x\\sub", "..\\Lib.Ring"));
    try std.testing.expectEqualStrings("tests/a.ring", try normPath(al, "tests", "./a.ring"));
    try std.testing.expectEqualStrings("c:/y/b.ring", try normPath(al, "tests", "C:/y/b.ring"));
}

test "closure, conflict and join-point on a synthetic graph" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const al = a.allocator();

    // lib defines Helper; app loads lib and calls it (cross-file visible).
    // dup_a and dup_b both define Same; dup_main loads BOTH -> the join.
    // indep also defines Same but loads nothing -> unrelated, untouched.
    const sigHelper = [_]types.Collected{.{ .display = "Helper", .lower = "helper", .params = &.{}, .ret = "", .row = 1 }};
    const sigSameA = [_]types.Collected{.{ .display = "Same", .lower = "same", .params = &.{}, .ret = "", .row = 1 }};
    const sigSameB = [_]types.Collected{.{ .display = "Same", .lower = "same", .params = &.{}, .ret = "", .row = 1 }};
    const sigSameI = [_]types.Collected{.{ .display = "Same", .lower = "same", .params = &.{}, .ret = "", .row = 1 }};

    var files = [_]FileInfo{
        .{ .path = "lib.ring", .norm = "lib.ring", .sigs = @constCast(&sigHelper), .loads = &.{}, .loads_typehints = false, .parsed_ok = true },
        .{ .path = "app.ring", .norm = "app.ring", .sigs = &.{}, .loads = @constCast(&[_][]const u8{"lib.ring"}), .loads_typehints = false, .parsed_ok = true },
        .{ .path = "dup_a.ring", .norm = "dup_a.ring", .sigs = @constCast(&sigSameA), .loads = &.{}, .loads_typehints = false, .parsed_ok = true },
        .{ .path = "dup_b.ring", .norm = "dup_b.ring", .sigs = @constCast(&sigSameB), .loads = &.{}, .loads_typehints = false, .parsed_ok = true },
        .{ .path = "dup_main.ring", .norm = "dup_main.ring", .sigs = &.{}, .loads = @constCast(&[_][]const u8{ "dup_a.ring", "dup_b.ring" }), .loads_typehints = false, .parsed_ok = true },
        .{ .path = "indep.ring", .norm = "indep.ring", .sigs = @constCast(&sigSameI), .loads = &.{}, .loads_typehints = false, .parsed_ok = true },
    };

    var p = try Project.build(al, &files);

    const v_app = try p.viewFor(al, 1);
    try std.testing.expect(v_app.extern_sigs.get("helper") != null);
    try std.testing.expectEqual(@as(usize, 0), v_app.duplicates.len);

    const v_main = try p.viewFor(al, 4);
    try std.testing.expectEqual(@as(usize, 1), v_main.duplicates.len);
    try std.testing.expect(v_main.conflicted.contains("same"));
    try std.testing.expect(v_main.extern_sigs.get("same") == null);

    // the join is dup_main, so its CHILDREN report nothing
    const v_a = try p.viewFor(al, 2);
    try std.testing.expectEqual(@as(usize, 0), v_a.duplicates.len);

    // and the independent file is untouched: its own Same is local, one def
    const v_i = try p.viewFor(al, 5);
    try std.testing.expectEqual(@as(usize, 0), v_i.duplicates.len);
    try std.testing.expect(!v_i.conflicted.contains("same"));
}
