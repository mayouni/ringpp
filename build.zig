const std = @import("std");

// Ring++ — the `ringpp` CLI.
//
// Tier 0: analysis only. Nothing here needs a C compiler on the user's
// machine — tree-sitter and the Ring grammar are statically linked into the
// binary at build time. See docs/DESIGN_TOOLCHAIN.md §5 and §7.

const ts_sources = [_][]const u8{
    "vendor/tree-sitter/src/lib.c",
};

const grammar_sources = [_][]const u8{
    "vendor/tree-sitter-ring/src/parser.c",
    "vendor/tree-sitter-ring/src/scanner.c",
};

// The generated parser table is 21 MB of switch statements; -O2 on it costs
// build time and buys nothing, so it is compiled -O1 while our own code and
// the tree-sitter runtime get the normal optimisation level.
// -fno-sanitize=undefined: Zig turns UBSan on for C in Debug/ReleaseSafe, and
// tree-sitter's generated parser trips it (harmlessly) on the way through its
// table. Same reason RingScript's build.zig carries the flag.
const c_flags = [_][]const u8{ "-std=c11", "-w", "-fno-sanitize=undefined" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    mod.addIncludePath(b.path("vendor/tree-sitter-ring/src"));
    mod.addCSourceFiles(.{ .files = &ts_sources, .flags = &c_flags });
    mod.addCSourceFiles(.{ .files = &grammar_sources, .flags = &(c_flags ++ [_][]const u8{"-O1"}) });

    // FINDINGS.md is handed to the module so a test can @embedFile it and
    // assert that every citation in `ringpp why` points at a heading that
    // actually exists. @embedFile cannot reach outside src/, and a citation
    // nobody verifies is how a help system starts lying.
    mod.addAnonymousImport("findings_md", .{ .root_source_file = b.path("docs/FINDINGS.md") });

    const exe = b.addExecutable(.{ .name = "ringpp", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run ringpp").dependOn(&run.step);

    // `zig build test` — the gates from docs/PHASE_PLAN.md T1.
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build conformance` — docs/PHASE_PLAN.md P4.
    //
    // Builds a `ring` from every configured VM source tree and runs the
    // Ring++ gates against each, then writes docs/MATRIX.md. It compiles the
    // VMs itself rather than declaring them here, because the file list
    // differs between Ring versions and a hardcoded list would silently go
    // stale — which is the exact failure this step exists to catch.
    const conf_exe = b.addExecutable(.{
        .name = "ringpp-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const conf_run = b.addRunArtifact(conf_exe);
    conf_run.setCwd(b.path("."));
    conf_run.stdio = .inherit;
    if (b.args) |args| conf_run.addArgs(args);
    b.step("conformance", "Build every configured Ring VM and run the gates against each")
        .dependOn(&conf_run.step);
}
