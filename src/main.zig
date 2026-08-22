//! ringpp — Ring++ CLI.
//! Tier 0: analysis only, no compiler required. See docs/CLI.md.

const std = @import("std");
const ts = @import("ts.zig");
const check = @import("check.zig");
const why = @import("why.zig");
const types = @import("types.zig");

const version = "0.1.0";

fn usage(w: anytype) void {
    w.print(
        \\+-------------------------------------+
        \\|  Ring++ v{s} -- Ring, two levels  |
        \\+-------------------------------------+
        \\
        \\Analyse
        \\
        \\  ringpp check [path]         Type-check and lint; no run, no build     (always available)
        \\  ringpp why <thing>          Explain a rule, a finding, or a Ring error code
        \\  ringpp version              Show version
        \\  ringpp help                 This screen
        \\
        \\  `why` takes what you have in hand: a rule `check` printed
        \\  (rpp/empty-catch), a finding (F-16), or the Ring error code you
        \\  actually saw (R4). `ringpp why` alone lists everything it knows.
        \\
        \\Not built yet: probe, bench, run, build, emit, dist, doctor, vendor.
        \\
        \\
    , .{version}) catch {};
}

pub fn main() !u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var out_buf: [8192]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&out_buf);
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
        const path = if (args.len > 2) args[2] else ".";
        return try runCheck(gpa, w, path);
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

fn runCheck(gpa: std.mem.Allocator, w: anytype, path: []const u8) !u8 {
    var files = std.ArrayList([]const u8){};
    defer {
        for (files.items) |f| gpa.free(f);
        files.deinit(gpa);
    }
    try collectFiles(gpa, path, &files);
    std.mem.sort([]const u8, files.items, {}, lessStr);

    const parser = ts.Parser.init();
    defer parser.deinit();

    var report = check.Report.init(gpa);
    defer report.deinit(gpa);

    var bytes: usize = 0;
    var timer = try std.time.Timer.start();

    // A pre-pass, because one question cannot be answered from a single file:
    // a project may `load "typehints.ring"` once in an entry file and pull the
    // rest in from there. Without this, every included file would be told it
    // is about to raise R24 — an error on correct code, which is the one
    // failure a checker must not have. Cheap: a substring scan, no parsing.
    var tctx = types.Ctx{};
    for (files.items) |f| {
        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        if (std.mem.indexOf(u8, src, "typehints") != null) {
            tctx.typehints_loaded_in_scan = true;
            break;
        }
    }

    for (files.items) |f| {
        const src = std.fs.cwd().readFileAlloc(gpa, f, 64 * 1024 * 1024) catch continue;
        defer gpa.free(src);
        bytes += src.len;
        try check.checkSourceCtx(gpa, parser, f, src, &report, tctx);
    }
    const ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;

    var last_file: []const u8 = "";
    for (report.findings.items) |f| {
        if (!std.mem.eql(u8, last_file, f.file)) {
            try w.print("\n{s}\n", .{f.file});
            last_file = f.file;
        }
        try w.print("  {d}:{d}  {s: <5}  {s}\n", .{ f.row, f.col, f.severity.label(), f.rule });
        try w.print("          {s}\n", .{f.message});
        if (f.detail.len > 0) try wrapPrint(w, f.detail, 10, 74);
    }

    const c = report.counts();
    try w.print(
        "\n  {d} error, {d} warn, {d} perf, {d} note   in {d} files ({d:.1} KB, {d:.0} ms)\n",
        .{ c.err, c.warn, c.perf, c.note, files.items.len, @as(f64, @floatFromInt(bytes)) / 1024.0, ms },
    );
    // A rule id with nowhere to go is a rule to obey rather than a fact to
    // understand. Name the way out, once, and only when there is something
    // to explain.
    if (report.findings.items.len > 0) {
        try w.print("  ringpp why {s}   for any rule above\n", .{report.findings.items[0].rule});
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

fn collectFiles(gpa: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]const u8)) !void {
    // Try as a directory first: on Windows statFile() fails on directories.
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
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
}
