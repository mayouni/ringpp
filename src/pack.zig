//! `ringpp build` — phase B3 of the build half.
//!
//! Assembles one package from three ingredients, each already built by an
//! earlier phase:
//!
//!   bytecode  `<ring> <entry.ring> -go` produces `<entry>.ringo` — Ring's
//!             own mechanism, portable between x64 platforms (FINDINGS F-29)
//!   runtime   a stub compiled by phase B2, one per target platform, that
//!             needs no C compiler and (on the platforms tested) no
//!             companion DLL either
//!   deps      phase B1's static scan of every `loadlib`/`loadlibfile`
//!             reachable from the entry point
//!
//! Two shapes come out, and neither is silently rounded up to the other:
//!
//!   PURE RING  deps reaches no native library -> a stub + bytecode pair,
//!              renamed to match. Portable, complete, nothing missing.
//!   BUNDLE     deps reaches native libraries -> the same pair plus every
//!              library `deps` could locate under `--lib-dir`. Anything not
//!              found is named MISSING in the manifest, never silently
//!              dropped — this is why DESIGN_BUILD.md §3 does not call a
//!              GUI or database program one file.
//!
//! What this is NOT: a single self-contained executable. Measured before
//! writing this — Ring's own binary does not look for a same-named `.ringo`
//! when run with no arguments, and appending bytecode to the exe does
//! nothing either. A genuine one-file artefact needs a loader Ring++
//! compiles itself, which touches no VM source (ground rule 1) but is
//! unbuilt and unscheduled. The artefact here is a pair: `<name>[.exe]` and
//! `<name>.ringo`, invoked as `<name>[.exe] <name>.ringo`.

const std = @import("std");
const deps = @import("deps.zig");
const builtin = @import("builtin");

const Platform = struct {
    name: []const u8,
    exe_ext: []const u8,
    lib_ext: []const u8,
    lib_prefix: []const u8,
    /// which column of a deps.Report `Lib` row names this platform's file
    col: u8,
};

const platforms = [_]Platform{
    .{ .name = "win64", .exe_ext = ".exe", .lib_ext = ".dll", .lib_prefix = "", .col = 'w' },
    .{ .name = "linux-x64", .exe_ext = "", .lib_ext = ".so", .lib_prefix = "lib", .col = 'l' },
    .{ .name = "linux-arm64", .exe_ext = "", .lib_ext = ".so", .lib_prefix = "lib", .col = 'l' },
    .{ .name = "macos-x64", .exe_ext = "", .lib_ext = ".dylib", .lib_prefix = "lib", .col = 'm' },
    .{ .name = "macos-arm64", .exe_ext = "", .lib_ext = ".dylib", .lib_prefix = "lib", .col = 'm' },
};

fn findPlatform(name: []const u8) ?Platform {
    for (platforms) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The host's own entry in `platforms`, so a bare `ringpp build app.ring`
/// with no `--target` does the obvious thing.
fn hostPlatformName() []const u8 {
    return switch (builtin.target.os.tag) {
        .windows => "win64",
        .macos => if (builtin.target.cpu.arch == .aarch64) "macos-arm64" else "macos-x64",
        else => if (builtin.target.cpu.arch == .aarch64) "linux-arm64" else "linux-x64",
    };
}

fn exists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// A minimal `which`: PATH is the only lookup, because that is what a user
/// actually has when they type `ring` at a shell.
fn findOnPath(gpa: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const path_env = std.process.getEnvVarOwned(gpa, "PATH") catch return null;
    defer gpa.free(path_env);
    const sep: u8 = if (builtin.target.os.tag == .windows) ';' else ':';
    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const cand = if (builtin.target.os.tag == .windows)
            try std.fmt.allocPrint(gpa, "{s}\\{s}.exe", .{ dir, name })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
        if (exists(cand)) return cand;
        gpa.free(cand);
    }
    return null;
}

fn usage(w: anytype) void {
    w.print(
        \\usage: ringpp build <entry.ring> [options]
        \\
        \\  --target <platform>   win64 | linux-x64 | linux-arm64 | macos-x64 | macos-arm64
        \\                        (default: the platform ringpp itself is running on)
        \\  --ring <path>         a working `ring` executable, used to compile the
        \\                        entry point ( -go ). Default: search PATH.
        \\  --ring-root <dir>     a Ring install, so `load "stdlib.ring"` and friends
        \\                        can be followed (same meaning as `ringpp deps --ring`)
        \\  --runtime <path>      an explicit B2 runtime stub for --target
        \\  --runtime-dir <dir>   search <dir>/<target>/ring[.exe] for the stub
        \\                        (default: alongside the ringpp executable, then ./runtime)
        \\  --lib-dir <dir>       a directory holding the TARGET's actual native
        \\                        library files, to bundle what `deps` names
        \\  --out <dir>           output directory (default: <entry-basename>-<target>)
        \\
    , .{}) catch {};
}

pub fn run(gpa: std.mem.Allocator, w: anytype, args: []const []const u8) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (args.len < 3 or std.mem.eql(u8, args[2], "-h") or std.mem.eql(u8, args[2], "--help")) {
        usage(w);
        return if (args.len < 3) 1 else 0;
    }
    const entry = args[2];

    var target_name = hostPlatformName();
    var ring_exe: ?[]const u8 = null;
    var ring_root: ?[]const u8 = null;
    var runtime_path: ?[]const u8 = null;
    var runtime_dir: ?[]const u8 = null;
    var lib_dir: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const val: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, flag, "--target") and val.len > 0) {
            target_name = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--ring") and val.len > 0) {
            ring_exe = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--ring-root") and val.len > 0) {
            ring_root = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--runtime") and val.len > 0) {
            runtime_path = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--runtime-dir") and val.len > 0) {
            runtime_dir = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--lib-dir") and val.len > 0) {
            lib_dir = val;
            i += 1;
        } else if (std.mem.eql(u8, flag, "--out") and val.len > 0) {
            out_dir = val;
            i += 1;
        } else {
            try w.print("ringpp build: unknown option '{s}'\n", .{flag});
            usage(w);
            return 1;
        }
    }

    if (!exists(entry)) {
        try w.print("ringpp build: no such file: {s}\n", .{entry});
        return 1;
    }
    const plat = findPlatform(target_name) orelse {
        try w.print("ringpp build: unknown --target '{s}'. Known: win64, linux-x64, linux-arm64, macos-x64, macos-arm64\n", .{target_name});
        return 1;
    };

    // ---------------------------------------------------------- 1. compile
    const ring_found = ring_exe orelse (try findOnPath(a, "ring")) orelse {
        try w.print("ringpp build: no `ring` found on PATH, and --ring was not given.\n", .{});
        try w.print("              `ringpp build` compiles bytecode by shelling out to a\n", .{});
        try w.print("              working Ring — it does not reimplement Ring's compiler.\n", .{});
        return 1;
    };
    const ring = std.fs.cwd().realpathAlloc(a, ring_found) catch ring_found;

    const entry_dir = std.fs.path.dirname(entry) orelse ".";
    const entry_base = std.fs.path.stem(std.fs.path.basename(entry));
    const ringo_path = try std.fs.path.join(a, &.{ entry_dir, try std.fmt.allocPrint(a, "{s}.ringo", .{entry_base}) });

    const compiled = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{ ring, entry, "-go" },
        .max_output_bytes = 4 * 1024 * 1024,
    });
    defer gpa.free(compiled.stdout);
    defer gpa.free(compiled.stderr);
    if (!exists(ringo_path)) {
        try w.print("ringpp build: `{s} {s} -go` did not produce {s}\n", .{ ring, entry, ringo_path });
        if (compiled.stderr.len > 0) try w.print("  {s}\n", .{compiled.stderr});
        return 1;
    }
    const ringo_bytes = try std.fs.cwd().readFileAlloc(a, ringo_path, 256 * 1024 * 1024);

    // -------------------------------------------------------------- 2. deps
    const rep = try deps.collect(a, entry, ring_root);
    const closure_complete = rep.loads_unfound.items.len == 0;

    // Refuse before writing anything. Bundling ringqt.dll alone (the only
    // thing loadlib scanning can name) produces a package that reports
    // "nothing missing" and then crashes with no diagnostic at all --
    // measured, not assumed: exit 0xC0000409 in an isolated directory,
    // caused by the ~75 further Qt libraries ringqt.dll itself needs at
    // the OS loader level, invisible to this tool by construction. Per the
    // project's dependency-free principle Ring++ does not package Qt
    // programs at all, rather than half-support one into a false success.
    if (rep.excluded.items.len > 0) {
        try w.print("ringpp build: this program reaches Ring's Qt bridge ({s}), which\n", .{rep.excluded.items[0].base});
        try w.print("  Ring++ does not package — see DESIGN_BUILD.md sections 3 and 6.\n", .{});
        try w.print("  `ringpp deps` explains why bundling it would be unsafe.\n", .{});
        return 1;
    }

    // ---------------------------------------------------------- 3. runtime
    const exe_self_dir = std.fs.selfExeDirPathAlloc(a) catch null;
    var found_runtime: ?[]const u8 = runtime_path;
    if (found_runtime == null) {
        const stub_name = try std.fmt.allocPrint(a, "ring{s}", .{plat.exe_ext});
        var cands = std.ArrayList([]const u8){};
        if (runtime_dir) |d| try cands.append(a, try std.fs.path.join(a, &.{ d, plat.name, stub_name }));
        if (exe_self_dir) |d| try cands.append(a, try std.fs.path.join(a, &.{ d, "runtime", plat.name, stub_name }));
        try cands.append(a, try std.fs.path.join(a, &.{ "runtime", plat.name, stub_name }));
        for (cands.items) |c| {
            if (exists(c)) {
                found_runtime = c;
                break;
            }
        }
    }
    // Absolutise before it goes in the manifest. A relative path recorded
    // there is only meaningful if you also know the build's CWD, which the
    // manifest does not record — that reads as precise and is not.
    if (found_runtime) |fr| found_runtime = std.fs.cwd().realpathAlloc(a, fr) catch fr;
    const runtime = found_runtime orelse {
        try w.print("ringpp build: no runtime stub for '{s}'. Looked beside ringpp, and\n", .{plat.name});
        try w.print("              under ./runtime/{s}/. Build one (phase B2):\n", .{plat.name});
        try w.print("                powershell -File tests\\b2_runtimes.ps1\n", .{});
        try w.print("              or pass --runtime <path> directly.\n", .{});
        return 1;
    };
    const runtime_bytes = try std.fs.cwd().readFileAlloc(a, runtime, 64 * 1024 * 1024);

    // --------------------------------------------------------- 4. assemble
    const out = out_dir orelse try std.fmt.allocPrint(a, "{s}-{s}", .{ entry_base, plat.name });
    try std.fs.cwd().makePath(out);

    const out_exe = try std.fs.path.join(a, &.{ out, try std.fmt.allocPrint(a, "{s}{s}", .{ entry_base, plat.exe_ext }) });
    try std.fs.cwd().writeFile(.{ .sub_path = out_exe, .data = runtime_bytes });
    const out_ringo = try std.fs.path.join(a, &.{ out, try std.fmt.allocPrint(a, "{s}.ringo", .{entry_base}) });
    try std.fs.cwd().writeFile(.{ .sub_path = out_ringo, .data = ringo_bytes });

    var bundled = std.ArrayList([]const u8){};
    var missing = std.ArrayList([]const u8){};
    for (rep.libs.items) |l| {
        const fname: ?[]const u8 = switch (plat.col) {
            'w' => l.win,
            'm' => l.mac,
            else => l.lin,
        };
        const name = fname orelse continue; // not declared for THIS platform's spelling at all
        var placed = false;
        if (lib_dir) |ld| {
            const src = try std.fs.path.join(a, &.{ ld, name });
            if (exists(src)) {
                const dst = try std.fs.path.join(a, &.{ out, name });
                try std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});
                try bundled.append(a, name);
                placed = true;
            }
        }
        if (!placed) try missing.append(a, name);
    }

    // ---------------------------------------------------------- 5. manifest
    var mf = std.ArrayList(u8){};
    const mw = mf.writer(a);
    try mw.print("Ring++ build manifest — ringpp build (phase B3)\n\n", .{});
    try mw.print("entry     : {s}\n", .{entry});
    try mw.print("target    : {s}\n", .{plat.name});
    try mw.print("ring used : {s}\n", .{ring});
    try mw.print("runtime   : {s}\n\n", .{runtime});
    try mw.print("run with  : {s}{s} {s}.ringo\n\n", .{ entry_base, plat.exe_ext, entry_base });

    if (rep.libs.items.len == 0 and closure_complete) {
        try mw.print("dependencies: PURE RING. No native library reachable from this\n", .{});
        try mw.print("  program (FINDINGS F-29 — .ringo + a runtime stub is everything\n", .{});
        try mw.print("  it needs, and that pair is portable between x64 platforms).\n", .{});
    } else if (!closure_complete) {
        try mw.print("dependencies: INCOMPLETE PICTURE. {d} load target(s) could not be\n", .{rep.loads_unfound.items.len});
        try mw.print("  located ({s}), so this manifest may be missing libraries this\n", .{if (ring_root == null) "no --ring-root was given" else "not found under --ring-root"});
        try mw.print("  program actually needs. Do not ship this build.\n", .{});
    } else {
        try mw.print("dependencies:\n", .{});
        for (bundled.items) |n| try mw.print("  bundled  {s}\n", .{n});
        for (missing.items) |n| try mw.print("  MISSING  {s}  (not found under --lib-dir)\n", .{n});
        if (missing.items.len > 0) {
            try mw.print("\n  A missing library is not a broken build; it is an honest report.\n", .{});
            try mw.print("  This package will fail exactly where the real dependency bites —\n", .{});
            try mw.print("  see FINDINGS F-29 for why a failed loadlib is silent on Windows\n", .{});
            try mw.print("  and fatal on Linux.\n", .{});
        }
    }
    const manifest_path = try std.fs.path.join(a, &.{ out, "BUILD-MANIFEST.txt" });
    try std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = mf.items });

    // ------------------------------------------------------------- 6. print
    try w.print("\nbuilt  {s}\n", .{out});
    try w.print("  {s}{s}\n", .{ entry_base, plat.exe_ext });
    try w.print("  {s}.ringo\n", .{entry_base});
    for (bundled.items) |n| try w.print("  {s}\n", .{n});
    try w.print("\nrun with:  {s}{s} {s}.ringo\n", .{ entry_base, plat.exe_ext, entry_base });
    if (!closure_complete) {
        try w.print("\nWARNING: dependency picture is incomplete — see BUILD-MANIFEST.txt\n", .{});
        return 1;
    }
    if (missing.items.len > 0) {
        try w.print("\n{d} declared librar{s} not bundled — see BUILD-MANIFEST.txt\n", .{ missing.items.len, if (missing.items.len == 1) "y" else "ies" });
    }
    return 0;
}
