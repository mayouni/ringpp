//! `ringpp deps` — what must ship beside this program.
//!
//! Phase B1 of the build half. It exists because of what B0 measured
//! ([FINDINGS F-29]): a `.ringo` is portable between x64 platforms, but a
//! program that reaches a native extension is NOT, and the failure arrives
//! at RUN time on the user's machine rather than at build time. A program
//! that works when packaged on Windows can die on Linux with `R38` for a
//! library it never calls.
//!
//! The reason that is fixable statically is Ring's own idiom. Every
//! extension is reached like this:
//!
//!     if iswindows()   LoadLib("ring_odbc.dll")
//!     but ismacosx()   LoadLib("libring_odbc.dylib")
//!     but islinux()    LoadLib("libring_odbc.so")
//!     ok
//!
//! **The platform branch is decided at run time; the file names are literal
//! strings.** So the complete set of native libraries a program may need on
//! any platform is visible in the source, without running it — which is
//! exactly what a packager needs and what no tool reports today.
//!
//! What this does NOT do, on purpose: it does not decide whether a library
//! is really needed on a given run. `stdlib.ring` loads six database and
//! network extensions to offer `upper()`. Ring tolerates their absence on
//! Windows and does not on Linux, and *which* of them a program truly
//! touches is a runtime question. This reports what CAN be reached, names
//! where each one is declared, and leaves the judgement to the reader.

const std = @import("std");
const ts = @import("ts.zig");
const project = @import("project.zig");

/// One native library, collapsed across the three platform spellings that
/// Ring's own idiom writes as three separate literals.
const Lib = struct {
    base: []const u8, // "ring_odbc"
    win: ?[]const u8 = null, // "ring_odbc.dll"
    mac: ?[]const u8 = null, // "libring_odbc.dylib"
    lin: ?[]const u8 = null, // "libring_odbc.so"
    from: []const u8 = "", // the file that declares it
    row: u32 = 0,
};

/// A `loadlib` whose argument is not a literal. Reported, never guessed at:
/// an unresolvable dependency is a fact about the program, and inventing a
/// name for it would be the one thing this tool must not do.
const Unresolved = struct {
    from: []const u8,
    row: u32,
    text: []const u8,
};

pub const Report = struct {
    libs: std.ArrayList(Lib) = .{},
    unresolved: std.ArrayList(Unresolved) = .{},
    files_scanned: u32 = 0,
    loads_unfound: std.ArrayList([]const u8) = .{},

    fn upsert(self: *Report, a: std.mem.Allocator, base: []const u8, which: u8, name: []const u8, from: []const u8, row: u32) !void {
        for (self.libs.items) |*l| {
            if (std.mem.eql(u8, l.base, base)) {
                switch (which) {
                    'w' => if (l.win == null) {
                        l.win = name;
                    },
                    'm' => if (l.mac == null) {
                        l.mac = name;
                    },
                    else => if (l.lin == null) {
                        l.lin = name;
                    },
                }
                return;
            }
        }
        var l = Lib{ .base = base, .from = from, .row = row };
        switch (which) {
            'w' => l.win = name,
            'm' => l.mac = name,
            else => l.lin = name,
        }
        try self.libs.append(a, l);
    }
};

/// Strip Ring's platform decoration to get the library's identity, so the
/// three literals in an if/but/but chain collapse to one row.
///   ring_odbc.dll        -> ring_odbc, 'w'
///   libring_odbc.so      -> ring_odbc, 'l'
///   libring_odbc.dylib   -> ring_odbc, 'm'
fn classify(name: []const u8) struct { base: []const u8, which: u8 } {
    // take the basename first: LoadLib is sometimes given a path
    var s = name;
    if (std.mem.lastIndexOfAny(u8, s, "/\\")) |i| s = s[i + 1 ..];

    var which: u8 = 0;
    if (std.mem.endsWith(u8, s, ".dll")) {
        which = 'w';
        s = s[0 .. s.len - 4];
    } else if (std.mem.endsWith(u8, s, ".dylib")) {
        which = 'm';
        s = s[0 .. s.len - 6];
    } else if (std.mem.endsWith(u8, s, ".so")) {
        which = 'l';
        s = s[0 .. s.len - 3];
    }
    // "lib" is a unix convention; Windows names carry no prefix. Only strip
    // it where the extension says unix, or `libcurl.dll` would become
    // `curl` and stop matching `libcurl.so`.
    if ((which == 'm' or which == 'l') and std.mem.startsWith(u8, s, "lib")) s = s[3..];
    return .{ .base = s, .which = which };
}

fn isCall(node: ts.Node, comptime lowered: []const u8) bool {
    if (!std.mem.eql(u8, node.kind(), "call_expression")) return false;
    const c = node.child(0);
    if (c.isNull()) return false;
    const t = c.text();
    if (t.len != lowered.len) return false;
    // Ring identifiers are case-insensitive (FINDINGS F-18); `LoadLib`,
    // `loadlib` and `LOADLIB` are one name.
    for (t, lowered) |a, b| if (std.ascii.toLower(a) != b) return false;
    return true;
}

/// The first argument, if and only if it is a plain string literal.
fn literalArg(node: ts.Node) ?[]const u8 {
    var i: u32 = 0;
    while (i < node.namedChildCount()) : (i += 1) {
        const c = node.namedChild(i);
        if (std.mem.eql(u8, c.kind(), "arguments") or std.mem.eql(u8, c.kind(), "argument_list")) {
            var j: u32 = 0;
            while (j < c.namedChildCount()) : (j += 1) {
                const a = c.namedChild(j);
                if (!std.mem.eql(u8, a.kind(), "string")) return null;
                const t = a.text();
                if (t.len < 2) return null;
                return t[1 .. t.len - 1];
            }
            return null;
        }
        if (std.mem.eql(u8, c.kind(), "string")) {
            const t = c.text();
            if (t.len < 2) return null;
            return t[1 .. t.len - 1];
        }
    }
    return null;
}

/// Is this node inside the body of Ring's own `loadlibfile` dispatcher?
///
/// That function IS the three-way platform branch — `LoadLib(cLibName+".dll")`
/// and friends. Its arguments are computed by construction, so reporting them
/// as "unresolved dependencies" is true and useless: it fires once for every
/// program that loads guilib, and says nothing about that program. The real
/// dependency is the literal at the CALL site, which is collected normally.
///
/// Named rather than pattern-matched, because it is one specific function in
/// Ring's own libraries (libraries/guilib/loadlibfile.ring), not a shape.
fn inLoadLibFile(n: ts.Node) bool {
    var p = n.parent();
    var hops: u32 = 0;
    while (!p.isNull() and hops < 64) : (hops += 1) {
        if (std.mem.eql(u8, p.kind(), "function_definition")) {
            var i: u32 = 0;
            while (i < p.namedChildCount()) : (i += 1) {
                const c = p.namedChild(i);
                if (!std.mem.eql(u8, c.kind(), "identifier")) continue;
                const t = c.text();
                if (t.len != "loadlibfile".len) return false;
                for (t, "loadlibfile") |x, y| if (std.ascii.toLower(x) != y) return false;
                return true;
            }
            return false;
        }
        p = p.parent();
    }
    return false;
}

fn walk(a: std.mem.Allocator, n: ts.Node, path: []const u8, rep: *Report) !void {
    if (isCall(n, "loadlib")) {
        if (literalArg(n)) |lit| {
            const c = classify(lit);
            if (c.which != 0) {
                try rep.upsert(a, try a.dupe(u8, c.base), c.which, try a.dupe(u8, lit), path, n.start().row + 1);
            } else {
                // no recognised extension: keep the literal as its own row
                try rep.upsert(a, try a.dupe(u8, lit), 'w', try a.dupe(u8, lit), path, n.start().row + 1);
            }
        } else if (!inLoadLibFile(n)) {
            try rep.unresolved.append(a, .{ .from = path, .row = n.start().row + 1, .text = try a.dupe(u8, n.text()) });
        }
    } else if (isCall(n, "loadlibfile")) {
        // Ring's own helper: one base name, all three spellings derived by
        // the rule in libraries/guilib/loadlibfile.ring.
        if (literalArg(n)) |lit| {
            const base = try a.dupe(u8, lit);
            const row = n.start().row + 1;
            try rep.upsert(a, base, 'w', try std.fmt.allocPrint(a, "{s}.dll", .{lit}), path, row);
            try rep.upsert(a, base, 'm', try std.fmt.allocPrint(a, "lib{s}.dylib", .{lit}), path, row);
            try rep.upsert(a, base, 'l', try std.fmt.allocPrint(a, "lib{s}.so", .{lit}), path, row);
        } else {
            try rep.unresolved.append(a, .{ .from = path, .row = n.start().row + 1, .text = try a.dupe(u8, n.text()) });
        }
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try walk(a, n.child(i), path, rep);
}

/// Collect `load "x"` targets as written, unresolved.
fn rawLoads(a: std.mem.Allocator, n: ts.Node, out: *std.ArrayList([]const u8)) !void {
    if (std.mem.eql(u8, n.kind(), "load_statement")) {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const c = n.namedChild(i);
            if (!std.mem.eql(u8, c.kind(), "string")) continue;
            const t = c.text();
            if (t.len >= 2) try out.append(a, t[1 .. t.len - 1]);
        }
        return;
    }
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) try rawLoads(a, n.child(i), out);
}

fn exists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// Ring's own search order, as far as it can be reproduced statically:
/// beside the loading file first, then the interpreter's `bin/load`
/// aggregators, then the library tree.
fn resolveLoad(a: std.mem.Allocator, target: []const u8, from_dir: []const u8, ring_root: ?[]const u8) !?[]const u8 {
    var cands = std.ArrayList([]const u8){};
    defer cands.deinit(a);

    try cands.append(a, try std.fs.path.join(a, &.{ from_dir, target }));
    if (ring_root) |r| {
        try cands.append(a, try std.fs.path.join(a, &.{ r, "bin", "load", target }));
        try cands.append(a, try std.fs.path.join(a, &.{ r, "libraries", "stdlib", target }));
        try cands.append(a, try std.fs.path.join(a, &.{ r, "libraries", "guilib", target }));
    }
    for (cands.items) |c| if (exists(c)) return c;
    return null;
}

/// Everything `run` needs before it starts printing, factored out so B3's
/// `ringpp build` can get the structured Report directly — copying files
/// needs the parsed list, not a column of text to re-parse. `a` must
/// outlive the returned Report (an arena the caller owns); this function
/// allocates into it and does not free anything itself.
pub fn collect(a: std.mem.Allocator, entry: []const u8, ring_root: ?[]const u8) !Report {
    const parser = ts.Parser.init();
    defer parser.deinit();

    var rep = Report{};
    var seen = std.StringHashMap(void).init(a);
    var queue = std.ArrayList([]const u8){};
    try queue.append(a, try a.dupe(u8, entry));

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const path = queue.items[qi];
        const key = try project.normPath(a, "", path);
        if (seen.contains(key)) continue;
        try seen.put(key, {});

        const src = std.fs.cwd().readFileAlloc(a, path, 64 * 1024 * 1024) catch continue;
        const tree = parser.parse(src) orelse continue;
        defer tree.deinit();
        rep.files_scanned += 1;

        try walk(a, tree.root(), path, &rep);

        var loads = std.ArrayList([]const u8){};
        try rawLoads(a, tree.root(), &loads);
        const dir = project.dirOf(path);
        for (loads.items) |t| {
            if (try resolveLoad(a, t, dir, ring_root)) |p| {
                try queue.append(a, p);
            } else {
                try rep.loads_unfound.append(a, try a.dupe(u8, t));
            }
        }
    }
    return rep;
}

pub fn run(gpa: std.mem.Allocator, w: anytype, entry: []const u8, ring_root: ?[]const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (!exists(entry)) {
        try w.print("ringpp deps: no such file: {s}\n", .{entry});
        return 1;
    }

    const rep = try collect(a, entry, ring_root);

    // ----------------------------------------------------------- report
    try w.print("\n{s}\n", .{entry});
    try w.print("  load closure : {d} file(s) reached\n", .{rep.files_scanned});
    if (ring_root == null) {
        try w.print("  ring root    : NOT SUPPLIED — `load \"stdlib.ring\"` and friends\n", .{});
        try w.print("                 cannot be followed. Pass --ring <dir> for the whole picture.\n", .{});
    }

    if (rep.libs.items.len == 0 and rep.unresolved.items.len == 0) {
        // A clean result is only worth printing if the search was complete.
        // Saying "pure Ring" after failing to follow `load "stdlib.ring"` is
        // the exact failure that made tests/fidelity.ps1 report a clean
        // corpus for a year: an answer that looks like a verdict and is
        // actually a measure of what the tool could not see.
        if (rep.loads_unfound.items.len > 0) {
            try w.print("\n  NO VERDICT. {d} load target(s) could not be located, so this\n", .{rep.loads_unfound.items.len});
            try w.print("  program's dependencies are UNKNOWN, not empty:\n", .{});
            var shown: usize = 0;
            for (rep.loads_unfound.items) |u| {
                if (shown >= 8) break;
                try w.print("    load \"{s}\"\n", .{u});
                shown += 1;
            }
            if (ring_root == null) {
                try w.print("\n  Most of these are Ring's own libraries. Pass --ring <dir> so they\n", .{});
                try w.print("  can be followed; without it this command cannot answer the question.\n\n", .{});
            } else {
                try w.print("\n  They were not found under the supplied --ring root either.\n\n", .{});
            }
            return 1;
        }
        try w.print("\n  No native library is reachable from here.\n", .{});
        try w.print("  This program is PURE RING: one .ringo plus a Ring runtime is all it needs,\n", .{});
        try w.print("  and that is portable between x64 platforms (FINDINGS F-29).\n\n", .{});
        return 0;
    }

    try w.print("\n  Native libraries reachable from this program — these do NOT travel\n", .{});
    try w.print("  inside a .ringo and must exist on the target machine:\n\n", .{});
    try w.print("    {s: <18} {s: <22} {s: <24} {s}\n", .{ "windows", "macos", "linux", "declared in" });
    for (rep.libs.items) |l| {
        try w.print("    {s: <18} {s: <22} {s: <24} {s}:{d}\n", .{
            l.win orelse "-",
            l.mac orelse "-",
            l.lin orelse "-",
            std.fs.path.basename(l.from),
            l.row,
        });
    }

    if (rep.unresolved.items.len > 0) {
        try w.print("\n  Computed loadlib argument(s) — the name is not a literal, so it\n", .{});
        try w.print("  cannot be known without running the program:\n", .{});
        for (rep.unresolved.items) |u| {
            try w.print("    {s}:{d}  {s}\n", .{ std.fs.path.basename(u.from), u.row, u.text });
        }
    }

    if (rep.loads_unfound.items.len > 0) {
        try w.print("\n  {d} load target(s) could not be located, so anything they reach is\n", .{rep.loads_unfound.items.len});
        try w.print("  NOT in the table above. This report is a floor, never a ceiling:\n", .{});
        var shown: usize = 0;
        for (rep.loads_unfound.items) |u| {
            if (shown >= 6) break;
            try w.print("    {s}\n", .{u});
            shown += 1;
        }
    }

    try w.print("\n  Verdict: this program is NOT a single file on any platform whose\n", .{});
    try w.print("  library above is missing. On Linux and macOS a missing one is FATAL\n", .{});
    try w.print("  (Error R38); on Windows the same absence is silently tolerated, so\n", .{});
    try w.print("  testing the package on Windows will not reveal it — FINDINGS F-29.\n\n", .{});
    return 0;
}

test "classify collapses the three platform spellings onto one base" {
    const w = classify("ring_odbc.dll");
    try std.testing.expectEqualStrings("ring_odbc", w.base);
    try std.testing.expectEqual(@as(u8, 'w'), w.which);

    const l = classify("libring_odbc.so");
    try std.testing.expectEqualStrings("ring_odbc", l.base);
    try std.testing.expectEqual(@as(u8, 'l'), l.which);

    const m = classify("libring_odbc.dylib");
    try std.testing.expectEqualStrings("ring_odbc", m.base);
    try std.testing.expectEqual(@as(u8, 'm'), m.which);
}

test "KNOWN GAP: a library genuinely named lib* does not collapse" {
    // This asserts a LIMITATION, not correctness, and is here so the
    // limitation cannot be lost.
    //
    // "lib" is stripped only from unix spellings, because Windows names
    // carry no such prefix. A library whose real name begins with "lib"
    // therefore lands in two rows instead of one:
    const w = classify("libcurl.dll"); // windows: nothing to strip
    const l = classify("libcurl.so"); // unix: "lib" stripped as decoration
    try std.testing.expectEqualStrings("libcurl", w.base);
    try std.testing.expectEqualStrings("curl", l.base);
    try std.testing.expect(!std.mem.eql(u8, w.base, l.base)); // <- the gap
    //
    // It does not bite on Ring today: every shipped extension is named
    // `ring_*` (`ring_libcurl.dll` / `libring_libcurl.so` -> `ring_libcurl`
    // on both), so the collapse is correct for the whole real corpus. The
    // fix, if a counter-example appears, is to key on the declaring FILE
    // and line-group rather than on the name — deferred deliberately
    // rather than guessed at.
    const rw = classify("ring_libcurl.dll");
    const rl = classify("libring_libcurl.so");
    try std.testing.expectEqualStrings(rw.base, rl.base);
}
