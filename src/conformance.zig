//! P4 — the conformance matrix.
//!
//! Two axes, because both move underneath us:
//!
//!   Ring axis  every VM source tree we can build, each compiled from source
//!              so the binary is ours and the comparison is honest
//!   Zig axis   the toolchain doing the compiling
//!
//! For each cell it builds a `ring` and then asks the only question that
//! matters: **does Ring++ still work on it?** That is the probe suite plus
//! the P2/P3 gates, run against that binary.
//!
//! The point is not to collect green ticks. It is that when Ring 1.28 or
//! Zig 0.17 breaks an assumption, a cell goes red and names it — instead of
//! a user finding out.

const std = @import("std");

const VmSource = struct {
    label: []const u8,
    /// directory holding the .c files
    src: []const u8,
    /// directory holding the headers
    include: []const u8,
    /// extra .c files this tree needs to link as a CLI, and extra include
    /// dirs for them. A vendored VM may depend on its host's bridge.
    extra_src: []const []const u8 = &.{},
    extra_inc: []const []const u8 = &.{},
    note: []const u8 = "",
};

/// Add a row here to add a Ring version. Trees that are absent are reported
/// as "not present" rather than failing the run — this has to work on a
/// machine that does not have every version checked out.
const vm_sources = [_]VmSource{
    .{
        .label = "1.27.0 stock",
        .src = "D:/ring127/language/src",
        .include = "D:/ring127/language/include",
        .note = "the reference: an unmodified release tree",
    },
    .{
        .label = "1.27.0 ringscript",
        .src = "D:/GitHub/ringscript/ringvm/src",
        .include = "D:/GitHub/ringscript/ringvm/include",
        // Not standalone: vendor patch 6 (the object template cache) calls
        // rs_objcache_new() in RingScript's own bridge, so the tree cannot
        // link a CLI without it. Worth knowing, and exactly the kind of
        // coupling a matrix should surface.
        .extra_src = &.{"D:/GitHub/ringscript/src/rs_oop.c"},
        .extra_inc = &.{"D:/GitHub/ringscript/src"},
        // "8 vendor patches" until 2026-08-25: RingScript numbers patch SLOTS
        // 1-8 and keeps retired/withdrawn ones in place so old writing still
        // resolves (ringscript/docs/VENDOR_PATCHES.md), so 8 counted slots,
        // not 8 live patches -- two are RETIRED (merged upstream) and one is
        // WITHDRAWN (rejected upstream, F-23's correction). 5 are active.
        // Found while checking F-23 against RingScript's current source.
        .note = "same version carrying RingScript's vendor patches (5 active of 8 numbered slots); needs its bridge to link",
    },
};

/// Each check runs a Ring program and looks for a marker in its output.
const Check = struct {
    name: []const u8,
    /// relative to the repository root
    dir: []const u8,
    file: []const u8,
    expect: []const u8,
};

const checks = [_]Check{
    .{ .name = "probe", .dir = "tests", .file = "probe_smoke.ring", .expect = "PROBE OK" },
    .{ .name = "buffer", .dir = "tests", .file = "buffer.ring", .expect = "0 failed" },
    .{ .name = "idioms", .dir = "tests", .file = "idioms.ring", .expect = "0 failed" },
    .{ .name = "fuzz", .dir = "tests", .file = "fuzz_bounds.ring", .expect = "GATE PASSED" },
    .{ .name = "bytecode", .dir = "bench", .file = "13_bytecode_channel.ring", .expect = "sections = 5" },
};

const Result = struct {
    built: bool = false,
    build_ms: u64 = 0,
    version: []const u8 = "",
    passed: [checks.len]bool = [_]bool{false} ** checks.len,
    build_error: []const u8 = "",
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var out_buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const w = &stdout_writer.interface;

    const zig_version = try run(gpa, &.{ "zig", "version" }, null);
    defer freeRun(gpa, zig_version);
    const zv = std.mem.trim(u8, zig_version.stdout, " \r\n");

    try w.print("Ring++ conformance matrix\n", .{});
    try w.print("  Zig axis  : {s}\n", .{zv});
    try w.print("  Ring axis : {d} source tree(s) configured\n\n", .{vm_sources.len});
    try w.flush();

    var results = [_]Result{.{}} ** vm_sources.len;

    for (vm_sources, 0..) |vm, i| {
        try w.print("building {s} ... ", .{vm.label});
        try w.flush();
        results[i] = buildAndCheck(gpa, vm, w) catch |e| blk: {
            try w.print("error: {s}\n", .{@errorName(e)});
            break :blk Result{};
        };
    }

    try w.print("\n", .{});
    try printMatrix(w, &results);
    try w.flush();

    try writeMarkdown(gpa, zv, &results);
    try w.print("\nwrote docs/MATRIX.md\n", .{});
    try w.flush();

    // A red cell must fail the build step, or the matrix is decoration.
    for (results) |r| {
        if (!r.built) continue;
        for (r.passed) |p| if (!p) std.process.exit(1);
    }
}

fn buildAndCheck(gpa: std.mem.Allocator, vm: VmSource, w: anytype) !Result {
    var res = Result{};

    var dir = std.fs.cwd().openDir(vm.src, .{ .iterate = true }) catch {
        try w.print("not present\n", .{});
        return res;
    };
    defer dir.close();

    var argv: std.ArrayList([]const u8) = .{};
    // Only the strings we allocated go in `owned`. An earlier version freed
    // everything from a fixed index, which walked into the "-o" literal and
    // segfaulted.
    var owned: std.ArrayList([]const u8) = .{};
    defer {
        for (owned.items) |a| gpa.free(a);
        owned.deinit(gpa);
        argv.deinit(gpa);
    }

    const out_exe = try std.fmt.allocPrint(gpa, "zig-out/vm/ring-{d}.exe", .{std.hash.Wyhash.hash(0, vm.label)});
    defer gpa.free(out_exe);
    std.fs.cwd().makePath("zig-out/vm") catch {};

    try argv.append(gpa, "zig");
    try argv.append(gpa, "cc");
    try argv.append(gpa, "-O2");
    try argv.append(gpa, "-w");
    try argv.append(gpa, "-I");
    try argv.append(gpa, vm.include);
    for (vm.extra_inc) |inc| {
        try argv.append(gpa, "-I");
        try argv.append(gpa, inc);
    }

    var it = dir.iterate();
    var n_files: usize = 0;
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;
        // ringw.c is the Windows GUI entry point; it collides with ring.c
        if (std.mem.eql(u8, entry.name, "ringw.c")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ vm.src, entry.name });
        try owned.append(gpa, path);
        try argv.append(gpa, path);
        n_files += 1;
    }
    if (n_files == 0) {
        try w.print("no sources\n", .{});
        return res;
    }
    for (vm.extra_src) |ex| {
        try argv.append(gpa, ex);
        n_files += 1;
    }
    try argv.append(gpa, "-o");
    const out_dup = try gpa.dupe(u8, out_exe);
    try owned.append(gpa, out_dup);
    try argv.append(gpa, out_dup);

    var timer = try std.time.Timer.start();
    const built = try run(gpa, argv.items, null);
    defer freeRun(gpa, built);
    res.build_ms = timer.read() / std.time.ns_per_ms;

    if (built.term != .Exited or built.term.Exited != 0) {
        // Keep the compiler's own first diagnostic. A bare "BUILD FAILED"
        // sends the reader back to the command line to rediscover what the
        // runner already had in hand.
        res.build_error = try firstErrorLine(gpa, built.stderr);
        try w.print("BUILD FAILED\n      {s}\n", .{res.build_error});
        return res;
    }
    res.built = true;
    try w.print("ok ({d} files, {d} ms)\n", .{ n_files, res.build_ms });

    // what does it call itself?
    const ver = try run(gpa, &.{ out_exe, "-v" }, null);
    defer freeRun(gpa, ver);
    res.version = try firstVersionLine(gpa, ver.stdout);

    for (checks, 0..) |c, ci| {
        const prog = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ c.dir, c.file });
        defer gpa.free(prog);
        const abs_exe = try std.fs.cwd().realpathAlloc(gpa, out_exe);
        defer gpa.free(abs_exe);
        const r = run(gpa, &.{ abs_exe, c.file }, c.dir) catch {
            continue;
        };
        defer freeRun(gpa, r);
        res.passed[ci] = std.mem.indexOf(u8, r.stdout, c.expect) != null;
        try w.print("    {s:<10} {s}\n", .{ c.name, if (res.passed[ci]) "pass" else "FAIL" });
        try w.flush();
    }
    return res;
}

/// The first line that names a problem, so a failed row explains itself.
fn firstErrorLine(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, s, 10);
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, &[_]u8{ ' ', 13, 10 });
        if (t.len == 0) continue;
        if (std.mem.indexOf(u8, t, "error") != null) return gpa.dupe(u8, t);
    }
    return gpa.dupe(u8, "no diagnostic on stderr");
}

fn firstVersionLine(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, s, '\n');
    while (lines.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \r\n");
        if (std.mem.startsWith(u8, t, "Ring version")) return gpa.dupe(u8, t);
    }
    return gpa.dupe(u8, "unknown");
}

const RunResult = std.process.Child.RunResult;

fn run(gpa: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    return std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 4 * 1024 * 1024,
    });
}

fn freeRun(gpa: std.mem.Allocator, r: RunResult) void {
    gpa.free(r.stdout);
    gpa.free(r.stderr);
}

fn printMatrix(w: anytype, results: []const Result) !void {
    try w.print("{s:<24}", .{"Ring source"});
    for (checks) |c| try w.print(" {s:<10}", .{c.name});
    try w.print("\n", .{});
    try w.print("{s:<24}", .{"------------------------"});
    for (checks) |_| try w.print(" {s:<10}", .{"----------"});
    try w.print("\n", .{});

    for (vm_sources, 0..) |vm, i| {
        try w.print("{s:<24}", .{vm.label});
        if (!results[i].built) {
            try w.print(" (not built)\n", .{});
            continue;
        }
        for (results[i].passed) |p| try w.print(" {s:<10}", .{if (p) "pass" else "FAIL"});
        try w.print("\n", .{});
    }
}

fn writeMarkdown(gpa: std.mem.Allocator, zv: []const u8, results: []const Result) !void {
    std.fs.cwd().makePath("docs") catch {};
    var f = try std.fs.cwd().createFile("docs/MATRIX.md", .{});
    defer f.close();

    var buf: [8192]u8 = undefined;
    var fw = f.writer(&buf);
    const w = &fw.interface;

    try w.print("# Conformance matrix\n\n", .{});
    try w.print("*Generated by `zig build conformance`. Do not edit by hand.*\n\n", .{});
    try w.print("Every VM here is **built from source by this runner**, so the\n", .{});
    try w.print("comparison is between trees rather than between someone else's\n", .{});
    try w.print("binaries. Each cell asks one question: does Ring++ still work on it?\n\n", .{});
    try w.print("- **Zig axis:** {s}\n", .{zv});
    try w.print("- **Ring axis:** {d} source tree(s) configured\n\n", .{vm_sources.len});
    try w.print("The Zig axis carries **one toolchain today** — whichever `zig` is on\n", .{});
    try w.print("`PATH`. It is an axis rather than a constant because the compiler is\n", .{});
    try w.print("part of the product: a second entry is what would catch a codegen or\n", .{});
    try w.print("libc change breaking a VM that Ring itself never touched. Run this\n", .{});
    try w.print("step under a second `zig` to fill in that axis.\n\n", .{});

    try w.print("| Ring source |", .{});
    for (checks) |c| try w.print(" {s} |", .{c.name});
    try w.print("\n|---|", .{});
    for (checks) |_| try w.print("---|", .{});
    try w.print("\n", .{});

    for (vm_sources, 0..) |vm, i| {
        try w.print("| {s} |", .{vm.label});
        if (!results[i].built) {
            for (checks) |_| try w.print(" — |", .{});
            try w.print("\n", .{});
            continue;
        }
        for (results[i].passed) |p| try w.print(" {s} |", .{if (p) "pass" else "**FAIL**"});
        try w.print("\n", .{});
    }

    try w.print("\n## What each column checks\n\n", .{});
    for (checks) |c| try w.print("- **{s}** — `{s}/{s}`\n", .{ c.name, c.dir, c.file });

    try w.print("\n## Rows\n\n", .{});
    for (vm_sources, 0..) |vm, i| {
        try w.print("- **{s}**", .{vm.label});
        if (vm.note.len > 0) try w.print(" — {s}", .{vm.note});
        if (results[i].built) {
            try w.print(" (built in {d} ms", .{results[i].build_ms});
            if (results[i].version.len > 0) try w.print("; reports `{s}`", .{results[i].version});
            try w.print(")", .{});
        } else if (results[i].build_error.len > 0) {
            try w.print(" — **build failed**: `{s}`", .{results[i].build_error});
        } else if (results[i].build_error.len > 0) {
            try w.print(" — **build failed**: `{s}`", .{results[i].build_error});
        } else {
            try w.print(" — **not built on this machine**", .{});
        }
        try w.print("\n", .{});
    }

    try w.print("\n## What this has caught\n\n", .{});
    try w.print("The first two-row run failed `idioms` on the **patched** VM, not the\n", .{});
    try w.print("stock one: RingScript's `rlist.c` builds the items array on random\n", .{});
    try w.print("access, so `RppIndexed` had nothing left to buy — 467 ms baseline on\n", .{});
    try w.print("stock against 4 ms there. The gate was wrong, not the VM; it asserted\n", .{});
    try w.print("a mechanism (\"at least 20x from my library\") where it should have\n", .{});
    try w.print("asserted the outcome (\"a permuted pass is not quadratic\"). It now\n", .{});
    try w.print("accepts either route. See FINDINGS **F-23**.\n\n", .{});

    try w.print("## Adding a version\n\n", .{});
    try w.print("One entry in `vm_sources` in `src/conformance.zig`: a label, the\n", .{});
    try w.print("directory of `.c` files, and the include directory. A tree that is\n", .{});
    try w.print("absent is reported as not built rather than failing the run, so this\n", .{});
    try w.print("works on a machine that does not have every version checked out.\n", .{});

    try w.flush();

    for (results) |r| if (r.version.len > 0) gpa.free(r.version);
}
