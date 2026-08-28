//! ringpp — Ring++ CLI.
//! Tier 0: analysis only, no compiler required. See docs/CLI.md.

const std = @import("std");
const builtin = @import("builtin");
const ts = @import("ts.zig");
const check = @import("check.zig");
const why = @import("why.zig");
const types = @import("types.zig");
const project = @import("project.zig");
const deps = @import("deps.zig");
const pack = @import("pack.zig");

const version = "0.9";

fn usage(w: anytype) void {
    // The rule was drawn as a fixed run of dashes and lined up only because
    // the version happened to be five characters. Going 0.1.0 -> 0.9 left the
    // box two short. Derive the rule from the title instead, so it is right
    // for any version anyone ever sets.
    const title = "  Ring++ v" ++ version ++ " -- Ring, two levels  ";
    const rule = "+" ++ ("-" ** title.len) ++ "+";
    w.print("{s}\n|{s}|\n{s}\n", .{ rule, title, rule }) catch {};
    w.print(
        \\
        \\Analyse
        \\
        \\  ringpp check [path] [--advise]  Type-check and lint; --advise names every place a measured Ring++ idiom is faster
        \\  ringpp why <thing>          Explain a rule, a finding, or a Ring error code
        \\  ringpp version              Show version
        \\  ringpp help                 This screen
        \\
        \\  `why` takes what you have in hand: a rule `check` printed
        \\  (rpp/empty-catch), a finding (F-16), or the Ring error code you
        \\  actually saw (R4). `ringpp why` alone lists everything it knows.
        \\
        \\Package
        \\
        \\  ringpp deps <file.ring> [--ring <dir>]
        \\                               Native libraries this program can reach; no compiler
        \\  ringpp build <file.ring> [options]
        \\                               Bytecode + a runtime stub + declared native libs, one
        \\                               package. `ringpp build -h` for the full option list.
        \\
        \\Not built yet: probe, bench, run, emit, dist, doctor, vendor.
        \\
        \\
    , .{}) catch {};
}

/// Stdout that survives its reader leaving.
///
/// `ringpp check big-tree | head -2` used to PANIC: "reached unreachable
/// code" at std/os/windows.zig's WriteFile. The pipes MSYS and PowerShell
/// hand a child are OVERLAPPED handles, so when the reader (head, grep -c,
/// Select-Object -First) closes its end, kernel32.WriteFile fails with
/// GetLastError() = IO_PENDING — a code std's synchronous wrapper declares
/// unreachable. Nothing to catch: the process aborts mid-report.
///
/// So this writer calls kernel32.WriteFile itself and treats ANY write
/// failure one way: the reader is gone, everything further is silently
/// discarded, and the command finishes with the verdict it computed. That
/// is what a CLI is expected to do when its pipe closes — head took what
/// it wanted; the rest of the output has no audience, and a panic trace
/// on stderr is not a verdict. POSIX builds take the same path via
/// posix.write, where EPIPE arrives as an ordinary error.
///
/// Modeled on std.Io.Writer.Discarding: drain consumes buffer[0..end]
/// first (tracked by resetting `end`), then the data slices with the last
/// repeated `splat` times, and returns only the bytes consumed from
/// `data`.
const PipeSafeStdout = struct {
    interface: std.Io.Writer,
    file: std.fs.File,
    /// Set on the first failed write; never cleared. One flag, not an
    /// error return, so no caller anywhere has to handle a half-dead
    /// stream — printing simply becomes free.
    dead: bool = false,

    fn init(buffer: []u8) PipeSafeStdout {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
            .file = std.fs.File.stdout(),
        };
    }

    fn rawWrite(self: *PipeSafeStdout, bytes: []const u8) void {
        if (self.dead) return;
        var off: usize = 0;
        while (off < bytes.len) {
            if (builtin.os.tag == .windows) {
                var written: std.os.windows.DWORD = 0;
                const chunk: std.os.windows.DWORD =
                    @intCast(@min(bytes.len - off, std.math.maxInt(u31)));
                const ok = std.os.windows.kernel32.WriteFile(
                    self.file.handle,
                    bytes.ptr + off,
                    chunk,
                    &written,
                    null,
                );
                if (ok == 0 or written == 0) {
                    self.dead = true;
                    return;
                }
                off += written;
            } else {
                const n = std.posix.write(self.file.handle, bytes[off..]) catch {
                    self.dead = true;
                    return;
                };
                if (n == 0) {
                    self.dead = true;
                    return;
                }
                off += n;
            }
        }
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *PipeSafeStdout = @alignCast(@fieldParentPtr("interface", io_w));
        self.rawWrite(io_w.buffer[0..io_w.end]);
        io_w.end = 0;
        if (data.len == 0) return 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.rawWrite(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| self.rawWrite(pattern);
        return consumed + pattern.len * splat;
    }
};

pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [8192]u8 = undefined;
    var stdout_w = PipeSafeStdout.init(&out_buf);
    const w = &stdout_w.interface;
    defer w.flush() catch {};

    if (args.len < 2) {
        usage(w);
        return 1;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "-v")) {
        try w.print("ringpp {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "-h")) {
        usage(w);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "check") or std.mem.eql(u8, cmd, "c")) {
        // `check` takes one optional path and one optional flag. Anything
        // else was silently ignored until now, so `ringpp check src/ --fix`
        // reported a clean run having done nothing of the kind. A tool that
        // refuses rather than guesses has to refuse here too.
        var advise = false;
        var path: []const u8 = ".";
        var got_path = false;
        var ai: usize = 2;
        while (ai < args.len) : (ai += 1) {
            const a2 = args[ai];
            if (std.mem.eql(u8, a2, "--advise")) {
                advise = true;
            } else if (a2.len > 1 and a2[0] == '-') {
                try w.print("ringpp check: unknown option '{s}'\n", .{a2});
                try w.print("usage: ringpp check [path] [--advise]\n", .{});
                return 1;
            } else if (!got_path) {
                path = a2;
                got_path = true;
            } else {
                try w.print("ringpp check: unexpected argument '{s}'\n", .{a2});
                try w.print("usage: ringpp check [path] [--advise]\n", .{});
                return 1;
            }
        }
        return try runCheck(gpa, w, path, advise);
    }
    if (std.mem.eql(u8, cmd, "deps") or std.mem.eql(u8, cmd, "d")) {
        if (args.len < 3) {
            try w.print("usage: ringpp deps <file.ring> [--ring <dir>]\n", .{});
            return 1;
        }
        var ring_root: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--ring") and i + 1 < args.len) {
                ring_root = args[i + 1];
                i += 1;
            }
        }
        return try deps.run(gpa, w, args[2], ring_root);
    }
    if (std.mem.eql(u8, cmd, "build") or std.mem.eql(u8, cmd, "b")) {
        return try pack.run(gpa, w, args);
    }
    if (std.mem.eql(u8, cmd, "why") or std.mem.eql(u8, cmd, "w")) {
        return try why.run(w, if (args.len > 2) args[2] else null);
    }
    // Undocumented on the help screen: this prints the grammar's view of a
    // file. It exists because every rule in check.zig is written against a
    // node shape, and guessing at that shape is how false positives are
    // born. Also the fastest way to adjudicate a grammar disagreement.
    if (std.mem.eql(u8, cmd, "ast")) {
        if (args.len < 3) {
            try w.print("usage: ringpp ast <file.ring>\n", .{});
            return 1;
        }
        return try runAst(gpa, w, args[2]);
    }

    try w.print("ringpp: unknown command '{s}'\n\n", .{cmd});
    usage(w);
    return 1;
}

fn runCheck(gpa: std.mem.Allocator, w: anytype, path: []const u8, advise: bool) !u8 {
    var files = std.ArrayList([]const u8){};
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    // Paths the user named that are not there at all, and files that are
    // there and could not be read. Both mean the same thing to a reader --
    // this was NOT checked -- and both used to be invisible.
    var missing = std.ArrayList([]const u8){};
    defer {
        for (missing.items) |f| gpa.free(f);
        missing.deinit(gpa);
    }
    var unreadable = std.ArrayList([]const u8){};
    defer unreadable.deinit(gpa);

    try collectFiles(gpa, path, &files, &missing);
    std.mem.sort([]const u8, files.items, {}, lessStr);

    const parser = ts.Parser.init();
    defer parser.deinit();

    var report = check.Report.init(gpa);
    defer report.deinit(gpa);

    var bytes: usize = 0;
    var timer = try std.time.Timer.start();

    // PASS 1 — the project layer (src/project.zig). Each file is parsed,
    // its top-level signatures and `load` targets extracted, and the tree
    // FREED before the next file is touched: parsing twice trades time for
    // never holding two trees at once, on a machine that has punished the
    // alternative. The load graph then says which definitions each file can
    // actually reach — and cross-file calls are checked with the same
    // certainty as local ones, because Ring's C22 guarantees a name has at
    // most one live definition per program (FINDINGS F-26).
    var parena_state = std.heap.ArenaAllocator.init(gpa);
    defer parena_state.deinit();
    const parena = parena_state.allocator();

    var infos = std.ArrayList(project.FileInfo){};
    var any_typehints = false;
    for (files.items) |f| {
        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch {
            // Excluded from cross-file reasoning, which was already correct,
            // and now also NAMED to the user -- a file the tool could not
            // read is not a file it found nothing wrong with.
            try unreadable.append(gpa, f);
            try infos.append(parena, .{
                .path = try parena.dupe(u8, f),
                .norm = try project.normPath(parena, "", f),
                .sigs = &.{},
                .loads = &.{},
                .loads_typehints = false,
                .parsed_ok = false, // unreadable: no signatures, no findings
            });
            continue;
        };
        defer gpa.free(src);
        const info = try project.scanFile(parena, parser, f, src);
        if (info.loads_typehints) any_typehints = true;
        try infos.append(parena, info);
    }
    var proj = try project.Project.build(parena, infos.items);

    // PASS 2 — the checks, per file, with that file's load-graph view.
    // The suppression set for rpp/undefined-function: every name defined in
    // any form anywhere in the checked set. Built ONLY when every file
    // parsed — one unparsed file hides an unknown number of definitions,
    // and a rule that says "R3 the moment this line runs" may not speak
    // over a universe with holes in it. NO VERDICT beats a wrong one.
    var all_defined = std.StringHashMap(void).init(gpa);
    defer all_defined.deinit();
    var universe_complete = true;
    for (infos.items) |info| {
        // ALL of these are SET-GLOBAL on purpose, not per-closure. The
        // per-closure version shipped first and produced 17 false R11s in
        // ring127/applications: webapi.ring never loads guilib.ring -- the
        // MAIN app does, and load edges point the wrong way for a
        // fragment's closure to see its own runtime universe. A fragment
        // file's world is defined by whoever loads it, which is exactly
        // what a static pass cannot know -- so one unresolved load, one
        // loadlib, one eval or one unparsed file ANYWHERE silences the
        // absence-based rules (R3, R24, R11/R15) for the whole set.
        if (!info.parsed_ok or info.has_dynamic or info.has_unresolved_load) {
            universe_complete = false;
            break;
        }
    }
    var all_globals = std.StringHashMap(void).init(gpa);
    defer all_globals.deinit();
    var all_classes = std.StringHashMap(void).init(gpa);
    defer all_classes.deinit();
    if (universe_complete) {
        for (infos.items) |info| {
            for (info.defnames) |dn| try all_defined.put(dn, {});
            for (info.globalnames) |gn| try all_globals.put(gn, {});
            for (info.classnames) |cn| try all_classes.put(cn, {});
        }
    }

    for (files.items, 0..) |f, i| {
        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        bytes += src.len;

        // per-file scratch: a view must die with its file, or six thousand
        // of them accumulate and the process dies OutOfMemory (measured)
        var scratch_state = std.heap.ArenaAllocator.init(gpa);
        defer scratch_state.deinit();
        const view = try proj.viewFor(scratch_state.allocator(), @intCast(i));
        try check.checkSourceCtx(gpa, parser, f, src, &report, .{
            .typehints_loaded_in_scan = any_typehints,
            .extern_sigs = &view.extern_sigs,
            .conflicted = &view.conflicted,
            .duplicates = view.duplicates,
            .assert_undefined = view.assert_undefined,
            .all_defined = if (universe_complete) &all_defined else null,
            .all_globals = if (universe_complete) &all_globals else null,
            .all_classes = if (universe_complete) &all_classes else null,
        });
    }
    const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;

    var last_file: []const u8 = "";
    for (report.findings.items) |f| {
        // Advice is opt-in. It describes working code that could be faster,
        // and printing it beside real defects teaches people to skim both.
        if (f.severity == .adv and !advise) continue;
        if (!std.mem.eql(u8, last_file, f.file)) {
            try w.print("\n{s}\n", .{f.file});
            last_file = f.file;
        }
        try w.print("  {d}:{d}  {s: <5}  {s}\n", .{ f.row, f.col, f.severity.label(), f.rule });
        try w.print("          {s}\n", .{f.message});
        if (f.detail.len > 0) try wrapPrint(w, f.detail, 10, 74);
    }

    const c = report.counts();
    const read_ok = files.items.len - unreadable.items.len;

    // A file carrying rpp/unparsed had NO rules applied to it. That is
    // already said in the finding, but the summary is the line people scan,
    // and "in 12 files" beside "0 error" reads as twelve files checked.
    // Counted here so the headline cannot imply coverage that was not there.
    var unparsed: usize = 0;
    for (report.findings.items) |f| {
        if (std.mem.eql(u8, f.rule, "rpp/unparsed")) unparsed += 1;
    }

    try w.print(
        "\n  {d} error, {d} warn, {d} perf, {d} note   in {d} files ({d:.1} KB, {d:.0} ms)\n",
        .{ c.err, c.warn, c.perf, c.note, read_ok, @as(f64, @floatFromInt(bytes)) / 1024.0, ms },
    );
    if (c.adv > 0 and !advise) {
        try w.print("  {d} place(s) where a measured Ring++ idiom is faster -- add --advise to see them\n", .{c.adv});
    } else if (advise and c.adv > 0) {
        try w.print("  {d} advice item(s) above are opportunities, not defects\n", .{c.adv});
    }
    if (unparsed > 0) {
        try w.print(
            "  {d} of those parsed as far as a point and no further, so no rule ran on them\n",
            .{unparsed},
        );
    }

    // NO VERDICT, on the same principle deps.zig already states: an answer
    // that looks like a verdict and is actually a measure of what the tool
    // could not see is worse than no answer. "0 error" beside a file that
    // was never opened is exactly that.
    if (missing.items.len > 0 or unreadable.items.len > 0) {
        try w.print("\n  NO VERDICT. {d} path(s) were not checked, so this result is\n", .{missing.items.len + unreadable.items.len});
        try w.print("  INCOMPLETE, not clean:\n", .{});
        var shown: usize = 0;
        for (missing.items) |m| {
            if (shown >= 8) break;
            try w.print("    {s}   -- not found\n", .{m});
            shown += 1;
        }
        for (unreadable.items) |u| {
            if (shown >= 8) break;
            try w.print("    {s}   -- unreadable\n", .{u});
            shown += 1;
        }
        const total = missing.items.len + unreadable.items.len;
        if (total > shown) try w.print("    ... and {d} more\n", .{total - shown});
        try w.print("\n", .{});
        return 1;
    }
    // Naming a target and checking nothing is the same failure wearing a
    // friendlier face: it exits 0 with "0 error" having opened no file.
    if (files.items.len == 0) {
        try w.print("\n  NO VERDICT. No .ring file was found under '{s}', so nothing\n", .{path});
        try w.print("  was checked. This is not a clean result.\n\n", .{});
        return 1;
    }
    // A rule id with nowhere to go is a rule to obey rather than a fact to
    // understand. Name the way out, once, and only when there is something
    // to explain.
    for (report.findings.items) |f| {
        // The first VISIBLE finding: naming a rule this run just hid would
        // send the reader to `why` for a line they cannot see above.
        if (f.severity == .adv and !advise) continue;
        try w.print("  ringpp why {s}   for any rule above\n", .{f.rule});
        break;
    }
    return if (c.err > 0) 1 else 0;
}

fn runAst(gpa: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    const src = try std.fs.cwd().readFileAlloc(gpa, path, 16 * 1024 * 1024);
    defer gpa.free(src);
    const parser = ts.Parser.init();
    defer parser.deinit();
    const tree = parser.parse(src) orelse return 1;
    defer tree.deinit();
    try dumpNode(w, tree.root(), 0);
    return 0;
}

fn dumpNode(w: anytype, n: ts.Node, depth: u32) !void {
    if (depth > 40) return;
    for (0..depth) |_| try w.print("  ", .{});
    const t = n.text();
    // one line of source is enough to recognise the node; more is noise
    const cut = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    try w.print("{s}", .{n.kind()});
    if (n.namedChildCount() == 0 and cut > 0) {
        try w.print("  '{s}'", .{t[0..@min(cut, 40)]});
    }
    try w.print("\n", .{});
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) try dumpNode(w, n.namedChild(i), depth + 1);
}

fn wrapPrint(w: anytype, text: []const u8, indent: usize, width: usize) !void {
    var it = std.mem.tokenizeAny(u8, text, " \n\r\t");
    var col: usize = 0;
    var started = false;
    while (it.next()) |word| {
        if (!started or col + word.len + 1 > width) {
            if (started) try w.print("\n", .{});
            for (0..indent) |_| try w.print(" ", .{});
            col = 0;
            started = true;
        } else {
            try w.print(" ", .{});
            col += 1;
        }
        try w.print("{s}", .{word});
        col += word.len;
    }
    if (started) try w.print("\n", .{});
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectFiles(
    gpa: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList([]const u8),
    missing: *std.ArrayList([]const u8),
) !void {
    // Try as a directory first: on Windows statFile() fails on directories.
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
        // Not a directory. Before accepting it as a file, ask whether it is
        // THERE. Without this, any argument ending in .ring was appended
        // unseen, counted in the "in N files" line, failed to read, and was
        // skipped in silence -- so `ringpp check typo.ring` answered
        // "0 error ... in 1 files" about a file that does not exist.
        // The same defect deps.zig already carries a comment about.
        std.fs.cwd().access(path, .{}) catch {
            try missing.append(gpa, try gpa.dupe(u8, path));
            return;
        };
        if (std.mem.endsWith(u8, path, ".ring")) try out.append(gpa, try gpa.dupe(u8, path));
        return;
    };
    defer dir.close();
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind != .file) continue;
        if (!std.mem.endsWith(u8, e.basename, ".ring")) continue;
        const full = try std.fs.path.join(gpa, &.{ path, e.path });
        try out.append(gpa, full);
    }
}

test {
    _ = ts;
    _ = check;
    _ = why;
    _ = types;
    _ = project;
}
