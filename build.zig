const std = @import("std");

// Three builds that differ in EXACTLY one thing at a time, so the memory
// model's cost decomposes instead of arriving as one lump:
//
//   zig build                    -> rnx-arena    bump arena, never frees
//   zig build -Dmi=true          -> rnx-mi       mimalloc, still never frees
//   zig build -Dmi=true -Drc=true-> rnx-mi-rc    mimalloc + refcounts + frees
//
// arena->mi prices the allocator. mi->mi-rc prices the refcount traffic.
//
// mimalloc is vendored under vendor/mimalloc (provenance and sha256 in its
// NOTES.md and SHA256SUMS; F-40 is why it is here). -Dmimalloc=<path>
// overrides the location.

// The Ring grammar and the tree-sitter runtime, vendored under vendor/ with
// SHA256SUMS; -Dts=<path> overrides. The generated parser table is 21 MB of
// switch statements so it is compiled -O1; UBSan trips harmlessly on it;
// fdopen needs a POSIX level declared for non-Windows targets -- and on
// glibc that level HIDES le16toh/be16toh from <endian.h>, which the runtime's
// unicode.h calls, unless _DEFAULT_SOURCE is declared beside it (tree-sitter's
// own Makefile does both). Found by the first Linux build, 2026-09-28.
const ts_c_flags = [_][]const u8{
    "-std=c11",
    "-w",
    "-fno-sanitize=undefined",
    "-D_POSIX_C_SOURCE=200809L",
    "-D_DEFAULT_SOURCE",
    "-D_DARWIN_C_SOURCE",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Plain standardOptimizeOption: passing preferred_optimize_mode replaces
    // -Doptimize with a -Drelease bool that still DEFAULTS TO DEBUG, which
    // silently produced a 5x-slow "measurement" the first time round.
    const optimize = b.standardOptimizeOption(.{});

    const rc = b.option(bool, "rc", "reference counting and real frees") orelse false;
    const mi = b.option(bool, "mi", "allocate through mimalloc instead of a bump arena") orelse false;
    const typed = b.option(bool, "typed", "typed registers: skip refcount traffic the compiler can prove unnecessary") orelse false;
    const mipath = b.option([]const u8, "mimalloc", "path to the mimalloc tree") orelse b.pathFromRoot("vendor/mimalloc");

    if (rc and !mi) @panic("-Drc=true requires -Dmi=true: refcounting a bump arena is meaningless");
    const deferred = b.option(bool, "deferred", "deferred counting: registers are uncounted roots, freed via a zero-count table") orelse false;

    // C-7 (2026-09-11): the clone-on-write is gone -- Ring's copy happens at
    // the assignment now (the `copyv` opcode), and a write through a
    // parameter reaches the caller's list as Ring's does. The option stays
    // so the A/B build names and every recorded row keep their meaning; it
    // no longer changes behaviour.
    const cow = b.option(bool, "cow", "kept for the build names; superseded by eager copy at assignment (C-7)") orelse false;

    if (cow and !rc) @panic("-Dcow=true requires -Drc=true: the shared test IS the refcount");
    if (typed and !rc) @panic("-Dtyped=true requires -Drc=true: there is no counting to elide otherwise");
    if (deferred and !typed) @panic("-Ddeferred=true is measured on top of -Dtyped=true");

    const opts = b.addOptions();
    opts.addOption(bool, "rc", rc);
    opts.addOption(bool, "mi", mi);
    opts.addOption(bool, "typed", typed);
    opts.addOption(bool, "deferred", deferred);
    opts.addOption(bool, "cow", cow);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("config", opts);

    const name = if (cow and deferred) "rnx-cow-defer" else if (cow) "rnx-cow" else if (deferred) "rnx-defer" else if (typed) "rnx-mi-rc-typed" else if (rc) "rnx-mi-rc" else if (mi) "rnx-mi" else "rnx-arena";
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });

    if (mi) {
        mod.link_libc = true;
        mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mipath}) });
        mod.addCSourceFile(.{
            .file = .{ .cwd_relative = b.fmt("{s}/src/static.c", .{mipath}) },
            // No MI_MALLOC_OVERRIDE: this build calls mi_malloc_aligned
            // directly, and merely DEFINING that macro (even to 0) makes
            // mimalloc try to interpose malloc, which cannot work in a
            // statically linked Windows exe.
            .flags = &.{ "-O2", "-DNDEBUG" },
        });
    }

    b.installArtifact(exe);

    // ---- rnxc: the front end (Stage 2) -------------------------------
    const tspath = b.option([]const u8, "ts", "path to the vendor/ tree") orelse b.pathFromRoot("vendor");

    const cmod = b.createModule(.{
        .root_source_file = b.path("src/rnxc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // rnxc imports the VM out of main.zig, so it needs the same options.
    cmod.addOptions("config", opts);
    cmod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/tree-sitter/include", .{tspath}) });
    cmod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/tree-sitter/src", .{tspath}) });
    cmod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/tree-sitter-ring/src", .{tspath}) });
    cmod.addCSourceFile(.{
        .file = .{ .cwd_relative = b.fmt("{s}/tree-sitter/src/lib.c", .{tspath}) },
        .flags = &ts_c_flags,
    });
    cmod.addCSourceFiles(.{
        .root = .{ .cwd_relative = b.fmt("{s}/tree-sitter-ring/src", .{tspath}) },
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &(ts_c_flags ++ [_][]const u8{"-O1"}),
    });
    // rnxc runs programs, so its VM heap must FREE (the compiler keeps its
    // arena). mimalloc is vendored for exactly this -- F-40 -- and it is
    // measurably better than libc malloc on the kernels: Sieve 68 ms through
    // libc against 56 through mimalloc, measured 2026-09-12.
    cmod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mipath}) });
    cmod.addCSourceFile(.{
        .file = .{ .cwd_relative = b.fmt("{s}/src/static.c", .{mipath}) },
        .flags = &.{ "-O2", "-DNDEBUG" },
    });
    b.installArtifact(b.addExecutable(.{ .name = "rnxc", .root_module = cmod }));

    // Ring's standard library beside rnxc, in Ring's own layout, so a
    // program's `load "stdlibcore.ring"` resolves here exactly as it does
    // beside ring.exe: <exefolder>/load/ holds the shims, and the shim's
    // /../../libraries/stdlib is <prefix>/libraries/stdlib. See
    // vendor/ring-stdlib/NOTES.md.
    b.installDirectory(.{
        .source_dir = b.path("vendor/ring-stdlib/load"),
        .install_dir = .bin,
        .install_subdir = "load",
    });
    // ...except the two files whose functions read stdlib.rh's globals BARE,
    // which Rule A refuses -- Sleep() and List2Code() among them, which the
    // estate calls. OURS (rpp/stdlib) are Ring's with those reads made `$`,
    // every line number unchanged; the vendored pair stays for the ORACLE.
    // The separator is in the suffix because usestdlibcore.ring ends in
    // "stdlibcore.ring" too, and it is Ring's, unchanged.
    b.installDirectory(.{
        .source_dir = b.path("vendor/ring-stdlib/libraries"),
        .install_dir = .prefix,
        .install_subdir = "libraries",
        .exclude_extensions = &.{
            "stdlib" ++ std.fs.path.sep_str ++ "stdlib.rh",
            "stdlib" ++ std.fs.path.sep_str ++ "stdlibcore.ring",
        },
    });
    b.installDirectory(.{
        .source_dir = b.path("rpp/stdlib"),
        .install_dir = .prefix,
        .install_subdir = "libraries/stdlib",
    });
    // The zip extension's Ring-side shim, so `load "ziplib.ring"` resolves
    // here as it does beside ring.exe -- but OURS (rpp/ringzip), not the
    // vendored one, because the native half is BUILT IN. Ring reaches zip
    // through an extension DLL; src/zip.zig publishes the same twelve names
    // at start-up, so the shim has no LoadLib line and nothing outside this
    // repository is reached. The vendored files stay for the ORACLE, which
    // is Ring's own build and must behave like Ring.
    b.installDirectory(.{
        .source_dir = b.path("rpp/ringzip"),
        .install_dir = .prefix,
        .install_subdir = "extensions/ringzip",
        .include_extensions = &.{".ring"},
    });
}
