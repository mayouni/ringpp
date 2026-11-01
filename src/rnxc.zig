//! rnxc — the Ring-Next front end. Stage 2, milestone 1.
//!
//!     rnxc dump <file.ring>     print the parse tree (a tool for building
//!                               this compiler, not a product feature)
//!
//! The parser is ringpp's vendored tree-sitter-ring, the same grammar the
//! checker uses. What is new here is that its output is consumed by CODEGEN
//! rather than by diagnostics: in the checker a wrong guess about a node's
//! shape produces a false positive, here it produces a wrong program. So
//! every node kind this file handles is one that was read out of a real
//! parse tree first, never one that was assumed.

const std = @import("std");
const ts = @import("ts.zig");
const co = @import("compile.zig");
const vm = @import("main.zig");
const check = @import("check.zig");
const universe = @import("universe.zig");
const image = @import("image.zig");
const dumpjson = @import("dumpjson.zig");
const fmt = @import("fmt.zig");
const graph = @import("graph.zig");
const zip = @import("zip.zig");
const httpd = @import("httpd.zig");
const prefix = @import("prefix.zig");
const lift = @import("lift.zig");
const native = @import("native.zig");

/// Ring's `shutdown(n)` (vendor/ring-vm/src/os_e.c:235): end the program HERE with exit code n -- 0 with no argument,
/// as `bye` -- wherever it stands; nothing after it runs. A guard ends with `shutdown($nFail)` so that its exit code
/// says what its last line says; without it the call was R3 and the guard died on its LAST line, after printing its verdict.
/// A native of ours rather than a builtin of the VM: an edit inside the run loop moves the layout of every kernel (F-118).
/// A non-number is "Bad parameter type!", a number outside an int is "...error in range!", more than one argument is an error.
fn ringShutdown(args: [*]const native.RppVal, argc: u32, out: *native.RppVal) callconv(.c) c_int {
    var code: i32 = 0;
    if (argc > 1) {
        out.* = native.RppVal.str("Bad parameters count, the function expect one parameter");
        return 1;
    }
    if (argc == 1) {
        const a = args[0];
        const d: f64 = switch (a.tag) {
            @intFromEnum(native.Tag.int) => @floatFromInt(@as(i64, @bitCast(a.bits))),
            @intFromEnum(native.Tag.num) => @bitCast(a.bits),
            else => {
                out.* = native.RppVal.str("Bad parameter type!");
                return 1;
            },
        };
        if (d != d or d < -2147483648.0 or d > 2147483647.0) {
            out.* = native.RppVal.str("Bad parameters value, error in range!");
            return 1;
        }
        code = @intFromFloat(d);
    }
    vm.outFlush();
    // Windows keeps all 32 bits of the code; POSIX keeps the low eight, which is what Ring's exit() gets there too.
    if (@import("builtin").os.tag == .windows) {
        std.os.windows.kernel32.ExitProcess(@bitCast(code));
    } else {
        std.process.exit(@truncate(@as(u32, @bitCast(code))));
    }
}

/// THE VM HEAP FREES; the compiler's arena does not, and must not -- parse
/// trees, the code stream and the constant table live until exit, and a bump
/// arena is the right shape for that. But the VM's strings, lists and objects
/// are REFCOUNTED, and `release` on an arena is a NO-OP: every value a program
/// ever made stayed resident. Measured 2026-09-12 on perf/engine_senses, which
/// reports its own footprint: 615 MB against Ring's 136, and then `panic: oom`
/// inside a string concatenation.
///
/// Constants are safe here: the compiler builds them with rc = 1 and every
/// retain/release pairs, so they never reach zero and this allocator is never
/// asked to free arena memory.
/// Chosen at startup: mimalloc normally, the POISONING heap when
/// RNXC_POISON is set. See vm.poison_allocator for why that exists.
var vmheap: std.mem.Allocator = undefined;

/// A file and its parse tree, kept alive because every Node points into it.
const Unit = struct {
    trees: std.ArrayListUnmanaged(ts.Tree) = .{},
    roots: std.ArrayListUnmanaged(ts.Node) = .{},
    /// Parallel to roots: each file's bytes as they stand ON DISK. A root's `src` is the text its tree indexes, which is the file's own
    /// unless a `not` was lifted (src/lift.zig); the image stamps and anything printed for an applier are of the file.
    origs: std.ArrayListUnmanaged([]const u8) = .{},
    /// Read Ring's `not` as Ring does (C-32). Off for the commands that print a BYTE OFFSET into the file (migrate, attrs, shadows) and
    /// for `dump`, which shows the grammar's own tree.
    lift: bool = true,
    paths: std.ArrayListUnmanaged([]const u8) = .{},
    /// Parallel to paths: each file as Ring NAMES it in a report (F-111) --
    /// the root as typed, a loaded file as the folder its load was resolved
    /// against, the platform separator and the load as written.
    names: std.ArrayListUnmanaged([]const u8) = .{},
    /// `load` targets that could not be read. Each is a whole file the
    /// checker cannot see, so any one of them shuts the absence rules for
    /// the unit (src/universe.zig). Counted here, named where it happens.
    missing: u32 = 0,
    /// Files whose text Ring's SCANNER rejects -- an unclosed literal (S1) or
    /// comment (S2) -- so Ring runs nothing of the program (F-109).
    scan_bad: u32 = 0,
    /// The first implicit file Ring would read beside a file of the unit,
    /// and that file (C-28, `implicitIn`).
    implicit: ?Implicit = null,
    /// The ROOT's text when it is not a file: `admitcode(cName, cSource)`
    /// admits source a program built, under a name it chose. Its loads
    /// resolve as a root's do, against the current directory.
    root_src: ?[]const u8 = null,
    /// The `already` paths loadUnit is handed are normalised already
    /// (normalisePath): the resident VM keeps its held files' keys, where
    /// normalising them again opened every one on each admission -- 612
    /// files, ~25 ms of a small admission at Softanza's size (rung 5).
    already_norm: bool = false,
    /// `rnxc check --subst=<file>=<text>`: the unit as it would be with one file's text replaced -- the rung-5
    /// gate asks about a refined library file inside the program that loads it, without writing the tree.
    /// Normalised keys (normalisePath), parallel to `subst_with`; the file keeps its own path, so its loads
    /// resolve from where it stands.
    subst_keys: []const []const u8 = &.{},
    subst_with: []const []const u8 = &.{},
};

/// RING READS FILES NOBODY NAMED (vendor/ring-vm/src/state.c:177-203 and
/// 476-485). `ring.ring` or `ring.ringo` in the current folder is run INSTEAD
/// of the program on the command line; `startup.ring` in the folder of the
/// first file Ring reads is loaded before it; and `ringsyntax.ring` in the
/// folder of EVERY file it reads -- it switches into that folder first
/// (state.c:164) -- is read before the file and may rename keywords and
/// operators. Ring++ reads none of them (C-28), so beside one a program would
/// run here as a different program from Ring's, with no word said: it is
/// refused instead, naming the file. Softanza has none.
const Implicit = struct { path: []const u8, kind: enum { instead, startup, syntax }, of: []const u8 };

fn implicitIn(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const p = std.fs.path.join(alloc, &.{ dir, name }) catch return null;
    std.fs.cwd().access(p, .{}) catch return null;
    return p;
}

/// The checks that need no load graph: the current folder, and the root's.
fn implicitAtStart(alloc: std.mem.Allocator, root_path: []const u8) ?Implicit {
    for ([_][]const u8{ "ring.ring", "ring.ringo" }) |n|
        if (implicitIn(alloc, ".", n)) |p| return .{ .path = p, .kind = .instead, .of = root_path };
    const dir = std.fs.path.dirname(root_path) orelse ".";
    if (implicitIn(alloc, dir, "startup.ring")) |p| return .{ .path = p, .kind = .startup, .of = root_path };
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(root_path), "ringsyntax.ring"))
        if (implicitIn(alloc, dir, "ringsyntax.ring")) |p| return .{ .path = p, .kind = .syntax, .of = root_path };
    return null;
}

fn refuseImplicit(im: Implicit) noreturn {
    var buf: [2048]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    w.print("\nRing++ refused this program (C-28): Ring would read {s}, a file the program does not name, ", .{im.path}) catch {};
    switch (im.kind) {
        .instead => w.print("and run it INSTEAD of {s}", .{im.of}) catch {},
        .startup => w.print("before {s}", .{im.of}) catch {},
        .syntax => w.print("before {s}, and it may rename Ring's keywords and operators", .{im.of}) catch {},
    }
    w.print(" -- Ring++ reads none of Ring's implicit files, so the program would run here as a different one\n", .{}) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

/// RING'S SCANNER, the part that can refuse a file (F-109; vendor/ring-vm/
/// src/scanner.c:105-171, measured on 1.27). A `"`, `'` or `` ` `` opens a
/// literal that only the same character closes -- across lines, no escapes;
/// `#` and `//` comment to the end of the line; `/*` opens a comment that
/// `*/` closes (stars may repeat). One still open at the end of the text is
/// S1 or S2, at the line where it OPENED. A quote inside a comment and a
/// comment marker inside a literal are nothing. Exact by construction: it is
/// the scanner's own state machine, not the grammar's reading, so it cannot
/// refuse a file Ring would run.
const ScanErr = struct { s1: bool, line: u32 };
fn ringScanError(src: []const u8) ?ScanErr {
    var i: usize = 0;
    if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) i = 3;
    var line: u32 = 1;
    var state: enum { gen, lit, cmt, ml } = .gen;
    var delim: u8 = 0;
    var start: u32 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        switch (state) {
            .gen => {
                if (c == '"' or c == '\'' or c == '`') {
                    state = .lit;
                    delim = c;
                    start = line;
                } else if (c == '#') {
                    state = .cmt;
                } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
                    state = .cmt;
                    i += 1;
                } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
                    state = .ml;
                    start = line;
                    i += 1;
                }
            },
            .lit => if (c == delim) {
                state = .gen;
            },
            .cmt => if (c == '\n') {
                state = .gen;
            },
            .ml => if (c == '*' and i + 1 < src.len and src[i + 1] == '/') {
                state = .gen;
                i += 1;
            },
        }
        if (c == '\n') line += 1;
    }
    return switch (state) {
        .lit => .{ .s1 = true, .line = start },
        .ml => .{ .s1 = false, .line = start },
        else => null,
    };
}

/// The scanner's report, as scanner.c:420-446 prints it: the file Ring was
/// reading, the line, and -- for a loaded file -- `Called from other source
/// code file` with no newline after it.
fn printScanError(w: *std.Io.Writer, e: ScanErr, name: []const u8, loaded: bool) !void {
    try w.print("Error ({s}) In file: {s} \n", .{ if (e.s1) "S1" else "S2", name });
    try w.print("In Line ({d}) {s} \n", .{ e.line, if (e.s1) "Literal not closed" else "Unclosed comment" });
    if (loaded) try w.print("Called from other source code file", .{});
}

/// Where the seconds go. A census of the corpus took 170-220 s and no
/// one knew which phase owned it; these are read from `phases:` in the
/// census output, so the number is never guessed.
threadlocal var t_read_ns: u64 = 0;
threadlocal var t_parse_ns: u64 = 0;

/// A single dummy address for the library's sources, which are not read on
/// the prefix path. `fileOf` maps a source POINTER to a file index, and it is
/// only ever asked about the file being compiled; these entries have to be
/// present so the indices line up, and must never match a real pointer.
var no_src: u8 = 0;

/// Is there a compiled library this file can be put on top of?
///
/// Parses the ROOT file alone -- one file, a few milliseconds -- to see what
/// it loads first, then looks for a prefix built from exactly that. Returns
/// the restored compiler, or null, which means "walk the load graph and
/// compile the unit whole" and is what always used to happen.
fn tryPrefix(
    alloc: std.mem.Allocator,
    parser: ts.Parser,
    root_path: []const u8,
    stamps: *std.ArrayListUnmanaged(image.Stamp),
    /// the library files' Ring names, parallel to stamps (F-111)
    names: *std.ArrayListUnmanaged([]const u8),
    on_top: *Unit,
) ?*co.Compiler {
    const src = std.fs.cwd().readFileAlloc(alloc, root_path, 64 << 20) catch return null;
    const tree = parser.parse(src) orelse return null;
    const rt = tree.root();

    // THE ONE THING A PREFIX CANNOT DO IS COME SECOND. Ring runs a loaded
    // file's top level AT the load statement, so the library's block is
    // first only if its load is the first thing in the file. Anything else
    // -- a line printed before it, another file loaded before it -- puts
    // this file's code in front of the library's, and a prefix cannot be
    // spliced into the middle of itself.
    //
    // OTHER loads are fine and are the normal case: every narrated test in
    // the estate says `load "../../stzBase.ring"` and then `load
    // "../_narrated.ring"`. Everything that is not the library is compiled
    // ON TOP, in the order the splice gives -- which is exact, because
    // those files are parsed here.
    var lib_lit: ?[]const u8 = null;
    var i: u32 = 0;
    while (i < rt.namedChildCount()) : (i += 1) {
        const ch = rt.namedChild(i);
        const k = ch.kind();
        if (std.mem.eql(u8, k, "comment")) continue;
        if (!std.mem.eql(u8, k, "load_statement")) break;
        if (ch.namedChildCount() == 0) return null;
        var lit = ch.namedChild(0).text();
        if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'' or lit[0] == '`')) lit = lit[1 .. lit.len - 1];
        if (lit.len == 0) return null;
        lib_lit = lit;
        break; // the FIRST load is the only one that can be the library
    }
    const lit = lib_lit orelse return null;

    const dir = std.fs.path.dirname(root_path) orelse ".";
    const lib_path = resolveLoad(alloc, lit, dir, true) catch return null;
    const lib_abs = std.fs.cwd().realpathAlloc(alloc, lib_path) catch lib_path;
    const p = prefix.pathFor(alloc, lib_abs) orelse return null;

    const c = alloc.create(co.Compiler) catch return null;
    c.* = .{ .alloc = alloc, .lenient = true };
    const sa = alloc.create(std.heap.ArenaAllocator) catch return null;
    sa.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    c.scratch_arena = sa;
    c.scratch = sa.allocator();
    if (!prefix.load(alloc, p, image.ExeStamp.ofSelf(alloc), c, stamps, names)) return null;
    // the library's own entry is named by THIS program's load of it, which
    // the prefix could not know: the folder it was found from, as written
    if (names.items.len > 0) {
        const cwd = std.process.getCwdAlloc(alloc) catch ".";
        names.items[0] = ringLoadName(alloc, lit, dir, true, lib_path, cwd) catch names.items[0];
    }

    // Now the files that are NOT the library: this one, and anything it
    // loads that the prefix does not already carry. The walk stops dead at
    // every library file, which is where the 3.38 s of parsing went.
    var lib_paths = alloc.alloc([]const u8, stamps.items.len) catch return null;
    for (stamps.items, 0..) |st, k| lib_paths[k] = st.path;
    loadUnit(alloc, parser, root_path, on_top, false, lib_paths) catch return null;
    if (on_top.roots.items.len == 0) return null;
    image.say("on top of the prefix: {d} file(s)", .{on_top.roots.items.len});
    return c;
}

/// Ring's own load resolution, probed on 1.27 (2026-09-09 and 2026-09-10).
/// Lifted out of loadUnit so the PREFIX lookup can ask the same question --
/// "which file does this root load first?" -- without parsing the graph.
fn resolveLoad(alloc: std.mem.Allocator, lit: []const u8, dir: []const u8, is_root: bool) ![]const u8 {
    const rooted = (lit[0] == '/' or lit[0] == '\\') and
        !(lit.len > 1 and (lit[1] == '/' or lit[1] == '\\'));
    return if (rooted) blk: {
        // F-127: Ring tries a rooted path AS WRITTEN first, then
        // <exefolder> + it, then <exefolder>/load/ + it (stmt.c:290-302).
        // On Windows `/x` names the drive's root, where nothing usually is,
        // so the load folder answers -- which is how the rule was first
        // measured, and read as "a leading `/` means load/". On Linux `/x`
        // is an ABSOLUTE path, and Softanza's node and worker scripts load
        // the library by one: every one of them was refused.
        if (fileExists(lit)) break :blk try alloc.dupe(u8, lit);
        const at_exe = try std.fs.path.join(alloc, &.{ exeDir(alloc), lit[1..] });
        if (fileExists(at_exe)) break :blk at_exe;
        break :blk try std.fs.path.join(alloc, &.{ exeDir(alloc), "load", lit[1..] });
    } else if (std.fs.path.isAbsolute(lit))
        try alloc.dupe(u8, lit)
    else blk: {
        // C-4, decided 2026-09-11: the file's OWN directory first for
        // every file, the root included; the launch directory only
        // as the root's fallback. Ring's rule for the root (launch
        // directory only) left 5,160 of Softanza's 5,179 tests
        // launchable from exactly one directory each. The one case
        // that changes meaning -- the same name both beside the root
        // and in the launch directory -- is priced in C-4.
        const beside = try std.fs.path.join(alloc, &.{ dir, lit });
        if (fileExists(beside)) break :blk beside;
        if (is_root) {
            const in_cwd = try alloc.dupe(u8, lit);
            if (fileExists(in_cwd)) break :blk in_cwd;
        }
        const at_exe = try std.fs.path.join(alloc, &.{ exeDir(alloc), lit });
        if (fileExists(at_exe)) break :blk at_exe;
        const in_load = try std.fs.path.join(alloc, &.{ exeDir(alloc), "load", lit });
        if (fileExists(in_load)) break :blk in_load;
        break :blk beside; // reported, by name, as unreadable below
    };
}

/// A LOAD THAT CANNOT BE OPENED STOPS THE PROGRAM BEFORE IT RUNS, as on Ring
/// (F-101, decided 2026-10-09 by Mansour: "refuse missing loads like Ring").
///
/// Ring reports it while PARSING, so nothing of the program runs -- not even
/// the lines above the load -- and it exits 1. rnxc used to print a note and
/// run on without the file, which is how the Linux package check of
/// 2026-09-28 passed with stzJsonFuncs.ring missing (its load spelt it in
/// another case). Measured on the oracle and official 1.27 (they agree), all
/// on STDOUT:
///
///     a load whose file cannot be opened  "\n\nError (E9) : Can't open file <as written> \n"
///                                         then "\n<file> Line (<n>) Error (C27) : Syntax Error!\n"
///     a loaded file that had errors       its own report first, then C27 at
///                                         its load line in the loading file
///     every file with errors              "\n<file> errors count : <k> \n"
///
/// in the order Ring PARSES: depth first, loads in source order -- which is
/// why this walks the graph again rather than reading loadUnit's breadth-
/// first queue. It runs only when a load is missing, so the second parse
/// costs nothing on a program that loads. Ring's names: the root as typed; a
/// loaded file as the folder it was resolved against, the platform's
/// separator, and the path as written (`C:\...\missingload\child.ring`,
/// `/root/.../_smoke/../../stzBase.ring` -- unnormalised, as Ring builds it).
///
/// NOT reproduced: a load inside a block (`if 0  load "x"  ok`), which Ring
/// reports as C3 "'ok' is missing" -- loadUnit does not follow a nested load
/// at all, and Softanza has none (C-4).
fn refuseMissingLoads(alloc: std.mem.Allocator, parser: ts.Parser, root_path: []const u8) noreturn {
    var buf: [16 * 1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;
    const cwd = std.process.getCwdAlloc(alloc) catch ".";
    var seen = std.StringHashMapUnmanaged(void){};
    if (normalisePath(alloc, root_path)) |k| seen.put(alloc, k, {}) catch {} else |_| {}
    // the ROOT is scanned whole before anything else is read (F-109)
    if (std.fs.cwd().readFileAlloc(alloc, root_path, 64 << 20)) |rsrc| {
        if (ringScanError(rsrc)) |e| {
            printScanError(w, e, root_path, false) catch {};
            w.flush() catch {};
            std.debug.print("refused: the file does not scan (an unclosed literal or comment), and Ring runs nothing then either\n", .{});
            std.process.exit(1);
        }
    } else |_| {}
    _ = loadReport(alloc, parser, root_path, root_path, true, cwd, &seen, w) catch {};
    w.flush() catch {};
    std.debug.print("refused: a load names a file that cannot be opened or does not scan, and Ring runs nothing then either\n", .{});
    std.process.exit(1);
}

fn loadReport(
    alloc: std.mem.Allocator,
    parser: ts.Parser,
    path: []const u8,
    name: []const u8,
    is_root: bool,
    cwd: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    w: *std.Io.Writer,
) !bool {
    const src = std.fs.cwd().readFileAlloc(alloc, path, 64 << 20) catch return false;
    // a loaded file that does not scan: the scanner's report, then the
    // loading file's C27 at its load line, which the caller prints (F-109)
    if (!is_root) {
        if (ringScanError(src)) |e| {
            try printScanError(w, e, name, true);
            return true;
        }
    }
    const tree = parser.parse(src) orelse return false;
    defer tree.deinit();
    const dir = std.fs.path.dirname(path) orelse ".";
    var errs: u32 = 0;
    var loads = std.ArrayListUnmanaged(ts.Node){};
    try collectLoads(alloc, tree.root(), &loads);
    for (loads.items) |ch| {
        if (ch.namedChildCount() == 0) continue;
        var lit = ch.namedChild(0).text();
        if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'' or lit[0] == '`')) lit = lit[1 .. lit.len - 1];
        if (lit.len == 0) continue;
        const line = ch.start().row + 1;
        const target = try resolveLoad(alloc, lit, dir, is_root);
        if (!fileExists(target)) {
            try w.print("\n\nError (E9) : Can't open file {s} \n", .{lit});
            // F-128: inside a block Ring's parser stops there and reports the
            // innermost block unclosed; the cascade it prints after that is
            // its error recovery, and is not reproduced line for line
            if (unclosedBlock(ch)) |u|
                try w.print("\n{s} Line ({d}) Error ({s}) : Unclosed control structure, {s} is missing\n", .{ name, line, u[0], u[1] })
            else
                try w.print("\n{s} Line ({d}) Error (C27) : Syntax Error!\n", .{ name, line });
            errs += 1;
            continue;
        }
        const key = try normalisePath(alloc, target);
        if (seen.contains(key)) continue;
        try seen.put(alloc, key, {});
        const child = try ringLoadName(alloc, lit, dir, is_root, target, cwd);
        if (try loadReport(alloc, parser, target, child, false, cwd, seen, w)) {
            try w.print("\n{s} Line ({d}) Error (C27) : Syntax Error!\n", .{ name, line });
            errs += 1;
        }
    }
    if (errs > 0) try w.print("\n{s} errors count : {d} \n", .{ name, errs });
    return errs > 0;
}

/// F-128: every `load` of a file outside its functions and classes, in source
/// order -- at its top level and nested inside its blocks.
fn collectLoads(alloc: std.mem.Allocator, n: ts.Node, out: *std.ArrayListUnmanaged(ts.Node)) !void {
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        const k = ch.kind();
        if (std.mem.eql(u8, k, "load_statement")) {
            try out.append(alloc, ch);
            continue;
        }
        if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition")) continue;
        try collectLoads(alloc, ch, out);
    }
}

/// The block a nested load stands in, as Ring's parser names it when the load
/// cannot be opened -- measured on both 1.27 builds: `if` C3 'ok', `while`
/// C4 'end', `for` C5 next (no quotes). Null at the top level.
fn unclosedBlock(n: ts.Node) ?[2][]const u8 {
    var p = n.parent();
    var guard: u32 = 0;
    while (guard < 256) : (guard += 1) {
        const k = p.kind();
        if (std.mem.eql(u8, k, "source_file")) return null;
        if (std.mem.eql(u8, k, "if_statement")) return .{ "C3", "'ok'" };
        if (std.mem.eql(u8, k, "while_statement")) return .{ "C4", "'end'" };
        if (std.mem.eql(u8, k, "for_statement")) return .{ "C5", "next" };
        p = p.parent();
    }
    return null;
}

/// The name Ring keeps for a loaded file: the folder the load was resolved
/// against, as the process sees it after changing into it, then the
/// separator, then the path as the load wrote it.
fn ringLoadName(alloc: std.mem.Allocator, lit: []const u8, dir: []const u8, is_root: bool, target: []const u8, cwd: []const u8) ![]const u8 {
    const sep = if (@import("builtin").os.tag == .windows) "\\" else "/";
    const rooted = (lit[0] == '/' or lit[0] == '\\') and !(lit.len > 1 and (lit[1] == '/' or lit[1] == '\\'));
    // Ring appends the path, leading `/` and all, to "<exefolder>load/":
    // `...\win64\load//../../libraries/stdlib/stdlib.ring`, measured --
    // unless it found it AS WRITTEN (an absolute path on Linux), when the
    // name is the path itself, or beside the executable (F-127).
    if (rooted) {
        if (std.mem.eql(u8, target, lit)) return alloc.dupe(u8, lit);
        const r_exe = try std.fs.path.join(alloc, &.{ exeDir(alloc), lit[1..] });
        if (std.mem.eql(u8, target, r_exe)) return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ exeDir(alloc), sep, lit });
        return std.fmt.allocPrint(alloc, "{s}{s}load/{s}", .{ exeDir(alloc), sep, lit });
    }
    if (std.fs.path.isAbsolute(lit)) return alloc.dupe(u8, lit);
    const beside = try std.fs.path.join(alloc, &.{ dir, lit });
    if (std.mem.eql(u8, target, beside)) {
        const base = std.fs.path.resolve(alloc, &.{ cwd, dir }) catch dir;
        return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ base, sep, lit });
    }
    if (is_root and std.mem.eql(u8, target, lit)) return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ cwd, sep, lit });
    const at_exe = try std.fs.path.join(alloc, &.{ exeDir(alloc), lit });
    if (std.mem.eql(u8, target, at_exe)) return std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ exeDir(alloc), sep, lit });
    return std.fmt.allocPrint(alloc, "{s}{s}load/{s}", .{ exeDir(alloc), sep, lit });
}

/// Follow Ring's `load` graph.
///
/// Ring resolves a relative load against the directory of the file that
/// CONTAINS it, and treats `load` as a compile-time directive -- it pulls in
/// every load it parses, whatever branch it sits in. Both are reproduced.
///
/// One deliberate difference: Ring keys its already-loaded set on the
/// literal path TEXT, so the same file reached by two spellings is loaded
/// twice and dies with C22 (function redefinition). Here the key is the
/// resolved path, which cannot double-load. That is stricter than Ring, and
/// it is noted rather than hidden: a library that relies on being loaded
/// twice would behave differently, and none should.
fn loadUnit(
    alloc: std.mem.Allocator,
    parser: ts.Parser,
    root_path: []const u8,
    u: *Unit,
    quiet: bool,
    /// Files a PREFIX already carries. They are marked loaded before the
    /// walk starts, so the graph stops at the library instead of parsing it
    /// again -- which is the whole saving.
    already: []const []const u8,
) !void {
    var queue = std.ArrayListUnmanaged([]const u8){};
    try queue.append(alloc, try alloc.dupe(u8, root_path));
    // each queued file's Ring name (F-111), parallel to the queue
    var qnames = std.ArrayListUnmanaged([]const u8){};
    try qnames.append(alloc, queue.items[0]);
    const cwd = std.process.getCwdAlloc(alloc) catch ".";
    var seen = std.StringHashMapUnmanaged(void){};
    for (already) |p| try seen.put(alloc, if (u.already_norm) p else try normalisePath(alloc, p), {});
    var implicit_dirs = std.StringHashMapUnmanaged(void){};

    var missing: u32 = 0;
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const p = queue.items[qi];
        const key = try normalisePath(alloc, p);
        if (seen.contains(key)) continue;
        try seen.put(alloc, key, {});

        var tr = std.time.Timer.start() catch unreachable;
        const sub: ?[]const u8 = for (u.subst_keys, 0..) |sk, si| {
            if (std.mem.eql(u8, sk, key)) break u.subst_with[si];
        } else null;
        const src = if (qi == 0 and u.root_src != null) u.root_src.? else std.fs.cwd().readFileAlloc(alloc, sub orelse p, 64 << 20) catch |e| {
            // Named, not counted: "2 file(s) could not be read" sends the
            // reader to grep for what a line here would have told them.
            std.debug.print("note: could not read {s} ({s})\n", .{ p, @errorName(e) });
            missing += 1;
            continue;
        };
        t_read_ns += tr.read();
        if (ringScanError(src) != null) u.scan_bad += 1;
        // C-28: a syntax file beside this one, which Ring would read first
        if (u.implicit == null and !std.ascii.eqlIgnoreCase(std.fs.path.basename(p), "ringsyntax.ring")) {
            const fdir = std.fs.path.dirname(p) orelse ".";
            if (!implicit_dirs.contains(fdir)) {
                try implicit_dirs.put(alloc, fdir, {});
                if (implicitIn(alloc, fdir, "ringsyntax.ring")) |ip| u.implicit = .{ .path = ip, .kind = .syntax, .of = p };
            }
        }
        var tp = std.time.Timer.start() catch unreachable;
        const parsed = parser.parse(src) orelse continue;
        t_parse_ns += tp.read();
        const lf: lift.Lifted = if (u.lift) lift.apply(alloc, parser, parsed, src, p) else .{ .tree = parsed, .src = src };
        const tree = lf.tree;
        try u.trees.append(alloc, tree);
        try u.roots.append(alloc, tree.root());
        try u.origs.append(alloc, src);
        try u.paths.append(alloc, p);
        try u.names.append(alloc, qnames.items[qi]);

        // queue this file's loads, resolved the way Ring resolves them.
        // The ROOT file is the one named on the command line -- index 0.
        const is_root = (qi == 0);
        const dir = std.fs.path.dirname(p) orelse ".";
        // F-128: the loads at the top level AND inside its blocks, in source
        // order -- Ring follows both as it parses (a branch never taken still
        // defines its file's functions), and the compiler runs a nested one's
        // top level where it stands.
        var loads = std.ArrayListUnmanaged(ts.Node){};
        try collectLoads(alloc, tree.root(), &loads);
        for (loads.items) |ch| {
            if (ch.namedChildCount() == 0) continue;
            var lit = ch.namedChild(0).text();
            if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'' or lit[0] == '`')) lit = lit[1 .. lit.len - 1];
            if (lit.len == 0) continue;
            // Ring's own resolution, probed on 1.27 (2026-09-09):
            //   an absolute path is itself;
            //   a leading `/` is tried as written, then <exefolder>/ + it,
            //     then <exefolder>/load/ + it (F-127: on Windows the drive's
            //     root rarely holds it, so load/ answers -- that is how
            //     bin/load/stdlibcore.ring reaches /../../libraries/stdlib;
            //     on Linux it is an absolute path and found as written);
            //   otherwise it depends on WHICH FILE the load sits in, and
            //     this took three probes on 2026-09-10 to pin down:
            //       the ROOT file's loads resolve against the CURRENT
            //         DIRECTORY -- `load "dep.ring"` beside the root file
            //         but not in the cwd is E9 "Can't open file";
            //       a LOADED file's loads resolve against ITS OWN
            //         directory -- Softanza's base/stzBase.ring says
            //         `load "common/stzFuncs.ring"` and is itself loaded
            //         from two directories up, which only works this way;
            //     then <exefolder>/, then <exefolder>/load/, which is how
            //     `load "stdlibcore.ring"` works from any directory.
            // Resolving EVERYTHING against the loading file accepts programs
            // Ring refuses; resolving everything against the cwd stopped the
            // corpus loading at all. It is neither: it is both.
            // build.zig installs vendor/ring-stdlib beside rnxc in that same
            // layout, so the estate's line 6 resolves here as it does on Ring.
            // The `/` test comes FIRST: on Windows, Zig's isAbsolute says yes
            // to a rooted `/x` too, and that branch swallowed the shim's
            // `/../../libraries/stdlib/stdlib.rh` as if it were a real path.
            // A UNC `\\server` or a drive `C:\` is absolute; a lone leading
            // separator is Ring's.
            const joined = try resolveLoad(alloc, lit, dir, is_root);
            try queue.append(alloc, joined);
            try qnames.append(alloc, try ringLoadName(alloc, lit, dir, is_root, joined, cwd));
        }
    }
    u.missing += missing;
    if (!quiet and missing > 0) {
        std.debug.print("note: {d} loaded file(s) could not be read\n", .{missing});
    }
}

/// The directory rnxc runs from -- Ring's `exefolder()`. Cached: the loader
/// asks for it once per load statement.
var exe_dir_cache: ?[]const u8 = null;
fn exeDir(alloc: std.mem.Allocator) []const u8 {
    if (exe_dir_cache) |d| return d;
    const d = std.fs.selfExeDirPathAlloc(alloc) catch ".";
    exe_dir_cache = d;
    return d;
}

fn fileExists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// A finding's detail, wrapped. Taken from the library-era CLI so the
/// diagnostics read exactly as they did.
fn wrapPrint(w: *std.Io.Writer, text: []const u8, indent: usize, width: usize) !void {
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
    try w.print("\n", .{});
}

/// Lower-case with forward slashes, so the same file is one key.
/// The key two spellings of the same file must share.
///
/// It was a lower-cased, separator-flipped copy of the path AS WRITTEN,
/// which makes `../../stzBase.ring` and `D:\...\base\stzBase.ring` two
/// different files -- fine while every path came from the same walk, and
/// wrong the moment a PREFIX brings a list of absolute paths to compare
/// against a walk that starts somewhere else. The real path first, and the
/// old form for anything that does not exist to have one.
fn normalisePath(alloc: std.mem.Allocator, p: []const u8) ![]const u8 {
    const real = std.fs.cwd().realpathAlloc(alloc, p) catch null;
    const src = real orelse p;
    const out = try alloc.alloc(u8, src.len);
    for (src, 0..) |ch, i| out[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
    return out;
}

fn dump(n: ts.Node, depth: u32, w: *std.Io.Writer) !void {
    var i: u32 = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
    const kind = n.kind();
    const txt = n.text();
    if (n.namedChildCount() == 0 and txt.len <= 40) {
        // Leaves carry their source text; interior nodes would drown it out.
        var flat: [40]u8 = undefined;
        var m: usize = 0;
        for (txt) |ch| {
            if (m == flat.len) break;
            flat[m] = if (ch == '\n') '\\' else ch;
            m += 1;
        }
        try w.print("{s}  '{s}'\n", .{ kind, flat[0..m] });
    } else {
        try w.print("{s}\n", .{kind});
    }
    // ALL children, not just named ones. Operators are anonymous tokens in
    // this grammar: `j = i` and `j += i` have identical named-child shapes,
    // so a compiler that reads only named children silently miscompiles
    // every compound assignment. Found by dumping, not by assuming.
    var k: u32 = 0;
    while (k < n.childCount()) : (k += 1) {
        try dump(n.child(k), depth + 1, w);
    }
}

/// Print the generated code. Guessing at a miscompile from its output is
/// how a wrong compiler gets "fixed" into a differently wrong one.
fn disasm(prog: co.Program, w: *std.Io.Writer) !void {
    for (prog.funcs) |f| {
        try w.print("\n{s}  entry={d} frame={d} id={d} mask=0x{x} ret={s}\n", .{
            f.name, f.entry, f.frame, f.id, f.mask, @tagName(f.ret),
        });
        for (f.locals.items) |l| {
            try w.print("    ; r{d} = {s} ({s})\n", .{ l.reg, l.name, @tagName(l.class) });
        }
    }
    try w.print("\n---- code ----\n", .{});
    for (prog.code, 0..) |in, i| {
        try w.print("{d:>4}  {s:<10} a={d:<3} b={d:<3} c={d:<3} d={d}\n", .{
            i, @tagName(in.op), in.a, in.b, in.c, in.d,
        });
    }
}

/// `rnxc call <file> <Func> [int args...]` -- run one compiled function and
/// print what it returned. The six-kernel driver is hardcoded; this is not,
/// so any Ring function in the subset can be checked against Ring itself.
fn callOne(alloc: std.mem.Allocator, prog: co.Program, name: []const u8, args: [][:0]u8) !void {
    const f = prog.find(name) orelse {
        std.debug.print("no such function: {s}\n", .{name});
        return;
    };
    if (f.poisoned) {
        std.debug.print("{s} is UNUSABLE: part of its body did not compile\n", .{name});
        std.debug.print("    running it would give a wrong answer, so it is refused\n", .{});
        return;
    }
    const regs = try alloc.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    const frames = try alloc.alloc(vm.Frame, 4096);
    vm.global_names = prog.global_names;
    var m = vm.VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = vmheap, .argv = g_sysargv, .names = prog.names, .globals = alloc.alloc(vm.Value, prog.nglobals + 1) catch unreachable, .globals_set = blk: {
        const g = alloc.alloc(bool, prog.nglobals + 1) catch unreachable;
        @memset(g, false);
        break :blk g;
    }, .handlers = alloc.alloc(vm.Handler, 256) catch unreachable, .fn_entry = prog.fn_entry, .fn_frame = prog.fn_frame };
    @memset(m.globals, vm.Value.nil());

    // The file's own top-level code runs FIRST, exactly as Ring runs it,
    // because that is what assigns the program's globals. Without this,
    // a function reading one gets nil.
    if (prog.find(co.MAIN)) |mf| {
        if (!mf.poisoned) _ = m.run(mf.tramp);
    }

    for (args, 0..) |a, i| {
        const v = std.fmt.parseInt(i64, a, 10) catch {
            std.debug.print("argument {d} is not an integer: {s}\n", .{ i, a });
            return;
        };
        m.setReg(@intCast(i), vm.Value.int(v));
    }
    const r = m.run(f.tramp);
    switch (r.tag) {
        .int => std.debug.print("CHECK {s} {d}\n", .{ name, r.p.i }),
        // A non-whole number printed as `<nil>` -- there was no .num case
        // at all. `return 0.5` and `sqrt(2)` both came back nil, so every
        // function answering with a fraction was untestable, and the
        // builtin batch's first failure turned out to be this and not the
        // builtins. Printed Ring's way: whole floats lose the decimals.
        .num => {
            var buf: [40]u8 = undefined;
            std.debug.print("CHECK {s} {s}\n", .{ name, vm.VM.numText(r, &buf) });
        },
        .vec => std.debug.print("CHECK {s} <list of {d}>\n", .{ name, r.p.v.len }),
        // The VALUE, not its length. Printing `<string of 6>` made every
        // string result unfalsifiable: `raised` and `guarded` and any wrong
        // answer of the same length all read as agreement, and the A/B gate
        // silently covered nothing that returns text.
        .str => std.debug.print("CHECK {s} {s}\n", .{ name, r.p.s.ptr[0..r.p.s.len] }),
        else => std.debug.print("CHECK {s} <nil>\n", .{name}),
    }
}

/// `rnxc time <file> <Func> <int arg> [reps]` -- minimum over repetitions,
/// for comparing two spellings of the same algorithm against each other.
fn timeOne(alloc: std.mem.Allocator, prog: co.Program, name: []const u8, arg: i64, reps: usize) !void {
    const f = prog.find(name) orelse {
        std.debug.print("no such function: {s}\n", .{name});
        return;
    };
    if (f.poisoned) {
        std.debug.print("{s} is UNUSABLE: part of its body did not compile\n", .{name});
        return;
    }
    const regs = try alloc.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    const frames = try alloc.alloc(vm.Frame, 4096);
    var timer = try std.time.Timer.start();
    var best: u64 = std.math.maxInt(u64);
    var chk: i64 = 0;
    for (0..reps) |_| {
        vm.global_names = prog.global_names;
        var m = vm.VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = vmheap, .argv = g_sysargv, .names = prog.names, .globals = alloc.alloc(vm.Value, prog.nglobals + 1) catch unreachable, .globals_set = blk: {
            const g = alloc.alloc(bool, prog.nglobals + 1) catch unreachable;
            @memset(g, false);
            break :blk g;
        }, .handlers = alloc.alloc(vm.Handler, 256) catch unreachable, .fn_entry = prog.fn_entry, .fn_frame = prog.fn_frame };
        // every global starts nil, as on the other three run paths: ggetw
        // tests the value's tag before it reads the set-bit
        @memset(m.globals, vm.Value.nil());
        m.setReg(0, vm.Value.int(arg));
        timer.reset();
        const r = m.run(f.tramp);
        const t = timer.read();
        if (t < best) best = t;
        chk = r.p.i;
    }
    const h: u64 = (best + 5_000) / 10_000;
    std.debug.print("CHECK {s} {d}\nTIME  {s} {d}.{d:0>2}\n", .{ name, chk, name, h / 100, h % 100 });
}

/// `rnxc census <file.ring>` -- how much of a real module compiles, and
/// exactly what the rest needs. This is the measurement Stage 2 exists for:
/// the friction is the list, not a feeling.
fn printCensus(cs: co.Census, w: *std.Io.Writer, alloc: std.mem.Allocator) !void {
    const total = cs.stmts_ok + cs.stmts_bad;
    try w.print("classes {d}   methods+functions {d}\n", .{ cs.classes, cs.methods });
    if (total > 0) {
        try w.print("statements {d}: {d} compiled ({d}%), {d} refused\n", .{
            total, cs.stmts_ok, cs.stmts_ok * 100 / total, cs.stmts_bad,
        });
    }
    // Printed ALWAYS, zero included: a count that appears only when it is
    // non-zero cannot be told apart from one that stopped being reported.
    // This is the number that was silently discarded until 2026-09-23.
    try w.print("functions whose codegen failed outside a statement: {d}\n", .{cs.emit_failed});
    // the register window (shareFunction): printed always, as above
    try w.print("functions whose locals share registers: {d} ({d} registers saved)\n", .{ cs.shared_funcs, cs.shared_saved });
    // `new K` of a class nobody defines compiles to Ring's run-time R11
    // (2026-09-27), and is counted here so a typo (`stzEnity`) stays
    // visible without a refusal. Printed always, for the reason above.
    try w.print("`new` of a class the unit does not define: {d} site(s), compiled to R11 at run time (--all lists them)\n", .{cs.absent_classes.len});
    if (cs.refusals.len == 0) {
        // the natives line lives below the refusal tables; with none to
        // print it would vanish, and a count that vanishes reads as zero
        if (cs.native_sites > 0)
            try w.print("NATIVE calls: {d} sites, {d} distinct names, awaiting a LoadLib\n", .{ cs.native_sites, cs.native_names });
        return;
    }

    // group by node kind, most frequent first
    var kinds: [64][]const u8 = undefined;
    var counts: [64]u32 = undefined;
    var nk: usize = 0;
    for (cs.refusals) |r| {
        var seen = false;
        for (kinds[0..nk], 0..) |kk, i| {
            if (std.mem.eql(u8, kk, r.kind)) {
                counts[i] += 1;
                seen = true;
            }
        }
        if (!seen and nk < kinds.len) {
            kinds[nk] = r.kind;
            counts[nk] = 1;
            nk += 1;
        }
    }
    // Which NAMES are refused, and of what shape. `$x` is Ring's explicit
    // global, `@x` an attribute Softanza declares by convention, `_x_` its
    // method-local convention -- and a BARE name is the one that needs a
    // scope decision rather than a feature.
    {
        var n_dollar: u32 = 0;
        var n_at: u32 = 0;
        var n_under: u32 = 0;
        var n_bare: u32 = 0;
        const IdRow = struct { name: []const u8, n: u32 };
        var idrows = std.ArrayListUnmanaged(IdRow){};
        defer idrows.deinit(alloc);
        for (cs.refusals) |r| {
            if (!std.mem.eql(u8, r.kind, "identifier")) continue;
            const nm = std.mem.trim(u8, r.text, " \t\r\n");
            if (nm.len == 0 or nm.len > 48) continue;
            if (nm[0] == '$') {
                n_dollar += 1;
            } else if (nm[0] == '@') {
                n_at += 1;
            } else if (nm[0] == '_') {
                n_under += 1;
            } else {
                n_bare += 1;
            }
            var idhit = false;
            for (idrows.items) |*row| {
                if (std.ascii.eqlIgnoreCase(row.name, nm)) {
                    row.n += 1;
                    idhit = true;
                    break;
                }
            }
            if (!idhit) try idrows.append(alloc, .{ .name = nm, .n = 1 });
        }
        if (idrows.items.len > 0) {
            try w.print("\nrefused identifiers ({d} distinct names):\n", .{idrows.items.len});
            try w.print("  {d:>5} $global   {d:>5} @attribute   {d:>5} _local_   {d:>5} bare\n", .{ n_dollar, n_at, n_under, n_bare });
            var idshown: usize = 0;
            while (idshown < 12) : (idshown += 1) {
                var idbest: usize = 0;
                var idbestc: u32 = 0;
                for (idrows.items, 0..) |row, k| {
                    if (row.n > idbestc) {
                        idbestc = row.n;
                        idbest = k;
                    }
                }
                if (idbestc == 0) break;
                try w.print("  {d:>5}x {s}\n", .{ idbestc, idrows.items[idbest].name });
                idrows.items[idbest].n = 0;
            }
        }
    }

    // Which CALLS are refused, by callee name. 6,399 "call_expression"
    // says nothing about what to build next; this says it.
    {
        const Row = struct { name: []const u8, n: u32 };
        var rows = std.ArrayListUnmanaged(Row){};
        defer rows.deinit(alloc);
        for (cs.refusals) |r| {
            if (!std.mem.eql(u8, r.kind, "call_expression")) continue;
            // the callee is the text up to the first '('
            var nm = r.text;
            const lp = std.mem.indexOfScalar(u8, nm, '(') orelse continue;
            nm = std.mem.trim(u8, nm[0..lp], " \t\r\n");
            if (nm.len == 0 or nm.len > 48) continue;
            var hit = false;
            for (rows.items) |*row| {
                if (std.ascii.eqlIgnoreCase(row.name, nm)) {
                    row.n += 1;
                    hit = true;
                    break;
                }
            }
            if (!hit) try rows.append(alloc, .{ .name = nm, .n = 1 });
        }
        if (rows.items.len > 0) {
            try w.print("\nrefused calls, by callee ({d} distinct names):\n", .{rows.items.len});
            var shown: usize = 0;
            var covered: u32 = 0;
            while (shown < 20) : (shown += 1) {
                var best: usize = 0;
                var bestc: u32 = 0;
                for (rows.items, 0..) |row, i| {
                    if (row.n > bestc) {
                        bestc = row.n;
                        best = i;
                    }
                }
                if (bestc == 0) break;
                try w.print("  {d:>5}x {s}\n", .{ bestc, rows.items[best].name });
                covered += bestc;
                rows.items[best].n = 0;
            }
            try w.print("  (top {d} names cover {d} of the refused calls)\n", .{ shown, covered });
        }
    }

    if (cs.native_sites > 0) {
        try w.print("  of which {d} are NATIVE calls, {d} distinct names, awaiting a LoadLib\n", .{ cs.native_sites, cs.native_names });
        try w.print("  (counted apart: emitting a call to an undefined name is not a compiled statement)\n", .{});
    }

    try w.print("\nwhat it still needs:\n", .{});
    var printed: usize = 0;
    while (printed < nk) : (printed += 1) {
        var best: usize = 0;
        var bestc: u32 = 0;
        for (counts[0..nk], 0..) |cn, i| {
            if (cn > bestc) {
                bestc = cn;
                best = i;
            }
        }
        if (bestc == 0) break;
        // an example of this kind, for the reader
        var ex: []const u8 = "";
        var exrow: u32 = 0;
        var exfn: []const u8 = "";
        for (cs.refusals) |r| {
            if (std.mem.eql(u8, r.kind, kinds[best])) {
                ex = r.text;
                exrow = r.row;
                exfn = r.func;
                break;
            }
        }
        try w.print("  {d:>3}x {s:<24} e.g. {s}() line {d}: {s}\n", .{ bestc, kinds[best], exfn, exrow, ex });
        counts[best] = 0;
    }
}

fn ms(best_ns: u64) struct { w: u64, f: u64 } {
    const h: u64 = (best_ns + 5_000) / 10_000;
    return .{ .w = h / 100, .f = h % 100 };
}

/// Same harness as the hand-written suite: minimum over repetitions, work
/// timed, setup outside. The point is to compare COMPILED code against
/// bytecode written by hand for the same algorithms.
fn benchKernels(alloc: std.mem.Allocator, prog: co.Program) !void {
    const REPS = 3;
    var timer = try std.time.Timer.start();
    const regs = try alloc.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    const frames = try alloc.alloc(vm.Frame, 4096);

    const H = struct {
        fn run1(p: co.Program, rg: []vm.Value, fr: []vm.Frame, al: std.mem.Allocator, name: []const u8, args: []const vm.Value) ?vm.Value {
            const f = p.find(name) orelse return null;
            var m = vm.VM{ .code = p.code, .regs = rg, .frames = fr, .alloc = al };
            for (args, 0..) |a, i| m.setReg(@intCast(i), a);
            return m.run(f.tramp);
        }
    };

    const Row = struct { label: []const u8, fname: []const u8, arg: i64 };
    const rows = [_]Row{
        .{ .label = "sieve", .fname = "Sieve", .arg = 300000 },
        .{ .label = "matmul", .fname = "MatMul", .arg = 80 },
        .{ .label = "fib", .fname = "Fib", .arg = 25 },
    };
    for (rows) |row| {
        var best: u64 = std.math.maxInt(u64);
        var chk: i64 = 0;
        for (0..REPS) |_| {
            timer.reset();
            const v = H.run1(prog, regs, frames, alloc, row.fname, &.{vm.Value.int(row.arg)}) orelse return;
            const t = timer.read();
            if (t < best) best = t;
            chk = v.p.i;
        }
        const m = ms(best);
        std.debug.print("CHECK {s} {d}\nTIME  {s} {d}.{d:0>2}\n", .{ row.label, chk, row.label, m.w, m.f });
    }

    // mergesort and binsearch share a data set, built outside the timing.
    const data = H.run1(prog, regs, frames, alloc, "BuildData", &.{vm.Value.int(8000)}) orelse return;
    var sorted: vm.Value = undefined;
    {
        var best: u64 = std.math.maxInt(u64);
        for (0..REPS) |_| {
            timer.reset();
            sorted = H.run1(prog, regs, frames, alloc, "MergeSort", &.{data}) orelse return;
            const t = timer.read();
            if (t < best) best = t;
        }
        const chk = H.run1(prog, regs, frames, alloc, "Sum32", &.{sorted}) orelse return;
        const m = ms(best);
        std.debug.print("CHECK mergesort {d}\nTIME  mergesort {d}.{d:0>2}\n", .{ chk.p.i, m.w, m.f });
    }
    {
        var best: u64 = std.math.maxInt(u64);
        var chk: i64 = 0;
        for (0..REPS) |_| {
            timer.reset();
            const v = H.run1(prog, regs, frames, alloc, "BinSearchAll", &.{ sorted, vm.Value.int(6000) }) orelse return;
            const t = timer.read();
            if (t < best) best = t;
            chk = v.p.i;
        }
        const m = ms(best);
        std.debug.print("CHECK binsearch {d}\nTIME  binsearch {d}.{d:0>2}\n", .{ chk, m.w, m.f });
    }
    std.debug.print("SUITE OK\n", .{});
}

/// The six-kernel driver: calls each and prints the CHECK lines Ring itself
/// prints for the same file. Hardcoded because this subset has no printing
/// and no main program yet; `call` above is the general form.
fn runKernels(alloc: std.mem.Allocator, prog: co.Program) !void {
    const regs = try alloc.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    const frames = try alloc.alloc(vm.Frame, 4096);

    const Call = struct {
        fn one(p: co.Program, regs_: []vm.Value, frames_: []vm.Frame, alloc_: std.mem.Allocator, name: []const u8, args: []const vm.Value) ?vm.Value {
            const f = p.find(name) orelse {
                std.debug.print("MISSING {s}\n", .{name});
                return null;
            };
            var m = vm.VM{ .code = p.code, .regs = regs_, .frames = frames_, .alloc = alloc_ };
            for (args, 0..) |a, i| m.setReg(@intCast(i), a);
            // Enter through the trampoline: `ret` pops a frame, so one has
            // to be pushed first. Calling f.entry directly underflows the
            // frame stack and the process dies with no message at all.
            return m.run(f.tramp);
        }
    };

    // sieve / matmul / fib take and return integers.
    if (Call.one(prog, regs, frames, alloc, "Sieve", &.{vm.Value.int(300000)})) |v|
        std.debug.print("CHECK sieve {d}\n", .{v.p.i});
    if (Call.one(prog, regs, frames, alloc, "MatMul", &.{vm.Value.int(80)})) |v|
        std.debug.print("CHECK matmul {d}\n", .{v.p.i});
    if (Call.one(prog, regs, frames, alloc, "Fib", &.{vm.Value.int(25)})) |v|
        std.debug.print("CHECK fib {d}\n", .{v.p.i});

    // mergesort and binsearch share a data set, as the Ring driver does.
    const data = Call.one(prog, regs, frames, alloc, "BuildData", &.{vm.Value.int(8000)}) orelse return;
    const sorted = Call.one(prog, regs, frames, alloc, "MergeSort", &.{data}) orelse return;
    if (Call.one(prog, regs, frames, alloc, "Sum32", &.{sorted})) |v|
        std.debug.print("CHECK mergesort {d}\n", .{v.p.i});
    if (Call.one(prog, regs, frames, alloc, "BinSearchAll", &.{ sorted, vm.Value.int(6000) })) |v|
        std.debug.print("CHECK binsearch {d}\n", .{v.p.i});

    std.debug.print("SUITE OK\n", .{});
}

/// What `sysargv` answers inside the program: [rnxc, script, args...] --
/// the shape Ring 1.27 gives it ([ring.exe, script, args...]), so Softanza's
/// _RingExecutable() spawns its child on THIS binary.
var g_sysargv: []const []const u8 = &.{};

/// rnxc's own STATUS during a run -- `files N functions+methods N`, `running
/// the top level...`, `TOP LEVEL RAN TO COMPLETION`, the prefix not applying --
/// is printed only with `RNXC_VERBOSE` set (and not "0"). Ring prints nothing
/// of its own around a program, and on stderr these lines still reach a
/// terminal, interleaved with the program's output: every person who tried the
/// v2.0.0 package saw three of them on every run (2026-10-16). The `note:`
/// lines are not status -- they say an answer is not certified, or a loaded
/// file could not be read -- and are always printed. The harnesses that read
/// status (bench/image.py, onto.py, child_start.py) set the variable.
var g_verbose = false;

fn status(comptime text: []const u8, args: anytype) void {
    if (g_verbose) std.debug.print(text, args);
}

/// Every name `rnxc` accepts in argv[1]. Listed so a bare `rnxc file.ring`
/// can be told apart from a subcommand without guessing -- and a file
/// genuinely named `census.ring` still reaches the subcommand, which is
/// the one ambiguity, resolved the way it was before this existed.
fn isSubcommand(a: []const u8) bool {
    for ([_][]const u8{
        "exec",    "dis",   "dump",   "census", "check",
        "call",    "time",  "poison", "usable", "migrate",
        "shadows", "attrs", "bench",  "run",    "prefix",
        "fmt",     "graph", "resident",
    }) |c| {
        if (std.mem.eql(u8, a, c)) return true;
    }
    return false;
}

/// Run a program whose compilation happened on some earlier run.
///
/// This is the tail of `exec` with the compiler removed, and the two have to
/// stay the same shape: every VM table the freeze sets is set here from the
/// image, and the same three status lines are printed (under RNXC_VERBOSE,
/// see `status`), because a warm run that says something different from a
/// cold run is a warm run nobody can check. `bench/image.py` runs both and
/// requires the bytes to match.
fn runImage(p: image.Parts, root_as_typed: []const u8) !void {
    const H = vmheap;
    vm.dispatch = p.dispatch;
    vm.method_tab = p.method_tab;
    vm.class_slots = p.class_slots;
    vm.attr_from = p.attr_from;
    vm.attr_ent = p.attr_ent;
    vm.global_names = p.global_names;
    vm.class_konst = p.class_konst;
    vm.class_parent = p.class_parent;
    vm.fn_owner = p.fn_owner;
    vm.acc_get = p.acc_get;
    vm.acc_set = p.acc_set;
    vm.class_attrs_fn = p.class_attrs_fn;
    vm.konst = p.konst;
    vm.n_names = p.n_names;
    vm.fn_masks = p.fn_masks;

    // Ring names the root file in an error report exactly as it was TYPED,
    // and the image was written from whatever spelling that run used. Every
    // other entry is an absolute path already.
    const file_names = try H.alloc([]const u8, p.file_names.len);
    @memcpy(file_names, p.file_names);
    if (file_names.len > 0) file_names[0] = root_as_typed;

    status("files {d}   functions+methods {d}   (compiled image)\n", .{ p.file_names.len, p.fn_names.len });
    if (p.poisoned_own) {
        std.debug.print("note: a statement in the top level did not compile. It runs to\n", .{});
        std.debug.print("      that statement and stops there, as Ring stops at a line it\n", .{});
        std.debug.print("      cannot execute. Nothing past it is certified correct.\n", .{});
    } else if (p.poisoned) {
        std.debug.print("note: the top level's own body compiled, but it calls functions\n", .{});
        std.debug.print("      that did not. Running it measures how far it gets, and a\n", .{});
        std.debug.print("      result it produces is NOT certified correct.\n", .{});
    }

    const regs = try H.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    const globals = try H.alloc(vm.Value, p.nglobals + 1);
    @memset(globals, vm.Value.nil());
    const gset = try H.alloc(bool, p.nglobals + 1);
    @memset(gset, false);

    var m = vm.VM{
        .code = p.code,
        .regs = regs,
        .frames = try H.alloc(vm.Frame, 4096),
        .alloc = H,
        .argv = g_sysargv,
        .names = p.names,
        .globals = globals,
        .globals_set = gset,
        .handlers = try H.alloc(vm.Handler, 256),
        .fn_entry = p.fn_entry,
        .fn_frame = p.fn_frame,
        .fn_local_from = p.fn_local_from,
        .local_names = p.local_names,
        .local_regs = p.local_regs,
        .local_boxed = p.local_boxed,
        .eval_hook = &evalHook,
        .rows = p.rows,
        .files = p.files,
        .fn_of = p.fn_of,
        .fn_names = p.fn_names,
        .fn_method = p.fn_method,
        .file_names = file_names,
        .main_fn = p.main_fn,
    };
    status("running the top level...\n", .{});
    vm.armWatchdog();
    _ = m.run(p.main_tramp);
    vm.outFlush();
    status("TOP LEVEL RAN TO COMPLETION\n", .{});
}

/// EVAL (F-72, C-9 revised): the string compiled at run time, in the
/// frame of the function that called eval, by ONE persistent compiler
/// bound to the VM's tables (see compile.EvalCtx). The code is appended to
/// the VM's growing code, run through `runFrom` with the handler floor at
/// the eval site, and the eval's registers, code and constants are then
/// released -- stack discipline, so a nested eval sits above its outer.
const EvalFrame = struct { fid: u32, base: u32, high: u8 };
/// A string already compiled for a caller: where its code sits in the VM's
/// code, and how many registers it uses. RESIDENT -- never truncated.
const EvalCached = struct { entry: u32, high: u8 };
/// THE CACHE, keyed on the caller's function id and the string's bytes:
/// the compiled code depends on nothing else (the caller's locals table,
/// its frame size and class are fixed per function; names and classes are
/// frozen; a string can define nothing). Measured before it existed: 53 us
/// an eval here against Ring's 14, every call re-parsing and re-compiling
/// -- and a loop that evals per item is an estate pattern. Bounded, so a
/// program building a new string each time cannot grow it without limit.
const EVAL_CACHE_MAX_ENTRIES = 8192;
const EVAL_CACHE_MAX_INSTRS = 1 << 20;
const EvalState = struct {
    c: co.Compiler,
    scratch: std.heap.ArenaAllocator,
    classes: std.StringHashMapUnmanaged(u16) = .{},
    stack: [32]EvalFrame = undefined,
    depth: usize = 0,
    ready: bool = false,
    inited: bool = false,
    trace: bool = false,
    cache: std.StringHashMapUnmanaged(EvalCached) = .{},
    cache_instrs: usize = 0,
    no_cache: bool = false,
};
var g_eval: EvalState = .{ .c = undefined, .scratch = undefined };

fn evalInit(m: *vm.VM) !void {
    const H = vmheap;
    g_eval.c = co.Compiler{ .alloc = H, .lenient = false };
    g_eval.scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    g_eval.c.scratch_arena = &g_eval.scratch;
    g_eval.c.scratch = g_eval.scratch.allocator();
    // the VM's names, in the VM's order, so every index the eval'd code
    // carries is the VM's; then frozen
    for (m.names) |nm| _ = try g_eval.c.nameIndexPub(nm);
    g_eval.c.names_frozen = true;
    for (vm.global_names) |g| try g_eval.c.globals.append(H, g);
    // classes by lower-cased name, from the class constant table
    for (vm.class_konst, 0..) |ki, cid| {
        if (ki >= vm.konst.len or vm.konst[ki].tag != .str) continue;
        const nm = vm.konst[ki].p.s.ptr[0..vm.konst[ki].p.s.len];
        const key = try H.alloc(u8, nm.len);
        for (nm, 0..) |ch, i| key[i] = std.ascii.toLower(ch);
        if (!g_eval.classes.contains(key)) try g_eval.classes.put(H, key, @intCast(cid));
    }
    g_eval.ready = true;
}

fn evalHook(m: *vm.VM, src: []const u8, caller_fid: u32, base: u32, fsp: u32, hsp: u32) vm.Value {
    if (!g_eval.inited) {
        g_eval.inited = true;
        g_eval.trace = std.process.hasEnvVarConstant("RNXC_TRACE_EVAL");
        // RNXC_EVAL_NOCACHE=1 compiles every eval afresh: the A side of the
        // cache's own measurement, and a way to rule it out of a hunt
        g_eval.no_cache = std.process.hasEnvVarConstant("RNXC_EVAL_NOCACHE");
        evalInit(m) catch return m.evalEscapePub("Error (E1) : eval could not initialise");
    }
    if (!g_eval.ready) return m.evalEscapePub("Error (E1) : eval could not initialise");
    if (g_eval.depth >= g_eval.stack.len) return m.evalEscapePub("Error (R4) : Stack Overflow");

    // WHOSE FRAME. An eval inside eval'd code is at the same base as the
    // eval that made it, and sits above its registers.
    var fid = caller_fid;
    var frame: u8 = 0;
    if (fid == vm.EVAL_NESTED) {
        if (g_eval.depth == 0) return m.evalEscapePub("Error (E1) : eval: nested eval with no frame");
        const outer = g_eval.stack[g_eval.depth - 1];
        fid = outer.fid;
        frame = outer.high +| 1;
    }
    if (fid + 1 >= m.fn_local_from.len) return m.evalEscapePub("Error (E1) : eval: no frame table for the caller");
    if (frame == 0) frame = m.fn_frame[fid];

    // the scratch arena is reset HERE and nowhere else on this path: the
    // cache key, the caller's locals, compileEval's snippet and constant
    // headers all live in it, and everything of the previous eval's is
    // already copied out (its code into the VM, its konst into strings)
    _ = g_eval.scratch.reset(.retain_capacity);

    // THE RECEIVER'S CLASS, not the class that DEFINES the method holding
    // the eval (F-92). Ring resolves a bare call and a bare name in eval on
    // the object: StzObjectQ().IfQ('NumberOfItems() > 2') called on a stzList
    // answers through stzList's method. The static owner is the fallback
    // when r0 holds no object.
    const static_owner: ?u16 = if (fid < vm.fn_owner.len and vm.fn_owner[fid] != 0xFFFF) vm.fn_owner[fid] else null;
    const owner: ?u16 = blk: {
        if (static_owner == null) break :blk null;
        const r0 = m.regs[base];
        if (r0.tag == .obj) break :blk r0.p.o.class;
        break :blk static_owner;
    };

    // THE CACHE. Only at depth 0 and for a direct caller: a nested eval's
    // frame depends on the outer eval's registers, and code made resident
    // while an outer eval's temporary region is live would be cut by that
    // eval's truncation. Keyed on the RECEIVER'S CLASS too, since what the
    // string compiles to depends on it: the same IfQ on another subclass
    // must not reuse code compiled against this one's methods.
    const cacheable = !g_eval.no_cache and caller_fid != vm.EVAL_NESTED and g_eval.depth == 0;
    var key: []u8 = &.{};
    if (cacheable) {
        key = g_eval.c.scratch.alloc(u8, 6 + src.len) catch return m.evalEscapePub("Error (E1) : eval: out of memory");
        std.mem.writeInt(u32, key[0..4], fid, .little);
        std.mem.writeInt(u16, key[4..6], owner orelse 0xFFFF, .little);
        @memcpy(key[6..], src);
        if (g_eval.cache.get(key)) |hit| {
            if (@as(usize, base) + hit.high + 16 >= m.regs.len) return m.evalEscapePub("Error (E1) : eval: register overflow");
            return runEval(m, fid, base, fsp, hsp, frame, hit.entry, hit.high, null);
        }
    }

    // the caller's locals, by register
    const lo = m.fn_local_from[fid];
    const hi = m.fn_local_from[fid + 1];
    const specs = g_eval.c.scratch.alloc(co.LocalSpec, hi - lo) catch return m.evalEscapePub("Error (E1) : eval: out of memory");
    for (lo..hi, 0..) |i, k| specs[k] = .{ .name = m.local_names[i], .reg = m.local_regs[i], .boxed = m.local_boxed[i] };
    // RNXC_TRACE_EVAL=1: what the string is bound to -- the frame, its
    // locals by register, the owner class -- and the string itself. Off
    // unless asked for; it named the first defect of this path in one line.
    if (g_eval.trace) {
        std.debug.print("eval: fid={d} {s} frame={d} base={d} owner={?d} src=`{s}`\n  locals:", .{ fid, if (fid < m.fn_names.len) m.fn_names[fid] else "?", frame, base, owner, src });
        for (specs) |s| std.debug.print(" {s}=r{d}{s}", .{ s.name, s.reg, if (s.boxed) "*" else "" });
        std.debug.print("\n", .{});
    }
    var ctx = co.EvalCtx{
        .vm_ = m,
        .frame = frame,
        .owner = owner,
        .is_main = fid == m.main_fn,
        .konst_base = @intCast(vm.konst.len),
        .classes = &g_eval.classes,
    };
    const out = co.compileEval(&g_eval.c, src, &ctx, specs) catch {
        // A STRING THAT DOES NOT PARSE (F-108): Ring prints its compile report
        // and raises R42 from inside eval(), catchable
        if (std.mem.eql(u8, g_eval.c.fail_kind, "eval-syntax")) {
            g_eval.c.fail_kind = "";
            vm.outPrint("{s}", .{g_eval.c.eval_report.items});
            m.eval_c_err = true;
            return m.evalEscapePub("Error (R42) : Error in eval() function");
        }
        var buf: [512]u8 = undefined;
        const kind = if (g_eval.c.fail_kind.len > 0) g_eval.c.fail_kind else "eval: could not compile";
        const msg = std.fmt.bufPrint(&buf, "Error (E1) : {s} `{s}`", .{ kind, g_eval.c.fail_text }) catch "Error (E1) : eval: could not compile";
        g_eval.c.fail_kind = "";
        g_eval.c.fail_text = "";
        return m.evalEscapePub(msg);
    };
    if (@as(usize, base) + out.high + 16 >= m.regs.len) return m.evalEscapePub("Error (E1) : eval: register overflow");

    // constants: the bytes copied out of the snippet into VM strings
    const kbase = vm.konst.len;
    for (out.konst) |kv| {
        if (kv.tag == .str) {
            _ = m.appendKonst(vm.Value.str(m.newStrPub(kv.p.s.ptr[0..kv.p.s.len])));
        } else _ = m.appendKonst(kv);
    }
    const code0 = m.code.len;
    co.relocate(out.code, @intCast(code0));
    const entry = m.appendCode(out.code);

    // RESIDENT, when the cache has room: the code and its constants stay
    // where they were appended, and the next call with this string from
    // this function runs them without parsing or compiling anything
    if (cacheable and g_eval.cache.count() < EVAL_CACHE_MAX_ENTRIES and
        g_eval.cache_instrs + out.code.len <= EVAL_CACHE_MAX_INSTRS)
    {
        if (vmheap.dupe(u8, key)) |k| {
            if (g_eval.cache.put(vmheap, k, .{ .entry = entry, .high = out.high })) |_| {
                g_eval.cache_instrs += out.code.len;
                return runEval(m, fid, base, fsp, hsp, frame, entry, out.high, null);
            } else |_| vmheap.free(k);
        } else |_| {}
    }
    return runEval(m, fid, base, fsp, hsp, frame, entry, out.high, .{ .code = code0, .konst = kbase });
}

/// Run compiled eval code in the caller's frame, then sweep its registers;
/// `release` names the code and constants to truncate back to, null for a
/// resident (cached) entry.
fn runEval(m: *vm.VM, fid: u32, base: u32, fsp: u32, hsp: u32, frame: u8, entry: u32, high: u8, release: ?struct { code: usize, konst: usize }) vm.Value {
    g_eval.stack[g_eval.depth] = .{ .fid = fid, .base = base, .high = high };
    g_eval.depth += 1;
    const saved_floor = m.hsp_floor;
    m.hsp_floor = hsp;
    // THE CALLER'S FRAME GROWS FOR THE EVAL'S LIFE. `.opcall` -- an
    // operator, a getter, a setter -- puts its window just past
    // `frames[fsp-1].size`, which is exactly where the eval's temporaries
    // start, so a getter called inside an eval string wrote over them.
    // Restored before the caller runs again, so its own sweep is unchanged.
    var saved_size: u8 = 0;
    if (fsp > 0) {
        saved_size = m.frames[fsp - 1].size;
        m.frames[fsp - 1].size = @intCast(@min(@as(u32, 255), @max(@as(u32, saved_size), @as(u32, high) + 1)));
    }
    const v = m.runFrom(entry, base, fsp, hsp);
    if (fsp > 0) m.frames[fsp - 1].size = saved_size;
    m.hsp_floor = saved_floor;
    g_eval.depth -= 1;

    // the value survives the sweep held once; the eval opcode drops the hold
    if (!m.eval_escaped) vm.VM.holdValue(v);
    m.clearRegs(base + frame, base + high);
    if (release) |r| {
        m.truncateCode(r.code);
        m.truncateKonst(r.konst);
    }
    if (m.eval_escaped) return vm.Value.nil();
    return v;
}

/// Copy a list of strings, and the bytes each one points at, out of the
/// compiler's arena. Names and file names are slices INTO THE SOURCE TEXT,
/// so copying the outer array alone would leave every element dangling.
fn dupStrings(h: std.mem.Allocator, in: []const []const u8) ![]const []const u8 {
    const out = try h.alloc([]const u8, in.len);
    for (in, 0..) |s, i| out[i] = try h.dupe(u8, s);
    return out;
}

/// The constant table. A string constant's bytes live in the source text and
/// its header in the arena, so both are copied. `cap` stays 0: a constant is
/// never grown in place, which is what keeps the self-append path from ever
/// writing through one.
fn dupKonst(h: std.mem.Allocator, in: []const vm.Value) ![]vm.Value {
    const out = try h.alloc(vm.Value, in.len);
    for (in, 0..) |v, i| {
        if (v.tag != .str) {
            out[i] = v;
            continue;
        }
        // ALWAYS ALLOCATE AT LEAST ONE BYTE. A zero-length allocation hands
        // back Zig's alignment SENTINEL -- 0xffffffffffffffff -- not an
        // address, and `""` is a constant the estate uses everywhere. Before
        // the arena was freed these pointed into the source text and were
        // always real; copying them out turned every empty constant into a
        // pointer nothing may dereference. Found 2026-09-14 by tracing a
        // `ret` that was handing back `str len=0 ptr=0xffffffffffffffff`.
        const n = v.p.s.len;
        const bytes = try h.alloc(u8, if (n == 0) 1 else n);
        if (n > 0) @memcpy(bytes[0..n], v.p.s.ptr[0..n]) else bytes[0] = 0;
        const sp = try h.create(vm.Str);
        // PINNED, not merely expected to balance -- see vm.konst_rc. A
        // constant that reached zero would be freed out from under the code
        // stream, and this had no way to stop that happening.
        sp.* = .{ .ptr = bytes.ptr, .len = @intCast(n), .rc = vm.konst_rc, .cap = 0 };
        out[i] = vm.Value.str(sp);
    }
    return out;
}

// ------------------------------------------------------------ the resident VM

/// THE RESIDENT VM: `rnxc resident <file.ring>...`. ONE program, fed files
/// while it runs -- RingServ's shape (one resident state, its library files
/// run into it one by one, every app arriving as more source), and Haro's
/// first rung past the bridge (haro/FROM-RINGPP.md).
///
/// Each file is ADMITTED or REFUSED whole (co.compileAdmit says why). The
/// program between admissions is the compiler's state, KEPT ALIVE (rung 5:
/// it was restored from bytes and saved again around every admission, two
/// thirds of a small one's cost at Softanza's size). An admission moves it
/// into a compiler of its own (co.takeProgram), compiles the file on top,
/// and is either rolled back to its marks (co.rollbackProgram) -- the
/// running VM never saw it -- or installed into the VM as a delta: code,
/// constants, names and globals appended, the per-function tables grown,
/// the class tables rebuilt only when a class changed, every value the
/// program holds left where it is. Then the file's top level runs, as Ring
/// runs a loaded file's. An error nothing catches there is reported as Ring
/// reports it, and the program carries on with the next file (VM.resident).
///
/// The live program's arena keeps what each admission's compile allocated
/// beside it, so it is COMPACTED -- saved to bytes and restored into a fresh
/// arena, the old path -- once it has doubled (plus 16 MB) since the last
/// time. A released admission's source and compile stay there until the
/// next compaction (rung 6). RNXC_RESIDENT_BLOB=1 compacts after every
/// admission, which IS the old path, so the two can be compared;
/// RNXC_RESIDENT_CHECK=1 saves the
/// program before each admission and, after a refusal, again, and stops if
/// the bytes differ.
const Resident = struct {
    /// the live program and the arena it lives in (rung 5)
    P: *co.Compiler = undefined,
    parena: *std.heap.ArenaAllocator = undefined,
    live: bool = false,
    /// every admitted file, as the program's own state records them
    stamps: std.ArrayListUnmanaged(image.Stamp) = .{},
    fnames: std.ArrayListUnmanaged([]const u8) = .{},
    compact_at: usize = compact_slack,
    compactions: usize = 0,
    prog_code: usize = 0,
    prog_konst: usize = 0,
    nfuncs: usize = 0,
    admitted: usize = 0,
    refused: usize = 0,
    stopped: usize = 0,
    /// codes admitted so far (`admitcode`), so each gets a path of its own
    codes: usize = 0,
    /// what an admission needs, kept here because a running program asks
    /// for one through `admitfile`/`admitcode` (admitHook), not the driver
    m: *vm.VM = undefined,
    parser: ts.Parser = undefined,
    exe: image.ExeStamp = undefined,
    /// the reason a refusal from inside the program raises with
    why: [640]u8 = undefined,
    /// each admitted file's normalised key, parallel to the program's
    /// stamps, so an admission does not open every held file again (rung 5)
    held_norm: std.ArrayListUnmanaged([]const u8) = .{},
    /// THE VM's TABLES (rung 5), grown by each admission rather than built
    /// again and copied whole: the VM's slices are views of these lists. A
    /// compile hands only what it added (co.Program's fn_base, code_base).
    vt: VmTables = .{},
    /// some function of the program has been replaced (rung 3), so the VM's
    /// name map is the installer's, which knows the replacements
    ever_replaced: bool = false,
    /// the running code's `r24` sites by name index (Compiler.r24_sites)
    r24: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)) = .{},
    /// RUNG 6: where the program stood before each admission that can still
    /// be released, the last on top -- a stack, since only the last can be
    /// (residentRelease). An admission that cannot be released empties it:
    /// nothing under it can be released before it is
    rel: std.ArrayListUnmanaged(ReleaseRec) = .{},
    /// why the last admission cannot be released, when the stack is empty
    unreleasable: []const u8 = "nothing has been admitted",
    /// what residentRelease formats its reasons into -- not `why`, which the
    /// hook then formats the error into, reading this
    rel_why: [640]u8 = undefined,
    released: usize = 0,
    /// D31: the app the admission under way is admitted into, and what it exports (admitHook sets both for the call)
    cur_app: ?[]const u8 = null,
    cur_exports: []const []const u8 = &.{},
    /// every export of every app, as the compiler checked them: the installer and the resident check apply them alike
    exports: std.ArrayListUnmanaged(co.AppExport) = .{},
    /// the apps admitted so far
    apps: usize = 0,
    /// RUNG 9: the admission compiling on a thread of its own (`admitstart`) until `admitfinish` installs it. One at a
    /// time -- the program has one compiler -- and while it compiles every other admission and release is refused, so
    /// nothing but that thread touches the program's compiler and its arena
    bg: ?*AdmitJob = null,
    /// THE COMPILING THREAD, started at the first `admitstart` and kept for the program's life: one per admission cost
    /// ~0.6 ms an admission on Windows (measured 2026-11-01: 300 small admissions 231 ms against 40 synchronously),
    /// most of it committing the new thread's stack. It waits for `bg_go`, compiles `bg`, and sets `bg_done`
    bg_started: bool = false,
    bg_go: std.Thread.ResetEvent = .{},
    /// set by that thread when its compile is over: `admitstate` reads and waits on it
    bg_done: std.Thread.ResetEvent = .{},
    /// THE TIDY-UP after a background admission's install, on that thread too: its parse trees released (146 ms at
    /// Softanza's size) and the program compacted when due (~90 ms) -- a pause for every request on the program's thread,
    /// measured 2026-11-01. While it runs nothing may touch the program's compiler: bgQuiet waits for it first
    bg_trees: std.ArrayListUnmanaged(ts.Tree) = .{},
    bg_compact: bool = false,
    bg_tidying: bool = false,
    /// what an admission refused while one compiles raises with (`why` is the compile's)
    busy_why: [640]u8 = undefined,
};

/// D31: VM.name_up for name `i` -- the unqualified name an APP's late name `app::x` falls back to, when that name came
/// first (the compiler interns it first: Compiler.appName's callers). From the names alone, so the installer's delta
/// and a whole build agree.
fn nameUpOf(c: *co.Compiler, names: []const []const u8, i: usize) u32 {
    const nm = names[i];
    if (std.mem.startsWith(u8, nm, "@@")) return vm.NO_FN;
    const k = std.mem.lastIndexOf(u8, nm, "::") orelse return vm.NO_FN;
    const suf = nm[k + 2 ..];
    var buf: [256]u8 = undefined;
    if (suf.len == 0 or suf.len > buf.len) return vm.NO_FN;
    const j = c.name_index.get(std.ascii.lowerString(&buf, suf)) orelse return vm.NO_FN;
    return if (j < i) j else vm.NO_FN;
}

/// D31: each export answers by its public name `app.Name` -- the function that runs under the internal name now (a
/// replacement followed) in `nfn`, or the class in `ncl`.
fn applyExports(rs: *const Resident, c: *co.Compiler, nfn: []u32, ncl: []u32) void {
    for (rs.exports.items) |e| {
        const t = co.exportTarget(c, e.internal, e.is_class) orelse continue;
        if (e.is_class) {
            if (e.pub_idx < ncl.len) ncl[e.pub_idx] = t;
        } else if (e.pub_idx < nfn.len) nfn[e.pub_idx] = t;
    }
}

/// THE RESIDENT VM, RUNG 6: what releasing an admission needs -- where the
/// program stood before it, the compiler's lists and the VM's tables, by
/// their lengths (everything an admission adds is appended past them), and
/// the few things it set on what was there: the `called` flags (the
/// compiler's undo log) and the native-call list it refilled. Kept only for
/// an admission that defined no class and no lambda and replaced nothing,
/// since an object of a released class or a closure over a released function
/// could outlive it and reach code that is gone.
const ReleaseRec = struct {
    name: []const u8,
    coded: bool,
    code: usize,
    fixups: usize,
    names: usize,
    globals: usize,
    konst: usize,
    funcs: usize,
    classes: usize,
    natives: []u16,
    counters: [5]usize,
    prefix_main: ?u32,
    called: []u32,
    prog_code: usize,
    prog_konst: usize,
    nfuncs: usize,
    file_names: usize,
    stamps: usize,
    fnames: usize,
    main_fn: u32,
    fn_owner: usize,
    acc: usize,
    vt: [vt_lists.len]usize,
    /// RNXC_RESIDENT_CHECK: the program's bytes before the admission, which a
    /// release must give back exactly
    check_before: ?[]u8,

    fn deinit(self: *ReleaseRec) void {
        vmheap.free(self.name);
        vmheap.free(self.natives);
        vmheap.free(self.called);
        if (self.check_before) |b| vmheap.free(b);
    }
};

/// The VM tables the installer grows (Resident.vt), and which of them hold
/// strings it duplicated
const vt_lists = .{ "fn_of", "rows", "files", "names", "global_names", "fn_entry", "fn_frame", "fn_local_from", "local_names", "local_regs", "local_boxed", "fn_names", "fn_method", "fn_nparams", "name_fn", "name_cls", "name_up", "ncache" };
const vt_string_lists = .{ "names", "global_names", "local_names", "fn_names" };

const VmTables = struct {
    fn_of: std.ArrayListUnmanaged(u32) = .{},
    rows: std.ArrayListUnmanaged(u32) = .{},
    files: std.ArrayListUnmanaged(u16) = .{},
    names: std.ArrayListUnmanaged([]const u8) = .{},
    global_names: std.ArrayListUnmanaged([]const u8) = .{},
    fn_entry: std.ArrayListUnmanaged(u32) = .{},
    fn_frame: std.ArrayListUnmanaged(u8) = .{},
    fn_local_from: std.ArrayListUnmanaged(u32) = .{},
    local_names: std.ArrayListUnmanaged([]const u8) = .{},
    local_regs: std.ArrayListUnmanaged(u8) = .{},
    local_boxed: std.ArrayListUnmanaged(bool) = .{},
    fn_names: std.ArrayListUnmanaged([]const u8) = .{},
    fn_method: std.ArrayListUnmanaged(bool) = .{},
    fn_nparams: std.ArrayListUnmanaged(u8) = .{},
    name_fn: std.ArrayListUnmanaged(u32) = .{},
    name_cls: std.ArrayListUnmanaged(u32) = .{},
    name_up: std.ArrayListUnmanaged(u32) = .{},
    ncache: std.ArrayListUnmanaged(?native.RppFn) = .{},
    /// the dispatch rows (vm.dispatch is its items), with room for a few
    /// more classes, since a row is as wide as the names
    dispatch: std.ArrayListUnmanaged(u32) = .{},
};
var g_res = Resident{};

/// Where an admission's top level runs. The driver's: an idle VM, the
/// handler floor its own, an error nothing caught REPORTED and the program
/// carrying on. Inside the program (`admitfile`, rung 2): just above the
/// caller's frame, the floor the caller's handler depth, so an error nothing
/// inside caught comes back to the call and is raised there, as eval's is.
const RunAt = struct { base: u32 = 0, fsp: u32 = 0, hsp: u32 = 1, nested: bool = false, pc: u32 = 0 };

fn residentMain(alloc: std.mem.Allocator, parser: ts.Parser, files: []const [:0]u8) !void {
    const H = vmheap;
    const regs = try H.alloc(vm.Value, 65536);
    @memset(regs, vm.Value.nil());
    var m = vm.VM{
        .code = &.{},
        .regs = regs,
        .frames = try H.alloc(vm.Frame, 4096),
        .alloc = H,
        .argv = g_sysargv,
        .handlers = try H.alloc(vm.Handler, 256),
        .eval_hook = &evalHook,
        .resident = true,
    };
    _ = alloc;
    m.admit_hook = &admitHook;
    m.admit_state_hook = &admitStateHook;
    const rs = &g_res;
    rs.m = &m;
    rs.parser = parser;
    rs.exe = image.ExeStamp.ofSelf(H);
    // `--replace <file>`: that file may redefine functions the program holds
    // (rung 3), as `replacefile` does from inside it
    // `--release <name>` releases the program's last admission (rung 6)
    var replace = false;
    var release = false;
    for (files) |path| {
        if (std.mem.eql(u8, path, "--replace")) {
            replace = true;
            continue;
        }
        if (std.mem.eql(u8, path, "--release")) {
            release = true;
            continue;
        }
        bgQuiet(rs);
        bgDiscard(rs);
        if (release) {
            if (residentRelease(rs, path, .{})) |why| {
                vm.outPrint("not released {s}: {s}\n", .{ path, why });
            } else {
                vm.outPrint("released {s} -- program: {d} function(s), {d} instruction(s), {d} global(s)\n", .{ path, rs.nfuncs, rs.prog_code, m.globals.len -| 1 });
            }
            release = false;
            continue;
        }
        _ = try residentAdmit(rs, path, null, replace, .{});
        replace = false;
    }
    // the last file's top level started one and never finished it: said, and
    // the process ends without waiting for its compile
    bgQuiet(rs);
    const left_compiling = rs.bg != null and !rs.bg_done.isSet();
    if (left_compiling) {
        vm.outPrint("not admitted {s}: started in the background (admitstart) and never finished\n", .{rs.bg.?.path});
        rs.refused += 1;
    } else bgDiscard(rs);
    if (rs.released > 0) {
        vm.outPrint("resident: {d} admitted, {d} refused, {d} released, {d} top level(s) stopped on an error; {d} function(s), {d} instruction(s), {d} global(s)\n", .{ rs.admitted, rs.refused, rs.released, rs.stopped, rs.nfuncs, rs.prog_code, m.globals.len -| 1 });
    } else vm.outPrint("resident: {d} admitted, {d} refused, {d} top level(s) stopped on an error; {d} function(s), {d} instruction(s), {d} global(s)\n", .{ rs.admitted, rs.refused, rs.stopped, rs.nfuncs, rs.prog_code, m.globals.len -| 1 });
    vm.outFlush();
    if (left_compiling) std.process.exit(0);
}

/// RUNG 9: `admitstart` -- the admission's COMPILE begins on a thread of its
/// own and the program carries on. The job owns its copies of what the
/// program handed it; nothing but that thread touches the program's compiler
/// until admitfinish joins it.
fn bgStart(rs: *Resident, name: []const u8, src: ?[]const u8, replace: bool) ?[]const u8 {
    const job = AdmitJob.create(rs, name, src, replace, true, true) catch |e|
        return std.fmt.bufPrint(&rs.busy_why, "Error : not started: {s}: {s}", .{ name, @errorName(e) }) catch "Error : not started";
    if (!rs.bg_started) {
        startWorker(rs) catch |e| {
            job.destroy();
            return std.fmt.bufPrint(&rs.busy_why, "Error : not started: {s}: {s}", .{ name, @errorName(e) }) catch "Error : not started";
        };
        rs.bg_started = true;
    }
    rs.bg_done.reset();
    rs.bg = job;
    rs.bg_go.set();
    return null;
}

/// The compiling thread, with the stack the program's own thread has: 16 MB,
/// rnxc's image -- the compile recurses over the parse tree as deep there as
/// here. RESERVED, as the image's is, and committed as it is used: Zig's
/// spawn hands Windows the size as a commit, and the 16 MB showed whole in
/// the server's private memory (measured 2026-11-01, 51.8 -> 67.8 MB). A
/// POSIX thread's stack is mapped, not committed.
fn startWorker(rs: *Resident) !void {
    const stack: usize = 16 << 20;
    if (@import("builtin").os.tag == .windows) {
        const W = struct {
            fn entry(p: ?*anyopaque) callconv(.winapi) std.os.windows.DWORD {
                bgWorker(@ptrCast(@alignCast(p)));
                return 0;
            }
        };
        const STACK_SIZE_PARAM_IS_A_RESERVATION: std.os.windows.DWORD = 0x00010000;
        const h = std.os.windows.kernel32.CreateThread(null, stack, W.entry, rs, STACK_SIZE_PARAM_IS_A_RESERVATION, null) orelse
            return error.ThreadNotStarted;
        std.os.windows.CloseHandle(h);
    } else {
        const t = try std.Thread.spawn(.{ .stack_size = stack }, bgWorker, .{rs});
        t.detach();
    }
}

/// The compiling thread: waits for a job, compiles it -- the compile half,
/// nothing of the VM's -- and signals the program's thread. Ends with the
/// process.
fn bgWorker(rs: *Resident) void {
    while (true) {
        rs.bg_go.wait();
        rs.bg_go.reset();
        if (rs.bg_tidying) {
            for (rs.bg_trees.items) |t| t.deinit();
            rs.bg_trees.clearRetainingCapacity();
            // a compaction that fails changed nothing: the old arena is kept
            if (rs.bg_compact) residentCompact(rs) catch {};
            rs.bg_compact = false;
        } else if (rs.bg) |job| admitCompile(job);
        rs.bg_done.set();
    }
}

/// Rung 9: the tidy-up after a background admission's install, handed to the
/// compiling thread (Resident.bg_tidying).
fn bgTidy(rs: *Resident, trees: []const ts.Tree) void {
    rs.bg_trees.appendSlice(vmheap, trees) catch {
        for (trees) |t| t.deinit();
    };
    rs.bg_compact = residentBlobOn() or rs.parena.queryCapacity() > rs.compact_at;
    rs.bg_tidying = true;
    rs.bg_done.reset();
    rs.bg_go.set();
}

/// Rung 9: wait for the compiling thread's tidy-up, if one runs -- before
/// anything touches the program's compiler.
fn bgQuiet(rs: *Resident) void {
    if (!rs.bg_tidying) return;
    rs.bg_done.wait();
    rs.bg_tidying = false;
}

/// RUNG 9: `admitfinish` -- waits for the compile if it is still running, then
/// the install, on the program's own thread, where the call stands: the same
/// admission as the verb's, refused or admitted as the verb would have been.
fn bgFinish(rs: *Resident, at: RunAt) ?[]const u8 {
    const job = rs.bg orelse return "Error : admitfinish(): no admission was started (admitstart)";
    rs.bg_done.wait();
    rs.bg = null;
    const why: ?[]const u8 = blk: {
        if (job.err) |e| break :blk std.fmt.bufPrint(&rs.why, "Error : not admitted: {s}: {s}", .{ job.path, @errorName(e) }) catch "Error : not admitted";
        if (job.why) |w| break :blk w;
        break :blk admitInstall(job, at) catch |e|
            (std.fmt.bufPrint(&rs.why, "Error : not admitted: {s}: {s}", .{ job.path, @errorName(e) }) catch "Error : not admitted");
    };
    // compacted when due by the tidy-up its install handed the compiling
    // thread (bgTidy), not here
    job.destroy();
    return why;
}

/// RUNG 9: an admission started and never finished, discarded by the driver
/// before it admits anything else: its compile waited for, the program as it
/// was before it (the undo a refusal takes), and it is not admitted.
fn bgDiscard(rs: *Resident) void {
    const job = rs.bg orelse return;
    vm.outPrint("not admitted {s}: started in the background (admitstart) and never finished\n", .{job.path});
    rs.refused += 1;
    rs.bg_done.wait();
    rs.bg = null;
    if (job.compiled) {
        var undo = Undo{ .rs = rs, .c = job.c, .marks = &job.marks, .before = job.check_before };
        _ = undo.done("");
    }
    job.destroy();
}

/// `admitstate([nWaitMs])`: 0 none, 1 compiling, 2 compiled.
fn admitStateHook(m: *vm.VM, wait_ms: i64) u8 {
    _ = m;
    const rs = &g_res;
    if (rs.bg == null) return 0;
    if (wait_ms > 0 and !rs.bg_done.isSet()) rs.bg_done.timedWait(@as(u64, @intCast(wait_ms)) * std.time.ns_per_ms) catch {};
    return if (rs.bg_done.isSet()) 2 else 1;
}

/// `admitfile(cPath)` and `admitcode(cName, cSource)` from inside the
/// running program (VM.AdmitHook): the same admission as the driver's, its
/// top level run above the caller's frame, nothing printed -- a refusal is
/// the reason the call raises with. `replacefile`/`replacecode` the same,
/// `replace` set (mode 1); `releasefile`/`releasecode` release the program's
/// last admission (mode 2, rung 6).
fn admitHook(m: *vm.VM, name: []const u8, src: ?[]const u8, mode_in: u8, base: u32, fsp: u32, hsp: u32, pc: u32) ?[]const u8 {
    const at: RunAt = .{ .base = base, .fsp = fsp, .hsp = hsp, .nested = true, .pc = pc };
    // rung 9: `admitfinish`, and `admitstart` (the verb's mode, ADMIT_BG set) --
    // and nothing touches the program's compiler during a tidy-up
    bgQuiet(&g_res);
    if (mode_in == vm.ADMIT_FINISH) return bgFinish(&g_res, at);
    const bg = mode_in & vm.ADMIT_BG != 0;
    const mode = mode_in & 0x0F;
    // ONE admission compiles at a time: while one does in the background,
    // the program's compiler is that thread's alone
    if (g_res.bg) |job| {
        const verb = if (bg) "not started" else if (mode == 2) "not released" else "not admitted";
        return std.fmt.bufPrint(&g_res.busy_why, "Error : {s}: {s}: {s} is compiling in the background -- admitfinish() first", .{ verb, name, job.path }) catch "Error : busy";
    }
    if (mode == 2) {
        const why = residentRelease(&g_res, name, at) orelse return null;
        return std.fmt.bufPrint(&g_res.why, "Error : not released: {s}: {s}", .{ name, why }) catch "Error : not released";
    }
    // D31: an app -- `admitapp(cApp, cSource, aExports)` (mode 3) and `replaceapp(cApp, cSource)` (mode 4). The app's
    // name is an identifier; its exports are names, each checked by the compile against what the app defines.
    if (mode >= 3) {
        var ok = name.len > 0 and name.len <= 64 and std.ascii.isAlphabetic(name[0]);
        for (name) |ch| ok = ok and (std.ascii.isAlphanumeric(ch) or ch == '_');
        if (!ok) return std.fmt.bufPrint(&g_res.why, "Error : not admitted: {s}: an app's name is an identifier (letters, digits, _)", .{name}) catch "Error : not admitted";
        var ex = std.ArrayListUnmanaged([]const u8){};
        defer ex.deinit(vmheap);
        if (mode == 3) {
            const lv = m.admit_exports;
            if (lv.tag == .vec) {
                for (lv.p.v.ptr[0..lv.p.v.len]) |it| {
                    if (it.tag != .str) return std.fmt.bufPrint(&g_res.why, "Error : not admitted: {s}: an export is a name (a string)", .{name}) catch "Error : not admitted";
                    ex.append(vmheap, it.p.s.ptr[0..it.p.s.len]) catch return "Error : not admitted";
                }
            }
        }
        g_res.cur_app = name;
        g_res.cur_exports = ex.items;
        defer {
            g_res.cur_app = null;
            g_res.cur_exports = &.{};
        }
        if (bg) return bgStart(&g_res, name, src, mode == 4);
        return residentAdmit(&g_res, name, src, mode == 4, at) catch |e|
            (std.fmt.bufPrint(&g_res.why, "Error : not admitted: {s}: {s}", .{ name, @errorName(e) }) catch "Error : not admitted");
    }
    if (bg) return bgStart(&g_res, name, src, mode == 1);
    return residentAdmit(&g_res, name, src, mode == 1, at) catch |e|
        (std.fmt.bufPrint(&g_res.why, "Error : not admitted: {s}: {s}", .{ name, @errorName(e) }) catch "Error : not admitted");
}

/// RNXC_ADMIT_PHASES=1: one line per admission on stderr -- restoring the
/// program's state, loading the file, compiling it (and inside that,
/// co.admit_ns's four), installing the delta, saving the state, running its
/// top level. The resident VM's cost is the sum, and which part grows with
/// the program is the question this answers.
const AdmitPhases = struct {
    const Phase = enum { restore, load, compile, install, save, run };
    ns: [6]u64 = .{0} ** 6,
    t: ?std.time.Timer = null,
    fn lap(self: *AdmitPhases, p: Phase) void {
        if (self.t == null) self.t = std.time.Timer.start() catch return;
        self.ns[@intFromEnum(p)] = self.t.?.lap();
    }
    fn report(self: *AdmitPhases, path: []const u8, rs: *const Resident, ans: [4]u64) void {
        if (!admitPhasesOn()) return;
        const msOf = struct {
            fn f(x: u64) f64 {
                return @as(f64, @floatFromInt(x)) / 1e6;
            }
        }.f;
        std.debug.print("phases: {s}: restore {d:.1} load {d:.1} compile {d:.1} (collect {d:.1} resolve {d:.1} front {d:.1} finish {d:.1}) install {d:.1} save {d:.1} run {d:.1} ms; program arena {d} MB, compacted {d}x\n", .{
            std.fs.path.basename(path), msOf(self.ns[0]), msOf(self.ns[1]), msOf(self.ns[2]),
            msOf(ans[0]), msOf(ans[1]), msOf(ans[2]), msOf(ans[3]),
            msOf(self.ns[3]), msOf(self.ns[4]), msOf(self.ns[5]),
            // a background compile, or its tidy-up, may be using the arena (rung 9)
            if (rs.bg == null and !rs.bg_tidying) rs.parena.queryCapacity() >> 20 else 0, rs.compactions,
        });
    }
};
var g_admit_phases: ?bool = null;
fn admitPhasesOn() bool {
    if (g_admit_phases == null) g_admit_phases = std.process.hasEnvVarConstant("RNXC_ADMIT_PHASES");
    return g_admit_phases.?;
}

/// A REFUSED admission undone (rung 5): the live program rolled back to its
/// marks and moved back. Under RNXC_RESIDENT_CHECK=1 the program is saved
/// again and must be the bytes it was before -- the proof the undo is whole,
/// since those bytes are everything the next admission would start from.
const Undo = struct {
    rs: *Resident,
    c: *co.Compiler,
    marks: *const co.Marks,
    before: ?[]u8,
    fn done(self: *Undo, why: []const u8) ?[]const u8 {
        co.rollbackProgram(self.c, self.marks);
        co.takeProgram(self.rs.P, self.c);
        if (self.before) |b| {
            const after = prefix.encode(vmheap, self.rs.exe, self.rs.stamps.items, self.rs.fnames.items, self.rs.P) catch @panic("resident: the program could not be saved");
            defer vmheap.free(after);
            if (!std.mem.eql(u8, b, after)) {
                std.debug.print("resident: RNXC_RESIDENT_CHECK -- a refused admission changed the program ({d} bytes before, {d} after): a defect of rnxc\n", .{ b.len, after.len });
                std.process.exit(2);
            }
        }
        return why;
    }
};

/// THE CLASS TABLES GROW (rung 5): what an admission adds to the object
/// model, written into the VM's tables where they stand -- never a rebuild.
/// A rebuild cost a class admission ~80 ms at Softanza's size (a dispatch
/// row per class, as wide as the names: ~175 MB), and lost what `addmethod`
/// had attached at run time.
///
///   a new class        a row: its own methods, then its parent's row for
///                      every name it does not define -- the parent's row
///                      already holds each ancestor's answer
///   a replaced class   its new methods over the row it has (rung 4: the
///                      later method wins), and in every descendant's row
///                      each cell that held the replaced class's old answer
///                      -- an inherited cell holds exactly that, an
///                      overriding one never does
///   more names than the rows are wide: every row laid out again, wider
///
/// The method table only grows, so every slot a row or `addmethod` holds
/// stays valid. RNXC_RESIDENT_CHECK compares the result, cell by cell, with
/// the tables a whole build gives (checkVmTables).
/// Rung 7: a gained attribute's starting value as the VM holds it -- built
/// once, kept in vm.class_gained, copied into each object that takes it
fn gainedValue(m: *vm.VM, v: co.ConstVal) vm.Value {
    return switch (v) {
        .int => |i| vm.Value.int(i),
        .konst => |k| vm.konst[@intCast(k)],
        .list => |items| blk: {
            const vec = m.newVec(@intCast(items.len));
            for (items, 0..) |it, i| {
                const e = gainedValue(m, it);
                vm.VM.holdValue(e);
                vec.ptr[i] = e;
            }
            vec.len = @intCast(items.len);
            break :blk vm.Value.vec(vec);
        },
    };
}

fn growClassTables(rs: *Resident, c: *co.Compiler, prog: co.Program, old_funcs: usize, old_classes: usize) !void {
    const H = vmheap;
    const vt = &rs.vt;
    const ncls = c.classes.items.len;
    const nn = c.names.items.len;
    var nnm: usize = vm.n_names;
    std.debug.assert(vm.class_slots.len == old_classes and vt.dispatch.items.len == old_classes * nnm);
    // the rows' width
    if (nn > nnm) {
        const wide = nn + nn / 8 + 256;
        var nd = std.ArrayListUnmanaged(u32){};
        try nd.ensureTotalCapacityPrecise(H, (old_classes + 32) * wide);
        for (0..old_classes) |k| {
            nd.appendSliceAssumeCapacity(vt.dispatch.items[k * nnm ..][0..nnm]);
            nd.appendNTimesAssumeCapacity(0, wide - nnm);
        }
        vt.dispatch.deinit(H);
        vt.dispatch = nd;
        nnm = wide;
        vm.n_names = @intCast(wide);
    }
    // the method table: an entry for each method this admission added to a
    // class -- a new class's, or a replaced class's new ones
    const slot_of = try H.alloc(u32, c.funcs.items.len - old_funcs);
    defer H.free(slot_of);
    @memset(slot_of, 0);
    var added = std.ArrayListUnmanaged(u32){};
    defer added.deinit(H);
    for (c.class_repl.items) |r| {
        for (c.classes.items[r.cid].methods.items) |mi| {
            if (mi >= old_funcs) try added.append(H, mi);
        }
    }
    for (c.classes.items[old_classes..]) |ci| try added.appendSlice(H, ci.methods.items);
    if (added.items.len > 0) {
        const mt = try H.alloc(vm.MethodEnt, vm.method_tab.len + added.items.len);
        @memcpy(mt[0..vm.method_tab.len], vm.method_tab);
        for (added.items, vm.method_tab.len..) |mi, at| {
            mt[at] = co.methodEnt(&c.funcs.items[mi]);
            slot_of[mi - old_funcs] = @intCast(at + 1);
        }
        if (vm.method_tab.len > 0) H.free(vm.method_tab);
        vm.method_tab = mt;
    }
    const slotOf = struct {
        fn f(so: []const u32, base: usize, mi: u32) u32 {
            return so[mi - base];
        }
    }.f;
    // the replaced classes, and what inherited from them
    const Change = struct { nm: u32, was: u32, now: u32 };
    var changes = std.ArrayListUnmanaged(Change){};
    defer changes.deinit(H);
    for (c.class_repl.items) |r| {
        changes.clearRetainingCapacity();
        const row = vt.dispatch.items[@as(usize, r.cid) * nnm ..][0..nnm];
        for (c.classes.items[r.cid].methods.items) |mi| {
            if (mi < old_funcs) continue;
            const nm = c.funcs.items[mi].name_idx;
            const now = slotOf(slot_of, old_funcs, mi);
            const seen = for (changes.items) |*ch| {
                if (ch.nm == nm) break ch;
            } else null;
            if (seen) |ch| ch.now = now else try changes.append(H, .{ .nm = nm, .was = row[nm], .now = now });
            row[nm] = now;
        }
        for (0..old_classes) |d| {
            if (d == r.cid) continue;
            var p = c.classes.items[d].parent;
            const descends = while (p) |pid| {
                if (pid == r.cid) break true;
                p = c.classes.items[pid].parent;
            } else false;
            if (!descends) continue;
            const drow = vt.dispatch.items[d * nnm ..][0..nnm];
            for (changes.items) |ch| {
                if (drow[ch.nm] == ch.was) drow[ch.nm] = ch.now;
            }
        }
    }
    // RUNG 7: a replaced class that GAINED attributes -- its slot count and
    // the attribute table (rebuilt for the classes there were, so the new
    // ones below append to it), and what each gained slot starts as in the
    // objects made before (vm.class_gained, read by VM.fitObj)
    {
        var relaid = false;
        for (c.class_repl.items) |r| {
            const now: u32 = @intCast(c.classes.items[r.cid].attrs.items.len);
            if (now != vm.class_slots[r.cid]) {
                vm.class_slots[r.cid] = now;
                relaid = true;
            }
        }
        if (relaid) {
            var ents = std.ArrayListUnmanaged(vm.AttrEnt){};
            const from = try H.alloc(u32, old_classes + 1);
            for (0..old_classes) |k| {
                from[k] = @intCast(ents.items.len);
                try co.classAttrEnts(c, H, @intCast(k), &ents, from[k]);
            }
            from[old_classes] = @intCast(ents.items.len);
            if (vm.attr_ent.len > 0) H.free(vm.attr_ent);
            if (vm.attr_from.len > 0) H.free(vm.attr_from);
            vm.attr_ent = try ents.toOwnedSlice(H);
            vm.attr_from = from;
        }
        for (c.class_gained.items) |g| {
            if (g.cid >= vm.class_gained.len) {
                const rows = try H.alloc([]vm.Value, @as(usize, g.cid) + 1);
                @memcpy(rows[0..vm.class_gained.len], vm.class_gained);
                for (rows[vm.class_gained.len..]) |*row| row.* = &.{};
                if (vm.class_gained.len > 0) H.free(vm.class_gained);
                vm.class_gained = rows;
            }
            const row = &vm.class_gained[g.cid];
            if (g.slot >= row.len) {
                const nr = try H.alloc(vm.Value, vm.class_slots[g.cid]);
                @memcpy(nr[0..row.len], row.*);
                @memset(nr[row.len..], vm.Value.nil());
                if (row.len > 0) H.free(row.*);
                row.* = nr;
            }
            const v = gainedValue(rs.m, g.val);
            vm.VM.holdValue(v);
            row.*[g.slot] = v;
        }
    }
    // the new classes' rows, a parent before its children
    if (ncls > old_classes) {
        if (vt.dispatch.capacity < ncls * nnm) try vt.dispatch.ensureTotalCapacityPrecise(H, (ncls + 32) * nnm);
        vt.dispatch.appendNTimesAssumeCapacity(0, (ncls - old_classes) * nnm);
        const done = try H.alloc(bool, ncls - old_classes);
        defer H.free(done);
        @memset(done, false);
        var left = ncls - old_classes;
        while (left > 0) {
            const before = left;
            for (old_classes..ncls) |k| {
                if (done[k - old_classes]) continue;
                const ci = &c.classes.items[k];
                if (ci.parent) |pp| {
                    if (pp >= old_classes and !done[pp - old_classes]) continue;
                }
                const row = vt.dispatch.items[k * nnm ..][0..nnm];
                for (ci.methods.items) |mi| row[c.funcs.items[mi].name_idx] = slotOf(slot_of, old_funcs, mi);
                if (ci.parent) |pp| {
                    const prow = vt.dispatch.items[@as(usize, pp) * nnm ..][0..nnm];
                    for (row, prow) |*cell, pv| {
                        if (cell.* == 0) cell.* = pv;
                    }
                }
                done[k - old_classes] = true;
                left -= 1;
            }
            if (left == before) return error.ClassCycle;
        }
        // their slots, parents, names and attributes
        const grow = struct {
            fn f(comptime T: type, old: []T, extra: usize) ![]T {
                const n = try vmheap.alloc(T, old.len + extra);
                @memcpy(n[0..old.len], old);
                if (old.len > 0) vmheap.free(old);
                return n;
            }
        }.f;
        const add = ncls - old_classes;
        vm.class_slots = try grow(u32, vm.class_slots, add);
        vm.class_parent = try grow(u16, vm.class_parent, add);
        vm.class_konst = try grow(u32, vm.class_konst, add);
        std.debug.assert(prog.class_konst_new.len == add);
        var ents = std.ArrayListUnmanaged(vm.AttrEnt){};
        try ents.appendSlice(H, vm.attr_ent);
        const from = try grow(u32, vm.attr_from, add);
        for (old_classes..ncls) |k| {
            const ci = c.classes.items[k];
            vm.class_slots[k] = @intCast(ci.attrs.items.len);
            vm.class_parent[k] = if (ci.parent) |pp| @intCast(pp) else 0xFFFF;
            vm.class_konst[k] = prog.class_konst_new[k - old_classes];
            from[k] = @intCast(ents.items.len);
            try co.classAttrEnts(c, H, @intCast(k), &ents, from[k]);
        }
        from[ncls] = @intCast(ents.items.len);
        if (vm.attr_ent.len > 0) H.free(vm.attr_ent);
        vm.attr_ent = try ents.toOwnedSlice(H);
        vm.attr_from = from;
    }
    vm.dispatch = vt.dispatch.items;
    // a method `addmethod` attached under a name the program did not have --
    // not yet, or no longer, a release having taken it (rung 6) -- reaches
    // its class once an admission brings the name: the cell is written then,
    // the later attachment winning, a method of the class's own kept
    {
        var set = std.AutoHashMapUnmanaged(usize, void){};
        defer set.deinit(H);
        var lb: [256]u8 = undefined;
        for (vm.dyn_methods.items) |dm| {
            if (dm.name.len > lb.len) continue;
            const ni = c.name_index.get(std.ascii.lowerString(&lb, dm.name)) orelse continue;
            const cell = @as(usize, dm.cls) * nnm + ni;
            if (ni >= nnm or cell >= vt.dispatch.items.len) continue;
            if (vt.dispatch.items[cell] == 0 or set.contains(cell)) {
                vt.dispatch.items[cell] = dm.slot;
                try set.put(H, cell, {});
            }
        }
    }
    // the class that defines each new function
    {
        const fo = try H.alloc(u16, c.funcs.items.len);
        @memcpy(fo[0..vm.fn_owner.len], vm.fn_owner);
        for (c.funcs.items[vm.fn_owner.len..], vm.fn_owner.len..) |f, ix| fo[ix] = if (f.owner) |o| o else 0xFFFF;
        if (vm.fn_owner.len > 0) H.free(vm.fn_owner);
        vm.fn_owner = fo;
    }
    // the accessor tables: a new name `get<k>` names k's getter, and a new
    // name k takes a `get<k>` the program already had
    {
        const old_nn = vm.acc_get.len;
        const ag = try H.alloc(u32, nn);
        const as = try H.alloc(u32, nn);
        @memcpy(ag[0..old_nn], vm.acc_get);
        @memcpy(as[0..old_nn], vm.acc_set);
        @memset(ag[old_nn..], vm.ACC_NONE);
        @memset(as[old_nn..], vm.ACC_NONE);
        var buf: [256]u8 = undefined;
        for (c.names.items[old_nn..], old_nn..) |nm, i| {
            co.accessorOf(c, nm, @intCast(i), ag, as);
            if (nm.len + 3 > buf.len) continue;
            _ = std.ascii.lowerString(buf[3 .. 3 + nm.len], nm);
            @memcpy(buf[0..3], "get");
            if (c.name_index.get(buf[0 .. 3 + nm.len])) |gi| ag[i] = gi;
            @memcpy(buf[0..3], "set");
            if (c.name_index.get(buf[0 .. 3 + nm.len])) |si| as[i] = si;
        }
        if (old_nn > 0) {
            H.free(vm.acc_get);
            H.free(vm.acc_set);
        }
        vm.acc_get = ag;
        vm.acc_set = as;
    }
}

/// RNXC_RESIDENT_CHECK's third part (rung 5): the grown class tables against
/// the ones a whole build of the program gives. A dispatch cell is compared
/// by the method it reaches, since a grown table numbers its methods in the
/// order they arrived; a cell `addmethod` wrote at run time is left out.
fn checkClassTables(c: *co.Compiler, a: std.mem.Allocator, bad: *const fn ([]const u8) noreturn) void {
    const names_before = c.names.items.len;
    const konst_before = c.konst.items.len;
    const nnm: usize = vm.n_names;
    const ncls = c.classes.items.len;
    if (ncls > 0) {
        const full = co.buildClassTables(c, a, nnm) catch @panic("oom");
        if (!std.mem.eql(u32, vm.class_slots, full.class_slots)) bad("class_slots");
        if (!std.mem.eql(u16, vm.class_parent, full.class_parent)) bad("class_parent");
        if (!std.mem.eql(u32, vm.class_konst, full.class_konst)) bad("class_konst");
        if (vm.attr_from.len != full.attr_from.len) bad("attr_from's length");
        for (0..ncls) |k| {
            const x = vm.attr_ent[vm.attr_from[k]..vm.attr_from[k + 1]];
            const y = full.attr_ent[full.attr_from[k]..full.attr_from[k + 1]];
            if (x.len != y.len) bad("attr_ent");
            for (x, y) |p, q| if (p.name != q.name or p.slot != q.slot) bad("attr_ent");
        }
        if (vm.dispatch.len != full.dispatch.len) bad("dispatch's length");
        var skip = std.AutoHashMapUnmanaged(usize, void){};
        for (vm.dyn_methods.items) |dm| {
            if (c.name_index.get(dm.name)) |ni| skip.put(a, @as(usize, dm.cls) * nnm + ni, {}) catch @panic("oom");
        }
        for (vm.dispatch, full.dispatch, 0..) |x, y, cell| {
            if (x == y and x == 0) continue;
            if (skip.contains(cell)) continue;
            if ((x == 0) != (y == 0)) bad("dispatch");
            const p = vm.method_tab[x - 1];
            const q = full.method_tab[y - 1];
            if (p.entry != q.entry or p.frame != q.frame or p.id != q.id or p.nparams != q.nparams or p.shift != q.shift) bad("dispatch");
        }
    }
    const fo = co.buildFnOwner(c, a) catch @panic("oom");
    if (!std.mem.eql(u16, vm.fn_owner, fo)) bad("fn_owner");
    const acc = co.buildAccessors(c, a) catch @panic("oom");
    if (!std.mem.eql(u32, vm.acc_get, acc[0]) or !std.mem.eql(u32, vm.acc_set, acc[1])) bad("accessor tables");
    if (c.names.items.len != names_before or c.konst.items.len != konst_before) bad("program (the check itself added a name)");
}

/// RNXC_RESIDENT_CHECK: the `r24` index (Resident.r24) is exactly the running
/// code's `r24` sites, each once -- an admission adds its own, a release takes
/// them away again. An entry a release left behind names a place past the
/// code, which the next new-global check would read (rung 6)
fn checkR24Index(rs: *Resident) void {
    const code = rs.m.code;
    var n: usize = 0;
    for (code) |in| {
        if (in.op == .r24 and in.d >= 0) n += 1;
    }
    var listed: usize = 0;
    var it = rs.r24.iterator();
    while (it.next()) |e| {
        for (e.value_ptr.items) |pc| {
            listed += 1;
            if (pc >= code.len or code[pc].op != .r24 or code[pc].d != @as(i32, @intCast(e.key_ptr.*))) {
                std.debug.print("resident: RNXC_RESIDENT_CHECK -- the r24 index names {d}, which is not an r24 of its name in the {d} instruction(s) of the code: a defect of rnxc\n", .{ pc, code.len });
                std.process.exit(2);
            }
        }
    }
    if (listed != n) {
        std.debug.print("resident: RNXC_RESIDENT_CHECK -- the r24 index lists {d} site(s), the code holds {d}: a defect of rnxc\n", .{ listed, n });
        std.process.exit(2);
    }
}

/// RNXC_RESIDENT_CHECK's second half (rung 5): the VM's grown tables against
/// the ones a whole build of the program gives -- per function and per name
/// whole; per instruction, the code this admission added (an earlier
/// admission's was checked when it was added, and is never written again).
/// A difference is a defect of rnxc, and stops it.
fn checkVmTables(m: *vm.VM, c: *co.Compiler, prog: co.Program, a: std.mem.Allocator) void {
    const S = struct {
        fn bad(what: []const u8) noreturn {
            std.debug.print("resident: RNXC_RESIDENT_CHECK -- the VM's {s} is not what a whole build gives: a defect of rnxc\n", .{what});
            std.process.exit(2);
        }
        fn strs(x: []const []const u8, y: []const []const u8) bool {
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
            return true;
        }
    };
    const ft = co.fnTables(prog.funcs, a, 0) catch @panic("oom");
    if (!std.mem.eql(u32, m.fn_entry, ft.entry)) S.bad("fn_entry");
    if (!std.mem.eql(u8, m.fn_frame, ft.frame)) S.bad("fn_frame");
    if (!std.mem.eql(u32, m.fn_local_from, ft.local_from)) S.bad("fn_local_from");
    if (!S.strs(m.local_names, ft.local_names)) S.bad("local_names");
    if (!std.mem.eql(u8, m.local_regs, ft.local_regs)) S.bad("local_regs");
    if (!std.mem.eql(bool, m.local_boxed, ft.local_boxed)) S.bad("local_boxed");
    const fo = co.fnOfTable(a, prog.funcs, prog.code.len, prog.body_end, 0, 0) catch @panic("oom");
    // A function's code begins with a placeholder jump its entry moves past
    // when the body clears no local (F-89). A whole build gives the first
    // new function's placeholder to the function before it by address -- an
    // earlier admission's, whose range that admission closed -- and the
    // delta to none. It never runs; it is the one difference allowed, and
    // only for a jump.
    if (m.fn_of.len != fo.len) S.bad("fn_of's length");
    var lo = prog.code_base;
    while (lo < fo.len and m.fn_of[lo] == std.math.maxInt(u32) and fo[lo] < prog.fn_base and prog.code[lo].op == .jmp) lo += 1;
    if (!std.mem.eql(u32, m.fn_of[lo..], fo[lo..])) S.bad("fn_of");
    if (!std.mem.eql(u32, m.rows, prog.rows)) S.bad("rows");
    if (!std.mem.eql(u16, m.files, prog.files)) S.bad("files");
    if (!S.strs(m.names, prog.names)) S.bad("names");
    if (!S.strs(vm.global_names, prog.global_names)) S.bad("global_names");
    if (m.fn_names.len != prog.funcs.len or m.fn_method.len != prog.funcs.len or m.fn_nparams.len != prog.funcs.len) S.bad("per-function table lengths");
    const nfn = a.alloc(u32, prog.names.len) catch @panic("oom");
    @memset(nfn, vm.NO_FN);
    for (prog.funcs, 0..) |f, i| {
        if (!std.mem.eql(u8, m.fn_names[i], f.name)) S.bad("fn_names");
        if (m.fn_method[i] != (f.owner != null)) S.bad("fn_method");
        const plain = f.owner == null and f.lambda_at == null and !std.mem.startsWith(u8, f.name, "@@");
        if (m.fn_nparams[i] != (if (plain and f.params.len < 0xFF) @as(u8, @intCast(f.params.len)) else 0xFF)) S.bad("fn_nparams");
        if (plain and f.name_idx < nfn.len and nfn[f.name_idx] == vm.NO_FN) nfn[f.name_idx] = prog.funcs[c.live(@intCast(i))].id;
    }
    const ncl = a.alloc(u32, prog.names.len) catch @panic("oom");
    @memset(ncl, vm.NO_CLS);
    co.lateClasses(c, ncl);
    applyExports(&g_res, c, nfn, ncl);
    if (!std.mem.eql(u32, m.name_fn, nfn)) S.bad("name_fn");
    if (!std.mem.eql(u32, m.name_cls, ncl)) S.bad("name_cls");
    if (m.name_up.len != prog.names.len) S.bad("name_up's length");
    for (0..prog.names.len) |i| {
        if (m.name_up[i] != nameUpOf(c, prog.names, i)) S.bad("name_up");
    }
    if (m.ncache.len != m.names.len) S.bad("native cache's length");
    if (m.fn_index) |fi| {
        var want = std.StringHashMapUnmanaged(u32){};
        for (prog.funcs, 0..) |f, i| {
            if (f.name.len == 0 or f.name.len > 250 or f.owner != null) continue;
            const key = a.alloc(u8, f.name.len) catch @panic("oom");
            for (f.name, 0..) |ch, k| key[k] = std.ascii.toLower(ch);
            if (want.contains(key)) continue;
            want.put(a, key, prog.funcs[c.live(@intCast(i))].id) catch @panic("oom");
        }
        if (want.count() != fi.count()) S.bad("name map's size");
        var it = want.iterator();
        while (it.next()) |e| if ((fi.get(e.key_ptr.*) orelse S.bad("name map")) != e.value_ptr.*) S.bad("name map");
    }
    if (m.name_lc) |nl| {
        var n: usize = 0;
        for (prog.names, 0..) |nm, i| {
            if (nm.len == 0 or nm.len > 250) continue;
            var low: [250]u8 = undefined;
            const key = std.ascii.lowerString(&low, nm);
            const got = nl.get(key) orelse S.bad("name index map");
            if (got == i) n += 1;
        }
        if (n != nl.count()) S.bad("name index map's size");
    }
    checkClassTables(c, a, &S.bad);
}

/// The live program's first state: empty, in an arena of its own.
fn residentLive(rs: *Resident) !void {
    const pa = try vmheap.create(std.heap.ArenaAllocator);
    pa.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const p = try pa.allocator().create(co.Compiler);
    p.* = .{ .alloc = pa.allocator(), .lenient = true };
    rs.parena = pa;
    rs.P = p;
    rs.live = true;
}

/// The live program COMPACTED: saved to bytes and restored into a fresh
/// arena -- the path every admission took before rung 5 -- and the old arena,
/// with everything the compiles left in it, released. Run when the arena has
/// doubled (plus `compact_slack`) since the last time, and after every admission under
/// RNXC_RESIDENT_BLOB=1. Nothing still running reads the old arena: an
/// admission releases its trees and finishes with `prog` before it can run a
/// top level that compacts.
fn residentCompact(rs: *Resident) !void {
    const H = vmheap;
    var tm = std.time.Timer.start() catch null;
    const cap_before = rs.parena.queryCapacity();
    const blob = try prefix.encode(H, rs.exe, rs.stamps.items, rs.fnames.items, rs.P);
    defer H.free(blob);
    const na = try H.create(std.heap.ArenaAllocator);
    na.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = na.allocator();
    const np = try a.create(co.Compiler);
    np.* = .{ .alloc = a, .lenient = true };
    var st = std.ArrayListUnmanaged(image.Stamp){};
    var fnm = std.ArrayListUnmanaged([]const u8){};
    // the dispatch rows' width is the VM's, and decode leaves it alone: this
    // may run on the compiling thread while the VM dispatches (rung 9)
    if (!prefix.decode(a, blob, rs.exe, np, &st, &fnm)) {
        std.debug.print("resident: the program's own state did not read back -- a defect of rnxc\n", .{});
        std.process.exit(2);
    }
    // room to grow: a list restored at its exact length doubles -- into this
    // arena, for good -- the first time the next admission appends to it
    inline for (.{ "code", "rows", "files", "fixups", "names", "globals", "natives", "konst", "funcs", "classes" }) |f| {
        const l = &@field(np, f);
        try l.ensureTotalCapacity(a, l.items.len + l.items.len / 4 + 256);
    }
    rs.parena.deinit();
    H.destroy(rs.parena);
    rs.parena = na;
    rs.P = np;
    rs.compact_at = na.queryCapacity() * 2 + compact_slack;
    rs.compactions += 1;
    if (admitPhasesOn()) std.debug.print("compaction {d}: program arena {d} -> {d} KB in {d:.1} ms\n", .{
        rs.compactions, cap_before >> 10, na.queryCapacity() >> 10, if (tm) |*t| @as(f64, @floatFromInt(t.read())) / 1e6 else 0,
    });
}

/// What the arena may grow by past twice what it held after the last
/// compaction. 64 MB until rung 6; a server releasing code per request left
/// its sources there, and a small program climbed 64 MB before it was
/// reclaimed (measured 2026-10-31: ~17 KB a run of 16 KB of source). A
/// compaction of a small program costs a few milliseconds; at Softanza's size
/// the doubling, not this, decides when.
const compact_slack: usize = 16 << 20;

var g_resident_check: ?bool = null;
fn residentCheckOn() bool {
    if (g_resident_check == null) g_resident_check = std.process.hasEnvVarConstant("RNXC_RESIDENT_CHECK");
    return g_resident_check.?;
}
var g_resident_blob: ?bool = null;
fn residentBlobOn() bool {
    if (g_resident_blob == null) g_resident_blob = std.process.hasEnvVarConstant("RNXC_RESIDENT_BLOB");
    return g_resident_blob.?;
}

/// One admission: null when admitted (and its top level run), else why not.
/// `path` is the file, or with `src` the NAME code is admitted under.
/// `replace` (rung 3): it may redefine functions the program holds -- and a
/// file may then be one the program already admitted, read again as it is
/// now on disk, the shape of a redeploy.
fn residentAdmit(rs: *Resident, path: []const u8, src: ?[]const u8, replace: bool, at: RunAt) !?[]const u8 {
    const why = try residentAdmitOnce(rs, path, src, replace, at);
    // compacted once the admission is wholly over -- its own cleanup reads
    // lists in the program's arena -- and before the next one starts
    // -- and not while a compile started from its top level owns the arena (rung 9)
    bgQuiet(rs);
    if (rs.bg == null and (residentBlobOn() or rs.parena.queryCapacity() > rs.compact_at)) try residentCompact(rs);
    return why;
}

/// ONE ADMISSION IN TWO HALVES (rung 9). admitCompile reads and writes the
/// program's COMPILER only -- never the VM: nothing it reads is the VM's, and
/// what compileFinish builds for the VM's globals waits in co.VmOut -- so it
/// may run on a thread of its own while the program runs (`admitstart`).
/// admitInstall hands the VM the delta and runs the admitted top level, on
/// the program's own thread. Back to back on one thread they are the
/// admission of rungs 1-8, which every synchronous verb still is.
const AdmitJob = struct {
    rs: *Resident,
    path: []const u8,
    src: ?[]const u8,
    replace: bool,
    nested: bool,
    /// D31: the app it is admitted into, and what that app exports
    app: ?[]const u8,
    exports: []const []const u8,
    /// whether the VM held class tables when the admission began (read on
    /// the program's thread: the compile may not read the VM's tables)
    vm_has_classes: bool,
    /// rung 9: started in the background, so the job owns its copies of
    /// path, src, app and exports -- the program may release its own -- and
    /// its install hands the tidy-up to the compiling thread (bgTidy)
    own: bool,
    arena: std.heap.ArenaAllocator,
    sa: std.heap.ArenaAllocator,
    timer: std.time.Timer,
    ph: AdmitPhases,
    c: *co.Compiler = undefined,
    marks: co.Marks = undefined,
    check_before: ?[]u8 = null,
    on_top: Unit = .{},
    old_funcs: usize = 0,
    old_classes: usize = 0,
    prog: co.Program = undefined,
    admit_ns: [4]u64 = .{0} ** 4,
    /// the compile's outcome: refused (the program undone, and why), failed
    /// with an error, or compiled -- ready for admitInstall
    why: ?[]const u8 = null,
    err: ?anyerror = null,
    compiled: bool = false,

    fn create(rs: *Resident, path: []const u8, src: ?[]const u8, replace: bool, nested: bool, own: bool) !*AdmitJob {
        const H = vmheap;
        const job = try H.create(AdmitJob);
        var ex: []const []const u8 = rs.cur_exports;
        if (own) {
            const e2 = try H.alloc([]const u8, rs.cur_exports.len);
            for (rs.cur_exports, 0..) |e, k| e2[k] = try H.dupe(u8, e);
            ex = e2;
        }
        job.* = .{
            .rs = rs,
            .path = if (own) try H.dupe(u8, path) else path,
            .src = if (src) |t| (if (own) try H.dupe(u8, t) else t) else null,
            .replace = replace,
            .nested = nested,
            .app = if (rs.cur_app) |ap| (if (own) try H.dupe(u8, ap) else ap) else null,
            .exports = ex,
            .vm_has_classes = vm.dispatch.len > 0,
            .own = own,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .sa = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .timer = try std.time.Timer.start(),
            .ph = .{ .t = std.time.Timer.start() catch null },
        };
        return job;
    }

    fn destroy(job: *AdmitJob) void {
        const H = vmheap;
        for (job.on_top.trees.items) |t| t.deinit();
        job.on_top.trees.clearRetainingCapacity();
        if (job.check_before) |b| H.free(b);
        job.sa.deinit();
        job.arena.deinit();
        if (job.own) {
            H.free(job.path);
            if (job.src) |t| H.free(t);
            if (job.app) |ap| H.free(ap);
            for (job.exports) |e| H.free(e);
            H.free(job.exports);
        }
        H.destroy(job);
    }
};

fn residentAdmitOnce(rs: *Resident, path: []const u8, src: ?[]const u8, replace: bool, at: RunAt) !?[]const u8 {
    const job = try AdmitJob.create(rs, path, src, replace, at.nested, false);
    defer job.destroy();
    admitCompile(job);
    if (job.err) |e| return e;
    if (job.why) |w| return w;
    return admitInstall(job, at);
}

/// The COMPILE half: everything an admission does before the VM is touched.
/// A refusal is undone here and leaves `why`; an error is kept in `err`.
fn admitCompile(job: *AdmitJob) void {
    admitCompileOrFail(job) catch |e| {
        job.err = e;
    };
    // the compiler's own counters are per thread (co.admit_ns): kept here
    // for the report, which the install half prints
    job.admit_ns = co.admit_ns;
}

fn admitCompileOrFail(job: *AdmitJob) !void {
    const H = vmheap;
    const rs = job.rs;
    const parser = rs.parser;
    const exe = rs.exe;
    const path = job.path;
    const src = job.src;
    const replace = job.replace;
    // a refusal is printed only by the driver (refuse reads `nested` alone)
    const at: RunAt = .{ .nested = job.nested };
    const a = job.arena.allocator();
    if (!at.nested) vm.outFlush();
    // RNXC_ADMIT_PHASES=1: where each admission's time goes, on stderr
    const ph = &job.ph;

    // the program so far, moved into a compiler of this admission's own: the
    // live program's lists and indexes, everything per-admission fresh. What
    // the compile allocates beside the program goes in the program's arena
    // (`pa`), since the program keeps it; the tables built for the VM, which
    // the install copies, in this admission's (`a`)
    if (!rs.live) try residentLive(rs);
    const pa = rs.parena.allocator();
    const c = try a.create(co.Compiler);
    c.* = .{ .alloc = pa, .lenient = true };
    job.c = c;
    c.scratch_arena = &job.sa;
    c.scratch = job.sa.allocator();
    co.takeProgram(c, rs.P);
    c.tables_alloc = a;
    c.r24_sites = &rs.r24;
    c.vm_has_classes = job.vm_has_classes;
    c.app = if (job.app) |ap| try pa.dupe(u8, ap) else null;
    c.app_exports = job.exports;
    job.marks = try co.markProgram(c, a);
    job.check_before = if (residentCheckOn()) try prefix.encode(H, exe, rs.stamps.items, rs.fnames.items, c) else null;
    var undo = Undo{ .rs = rs, .c = c, .marks = &job.marks, .before = job.check_before };
    const nadm = rs.stamps.items.len;
    ph.lap(.restore);

    // the file, and what it loads that the program does not already hold
    const on_top = &job.on_top;
    var held_l = std.ArrayListUnmanaged([]const u8){};
    const root_key = if (replace and src == null) try normalisePath(a, path) else "";
    std.debug.assert(rs.held_norm.items.len == rs.stamps.items.len);
    for (rs.held_norm.items) |key| {
        // replacing a file the program holds reads it again; what IT loads
        // that the program holds stays held
        if (root_key.len > 0 and std.mem.eql(u8, key, root_key)) continue;
        try held_l.append(a, key);
    }
    const held = held_l.items;
    on_top.already_norm = true;
    // code is admitted under a path of its own, so the same name twice is two
    // admissions (a redefinition is still refused), and reported by its name
    const root_path = if (src != null) try std.fmt.allocPrint(pa, "{s}:{d}:{s}", .{ if (job.app != null) "admitapp" else "admitcode", rs.codes + 1, path }) else path;
    // the source lives with the program, whose names are slices of it: a
    // program's own string handed to admitcode may be released after
    on_top.root_src = if (src) |t| try pa.dupe(u8, t) else null;
    try loadUnit(pa, parser, root_path, on_top, true, held);
    if (src != null and on_top.names.items.len > 0) on_top.names.items[0] = path;
    if (on_top.roots.items.len == 0) {
        job.why = keepWhy(rs, undo.done(refuse(rs, at, path, if (on_top.missing > 0) "it cannot be read" else "it is already admitted (Ring loads a file once)", null, &.{})));
        return;
    }
    if (on_top.missing + on_top.scan_bad > 0 or on_top.implicit != null) {
        for (on_top.trees.items) |t| t.deinit();
        on_top.trees.clearRetainingCapacity();
        job.why = keepWhy(rs, undo.done(refuse(rs, at, path, if (on_top.implicit != null)
            "Ring would read an implicit file beside it (C-28)"
        else if (on_top.scan_bad > 0)
            "a file does not scan (an unclosed literal or comment)"
        else
            "a load names a file that cannot be opened", null, &.{})));
        return;
    }

    // the unit: the admitted files hold their places, so every file index
    // baked into admitted code still names the same file
    var roots = std.ArrayListUnmanaged(ts.Node){};
    var paths = std.ArrayListUnmanaged([]const u8){};
    const blank = ts.Node{ .raw = std.mem.zeroes(@TypeOf(on_top.roots.items[0].raw)), .src = "" };
    for (0..nadm) |k| {
        try roots.append(a, blank);
        try paths.append(a, rs.stamps.items[k].path);
    }
    try roots.appendSlice(a, on_top.roots.items);
    try paths.appendSlice(a, on_top.paths.items);
    const srcs = try a.alloc([*]const u8, paths.items.len);
    for (srcs) |*x| x.* = @ptrCast(&no_src);
    for (on_top.roots.items, 0..) |r, k| srcs[nadm + k] = r.src.ptr;
    co.load_srcs = srcs;
    co.load_paths = paths.items;
    defer {
        co.load_srcs = &.{};
        co.load_paths = &.{};
    }

    job.old_funcs = c.funcs.items.len;
    job.old_classes = c.classes.items.len;
    ph.lap(.load);
    c.replacing = replace;
    job.prog = co.compileAdmit(c, roots.items, @intCast(nadm), pa) catch |e| {
        if (e != co.Error.Refused) {
            job.why = keepWhy(rs, undo.done(refuse(rs, at, path, @errorName(e), null, &.{})));
            return;
        }
        job.why = keepWhy(rs, undo.done(refuse(rs, at, path, co.admit_why, c, paths.items)));
        return;
    };
    ph.lap(.compile);
    job.compiled = true;
}

/// A refusal's reason, held where it outlives the compile: `rs.why`, which
/// refuse formats into -- or, when it could not (the reason was too long),
/// copied there. The compiler's own reason is per thread (co.admit_why), and
/// a background compile's thread is gone by the time the reason is raised.
fn keepWhy(rs: *Resident, wo: ?[]const u8) ?[]const u8 {
    const w = wo orelse return null;
    const lo = @intFromPtr(&rs.why);
    if (@intFromPtr(w.ptr) >= lo and @intFromPtr(w.ptr) < lo + rs.why.len) return w;
    const n = @min(w.len, rs.why.len);
    std.mem.copyForwards(u8, rs.why[0..n], w[0..n]);
    return rs.why[0..n];
}

/// The INSTALL half (rung 9): the VM takes what admitCompile compiled, and
/// the admitted top level runs -- on the program's own thread, always.
fn admitInstall(job: *AdmitJob, at: RunAt) !?[]const u8 {
    const H = vmheap;
    const rs = job.rs;
    const m = rs.m;
    const a = job.arena.allocator();
    const c = job.c;
    const prog = job.prog;
    const marks = &job.marks;
    const check_before = job.check_before;
    const path = job.path;
    const src = job.src;
    const replace = job.replace;
    const old_funcs = job.old_funcs;
    const old_classes = job.old_classes;
    const on_top = &job.on_top;
    const ph = &job.ph;
    const timer = &job.timer;
    // what the compile built for the VM's own globals is published HERE, on
    // the program's thread (co.VmOut) -- what it replaces kept first, so the
    // install can tell the tables a first class admission built whole
    const keep = .{
        .dispatch = vm.dispatch,
        .method_tab = vm.method_tab,
        .class_slots = vm.class_slots,
        .attr_from = vm.attr_from,
        .attr_ent = vm.attr_ent,
        .class_konst = vm.class_konst,
        .class_parent = vm.class_parent,
        .fn_owner = vm.fn_owner,
        .acc_get = vm.acc_get,
        .acc_set = vm.acc_set,
    };
    co.publishVm(c);
    // rung 6: where the VM's side stood before the install, for a release
    var rec_vt: [vt_lists.len]usize = undefined;
    inline for (vt_lists, 0..) |f, k| rec_vt[k] = @field(rs.vt, f).items.len;
    const rec_vm = .{ .prog_code = rs.prog_code, .prog_konst = rs.prog_konst, .nfuncs = rs.nfuncs, .file_names = m.file_names.len, .stamps = rs.stamps.items.len, .fnames = rs.fnames.items.len, .main_fn = m.main_fn, .fn_owner = vm.fn_owner.len, .acc = vm.acc_get.len };
    // ---- INSTALL: the VM takes the delta ------------------------------
    // Eval code past the program is cut and its cache forgotten: a string
    // compiled before this admission may have read a name this file now
    // defines as something else.
    m.truncateCode(rs.prog_code);
    m.truncateKonst(rs.prog_konst);
    evalReset();
    std.debug.assert(c.prefix_code == rs.prog_code);
    _ = m.appendCode(prog.code[rs.prog_code..]);
    // the admitted code's `r24` sites, by name: what the next admission's
    // new-global refusal reads (compileAdmit) -- code is never rewritten
    // there, so the list only grows
    for (prog.code[rs.prog_code..], rs.prog_code..) |in, pc| {
        if (in.op != .r24 or in.d < 0) continue;
        const gop = try rs.r24.getOrPut(H, @intCast(in.d));
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.append(H, @intCast(pc));
    }
    // rung 3: the running code's calls to a replaced function now reach the
    // replacement -- one instruction each, rewritten where it stands (the
    // run loop reads the code again after an admission from inside)
    for (c.repatched.items) |site| {
        std.debug.assert(site < rs.prog_code);
        @constCast(m.code.ptr)[site] = prog.code[site];
    }
    // THE VM's TABLES GROW (rung 5): what this admission added is appended
    // to each, the program's own lists never copied again. An earlier
    // instruction keeps its row, file and function -- a replacement rewrites
    // an instruction, never where it came from -- and an earlier function
    // its entry, frame and locals (a replacement is a new function).
    const vt = &rs.vt;
    {
        std.debug.assert(prog.code_base == rs.prog_code and vt.fn_of.items.len == rs.prog_code);
        try vt.fn_of.appendSlice(H, prog.fn_of);
        try vt.rows.appendSlice(H, prog.rows[vt.rows.items.len..]);
        try vt.files.appendSlice(H, prog.files[vt.files.items.len..]);
        m.fn_of = vt.fn_of.items;
        m.rows = vt.rows.items;
        m.files = vt.files.items;
    }
    // constants: appended, pinned as the freeze pins them
    {
        const add = try dupKonst(H, c.konst.items[rs.prog_konst..]);
        for (add) |kv| _ = m.appendKonst(kv);
        H.free(add);
    }
    // names: appended, and the VM's two maps that read them extended rather
    // than dropped (a name's index never changes)
    const old_names = vt.names.items.len;
    for (prog.names[old_names..]) |nm| try vt.names.append(H, try H.dupe(u8, nm));
    m.names = vt.names.items;
    if (m.name_lc) |*nl| {
        for (vt.names.items[old_names..], old_names..) |nm, i| {
            if (nm.len == 0 or nm.len > 250) continue;
            const key = try H.alloc(u8, nm.len);
            for (nm, 0..) |ch, k| key[k] = std.ascii.toLower(ch);
            if (nl.contains(key)) {
                H.free(key);
                continue;
            }
            try nl.put(H, key, @intCast(i));
        }
    }
    // a name's native, once found, is still that name's: the cache grows
    try vt.ncache.appendNTimes(H, null, vt.names.items.len - vt.ncache.items.len);
    m.ncache = vt.ncache.items;
    // globals: grown, every value kept in its slot
    {
        const ng = prog.nglobals + 1;
        const g = try H.alloc(vm.Value, ng);
        @memset(g, vm.Value.nil());
        @memcpy(g[0..m.globals.len], m.globals);
        const gs = try H.alloc(bool, ng);
        @memset(gs, false);
        @memcpy(gs[0..m.globals_set.len], m.globals_set);
        H.free(m.globals);
        H.free(m.globals_set);
        m.globals = g;
        m.globals_set = gs;
        for (prog.global_names[vt.global_names.items.len..]) |nm| try vt.global_names.append(H, try H.dupe(u8, nm));
        vm.global_names = vt.global_names.items;
    }
    // the per-function tables: this admission's functions appended (the
    // compile built them for those alone, fn_local_from counting from the
    // first new function's first local)
    {
        const fb = prog.fn_base;
        // a program with no function yet had one empty row; it goes
        std.debug.assert(fb <= vt.fn_entry.items.len and fb + 1 >= vt.fn_entry.items.len);
        const lbase: u32 = if (fb < vt.fn_local_from.items.len) vt.fn_local_from.items[fb] else 0;
        vt.fn_entry.shrinkRetainingCapacity(fb);
        vt.fn_frame.shrinkRetainingCapacity(fb);
        vt.fn_local_from.shrinkRetainingCapacity(fb);
        std.debug.assert(lbase == vt.local_names.items.len);
        try vt.fn_entry.appendSlice(H, prog.fn_entry);
        try vt.fn_frame.appendSlice(H, prog.fn_frame);
        for (prog.fn_local_from) |x| try vt.fn_local_from.append(H, lbase + x);
        for (prog.local_names) |nm| try vt.local_names.append(H, try H.dupe(u8, nm));
        try vt.local_regs.appendSlice(H, prog.local_regs);
        try vt.local_boxed.appendSlice(H, prog.local_boxed);
        m.fn_entry = vt.fn_entry.items;
        m.fn_frame = vt.fn_frame.items;
        m.fn_local_from = vt.fn_local_from.items;
        m.local_names = vt.local_names.items;
        m.local_regs = vt.local_regs.items;
        m.local_boxed = vt.local_boxed.items;
    }
    // by function: its name, whether it is a method, how many parameters a
    // call by name must pass (0xFF: not counted) -- and by NAME, the function
    // a call compiled before it existed reaches (VM.name_fn: the first plain
    // function of that name, as Ring takes the first definition)
    const old_fns = vt.fn_names.items.len;
    {
        for (prog.funcs[old_fns..], old_fns..) |f, i| {
            std.debug.assert(f.id == i);
            try vt.fn_names.append(H, try H.dupe(u8, f.name));
            try vt.fn_method.append(H, f.owner != null);
            const plain = f.owner == null and f.lambda_at == null and !std.mem.startsWith(u8, f.name, "@@");
            try vt.fn_nparams.append(H, if (plain and f.params.len < 0xFF) @intCast(f.params.len) else 0xFF);
        }
        m.fn_names = vt.fn_names.items;
        m.fn_method = vt.fn_method.items;
        m.fn_nparams = vt.fn_nparams.items;
        try vt.name_fn.appendNTimes(H, vm.NO_FN, prog.names.len - vt.name_fn.items.len);
        // rung 3: a call by name to a replaced function reaches its
        // replacement -- the late link here, `call "f"()` and eval through
        // the name map below (VM.fn_index); the replaced one keeps its own
        // entries for the frames still running it. A replacement is a new
        // function of the name it replaces, so the new functions alone say
        // what moved (rung 5): a name an earlier function held keeps that
        // function, followed to the one that runs now (Compiler.live), and a
        // name none held takes the new one -- a full mapping's answer.
        const nfn = vt.name_fn.items;
        for (prog.funcs[old_fns..], old_fns..) |f, i| {
            if (f.owner != null or f.lambda_at != null or std.mem.startsWith(u8, f.name, "@@")) continue;
            if (f.name_idx >= nfn.len) continue;
            const cur = nfn[f.name_idx];
            nfn[f.name_idx] = prog.funcs[c.live(if (cur == vm.NO_FN) @intCast(i) else cur)].id;
        }
        m.name_fn = nfn;
    }
    // rung 8: by NAME, the class a `new` compiled before it existed reaches
    // (VM.name_cls) -- grown with the names, filled when the admission added
    // a name or a class (a class is never released, and a replaced one keeps
    // its id)
    {
        const had = vt.name_cls.items.len;
        try vt.name_cls.appendNTimes(H, vm.NO_CLS, prog.names.len - had);
        if (prog.names.len > had or c.classes.items.len > old_classes) co.lateClasses(c, vt.name_cls.items);
        m.name_cls = vt.name_cls.items;
    }
    // D31: an app's exports answer by their public names, and an app's late names fall back to the base's
    {
        for (c.new_exports.items) |e| try rs.exports.append(H, .{ .pub_idx = e.pub_idx, .internal = try H.dupe(u8, e.internal), .is_class = e.is_class });
        applyExports(rs, c, vt.name_fn.items, vt.name_cls.items);
        const had = vt.name_up.items.len;
        for (had..prog.names.len) |i| try vt.name_up.append(H, nameUpOf(c, prog.names, i));
        m.name_up = vt.name_up.items;
        if (c.app != null) rs.apps += 1;
    }
    if (replace) {
        for (prog.funcs[0..old_fns]) |f| {
            if (f.replaced_by != null) {
                rs.ever_replaced = true;
                break;
            }
        }
    }
    // the object model's tables: GROWN in place once the VM holds them
    // (rung 5, growClassTables); until then compileFinish built them whole
    // in the arena, and those are copied out -- the dispatch rows into the
    // list they grow in from then on
    if (prog.grow_classes) {
        try growClassTables(rs, c, prog, old_funcs, old_classes);
    } else {
        inline for (.{ "dispatch", "method_tab", "class_slots", "attr_from", "attr_ent", "class_konst", "class_parent", "fn_owner", "acc_get", "acc_set" }) |t| {
            const cur = @field(vm, t);
            const was = @field(keep, t);
            if (cur.ptr != was.ptr) {
                @field(vm, t) = try H.dupe(@TypeOf(cur[0]), cur);
                H.free(was);
            }
        }
        // room for 32 more classes now, while the first classes' admission
        // pays for a copy anyway: a row is as wide as the names (~175 MB of
        // rows at Softanza's size, ~40 ms to move)
        if (vm.dispatch.len > 0 and vt.dispatch.items.len == 0) {
            vt.dispatch = std.ArrayListUnmanaged(u32).fromOwnedSlice(vm.dispatch);
            try vt.dispatch.ensureTotalCapacityPrecise(H, vt.dispatch.items.len + 32 * @as(usize, vm.n_names));
            vm.dispatch = vt.dispatch.items;
        }
    }
    H.free(vm.class_attrs_fn);
    vm.class_attrs_fn = try H.dupe(u32, prog.class_attrs_fn);
    // THE VM's NAME MAP (VM.fn_index), by VM.funcByName's own rules -- a
    // function, not a method; Ring folds case and takes the first definition
    // of a name. The VM builds it on its first use; from then on each
    // admission's functions join it here, a name already mapped followed to
    // the function that runs now (rung 3: the VM is not taught a replacement,
    // the map it keeps carries it). A program that replaced a function before
    // the VM built the map gets it built HERE, the replacements followed.
    const lowKey = struct {
        fn f(nm: []const u8) ![]u8 {
            const key = try vmheap.alloc(u8, nm.len);
            for (nm, 0..) |ch, k| key[k] = std.ascii.toLower(ch);
            return key;
        }
    }.f;
    if (m.fn_index == null) {
        if (rs.ever_replaced) {
            var mp = std.StringHashMapUnmanaged(u32){};
            for (prog.funcs, 0..) |f, i| {
                if (f.name.len == 0 or f.name.len > 250 or f.owner != null) continue;
                const key = try lowKey(f.name);
                if (mp.contains(key)) {
                    H.free(key);
                    continue;
                }
                try mp.put(H, key, prog.funcs[c.live(@intCast(i))].id);
            }
            m.fn_index = mp;
        }
    } else if (m.fn_index) |*fi| {
        for (prog.funcs[old_fns..], old_fns..) |f, i| {
            if (f.name.len == 0 or f.name.len > 250 or f.owner != null) continue;
            const key = try lowKey(f.name);
            if (fi.getPtr(key)) |v| {
                v.* = prog.funcs[c.live(v.*)].id;
                H.free(key);
                continue;
            }
            try fi.put(H, key, prog.funcs[c.live(@intCast(i))].id);
        }
    }
    {
        const old = m.file_names;
        const fn2 = try H.alloc([]const u8, old.len + on_top.names.items.len);
        @memcpy(fn2[0..old.len], old);
        for (on_top.names.items, 0..) |nm, k| fn2[old.len + k] = try H.dupe(u8, nm);
        H.free(old);
        m.file_names = fn2;
    }
    m.main_fn = prog.main_fn;
    // RNXC_RESIDENT_CHECK: each table the VM now holds is the one a whole
    // build of the program gives -- the proof the appends ARE the tables
    if (residentCheckOn()) {
        checkVmTables(m, c, prog, a);
        checkR24Index(rs);
    }

    ph.lap(.install);
    // ---- the program, kept for the next admission ---------------------
    for (on_top.paths.items, 0..) |p, k| {
        const text = on_top.origs.items[k];
        try rs.stamps.append(H, .{ .path = try H.dupe(u8, p), .len = text.len, .hash = image.hashOf(text) });
        try rs.held_norm.append(H, try normalisePath(H, p));
    }
    for (on_top.names.items) |nm| try rs.fnames.append(H, try H.dupe(u8, nm));
    var new_funcs: usize = 0;
    for (c.funcs.items[old_funcs..]) |f| {
        if (f.lambda_at == null and !std.mem.startsWith(u8, f.name, "@@")) new_funcs += 1;
    }
    var replaced: usize = 0;
    if (replace) for (c.funcs.items[0..old_funcs]) |f| {
        if (f.replaced_by) |r| {
            // a class's prologue (rung 4) is not one of its functions
            if (r >= old_funcs and !std.mem.startsWith(u8, f.name, "@@")) replaced += 1;
        }
    };
    const stmts = c.stmts_ok;
    // what the rest needs of `prog`, which points into the program's arena
    const entry: ?u32 = prog.entry_tramp orelse
        (if (prog.main_fn < prog.funcs.len) prog.funcs[prog.main_fn].tramp else null);
    const prog_funcs = prog.funcs.len;
    const prog_nglobals = prog.nglobals;
    // rung 6: can it be released later? Not when it defined a class or a
    // lambda (an object, a closure, could outlive it) or replaced anything
    // (the running code's calls were re-pointed). If it can, where it all
    // stood goes on the stack; if not, nothing under it can be either
    {
        var why: []const u8 = "";
        if (replace) why = "it replaced what the program held";
        if (c.app != null) why = "it admitted an app, whose names other apps may reach by its exports";
        if (c.classes.items.len != old_classes) why = "it defined a class, whose objects could outlive it";
        for (c.funcs.items[old_funcs..]) |f| {
            if (f.lambda_at != null) why = "it defined a lambda, which could outlive it";
        }
        if (why.len == 0) {
            try rs.rel.append(H, .{
                .name = try H.dupe(u8, path),
                .coded = src != null,
                .code = marks.code,
                .fixups = marks.fixups,
                .names = marks.names,
                .globals = marks.globals,
                .konst = marks.konst,
                .funcs = marks.funcs,
                .classes = marks.classes,
                .natives = try H.dupe(u16, marks.natives_copy),
                .counters = marks.counters,
                .prefix_main = marks.prefix_main,
                .called = try H.dupe(u32, c.called_log.items),
                .prog_code = rec_vm.prog_code,
                .prog_konst = rec_vm.prog_konst,
                .nfuncs = rec_vm.nfuncs,
                .file_names = rec_vm.file_names,
                .stamps = rec_vm.stamps,
                .fnames = rec_vm.fnames,
                .main_fn = rec_vm.main_fn,
                .fn_owner = rec_vm.fn_owner,
                .acc = rec_vm.acc,
                .vt = rec_vt,
                .check_before = if (check_before) |b| try H.dupe(u8, b) else null,
            });
        } else {
            for (rs.rel.items) |*r| r.deinit();
            rs.rel.clearRetainingCapacity();
            rs.unreleasable = why;
        }
    }
    // its new functions and classes in the shape a restore would give them,
    // the trees they were read from released, the program moved back
    prefix.freeze(c, old_funcs, old_classes, c.class_repl.items);
    c.prefix_funcs = c.funcs.items.len;
    c.prefix_classes = c.classes.items.len;
    c.prefix_code = c.code.items.len;
    c.prefix_fixups = c.fixups.items.len;
    c.prefix_main = null;
    c.main_fn = null;
    co.takeProgram(rs.P, c);
    if (job.own) {
        // rung 9: the trees released, and the program compacted when due, on
        // the compiling thread while the top level runs here -- nothing below
        // reads the program's arena, and what next does waits (bgQuiet)
        bgTidy(rs, on_top.trees.items);
    } else for (on_top.trees.items) |t| t.deinit();
    on_top.trees.clearRetainingCapacity();
    ph.lap(.save);
    rs.prog_code = prog.code.len;
    rs.prog_konst = vm.konst.len;
    rs.nfuncs = prog_funcs;
    rs.admitted += 1;
    if (src != null) rs.codes += 1;
    const took = timer.read() / std.time.ns_per_ms;
    if (!at.nested) {
        if (replace) {
            vm.outPrint("admitted {s}: {d} function(s), {d} of them replacing, {d} statement(s), {d} ms -- program: {d} function(s), {d} instruction(s), {d} global(s)\n", .{ path, new_funcs, replaced, stmts, took, prog_funcs, rs.prog_code, prog_nglobals });
        } else {
            vm.outPrint("admitted {s}: {d} function(s), {d} statement(s), {d} ms -- program: {d} function(s), {d} instruction(s), {d} global(s)\n", .{ path, new_funcs, stmts, took, prog_funcs, rs.prog_code, prog_nglobals });
        }
    }

    // ---- its top level runs, as a loaded file's does ------------------
    if (entry) |e| {
        // nested: just above the frame that called admitfile, as `.opcall`
        // places an operator's window
        const win: u32 = if (at.nested) at.base + m.frames[at.fsp - 1].size else 0;
        const saved_floor = m.hsp_floor;
        m.hsp_floor = at.hsp;
        _ = m.runFrom(e, win, at.fsp, at.hsp);
        m.hsp_floor = saved_floor;
        if (!at.nested) vm.outFlush();
        if (m.eval_escaped) {
            // its frames' registers are forgotten, not released: a borrow
            // among them was never counted (VM.forgetUnwound's rule)
            var hw: u32 = win;
            var k: u32 = at.fsp;
            while (k < m.esc_fsp) : (k += 1) {
                const own: u32 = if (k + 1 < m.esc_fsp) m.frames[k + 1].base else m.esc_base;
                hw = @max(hw, own + m.frames[k].size);
            }
            var r: u32 = win;
            while (r < hw and r < m.regs.len) : (r += 1) m.regs[r] = vm.Value.nil();
            rs.stopped += 1;
            // nested, the error is left pending: the call raises it
            if (!at.nested) {
                m.eval_escaped = false;
                m.pending = "";
                vm.outPrint("\n         its top level stopped on that error; the program carries on\n", .{});
            }
        }
    }
    ph.lap(.run);
    ph.report(path, rs, job.admit_ns);
    return null;
}


/// A refusal, and the program it left exactly as it was: printed by the
/// driver, with the statements behind it; from inside the program, the
/// reason the call raises with, the first statement named.
fn refuse(rs: *Resident, at: RunAt, path: []const u8, why: []const u8, c: ?*co.Compiler, paths: []const []const u8) []const u8 {
    rs.refused += 1;
    const m = rs.m;
    if (!at.nested) vm.outPrint("refused  {s}: {s}\n         -- program unchanged: {d} function(s), {d} instruction(s), {d} global(s)\n", .{ path, why, rs.nfuncs, rs.prog_code, m.globals.len -| 1 });
    var first: ?co.Refusal = null;
    var first_file: []const u8 = path;
    if (c) |cc| {
        for (cc.refusals.items, 0..) |r, k| {
            // a statement re-read from a copy (F-80) names no file: the
            // admitted root is the likeliest, and the row is the file's
            const fi = cc.fileOfPub(r.src.ptr);
            var fname = std.fs.path.basename(if (fi) |x| (if (x < paths.len) paths[x] else path) else path);
            // code admitted under a path of its own is named as the program named it -- an app's too (D31)
            for ([_][]const u8{ "admitcode:", "admitapp:" }) |pre| {
                if (!std.mem.startsWith(u8, fname, pre)) continue;
                if (std.mem.indexOfScalarPos(u8, fname, pre.len, ':')) |colon| fname = fname[colon + 1 ..];
            }
            if (k == 0) {
                first = r;
                first_file = fname;
            }
            if (at.nested) break;
            if (k == 8) {
                vm.outPrint("         ... and {d} more\n", .{cc.refusals.items.len - 8});
                break;
            }
            vm.outPrint("         {s}:{d}  in {s}  {s}  `{s}`\n", .{ fname, r.row, r.func, r.kind, r.text });
        }
    }
    if (first) |r| return std.fmt.bufPrint(&rs.why, "Error : not admitted: {s}: {s} -- {s}:{d} in {s}: {s} `{s}`", .{ path, why, first_file, r.row, r.func, r.kind, r.text }) catch why;
    return std.fmt.bufPrint(&rs.why, "Error : not admitted: {s}: {s}", .{ path, why }) catch why;
}

/// Free a table dupStrings made: each string, then the array.
fn freeStrings(xs: []const []const u8) void {
    for (xs) |s| vmheap.free(s);
    vmheap.free(xs);
}

/// Forget everything eval built from the program's old tables: its compiler
/// (names, globals and classes are read at init) and its cache, whose code
/// sat past the program and is cut by the admission.
fn evalReset() void {
    if (!g_eval.inited) return;
    var it = g_eval.cache.keyIterator();
    while (it.next()) |k| vmheap.free(k.*);
    g_eval.cache.deinit(vmheap);
    g_eval.cache = .{};
    g_eval.cache_instrs = 0;
    var ci = g_eval.classes.keyIterator();
    while (ci.next()) |k| vmheap.free(k.*);
    g_eval.classes.deinit(vmheap);
    g_eval.classes = .{};
    if (g_eval.ready) {
        g_eval.scratch.deinit();
        if (g_eval.c.eval_parser) |p| p.deinit();
        g_eval.c.names.deinit(vmheap);
        g_eval.c.globals.deinit(vmheap);
    }
    g_eval.inited = false;
    g_eval.ready = false;
    g_eval.depth = 0;
}

var g_arena: ?*std.heap.ArenaAllocator = null;
fn arenaCap() usize {
    return if (g_arena) |a| a.queryCapacity() else 0;
}

/// Bytes the compiler actually ASKED for, as opposed to what the arena
/// reserved. The two are far apart and the difference is not waste by the
/// compiler: ArenaAllocator grows by allocating a new chunk roughly the size
/// of everything before it, so `queryCapacity` climbs in doublings and a
/// single innocent function appears to allocate 197 MB because it happened
/// to be the one that crossed a chunk boundary. Attributing memory to a
/// function on that basis is wrong, and this is what replaces it.
var g_asked: usize = 0;
var g_peak_one: usize = 0;
/// Bytes asked for, split by request size: under 1 KB, under 64 KB, under
/// 1 MB, and 1 MB and over. Small-and-many means per-statement churn; large
/// means an ArrayList doubling and abandoning its old buffer, which in an
/// arena is never reclaimed.
var g_bucket = [_]usize{0} ** 4;
var g_bucket_n = [_]usize{0} ** 4;
/// `RNXC_TRACE_ALLOC=<bytes>` in the environment turns on stack traces for
/// requests of exactly that size. Off unless asked for: it is a tool for
/// answering "who allocates this", not something a census should print.
var g_trace_size: usize = 0;
var g_trace_seen: usize = 0;
var g_in_trace: bool = false;

/// Exact sizes of the small requests, so the 2.8 million of them can be
/// matched to a struct instead of guessed at.
var g_small = [_]usize{0} ** 129;

fn tally(len: usize) void {
    if (len <= 128) g_small[len] += 1;
    const b: usize = if (len < 1024) 0 else if (len < 64 * 1024) 1 else if (len < 1024 * 1024) 2 else 3;
    g_bucket[b] += len;
    g_bucket_n[b] += 1;
}

const CountingAllocator = struct {
    child: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        g_asked += len;
        tally(len);
        if (len > g_peak_one) g_peak_one = len;
        // WHO asks for 128 bytes 600,000 times? A size histogram cannot say,
        // and watching arena capacity attributes it to whichever function
        // crossed a chunk boundary. A stack trace at the site can. Sampled at
        // three points in the run, because the answer may be more than one
        // call site; the guard is set before dumping, since dumping allocates.
        if (g_trace_size != 0 and len == g_trace_size) {
            g_trace_seen += 1;
            const at = g_trace_seen;
            if (at % 25_000 == 0 and !g_in_trace) {
                g_in_trace = true;
                std.debug.print("\n--- {d}-byte request #{d} ---\n", .{ len, at });
                std.debug.dumpCurrentStackTrace(ra);
                g_in_trace = false;
            }
        }
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            g_asked += new_len - buf.len;
            tally(new_len - buf.len);
        }
        return self.child.rawResize(buf, a, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            g_asked += new_len - buf.len;
            tally(new_len - buf.len);
        }
        if (new_len > g_peak_one) g_peak_one = new_len;
        return self.child.rawRemap(buf, a, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
};

/// Flush the program's output before reporting a panic: a crash must not
/// swallow what already ran. See vm.flushForPanic.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ra: ?usize) noreturn {
        vm.flushForPanic();
        std.debug.defaultPanic(msg, ra);
    }
}.f);

pub fn main() !void {
    vm.armFaultReporting();
    // `clock()` counts from here, so it starts near zero the way Ring's
    // does instead of reporting the epoch in milliseconds.
    vm.vm_start_ms = std.time.milliTimestamp();
    vm.seedRandom();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var counter = CountingAllocator{ .child = arena.allocator() };
    const alloc = counter.allocator();
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_POISON")) |v| {
        vm.poison_on = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    vmheap = vm.vmHeap();
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_VERBOSE")) |v| {
        g_verbose = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_TRACE_NATIVE")) |_| { vm.g_trace_native = true; } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_WATCHDOG")) |v| {
        vm.g_watchdog_s = std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
    } else |_| {}
    // ZIP is built IN, not loaded. Ring reaches it through an
    // extension DLL because that is how Ring reaches natives at all;
    // commitment 5 says this is one binary, so the twelve names are
    // published here, through the same table `rpp_init` fills.
    zip.registerAll(vmheap);
    // a server's socket, for a program that holds its own request loop
    // (HaroServer's host, under `rnxc resident`)
    httpd.registerAll(vmheap);
    native.register("shutdown", &ringShutdown);
    if (vm.poison_on) std.debug.print("note: POISONING HEAP -- freed memory is 0xDD and never reused\n", .{});
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_TRACE_RET")) |v| {
        vm.trace_ret_name = v;
    } else |_| {}
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "RNXC_TRACE_ALLOC")) |v| {
        g_trace_size = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
    } else |_| {}
    // So the census can report WHERE its memory went, phase by phase.
    g_arena = &arena;
    co.capFn = &arenaCap;

    var argv = try std.process.argsAlloc(alloc);

    // `rnxc <file.ring> [args...]` means `rnxc exec <file.ring> [args...]`.
    //
    // Ring is invoked as `ring script.ring args...`, and the estate spawns
    // ITSELF that way: Softanza's six _RingExecutable() methods hunt
    // sysargv for the interpreter and re-launch it on a generated script
    // (stzLoadDriver spawns an HTTP target and N load drivers this way).
    // A subcommand in argv[1] makes that spawn shape impossible, so the
    // one command every Ring program already knows how to say has to
    // work. Found 2026-09-12 from perf/driven_load.
    //
    // Only when argv[1] is not a subcommand and names a .ring file, so no
    // existing invocation changes meaning.
    if (argv.len >= 2 and !isSubcommand(argv[1]) and
        std.mem.endsWith(u8, argv[1], ".ring"))
    {
        var re = std.ArrayListUnmanaged([:0]u8){};
        try re.append(alloc, argv[0]);
        try re.append(alloc, try alloc.dupeZ(u8, "exec"));
        try re.appendSlice(alloc, argv[1..]);
        argv = re.items;
    }

    // `rnxc dump --json <file>` (or `rnxc dump <file> --json`): the parse of ONE file, lossless -- every node with its byte span, every
    // gap, every token the grammar hides (src/dumpjson.zig has the format). It follows no load and compiles nothing.
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "dump")) {
        const flag_first = std.mem.eql(u8, argv[2], "--json");
        if (flag_first or std.mem.eql(u8, argv[3], "--json")) {
            const jparser = ts.Parser.init();
            defer jparser.deinit();
            var jbuf: [64 * 1024]u8 = undefined;
            var jw = std.fs.File.stdout().writer(&jbuf);
            const ok = try dumpjson.exportFile(alloc, jparser, if (flag_first) argv[3] else argv[2], &jw.interface);
            try jw.interface.flush();
            if (!ok) std.process.exit(1);
            return;
        }
    }

    // `rnxc fmt [--write | --check] <file.ring>`: the canonical text of a Ring file (src/fmt.zig). It follows no load and compiles nothing.
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "fmt")) {
        var fargs = std.ArrayListUnmanaged([]const u8){};
        for (argv[2..]) |a| try fargs.append(alloc, a);
        std.process.exit(fmt.run(alloc, fargs.items));
    }

    // `rnxc resident <file.ring>...`: ONE program, each file admitted into it
    // while it runs, or refused whole (residentMain).
    if (argv.len >= 3 and std.mem.eql(u8, argv[1], "resident")) {
        var sa = std.ArrayListUnmanaged([]const u8){};
        try sa.append(alloc, argv[0]);
        for (argv[2..]) |x| try sa.append(alloc, x);
        g_sysargv = sa.items;
        const rparser = ts.Parser.init();
        defer rparser.deinit();
        co.exe_dir = exeDir(alloc);
        try residentMain(alloc, rparser, argv[2..]);
        return;
    }

    if (argv.len < 3) {
        std.debug.print("usage: rnxc <file.ring>            run it, as `ring` does\n", .{});
        std.debug.print("       rnxc <command> <file.ring>  exec, dis, dump [--json], fmt, graph, census,\n", .{});
        std.debug.print("                                   check, call, time, poison,\n", .{});
        std.debug.print("                                   migrate, shadows, attrs\n", .{});
        std.debug.print("       rnxc resident <file.ring>...  one program, each file admitted into it\n", .{});
        std.debug.print("                                     (--replace <file>: it may redefine a function it holds)\n", .{});
        return;
    }

    // [exe, script, args...]: argv[1] is the subcommand, which Ring has no
    // equivalent of, so it is the one thing left out.
    {
        var sa = std.ArrayListUnmanaged([]const u8){};
        try sa.append(alloc, argv[0]);
        try sa.append(alloc, argv[2]);
        if (argv.len > 3) try sa.appendSlice(alloc, argv[3..]);
        g_sysargv = sa.items;
    }

    const parser = ts.Parser.init();
    defer parser.deinit();

    // COMPILATION IS A STEP, AND IT MAY BE DONE ALREADY.
    //
    // Before a single file is read: if THIS binary compiled THIS root from
    // these exact sources before, the answer is on disk. Proving that costs
    // one read of each source (0.07 s on the Softanza unit) against the
    // 7.28 s of read, parse and compile it stands in for. Anything that does
    // not add up -- another build, a changed file, a short write -- is a
    // miss, and a miss is just what happened before this existed.
    var img_path: ?[]const u8 = null;
    if (std.process.getEnvVarOwned(alloc, "RNXC_IMAGE")) |v| {
        image.explain = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "RNXC_IMAGE_SEPKONST")) |v| {
        image.separate_konst = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "RNXC_NOINPLACE")) |v| {
        vm.no_inplace = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "RNXC_TRACE_ADD")) |v| {
        vm.trace_add = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "RNXC_LIFT_TRACE")) |v| {
        lift.trace = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    var want_onto = false;
    if (std.process.getEnvVarOwned(alloc, "RNXC_ONTO")) |v| {
        want_onto = !(v.len == 0 or std.mem.eql(u8, v, "0"));
    } else |_| {}
    // C-28: before any image is trusted -- an image built before a syntax
    // file appeared must not run past it. Four existence checks.
    if (std.mem.eql(u8, argv[1], "exec")) {
        if (implicitAtStart(alloc, argv[2])) |im| refuseImplicit(im);
    }
    if (std.mem.eql(u8, argv[1], "exec") and image.enabled(alloc)) {
        const root_abs = std.fs.cwd().realpathAlloc(alloc, argv[2]) catch argv[2];
        // From the VM's heap, NOT the arena: this path is read again after
        // the freeze has thrown the arena away, and an arena-allocated one
        // is a dangling pointer by then (found the hard way -- the write
        // took an access violation on a path that had already been freed).
        img_path = image.pathFor(vmheap, root_abs);
        if (img_path) |p| {
            if (image.load(vmheap, p, image.ExeStamp.ofSelf(alloc))) |parts| {
                try runImage(parts, argv[2]);
                return;
            }
        }
    }

    // THE LIBRARY, COMPILED ONCE AND KEPT.
    //
    // The image above answers "this program again". This answers "another
    // program, the same library" -- which is every file of a sweep. It has
    // to happen BEFORE the load graph is walked, because walking it is 3.38
    // of the 7.28 seconds. So: parse the root ALONE, see what it loads
    // first, and look for a prefix built from that.
    //
    // The prefix is built on purpose (`rnxc prefix <library.ring>`), never
    // as a side effect of a run: a 60 MB file per library is not something
    // to write behind someone's back.
    var pre_c: ?*co.Compiler = null;
    var pre_stamps = std.ArrayListUnmanaged(image.Stamp){};
    var pre_names = std.ArrayListUnmanaged([]const u8){};
    var on_top = Unit{};
    if (std.mem.eql(u8, argv[1], "exec") and image.enabled(alloc)) {
        pre_c = tryPrefix(alloc, parser, argv[2], &pre_stamps, &pre_names, &on_top);
    }

    // The whole `load` graph, not just the named file. A Softanza module
    // calls its siblings, so compiling one file alone can only ever refuse
    // them -- which is exactly what the 64% census was measuring.
    var unit = Unit{};
    unit.lift = !(std.mem.eql(u8, argv[1], "dump") or std.mem.eql(u8, argv[1], "migrate") or
        std.mem.eql(u8, argv[1], "attrs") or std.mem.eql(u8, argv[1], "shadows"));
    if (std.mem.eql(u8, argv[1], "check") and argv.len > 3) {
        var keys = std.ArrayListUnmanaged([]const u8){};
        var with = std.ArrayListUnmanaged([]const u8){};
        for (argv[3..]) |a| {
            if (!std.mem.startsWith(u8, a, "--subst=")) continue;
            const spec = a["--subst=".len..];
            const eq = std.mem.lastIndexOfScalar(u8, spec, '=') orelse {
                std.debug.print("rnxc check: --subst wants <file>=<text file>, got {s}\n", .{a});
                std.process.exit(2);
            };
            try keys.append(alloc, try normalisePath(alloc, spec[0..eq]));
            try with.append(alloc, spec[eq + 1 ..]);
        }
        unit.subst_keys = keys.items;
        unit.subst_with = with.items;
    }
    var pre_start: u32 = 0;
    var t_load = try std.time.Timer.start();
    if (pre_c != null) {
        // The library is already compiled, so only this file is parsed. The
        // unit is assembled from the prefix's own manifest: the library's
        // paths, in the order it was built in, and this file last -- so the
        // file indices already baked into the library's instructions still
        // name the same files, and this file gets the next index.
        const nlib = pre_stamps.items.len;
        for (pre_stamps.items) |st| try unit.paths.append(alloc, st.path);
        try unit.paths.appendSlice(alloc, on_top.paths.items);
        try unit.names.appendSlice(alloc, pre_names.items);
        try unit.names.appendSlice(alloc, on_top.names.items);
        // roots stays PARALLEL to paths: the library entries are never
        // walked (the splice starts past them) but loadTarget resolves a
        // load to an index in this array, and a library load has to land on
        // one that is already marked done rather than on a real file.
        for (0..nlib) |_| try unit.roots.append(alloc, ts.Node{ .raw = std.mem.zeroes(@TypeOf(on_top.roots.items[0].raw)), .src = "" });
        try unit.roots.appendSlice(alloc, on_top.roots.items);
        try unit.trees.appendSlice(alloc, on_top.trees.items);
        for (0..nlib) |_| try unit.origs.append(alloc, "");
        try unit.origs.appendSlice(alloc, on_top.origs.items);
        const srcs = try alloc.alloc([*]const u8, unit.paths.items.len);
        for (srcs) |*x| x.* = @ptrCast(&no_src);
        for (on_top.roots.items, 0..) |r, k| srcs[nlib + k] = r.src.ptr;
        co.load_srcs = srcs;
        pre_start = @intCast(nlib);
    } else {
        try loadUnit(alloc, parser, argv[2], &unit, std.mem.eql(u8, argv[1], "dump"), &.{});
    }
    // F-101: a program with a load Ring cannot open does not run on Ring;
    // it does not run here either. On the prefix path the files on top are
    // what was walked (`rnxc prefix` refuses a library with a hole).
    if (std.mem.eql(u8, argv[1], "exec") and
        (if (pre_c != null) on_top.missing + on_top.scan_bad else unit.missing + unit.scan_bad) > 0)
        refuseMissingLoads(alloc, parser, argv[2]);
    // C-28: a syntax file beside a loaded file (the root's was checked above)
    if (std.mem.eql(u8, argv[1], "exec")) {
        if (if (pre_c != null) on_top.implicit else unit.implicit) |im| refuseImplicit(im);
    }
    if (std.mem.eql(u8, argv[1], "prefix")) {
        if (unit.implicit) |im| {
            std.debug.print("prefix: NOT written -- Ring would read {s} before {s}, and Ring++ reads none of Ring's implicit files (C-28)\n", .{ im.path, im.of });
            std.process.exit(1);
        }
    }
    // ...and a prefix is never built from a library Ring would refuse.
    if (std.mem.eql(u8, argv[1], "prefix") and unit.scan_bad > 0) {
        std.debug.print("prefix: NOT written -- {d} file(s) in this library do not scan (an unclosed literal or comment), and Ring refuses every program that loads one\n", .{unit.scan_bad});
        std.process.exit(1);
    }
    if (std.mem.eql(u8, argv[1], "prefix") and unit.missing > 0) {
        std.debug.print("prefix: NOT written -- {d} load(s) in this library name a file that cannot be opened, and Ring refuses every program that loads it\n", .{unit.missing});
        std.process.exit(1);
    }
    const t_load_ns = t_load.read();
    // The compiler resolves each `load` back to the root it names, so it
    // can run their top levels in Ring's order rather than in queue order.
    co.load_paths = unit.paths.items;
    if (pre_c == null) {
        const srcs = try alloc.alloc([*]const u8, unit.roots.items.len);
        for (unit.roots.items, 0..) |r, i| srcs[i] = r.src.ptr;
        co.load_srcs = srcs;
    }
    co.exe_dir = exeDir(alloc); // the splice resolves loads the same way this does
    if (unit.roots.items.len == 0) {
        std.debug.print("nothing parsed\n", .{});
        return;
    }
    const tree = unit.trees.items[0];

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    const w = &fw.interface;

    if (std.mem.eql(u8, argv[1], "dump")) {
        if (tree.root().hasError()) std.debug.print("NOTE: tree contains errors\n", .{});
        try dump(tree.root(), 0, w);
        try w.flush();
        return;
    }

    // `rnxc graph <root.ring>` -- THE RESOLVED GRAPH (L2, haro/CODEGRAPH.md rung 4) of the load unit as the code-graph line protocol: the
    // classes, methods and functions, and the calls the compiler bound to one target or could only dispatch by name (src/graph.zig).
    if (std.mem.eql(u8, argv[1], "graph")) {
        const gd = co.graphData(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        const gs = try graph.print(alloc, gd, unit.roots.items, unit.paths.items, w);
        try w.flush();
        std.debug.print("graph: {d} file(s), {d} class(es), {d} method(s), {d} function(s); {d} static and {d} dynamic call edge(s); {d} function(s) the compiler could not finish\n", .{
            gs.files, gs.classes, gs.methods, gs.functions, gs.static_edges, gs.dynamic_edges, gs.poisoned,
        });
        return;
    }

    // `rnxc prefix <library.ring>` -- COMPILE THE LIBRARY AND KEEP IT.
    //
    // Written on purpose, once, rather than as a side effect of running
    // something: the file is tens of megabytes and it belongs to whoever
    // asked for it. Afterwards every file whose first statement loads this
    // library starts from here instead of from 613 parse trees.
    if (std.mem.eql(u8, argv[1], "prefix")) {
        const c = try alloc.create(co.Compiler);
        c.* = .{ .alloc = alloc, .lenient = true };
        var sa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        c.scratch_arena = &sa;
        c.scratch = sa.allocator();
        co.compilePrefixWhole(c, unit.roots.items, alloc) catch |e| {
            co.reportFailure(e);
            return;
        };
        const abs = std.fs.cwd().realpathAlloc(alloc, argv[2]) catch argv[2];
        const p = prefix.pathFor(alloc, abs) orelse {
            std.debug.print("no cache directory: set RNXC_CACHE\n", .{});
            return;
        };
        // ABSOLUTE paths: this list is read back from wherever the next
        // program happens to run, and `../../stzBase.ring` means nothing
        // two directories away.
        var stamps = try alloc.alloc(image.Stamp, unit.roots.items.len);
        for (unit.roots.items, 0..) |_, i| {
            const rp = unit.paths.items[i];
            stamps[i] = .{
                .path = std.fs.cwd().realpathAlloc(alloc, rp) catch rp,
                .len = unit.origs.items[i].len,
                .hash = image.hashOf(unit.origs.items[i]),
            };
        }
        // The parse trees are the compiler's, and this compile is over.
        for (unit.trees.items) |t| t.deinit();
        unit.trees.clearRetainingCapacity();
        prefix.save(alloc, p, image.ExeStamp.ofSelf(alloc), stamps, unit.names.items, c) catch |e| {
            std.debug.print("could not write the prefix: {s}\n", .{@errorName(e)});
            return;
        };
        const sz = blk: {
            const f = std.fs.cwd().openFile(p, .{}) catch break :blk 0;
            defer f.close();
            const st = f.stat() catch break :blk 0;
            break :blk st.size;
        };
        try w.print("prefix: {d} file(s), {d} function(s), {d} class(es), {d:.1} MB\n", .{
            unit.roots.items.len,              c.funcs.items.len, c.classes.items.len,
            @as(f64, @floatFromInt(sz)) / 1e6,
        });
        try w.print("   {s}\n", .{p});
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "dis")) {
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        try disasm(prog, w);
        try w.flush();
        return;
    }

    // `rnxc exec <file.ring>` -- RUN the file's top level, the way Ring
    // does when it loads it.
    //
    // Every other mode here measures COMPILING. The census counts
    // statements that compile, `usable` counts functions whose body
    // compiled, and both called a program healthy while `"a" + "b"`
    // compiled into a panic. Nothing executed anything at scale, so
    // nothing could have noticed. This executes.
    if (std.mem.eql(u8, argv[1], "exec")) {
        // THE LIBRARY COMPILED ONCE, THE FILE COMPILED ON TOP.
        //
        // 613 of the 614 files in a Softanza test's unit are the library,
        // and they are the same 613 for every test in the estate. `RNXC_ONTO`
        // compiles them as a PREFIX and this file on top of it -- in ONE
        // process here, which is slower than compiling the unit whole
        // (everything is parsed and the library is collected either way) and
        // is how the two paths are compared. What it proves is the
        // SEMANTICS; the saving arrives when the prefix comes from a file.
        var prefix_used = false;
        const prog = blk: {
            if (pre_c) |c| {
                if (co.compileOnto(c, unit.roots.items, pre_start, alloc)) |p| {
                    prefix_used = true;
                    break :blk p;
                } else |e| {
                    if (e != co.Error.PrefixInapplicable) {
                        co.reportFailure(e);
                        return;
                    }
                    // Rare, and it costs the parse of one file: everything
                    // below is the path taken before prefixes existed.
                    status("onto: the prefix does not apply here ({s}); compiling whole\n", .{co.prefix_blocked_by});
                    unit = Unit{};
                    try loadUnit(alloc, parser, argv[2], &unit, false, &.{});
                    if (unit.missing > 0) refuseMissingLoads(alloc, parser, argv[2]);
                    co.load_paths = unit.paths.items;
                    const srcs = try alloc.alloc([*]const u8, unit.roots.items.len);
                    for (unit.roots.items, 0..) |r, i| srcs[i] = r.src.ptr;
                    co.load_srcs = srcs;
                    pre_stamps.clearRetainingCapacity();
                    break :blk co.compileLenient(alloc, unit.roots.items) catch |e2| {
                        co.reportFailure(e2);
                        return;
                    };
                }
            }
            if (want_onto and unit.roots.items.len > 1) {
                var pc = try alloc.create(co.Compiler);
                pc.* = .{ .alloc = alloc, .lenient = true };
                var sa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                pc.scratch_arena = &sa;
                pc.scratch = sa.allocator();
                if (co.compilePrefix(pc, unit.roots.items, alloc)) |_| {
                    if (co.compileOnto(pc, unit.roots.items, 0, alloc)) |p| {
                        prefix_used = true;
                        break :blk p;
                    } else |e| {
                        if (e != co.Error.PrefixInapplicable) {
                            co.reportFailure(e);
                            return;
                        }
                        std.debug.print("onto: the prefix does not apply here ({s} is defined by both, or is called by the library); compiling whole\n", .{co.prefix_blocked_by});
                    }
                } else |e| {
                    co.reportFailure(e);
                    return;
                }
            }
            break :blk co.compileLenient(alloc, unit.roots.items) catch |e| {
                co.reportFailure(e);
                return;
            };
        };
        // A file with NO top-level statement is not an empty program: Ring
        // calls Main(), and compileFinish builds an entry that does. `mf`
        // is read below only for its trampoline -- which the entry
        // overrides -- and for the poison flags of the code that runs, so
        // the function the entry runs is the one that answers them.
        const mf = prog.find(co.MAIN) orelse blk: {
            if (prog.entry_tramp != null) {
                if (prog.find("main")) |um| break :blk um;
            }
            status("no top-level code in this file\n", .{});
            return;
        };
        // rnxc's OWN status goes to stderr, now that stdout carries the
        // program's output the way `ring script.ring` does. A caller
        // capturing that output must not find our chatter mixed into it --
        // and since 2026-10-16 it is printed only under RNXC_VERBOSE, because
        // a terminal shows stderr too (see `status`).
        status("files {d}   functions+methods {d}{s}\n", .{ unit.roots.items.len, prog.funcs.len, if (prefix_used) "   (library as a prefix)" else "" });
        // With a prefix there are TWO top levels -- the library's and this
        // file's -- and either can carry a refusal the note has to name.
        var tl_own = mf.poisoned_own;
        var tl_poisoned = mf.poisoned;
        for (prog.funcs) |f| {
            if (!std.ascii.eqlIgnoreCase(f.name, co.MAIN)) continue;
            tl_own = tl_own or f.poisoned_own;
            tl_poisoned = tl_poisoned or f.poisoned;
        }
        if (tl_own) {
            // A refused statement in the top level is NOT a reason to run
            // nothing. Every refusal compiles to a trap that raises where
            // the statement stood (the `refusal raises` gate step), so the
            // statements before it run and the program stops exactly
            // there -- which is what Ring does with a line it cannot
            // execute. Declining the whole file printed no output at all
            // where Ring printed eleven lines and then its error, and it
            // hid which statement was at fault behind a summary
            // (2026-09-12, reactive/62_reactive_timer_surface).
            std.debug.print("note: a statement in the top level did not compile. It runs to\n", .{});
            std.debug.print("      that statement and stops there, as Ring stops at a line it\n", .{});
            std.debug.print("      cannot execute. Nothing past it is certified correct.\n", .{});
        } else if (tl_poisoned) {
            // Poisoned by SPREAD, not by its own body. The spread rule is a
            // correctness guarantee for shipping; for measuring how far the
            // program gets it is the wrong gate, so this runs anyway and
            // says plainly what that means.
            std.debug.print("note: the top level's own body compiled, but it calls functions\n", .{});
            std.debug.print("      that did not. Running it measures how far it gets, and a\n", .{});
            std.debug.print("      result it produces is NOT certified correct.\n", .{});
        }
        const regs = try alloc.alloc(vm.Value, 65536);
        @memset(regs, vm.Value.nil());
        const frames = try alloc.alloc(vm.Frame, 4096);
        // What Ring's error report needs: function names and kinds, and
        // each file as Ring prints it -- the root as typed, a loaded file
        // as the folder its load was resolved against, the platform's
        // separator and the load AS WRITTEN (F-111: `...\file\stzJsonFuncs.ring`
        // for `load "stzJsonFuncs.ring"`). This was the real path of the
        // file's directory, "/" and its name, which is the same string only
        // when the load names one folder and a file (`C:\...\el\sub/dep.ring`,
        // the shape it was measured on).
        const fn_names = try alloc.alloc([]const u8, prog.funcs.len);
        const fn_method = try alloc.alloc(bool, prog.funcs.len);
        for (prog.funcs, 0..) |f, i| {
            fn_names[i] = f.name;
            fn_method[i] = f.owner != null;
        }
        const file_names = try alloc.alloc([]const u8, unit.paths.items.len);
        for (unit.paths.items, 0..) |p, i| {
            // Ring names the file given on the command line exactly as it
            // was TYPED, and every other file by the real path of its
            // directory. That was written as "index 0" -- true until a
            // PREFIX put 612 library files in front of it, after which every
            // report named the root by its absolute path instead.
            if (i == pre_start) {
                file_names[i] = p;
                continue;
            }
            if (i < unit.names.items.len) {
                file_names[i] = unit.names.items[i];
                continue;
            }
            const dir = std.fs.path.dirname(p) orelse ".";
            const real = std.fs.cwd().realpathAlloc(alloc, dir) catch dir;
            file_names[i] = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ real, std.fs.path.basename(p) });
        }
        // THE PARSE TREES ARE THE COMPILER'S, AND COMPILATION IS OVER.
        //
        // 613 of them, and they are the largest single thing this process
        // owns -- around 230 MB of the footprint, held in tree-sitter's own
        // malloc rather than the arena. Nothing the VM reaches touches a
        // node: the names, the constants and the file names it reports are
        // all slices into the SOURCE text, which stays, and `rows`/`files`/
        // `fn_of` are plain integer arrays built during compilation.
        //
        // Freed here rather than at exit because perf/engine_senses and
        // perf/metrics_monitor measure the runtime's resident size WHILE the
        // program runs, and a compiler's scaffolding standing in that number
        // is not a measurement of the runtime (2026-09-13).
        for (unit.trees.items) |t| t.deinit();
        unit.trees.clearRetainingCapacity();

        // COMPILATION ENDS HERE.
        //
        // Everything the VM reads is copied into the VM's own heap and the
        // compiler's arena is then thrown away whole. That arena holds 303 MB
        // on the Softanza unit -- 45,306 function records with their locals,
        // statement and call lists, the class tables, the refusals, the source
        // text -- against a runtime image of about 40 MB. None of the rest is
        // reachable from a running program, and an arena cannot give back a
        // part of itself, so the only way to stop paying for it is to stop
        // holding it.
        //
        // Every slice below is copied, not borrowed, because after the reset
        // any pointer into the arena is dangling -- including the bytes that
        // constants and names point at, which live in the SOURCE text.
        const H = vmheap;
        // A program built on a prefix starts at the entry that runs the
        // library'''s top level and then this file'''s; without one, @@main'''s
        // own trampoline is the entry, as it always was.
        const main_tramp = prog.entry_tramp orelse mf.tramp;
        const nglobals = prog.nglobals;
        const main_fn = prog.main_fn;
        const poisoned_own = mf.poisoned_own;
        const poisoned = mf.poisoned;

        const f_code = try H.dupe(vm.Instr, prog.code);
        const f_rows = try H.dupe(u32, prog.rows);
        const f_files = try H.dupe(u16, prog.files);
        const f_fn_of = try H.dupe(u32, prog.fn_of);
        const f_fn_entry = try H.dupe(u32, prog.fn_entry);
        const f_fn_frame = try H.dupe(u8, prog.fn_frame);
        const f_fn_method = try H.dupe(bool, fn_method);
        const f_names = try dupStrings(H, prog.names);
        vm.global_names = try dupStrings(H, prog.global_names);
        const f_fn_names = try dupStrings(H, fn_names);
        const f_file_names = try dupStrings(H, file_names);
        g_sysargv = try dupStrings(H, g_sysargv);

        // The per-class and per-name tables the object model dispatches on.
        vm.dispatch = try H.dupe(u32, vm.dispatch);
        vm.method_tab = try H.dupe(vm.MethodEnt, vm.method_tab);
        vm.class_slots = try H.dupe(u32, vm.class_slots);
        vm.attr_from = try H.dupe(u32, vm.attr_from);
        vm.attr_ent = try H.dupe(vm.AttrEnt, vm.attr_ent);
        vm.class_konst = try H.dupe(u32, vm.class_konst);
        vm.class_parent = try H.dupe(u16, vm.class_parent);
        vm.fn_owner = try H.dupe(u16, vm.fn_owner);
        vm.acc_get = try H.dupe(u32, vm.acc_get);
        vm.acc_set = try H.dupe(u32, vm.acc_set);
        vm.class_attrs_fn = try H.dupe(u32, prog.class_attrs_fn);
        // eval's view of every function's locals (F-72)
        const f_local_from = try H.dupe(u32, prog.fn_local_from);
        const f_local_names = try dupStrings(H, prog.local_names);
        const f_local_regs = try H.dupe(u8, prog.local_regs);
        const f_local_boxed = try H.dupe(bool, prog.local_boxed);
        vm.konst = try dupKonst(H, vm.konst);

        const f_globals = try H.alloc(vm.Value, nglobals + 1);
        const f_gset = try H.alloc(bool, nglobals + 1);
        @memset(f_gset, false);
        const f_handlers = try H.alloc(vm.Handler, 256);
        const f_regs = try H.dupe(vm.Value, regs);
        const f_frames = try H.dupe(vm.Frame, frames);

        // THE MANIFEST, taken while the sources are still in hand: each
        // file's path and a hash of the bytes it was compiled from. It has
        // to be gathered here -- after the reset neither the paths nor the
        // source text exists, and the hash is free now because the bytes are
        // already in memory.
        var stamps: []image.Stamp = &.{};
        if (img_path != null) {
            if (pre_stamps.items.len > 0) {
                // The prefix verified the library file by file on the way
                // in; that IS the manifest, and this file is the one it
                // does not have.
                stamps = try H.alloc(image.Stamp, pre_stamps.items.len + 1);
                for (pre_stamps.items, 0..) |st, i| {
                    stamps[i] = .{ .path = try H.dupe(u8, st.path), .len = st.len, .hash = st.hash };
                }
                const rs = unit.origs.items[unit.origs.items.len - 1];
                stamps[pre_stamps.items.len] = .{
                    .path = try H.dupe(u8, argv[2]),
                    .len = rs.len,
                    .hash = image.hashOf(rs),
                };
            } else {
                const n = @min(unit.paths.items.len, unit.roots.items.len);
                stamps = try H.alloc(image.Stamp, n);
                for (0..n) |i| {
                    const src = unit.origs.items[i];
                    stamps[i] = .{
                        .path = try H.dupe(u8, unit.paths.items[i]),
                        .len = src.len,
                        .hash = image.hashOf(src),
                    };
                }
            }
        }

        _ = arena.reset(.free_all);
        // Nothing below may read `prog`, `unit`, `mf` or anything else the
        // arena owned. The scalars above were taken while it was still alive.
        // The compiler's own file tables were arena slices too, and the eval
        // compiler runs from here on: they are emptied so nothing can walk
        // them by accident (the first cold-path eval did, and faulted).
        co.load_srcs = &.{};
        co.load_paths = &.{};

        // COMPILATION HAS ENDED, so write down what it produced. Only on a
        // miss -- this line is not reached when the image was used -- and
        // failure to write is silent on purpose: an unwritable cache
        // directory must cost a program nothing but the time it already
        // spent.
        if (img_path) |ip| {
            image.save(H, ip, image.ExeStamp.ofSelf(H), stamps, .{
                .code = f_code,
                .rows = f_rows,
                .files = f_files,
                .fn_of = f_fn_of,
                .fn_entry = f_fn_entry,
                .fn_frame = f_fn_frame,
                .fn_method = f_fn_method,
                .names = f_names,
                .fn_names = f_fn_names,
                .file_names = f_file_names,
                .dispatch = vm.dispatch,
                .method_tab = vm.method_tab,
                .class_slots = vm.class_slots,
                .attr_from = vm.attr_from,
                .attr_ent = vm.attr_ent,
                .global_names = vm.global_names,
                .class_konst = vm.class_konst,
                .class_parent = vm.class_parent,
                .fn_owner = vm.fn_owner,
                .fn_local_from = f_local_from,
                .local_names = f_local_names,
                .local_regs = f_local_regs,
                .local_boxed = f_local_boxed,
                .class_attrs_fn = @constCast(vm.class_attrs_fn),
                .acc_get = @constCast(vm.acc_get),
                .acc_set = @constCast(vm.acc_set),
                .konst = vm.konst,
                .fn_masks = vm.fn_masks,
                .main_tramp = main_tramp,
                .nglobals = @intCast(nglobals),
                .main_fn = main_fn,
                .n_names = vm.n_names,
                .poisoned_own = poisoned_own,
                .poisoned = poisoned,
            }) catch {};
        }

        var m = vm.VM{
            .code = f_code,
            .regs = f_regs,
            .frames = f_frames,
            .alloc = H,
            .argv = g_sysargv,
            .names = f_names,
            .globals = f_globals,
            .globals_set = f_gset,
            .handlers = f_handlers,
            .fn_entry = f_fn_entry,
            .fn_frame = f_fn_frame,
            .fn_local_from = f_local_from,
            .local_names = f_local_names,
            .local_regs = f_local_regs,
            .local_boxed = f_local_boxed,
            .eval_hook = &evalHook,
            .rows = f_rows,
            .files = f_files,
            .fn_of = f_fn_of,
            .fn_names = f_fn_names,
            .fn_method = f_fn_method,
            .file_names = f_file_names,
            .main_fn = main_fn,
        };
        @memset(m.globals, vm.Value.nil());
        status("running the top level...\n", .{});
        vm.armWatchdog();
        _ = m.run(main_tramp);
        // Reached only if the VM did not panic or exit. The program's stdout
        // is flushed FIRST, so our completion line cannot overtake the last
        // thing the program printed.
        vm.outFlush();
        status("TOP LEVEL RAN TO COMPLETION\n", .{});
        return;
    }

    // `rnxc poison <file.ring>` -- which refusals are load-bearing.
    //
    // 98% of statements compile and 36% of functions are usable, so the
    // constraint is not coverage but propagation. This ranks the own-body
    // failures by how many functions each one would free, greedily, so the
    // next piece of work is chosen by leverage instead of by frequency.
    if (std.mem.eql(u8, argv[1], "poison")) {
        const prog = co.compileRanked(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        const total = prog.funcs.len;
        const ok = prog.usableCount();
        try w.print("files {d}   functions+methods {d}\n", .{ unit.roots.items.len, total });
        if (total > 0) {
            try w.print("usable {d} ({d}%)   unusable {d}   roots {d}\n\n", .{
                ok, ok * 100 / total, total - ok, prog.poisoned_direct,
            });
        }

        // By CONSTRUCT first: this is the number that chooses the work.
        // Eleven separate roots all fail on `classname()`, and a function
        // held by two of them is freed by neither alone -- so ranking roots
        // one at a time understates the construct that unlocks them.
        var gcum: u32 = 0;
        try w.print("BY CONSTRUCT -- build this, free this many:\n\n", .{});
        for (prog.ranking.groups, 0..) |g, i| {
            gcum += g.unlocked;
            try w.print("{d:>3}. {s:<28} +{d:<6}  running {d}   ({d} root{s})\n", .{
                i + 1, g.key, g.unlocked, gcum, g.roots, if (g.roots == 1) "" else "s",
            });
            if (g.example_fn.len > 0) {
                var t = g.example_text;
                if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[0..nl];
                try w.print("     e.g. {s}() line {d}: {s}\n", .{ g.example_fn, g.example_row, t });
            }
        }

        var cum: u32 = 0;
        try w.print("\n\nBY SINGLE ROOT -- fixing these, in this order, frees this many:\n\n", .{});
        for (prog.ranking.roots, 0..) |r, i| {
            cum += r.unlocked;
            try w.print("{d:>3}. {s:<34} +{d:<6}  running {d}\n", .{ i + 1, r.name, r.unlocked, cum });
            if (r.kind.len > 0) {
                var t = r.text;
                if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[0..nl];
                try w.print("     line {d}: {s}\n     {s}\n", .{ r.row, r.kind, t });
            }
        }
        if (prog.ranking.roots.len == 0) {
            try w.print("  (nothing ranked -- no function failed on its own body)\n", .{});
        } else {
            const rest = (total - ok) - cum;
            try w.print("\n{d} of the {d} unusable are freed by these {d} roots; {d} need more.\n", .{
                cum, total - ok, prog.ranking.roots.len, rest,
            });
            try w.print("A function held by TWO roots is freed by neither alone, which is why\n", .{});
            try w.print("the running total is the honest number and the sum of parts is not.\n", .{});
        }
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "usable")) {
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        const total = prog.funcs.len;
        const ok = prog.usableCount();
        try w.print("files {d}   functions+methods {d}\n", .{ unit.roots.items.len, total });
        if (total > 0) {
            try w.print("usable {d} ({d}%)   unusable {d}\n", .{ ok, ok * 100 / total, total - ok });
            try w.print("  of the unusable: {d} failed on their OWN body, {d} were poisoned by a caller/dispatch edge\n", .{
                prog.poisoned_direct, (total - ok) - prog.poisoned_direct,
            });
            try w.print("  ({d} of those came from the conservative same-name dispatch rule)\n", .{prog.poisoned_dynamic});
        }
        // a few usable ones, so the number can be checked by hand
        try w.print("\nsome usable functions:\n", .{});
        var shown: usize = 0;
        for (prog.funcs) |f| {
            if (f.poisoned or f.owner != null or f.params.len != 1) continue;
            try w.print("  {s}({s})\n", .{ f.name, f.params[0] });
            shown += 1;
            if (shown == 12) break;
        }
        try w.flush();
        return;
    }

    // `rnxc migrate <file.ring>` -- every site Rule A needs changed, as
    // path<TAB>byte<TAB>name. The compiler emits these because it is the
    // only thing that knows, per site, whether a name resolves to a local:
    // `rnxc attrs <file.ring>` -- the class-aware half of Rule A: every
    // attribute declared WITHOUT `@`, with its declaration and every bare
    // use inside its class, as one TSV for the applier with `--sigil @`.
    if (std.mem.eql(u8, argv[1], "attrs")) {
        const sites = co.attrSites(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        var n_out: usize = 0;
        for (sites) |s| {
            var path: []const u8 = "";
            for (unit.roots.items, 0..) |rt, i| {
                if (rt.src.ptr == s.src.ptr) path = unit.paths.items[i];
            }
            if (path.len == 0) continue;
            try w.print("{s}\t{d}\t{s}\n", .{ path, s.byte, s.name });
            n_out += 1;
        }
        try w.flush();
        std.debug.print("attrs: {d} site(s)\n", .{n_out});
        return;
    }

    // `rnxc shadows <file.ring>` -- the sites the Rule A migration changed
    // the meaning of ON RING. Same TSV as `migrate`, so the same applier
    // puts the sigil back. See compile.shadows for the measurement.
    if (std.mem.eql(u8, argv[1], "shadows")) {
        // `--bare` prints C-2's bare-global WRITE sites as the TSV instead
        // of the `$` sites -- never both, because the `$` TSV is what the
        // migration applier reads and what the gate counts.
        var bare_tsv = false;
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                if (std.mem.eql(u8, a, "--bare")) bare_tsv = true;
            }
        }
        var loops: usize = 0;
        const sh = co.shadows(alloc, unit.roots.items, &loops) catch |e| {
            co.reportFailure(e);
            return;
        };
        // The verdict per name goes to stderr; only the CROSS-FUNCTION
        // names' sites go to stdout, in the TSV the applier reads.
        // Three verdicts, not two. A name every function writes first is
        // SCRATCH and needs nothing. A name MOST functions read first is a
        // constant or a flag -- it gets its sigil back everywhere. And a
        // name that 307 functions write first and ONE reads first is a
        // scratch name with a latent bug in that one function: before the
        // migration it read whatever the shared global happened to hold,
        // and now it is R24. That is Softanza's to fix, so it is REPORTED,
        // not hidden by turning 308 locals into a global.
        var scratch: usize = 0;
        var cross: usize = 0;
        var suspect: usize = 0;
        std.debug.print("{s:<28} {s:>6} {s:>10}  {s}\n", .{ "PREFIX -- constant or flag", "funcs", "read-first", "e.g. in" });
        for (sh.names) |nm| {
            if (nm.read_first == 0) {
                scratch += 1;
            } else if (nm.read_first * 2 > nm.funcs) {
                cross += 1;
                std.debug.print("{s:<28} {d:>6} {d:>10}  {s}\n", .{ nm.name, nm.funcs, nm.read_first, nm.witness });
            } else suspect += 1;
        }
        std.debug.print("\n{s:<28} {s:>6} {s:>10}  {s}\n", .{ "REPORT -- scratch, read-first", "funcs", "read-first", "look at" });
        for (sh.names) |nm| {
            if (nm.read_first == 0 or nm.read_first * 2 > nm.funcs) continue;
            std.debug.print("{s:<28} {d:>6} {d:>10}  {s}\n", .{ nm.name, nm.funcs, nm.read_first, nm.witness });
        }
        var n_out: usize = 0;
        for (sh.sites) |s| {
            var is_cross = false;
            for (sh.names) |nm| {
                if (nm.read_first * 2 > nm.funcs and std.ascii.eqlIgnoreCase(nm.name, s.name)) is_cross = true;
            }
            if (!is_cross) continue;
            var path: []const u8 = "";
            for (unit.roots.items, 0..) |rt, i| {
                if (rt.src.ptr == s.src.ptr) path = unit.paths.items[i];
            }
            if (path.len == 0) continue;
            if (!bare_tsv) try w.print("{s}\t{d}\t{s}\n", .{ path, s.byte, s.name });
            n_out += 1;
        }
        std.debug.print("\nscratch names (every function writes first, nothing to fix): {d}\n", .{scratch});
        std.debug.print("constants and flags (sigil restored everywhere): {d} names, {d} site(s)\n", .{ cross, n_out });
        std.debug.print("scratch names with a read-first function (reported, not touched): {d}\n", .{suspect});
        std.debug.print("for-loop variables on global names, left for a person: {d}\n", .{loops});

        // C-2's BARE globals, measured 2026-09-23: a function, method or
        // lambda that assigns a bare top-level global writes the GLOBAL on
        // Ring and a LOCAL here. Everything above is about `$` names, where
        // the two runtimes agree; this is where they do not. PINNED APART:
        // the gate reads the write-site count off the summary line below
        // against bench/shadows_bare.max (0 on the base unit, Mansour's
        // decision of 2026-09-23), and this report is TAB-FREE, because
        // the `$` pin counts every tabbed line of this command's output.
        var n_reader: usize = 0;
        var n_scratch: usize = 0;
        var s_reader: usize = 0;
        var s_scratch: usize = 0;
        var s_loud: usize = 0;
        for (sh.bare_names) |nm| {
            switch (nm.verdict()) {
                .reader => n_reader += 1,
                .scratch => n_scratch += 1,
                .none => {},
            }
            s_loud += nm.read_first_fn;
        }
        for (sh.bare_sites) |s| {
            if (!s.write) continue;
            for (sh.bare_names) |nm| {
                if (!std.ascii.eqlIgnoreCase(nm.name, s.name)) continue;
                switch (nm.verdict()) {
                    .reader => s_reader += 1,
                    .scratch => s_scratch += 1,
                    .none => {},
                }
                break;
            }
        }
        std.debug.print("\n{s:<34} {s:>7} {s:>8} {s:>9} {s:>9}  {s}\n", .{ "BARE -- C-2, written for a reader", "writers", "fn-reads", "lam-reads", "top-reads", "e.g. at" });
        for (sh.bare_names) |nm| {
            if (nm.verdict() != .reader) continue;
            var path: []const u8 = "?";
            for (unit.roots.items, 0..) |rt, i| {
                if (rt.src.ptr == nm.at_src.ptr) path = unit.paths.items[i];
            }
            const line = 1 + std.mem.count(u8, nm.at_src[0..@min(nm.at_byte, nm.at_src.len)], "\n");
            std.debug.print("{s:<34} {d:>7} {d:>8} {d:>9} {d:>9}  {s}:{d} ({s})\n", .{ nm.name, nm.writers, nm.read_first_fn, nm.read_first_lam, nm.top_reads, std.fs.path.basename(path), line, nm.witness });
        }
        std.debug.print("\nbare top-level globals in this unit: {d}\n", .{sh.bare_globals});
        std.debug.print("bare globals written in a function, method or lambda (C-2, pinned apart in bench/shadows_bare.max): {d} name(s), {d} write site(s)\n", .{ n_reader + n_scratch, s_reader + s_scratch });
        std.debug.print("  written for a reader -- Ring writes the global, Ring++ a local, and something reads it: {d} name(s), {d} site(s)\n", .{ n_reader, s_reader });
        std.debug.print("  scratch -- written first, read by nothing outside the function: {d} name(s), {d} site(s)\n", .{ n_scratch, s_scratch });
        std.debug.print("  read first in a named function -- Ring reads the global, Ring++ REFUSES it (loud): {d} function(s)\n", .{s_loud});

        if (bare_tsv) {
            for (sh.bare_sites) |s| {
                if (!s.write) continue;
                var verdict: []const u8 = "none";
                for (sh.bare_names) |nm| {
                    if (std.ascii.eqlIgnoreCase(nm.name, s.name)) {
                        verdict = @tagName(nm.verdict());
                        break;
                    }
                }
                var path: []const u8 = "";
                for (unit.roots.items, 0..) |rt, i| {
                    if (rt.src.ptr == s.src.ptr) path = unit.paths.items[i];
                }
                if (path.len == 0) continue;
                const line = 1 + std.mem.count(u8, s.src[0..@min(s.byte, s.src.len)], "\n");
                try w.print("{s}\t{d}\t{s}\t{s}\t{s}\n", .{ path, line, s.name, s.fname, verdict });
            }
        }
        try w.flush();
        return;
    }

    // 92 of Softanza's 728 top-level names are ALSO locals elsewhere, so a
    // textual rename would turn thousands of locals into globals.
    if (std.mem.eql(u8, argv[1], "migrate")) {
        const cs = co.census(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        var n_out: usize = 0;
        for (cs.refusals) |r| {
            const rule_a = std.mem.indexOf(u8, r.kind, "(Rule A)") != null;
            if (!rule_a) continue;
            // which file does this node's source belong to?
            var path: []const u8 = "";
            for (unit.roots.items, 0..) |rt, i| {
                if (rt.src.ptr == r.src.ptr) path = unit.paths.items[i];
            }
            if (path.len == 0) continue;
            // the identifier text, up to the first non-name character
            var nm = r.text;
            var e2: usize = 0;
            while (e2 < nm.len and (std.ascii.isAlphanumeric(nm[e2]) or nm[e2] == '_')) e2 += 1;
            nm = nm[0..e2];
            if (nm.len == 0) continue;
            try w.print("{s}\t{d}\t{s}\n", .{ path, r.byte, nm });
            n_out += 1;
        }
        try w.flush();
        std.debug.print("migrate: {d} site(s)\n", .{n_out});
        return;
    }

    // `rnxc check <file> [--advise]` -- the 17 rules of docs/FINDINGS.md,
    // applied to every file the program loads.
    //
    // Commitment #4 says the compiler refusing statically IS the checker,
    // and for a week that was half true: src/check.zig, why.zig and
    // types.zig sat in the tree unbuilt, and tests/run-all.ps1 printed
    // `SKIP checker` on every run. They build now -- types.zig needed one
    // function out of the 753-line project.zig that went with the library
    // half, and it is inlined there rather than the file resurrected.
    //
    // WHAT IS NOT WIRED, said here rather than discovered: the old CLI also
    // ran cross-file rules -- a call to a function no file defines, a class
    // no file declares -- from a project model that was deleted. Those need
    // the load unit walked for definitions first, and until they are, this
    // reports the per-file rules only.
    if (std.mem.eql(u8, argv[1], "check")) {
        var advise = false;
        var closed = false;
        var natives_path: ?[]const u8 = null;
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                if (std.mem.eql(u8, a, "--advise")) advise = true;
                if (std.mem.eql(u8, a, "--closed")) closed = true;
                if (std.mem.startsWith(u8, a, "--natives=")) natives_path = a["--natives=".len..];
            }
        }
        var report = check.Report.init(alloc);
        // THE DEFINITION UNIVERSE, built once from the loader's own trees
        // and shared by every file: the unit IS the program, so one
        // universe is right for all of them. This was `.{}` -- every map
        // null -- and the four absence rules sat silent for fourteen days
        // while the gate counted them (src/universe.zig).
        var uni = try universe.Universe.build(alloc, unit.roots.items, unit.missing, closed);
        if (closed) try uni.addUnitSigs(alloc, unit.roots.items, unit.paths.items);
        var n_natives: usize = 0;
        if (natives_path) |np| {
            const txt = std.fs.cwd().readFileAlloc(alloc, np, 64 << 20) catch {
                std.debug.print("rnxc check: cannot read the natives list {s}\n", .{np});
                std.process.exit(2);
            };
            var names = std.ArrayListUnmanaged([]const u8){};
            var it = std.mem.tokenizeAny(u8, txt, " \t\r\n");
            while (it.next()) |n| try names.append(alloc, n);
            try uni.addNatives(alloc, names.items);
            n_natives = names.items.len;
        }
        const ctx = uni.ctx();
        // Each file's text as the unit READ it (origs) -- the file's bytes on disk, or the text `--subst` gave it.
        for (unit.roots.items, 0..) |_, i| {
            const path = unit.paths.items[i];
            check.checkSourceCtx(alloc, parser, path, unit.origs.items[i], &report, ctx) catch continue;
        }
        var last_file: []const u8 = "";
        for (report.findings.items) |f| {
            // Advice is opt-in: it describes working code that could be
            // faster, and printing it beside real defects teaches people
            // to skim both.
            if (f.severity == .adv and !advise) continue;
            if (!std.mem.eql(u8, last_file, f.file)) {
                try w.print("{s}{s}\n", .{ if (last_file.len == 0) "" else "\n", f.file });
                last_file = f.file;
            }
            try w.print("  {d}:{d}  {s: <5}  {s}\n", .{ f.row, f.col, f.severity.label(), f.rule });
            try w.print("          {s}\n", .{f.message});
            if (f.detail.len > 0) try wrapPrint(w, f.detail, 10, 74);
        }
        const c = report.counts();
        try w.print(
            "\n  {d} error, {d} warn, {d} perf, {d} note   in {d} file(s)\n",
            .{ c.err, c.warn, c.perf, c.note, unit.roots.items.len },
        );
        if (c.adv > 0 and !advise) {
            try w.print("  {d} place(s) where a measured idiom is faster -- add --advise to see them\n", .{c.adv});
        }
        // A rule that stays silent must SAY so, or "0 error" reads as a clean
        // bill of health for four rules that never looked. On the Softanza
        // aggregator this is the line that tells you why: eval and loadlib.
        if (closed and uni.complete) {
            try w.print("  checked CLOSED: a name only eval, loadlib or an admission could make is reported absent; {d} native name(s) given\n", .{n_natives});
        }
        if (!uni.complete) {
            try w.print("  undefined-function, unknown-class/-package: NOT checked -- {s}\n", .{uni.reason});
        }
        if (!uni.complete_vars) {
            try w.print("  uninitialized-variable: NOT checked -- {s}\n", .{if (uni.reason.len > 0)
                uni.reason
            else
                "an eval() in the unit assigns a name this pass cannot read"});
        }
        try w.flush();
        return;
    }
    if (std.mem.eql(u8, argv[1], "census")) {
        var t_census = try std.time.Timer.start();
        const cs = co.census(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        const t_census_ns = t_census.read();
        // `--natives`: every name compiled as a native call, most sites
        // first -- engine functions and, mixed in, any Ring builtin Ring++
        // lacks, which would otherwise surface only as an R3 at run time.
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                if (!std.mem.eql(u8, a, "--natives")) continue;
                const list = cs.native_list;
                const Cmp = struct {
                    fn lt(_: void, x: co.NativeName, y: co.NativeName) bool {
                        return x.sites > y.sites;
                    }
                };
                std.mem.sort(co.NativeName, list, {}, Cmp.lt);
                for (list) |nn| try w.print("native: {d:>6} {s}\n", .{ nn.sites, nn.name });
            }
        }
        try w.print("files loaded {d}\n", .{unit.roots.items.len});
        // WHERE THE MEMORY IS. Two allocators hold this process: the arena
        // below (every compiler structure, and the source text) and C malloc
        // (tree-sitter's trees, which never pass through Zig). Peak working
        // set alone cannot tell them apart, and 613 parse trees are the
        // biggest single thing this program owns -- so the split is printed
        // rather than guessed at.
        try w.print("arena: {d:.1} MB reserved   (peak working set is this plus tree-sitter's trees)\n", .{
            @as(f64, @floatFromInt(arena.queryCapacity())) / (1024.0 * 1024.0),
        });
        try w.print("phases: load {d:.2} s (read {d:.2}, parse {d:.2}, other {d:.2})  census {d:.2} s\n", .{
            @as(f64, @floatFromInt(t_load_ns)) / 1e9,
            @as(f64, @floatFromInt(t_read_ns)) / 1e9,
            @as(f64, @floatFromInt(t_parse_ns)) / 1e9,
            @as(f64, @floatFromInt(t_load_ns -| t_read_ns -| t_parse_ns)) / 1e9,
            @as(f64, @floatFromInt(t_census_ns)) / 1e9,
        });
        // C-32: the `not`s that led a chain and were read as Ring reads them, and what looking for them cost (it is inside "other" above)
        try w.print("lift: {d} `not` site(s) in {d} file(s), {d:.2} s (of it {d:.2} s parsing the rewritten files)\n", .{ lift.sites, lift.files, @as(f64, @floatFromInt(lift.ns)) / 1e9, @as(f64, @floatFromInt(lift.ns_reparse)) / 1e9 });
        try w.print("scans: knownGlobal {d}  globalSlot {d}  nameIndex {d}  findClass {d}  funcIndex {d}  findFunc {d}  attrSlotOf {d}  konstIndex {d}  methodOf {d}  lookup {d}   tables: globals {d} names {d} funcs {d} konst {d}\n", .{
            co.scans[0], co.scans[1], co.scans[2], co.scans[3], co.scans[4], co.scans[5], co.scans[6], co.scans[7], co.scans[8], co.scans[9],
            co.sizes[0], co.sizes[1], co.sizes[2], co.sizes[3],
        });
        {
            const MB = 1024.0 * 1024.0;
            try w.print("arena by phase (MB): collect {d:.0}  splice {d:.0}  pass A {d:.0}  classify {d:.0}  pass B {d:.0}\n", .{
                @as(f64, @floatFromInt(co.census_mem[0])) / MB,
                @as(f64, @floatFromInt(co.census_mem[1])) / MB,
                @as(f64, @floatFromInt(co.census_mem[2])) / MB,
                @as(f64, @floatFromInt(co.census_mem[3])) / MB,
                @as(f64, @floatFromInt(co.census_mem[4])) / MB,
            });
        }
        try w.print("built: code {d} instr  locals {d} (capacity {d})  stmts {d}\n", .{
            co.sizes[4], co.sizes[5], co.sizes[6], co.sizes[7],
        });
        {
            const MB = 1024.0 * 1024.0;
            {
                var top: [5]usize = .{ 0, 0, 0, 0, 0 };
                for (g_small, 0..) |cnt, sz| {
                    _ = cnt;
                    var j: usize = 0;
                    while (j < top.len) : (j += 1) {
                        if (g_small[sz] > g_small[top[j]]) {
                            var k = top.len - 1;
                            while (k > j) : (k -= 1) top[k] = top[k - 1];
                            top[j] = sz;
                            break;
                        }
                    }
                }
                try w.print("commonest small requests: {d}B x{d}  {d}B x{d}  {d}B x{d}  {d}B x{d}  {d}B x{d}\n", .{
                    top[0], g_small[top[0]], top[1], g_small[top[1]], top[2], g_small[top[2]],
                    top[3], g_small[top[3]], top[4], g_small[top[4]],
                });
            }
            try w.print("asked by size: <1KB {d:.0} MB ({d})  <64KB {d:.0} MB ({d})  <1MB {d:.0} MB ({d})  >=1MB {d:.0} MB ({d})\n", .{
                @as(f64, @floatFromInt(g_bucket[0])) / MB, g_bucket_n[0],
                @as(f64, @floatFromInt(g_bucket[1])) / MB, g_bucket_n[1],
                @as(f64, @floatFromInt(g_bucket[2])) / MB, g_bucket_n[2],
                @as(f64, @floatFromInt(g_bucket[3])) / MB, g_bucket_n[3],
            });
        }
        try w.print("asked for: {d:.0} MB total, largest single allocation {d:.1} MB\n", .{
            @as(f64, @floatFromInt(g_asked)) / (1024.0 * 1024.0),
            @as(f64, @floatFromInt(g_peak_one)) / (1024.0 * 1024.0),
        });
        try w.print("census phases: collect {d:.2} s  splice {d:.2} s  pass A {d:.2} s  classify {d:.2} s ({d} rounds)  pass B {d:.2} s\n", .{
            @as(f64, @floatFromInt(co.census_ns[0])) / 1e9,
            @as(f64, @floatFromInt(co.census_ns[1])) / 1e9,
            @as(f64, @floatFromInt(co.census_ns[2])) / 1e9,
            @as(f64, @floatFromInt(co.census_ns[3])) / 1e9,
            co.census_ns[5],
            @as(f64, @floatFromInt(co.census_ns[4])) / 1e9,
        });
        try w.print("collect: gather {d:.2} s  sort {d:.2} s  pass 1 {d:.2} s  class loop {d:.2} s  pass 2 {d:.2} s\n", .{
            @as(f64, @floatFromInt(co.collect_ns[0])) / 1e9,
            @as(f64, @floatFromInt(co.collect_ns[1])) / 1e9,
            @as(f64, @floatFromInt(co.collect_ns[2])) / 1e9,
            @as(f64, @floatFromInt(co.collect_ns[3])) / 1e9,
            @as(f64, @floatFromInt(co.collect_ns[4])) / 1e9,
        });
        try printCensus(cs, w, alloc);
        // `rnxc census <file> --all [kind]`: every refusal, one per line --
        // file, line, function, kind, text. One example per kind says what a
        // construct looks like; it does not say where the other 47 sites are,
        // and closing a construct means reading them.
        var all = false;
        var only: []const u8 = "";
        if (argv.len > 3) {
            for (argv[3..]) |a| {
                if (std.mem.eql(u8, a, "--all")) {
                    all = true;
                } else if (all and only.len == 0) only = a;
            }
        }
        if (all) {
            try w.print("\nevery refusal{s}{s}:\n", .{ if (only.len > 0) " of kind " else "", only });
            for (cs.refusals) |r| {
                if (only.len > 0 and !std.mem.eql(u8, r.kind, only)) continue;
                var file: []const u8 = "?";
                for (unit.roots.items, 0..) |root, ri| {
                    if (root.src.ptr == r.src.ptr and ri < co.load_paths.len) file = co.load_paths[ri];
                }
                var t = r.text;
                if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t = t[0..nl];
                try w.print("  {s}:{d}  {s}()  {s}  {s}\n", .{ file, r.row, r.func, r.kind, t });
            }
            if (only.len == 0 and cs.absent_classes.len > 0) {
                try w.print("\nevery `new` of a class the unit does not define (compiled, R11 at run time):\n", .{});
                for (cs.absent_classes) |r| {
                    var file: []const u8 = "?";
                    for (unit.roots.items, 0..) |root, ri| {
                        if (root.src.ptr == r.src.ptr and ri < co.load_paths.len) file = co.load_paths[ri];
                    }
                    try w.print("  {s}:{d}  {s}()  {s}\n", .{ file, r.row, r.func, r.text });
                }
            }
        }
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "time")) {
        if (argv.len < 5) {
            std.debug.print("usage: rnxc time <file.ring> <Func> <int arg> [reps]\n", .{});
            return;
        }
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        const arg = std.fmt.parseInt(i64, argv[4], 10) catch 0;
        const reps: usize = if (argv.len > 5) (std.fmt.parseInt(usize, argv[5], 10) catch 3) else 3;
        try timeOne(alloc, prog, argv[3], arg, reps);
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "call")) {
        if (argv.len < 4) {
            std.debug.print("usage: rnxc call <file.ring> <Func> [int args...]\n", .{});
            return;
        }
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        try callOne(alloc, prog, argv[3], argv[4..]);
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "bench")) {
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        try benchKernels(alloc, prog);
        try w.flush();
        return;
    }

    if (std.mem.eql(u8, argv[1], "run")) {
        if (tree.root().hasError()) {
            std.debug.print("parse errors in {s}\n", .{argv[2]});
            return;
        }
        const prog = co.compileLenient(alloc, unit.roots.items) catch |e| {
            co.reportFailure(e);
            return;
        };
        std.debug.print("compiled {d} functions, {d} instructions\n\n", .{ prog.funcs.len, prog.code.len });
        try runKernels(alloc, prog);
    }
    try w.flush();
}

/// THE RESIDENT VM, RUNG 6: RELEASE. The program's LAST admission undone after
/// it was admitted -- its functions, globals, constants, names and code gone,
/// the program exactly as it was before it (RNXC_RESIDENT_CHECK compares the
/// saved bytes). A server that admits code with a request releases it when
/// the request is done, and a program fed code for ever stays its size: an
/// admission it keeps costs about a kilobyte for good (measured, 2026-10-31).
///
/// Null when released, else why not. Refused: anything but the LAST admission
/// (a stack -- what came after it may call it); one that defined a class or a
/// lambda, or replaced anything (ReleaseRec); and while a frame of it runs.
/// `name` is what it was admitted under: admitcode's name, admitfile's path.
fn residentRelease(rs: *Resident, name: []const u8, at: RunAt) ?[]const u8 {
    var rl_t = std.time.Timer.start() catch null;
    const H = vmheap;
    const m = rs.m;
    if (!rs.live) return "nothing has been admitted";
    const top = if (rs.rel.items.len > 0) &rs.rel.items[rs.rel.items.len - 1] else
        return std.fmt.bufPrint(&rs.rel_why, "the program's last admission cannot be released: {s}", .{rs.unreleasable}) catch "the last admission cannot be released";
    const same = if (top.coded) std.mem.eql(u8, top.name, name) else blk: {
        const a = normalisePath(H, top.name) catch break :blk false;
        defer H.free(a);
        const b = normalisePath(H, name) catch break :blk false;
        defer H.free(b);
        break :blk std.mem.eql(u8, a, b);
    };
    if (!same) return std.fmt.bufPrint(&rs.rel_why, "the program's last admission is {s}, and only the last can be released", .{top.name}) catch "only the last admission can be released";
    // a frame of it still running -- the caller, or one the caller returns to
    const lo = top.prog_code;
    const hi = rs.prog_code;
    if (at.nested) {
        var running = at.pc >= lo and at.pc < hi;
        for (m.frames[0..at.fsp]) |fr| {
            if (fr.ret_pc >= lo and fr.ret_pc < hi) running = true;
        }
        if (running) return "a frame of its code is running";
    }
    // one of its functions attached to a class by `addmethod`: the class's
    // row would reach code that is gone, as a closure would (ReleaseRec)
    for (vm.dyn_methods.items) |dm| {
        if (dm.slot == 0 or dm.slot > vm.method_tab.len) continue;
        const e = vm.method_tab[dm.slot - 1].entry;
        if (e >= lo and e < hi) return std.fmt.bufPrint(&rs.rel_why, "addmethod attached one of its functions to a class, as the method {s}", .{dm.name}) catch "addmethod attached one of its functions to a class";
    }
    const P = rs.P;
    const vt = &rs.vt;
    const old_names = top.names;
    const old_funcs = top.funcs;

    var rl_ns = [_]u64{0} ** 9;
    rl_ns[8] = if (rl_t) |*t| t.lap() else 0;
    // ---- the VM: first what it holds BY NAME of the released functions --
    // the late link (VM.name_fn) of a name it filled, the name map, the name
    // index, the r24 index -- then every table cut back to where it stood
    const lowKey = struct {
        fn f(buf: []u8, nm: []const u8) ?[]u8 {
            if (nm.len == 0 or nm.len > buf.len) return null;
            return std.ascii.lowerString(buf[0..nm.len], nm);
        }
    }.f;
    var kb: [256]u8 = undefined;
    for (P.funcs.items[old_funcs..], old_funcs..) |f, i| {
        if (f.owner == null and f.lambda_at == null and f.name_idx < old_names and f.name_idx < vt.name_fn.items.len) {
            if (vt.name_fn.items[f.name_idx] == i) vt.name_fn.items[f.name_idx] = vm.NO_FN;
        }
        if (f.owner != null) continue;
        if (m.fn_index) |*fi| {
            if (lowKey(&kb, f.name)) |key| {
                if (fi.get(key)) |v| {
                    if (v == i) {
                        if (fi.fetchRemove(key)) |kv| H.free(kv.key);
                    }
                }
            }
        }
    }
    if (m.name_lc) |*nl| {
        for (vt.names.items[old_names..], old_names..) |nm, i| {
            const key = lowKey(&kb, nm) orelse continue;
            if (nl.get(key)) |v| {
                if (v == i) {
                    if (nl.fetchRemove(key)) |kv| H.free(kv.key);
                }
            }
        }
    }
    for (m.code[lo..@min(hi, m.code.len)], lo..) |in, pc| {
        if (in.op != .r24 or in.d < 0) continue;
        if (rs.r24.getPtr(@intCast(in.d))) |l| {
            if (l.items.len > 0 and l.items[l.items.len - 1] == pc) _ = l.pop();
        }
    }
    // its constants: the table's pin taken off (dupKonst pins at konst_rc,
    // appendKonst holds one more) and the size it was allocated restored, so
    // a constant nothing else holds is freed as the table lets go -- and one
    // a value still holds (a reply the host kept) lives as long as that value
    for (vm.konst[@min(top.prog_konst, vm.konst.len)..]) |v| {
        if (v.tag != .str) continue;
        const sp = v.p.s;
        if (sp.rc < vm.konst_rc) continue; // eval's, held once by the table
        sp.rc -= vm.konst_rc;
        sp.cap = if (sp.len == 0) 1 else sp.len;
    }
    // the frame masks compileFinish wrote for its functions with an id under
    // 64 (vm.fn_masks), back to what an id nothing has used holds -- the
    // check found them left behind, harmless and not "as it was"
    for (P.funcs.items[old_funcs..]) |f| {
        if (f.id < vm.fn_masks.len) vm.fn_masks[f.id] = 0;
    }
    if (rl_t) |*t| rl_ns[0] = t.lap();
    m.truncateCode(top.prog_code);
    m.truncateKonst(top.prog_konst);
    evalReset();
    if (rl_t) |*t| rl_ns[1] = t.lap();
    // the tables the installer grew
    inline for (vt_string_lists) |f| {
        const l = &@field(vt, f);
        const keep = top.vt[comptime vtIndex(f)];
        for (l.items[keep..]) |sx| H.free(sx);
    }
    inline for (vt_lists, 0..) |f, k| @field(vt, f).shrinkRetainingCapacity(top.vt[k]);
    m.fn_of = vt.fn_of.items;
    m.rows = vt.rows.items;
    m.files = vt.files.items;
    m.names = vt.names.items;
    m.ncache = vt.ncache.items;
    vm.global_names = vt.global_names.items;
    m.fn_entry = vt.fn_entry.items;
    m.fn_frame = vt.fn_frame.items;
    m.fn_local_from = vt.fn_local_from.items;
    m.local_names = vt.local_names.items;
    m.local_regs = vt.local_regs.items;
    m.local_boxed = vt.local_boxed.items;
    m.fn_names = vt.fn_names.items;
    m.fn_method = vt.fn_method.items;
    m.fn_nparams = vt.fn_nparams.items;
    m.name_fn = vt.name_fn.items;
    m.name_cls = vt.name_cls.items;
    m.name_up = vt.name_up.items;
    // a cell `addmethod` wrote for one of its NAMES -- the only cells past the
    // names it found, since it defined no class -- emptied, so the index the
    // next admission's name takes does not answer for it. The attachment
    // stays in vm.dyn_methods and comes back with the name (growClassTables)
    // -- found through the attachments, whose names the compiler still
    // knows here: zeroing every row past the old names cost ~2 ms a release
    // at Softanza's size (600 classes, the rows' headroom)
    {
        const nnm: usize = vm.n_names;
        var lb: [256]u8 = undefined;
        for (vm.dyn_methods.items) |dm| {
            if (dm.name.len > lb.len) continue;
            const ni = P.name_index.get(std.ascii.lowerString(&lb, dm.name)) orelse continue;
            if (ni < old_names or ni >= nnm) continue;
            const cell = @as(usize, dm.cls) * nnm + ni;
            if (cell < vt.dispatch.items.len) vt.dispatch.items[cell] = 0;
        }
    }
    if (rl_t) |*t| rl_ns[2] = t.lap();
    // its globals, and what they held. Slots count from 0 and the VM's table
    // is one longer than the program's list (`prog.nglobals + 1`), so the
    // admission's first global sat in the slot past the list as it stood --
    // inside the table's old length. Cut to the list, and that slot emptied:
    // a global admitted after the release takes it, and must find it unset
    const keep_g = top.globals;
    if (m.globals.len > keep_g) {
        for (m.globals[keep_g..]) |v| m.dropValue(v);
        const g = H.alloc(vm.Value, keep_g + 1) catch @panic("oom");
        @memcpy(g[0..keep_g], m.globals[0..keep_g]);
        g[keep_g] = vm.Value.nil();
        const gs = H.alloc(bool, keep_g + 1) catch @panic("oom");
        @memcpy(gs[0..keep_g], m.globals_set[0..keep_g]);
        gs[keep_g] = false;
        H.free(m.globals);
        H.free(m.globals_set);
        m.globals = g;
        m.globals_set = gs;
    }
    if (m.file_names.len > top.file_names) {
        for (m.file_names[top.file_names..]) |fnm| H.free(fnm);
        const fl = H.alloc([]const u8, top.file_names) catch @panic("oom");
        @memcpy(fl, m.file_names[0..top.file_names]);
        H.free(m.file_names);
        m.file_names = fl;
    }
    m.main_fn = top.main_fn;
    if (rl_t) |*t| rl_ns[3] = t.lap();
    // the class each function belongs to, and the accessor tables: an old
    // name whose getter or setter was one of the released names had none
    // before (names are unique in any case, so it was that one or nothing)
    if (vm.fn_owner.len > top.fn_owner) {
        const fo = H.alloc(u16, top.fn_owner) catch @panic("oom");
        @memcpy(fo, vm.fn_owner[0..top.fn_owner]);
        H.free(vm.fn_owner);
        vm.fn_owner = fo;
    }
    if (vm.acc_get.len > top.acc) {
        const ag = H.alloc(u32, top.acc) catch @panic("oom");
        const as = H.alloc(u32, top.acc) catch @panic("oom");
        @memcpy(ag, vm.acc_get[0..top.acc]);
        @memcpy(as, vm.acc_set[0..top.acc]);
        for (ag, as) |*g, *s| {
            if (g.* != vm.ACC_NONE and g.* >= old_names) g.* = vm.ACC_NONE;
            if (s.* != vm.ACC_NONE and s.* >= old_names) s.* = vm.ACC_NONE;
        }
        H.free(vm.acc_get);
        H.free(vm.acc_set);
        vm.acc_get = ag;
        vm.acc_set = as;
    }

    if (rl_t) |*t| rl_ns[4] = t.lap();
    // ---- the compiler: rolled back as a refusal is, from the record -------
    const marks = co.Marks{
        .code = top.code,
        .fixups = top.fixups,
        .names = top.names,
        .globals = top.globals,
        .konst = top.konst,
        .funcs = top.funcs,
        .classes = top.classes,
        .classes_copy = &.{}, // no class was touched (ReleaseRec)
        .natives_copy = top.natives,
        .counters = top.counters,
        .prefix_main = top.prefix_main,
    };
    P.called_log.clearRetainingCapacity();
    P.called_log.appendSlice(P.alloc, top.called) catch @panic("oom");
    co.rollbackProgram(P, &marks);
    P.called_log.clearRetainingCapacity();
    P.prefix_funcs = top.funcs;
    P.prefix_classes = top.classes;
    P.prefix_code = top.code;
    P.prefix_fixups = top.fixups;
    P.main_fn = null;

    if (rl_t) |*t| rl_ns[5] = t.lap();
    // ---- the resident's own record of what it holds -----------------------
    for (rs.stamps.items[top.stamps..]) |st| H.free(st.path);
    rs.stamps.shrinkRetainingCapacity(top.stamps);
    for (rs.held_norm.items[top.stamps..]) |k| H.free(k);
    rs.held_norm.shrinkRetainingCapacity(top.stamps);
    for (rs.fnames.items[top.fnames..]) |f| H.free(f);
    rs.fnames.shrinkRetainingCapacity(top.fnames);
    rs.prog_code = top.prog_code;
    rs.prog_konst = top.prog_konst;
    rs.nfuncs = top.nfuncs;
    rs.released += 1;

    if (rl_t) |*t| rl_ns[6] = t.lap();
    // RNXC_RESIDENT_CHECK: the program's bytes are what they were before
    // the admission, and the VM's tables are as long as the program's lists
    if (top.check_before) |b| {
        const after = prefix.encode(H, rs.exe, rs.stamps.items, rs.fnames.items, P) catch @panic("resident: the program could not be saved");
        defer H.free(after);
        if (!std.mem.eql(u8, b, after)) {
            std.debug.print("resident: RNXC_RESIDENT_CHECK -- a release left the program other than it was ({d} bytes before the admission, {d} after the release): a defect of rnxc\n", .{ b.len, after.len });
            std.process.exit(2);
        }
        if (m.code.len != P.code.items.len or m.names.len != P.names.items.len or m.fn_names.len != P.funcs.items.len or
            vm.global_names.len != P.globals.items.len or m.fn_of.len != P.code.items.len or vm.konst.len != P.konst.items.len or
            m.globals.len != P.globals.items.len + 1 or m.globals_set[P.globals.items.len] or m.globals[P.globals.items.len].tag != .nil)
        {
            std.debug.print("resident: RNXC_RESIDENT_CHECK -- after a release the VM's tables and the program disagree in length, or the slot past the last global is not empty: a defect of rnxc\n", .{});
            std.process.exit(2);
        }
        checkR24Index(rs);
    }
    // what is now last keeps its own record, or the reason it has none
    var done = rs.rel.pop().?;
    done.deinit();
    if (rl_t) |*t| rl_ns[7] = t.lap();
    if (admitPhasesOn()) {
        std.debug.print("release: {s}:", .{name});
        const lbl = [_][]const u8{ "by-name", "truncate", "vm-lists", "dispatch", "globals", "owner-acc", "compiler", "resident", "checks" };
        for (lbl, rl_ns) |l, x| std.debug.print(" {s} {d:.2}", .{ l, @as(f64, @floatFromInt(x)) / 1e6 });
        std.debug.print(" ms\n", .{});
    }
    // what the admission's compile left in the program's arena is garbage
    // now, and the next admission's compaction rule reclaims it with the
    // rest: a release adds nothing to the arena, so a check here never fires
    return null;
}

fn vtIndex(comptime f: []const u8) usize {
    inline for (vt_lists, 0..) |g, k| {
        if (comptime std.mem.eql(u8, f, g)) return k;
    }
    @compileError("not a VM table: " ++ f);
}
