//! Ring source -> spike bytecode. Stage 2, milestone 1.
//!
//! Single pass over tree-sitter's tree, in the shape Ring's own grammar
//! already suggests (all functions before all classes, F-21) -- Wren's
//! lesson that a language designed for single-pass compilation does not
//! need more than one.
//!
//! THE ONE PIECE OF REAL ANALYSIS is `classify`: which locals can hold a
//! heap reference. That decides the boxed-register masks, and the Stage 1
//! measurements showed those masks are worth 45-154% on ARM. The inference
//! here is deliberately crude -- a subscript yields "reference" because
//! element types are unknown -- and where it is crude the program pays. That
//! is the mechanism, visible.

const std = @import("std");
const ts = @import("ts.zig");
const vm = @import("main.zig");

pub const Error = error{ Unsupported, OutOfMemory, BadNumber, PrefixInapplicable };

const MAXREG = 200;

/// `d` of a `vpush` or `dlen` that IS add() or len(): the VM names the C
/// function an error was raised inside (`In add()`, vm.cfnAt), and these
/// two opcodes also serve list literals, `aL[i] + v` and for-in (F-102).
const CFN: i32 = 1;

/// Name -> id -> one `bcall`, and the arity each name takes. One name
/// can carry two arities (find, sort). Hoisted to file scope 2026-09-24 so
/// the classify pre-pass can ask the same question codegen does: is this
/// callee a builtin, or does the list it is handed escape into a call?
const BuiltinEntry = struct { name: []const u8, id: vm.Builtin, argc: u32 };
const builtin_table = [_]BuiltinEntry{
    .{ .name = "char", .id = .char, .argc = 1 },
    .{ .name = "lower", .id = .lower, .argc = 1 },
    .{ .name = "upper", .id = .upper, .argc = 1 },
    .{ .name = "trim", .id = .trim, .argc = 1 },
    .{ .name = "left", .id = .left, .argc = 2 },
    .{ .name = "right", .id = .right, .argc = 2 },
    .{ .name = "copy", .id = .copystr, .argc = 2 },
    .{ .name = "fabs", .id = .fabs, .argc = 1 },
    .{ .name = "max", .id = .max, .argc = 2 },
    .{ .name = "min", .id = .min, .argc = 2 },
    .{ .name = "number", .id = .number, .argc = 1 },
    .{ .name = "islist", .id = .islist, .argc = 1 },
    .{ .name = "isstring", .id = .isstring, .argc = 1 },
    .{ .name = "isnumber", .id = .isnumber, .argc = 1 },
    .{ .name = "isnull", .id = .isnull, .argc = 1 },
    .{ .name = "string", .id = .string, .argc = 1 },
    .{ .name = "type", .id = .typeof, .argc = 1 },
    .{ .name = "decimals", .id = .decimals, .argc = 1 },
    .{ .name = "find", .id = .find2, .argc = 2 },
    .{ .name = "find", .id = .find3, .argc = 3 },
    .{ .name = "find", .id = .find4, .argc = 4 },
    .{ .name = "sort", .id = .sort1, .argc = 1 },
    .{ .name = "sort", .id = .sort2, .argc = 2 },
    .{ .name = "reverse", .id = .reverse, .argc = 1 },
    .{ .name = "isobject", .id = .isobject, .argc = 1 },
    .{ .name = "ispointer", .id = .ispointer, .argc = 1 },
    .{ .name = "isalpha", .id = .isalpha, .argc = 1 },
    .{ .name = "islower", .id = .islower, .argc = 1 },
    .{ .name = "isupper", .id = .isupper, .argc = 1 },
    .{ .name = "isalnum", .id = .isalnum, .argc = 1 },
    .{ .name = "isdigit", .id = .isdigit, .argc = 1 },
    .{ .name = "hex", .id = .hex, .argc = 1 },
    .{ .name = "dec", .id = .dec, .argc = 1 },
    .{ .name = "filename", .id = .filename, .argc = 0 },
    .{ .name = "syssleep", .id = .syssleep, .argc = 1 },
    .{ .name = "remove", .id = .removefile, .argc = 1 },
    .{ .name = "attributes", .id = .attributes, .argc = 1 },
    .{ .name = "ascii", .id = .ascii, .argc = 1 },
    .{ .name = "ceil", .id = .ceil, .argc = 1 },
    .{ .name = "floor", .id = .floor, .argc = 1 },
    .{ .name = "sqrt", .id = .sqrt, .argc = 1 },
    .{ .name = "strcmp", .id = .strcmp, .argc = 2 },
    .{ .name = "fexists", .id = .fexists, .argc = 1 },
    .{ .name = "read", .id = .readf, .argc = 1 },
    .{ .name = "write", .id = .writef, .argc = 2 },
    .{ .name = "LoadLib", .id = .loadlib, .argc = 1 },
    // Chosen by counting what RUNNING Softanza asked for, not from
    // Ring's manual. Call sites in Softanza, after discarding the
    // 60 names it defines itself: clock 391, clockspersecond 177,
    // sin 104, direxists 99, currentdir 93, pow 57, cos 53,
    // random 36, str2list 23, log10 15.
    .{ .name = "clock", .id = .clock, .argc = 0 },
    .{ .name = "clockspersecond", .id = .clockspersecond, .argc = 0 },
    .{ .name = "sin", .id = .sin, .argc = 1 },
    .{ .name = "cos", .id = .cos, .argc = 1 },
    .{ .name = "tan", .id = .tan, .argc = 1 },
    .{ .name = "asin", .id = .asin, .argc = 1 },
    .{ .name = "acos", .id = .acos, .argc = 1 },
    .{ .name = "atan", .id = .atan, .argc = 1 },
    .{ .name = "atan2", .id = .atan2, .argc = 2 },
    .{ .name = "sinh", .id = .sinh, .argc = 1 },
    .{ .name = "cosh", .id = .cosh, .argc = 1 },
    .{ .name = "tanh", .id = .tanh, .argc = 1 },
    .{ .name = "log", .id = .log, .argc = 1 },
    .{ .name = "log10", .id = .log10, .argc = 1 },
    .{ .name = "exp", .id = .exp, .argc = 1 },
    .{ .name = "pow", .id = .pow, .argc = 2 },
    .{ .name = "direxists", .id = .direxists, .argc = 1 },
    .{ .name = "currentdir", .id = .currentdir, .argc = 0 },
    .{ .name = "exefolder", .id = .exefolder, .argc = 0 },
    .{ .name = "random", .id = .random, .argc = 1 },
    .{ .name = "random", .id = .random0, .argc = 0 },
    .{ .name = "srandom", .id = .srandom, .argc = 1 },
    .{ .name = "nothing", .id = .nothing, .argc = 0 },
    .{ .name = "str2list", .id = .str2list, .argc = 1 },
    .{ .name = "version", .id = .version, .argc = 0 },
    .{ .name = "iswindows", .id = .iswindows, .argc = 0 },
    .{ .name = "iswindows64", .id = .iswindows64, .argc = 0 },
    .{ .name = "islinux", .id = .islinux, .argc = 0 },
    .{ .name = "ismacosx", .id = .ismacosx, .argc = 0 },
    .{ .name = "isfreebsd", .id = .isfreebsd, .argc = 0 },
    .{ .name = "isunix", .id = .isunix, .argc = 0 },
    .{ .name = "isandroid", .id = .isandroid, .argc = 0 },
    .{ .name = "ismsdos", .id = .ismsdos, .argc = 0 },
    // Found by `rnxc census --natives` (2026-09-23): Ring builtins
    // the base unit calls that compiled to NATIVE calls and failed
    // only at run time -- dir 17 sites, System 14, Date 12, Time 9,
    // windowsnl 5, tempname 4, chdir 3 and the rest.
    .{ .name = "dir", .id = .dir, .argc = 1 },
    .{ .name = "date", .id = .date, .argc = 0 },
    .{ .name = "time", .id = .time, .argc = 0 },
    .{ .name = "timelist", .id = .timelist, .argc = 0 },
    .{ .name = "adddays", .id = .adddays, .argc = 2 },
    .{ .name = "diffdays", .id = .diffdays, .argc = 2 },
    .{ .name = "sysget", .id = .sysget, .argc = 1 },
    .{ .name = "sysset", .id = .sysset, .argc = 2 },
    .{ .name = "sysunset", .id = .sysunset, .argc = 1 },
    .{ .name = "tempname", .id = .tempname, .argc = 0 },
    .{ .name = "chdir", .id = .chdir, .argc = 1 },
    .{ .name = "exefilename", .id = .exefilename, .argc = 0 },
    .{ .name = "getpathtype", .id = .getpathtype, .argc = 1 },
    .{ .name = "windowsnl", .id = .windowsnl, .argc = 0 },
    .{ .name = "system", .id = .system, .argc = 1 },
    .{ .name = "rename", .id = .rename, .argc = 2 },
    // Ring's C-style file functions: fopen 14 sites, fclose 14,
    // fwrite 7, fread 3, fgetc 3, fseek 3 ... (census --natives).
    .{ .name = "fopen", .id = .fopen, .argc = 2 },
    .{ .name = "fclose", .id = .fclose, .argc = 1 },
    .{ .name = "fflush", .id = .fflush, .argc = 1 },
    .{ .name = "fwrite", .id = .fwrite, .argc = 2 },
    .{ .name = "fread", .id = .fread, .argc = 2 },
    .{ .name = "fgetc", .id = .fgetc, .argc = 1 },
    .{ .name = "fputc", .id = .fputc, .argc = 2 },
    .{ .name = "fputs", .id = .fputs, .argc = 2 },
    .{ .name = "fgets", .id = .fgets, .argc = 2 },
    .{ .name = "fseek", .id = .fseek, .argc = 3 },
    .{ .name = "ftell", .id = .ftell, .argc = 1 },
    .{ .name = "rewind", .id = .rewind, .argc = 1 },
    .{ .name = "feof", .id = .feof, .argc = 1 },
    .{ .name = "ferror", .id = .ferror, .argc = 1 },
    .{ .name = "clearerr", .id = .clearerr, .argc = 1 },
    .{ .name = "ungetc", .id = .ungetc, .argc = 2 },
    .{ .name = "tempfile", .id = .tempfile, .argc = 0 },
    .{ .name = "freopen", .id = .freopen, .argc = 3 },
    .{ .name = "perror", .id = .perror, .argc = 1 },
    .{ .name = "fgetpos", .id = .fgetpos, .argc = 1 },
    .{ .name = "fsetpos", .id = .fsetpos, .argc = 2 },
    .{ .name = "isspace", .id = .isspace, .argc = 1 },
    .{ .name = "isgraph", .id = .isgraph, .argc = 1 },
    .{ .name = "ispunct", .id = .ispunct, .argc = 1 },
    .{ .name = "iscntrl", .id = .iscntrl, .argc = 1 },
    .{ .name = "isprint", .id = .isprint, .argc = 1 },
    .{ .name = "isxdigit", .id = .isxdigit, .argc = 1 },
    .{ .name = "hex2str", .id = .hex2str, .argc = 1 },
    .{ .name = "list2str", .id = .list2str1, .argc = 1 },
    .{ .name = "list2str", .id = .list2str2, .argc = 2 },
    .{ .name = "list2str", .id = .list2str3, .argc = 3 },
    .{ .name = "assert", .id = .assert, .argc = 1 },
    .{ .name = "int2bytes", .id = .int2bytes, .argc = 1 },
    .{ .name = "bytes2int", .id = .bytes2int, .argc = 1 },
    .{ .name = "float2bytes", .id = .float2bytes, .argc = 1 },
    .{ .name = "bytes2float", .id = .bytes2float, .argc = 1 },
    .{ .name = "double2bytes", .id = .double2bytes, .argc = 1 },
    .{ .name = "bytes2double", .id = .bytes2double, .argc = 1 },
    .{ .name = "unsigned", .id = .unsigned2, .argc = 2 },
    .{ .name = "unsigned", .id = .unsigned3, .argc = 3 },
    .{ .name = "list", .id = .list1, .argc = 1 },
    .{ .name = "list", .id = .list2d, .argc = 2 },
    .{ .name = "newlist", .id = .newlist1, .argc = 1 },
    .{ .name = "newlist", .id = .newlist2d, .argc = 2 },
    .{ .name = "ismethod", .id = .ismethod, .argc = 2 },
    .{ .name = "isfunction", .id = .isfunction, .argc = 1 },
    .{ .name = "methods", .id = .methods, .argc = 1 },
    .{ .name = "getattribute", .id = .getattribute, .argc = 2 },
    .{ .name = "setattribute", .id = .setattribute, .argc = 3 },
    .{ .name = "isattribute", .id = .isattribute, .argc = 2 },
    .{ .name = "functions", .id = .functions, .argc = 0 },
    .{ .name = "classes", .id = .classes, .argc = 0 },
    .{ .name = "globals", .id = .globals, .argc = 0 },
    .{ .name = "prevfilename", .id = .prevfilename, .argc = 0 },
    .{ .name = "packages", .id = .packages, .argc = 0 },
    .{ .name = "addattribute", .id = .addattribute, .argc = 2 },
    .{ .name = "addmethod", .id = .addmethod, .argc = 3 },
    .{ .name = "ref", .id = .refv, .argc = 1 },
    .{ .name = "reference", .id = .reference, .argc = 1 },
    .{ .name = "refcount", .id = .refcount, .argc = 1 },
    // The console primitives (contract gate 3). Measured on conhost
    // and Windows Terminal before they were written -- main.zig
    // has the table.
    .{ .name = "tui_init", .id = .tui_init, .argc = 0 },
    .{ .name = "tui_key", .id = .tui_key, .argc = 0 },
    .{ .name = "tui_size", .id = .tui_size, .argc = 0 },
    .{ .name = "tui_done", .id = .tui_done, .argc = 0 },
    .{ .name = "web_serve", .id = .web_serve, .argc = 1 },
    .{ .name = "web_wait", .id = .web_wait, .argc = 1 },
    .{ .name = "web_done", .id = .web_done, .argc = 0 },
    .{ .name = "web_bye", .id = .web_bye, .argc = 1 },
    // eval(code): compiled at RUN TIME in the caller's frame (F-72, C-9)
    .{ .name = "eval", .id = .eval, .argc = 1 },
};

/// Is this callee one of the builtins codegen compiles to a `bcall`?
fn builtinNamed(name: []const u8) bool {
    for (builtin_table) |bi| {
        if (std.ascii.eqlIgnoreCase(name, bi.name)) return true;
    }
    return false;
}

/// What a value is, as far as this front end can tell.
///
/// Two axes matter to codegen. `int` needs no refcount traffic at all;
/// everything else does. And knowing specifically `list` or `str` lets the
/// dynamic `dget`/`dlen` collapse to the specialised opcode the hand-written
/// bytecode uses -- which is the whole difference between "the front end
/// works" and "the front end is worth using".
///
/// `unknown` is the bottom of the lattice (an empty list whose element type
/// nothing has revealed yet); `ref` is the top (could be anything, so assume
/// a reference).
pub const Class = enum {
    unknown,
    int,
    list,
    str,
    ref,

    /// Anything that is not provably an int must be refcounted.
    pub fn boxed(c: Class) bool {
        return c != .int;
    }

    pub fn join(a: Class, b: Class) Class {
        if (a == .unknown) return b;
        if (b == .unknown) return a;
        if (a == b) return a;
        return .ref;
    }
};

pub const Local = struct {
    name: []const u8,
    reg: u8,
    /// Bottom, not `int`: starting at `int` makes the first join with `list`
    /// collapse to `ref` and nothing in the file specialises.
    class: Class = .unknown,
    /// Stated in the source rather than inferred, via Ring's parameter
    /// annotation. A declared class is not widened by the conservative
    /// entry-point rule: the programmer said what it is.
    declared: bool = false,
    /// WHICH class this holds, when every assignment in the function
    /// provably yields the same one. `.ref` says "an object"; this says
    /// which -- and that is what turns `o.Content()` from "any Content()
    /// anywhere" into one method.
    cls: ?u16 = null,
    /// Set the moment two assignments disagree, or one cannot be proved.
    /// Monotone: once unprovable, never provable again. The unsafe
    /// direction here is silence, so anything unproven sets it.
    cls_bad: bool = false,
    /// For a list: what its elements are. `aA[i]` is only compilable to a
    /// specialised `vget` when we know both that aA is a list AND what
    /// comes out of it -- matmul's `aRow = aA[i]` then `aRow[k]` needs
    /// exactly this second level.
    elem: Class = .unknown,
};

pub const Func = struct {
    name: []const u8,
    node: ts.Node,
    params: [][]const u8,
    entry: u32 = 0,
    /// Widened from u8. There are 43,712 functions in Softanza and the
    /// cast `@intCast(funcs.items.len)` into a u8 is illegal behaviour
    /// past 255 -- silently so in ReleaseFast, which is how it survived.
    /// ReleaseSafe caught it on the first run.
    id: u32 = 0,
    frame: u8 = 0,
    mask: u64 = 0,
    ret: Class = .unknown,
    /// Declared parameter classes, one per parameter, `.unknown` where the
    /// source said nothing.
    hints: []Class = &.{},
    /// Element class of a returned list, propagated like `ret`.
    ret_elem: Class = .unknown,
    /// Did any call site inside this compilation unit call it? A function
    /// only ever entered from outside gives inference nothing to work with.
    called: bool = false,
    /// Entry point for a call from OUTSIDE the bytecode. A compiled function
    /// ends in `ret`, which pops a frame, so it cannot be entered directly --
    /// it needs one pushed first. Two instructions: call, then halt.
    tramp: u32 = 0,
    locals: std.ArrayListUnmanaged(Local) = .{},
    /// First statement index in the function node's children.
    body_from: u32 = 0,
    /// The class that owns this function, if it is a method. A method's
    /// register 0 is always the receiver, so its parameters start at r1.
    owner: ?u16 = null,
    /// Index into the compiler's name table, for dispatch.
    name_idx: u16 = 0,
    /// A statement of this function could not be compiled, so its body is
    /// INCOMPLETE. Emitting it anyway and letting it run would produce a
    /// wrong answer silently, which is the one outcome worth more than a
    /// missing feature. Poison spreads to callers.
    poisoned: bool = false,
    /// This function's OWN body failed, as opposed to inheriting poison
    /// from something it calls. These are the only functions worth fixing:
    /// 824 of them hold 27,062 hostage, so the ranking is over these.
    poisoned_own: bool = false,
    /// Method names this function calls dynamically, for poison spreading.
    calls_named: std.ArrayListUnmanaged(u16) = .{},
    /// Method calls whose receiver class was PROVED, recorded as the one
    /// function they can reach. These do not take part in the same-name
    /// poison rule -- they have a real edge instead.
    calls_static: std.ArrayListUnmanaged(u32) = .{},
    /// Names this lambda captures from its enclosing function, in slot
    /// order. Slot 0 of the closure vector is the function id, so capture
    /// i lives at slot i+1.
    captures: std.ArrayListUnmanaged([]const u8) = .{},
    /// Byte offset of the `anonymous_function` node this was lowered
    /// from, so the creation site can find it again.
    lambda_at: ?u32 = null,
    /// The function this lambda was lowered FROM -- its defining scope.
    /// C-14 asks whether that scope is the top level: a bare write there
    /// to a top-level global writes the global, as on Ring.
    encl: ?u32 = null,
    /// Did this function reach the emitter? `entry` defaults to 0, which is
    /// also a legal address, so the two were told apart by "is it @@main" --
    /// and that silently unnamed whatever function happened to be emitted
    /// FIRST in every call-chain report where it was not @@main. It never
    /// showed, because the root file's top level is usually collected first
    /// and is therefore the function at address 0. Compiling a file on top
    /// of a PREFIX puts a library function there, and `In function
    /// Loaded()` vanished from bench/exec/err_loaded.ring (2026-09-14).
    emitted: bool = false,
    /// The body calls `eval`, which may assign any local by name -- so no
    /// read in it can be judged unassigned (definite assignment, F-89).
    /// Set by the openElems pre-pass, which already finds every eval.
    calls_eval: bool = false,
    /// The synthetic function holding the file's top-level statements.
    /// Its assignments create GLOBALS; every other function's create
    /// locals. That is Ring's actual rule, and the whole of it.
    is_main: bool = false,
    /// The function's statements, reconstructed BY POSITION.
    ///
    /// The grammar does not reliably nest them inside the function node: a
    /// body may close early and the rest of the statements appear as
    /// siblings at file level, because Ring has no `end func` and "one
    /// statement then top-level code" is a legal parse of the same text.
    /// Measured: in an eight-function file, EVERY function except the last
    /// kept only its first statement. Ring's real rule is F-21's -- a
    /// function owns everything up to the next `func` -- so that is what is
    /// reconstructed here. The checker learned the same lesson about
    /// classes and answers it the same way, with position rather than
    /// nesting.
    stmts: std.ArrayListUnmanaged(ts.Node) = .{},
    /// The registers its locals occupy are 0..reg_top-1. One per local, so
    /// equal to `locals.items.len`, for every function but one that SHARES.
    reg_top: u16 = 0,
    /// `define` met the register window (MAXREG): one register per local
    /// does not fit. See shareFunction.
    window_full: bool = false,
    share_tried: bool = false,
    /// Its locals SHARE registers (shareFunction): at the start of each
    /// statement keyed here, the registers listed are cleared for their
    /// next owner.
    share: ?*ShareTable = null,
};

/// Statement (its own first and last byte, packed) -> the registers cleared
/// before it, because a local that shares them begins its stretch there.
pub const ShareTable = std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged(u8));

/// One statement sequence the emitter walked during a structure pass: how
/// many loops enclose it, and each element -- the key of its first
/// statement, and the bytes from that statement to the last one it consumed.
const SeqRec = struct {
    depth: u32,
    keys: std.ArrayListUnmanaged(u64) = .{},
    spans: std.ArrayListUnmanaged([2]u32) = .{},
};

fn stmtKeyBytes(n: ts.Node) u64 {
    return (@as(u64, n.startByte()) << 32) | n.endByte();
}

/// A header (`func`, `def`, `class`) or a loose statement, in source order.
const Piece = struct {
    node: ts.Node,
    off: u32,
    kind: enum { func, class, stmt },
};

/// Everything that is a DIRECT member of the file, a class, or a function --
/// never the inside of an `if`/`while`/`for`, which belongs to its statement.
fn gatherPieces(n: ts.Node, out: *std.ArrayListUnmanaged(Piece), alloc: std.mem.Allocator) Error!void {
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        const k = ch.kind();
        if (std.mem.eql(u8, k, "comment") or
            std.mem.eql(u8, k, "identifier") or
            std.mem.eql(u8, k, "qualified_identifier") or
            std.mem.eql(u8, k, "param_list") or
            std.mem.eql(u8, k, "class_parent")) continue;
        if (std.mem.eql(u8, k, "function_definition")) {
            try out.append(alloc, .{ .node = ch, .off = ch.startByte(), .kind = .func });
            try gatherPieces(ch, out, alloc);
        } else if (std.mem.eql(u8, k, "class_definition")) {
            try out.append(alloc, .{ .node = ch, .off = ch.startByte(), .kind = .class });
            try gatherPieces(ch, out, alloc);
        } else if (std.mem.eql(u8, k, "private_section")) {
            // The grammar nests the REST OF THE CLASS inside this node --
            // its attributes, its private methods, and their fallen-out
            // statements. Treated as one opaque statement, every private
            // method of every Softanza class was silently dropped. The
            // marker is a piece (pass 2 hands the class its context back
            // on it) and what it holds is walked like the class itself.
            try out.append(alloc, .{ .node = ch, .off = ch.startByte(), .kind = .stmt });
            try gatherPieces(ch, out, alloc);
        } else {
            try out.append(alloc, .{ .node = ch, .off = ch.startByte(), .kind = .stmt });
        }
    }
}

/// The bare word `private` on its own line inside a class. Ring treats it as
/// a section marker, and what follows it is the class's again -- see the
/// attribute walk in collectAll.
fn isPrivateMarker(n: ts.Node) bool {
    // The grammar gives `private` its own node when it can, and the rest of
    // the class nests INSIDE it; when the word fell into a method body
    // (F-58) it is a bare identifier statement instead. Both are the marker.
    if (std.mem.eql(u8, n.kind(), "private_section")) return true;
    if (!std.mem.eql(u8, n.kind(), "expression_statement") or n.namedChildCount() != 1) return false;
    const e = n.namedChild(0);
    return std.mem.eql(u8, e.kind(), "identifier") and std.ascii.eqlIgnoreCase(e.text(), "private");
}

fn lessPiece(_: void, a: Piece, b: Piece) bool {
    return a.off < b.off;
}

/// The file behind each parsed root, in the same order, so a `load` can be
/// resolved back to the root it names. Set by the driver after it walks the
/// load graph; empty means "cannot resolve", and the splice below then
/// leaves the order alone rather than guessing at it.
pub var load_paths: []const []const u8 = &.{};
/// The source buffer of each loaded file, parallel to load_paths, so a
/// statement's node (which points into one of them) names its file.
pub var load_srcs: []const [*]const u8 = &.{};

/// How many string comparisons each by-name lookup performed, and how
/// large its table was at the end. Printed by `rnxc census` as `scans:`
/// because a 114,796-statement unit compiled at 700 statements/s while a
/// 1,687-statement one ran at 56,000/s -- a quadratic scan somewhere, and
/// this is how it was found and how it stays found.
/// For the three that are hashed now (nameIndex, funcIndex, findFunc) the
/// count is LOOKUPS; for the rest it is still comparisons. A hashed one
/// climbing back into the billions is the scan returning.
pub var scans = [_]u64{0} ** 10; // knownGlobal globalSlot nameIndex findClass funcIndex findFunc attrSlotOf konstIndex methodOf lookup
pub var sizes = [_]usize{0} ** 8; // globals names funcs konst code locals cap_locals stmts
/// Nanoseconds per phase of `census`: collect, splice, pass A, the
/// classify rounds, pass B -- and the number of rounds in [5].
pub var census_ns = [_]u64{0} ** 6;
/// Arena capacity at each census phase boundary, so "where does the memory
/// go" is answered by measurement rather than by reasoning about struct
/// sizes. Set by whoever owns the arena; unset leaves the row silent.
pub var capFn: ?*const fn () usize = null;
pub var census_mem = [_]usize{0} ** 6;
fn capAt(i: usize) void {
    if (capFn) |f| census_mem[i] = f();
}
/// Nanoseconds inside collectAll, summed over files: gather, sort,
/// pass 1, the class loop, pass 2.
pub var collect_ns = [_]u64{0} ** 5;

/// Lower-case, forward slashes -- the same key the driver dedups on, so a
/// resolved load target and a root's own path compare equal.
fn pathKey(alloc: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, p.len);
    for (p, 0..) |ch, i| out[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
    return out;
}

/// Where rnxc runs from, filled by the driver -- the loader's `<exefolder>`.
/// The two must agree about which file a load names, or the loaded file's
/// top level runs in the wrong place.
pub var exe_dir: []const u8 = ".";

/// Which root does this `load` name? THE SAME RULE THE LOADER USED, and it
/// has to be: when the loader resolved against the current directory and
/// this resolved against the loading file's, the splice below could not
/// find the target, and a loaded file's top level ran after its loader's
/// instead of at the load statement (caught 2026-09-10, one probe).
fn loadTarget(alloc: std.mem.Allocator, from: u32, n: ts.Node) ?u32 {
    if (n.namedChildCount() == 0) return null;
    var lit = n.namedChild(0).text();
    if (lit.len >= 2 and (lit[0] == '"' or lit[0] == '\'' or lit[0] == '`')) lit = lit[1 .. lit.len - 1];
    if (lit.len == 0) return null;

    const rooted = (lit[0] == '/' or lit[0] == '\\') and
        !(lit.len > 1 and (lit[1] == '/' or lit[1] == '\\'));
    var cands: [4][]const u8 = undefined;
    var n_cands: usize = 0;
    if (rooted) {
        // F-127, the loader's order: as written, beside the exe, in load/
        cands[0] = alloc.dupe(u8, lit) catch return null;
        cands[1] = std.fs.path.join(alloc, &.{ exe_dir, lit[1..] }) catch return null;
        cands[2] = std.fs.path.join(alloc, &.{ exe_dir, "load", lit[1..] }) catch return null;
        n_cands = 3;
    } else if (std.fs.path.isAbsolute(lit)) {
        cands[0] = alloc.dupe(u8, lit) catch return null;
        n_cands = 1;
    } else {
        // the root file's loads are cwd-relative, every other file's are
        // relative to itself -- the loader's rule, and it must be the same
        // one or the splice cannot find the target
        // C-4: beside the loading file first, for the root too; the launch
        // directory only as the root's fallback -- the loader's rule.
        const d = std.fs.path.dirname(load_paths[from]) orelse ".";
        cands[0] = std.fs.path.join(alloc, &.{ d, lit }) catch return null;
        n_cands = 1;
        if (from == 0) {
            cands[n_cands] = alloc.dupe(u8, lit) catch return null;
            n_cands += 1;
        }
        cands[n_cands] = std.fs.path.join(alloc, &.{ exe_dir, lit }) catch return null;
        cands[n_cands + 1] = std.fs.path.join(alloc, &.{ exe_dir, "load", lit }) catch return null;
        n_cands += 2;
    }

    for (cands[0..n_cands]) |c| {
        const want = pathKey(alloc, c) catch continue;
        for (load_paths, 0..) |p, i| {
            const have = pathKey(alloc, p) catch continue;
            if (std.mem.eql(u8, have, want)) return @intCast(i);
        }
    }
    // A relative literal the loader opened through the current directory is
    // recorded as an ABSOLUTE path by the operating system; compare on the
    // tail as a last resort rather than losing the splice.
    if (!rooted and !std.fs.path.isAbsolute(lit)) {
        const want = pathKey(alloc, lit) catch return null;
        for (load_paths, 0..) |p, i| {
            const have = pathKey(alloc, p) catch continue;
            if (std.mem.endsWith(u8, have, want) and
                (have.len == want.len or have[have.len - want.len - 1] == '/')) return @intCast(i);
        }
    }
    return null;
}

/// Append one file's top-level statements, splicing in each file it loads
/// AT THE LOAD STATEMENT.
///
/// Ring runs a loaded file's top level right there, so a statement after a
/// `load` sees what that file set up. Ring++ parsed every load up front and
/// ran each file's top level as one block in queue order, which put
/// Softanza's `StzMetaInit()` (stzRingLibs.ring line 116) BEFORE the
/// `$pStzMetaHandle = LoadLib(...)` it depends on (line 113's file).
fn spliceOne(
    roots: []const ts.Node,
    ri: u32,
    out: *std.ArrayListUnmanaged(ts.Node),
    visited: []bool,
    alloc: std.mem.Allocator,
) Error!void {
    if (visited[ri]) return;
    visited[ri] = true;
    const root = roots[ri];
    // Everything after the first `func`/`class` belongs to it, not to the
    // file -- the same rule the piece walk applies. Loads still count
    // wherever they sit, because Ring processes them as it parses.
    var seen_def = false;
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const ch = root.namedChild(i);
        const k = ch.kind();
        if (std.mem.eql(u8, k, "function_definition") or
            std.mem.eql(u8, k, "class_definition"))
        {
            seen_def = true;
            continue;
        }
        if (std.mem.eql(u8, k, "comment")) continue;
        if (std.mem.eql(u8, k, "load_statement")) {
            if (loadTarget(alloc, ri, ch)) |t| try spliceOne(roots, t, out, visited, alloc);
            continue;
        }
        if (!seen_def) try out.append(alloc, ch);
    }
}

/// F-128: mark the targets of every `load` nested inside `n` -- a block of a
/// file's top level -- that no top-level load has already reached. A load
/// inside a function or a class is not followed: Ring++ keeps those as they
/// were.
fn markNestedLoads(alloc: std.mem.Allocator, ri: u32, n: ts.Node, visited: []const bool, nested: []bool) void {
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        const k = ch.kind();
        if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition")) continue;
        if (std.mem.eql(u8, k, "load_statement")) {
            if (loadTarget(alloc, ri, ch)) |t| {
                if (!visited[t]) nested[t] = true;
            }
            continue;
        }
        markNestedLoads(alloc, ri, ch, visited, nested);
    }
}

/// A bare name inside a function that is ALSO a `$` global.
pub const Shadow = struct {
    byte: u32,
    src: []const u8,
    name: []const u8,
    /// Index of the function it sits in.
    fi: u32,
    /// Is this an assignment TARGET (or a loop variable)?
    write: bool,
    /// The first time this function mentions the name?
    first: bool,
    /// The function it sits in, by name -- the bare-global report prints
    /// it; the `$` report finds it through `fi` itself.
    fname: []const u8 = "",
};

/// One BARE top-level global's verdict (C-2): the name the top level
/// writes, and what the functions that also use it bare do with it.
pub const BareName = struct {
    name: []const u8,
    /// Functions, methods and lambdas whose FIRST use of the name WRITES
    /// it. On Ring that write lands in the global; here, in a local. The
    /// silent half of C-2.
    writers: u32 = 0,
    /// Named functions and methods whose first use READS it. Ring reads
    /// the global; Ring++ refuses the read at compile time (Rule A), so
    /// these are LOUD -- in the census, not silent.
    read_first_fn: u32 = 0,
    /// Lambdas whose first use reads it: a global read on Ring++ as on Ring
    /// (2026-09-22), so a lambda is a READER of the global.
    read_first_lam: u32 = 0,
    /// Reads of it at the top level, of any loaded file.
    top_reads: u32 = 0,
    /// One writer, for the report.
    witness: []const u8 = "",
    at_src: []const u8 = "",
    at_byte: u32 = 0,

    pub const Verdict = enum { none, reader, scratch };
    /// `reader`: something written in a function and read OUTSIDE it --
    /// by the top level, a lambda, or a function that reads it first. On
    /// Ring the reader sees the write; on Ring++ it never arrives. `scratch`:
    /// written first and read by nothing else, so Ring overwrites a global
    /// nobody reads again and the local is what was meant. `none`: never
    /// written in a function.
    pub fn verdict(self: BareName) Verdict {
        if (self.writers == 0) return .none;
        if (self.top_reads > 0 or self.read_first_lam > 0 or self.read_first_fn > 0) return .reader;
        return .scratch;
    }
};

/// One name's verdict across the whole program.
pub const ShadowName = struct {
    name: []const u8,
    funcs: u32,
    /// Functions whose FIRST use of the name is a read -- they depend on
    /// some other function's write, or on the global's initial value.
    read_first: u32,
    /// One such function, for the report.
    witness: []const u8,
};

const Seen = struct { name: []const u8 };

fn nameIsGlobal(c: *Compiler, t: []const u8) bool {
    for (c.globals.items) |g| {
        if (g.len == t.len + 1 and g[0] == '$' and std.ascii.eqlIgnoreCase(g[1..], t)) return true;
    }
    return false;
}

/// Inside a method, a bare name that is an ATTRIBUTE of the owning class
/// (or a parent) is that attribute -- Ring resolves it before any global.
/// The first draft of this walk called `n`, `Hour`, `data` and `oConfig`
/// cross-function globals; they are attributes, and a `$` on them would
/// have swapped the object's field for a global of the same name.
fn ownerHasAttr(c: *Compiler, owner: ?u16, t: []const u8) bool {
    var cur = owner;
    var guard: u32 = 0;
    while (cur) |cid| : (guard += 1) {
        if (guard > 64 or cid >= c.classes.items.len) return false;
        for (c.classes.items[cid].attrs.items) |a| {
            const an = if (a.name.len > 0 and a.name[0] == '@') a.name[1..] else a.name;
            if (std.ascii.eqlIgnoreCase(an, t)) return true;
        }
        cur = c.classes.items[cid].parent;
    }
    return false;
}

/// A bare name in callee position (`second(x)`) names a FUNCTION, and one
/// after a dot (`o.second`) names a member; neither is the variable, so
/// neither is a site. The target of `x = ...` is a WRITE; the root of
/// `x[1] = ...` is a READ of the container.
fn walkShadows(
    c: *Compiler,
    f: *const Func,
    fi: u32,
    n: ts.Node,
    writing: bool,
    seen: *std.ArrayListUnmanaged(Seen),
    out: *std.ArrayListUnmanaged(Shadow),
    loops: *usize,
    alloc: std.mem.Allocator,
) Error!void {
    const k = n.kind();
    // A symbol is a string literal -- `:none` as an argument, `:tab` as a
    // hash key -- and the grammar nests an identifier inside it. Walking
    // into it counted `:none` and `:tab = "box"` as bare uses of the
    // globals $none and $tab: the 55th shadow site of 2026-09-11, in
    // stzDiagram.ring, was exactly that. A symbol is never a variable.
    if (std.mem.eql(u8, k, "symbol")) return;
    if (std.mem.eql(u8, k, "identifier")) {
        const t = n.text();
        if (t.len == 0 or t[0] == '$' or t[0] == '@' or t[0] == ':') return;
        for (f.params) |p| if (std.ascii.eqlIgnoreCase(p, t)) return;
        if (!nameIsGlobal(c, t)) return;
        if (ownerHasAttr(c, f.owner, t)) return;
        var first = true;
        for (seen.items) |s| if (std.ascii.eqlIgnoreCase(s.name, t)) {
            first = false;
        };
        if (first) try seen.append(alloc, .{ .name = t });
        try out.append(alloc, .{ .byte = n.startByte(), .src = n.src, .name = t, .fi = fi, .write = writing, .first = first });
        return;
    }
    if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() >= 2) {
        const tgt = n.namedChild(0);
        try walkShadows(c, f, fi, tgt, std.mem.eql(u8, tgt.kind(), "identifier"), seen, out, loops, alloc);
        var j: u32 = 1;
        while (j < n.namedChildCount()) : (j += 1) {
            try walkShadows(c, f, fi, n.namedChild(j), false, seen, out, loops, alloc);
        }
        return;
    }
    var from: u32 = 0;
    if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() > 0) {
        // `foo()` names a function; `g.Method()` READS g first. Same blind
        // spot the attribute walk had, fixed the same day.
        const callee = n.namedChild(0);
        if (std.mem.eql(u8, callee.kind(), "member_expression") and callee.namedChildCount() > 0) {
            try walkShadows(c, f, fi, callee.namedChild(0), false, seen, out, loops, alloc);
        }
        from = 1;
    }
    if (std.mem.eql(u8, k, "member_expression")) {
        if (n.namedChildCount() > 0) try walkShadows(c, f, fi, n.namedChild(0), false, seen, out, loops, alloc);
        return;
    }
    if (std.mem.eql(u8, k, "for_statement") or std.mem.eql(u8, k, "for_in_statement")) {
        // `for $x = ...` is not something to introduce by script: counted
        // and left for a person. The loop variable is still a WRITE for
        // the first-use question, so it is recorded as seen.
        if (n.namedChildCount() > 0 and std.mem.eql(u8, n.namedChild(0).kind(), "identifier")) {
            const t = n.namedChild(0).text();
            if (nameIsGlobal(c, t)) {
                loops.* += 1;
                var first = true;
                for (seen.items) |s| if (std.ascii.eqlIgnoreCase(s.name, t)) {
                    first = false;
                };
                if (first) try seen.append(alloc, .{ .name = t });
            }
            from = 1;
        }
    }
    var i: u32 = from;
    while (i < n.namedChildCount()) : (i += 1) {
        try walkShadows(c, f, fi, n.namedChild(i), false, seen, out, loops, alloc);
    }
}

/// Lower-cased into `buf`, for the bare-global set. Ring folds identifier
/// case (F-18), so `cWhy` and `CWHY` are one global. Null past 256 bytes,
/// which no identifier in the estate comes near.
fn lowerInto(buf: *[256]u8, t: []const u8) ?[]const u8 {
    if (t.len > buf.len) return null;
    for (t, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..t.len];
}

/// The shadows walk for C-2's BARE globals -- the names the top level
/// writes without a sigil, which C-2 made globals. `nameIsGlobal` matches
/// only `$` names, so until 2026-09-23 no bare-global site was ever
/// counted, although C-2's record called the guard exactly that.
///
/// The same exclusions as walkShadows -- a symbol, a callee, a member
/// after a dot, a parameter, an attribute of the owning class -- and two
/// of its own. An `anonymous_function` is NOT descended into: it is a
/// Func of its own and walked as one, and descending would count every
/// lambda use twice (walkShadows does, for `$` names; left alone, because
/// its count is pinned). And a lambda's CAPTURE is an enclosing local, not
/// the global. A `for` variable is not a site at all: Ring makes it the
/// function's local too (measured, below).
/// Is `f` a lambda whose defining scope, through any lambdas it sits
/// inside, is the top level? The free-function form of Compiler.lambdaOfMain.
fn lambdaDefinedAtTop(c: *const Compiler, f: *const Func) bool {
    var cur: *const Func = f;
    var guard: u32 = 0;
    while (cur.lambda_at != null and guard < 64) : (guard += 1) {
        const e = cur.encl orelse return false;
        if (e >= c.funcs.items.len) return false;
        cur = &c.funcs.items[e];
        if (cur.is_main) return true;
    }
    return false;
}

fn walkBare(
    c: *Compiler,
    f: *const Func,
    fi: u32,
    n: ts.Node,
    writing: bool,
    set: *const std.StringHashMapUnmanaged(void),
    seen: *std.ArrayListUnmanaged(Seen),
    out: *std.ArrayListUnmanaged(Shadow),
    alloc: std.mem.Allocator,
) Error!void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "symbol") or std.mem.eql(u8, k, "anonymous_function")) return;
    if (std.mem.eql(u8, k, "identifier")) {
        try bareSite(c, f, fi, n, writing, set, seen, out, alloc);
        return;
    }
    if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() >= 2) {
        const tgt = n.namedChild(0);
        try walkBare(c, f, fi, tgt, std.mem.eql(u8, tgt.kind(), "identifier"), set, seen, out, alloc);
        var j: u32 = 1;
        while (j < n.namedChildCount()) : (j += 1) {
            try walkBare(c, f, fi, n.namedChild(j), false, set, seen, out, alloc);
        }
        return;
    }
    var from: u32 = 0;
    if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() > 0) {
        const callee = n.namedChild(0);
        if (std.mem.eql(u8, callee.kind(), "member_expression") and callee.namedChildCount() > 0) {
            try walkBare(c, f, fi, callee.namedChild(0), false, set, seen, out, alloc);
        }
        from = 1;
    }
    if (std.mem.eql(u8, k, "member_expression")) {
        if (n.namedChildCount() > 0) try walkBare(c, f, fi, n.namedChild(0), false, set, seen, out, alloc);
        return;
    }
    if (std.mem.eql(u8, k, "for_statement") or std.mem.eql(u8, k, "for_in_statement")) {
        // NOT a site. Measured on 1.27: a `for` variable inside a function
        // is that function's LOCAL even when a global of the name exists --
        // `i = 100` at the top level survives `for i = 1 to 3` in F. The
        // first version counted it as a write of the global and flagged a
        // divergence that does not exist. It DEFINES the name for the rest
        // of the function instead, so a later use of it is the loop's own.
        if (n.namedChildCount() > 0 and std.mem.eql(u8, n.namedChild(0).kind(), "identifier")) {
            const t = n.namedChild(0).text();
            var already = false;
            for (seen.items) |s| if (std.ascii.eqlIgnoreCase(s.name, t)) {
                already = true;
            };
            if (!already) try seen.append(alloc, .{ .name = t });
            from = 1;
        }
    }
    var i: u32 = from;
    while (i < n.namedChildCount()) : (i += 1) {
        try walkBare(c, f, fi, n.namedChild(i), false, set, seen, out, alloc);
    }
}

fn bareSite(
    c: *Compiler,
    f: *const Func,
    fi: u32,
    n: ts.Node,
    writing: bool,
    set: *const std.StringHashMapUnmanaged(void),
    seen: *std.ArrayListUnmanaged(Seen),
    out: *std.ArrayListUnmanaged(Shadow),
    alloc: std.mem.Allocator,
) Error!void {
    const t = n.text();
    if (t.len == 0 or t[0] == '$' or t[0] == '@' or t[0] == ':') return;
    var buf: [256]u8 = undefined;
    const low = lowerInto(&buf, t) orelse return;
    if (!set.contains(low)) return;
    for (f.params) |p| if (std.ascii.eqlIgnoreCase(p, t)) return;
    for (f.captures.items) |cap| if (std.ascii.eqlIgnoreCase(cap, t)) return;
    // C-14 (2026-09-24): a lambda DEFINED AT THE TOP LEVEL writes the
    // global on both runtimes, so its bare write is no longer a site --
    // shape P3 of bench/shadows_bare.py agrees with Ring now. A lambda
    // inside a function stays one (P10), as the function itself does.
    if (f.lambda_at != null and lambdaDefinedAtTop(c, f)) return;
    if (ownerHasAttr(c, f.owner, t)) return;
    var first = true;
    for (seen.items) |s| if (std.ascii.eqlIgnoreCase(s.name, t)) {
        first = false;
    };
    if (first) try seen.append(alloc, .{ .name = t });
    try out.append(alloc, .{ .byte = n.startByte(), .src = n.src, .name = t, .fi = fi, .write = writing, .first = first, .fname = f.name });
}

pub const Shadows = struct {
    sites: []Shadow,
    names: []ShadowName,
    /// C-2's bare globals: every bare use of one inside a function, method
    /// or lambda, and the verdict per name. Pinned APART from the `$` count
    /// (bench/shadows_bare.max, 0 on the base unit since 2026-09-23).
    bare_sites: []Shadow = &.{},
    bare_names: []BareName = &.{},
    /// How many bare top-level globals the unit HAS -- printed, because a
    /// report of zero sites means nothing without the set it looked in.
    bare_globals: usize = 0,
};

/// Every bare use, inside a function, of a name the program also defines
/// as a `$` global -- and, per name, whether any function READS it before
/// writing it.
///
/// Measured on 1.27: inside a function, a bare assignment to a name that
/// also exists as a global WRITES THE GLOBAL; Ring has no local-by-default.
/// Rule A says local. The migration prefixed only what Rule A called a
/// global and left these bare, then renamed the global out from under
/// them. That splits into two very different populations:
///
///   * SCRATCH -- `_i_`, `_nLen_`, `_aResult_`: every function that uses
///     one writes it first. On the migrated library Ring now gives each
///     function its own local, which is what was always meant. Nothing to
///     fix; 28,000 sites, and prefixing them would entrench a shared
///     global that only ever worked by accident.
///
///   * CROSS-FUNCTION -- `_bInHistoryUpdate`: one function writes it for
///     another to read, or a function reads it before its own write.
///     These relied on Ring's global write, and on the migrated library
///     the read is R24 -- which is how `new stzList([1,2,3])` came to
///     fail. Every site of such a name gets its sigil back, in every
///     function, because the writers were writing FOR the readers.
pub fn shadows(alloc: std.mem.Allocator, roots: []const ts.Node, loops_out: *usize) !Shadows {
    var c = Compiler{ .alloc = alloc, .census = true };
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    c.scratch_arena = &scratch_arena;
    c.scratch = scratch_arena.allocator();
    last_fail = .{};
    for (roots) |r| try collectAll(&c, r, alloc);
    try resolveAllSlots(&c, alloc);
    try emitAll(&c);

    var all = std.ArrayListUnmanaged(Shadow){};
    for (c.funcs.items, 0..) |*f, fi| {
        if (f.is_main) continue;
        var seen = std.ArrayListUnmanaged(Seen){};
        defer seen.deinit(alloc);
        for (f.stmts.items) |st| {
            try walkShadows(&c, f, @intCast(fi), st, false, &seen, &all, loops_out, alloc);
        }
    }

    // per name: how many functions, and how many of them read it first
    var names = std.ArrayListUnmanaged(ShadowName){};
    for (all.items) |s| {
        if (!s.first) continue;
        var idx: ?usize = null;
        for (names.items, 0..) |nm, i| if (std.ascii.eqlIgnoreCase(nm.name, s.name)) {
            idx = i;
        };
        if (idx == null) {
            try names.append(alloc, .{ .name = s.name, .funcs = 0, .read_first = 0, .witness = "" });
            idx = names.items.len - 1;
        }
        names.items[idx.?].funcs += 1;
        if (!s.write) {
            names.items[idx.?].read_first += 1;
            if (names.items[idx.?].witness.len == 0) names.items[idx.?].witness = c.funcs.items[s.fi].name;
        }
    }

    // C-2's BARE globals. A top-level name without a sigil is a global
    // since 2026-09-09, and a function that assigns it bare WRITES it on
    // Ring and makes a local here. The globals list holds both kinds; a
    // bare entry is one the top level wrote (globalSlot's callers are the
    // top-level assignment, `give`, and a global loop variable).
    var set = std.StringHashMapUnmanaged(void){};
    for (c.globals.items) |g| {
        if (g.len == 0 or g[0] == '$' or g[0] == '@') continue;
        var buf: [256]u8 = undefined;
        const low = lowerInto(&buf, g) orelse continue;
        if (set.contains(low)) continue;
        try set.put(alloc, try alloc.dupe(u8, low), {});
    }
    var bare = std.ArrayListUnmanaged(Shadow){};
    var top_reads = std.StringHashMapUnmanaged(u32){};
    for (c.funcs.items, 0..) |*f, fi| {
        var seen = std.ArrayListUnmanaged(Seen){};
        defer seen.deinit(alloc);
        const start = bare.items.len;
        for (f.stmts.items) |st| {
            try walkBare(&c, f, @intCast(fi), st, false, &set, &seen, &bare, alloc);
        }
        if (!f.is_main) continue;
        // The top level's own uses are not divergences -- they ARE the
        // global. Only its reads matter, as readers of what a function
        // may have written.
        for (bare.items[start..]) |s| {
            if (s.write) continue;
            var buf: [256]u8 = undefined;
            const low = lowerInto(&buf, s.name) orelse continue;
            const gop = try top_reads.getOrPut(alloc, try alloc.dupe(u8, low));
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        bare.shrinkRetainingCapacity(start);
    }
    var bnames = std.ArrayListUnmanaged(BareName){};
    for (bare.items) |s| {
        if (!s.first) continue;
        var idx: ?usize = null;
        for (bnames.items, 0..) |nm, i| if (std.ascii.eqlIgnoreCase(nm.name, s.name)) {
            idx = i;
        };
        if (idx == null) {
            var buf: [256]u8 = undefined;
            const low = lowerInto(&buf, s.name) orelse s.name;
            try bnames.append(alloc, .{ .name = s.name, .top_reads = top_reads.get(low) orelse 0 });
            idx = bnames.items.len - 1;
        }
        const b = &bnames.items[idx.?];
        const is_lambda = c.funcs.items[s.fi].lambda_at != null;
        if (s.write) {
            b.writers += 1;
            if (b.witness.len == 0) {
                b.witness = c.funcs.items[s.fi].name;
                b.at_src = s.src;
                b.at_byte = s.byte;
            }
        } else if (is_lambda) {
            b.read_first_lam += 1;
        } else {
            b.read_first_fn += 1;
        }
    }
    return .{
        .sites = try all.toOwnedSlice(alloc),
        .names = try names.toOwnedSlice(alloc),
        .bare_sites = try bare.toOwnedSlice(alloc),
        .bare_names = try bnames.toOwnedSlice(alloc),
        .bare_globals = set.count(),
    };
}

/// A bare use of `name` inside one function -- the same exclusions as the
/// shadows walk: a callee is a function, a property after a dot is a
/// member, and neither is the attribute.
fn walkAttrUses(f: *const Func, name: []const u8, n: ts.Node, out: *std.ArrayListUnmanaged(Shadow), alloc: std.mem.Allocator) Error!void {
    const k = n.kind();
    // the same blind spot as the shadows walk: a symbol is a literal
    if (std.mem.eql(u8, k, "symbol")) return;
    if (std.mem.eql(u8, k, "identifier")) {
        const t = n.text();
        if (!std.ascii.eqlIgnoreCase(t, name)) return;
        for (f.params) |p| if (std.ascii.eqlIgnoreCase(p, t)) return;
        try out.append(alloc, .{ .byte = n.startByte(), .src = n.src, .name = t, .fi = 0, .write = false, .first = false });
        return;
    }
    var from: u32 = 0;
    if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() > 0) {
        // The callee of `foo()` is a function name, not a variable. But
        // the callee of `oOwner.Base()` is a member expression whose
        // RECEIVER is a variable read -- skipping it whole left
        // `oRppOwner.Base()` unrenamed and every gate at R24 on that line.
        const callee = n.namedChild(0);
        if (std.mem.eql(u8, callee.kind(), "member_expression") and callee.namedChildCount() > 0) {
            try walkAttrUses(f, name, callee.namedChild(0), out, alloc);
        }
        from = 1;
    }
    if (std.mem.eql(u8, k, "member_expression")) {
        if (n.namedChildCount() > 0) try walkAttrUses(f, name, n.namedChild(0), out, alloc);
        return;
    }
    var i: u32 = from;
    while (i < n.namedChildCount()) : (i += 1) {
        try walkAttrUses(f, name, n.namedChild(i), out, alloc);
    }
}

/// The class-aware half of Rule A: for every attribute a class declares
/// WITHOUT the `@` sigil -- Ring's own style, `nRppCap` on a line of its
/// own or `nRppCap = 0` -- the declaration site and every bare use inside
/// that class's methods, so the applier can put `@` on all of them
/// TOGETHER. A rename, not an insert: the byte applier alone prefixed
/// these as globals and broke Ring (rpp/ migration, 2026-09-03).
///
/// `This.x` and `obj.x` are not emitted: none exist in the library this
/// was built for, and either would need its own measured answer first.
pub fn attrSites(alloc: std.mem.Allocator, roots: []const ts.Node) ![]Shadow {
    var c = Compiler{ .alloc = alloc, .census = true };
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    c.scratch_arena = &scratch_arena;
    c.scratch = scratch_arena.allocator();
    last_fail = .{};
    for (roots) |r| try collectAll(&c, r, alloc);
    try resolveAllSlots(&c, alloc);

    var out = std.ArrayListUnmanaged(Shadow){};
    for (c.classes.items) |ci| {
        for (ci.attrs.items) |a| {
            if (a.name.len == 0) continue;
            // An attribute ALREADY declared `@name` can still have bare
            // uses left behind -- a half-finished rename, which is what a
            // walk that missed one site leaves. Then only the uses are
            // wanted, under the stripped name.
            if (a.name[0] == '@') {
                if (a.name.len == 1) continue;
                const bare = a.name[1..];
                for (ci.methods.items) |mi| {
                    const f = &c.funcs.items[mi];
                    for (f.stmts.items) |st| try walkAttrUses(f, bare, st, &out, alloc);
                }
                continue;
            }
            // the declaration: a direct child of the class node, before
            // its first method -- a bare identifier or an assignment
            var k: u32 = 0;
            while (k < ci.node.namedChildCount()) : (k += 1) {
                const ch = ci.node.namedChild(k);
                if (std.mem.eql(u8, ch.kind(), "function_definition")) break;
                if (!std.mem.eql(u8, ch.kind(), "expression_statement") or ch.namedChildCount() == 0) continue;
                var e = ch.namedChild(0);
                if (std.mem.eql(u8, e.kind(), "assignment_expression") and e.namedChildCount() > 0) e = e.namedChild(0);
                if (std.mem.eql(u8, e.kind(), "identifier") and std.ascii.eqlIgnoreCase(e.text(), a.name)) {
                    try out.append(alloc, .{ .byte = e.startByte(), .src = e.src, .name = e.text(), .fi = 0, .write = true, .first = true });
                }
            }
            // every bare use in the class's own methods
            for (ci.methods.items) |mi| {
                const f = &c.funcs.items[mi];
                for (f.stmts.items) |st| try walkAttrUses(f, a.name, st, &out, alloc);
            }
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Rebuild @@main's statements in the order Ring would execute them.
///
/// `start` is the file the walk begins at, and every file before it is left
/// out entirely. It is 0 for a whole unit. A PREFIX starts at 1: the file
/// at 0 is the one that will be compiled on top, so the library's own order
/// is the walk from the first thing that file loads -- which is the same
/// order those statements would have had in the whole unit, with the root's
/// own statements removed.
fn spliceMain(c: *Compiler, roots: []const ts.Node, start: u32, alloc: std.mem.Allocator) Error!void {
    const mi = c.main_fn orelse return;
    if (load_paths.len != roots.len or roots.len <= start) return;

    var ordered = std.ArrayListUnmanaged(ts.Node){};
    defer ordered.deinit(alloc);
    const visited = try alloc.alloc(bool, roots.len);
    defer alloc.free(visited);
    @memset(visited, false);
    for (0..start) |i| visited[i] = true;

    try spliceOne(roots, start, &ordered, visited, alloc);

    // F-128: the files only a load INSIDE A BLOCK reaches. Their top level
    // is laid out here as before -- so every pass before code generation
    // sees it -- but recorded, so code generation emits it at that load.
    const nested = try alloc.alloc(bool, roots.len);
    defer alloc.free(nested);
    @memset(nested, false);
    for (roots, 0..) |root, ri| {
        if (ri < start) continue;
        var seen_def = false;
        var i: u32 = 0;
        while (i < root.namedChildCount()) : (i += 1) {
            const ch = root.namedChild(i);
            const k = ch.kind();
            if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition")) seen_def = true;
            if (seen_def or std.mem.eql(u8, k, "load_statement")) continue;
            markNestedLoads(alloc, @intCast(ri), ch, visited, nested);
        }
    }
    c.nested_stmts.clearRetainingCapacity();
    c.nested_skip.clearRetainingCapacity();
    for (roots, 0..) |_, i| {
        if (visited[i] or !nested[i]) continue;
        const from = ordered.items.len;
        try spliceOne(roots, @intCast(i), &ordered, visited, alloc);
        const own = try alloc.dupe(ts.Node, ordered.items[from..]);
        try c.nested_stmts.put(alloc, @intCast(i), own);
        for (own) |st| try c.nested_skip.put(alloc, stmtKey(st), {});
    }

    // A file nothing loads still runs its top level, after -- dropping it
    // would lose code that the old order did run.
    for (roots, 0..) |_, i| {
        if (!visited[i]) try spliceOne(roots, @intCast(i), &ordered, visited, alloc);
    }

    c.funcs.items[mi].stmts.clearRetainingCapacity();
    for (ordered.items) |st| try c.funcs.items[mi].stmts.append(alloc, st);
}

pub const Refusal = struct {
    kind: []const u8,
    row: u32,
    text: []const u8,
    func: []const u8,
    /// Byte offset of the offending node, and the source it sits in.
    /// Together these name a site precisely enough to rewrite it -- which
    /// is what the Rule A migration needs and what a regex cannot supply.
    byte: u32 = 0,
    src: []const u8 = &.{},
};

pub const Attr = struct { name: []const u8, slot: u32 };

/// A class body's `nCount = 7` lines are a CONSTRUCTOR, and Ring runs them
/// on `new` before `init`. Nothing in the source says so, which is why
/// they were invisible here until bare attributes started resolving: the
/// slots stayed nil and every read of one was quietly wrong. They are
/// gathered into a synthetic method instead.
pub const PROLOGUE = "@@attrs";

/// The synthetic function holding every file's top-level statements, in
/// load order. Ring runs that code, and the names it assigns are the
/// program's globals.
pub const MAIN = "@@main";

/// A call site waiting for its callee to be emitted, patched at the end.
pub const Fixup = extern struct { site: u32, fidx: u32, from: u32 };

/// A statement's identity across passes: its source buffer and where it starts.
pub const NodeKey = struct { src: usize, byte: u32 };
pub fn stmtKey(n: ts.Node) NodeKey {
    return .{ .src = @intFromPtr(n.src.ptr), .byte = n.startByte() };
}

pub const ClassInfo = struct {
    name: []const u8,
    node: ts.Node,
    parent_name: []const u8 = "",
    parent: ?u16 = null,
    /// Index into `funcs` of this class's attribute prologue, if it has
    /// one. A child inherits its parent's initialisers by copying them in
    /// front of its own, so one call at the `new` site covers the chain.
    attrs_fn: ?u32 = null,
    attrs_done: bool = false,
    /// Own attributes AND inherited ones, flattened. A slot index is a
    /// compile-time constant, which is the point: Ring looks an attribute up
    /// by name in a list of lists at runtime.
    attrs: std.ArrayListUnmanaged(Attr) = .{},
    methods: std.ArrayListUnmanaged(u32) = .{},
    id: u16 = 0,
    /// How many of `attrs` came from the parent, so the class's OWN
    /// declarations can be found again and the layout rebuilt. It is
    /// rebuilt because a parent can arrive after its child: Softanza loads
    /// number/stzListOfNumbers.ring at line 58 of stzBase and the stzList
    /// it inherits from at line 253, and a one-shot `resolved` flag froze
    /// that child with no parent at all.
    inherited: u32 = 0,
    /// The resolve pass this class was last laid out in, so one pass does
    /// each class once and parents first, through the recursion.
    pass: u32 = 0,
    resolving: bool = false,
    /// The same, for the attribute-initialiser prologue, and how many of
    /// its leading statements were copied in from the parent.
    graft_pass: u32 = 0,
    grafted: u32 = 0,
    grafting: bool = false,
    /// The parent's prologue to CALL first, when its statements cannot be
    /// copied: a parent restored from the PREFIX arrives compiled, without
    /// its parse trees, so a class compiled on top of the library had no
    /// parent initialisers at all -- `@nWorkbench` read back as R24 in a
    /// test-side `class watcherAgentClass from stzPIAgent` (2026-10-17).
    /// The parent's compiled prologue already carries its own ancestors'.
    parent_prologue: ?u32 = null,
};

/// The function each instruction belongs to: functions are laid out
/// contiguously, so it is the one with the greatest entry <= pc.
/// A function never compiled keeps entry 0, which is also @@main's
/// address, so an entry of 0 counts only for @@main.
/// `body_end` is where the compiled functions stop and the TRAMPOLINES
/// begin. They belong to no function, and saying otherwise put a wrong
/// name in a call chain: the last function by address owned everything to
/// the end of the code, trampolines included, so a frame entered from one
/// of them reported `In function <whatever was last>()` where Ring reports
/// the file alone. It never showed while every program had a top level --
/// the chain stops at @@main's frame, which is below the trampoline -- and
/// it showed the day Main() began to be called from the entry in a file
/// that has no top level at all (2026-09-22).
fn fnOfTable(alloc: std.mem.Allocator, funcs: []const Func, n: usize, body_end: usize) ![]const u32 {
    const out = try alloc.alloc(u32, n);
    @memset(out, std.math.maxInt(u32));
    // sort function ids by entry
    const ids = try alloc.alloc(u32, funcs.len);
    for (ids, 0..) |*x, i| x.* = @intCast(i);
    std.mem.sort(u32, ids, funcs, struct {
        fn lt(fs: []const Func, a: u32, b: u32) bool {
            return fs[a].entry < fs[b].entry;
        }
    }.lt);
    for (ids, 0..) |id, k| {
        const from = funcs[id].entry;
        if (from == std.math.maxInt(u32) or from >= body_end) continue;
        if (!funcs[id].emitted) continue;
        var to: usize = body_end;
        var j = k + 1;
        while (j < ids.len) : (j += 1) {
            const e = funcs[ids[j]].entry;
            if (e != std.math.maxInt(u32) and e > from) {
                to = @min(to, e);
                break;
            }
        }
        @memset(out[from..to], id);
    }
    return out;
}

pub const Program = struct {
    code: []vm.Instr,
    funcs: []Func,
    /// Per instruction: source row, file index, and the function it
    /// belongs to -- Ring's runtime error report reads all three.
    rows: []const u32 = &.{},
    files: []const u16 = &.{},
    fn_of: []const u32 = &.{},
    main_fn: u32 = 0,
    /// The name table, so the VM can resolve and report `ncall` targets.
    names: []const []const u8 = &.{},
    /// How many `$x` global slots the program needs -- one per distinct
    /// name, resolved to an index at compile time.
    nglobals: usize = 0,
    /// Their names, in slot order, so a read of one nothing assigned can
    /// raise R24 naming it the way Ring does.
    global_names: []const []const u8 = &.{},
    /// Entry address and frame size per function id, for closure calls.
    fn_entry: []const u32 = &.{},
    fn_frame: []const u8 = &.{},
    /// EVERY FUNCTION'S LOCALS -- name, register, boxed -- so `eval` can
    /// bind a string compiled at RUN TIME to its caller's frame (F-72, C-9
    /// revised): `fn_local_from[fid] .. fn_local_from[fid + 1]` index the
    /// three flat tables. Parameters included, in register order.
    fn_local_from: []const u32 = &.{},
    local_names: []const []const u8 = &.{},
    local_regs: []const u8 = &.{},
    local_boxed: []const bool = &.{},
    /// Per class, the function id of its attribute prologue (`@@attrs`),
    /// 0xFFFFFFFF for none -- `new K` inside eval has to call it and cannot
    /// find it by name, since every prologue shares one.
    class_attrs_fn: []const u32 = &.{},
    /// Functions whose OWN body failed, before poison spread to callers.
    /// The gap between this and the final count is what the conservative
    /// dispatch rule costs, and it deserves to be visible.
    poisoned_direct: usize = 0,
    /// ...of which, poisoned only because a same-named method somewhere is.
    poisoned_dynamic: usize = 0,
    /// Own-body failures ranked by how much they hold hostage. Populated
    /// only by `compileRanked` -- the bitsets cost memory nobody shipping a
    /// program should pay.
    ranking: Ranking = .{},
    /// Where a program built on a PREFIX starts: one trampoline that calls
    /// the library's top level and then this file's. Null when there was no
    /// prefix, and the single @@main's own trampoline is the entry.
    entry_tramp: ?u32 = null,

    pub fn find(self: Program, name: []const u8) ?*const Func {
        for (self.funcs) |*f| {
            if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
        }
        return null;
    }

    pub fn usableCount(self: Program) usize {
        var n: usize = 0;
        for (self.funcs) |f| {
            if (!f.poisoned) n += 1;
        }
        return n;
    }
};

/// A loop variable whose loop has ended, in one function (C-11).
const Retired = struct { fi: u32, name: []const u8 };

/// One `obj { ... }` block being compiled: its object register and class.
const BraceCtx = struct { reg: u8, cid: ?u16 };

/// EVAL MODE (F-72, C-9 revised): the compiler bound to a RUNNING frame.
///
/// `eval(code)` compiles its string while the program runs, in the frame of
/// the function that called it: the caller's locals are registers by
/// number (the image's locals tables), its attributes are reached by NAME
/// through the receiver in r0, its globals through `global_names`, user
/// functions through the string-call path (`calli` on the name), methods
/// by `callm` with the name's index, classes by name through the class
/// constant table, builtins from the static table. The eval's own
/// registers start at `frame` -- the caller's frame size, or above an
/// enclosing eval -- and a new name the string assigns becomes one of them.
/// The code is emitted from address 0 and relocated onto the VM's growing
/// code by the hook (rnxc.zig), which also runs it and sweeps the registers.
pub const EvalCtx = struct {
    vm_: *vm.VM,
    frame: u8,
    owner: ?u16,
    is_main: bool,
    konst_base: i32,
    next_reg: u8 = 0,
    /// lower-cased class name -> id, built once from the VM's tables
    classes: *std.StringHashMapUnmanaged(u16),
};
pub const LocalSpec = struct { name: []const u8, reg: u8, boxed: bool };
pub const EvalOut = struct { code: []vm.Instr, konst: []const vm.Value, high: u8 };

/// Eval'd code is emitted from 0: the jumps move with it. Only the opcodes
/// whose `d` is a code address; a `call` emitted in eval mode carries the
/// callee's absolute entry and must not move.
pub fn relocate(code: []vm.Instr, base: u32) void {
    for (code) |*in| {
        switch (in.op) {
            .jmp, .jlt, .jle, .jgt, .jge, .jeq, .jne, .jeqi, .jnei, .jgti, .jfalsy, .jtruthy, .forloop, .forloops, .ptry, .jmpl, .lnhi => in.d += @intCast(base),
            else => {},
        }
    }
}

/// The locals assigned on EVERY path to a point, as a bitset of registers,
/// and whether that point is reachable at all (`dead` after a return, a
/// raise, an exit or a loop: nothing after it on the path runs, so it
/// constrains nothing where paths meet).
/// F-114: a statement's last postfix construct (its byte span's start and
/// end) and the line of the token after it.
const Tail = struct { end: u32, pf_start: u32, row: u32 };

/// F-114: RING READS PAST THE NEWLINE AFTER A POSTFIX CONSTRUCT before it
/// finishes the statement. After `a[i]`, `f()`, `(x)` or `o.v` its parser
/// looks for a `.` continuing the chain on the next line, and passing the
/// newline emits the next line's marker -- ahead of the operators that
/// complete the statement, which then report THAT line: `x = 0 + aL[1]` with
/// aL[1] a string is R41 at the next statement's line, or at the `ok`,
/// `else`, `next` or `func` that follows, comments and blank lines passed.
/// An identifier, a literal or a list literal last does not do it, nor a
/// next token on the same line. 28 shapes on both 1.27 builds, 2026-10-13.
/// Only a statement's rows change, so nothing runs differently.
fn tailOf(c: *Compiler, n: ts.Node) ?Tail {
    if (c.reread_src != null) return null;
    const pt = postfixTail(n) orelse return null;
    const pf = pt.pf;
    const cur = pt.leaf;
    const end = cur.endByte();
    const src = n.src;
    var p: usize = end;
    var nl: u32 = 0;
    while (p < src.len) {
        const ch = src[p];
        if (ch == '\n') {
            nl += 1;
            p += 1;
        } else if (ch == ' ' or ch == '\t' or ch == '\r') {
            p += 1;
        } else if (ch == '#' or (ch == '/' and p + 1 < src.len and src[p + 1] == '/')) {
            while (p < src.len and src[p] != '\n') p += 1;
        } else if (ch == '/' and p + 1 < src.len and src[p + 1] == '*') {
            p += 2;
            while (p + 1 < src.len and !(src[p] == '*' and src[p + 1] == '/')) : (p += 1) {
                if (src[p] == '\n') nl += 1;
            }
            p += 2;
        } else break;
    }
    if (nl == 0) return null;
    return .{ .end = @intCast(end), .pf_start = @intCast(pf.startByte()), .row = cur.end().row + 1 + nl };
}

/// F-114: a statement that ends in a postfix construct -- the construct
/// (the topmost one ending where the statement does) and the statement's
/// last token. Only the statements that emit something AFTER their value:
/// an expression statement (an assignment, or the stack freed), `?`/see,
/// `return`.
const PostfixTail = struct { pf: ts.Node, leaf: ts.Node };
fn postfixTail(n: ts.Node) ?PostfixTail {
    const k = n.kind();
    if (!(std.mem.eql(u8, k, "expression_statement") or std.mem.eql(u8, k, "see_statement") or
        std.mem.eql(u8, k, "return_statement"))) return null;
    var cur = n;
    var top_pf: ?ts.Node = null;
    while (cur.childCount() > 0) {
        var i = cur.childCount();
        var last: ?ts.Node = null;
        while (i > 0) {
            i -= 1;
            const ch = cur.child(i);
            if (!std.mem.eql(u8, ch.kind(), "comment")) {
                last = ch;
                break;
            }
        }
        const l = last orelse break;
        if (top_pf == null) {
            const lk = l.kind();
            if (std.mem.eql(u8, lk, "call_expression") or std.mem.eql(u8, lk, "subscript_expression") or
                std.mem.eql(u8, lk, "parenthesized_expression") or std.mem.eql(u8, lk, "member_expression")) top_pf = l;
        }
        cur = l;
    }
    const pf = top_pf orelse return null;
    if (pf.endByte() != cur.endByte()) return null;
    return .{ .pf = pf, .leaf = cur };
}

/// F-110: the code of one `if ... else ... ok` whose branches end in `jmpl`,
/// [start, end), and the statement level it stands at.
/// `srow`, once a statement follows: the row of its first line -- Ring runs
/// a marker at every newline it passes, inside a statement too, so only code
/// on that first line reports the line the jump carried.
const LnRegion = struct { start: u32, end: u32, level: u32, srow: u32 = 0 };

/// F-110: does the statement after this `if` lose its line marker to Ring's
/// merge? The `ok` label falls after the else body's last NEWLINE, so the
/// next statement's newline is merged into it -- when there is an else and
/// its body ends before the `ok`'s line, or ends in an if of this same shape
/// (that one's merged marker is then the last). An if without else ends its
/// last branch with a JUMP, which a newline cannot merge into.
fn ifMergesNext(n: ts.Node) bool {
    var else_cl: ?ts.Node = null;
    var i: u32 = 1;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        if (std.mem.eql(u8, ch.kind(), "else_clause")) else_cl = ch;
    }
    const e = else_cl orelse return false;
    var last: ?ts.Node = null;
    var j: u32 = 0;
    while (j < e.namedChildCount()) : (j += 1) {
        const ch = e.namedChild(j);
        if (std.mem.eql(u8, ch.kind(), "comment")) continue;
        last = ch;
    }
    // a last statement ending in a postfix construct has passed the newline
    // after it before its own last instruction (F-114), so the else body
    // ends on that instruction, not on a marker, and nothing merges
    if (last) |l| if (postfixTail(l) != null) return false;
    const last_row = if (last) |l| l.end().row else e.start().row;
    if (n.end().row > last_row) return true;
    if (last) |l| if (std.mem.eql(u8, l.kind(), "if_statement")) return ifMergesNext(l);
    return false;
}

/// RNXC_LINES_STATIC=1: every line from the static table, no F-110 record.
/// For a judge comparing the code of two LAYOUTS of one program -- the
/// formatter's court, Haro's graph court -- which compares no line (`rnxc
/// dis` prints none), while the record puts lines into the code itself and
/// exists only when an `ok` stands on its own line. Read once. An image is
/// not keyed on it: judges run with RNXC_NOCACHE.
var g_lines_static: ?bool = null;
fn linesStatic() bool {
    if (g_lines_static) |b| return b;
    const b = std.process.hasEnvVarConstant("RNXC_LINES_STATIC");
    g_lines_static = b;
    return b;
}

/// F-110: a branch's `jmpl` that lands on another `jmpl` -- an if that was
/// the last statement of an enclosing branch -- skips it, as Ring's jump
/// skips the enclosing if's merged marker, and keeps its own line.
fn lnThread(c: *Compiler, lo: u32) void {
    const end = c.here();
    var p = lo;
    while (p + 1 < end) : (p += 1) {
        const in = c.code.items[p];
        if (in.op != .jmpl or (in.a | in.b | in.c) == 0) continue;
        var hops: u32 = 0;
        while (hops < 64) : (hops += 1) {
            const t: u32 = @intCast(c.code.items[p].d);
            if (t + 1 >= end or c.code.items[t].op != .jmpl) break;
            c.code.items[p].d = c.code.items[t].d;
            c.code.items[p + 1] = c.code.items[t + 1]; // its region: end and row
        }
    }
}

/// Where `x = new K(args)` puts the object before the arguments run (F-91).
pub const NewEarly = union(enum) {
    global: i32,
    local: struct { reg: u8, boxed: bool },
};

pub const DaState = struct {
    set: [4]u64 = .{ 0, 0, 0, 0 },
    dead: bool = false,

    fn has(s: DaState, r: u8) bool {
        return s.dead or (s.set[r >> 6] >> @intCast(r & 63)) & 1 == 1;
    }
    fn add(s: *DaState, r: u8) void {
        s.set[r >> 6] |= @as(u64, 1) << @intCast(r & 63);
    }
    /// A register shared by locals is unassigned again when its next owner's
    /// stretch begins (shareFunction).
    fn del(s: *DaState, r: u8) void {
        s.set[r >> 6] &= ~(@as(u64, 1) << @intCast(r & 63));
    }
    /// Where two paths meet: assigned only if assigned on both, and a
    /// path that ended early does not count.
    fn meet(a: DaState, b: DaState) DaState {
        if (a.dead) return b;
        if (b.dead) return a;
        var r = DaState{};
        for (0..4) |i| r.set[i] = a.set[i] & b.set[i];
        return r;
    }
};

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    /// Set while compiling an eval string (see EvalCtx); null otherwise.
    eval: ?*EvalCtx = null,
    /// The name table is the VM's, seeded once and never grown: a name the
    /// program never mentions has no index for `callm`/`ncall` to carry.
    names_frozen: bool = false,
    /// An eval string that did not parse: Ring's own report of it (F-108),
    /// which the hook prints before it raises R42.
    eval_report: std.ArrayListUnmanaged(u8) = .{},
    eval_parser: ?ts.Parser = null,
    /// Which layout pass the classes are in. Bumped by resolveAllSlots, so
    /// one pass lays each class out once and its parents before it.
    resolve_pass: u32 = 0,
    code: std.ArrayListUnmanaged(vm.Instr) = .{},
    /// Source row and file of every instruction, for Ring's runtime
    /// error report (`Line N ... in file F`, and the call chain). Set
    /// per statement; an instruction emitted outside one reads 0.
    rows: std.ArrayListUnmanaged(u32) = .{},
    files: std.ArrayListUnmanaged(u16) = .{},
    cur_row: u32 = 0,
    cur_file: u16 = 0,
    /// F-128: the files a `load` INSIDE A BLOCK of the top level reaches and
    /// no top-level load does, each with its top level as spliceOne lays it
    /// out. Ring runs such a file's top level where that load stands, each
    /// time it is reached (three times in a three-turn loop), and never when
    /// it is not; its functions and classes exist either way. Ring++ ran it
    /// once, after everything. The statements stay in @@main's list, so every
    /// pass before code generation still sees them; `nested_skip` makes code
    /// generation pass them there, and the load site emits them.
    nested_stmts: std.AutoHashMapUnmanaged(u16, []const ts.Node) = .{},
    nested_skip: std.AutoHashMapUnmanaged(NodeKey, void) = .{},
    last_src: ?[*]const u8 = null,
    last_file: u16 = 0,
    funcs: std.ArrayListUnmanaged(Func) = .{},
    /// Case-folded name -> index in `funcs` of the FIRST plain function
    /// of that name (Ring folds identifier case, and the first definition
    /// wins, as the linear scan this replaces did). Built lazily and
    /// caught up on every lookup, so a Func appended later -- a lambda,
    /// the prologue -- is found without every append site knowing.
    /// Measured 2026-09-10: `findFunc` was 32.6 billion string
    /// comparisons over a 45,039-function unit -- 160 of the 163 s a
    /// census took. Safe because `owner` is set only in the struct
    /// literal and `findFunc` is never called during the pre-pass.
    fn_index: std.StringHashMapUnmanaged(u32) = .{},
    fn_indexed: usize = 0,
    /// Case-folded name -> its slot in `names`. The same scan, 2.7 billion.
    name_index: std.StringHashMapUnmanaged(u16) = .{},
    /// The same trick for string CONSTANTS. konstIndex was a linear scan with
    /// a string compare over the whole table, and that table is 29,167 entries
    /// on the Softanza unit: 1.4 BILLION comparisons in one compile, read off
    /// the `scans:` counter this project keeps for exactly this (2026-09-12).
    /// Same species as the findFunc and collectAll scans that took the census
    /// from 173 s to 10 s.
    konst_index: std.StringHashMapUnmanaged(i32) = .{},
    /// rereadSpan's cut points, reused across calls rather than reallocated
    /// per statement. See the note at its use.
    scratch_starts: std.ArrayListUnmanaged(usize) = .{},
    /// A SECOND allocator, reset at the start of every function emitted.
    ///
    /// The compiler builds small lists per control-flow statement -- the
    /// jump patch-up lists of an `if`, a `while`, a condition -- and frees
    /// each with `defer list.deinit(self.alloc)`. On a bump arena that
    /// deinit does NOTHING, so every one of them stayed resident for the
    /// life of the process: measured 2026-09-13, hundreds of thousands of
    /// small requests spread over a dozen sites, with no single site to
    /// blame. They are all function-local, so one arena reset per function
    /// reclaims the lot without changing a lifetime.
    scratch_arena: ?*std.heap.ArenaAllocator = null,
    scratch: std.mem.Allocator = undefined,
    /// Per class, its methods flattened over the parent chain. See methodOf.
    method_maps: std.ArrayListUnmanaged(?std.StringHashMapUnmanaged(u32)) = .{},
    /// The `obj { ... }` blocks being compiled, innermost last: the
    /// register holding the object (pinned by `floor`, so the block's
    /// statements cannot reuse it) and its class when proved.
    braces: std.ArrayListUnmanaged(BraceCtx) = .{},
    /// Names of loop variables whose loops have ended, per function (C-11).
    retired: std.ArrayListUnmanaged(Retired) = .{},
    /// The loop variables of the loops currently OPEN, innermost last.
    active_loops: std.ArrayListUnmanaged([]const u8) = .{},
    /// Case-folded top-level name -> the class every assignment to it in
    /// the top level proves (null when they disagree, or are not `new`).
    global_cls: std.StringHashMapUnmanaged(?u16) = .{},
    cur: *Func = undefined,
    /// Bump allocator for expression temporaries, reset per statement.
    temp: u8 = 0,
    /// Lowest register a temporary may use. A numeric `for` keeps its limit
    /// (and step) in registers that stay live across every statement of the
    /// body, so the body's temporaries must start ABOVE them. Without this
    /// the loop bound is quietly overwritten by the first subscript in the
    /// body and the loop runs a wrong number of times.
    floor: u8 = 0,
    high: u8 = 0,
    /// Patch sites for `exit`, innermost loop last.
    breaks: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .{},
    /// Patch sites for `loop` (continue), innermost loop last. A `for`
    /// continues at its step instruction, a `while` at its condition.
    continues: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .{},
    /// `try` BODIES open around the statement being compiled, in this
    /// function (F-90). A `return`, `exit` or `loop` that leaves one emits a
    /// `pend` for it: the handler is the try's, and it must not outlive the
    /// jump. It did -- `ret` never touches the handler stack -- so an error
    /// raised AFTER `try return x catch ... done` unwound into the catch of
    /// a frame that had already returned, and 256 such returns overflowed
    /// the stack.
    try_open: u32 = 0,
    /// `try_open` at the entry of each open loop, parallel to `breaks`.
    loop_try: std.ArrayListUnmanaged(u32) = .{},
    /// Per open `try` body, innermost last: the registers a BORROW wrote
    /// (`ggetw`, `gattrw`, `vgetw`) inside it. A borrow holds a container
    /// with no count of its own and ends with `loadi r, 0`, which stores
    /// without releasing -- on the normal path. An error raised between the
    /// borrow and that `loadi` landed in the catch with the register still
    /// holding the unowned container, and the catch's next write there
    /// released it as if owned: `try del(aL, "a") catch ? "c " +
    /// cCatchError done` on a global aL took aL's list one count below its
    /// holders, freed it under the global, and ReleaseSafe said `integer
    /// overflow` in `release` (2026-10-03, found when the gate's exec
    /// probes ran on the ReleaseSafe binary for the first time). The handler
    /// ends those borrows the normal path's way, first thing at landing.
    try_borrows: std.ArrayListUnmanaged([4]u64) = .{},
    /// `x = new K(args)` on Ring stores the new object into x BEFORE the
    /// arguments are evaluated (F-91): `o = new K([1] + o)` appends the
    /// object itself, and `q = new K(q)` hands init the object. The
    /// assignment leaves the target here; `newObj` takes it on entry, so a
    /// nested `new` in the arguments never sees it.
    new_early: ?NewEarly = null,
    classes: std.ArrayListUnmanaged(ClassInfo) = .{},
    /// Every distinct method name in the unit; dispatch is (class, index).
    names: std.ArrayListUnmanaged([]const u8) = .{},
    /// String constants, in the order `loadk` refers to them.
    konst: std.ArrayListUnmanaged(vm.Value) = .{},
    /// Where the last refusal happened. "Unsupported" with no location is a
    /// compiler telling you nothing; the port needs to know WHICH construct
    /// and WHERE, because that list is the actual deliverable.
    fail_kind: []const u8 = "",
    fail_row: u32 = 0,
    fail_text: []const u8 = "",
    fail_fn: []const u8 = "",
    /// The LAST refusal recorded, where `fail_*` above keeps the FIRST of
    /// the whole compile for the Program-level report. A refusal trap needs
    /// THIS statement's refusal, and it used to have no way to ask: it
    /// printed the enclosing statement's kind and row instead, which named
    /// `while_statement, line 1108` for an eval-assigned local at line 1125,
    /// and named a method in one file for a lambda in another that happened
    /// to share a line number (both 2026-09-12).
    last_kind: []const u8 = "",
    last_row: u32 = 0,
    last_text: []const u8 = "",
    last_fail_src: ?[*]const u8 = null,
    /// Census mode: record every refusal and keep going, instead of
    /// stopping at the first. A port needs the whole list, not the first
    /// item on it.
    census: bool = false,
    /// Compile everything that can be compiled, marking what cannot be.
    lenient: bool = false,
    /// Also rank the own-body failures by how much each holds hostage.
    rank: bool = false,
    /// Print the ranking's own cost. A tool that takes ten minutes and
    /// says nothing about why is a tool nobody runs twice.
    rank_verbose: bool = false,
    refusals: std.ArrayListUnmanaged(Refusal) = .{},
    /// `new K` sites whose class the unit does not define: compiled to
    /// Ring's run-time R11 and counted APART (absentClass).
    absent_classes: std.ArrayListUnmanaged(Refusal) = .{},
    /// Call sites deferred to a runtime-registered native, and the distinct
    /// names among them. Counted apart from compiled statements: a call to
    /// a name nobody has defined is not a compiled statement.
    stmts_native: usize = 0,
    natives: std.ArrayListUnmanaged(u16) = .{},
    /// `$x` global names, in slot order. Ring resolves a global by name at
    /// runtime; here the name becomes an index once, at compile time.
    globals: std.ArrayListUnmanaged([]const u8) = .{},
    /// Registers holding the caught value, innermost handler last. Each
    /// `try` gets its OWN, so an inner catch cannot clobber an outer's --
    /// which is the same guarantee, one scope down, that stops a callee
    /// clobbering its caller's.
    catch_regs: std.ArrayListUnmanaged(u8) = .{},
    /// DEFINITE ASSIGNMENT of the current function's locals, by register
    /// (F-89). Ring raises R24 the moment a variable nothing has assigned
    /// is read; for a local, whether anything has depends on the PATH, so
    /// codegen tracks the set assigned on every path to where it stands.
    /// A read outside it gets a `chkl` -- a nil test, so a read the set is
    /// merely too cautious about costs an instruction and never an error --
    /// and its register a `nilr` at entry. `da_on` is off at the top level,
    /// in the class prologue, in eval'd code and in a body that calls eval.
    da_on: bool = false,
    da: DaState = .{},
    da_flag: [4]u64 = .{ 0, 0, 0, 0 },
    /// Set while a function's STRUCTURE pass runs (shareFunction): every
    /// statement sequence the emitter walks in that function's own source is
    /// recorded here, with the loops around it.
    share_rec: ?*std.ArrayListUnmanaged(SeqRec) = null,
    /// The loop stack's length when the structure pass began: a refused loop
    /// never pops, so entries from earlier statements can still be on it.
    share_loop_base: usize = 0,
    /// Functions whose locals share registers, and the registers that saved.
    shared_funcs: u32 = 0,
    shared_saved: u32 = 0,
    /// Index of the synthetic top-level function, once one is needed.
    main_fn: ?u32 = null,
    /// A PREFIX is a compile that already happened. The library is 613 of
    /// the 614 files in a Softanza test's unit and it is the same 613 every
    /// time, so it is compiled ONCE and everything below these marks is
    /// finished: never re-collected, never re-classified, never re-emitted.
    /// A later file is COLLECTED AND EMITTED ON TOP -- its code appended
    /// after the prefix's, its functions and classes appended after the
    /// prefix's, so every entry, id, name index, global slot and constant
    /// index the prefix already baked into its instructions stays true.
    /// See compilePrefix / compileOnto, and the three things that make a
    /// prefix INAPPLICABLE, which rnxc checks before using one.
    prefix_funcs: usize = 0,
    prefix_classes: usize = 0,
    prefix_code: usize = 0,
    prefix_fixups: usize = 0,
    /// The prefix's own @@main -- the LIBRARY's top level. The file compiled
    /// on top gets its own, and the entry runs them in that order.
    prefix_main: ?u32 = null,
    /// What the poison spread found, handed from the front to the finish.
    spread_direct: usize = 0,
    spread_dyn: usize = 0,
    stmts_ok: u32 = 0,
    stmts_bad: u32 = 0,
    /// Functions whose codegen failed OUTSIDE any statement -- the
    /// failures the per-statement catch never sees. Counted and printed,
    /// because until 2026-09-23 the census discarded them: one of them
    /// stopped emitAll and the rest of the library went uncounted, under
    /// a gate that passed.
    emit_failed: u32 = 0,
    /// Re-parsing a line the grammar split in two (see rejoinTail): the
    /// parser, made on first use, and every snippet tree it produced -- kept
    /// alive, because a node compiled from one may be quoted in a refusal
    /// message long after this statement is done.
    rejoin_parser: ?ts.Parser = null,
    rejoin_trees: std.ArrayListUnmanaged(ts.Tree) = .{},
    /// WHERE EACH RE-READ SNIPPET CAME FROM, keyed by the snippet's buffer.
    /// A snippet is parsed behind a `func __reread()` header, so its byte
    /// offsets are not its file's -- and a LAMBDA inside one was looked up
    /// by such an offset alone: it matched nothing, and the statement was
    /// refused ("lambda was not lowered", 49 rows of the wide suite on
    /// 2026-10-05, a `#` comment inside a lambda's list literal being
    /// enough), or it matched ANOTHER lambda that happened to sit at that
    /// offset in some file of the unit, and ran it: `? call f(1)` printed
    /// another function's "WRONG". A node's byte plus `shift` is the byte
    /// of the same text in `src`, which is all the lookup needs.
    reread_origin: std.AutoHashMapUnmanaged(usize, RereadOrigin) = .{},
    /// Per source buffer, the byte where each line starts -- built only for a
    /// file a statement of which is re-read (`fileRowOf`).
    line_starts: std.AutoHashMapUnmanaged(usize, []const u32) = .{},
    /// `return func t { ... }` AS THE GRAMMAR READS IT: a bare `return` and, on
    /// the same row, a FUNCTION DEFINITION named `t`. Ring reads a lambda there
    /// (`return func(t) {`, `return func a, b {`, and this very line inside an
    /// `if`, the grammar reads right); the grammar cannot tell a one-parameter
    /// lambda from a definition at the head of a function's own statement list,
    /// so pass 2 gave the definition a function of its own and the enclosing one
    /// returned "" (2026-10-05, `call f(1)` was R3 with an empty name). collectAll
    /// takes the definition OUT of the pieces and records it here: the function
    /// lowers it as the lambda it is, and `ret_ext` -- keyed by the return's
    /// address -- tells `rereadSpan` that the statement's text runs to the
    /// definition's end, which is then read again as `return (func t { ... })`.
    absorbed: std.ArrayListUnmanaged(Absorbed) = .{},
    ret_ext: std.AutoHashMapUnmanaged(usize, u32) = .{},
    /// How many statements were re-read: lines the grammar cut in two and
    /// were joined back, and lines it joined that Ring keeps apart.
    rejoined: u32 = 0,
    resplit: u32 = 0,
    /// While a re-read piece compiles, where it REALLY is: a piece was
    /// parsed alone, so its nodes say row 2 of a snippet nobody can open.
    /// nope() reports these instead, so a refusal names the source line.
    reread_src: ?[]const u8 = null,
    reread_byte: u32 = 0,
    reread_row: u32 = 0,
    /// Recursion guard. A compiler that overflows the stack tells you
    /// nothing; one that refuses at a depth tells you which construct and
    /// where. Ring nests shallowly, so 200 is far above anything real.
    depth: u32 = 0,
    /// F-110, the line Ring carries past an `ok` (see `jmpl`): how many
    /// statements are being compiled, one inside another; an `if ... else
    /// ... ok` whose branches end in `jmpl`, waiting to learn whether a
    /// statement follows it in the same block; and that statement's region
    /// while it is being compiled -- up to its end, or to the first statement
    /// nested in it, whose own line marker Ring runs.
    stmt_level: u32 = 0,
    ln_pend: ?LnRegion = null,
    ln_open: ?LnRegion = null,
    /// Read by stmt() as it starts: whether another statement follows this
    /// one in its block, and whether the block is a branch of an if that
    /// records its line -- the only two cases where an if's own record can
    /// reach anything. An if/else last in a loop body pays nothing.
    ln_has_next: bool = false,
    ln_block_quirk: bool = false,
    /// F-114: the statement being compiled ends in a postfix construct and a
    /// newline follows it -- what it still emits after that construct takes
    /// the line of the next token, as Ring's does (see `tailOf`).
    tail: ?Tail = null,
    /// Call sites waiting for their callee's entry, frame size and id.
    /// Functions may be used before they are compiled (Fib calls itself),
    /// so every call is emitted blank and filled in at the end.
    fixups: std.ArrayListUnmanaged(Fixup) = .{},

    // ----------------------------------------------------------- emitting

    fn emit(self: *Compiler, op: vm.Op, a: u8, b: u8, c: u8, d: i32) !u32 {
        // a borrow inside a try body is one its handler must end (try_borrows)
        if (op == .ggetw or op == .gattrw or op == .vgetw) {
            for (self.try_borrows.items) |*set| set[a >> 6] |= @as(u64, 1) << @intCast(a & 63);
        }
        const at: u32 = @intCast(self.code.items.len);
        try self.code.append(self.alloc, .{ .op = op, .a = a, .b = b, .c = c, .d = d });
        try self.rows.append(self.alloc, self.cur_row);
        try self.files.append(self.alloc, self.cur_file);
        return at;
    }

    /// The row an instruction emitted for `n` reports: the END row of the
    /// node, which is where Ring's line counter stands when that
    /// instruction runs (measured -- see rows_per_node). A node from a
    /// re-read snippet keeps the statement's row, since the snippet has
    /// its own line numbering.
    fn atNode(self: *Compiler, n: ts.Node) void {
        if (self.reread_src != null) {
            if (self.fileRowOf(n.src, n.endByte())) |r| self.cur_row = r;
            return;
        }
        // memoised: fileOf is a scan of every loaded path, and this runs
        // per expression NODE -- 613 files x millions of nodes otherwise.
        if (self.last_src != n.src.ptr) {
            const fi = self.fileOf(n.src.ptr) orelse return;
            self.last_src = n.src.ptr;
            self.last_file = fi;
        }
        self.cur_row = n.end().row + 1;
        self.cur_file = self.last_file;
    }

    /// The row a CALL instruction reports in a "Called from line N" frame:
    /// the START of the call, i.e. the callee's line. Measured on 1.27
    /// (bench/exec/call_line.ring): a call whose arguments span three lines
    /// is attributed to the line the callee is on, not the closing paren --
    /// `f("a" +/ "b" +/ "c")` over lines 5-7 reports 5, for a plain
    /// function, a method, and an assignment's right-hand side alike. This
    /// is NOT the rule for `raise(...)`, which reports the closing paren
    /// (the trap opcode keeps `atNode`, measured at line ~2249): Ring emits
    /// the CALL when it reads the name and the RAISE when it finishes the
    /// argument, so the two stand on different lines. Six cluster tests
    /// differed only on this, all through `withfacet() -> stzraise(...)`.
    fn atNodeStart(self: *Compiler, n: ts.Node) void {
        if (self.reread_src != null) {
            if (self.fileRowOf(n.src, n.startByte())) |r| self.cur_row = r;
            return;
        }
        if (self.last_src != n.src.ptr) {
            const fi = self.fileOf(n.src.ptr) orelse return;
            self.last_src = n.src.ptr;
            self.last_file = fi;
        }
        self.cur_row = n.start().row + 1;
        self.cur_file = self.last_file;
    }

    /// THE FILE ROW OF A BYTE OF A RE-READ SNIPPET, 1-based. A re-read
    /// statement compiles from a snippet with rows of its own, so every
    /// instruction in it used to report the statement's FIRST row: a brace
    /// spanning lines 2-5 with a `#` comment inside -- which is what makes
    /// it re-read -- reported every call in it at line 2, where Ring reports
    /// each at its own line (base/test/list/546_removew, `Called from line
    /// 17` for 18; F-104). The snippet keeps every byte where the file has
    /// it -- blanking keeps the newlines -- so the byte, shifted back through
    /// `reread_origin` as the lambda lookup does, is the file's, and its row
    /// is read off a table of line starts. null when nothing maps it.
    fn fileRowOf(self: *Compiler, nsrc: []const u8, b: u32) ?u32 {
        var at: i64 = b;
        var in_src = nsrc;
        var hops: u32 = 0;
        while (self.reread_origin.get(@intFromPtr(in_src.ptr))) |o| : (hops += 1) {
            if (hops == 16) return null;
            at += o.shift;
            in_src = o.src;
        }
        if (hops == 0 or at < 0 or at > in_src.len) return null;
        const starts = self.line_starts.get(@intFromPtr(in_src.ptr)) orelse blk: {
            var list = std.ArrayListUnmanaged(u32){};
            list.append(self.alloc, 0) catch return null;
            for (in_src, 0..) |ch, i| {
                if (ch == '\n') list.append(self.alloc, @intCast(i + 1)) catch return null;
            }
            self.line_starts.put(self.alloc, @intFromPtr(in_src.ptr), list.items) catch return null;
            break :blk list.items;
        };
        // the number of lines starting at or before the byte is its row
        var lo: usize = 0;
        var hi: usize = starts.len;
        const ub: u32 = @intCast(at);
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (starts[mid] <= ub) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    /// Which loaded file a node belongs to, by its source buffer. Cached
    /// on the last answer: statements arrive file by file.
    fn fileOf(self: *Compiler, src: [*]const u8) ?u16 {
        // eval'd code belongs to no file: its snippet lives in the scratch
        // arena, and load_srcs is the DRIVER'S table -- arena-owned, and
        // cleared at the freeze because it dangles from then on. The first
        // cold-path eval walked it and faulted (2026-09-25).
        if (self.eval != null) return null;
        for (load_srcs, 0..) |p, i| {
            if (p == src) return @intCast(i);
        }
        return null;
    }
    fn here(self: *Compiler) u32 {
        return @intCast(self.code.items.len);
    }
    fn land(self: *Compiler, at: u32) void {
        self.code.items[at].d = @intCast(self.here());
    }

    /// F-110: the `jmpl`s of an if report their line for pcs up to `hi`
    /// whose row is the statement's first (the data word: d = hi, a|b|c =
    /// that row; 0 matches nothing).
    fn lnClose(self: *Compiler, r: LnRegion, hi: u32) void {
        var p = r.start;
        const end = @min(r.end, @as(u32, @intCast(self.code.items.len)));
        const s = @min(r.srow, 0xFF_FFFF);
        while (p + 1 < end) : (p += 1) {
            const in = self.code.items[p];
            if (in.op == .jmpl and in.d == @as(i32, @intCast(r.end)) and self.code.items[p + 1].op == .lnhi)
                self.code.items[p + 1] = .{ .op = .lnhi, .a = @truncate(s), .b = @truncate(s >> 8), .c = @truncate(s >> 16), .d = @intCast(hi) };
        }
    }

    /// F-110, at the start of every statement: it ends the region it was in
    /// (Ring runs its own line marker), and an if waiting for a statement
    /// after it gets one only when this one is in the if's own block.
    fn lnStmtStart(self: *Compiler, n: ts.Node) void {
        if (self.ln_open) |o| {
            self.lnClose(o, self.here());
            self.ln_open = null;
        }
        if (self.ln_pend) |p| {
            self.ln_pend = null;
            if (p.level == self.stmt_level) {
                var o = p;
                o.srow = if (self.reread_src != null)
                    self.fileRowOf(n.src, n.startByte()) orelse self.cur_row
                else
                    n.start().row + 1;
                self.ln_open = o;
            } else self.lnClose(p, p.end);
        }
    }

    /// ... and at the end of a block, for the statements at its level.
    fn lnSeqEnd(self: *Compiler) void {
        if (self.ln_open) |o| if (o.level == self.stmt_level) {
            self.lnClose(o, self.here());
            self.ln_open = null;
        };
        if (self.ln_pend) |p| if (p.level == self.stmt_level) {
            self.lnClose(p, p.end);
            self.ln_pend = null;
        };
    }

    /// F-110: a branch's end-jump, and when Ring's next statement loses its
    /// marker, the line Ring carries out of the branch -- the last NEWLINE it
    /// ran, which is that of the `but`/`else` after it when a newline comes
    /// first (blank lines and comments merge into it), else that of the line
    /// the branch began on.
    fn branchEnd(self: *Compiler, owner: ts.Node, from: u32, kw: ?ts.Node, quirk: bool) Error!u32 {
        if (!quirk) return self.emit(.jmp, 0, 0, 0, 0);
        var last_row = owner.namedChild(from - 1).end().row;
        var i: u32 = from;
        while (i < owner.namedChildCount()) : (i += 1) {
            const ch = owner.namedChild(i);
            const ck = ch.kind();
            if (std.mem.eql(u8, ck, "elseif_clause") or std.mem.eql(u8, ck, "else_clause")) break;
            if (std.mem.eql(u8, ck, "comment")) continue;
            last_row = ch.end().row;
        }
        const at = if (kw) |k| (if (k.start().row > last_row) k else owner) else owner;
        const line: u32 = if (self.reread_src != null)
            self.fileRowOf(at.src, at.startByte()) orelse self.cur_row
        else
            at.start().row + 1;
        const l = @min(line, 0xFF_FFFF);
        const j = try self.emit(.jmpl, @truncate(l), @truncate(l >> 8), @truncate(l >> 16), 0);
        _ = try self.emit(.lnhi, 0, 0, 0, 0);
        return j;
    }

    /// A READ of local `l`: if no path-proof says it is assigned here, a
    /// `chkl` goes in front of the read and the register is cleared at
    /// entry (F-89). Emitted before the instruction that consumes it.
    fn daRead(self: *Compiler, l: *const Local, name: []const u8) Error!void {
        if (!self.da_on or self.da.has(l.reg)) return;
        _ = try self.emit(.chkl, l.reg, 0, 0, @intCast(try self.nameIndex(name)));
        self.da_flag[l.reg >> 6] |= @as(u64, 1) << @intCast(l.reg & 63);
    }

    /// A WRITE of the local in register `r`: assigned from here on.
    fn daWrite(self: *Compiler, r: u8) void {
        if (self.da_on) self.da.add(r);
    }

    /// The path ends here -- return, raise, exit, loop, bye.
    fn daEnd(self: *Compiler) void {
        if (self.da_on) self.da.dead = true;
    }

    /// Leave `k` open `try` bodies: one `pend` each (F-90).
    fn leaveTries(self: *Compiler, k: u32) Error!void {
        var i: u32 = 0;
        while (i < k) : (i += 1) _ = try self.emit(.pend, 0, 0, 0, 0);
    }

    /// The `try` bodies a jump to the loop `lv` levels out leaves.
    fn triesInLoops(self: *Compiler, lv: usize) u32 {
        const lt = self.loop_try.items;
        if (lv == 0 or lv > lt.len) return 0;
        return self.try_open - lt[lt.len - lv];
    }

    fn reg(self: *Compiler, r: u8) u8 {
        if (r > self.high) self.high = r;
        return r;
    }
    fn tmp(self: *Compiler) !u8 {
        if (self.temp >= MAXREG) {
            // the LOCALS filled the window and left no room to compute in:
            // a statement needs its temporaries before it defines its new
            // local, so `define` may never see the limit (shareFunction)
            if (self.eval == null and self.cur.reg_top + SHARE_TEMPS >= MAXREG) self.cur.window_full = true;
            return Error.Unsupported;
        }
        const r = self.temp;
        self.temp += 1;
        return self.reg(r);
    }

    // ----------------------------------------------------------- symbols

    /// A PARAMETER spelt with `$` -- `func pvtMax(n1, $n2)` -- is the
    /// parameter, not the global: on Ring the `$` is part of the name, and
    /// a parameter is the innermost binding (F-91, both 1.27 builds:
    /// P(3, 7) answers 7). Rule A reads every other `$` name as a global.
    fn paramLocal(self: *Compiler, name: []const u8) ?*Local {
        if (name.len < 2 or name[0] != '$') return null;
        for (self.cur.params) |p| {
            if (std.ascii.eqlIgnoreCase(p, name)) return self.lookup(name);
        }
        return null;
    }

    fn lookup(self: *Compiler, name: []const u8) ?*Local {
        // The LAST definition wins: a loop variable is a fresh local for its
        // loop (C-11) and shadows an outer local of the same name until the
        // loop ends and retires it.
        var i: usize = self.cur.locals.items.len;
        while (i > 0) {
            i -= 1;
            const l = &self.cur.locals.items[i];
            scans[9] += 1;
            // Ring identifiers are case-insensitive (F-18).
            if (std.ascii.eqlIgnoreCase(l.name, name)) return l;
        }
        return null;
    }

    /// The loop is over: its variable stops answering to its name. A later
    /// read is refused BY NAME (the identifier path checks retired), so
    /// the message says what happened; a later assignment makes a new
    /// local, as Python and Lua allow.
    /// The loop is over: reads of its variable by name are refused from
    /// here to the end of the function (C-11). The LOCAL is untouched --
    /// same name, same register, still typed -- so the classify pass and
    /// every non-loop use are unaffected; only a bare read after the loop
    /// is caught, by wasLoopVar.
    fn retire(self: *Compiler, name: []const u8) !void {
        if (self.wasLoopVar(name)) return;
        try self.retired.append(self.alloc, .{ .fi = self.cur.id, .name = name });
    }

    /// A loop opening on a name an ENCLOSING loop is already using. Ring has
    /// one scope, so the two are ONE variable: the inner loop destroys the
    /// outer index and the outer loop then walks the wrong range. Found by
    /// this check in shipping Softanza -- stzFolder.ring 3540/3553, `for i`
    /// over directory entries with `for i` over a file's lines inside it,
    /// after which `_aEntries_[i][1]` reads an entry that is not the one
    /// being searched. A refusal, not a rename: which loop the author meant
    /// is not the compiler's to guess.
    fn loopVarInUse(self: *Compiler, name: []const u8) bool {
        for (self.active_loops.items) |a| {
            if (std.ascii.eqlIgnoreCase(a, name)) return true;
        }
        return false;
    }

    /// The name loops again (a re-loop, or pass B re-emitting): it is live.
    fn unretire(self: *Compiler, name: []const u8) void {
        var ri: usize = 0;
        while (ri < self.retired.items.len) {
            const r = self.retired.items[ri];
            if (r.fi == self.cur.id and std.ascii.eqlIgnoreCase(r.name, name)) {
                _ = self.retired.swapRemove(ri);
            } else ri += 1;
        }
    }

    /// Is the current function a lambda whose DEFINING scope, through any
    /// lambdas it sits inside, is the top level? (C-14)
    fn lambdaOfMain(self: *Compiler) bool {
        var f: *Func = self.cur;
        var guard: u32 = 0;
        while (f.lambda_at != null and guard < 64) : (guard += 1) {
            const e = f.encl orelse return false;
            if (e >= self.funcs.items.len) return false;
            f = &self.funcs.items[e];
            if (f.is_main) return true;
        }
        return false;
    }

    /// Is `name` one of the current lambda's captures?
    fn isCapture(self: *Compiler, name: []const u8) bool {
        for (self.cur.captures.items) |cap| {
            if (std.ascii.eqlIgnoreCase(cap, name)) return true;
        }
        return false;
    }

    fn wasLoopVar(self: *Compiler, name: []const u8) bool {
        for (self.retired.items) |r| {
            if (r.fi == self.cur.id and std.ascii.eqlIgnoreCase(r.name, name)) return true;
        }
        return false;
    }

    fn forIsIn(n: ts.Node) bool {
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) {
            if (std.mem.eql(u8, n.child(i).kind(), "in")) return true;
        }
        return false;
    }

    fn define(self: *Compiler, name: []const u8) !*Local {
        if (self.lookup(name)) |l| return l;
        // IN EVAL MODE a new name is a register ABOVE the caller's frame,
        // boxed (the string may store anything) -- the locals below are
        // the caller's own, by number, and are never redefined here.
        if (self.eval) |ev| {
            if (ev.next_reg >= MAXREG) return Error.Unsupported;
            const r = ev.next_reg;
            ev.next_reg += 1;
            if (self.temp <= r) self.temp = r + 1;
            try self.cur.locals.append(self.alloc, .{ .name = name, .reg = self.reg(r), .class = .ref, .declared = true });
            return &self.cur.locals.items[self.cur.locals.items.len - 1];
        }
        if (self.share_rec != null) {
            // THE STRUCTURE PASS (shareFunction) records where statements are;
            // its code is thrown away, so its registers only have to stay
            // inside the window: past the parameters they wrap.
            const p = self.cur.params.len;
            const n = self.cur.locals.items.len;
            const rp: u8 = if (n < p) @intCast(n) else @intCast(p + (n - p) % (SHARE_PROV - p));
            try self.cur.locals.append(self.alloc, .{ .name = name, .reg = self.reg(rp) });
            self.cur.reg_top = @max(self.cur.reg_top, @as(u16, rp) + 1);
            return &self.cur.locals.items[self.cur.locals.items.len - 1];
        }
        const r = self.cur.reg_top;
        if (r >= MAXREG) {
            self.cur.window_full = true;
            return Error.Unsupported;
        }
        try self.cur.locals.append(self.alloc, .{ .name = name, .reg = self.reg(@intCast(r)) });
        self.cur.reg_top = r + 1;
        return &self.cur.locals.items[self.cur.locals.items.len - 1];
    }

    /// The register above the locals. Eval code keeps the count it always
    /// used (its locals are the caller's, bound by register).
    fn localsTop(self: *Compiler) u8 {
        if (self.eval != null) return @intCast(self.cur.locals.items.len);
        return @intCast(self.cur.reg_top);
    }

    /// Where a statement's temporaries start: above the locals -- or, in
    /// eval mode, above the eval's own new names.
    fn bottom(self: *Compiler) u8 {
        if (self.eval) |ev| return ev.next_reg;
        return @intCast(self.cur.reg_top);
    }

    /// Before a statement of a function whose locals share registers: clear
    /// each register whose next owner's stretch begins here, releasing what
    /// the last owner left, and forget that it was assigned (shareFunction).
    fn shareClear(self: *Compiler, st: ts.Node) Error!void {
        const sh = self.cur.share orelse return;
        if (self.eval != null or st.src.ptr != self.cur.node.src.ptr) return;
        const regs = sh.get(stmtKeyBytes(st)) orelse return;
        for (regs.items) |r| {
            // `loadi` releases a counted value it overwrites (F-118's leak
            // fix), and the raw `nilr` then overwrites only the 0: a release
            // and a clear with no change to the VM. A change to the VM's one
            // big loop moves its layout, and that measured 9-11% on kernels
            // that never run the changed instruction (2026-10-18).
            _ = try self.emit(.loadi, self.reg(r), 0, 0, 0);
            _ = try self.emit(.nilr, r, 0, 0, 0);
            if (self.da_on) self.da.del(r);
        }
    }

    /// The structure pass: a sequence starts (its elements follow).
    fn seqOpen(self: *Compiler, first: ts.Node) ?usize {
        const rec = self.share_rec orelse return null;
        if (first.src.ptr != self.cur.node.src.ptr) return null;
        rec.append(self.alloc, .{ .depth = @intCast(self.loop_try.items.len -| self.share_loop_base) }) catch return null;
        return rec.items.len - 1;
    }

    /// The structure pass: the element made of list[from..to] (inclusive).
    fn seqElem(self: *Compiler, seq: ?usize, list: []const ts.Node, from: usize, to: usize) void {
        const si = seq orelse return;
        const rec = self.share_rec orelse return;
        if (from > to or to >= list.len) return;
        const s = &rec.items[si];
        s.keys.append(self.alloc, stmtKeyBytes(list[from])) catch return;
        s.spans.append(self.alloc, .{ list[from].startByte(), list[to].endByte() }) catch return;
    }

    /// Eval mode: does the caller's class (or a parent) have this attribute?
    fn evalHasAttr(self: *Compiler, ev: *EvalCtx, name: []const u8) bool {
        _ = self;
        const own = ev.owner orelse return false;
        const ni = ev.vm_.nameIdxPub(name) orelse return false;
        var cls: u16 = own;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            if (vm.attrLookup(cls, ni) != null) return true;
            if (cls >= vm.class_parent.len) return false;
            const p = vm.class_parent[cls];
            if (p == 0xFFFF) return false;
            cls = p;
        }
        return false;
    }

    /// Eval mode: does the caller's class answer this method name?
    fn evalHasMethod(self: *Compiler, ev: *EvalCtx, name: []const u8) bool {
        _ = self;
        const own = ev.owner orelse return false;
        const ni = ev.vm_.nameIdxPub(name) orelse return false;
        const key = @as(u32, own) * vm.n_names + ni;
        return key < vm.dispatch.len and vm.dispatch[key] != 0;
    }

    /// Eval mode: a bare call. The caller's own method first (Ring's rule
    /// inside a class), then a user function BY NAME through the string
    /// call, whose window lays the arguments out the way `calli` wants.
    /// False when neither, so builtins and natives get their turn.
    fn evalCall(self: *Compiler, ev: *EvalCtx, n: ts.Node, callee: []const u8, args: ts.Node, argc: u32, dst: u8) Error!bool {
        if (self.evalHasMethod(ev, callee)) {
            const save = self.temp;
            defer self.temp = save;
            const win = try self.tmp();
            _ = try self.emit(.move, win, 0, 1, 0);
            var a: u32 = 0;
            while (a < argc) : (a += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(a), r);
            }
            _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
            self.atNodeStart(n);
            _ = try self.emit(.callm, win, @intCast(argc), 0, try self.nameIndex(callee));
            _ = try self.emit(.move, dst, win, 1, 0);
            return true;
        }
        if (ev.vm_.funcByNamePub(callee) != null) {
            try self.evalStringCall(n, callee, args, argc, dst);
            return true;
        }
        return false;
    }

    /// The string-call path: the name in the window, the arguments after
    /// it, `calli` resolving at run time -- and, for a name the program
    /// never defined, Ring's own R3 naming it when the line runs.
    fn evalStringCall(self: *Compiler, n: ts.Node, callee: []const u8, args: ts.Node, argc: u32, dst: u8) Error!void {
        const save = self.temp;
        defer self.temp = save;
        const win = try self.tmp();
        _ = try self.emit(.loadk, win, 0, 0, try self.konstIndex(callee));
        var a: u32 = 0;
        while (a < argc) : (a += 1) {
            const r = try self.tmp();
            try self.expr(args.namedChild(a), r);
        }
        _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
        self.atNodeStart(n);
        _ = try self.emit(.calli, win, @intCast(argc), 0, 0);
        _ = try self.emit(.move, dst, win, 1, 0);
    }

    /// A read of a name nothing in the program assigns. Ring raises R24 at
    /// the read -- unless an EVAL made it at run time (F-107): this frame's,
    /// or a global a top-level eval made. Compiled code keeps `r24`, which
    /// consults the VM's run-time names first (c & 2: this function holds an
    /// eval, so its own frame's count too); eval'd code uses `dvget`, whose
    /// name is a string constant, since the frozen name table cannot take a
    /// name the program never mentions.
    fn unknownRead(self: *Compiler, dst: u8, nm: []const u8, method: bool) Error!void {
        if (self.eval != null) {
            _ = try self.emit(.dvget, dst, 0, if (method) 1 else 0, try self.konstIndex(nm));
            return;
        }
        const c: u8 = (if (method) @as(u8, 1) else 0) | (if (self.cur.calls_eval) @as(u8, 2) else 0);
        _ = try self.emit(.r24, dst, 0, c, @intCast(try self.nameIndex(nm)));
    }

    /// Eval mode: an assignment whose target resolves through the FRAME --
    /// an attribute of the caller's class by name, or a global. False for
    /// a local (the ordinary path) and for anything else.
    fn evalAssign(self: *Compiler, ev: *EvalCtx, n: ts.Node, lhs: ts.Node, rhs: ts.Node, op: []const u8) Error!bool {
        var attr: ?[]const u8 = null;
        var gslot: ?i32 = null;
        var dyn: ?[]const u8 = null;
        if (std.mem.eql(u8, lhs.kind(), "member_expression") and self.isThis(lhs.namedChild(0))) {
            attr = lhs.namedChild(1).text();
        } else if (std.mem.eql(u8, lhs.kind(), "identifier")) {
            const nm = lhs.text();
            if (nm.len > 1 and nm[0] == '@') {
                if (ev.owner == null) return self.nopeKind(lhs, "eval: @attribute outside a class");
                attr = nm;
            } else if (nm.len > 0 and nm[0] == '$') {
                return false;
            } else if (self.lookup(nm) != null) {
                return false;
            } else if (self.evalHasAttr(ev, nm)) {
                attr = nm;
            } else if (self.knownGlobal(nm)) |gs| {
                gslot = gs;
            } else {
                // A NAME THAT IS NOTHING YET: Ring makes it a variable of the
                // frame the eval runs in -- a global at the top level -- and
                // later evals, the function's own code and (for a global)
                // every function read it (F-107). It was refused at the top
                // level, and in a function became a register of the eval's own
                // that died with it.
                dyn = nm;
            }
        } else return false;
        const save = self.temp;
        defer self.temp = save;
        const t = try self.tmp();
        if (dyn) |dn| {
            const k = try self.konstIndex(dn);
            if (std.mem.eql(u8, op, "=")) {
                try self.expr(rhs, t);
                if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
            } else {
                const cur2 = try self.tmp();
                _ = try self.emit(.dvget, cur2, 0, 0, k);
                try self.expr(rhs, t);
                const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                _ = try self.emit(o, t, cur2, t, 1);
            }
            // the top level's names are GLOBALS: depth 0, which every function
            // reads (the top level itself runs a frame down)
            _ = try self.emit(.dvset, t, 0, if (ev.is_main) 1 else 0, k);
            return true;
        }
        if (attr) |an| {
            const ni = try self.nameIndex(an);
            if (std.mem.eql(u8, op, "=")) {
                try self.expr(rhs, t);
                if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
            } else {
                const cur2 = try self.tmp();
                // a compound through `This` reads through the getter, as in
                // compiled code (F-73); a bare or `@` name reads the slot
                const through_this = std.mem.eql(u8, lhs.kind(), "member_expression");
                _ = try self.emit(.gattrn, cur2, 0, if (through_this) vm.ACC_CHECK else vm.ACC_RAW, ni);
                try self.expr(rhs, t);
                const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                _ = try self.emit(o, t, cur2, t, 1);
            }
            _ = try self.emit(.sattrn, 0, t, vm.ACC_RAW, ni);
            return true;
        }
        const gs = gslot.?;
        if (std.mem.eql(u8, op, "=")) {
            try self.expr(rhs, t);
            if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
        } else {
            const cur2 = try self.tmp();
            _ = try self.emit(.gget, cur2, 0, 0, gs);
            try self.expr(rhs, t);
            const o: vm.Op = compoundOp(op) orelse return self.nope(n);
            _ = try self.emit(o, t, cur2, t, 1);
        }
        _ = try self.emit(.gset, t, 0, 0, gs);
        return true;
    }

    /// Eval mode: `new K(args)` from the VM's tables -- the class by name,
    /// its attribute prologue by `class_attrs_fn` (every prologue shares
    /// the name `@@attrs`, so it cannot be found by name), `init` by
    /// `callmq`, which a class without one misses harmlessly.
    fn newObjEval(self: *Compiler, ev: *EvalCtx, n: ts.Node, dst: u8) Error!void {
        var cn = n.namedChild(0);
        if (std.mem.eql(u8, cn.kind(), "call_expression")) cn = cn.namedChild(0);
        var lb: [256]u8 = undefined;
        const raw = cn.text();
        if (raw.len > lb.len) return self.nope(cn);
        const key = std.ascii.lowerString(&lb, raw);
        const cid = ev.classes.get(key) orelse return self.absentClass(cn);
        const save = self.temp;
        defer self.temp = save;
        const objr = try self.tmp();
        _ = try self.emit(.newobj, objr, 0, 0, @intCast(cid));
        var args = ts.Node{ .raw = undefined, .src = n.src };
        var have = false;
        var wrote_parens = std.mem.eql(u8, n.kind(), "new_with_parens") or
            std.mem.indexOfScalar(u8, n.text(), '(') != null;
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const ch = n.namedChild(i);
            if (std.mem.eql(u8, ch.kind(), "arguments")) {
                args = ch;
                have = true;
            } else if (std.mem.eql(u8, ch.kind(), "call_expression")) {
                wrote_parens = true;
                var j: u32 = 0;
                while (j < ch.namedChildCount()) : (j += 1) {
                    if (std.mem.eql(u8, ch.namedChild(j).kind(), "arguments")) {
                        args = ch.namedChild(j);
                        have = true;
                    }
                }
            } else if (!(std.mem.eql(u8, ch.kind(), "qualified_identifier") or std.mem.eql(u8, ch.kind(), "identifier"))) {
                return self.nopeKind(ch, "eval: `new K { ... }` inside eval");
            }
        }
        const argc: u32 = if (have) args.namedChildCount() else 0;
        if (cid < vm.class_attrs_fn.len and vm.class_attrs_fn[cid] != 0xFFFFFFFF) {
            const pfn = vm.class_attrs_fn[cid];
            const s2 = self.temp;
            defer self.temp = s2;
            const win = try self.tmp();
            _ = try self.emit(.move, win, objr, 1, 0);
            _ = self.reg(win + 8);
            self.atNodeStart(n);
            const mask_id: u8 = if (pfn < 64) @intCast(pfn) else vm.NO_MASK;
            _ = try self.emit(.call, win, ev.vm_.fn_frame[pfn], mask_id, @intCast(ev.vm_.fn_entry[pfn]));
        }
        if (have or wrote_parens) {
            const win = try self.tmp();
            _ = try self.emit(.move, win, objr, 1, 0);
            var a: u32 = 0;
            while (a < argc) : (a += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(a), r);
            }
            _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
            _ = try self.emit(.callmq, win, @intCast(argc), 0, try self.nameIndex("init"));
        }
        _ = try self.emit(.move, dst, objr, 1, 0);
    }

    /// THE LITERAL-PREFIX NAME OF AN EVAL STRING IS DECLARED AHEAD (F-72).
    /// 112 of the estate's 205 eval sites write `'<name> = ' + expr`, and
    /// the caller's own code then reads <name>: `eval("fresh = p * 2")`
    /// then `return fresh`. The name is spelled in the string, so the
    /// function gets a local for it at compile time -- boxed, since the
    /// string may store anything -- and the eval finds it in the frame. At
    /// the top level, or for a `$name`, a global slot instead.
    fn predeclareEval(self: *Compiler, arg: ts.Node) Error!void {
        var node = arg;
        while (std.mem.eql(u8, node.kind(), "binary_expression") and node.namedChildCount() >= 2 and
            std.mem.eql(u8, opText(node), "+")) node = node.namedChild(0);
        // eval(cCode): THE STRING WAS BUILT ELSEWHERE -- 48 of the estate's
        // 205 sites (F-72's census), and the dominant shape is `_cCode_ =
        // '_aListValue_ = ' + _cValue_` a few lines above. Every assignment
        // to that variable in this function is read the same way; a prefix
        // that spells a name declares it. `_cCode_ += ...` cannot change
        // the prefix, so `=` alone is followed.
        if (std.mem.eql(u8, node.kind(), "identifier")) {
            const target = node.text();
            for (self.cur.stmts.items) |st| try self.predeclareFromAssigns(st, target, 0);
            return;
        }
        // eval(acCodes[i]): THE STRING IS AN ELEMENT of a list this function
        // fills -- stzTable.InsertCalculatedRow builds `'_value_ = ' +
        // _cCode_` into _cCode_, appends it with `_acCodes_ + _cCode_`, and
        // evals each element, then reads _value_. Every value written INTO
        // the list is read as the eval's own argument would be, so the
        // identifier rule above follows _cCode_ to its prefix (2026-09-27).
        if (std.mem.eql(u8, node.kind(), "subscript_expression")) {
            var root = node;
            while (std.mem.eql(u8, root.kind(), "subscript_expression") and root.namedChildCount() > 0)
                root = root.namedChild(0);
            if (!std.mem.eql(u8, root.kind(), "identifier")) return;
            for (self.cur.stmts.items) |st| try self.predeclareFromElems(st, root.text(), 0);
            return;
        }
        if (!std.mem.eql(u8, node.kind(), "string")) return;
        var t = node.text();
        if (t.len >= 2 and (t[0] == '"' or t[0] == '\'' or t[0] == '`')) t = t[1 .. t.len - 1];
        var i: usize = 0;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        const start = i;
        while (i < t.len and (std.ascii.isAlphanumeric(t[i]) or t[i] == '_' or t[i] == '@' or t[i] == '$')) i += 1;
        if (i == start) return;
        const name = t[start..i];
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '$' and name[0] != '@') return;
        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) i += 1;
        if (i >= t.len or t[i] != '=') return;
        if (i + 1 < t.len and t[i + 1] == '=') return;
        if (name[0] == '@') return; // an attribute resolves by name at run time
        if (name[0] == '$' or self.cur.is_main) {
            _ = try self.globalSlot(name);
            return;
        }
        if (self.lookup(name) != null or self.declaredAttr(name) != null) return;
        const l = try self.define(name);
        l.class = .ref;
        l.declared = true;
    }

    /// Every `target = <expr>` under `n`: its right-hand side goes through
    /// predeclareEval as the eval's own argument would. Bounded in depth
    /// because the leaked-body grammar (F-21) can nest a long file deep.
    fn predeclareFromAssigns(self: *Compiler, n: ts.Node, target: []const u8, depth: u32) Error!void {
        if (depth > 64) return;
        if (std.mem.eql(u8, n.kind(), "assignment_expression") and n.namedChildCount() >= 2 and
            std.mem.eql(u8, opText(n), "="))
        {
            const lhs = n.namedChild(0);
            if (std.mem.eql(u8, lhs.kind(), "identifier") and std.ascii.eqlIgnoreCase(lhs.text(), target)) {
                const rhs = n.namedChild(1);
                if (!std.mem.eql(u8, rhs.kind(), "identifier")) try self.predeclareEval(rhs);
            }
        }
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) try self.predeclareFromAssigns(n.namedChild(i), target, depth + 1);
    }

    /// Every value written INTO the list `target` under `n` -- `target + v`
    /// wherever it stands (it appends in place, C-7's measurement), `add(
    /// target, v)`, `insert(target, k, v)`, `target[k] = v`, and the members
    /// of a list literal assigned to it -- goes through predeclareEval. An
    /// identifier value is skipped only when it IS the list, so the walk
    /// cannot chase itself.
    fn predeclareFromElems(self: *Compiler, n: ts.Node, target: []const u8, depth: u32) Error!void {
        if (depth > 64) return;
        const k = n.kind();
        if (std.mem.eql(u8, k, "binary_expression") and n.namedChildCount() >= 2 and std.mem.eql(u8, opText(n), "+")) {
            // `target + a + b` is `(target + a) + b`: every right operand
            // along a left spine that ends in the list is an appended item
            var spine = n;
            var items: [16]ts.Node = undefined;
            var ni: usize = 0;
            while (std.mem.eql(u8, spine.kind(), "binary_expression") and spine.namedChildCount() >= 2 and
                std.mem.eql(u8, opText(spine), "+") and ni < items.len)
            {
                items[ni] = spine.namedChild(1);
                ni += 1;
                spine = spine.namedChild(0);
            }
            if (std.mem.eql(u8, spine.kind(), "identifier") and std.ascii.eqlIgnoreCase(spine.text(), target)) {
                for (items[0..ni]) |v| try self.predeclareElem(v, target);
            }
        } else if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() >= 2) {
            const cn = n.namedChild(0);
            if (std.mem.eql(u8, cn.kind(), "identifier") and
                (std.ascii.eqlIgnoreCase(cn.text(), "add") or std.ascii.eqlIgnoreCase(cn.text(), "insert")))
            {
                var j: u32 = 1;
                while (j < n.namedChildCount()) : (j += 1) {
                    const args = n.namedChild(j);
                    if (!std.mem.eql(u8, args.kind(), "arguments") or args.namedChildCount() < 2) continue;
                    const a0 = args.namedChild(0);
                    if (std.mem.eql(u8, a0.kind(), "identifier") and std.ascii.eqlIgnoreCase(a0.text(), target))
                        try self.predeclareElem(args.namedChild(args.namedChildCount() - 1), target);
                }
            }
        } else if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() >= 2 and
            std.mem.eql(u8, opText(n), "="))
        {
            const lhs = n.namedChild(0);
            const rhs = n.namedChild(1);
            if (std.mem.eql(u8, lhs.kind(), "subscript_expression")) {
                var root = lhs;
                while (std.mem.eql(u8, root.kind(), "subscript_expression") and root.namedChildCount() > 0)
                    root = root.namedChild(0);
                if (std.mem.eql(u8, root.kind(), "identifier") and std.ascii.eqlIgnoreCase(root.text(), target))
                    try self.predeclareElem(rhs, target);
            } else if (std.mem.eql(u8, lhs.kind(), "identifier") and std.ascii.eqlIgnoreCase(lhs.text(), target) and
                std.mem.eql(u8, rhs.kind(), "list_literal"))
            {
                var j: u32 = 0;
                while (j < rhs.namedChildCount()) : (j += 1) try self.predeclareElem(rhs.namedChild(j), target);
            }
        }
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) try self.predeclareFromElems(n.namedChild(i), target, depth + 1);
    }

    fn predeclareElem(self: *Compiler, v: ts.Node, target: []const u8) Error!void {
        if (std.mem.eql(u8, v.kind(), "identifier") and std.ascii.eqlIgnoreCase(v.text(), target)) return;
        if (std.mem.eql(u8, v.kind(), "subscript_expression")) return; // no chase through a second list
        try self.predeclareEval(v);
    }

    // -------------------------------------------------------- expressions

    pub fn opText(n: ts.Node) []const u8 {
        // Operators are ANONYMOUS tokens in this grammar, so `j = i` and
        // `j += i` have identical named-child shapes. Reading only named
        // children silently miscompiles every compound assignment.
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) {
            const ch = n.child(i);
            if (!ch.isNamed()) return ch.kind();
        }
        return "";
    }

    /// `&&` and `||` are Ring's `and` and `or`: the grammar has them as
    /// alternatives of the same rule, Ring's own parser reads them alike, and
    /// rnxc compared the operator's text with the words only -- so `a && b`
    /// was refused as an unsupported binary expression (bench/exec/
    /// and_or_symbols.ring, measured on the oracle and the official 1.27).
    fn logicOp(op: []const u8) []const u8 {
        if (std.mem.eql(u8, op, "&&")) return "and";
        if (std.mem.eql(u8, op, "||")) return "or";
        return op;
    }

    /// The operator behind a compound assignment; null for a plain `=`.
    /// Ring accepts these four on every assignable PLACE -- a local, a
    /// global, an attribute, an element -- and this compiler had a
    /// different set at each: `$g += 1` but not `$g *= 2`, `n *= 2` but
    /// not `n /= 2`, and none at all on `a[i]`. One table, one answer.
    fn compoundOp(op: []const u8) ?vm.Op {
        if (std.mem.eql(u8, op, "+=")) return .add;
        if (std.mem.eql(u8, op, "-=")) return .sub;
        if (std.mem.eql(u8, op, "*=")) return .mul;
        if (std.mem.eql(u8, op, "/=")) return .div;
        return null;
    }

    fn intLit(n: ts.Node) !i64 {
        return std.fmt.parseInt(i64, std.mem.trim(u8, n.text(), " \t\r\n"), 10) catch Error.BadNumber;
    }

    /// Record the first construct that could not be compiled, and refuse.
    /// A refusal that names WHY, not just the node kind. Rule A's
    /// violations are a migration list, so they must be distinguishable
    /// from features that are merely unbuilt.
    /// Where a refusal really is. A node from a re-read piece was parsed
    /// alone and says "row 2"; while such a piece compiles, reread_* hold
    /// the statement's place in the source, and that is what gets recorded.
    fn rereadRow(self: *Compiler, n: ts.Node) u32 {
        return if (self.reread_src != null) self.reread_row else n.start().row + 1;
    }
    fn rereadByte(self: *Compiler, n: ts.Node) u32 {
        return if (self.reread_src != null) self.reread_byte else n.startByte();
    }
    fn rereadSrc(self: *Compiler, n: ts.Node) []const u8 {
        return self.reread_src orelse n.src;
    }

    /// What was actually refused, and where it really is. Last-wins: the
    /// innermost refusal of a statement is the one that propagates, so the
    /// last recorded is the one the trap should name.
    fn noteRefusal(self: *Compiler, n: ts.Node, why: []const u8) void {
        self.last_kind = why;
        self.last_row = self.rereadRow(n);
        const t = n.text();
        self.last_text = if (t.len > 60) t[0..60] else t;
        self.last_fail_src = self.rereadSrc(n).ptr;
    }

    fn nopeKind(self: *Compiler, n: ts.Node, why: []const u8) Error {
        self.noteRefusal(n, why);
        if (self.census) {
            const t0 = n.text();
            self.refusals.append(self.alloc, .{
                .kind = why,
                .row = self.rereadRow(n),
                .text = if (t0.len > 50) t0[0..50] else t0,
                .func = self.cur.name,
                .byte = self.rereadByte(n),
                .src = self.rereadSrc(n),
            }) catch {};
        }
        if (self.fail_kind.len == 0) {
            self.fail_kind = why;
            self.fail_row = self.rereadRow(n);
            const t = n.text();
            self.fail_text = if (t.len > 60) t[0..60] else t;
            self.fail_fn = self.cur.name;
        }
        return Error.Unsupported;
    }

    fn nope(self: *Compiler, n: ts.Node) Error {
        self.noteRefusal(n, n.kind());
        if (self.census) {
            const t0 = n.text();
            self.refusals.append(self.alloc, .{
                .kind = n.kind(),
                .row = self.rereadRow(n),
                .text = if (t0.len > 50) t0[0..50] else t0,
                .func = self.cur.name,
                .byte = self.rereadByte(n),
                .src = self.rereadSrc(n),
            }) catch {};
        }
        if (self.fail_kind.len == 0) {
            self.fail_kind = n.kind();
            self.fail_row = self.rereadRow(n);
            const t = n.text();
            self.fail_text = if (t.len > 60) t[0..60] else t;
            self.fail_fn = self.cur.name;
        }
        return Error.Unsupported;
    }

    /// Leaves the value of `n` in register `dst`.
    fn expr(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        try self.exprBody(n, dst);
        // F-114: the statement's last postfix construct is done -- what the
        // statement emits after it reports the line of the next token
        if (self.tail) |t| {
            if (n.endByte() == t.end and n.startByte() == t.pf_start) self.cur_row = t.row;
        }
    }

    fn exprBody(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        if (self.depth > 200) return self.nope(n);
        self.depth += 1;
        defer self.depth -= 1;
        self.atNode(n);
        const k = n.kind();

        if (std.mem.eql(u8, k, "number")) {
            // `loadi` carries a signed 32-bit immediate. Anything else --
            // a decimal, or an integer too wide for the field -- becomes a
            // constant instead of a refusal. Ring has one number type and
            // it is a double (§4.5), so a decimal is not an exotic case:
            // 233 literals in Softanza are written with a point.
            const t = std.mem.trim(u8, n.text(), " \t\r\n");
            if (std.fmt.parseInt(i64, t, 10)) |v| {
                if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
                    _ = try self.emit(.loadi, dst, 0, 0, @intCast(v));
                    return;
                }
                _ = try self.emit(.loadk, dst, 0, 0, try self.konstNum(@floatFromInt(v)));
                return;
            } else |_| {}
            const d = std.fmt.parseFloat(f64, t) catch return self.nope(n);
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstNum(d));
            return;
        }
        if (std.mem.eql(u8, k, "boolean")) {
            // Verified on 1.27: TRUE is the NUMBER 1, FALSE the NUMBER 0.
            // §3.1 -- there is no boolean type to load.
            const t = n.text();
            const yes = std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t\r\n"), "true");
            _ = try self.emit(.loadi, dst, 0, 0, if (yes) 1 else 0);
            return;
        }
        if (std.mem.eql(u8, k, "null")) {
            // Verified on 1.27: the NULL literal is the EMPTY STRING --
            // type() says STRING, len() says 0. (An UNINITIALISED slot is
            // the thing that prints as "NULL"; the literal is not it.)
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex("\"\""));
            return;
        }
        if (std.mem.eql(u8, k, "call_keyword_expression")) return self.callKeyword(n, dst);
        if (std.mem.eql(u8, k, "this") or std.mem.eql(u8, k, "self")) {
            _ = try self.emit(.move, dst, self.selfIsBrace(n) orelse 0, 1, 0); // r0 is the receiver
            return;
        }
        if (std.mem.eql(u8, k, "string")) {
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex(n.text()));
            return;
        }
        if (std.mem.eql(u8, k, "symbol")) {
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstSymbol(n.text()));
            return;
        }
        if (std.mem.eql(u8, k, "identifier")) {
            const nm = n.text();
            // Ring's predefined character constants, verified on 1.27:
            // one byte each -- nl is 10, tab 9, cr 13. `nl` alone is 303
            // of the refused identifiers, the largest single name.
            if (std.ascii.eqlIgnoreCase(nm, "nl") or
                std.ascii.eqlIgnoreCase(nm, "tab") or
                std.ascii.eqlIgnoreCase(nm, "cr"))
            {
                // ...and an ASSIGNMENT SHADOWS THEM, from the assignment
                // onwards. `cr = "xyz"` then `cr` is "xyz", while a read
                // BEFORE it still gives the carriage return -- probed on 1.27
                // and pinned in exec/char_consts.ring. That makes it a RUNTIME
                // question, so the constant is loaded and `gorc` replaces it
                // when the global has actually been set.
                //
                // This checked for a LOCAL only. At the TOP LEVEL an
                // assignment makes a GLOBAL, not a local, so every read
                // compiled to the constant and the name could never be
                // written at all: `cR = "xyz"` left len(cR) at 1, for ever.
                // Three ordinary variable names -- cr, nl, tab, in any case --
                // silently read-only. perf/seams stores a refusal result in a
                // variable called `cR`, which is how it surfaced 2026-09-14.
                if (self.lookup(nm) == null) {
                    const ch: u8 = if (std.ascii.eqlIgnoreCase(nm, "nl")) 10 else if (std.ascii.eqlIgnoreCase(nm, "tab")) 9 else 13;
                    // Heap, not stack: konstIndex KEEPS the slice, so a
                    // local array here dangles -- which is exactly what
                    // made `tab` come back as 13.
                    const one = self.alloc.alloc(u8, 3) catch return Error.OutOfMemory;
                    one[0] = '"';
                    one[1] = ch;
                    one[2] = '"';
                    _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex(one));
                    if (self.knownGlobal(nm)) |slot|
                        _ = try self.emit(.gorc, dst, 0, 0, slot);
                    return;
                }
            }

            // Rule A: `@x` is an ATTRIBUTE, wherever it appears in a
            // class. The pre-pass registered it, so this cannot fail for
            // a method; outside a class the name has no meaning.
            // Inside a catch body, `cCatchError` names THAT handler's
            // binding -- lexically, not through a shared cell. ANYWHERE
            // ELSE it is what Ring's is: the last error any handler
            // caught, process-wide, "NULL" before the first (C-15,
            // measured 2026-09-24). This REFUSED such a read, and the
            // estate reads it through a FUNCTION -- `CatchError()` in
            // stkRingFuncs.ring, called from inside its handlers -- so
            // every reactive watcher and computed attribute died here.
            if (std.ascii.eqlIgnoreCase(nm, "cCatchError")) {
                if (self.catch_regs.items.len > 0) {
                    _ = try self.emit(.move, dst, self.catch_regs.items[self.catch_regs.items.len - 1], 1, 0);
                    return;
                }
                _ = try self.emit(.bcall, dst, dst, 0, @intFromEnum(vm.Builtin.catchlast));
                return;
            }
            if (nm.len > 1 and nm[0] == '@') {
                if (self.braces.items.len > 0 and try self.braceAttrRead(nm, dst)) return;
                // eval mode: by NAME on the caller's receiver (F-72)
                if (self.eval) |ev| {
                    if (ev.owner == null) return self.nopeKind(n, "eval: @attribute outside a class");
                    _ = try self.emit(.gattrn, dst, 0, vm.ACC_RAW, try self.nameIndex(nm));
                    return;
                }
                const slot = self.attrSlot(nm) orelse return self.nopeKind(n, "@attribute outside a class");
                _ = try self.emit(.gattr, dst, 0, 0, @intCast(slot));
                return;
            }
            // a parameter spelt `$n2` is the parameter (F-91)
            if (self.paramLocal(nm)) |l| {
                try self.daRead(l, nm);
                _ = try self.emit(.move, dst, l.reg, if (l.class.boxed()) 1 else 0, 0);
                return;
            }
            // Rule A: `$x` is a GLOBAL. Reading one that nothing assigns
            // is a compile error -- §2.6's R24, moved to build time, which
            // is the whole point of making the sigil compulsory.
            if ((nm.len > 1 and nm[0] == '$') or (self.topGlobal(nm) and self.knownGlobal(nm) != null)) {
                // IN A CLASS BODY, an unknown name read makes Ring CREATE an
                // attribute of that name, NULL (F-70, measured on 1.27:
                // `x = $nope` in a class leaves o.x "NULL" and attributes(o)
                // listing `$nope`; the same read anywhere else is R24). The
                // prologue is that body. `ggeta` reads the global when it is
                // set and creates the attribute when it is not; a name no
                // slot exists for can only be the attribute (c = 1, d the
                // name). Softanza reads `$cDefaultDiagramOutputFormat`, which
                // nothing assigns, in stzDiagram's body -- three tests.
                if (std.mem.eql(u8, self.cur.name, PROLOGUE)) {
                    if (self.knownGlobal(nm)) |slot| {
                        _ = try self.emit(.ggeta, dst, 0, 0, slot);
                    } else {
                        _ = try self.emit(.ggeta, dst, 0, 1, @intCast(try self.nameIndex(nm)));
                    }
                    return;
                }
                const slot = self.knownGlobal(nm) orelse {
                    // eval: `$x` no slot exists for -- one an eval made, or R24
                    // naming it, as Ring raises (F-107); compiled code keeps the
                    // refusal, Rule A's
                    if (self.eval != null) return self.unknownRead(dst, nm, false);
                    return self.nopeKind(n, "$global never assigned");
                };
                // c = 1 IN A METHOD: an unset global falls back to an
                // attribute of that name the OBJECT gained (F-70's rule, or
                // addattribute) before it is R24 -- Ring resolves local ->
                // attribute -> global, and `def M return $nope` answers the
                // NULL the class body created.
                _ = try self.emit(.gget, dst, 0, if (self.cur.owner != null) 1 else 0, slot);
                return;
            }
            if (std.ascii.eqlIgnoreCase(nm, "this") or std.ascii.eqlIgnoreCase(nm, "self")) {
                _ = try self.emit(.move, dst, self.selfIsBrace(n) orelse 0, 1, 0);
                return;
            }
            // Ring resolves a bare name parameter/local -> attribute ->
            // global. The first two steps are provable here; the third is
            // not, and is where Ring++ stops. Probed on 1.27: a parameter
            // named like an attribute SHIELDS it (M(100) returned 101 and
            // the attribute stayed 7), so the local must be tried first.
            // C-11: the loop variable is scoped to its loop. Ring leaves 6 after
            // `for i = 1 to 5`, 3 after an exit at 3, 1 after a loop that never
            // ran and "" after a for-in (four rules, analysis 2.12); Ring++
            // leaves no variable, as Lua does, and says so here.
            if (self.wasLoopVar(nm)) return self.nopeKind(n, "loop variable read after its loop (C-11: it is scoped to the loop)");
            if (self.lookup(nm)) |l| {
                try self.daRead(l, nm);
                // eval code reading the CALLER's local: one nothing assigned is
                // R24 naming it, as on Ring (F-107)
                if (self.eval) |ev| {
                    if (l.reg < ev.frame) _ = try self.emit(.chkl, l.reg, 0, 1, try self.konstIndex(nm));
                }
                _ = try self.emit(.move, dst, l.reg, if (l.class.boxed()) 1 else 0, 0);
                return;
            }
            // Inside a lambda, a captured name lives in the closure --
            // slot 0 is the function id, so capture i is at slot i+1.
            if (self.cur.lambda_at != null) {
                for (self.cur.captures.items, 0..) |cap, ci| {
                    if (!std.ascii.eqlIgnoreCase(cap, nm)) continue;
                    const save = self.temp;
                    defer self.temp = save;
                    const ir = try self.tmp();
                    _ = try self.emit(.loadi, ir, 0, 0, @intCast(ci + 2));
                    _ = try self.emit(.vget, dst, 0, ir, 0);
                    return;
                }
                // NOT a capture: a free name in a lambda that names a
                // top-level GLOBAL is a global READ, performed when the
                // lambda RUNS. Measured on 1.27: `n = 10; f = func x {
                // return x + n }; n = 100; call f(32)` answers 132, not 42
                // -- and a name assigned only AFTER the lambda is built
                // still reads, which capture-at-creation cannot do at all.
                // The closure build drops these for the same reason, so
                // the two sides agree on what a capture is.
                if (self.knownGlobal(nm)) |gslot| {
                    _ = try self.emit(.gget, dst, 0, 0, gslot);
                    return;
                }
            }
            // `sysargv` is Ring's builtin global: the process arguments as
            // a list -- [exe, script, args...] on 1.27, probed 2026-09-09.
            // Softanza's six _RingExecutable() methods read [1] to spawn a
            // child on the same interpreter; here that child runs on rnxc.
            if (std.ascii.eqlIgnoreCase(nm, "sysargv")) {
                _ = try self.emit(.bcall, dst, dst, 0, @intFromEnum(vm.Builtin.sysargv));
                return;
            }
            // Inside `obj { ... }`: a local shields it (measured: `x = x + 1`
            // in a block, with a local x, wrote the LOCAL), otherwise the
            // name is the object's attribute.
            if (self.braces.items.len > 0 and try self.braceAttrRead(nm, dst)) return;
            // EVAL MODE resolves the same way Ring does at run time, from the
            // VM's tables: the caller's attribute by name, then a global.
            if (self.eval) |ev| {
                if (self.evalHasAttr(ev, nm)) {
                    _ = try self.emit(.gattrn, dst, 0, vm.ACC_RAW, try self.nameIndex(nm));
                    return;
                }
                if (self.knownGlobal(nm)) |gs| {
                    _ = try self.emit(.gget, dst, 0, if (ev.owner != null) 1 else 0, gs);
                    return;
                }
            }
            // Ring resolves a bare name local -> ATTRIBUTE -> global, and this
            // is step two: a name the class DECLARES (or inherits) is that
            // attribute. Provable -- the class is known and the name is in its
            // declaration list -- and it is what `cTP = ""` in a class body
            // means to every method that reads it. 196 refusals in Softanza.
            // NOT INSIDE A BRACE (F-124): there the object scope is the brace
            // object's, and the method's own attributes are not visible to a
            // bare name -- Ring answers R24 for one read there
            if (if (self.braces.items.len == 0) self.declaredAttr(nm) else null) |slot| {
                _ = try self.emit(.gattr, dst, 0, 0, @intCast(slot));
                return;
            }
            // At the top level, a bare name assigned NOWHERE is not a Rule A
            // question at all -- there is no global, attribute or local for
            // it to be confused with. Ring reads it and raises R24 naming
            // it, so this compiles to exactly that: the statements before it
            // run, and the program stops where Ring stops. Refusing instead
            // poisoned the whole top level and printed nothing at all
            // (2026-09-12, reactive/62_reactive_timer_surface: 0 lines
            // against Ring's 11 and its error).
            if (self.cur.is_main and self.knownGlobal(nm) == null) {
                try self.unknownRead(dst, nm, false);
                return;
            }
            // ...and the same holds INSIDE a function or a method, which the
            // rule above never reached (2026-09-27). Locals persist from pass
            // A, so "not a local" here means assigned NOWHERE in the function;
            // with no global of that name either, Rule A has nothing to guard
            // -- no other variable for the read to be confused with. Ring
            // raises R24 at the read, naming it, and ONLY IF THE LINE RUNS:
            // Ring's own stdlibcore has `if elementcount < 1 then return ok`
            // (`then` is not a keyword), and refusing it took Permutation()
            // down on every list, where Ring fails only on an empty one. In a
            // METHOD (c = 1) an attribute the object gained -- addattribute,
            // F-70 -- is what Ring finds first, as `gget` already does.
            if (self.knownGlobal(nm) == null) {
                try self.unknownRead(dst, nm, if (self.eval) |ev| ev.owner != null else self.cur.owner != null);
                return;
            }
            // Rule A: a bare name is a LOCAL, and nothing else. No
            // fall-through to attributes or globals -- that fall-through
            // is precisely §2.7, and removing it is what makes a method's
            // assignment physically unable to reach a caller.
            return self.nopeKind(n, if (self.cur.is_main)
                "top-level bare name needs $ (Rule A)"
            else
                "bare name is not a local (Rule A)");
        }
        // `new C` and `new C(args)` are two grammar nodes, and only the
        // first was routed here -- so `new stzList(This.Content())` fell
        // through to the generic refusal. 17 roots in Softanza. newObj
        // already reads an `arguments` child, which is exactly what
        // new_with_parens carries.
        if (std.mem.eql(u8, k, "brace_expression")) return self.braceExpr(n, dst);
        if (std.mem.eql(u8, k, "new_expression") or
            std.mem.eql(u8, k, "new_with_parens")) return self.newObj(n, dst);
        if (std.mem.eql(u8, k, "member_expression")) {
            // `This.Attr` has a receiver the compiler KNOWS, so its slot is a
            // constant. `o.Attr` does not: two unrelated classes can hold the
            // same name at different slots, and guessing would be a silent
            // wrong answer rather than a refusal. It waits for receiver-class
            // inference.
            if (self.isThis(n.namedChild(0))) {
                const mname = n.namedChild(1).text();
                // eval mode: by name, R12 at run time on a miss as Ring
                if (self.eval != null) {
                    _ = try self.emit(.gattrn, dst, 0, vm.ACC_RAW, try self.nameIndex(mname));
                    return;
                }
                if (self.attrSlot(mname)) |slot| {
                    _ = try self.emit(.gattr, dst, 0, 0, @intCast(slot));
                    return;
                }
                // `This.Name` WHERE THE CLASS HAS NO SUCH PROPERTY used to
                // be REFUSED here -- anonymously, or with a message when
                // Name was a method of this class. Measured on 1.27
                // (2026-09-22): Ring answers `Error (R12) : Error in
                // property name, property not found: name`, catchable, with
                // the program running on, for BOTH shapes -- a name that is
                // a method, a name that is nothing, and a name declared with
                // the `@` sigil and read without it.
                //
                // So the refusal was STRICTER THAN RING, and it is the same
                // verdict userCall already carries for R19: a refusal is the
                // safe answer only when the alternative is a WRONG one, and
                // here the alternative is Ring's own answer. It cost whole
                // methods -- `stzFile.PreserveAndModify` reads
                // `This.cOriginalContent` where the attribute is declared
                // `@cOriginalContent`, a one-line latent bug that compiled
                // the method away.
                //
                // Nothing special is emitted: falling through reaches the
                // by-NAME resolution below, which is what an unproved
                // receiver already uses and which raises Ring's R12 on a
                // miss. The path was there; only the refusal stood in front
                // of it.
                //
                // WHAT IS LOST is the diagnostic, and it was worth having:
                // `This.Name` naming a METHOD is always a defect. It
                // belongs to `rnxc check`, whose cross-file half needs the
                // definition universe -- named in "Next" rather than
                // pretended to be covered.
            }
            // `o.@attr` where o's class is PROVED. The slot is then known
            // and this is not the guess the comment above refuses to make:
            // recvClass answers only for `new C`, `This`, and a local every
            // assignment agrees on, and where it says nothing, so does this.
            // gattr already carries the object in r[b]; This-attribute reads
            // pass 0, which is r0, which is `this`.
            if (self.recvClass(n.namedChild(0))) |rcid| {
                if (self.attrSlotOf(rcid, n.namedChild(1).text())) |slot| {
                    // a class with `get<name>` is read through it (F-73):
                    // the by-name path below applies Ring's whole rule
                    if (!self.hasAccessor(rcid, n.namedChild(1).text(), true)) {
                        const save = self.temp;
                        defer self.temp = save;
                        const o = try self.tmp();
                        try self.expr(n.namedChild(0), o);
                        _ = try self.emit(.gattr, dst, o, 0, @intCast(slot));
                        return;
                    }
                }
            }
            // Not proved -- a receiver that arrived as a parameter, or sits
            // in a global or an attribute (`@oDiagram = poDiagram`, and
            // then `@oDiagram.@cTheme`: 105 sites in Softanza, 2026-09-09).
            // Resolved by NAME at run time from the object's actual class,
            // which is what Ring does at every property access; a miss is
            // Ring's R12 with the name. Not a guess: the object answers.
            {
                const save = self.temp;
                defer self.temp = save;
                const o = try self.tmp();
                try self.expr(n.namedChild(0), o);
                const ni = try self.nameIndex(n.namedChild(1).text());
                _ = try self.emit(.gattrn, dst, o, self.accMode(), ni);
                return;
            }
        }
        if (std.mem.eql(u8, k, "parenthesized_expression")) {
            return self.expr(n.namedChild(0), dst);
        }
        // `n++` AS A VALUE, and Ring's POSTFIX SYNTAX HAS PRE-INCREMENT
        // SEMANTICS: it increments and yields the NEW value. Measured on
        // 1.27 (bench/exec/postfix_value.ring) -- `x = n++` with n at 5
        // leaves BOTH at 6, `? m++` prints 6, `(k++) + 1` is 7, and
        // `j++ + j++` is 13, which is 6 + 7 and pins the order too.
        //
        // The statement form's comment said this "would need Ring's
        // pre/post distinction pinned down first, and it is not written
        // that way in Softanza". Both halves were wrong. The distinction is
        // measured above, and `This.MatchAt(_cStr_, _nStart_++)` is exactly
        // that shape -- as is `if _bUp_: _nConnections_++ ok`, where the
        // `:` is Ring's RANGE operator and not a one-line `if` at all
        // (F-65), so the increment is an eagerly evaluated range bound.
        //
        // Only a plain NAME is taken as a value. A subscript target would
        // have its index evaluated TWICE -- once to increment and once to
        // read back -- which is a silent wrong answer wherever the index
        // has a side effect. The estate has no such site, so the cheap
        // correct rule is the narrow one, and it says so when it declines.
        // IT IS EMITTED HERE AND NOT DELEGATED TO `stmt`. The first version
        // called `self.stmt(n)` and then read the name back, which is the
        // same instructions in the same order -- and it answered 12 for
        // `1 + n++`. `stmt` is a STATEMENT boundary: it hands out temporary
        // registers from the bottom, because no statement shares one with
        // another. Called from inside an expression it therefore reissued a
        // register the half-built expression was still holding. The
        // disassembly says it in two lines -- `loadi a=0 d=1` putting the
        // left operand in r0, then `gget a=0` overwriting it -- so the add
        // was 6 + 6. A LOCAL target never showed it, because that path
        // needs no temporary at all.
        //
        // dst is both the working register and the answer, which is what
        // makes the inline form shorter than the delegation would have been.
        if (std.mem.eql(u8, k, "postfix_expression")) {
            const tgt = n.namedChild(0);
            if (!std.mem.eql(u8, tgt.kind(), "identifier"))
                return self.nopeKind(n, "++ as a VALUE needs a plain name");
            const op = opText(n);
            const one: i32 = if (std.mem.eql(u8, op, "++"))
                1
            else if (std.mem.eql(u8, op, "--"))
                -1
            else
                return self.nope(n);
            const nm = tgt.text();
            self.unretire(nm);
            if ((nm.len > 1 and nm[0] == '$') or self.topGlobal(nm)) {
                const gslot = self.knownGlobal(nm) orelse
                    return self.nopeKind(tgt, "$global never assigned");
                _ = try self.emit(.gget, dst, 0, 0, gslot);
                _ = try self.emit(.addi, dst, dst, 1, one);
                _ = try self.emit(.gset, dst, 0, 0, gslot);
                return;
            }
            if (self.lookup(nm)) |l| {
                _ = try self.emit(.addi, l.reg, l.reg, 1, one);
                // c = 0: no retain. `addi` has just produced a NUMBER, so
                // there is no reference for the frame sweep to balance --
                // the trap that a `move c=0` carries is a boxed value moved
                // into a masked register, and this can never be one.
                _ = try self.emit(.move, dst, l.reg, 0, 0);
                self.daWrite(l.reg);
                return;
            }
            if (self.attrSlot(nm) orelse self.declaredAttr(nm)) |slot| {
                _ = try self.emit(.gattr, dst, 0, 0, @intCast(slot));
                _ = try self.emit(.addi, dst, dst, 1, one);
                _ = try self.emit(.sattr, 0, dst, 0, @intCast(slot));
                return;
            }
            return self.nopeKind(tgt, if (self.cur.is_main)
                "top-level bare name needs $ (Rule A)"
            else
                "bare name is not a local (Rule A)");
        }
        // A lambda evaluates to its CLOSURE: [func_id, captured...]. The
        // function itself was lowered before codegen; this is only the
        // capture, and it happens HERE, where the captured values are, not
        // at the call site -- which is the whole difference from Ring,
        // where a free name is looked up in the caller's scope when the
        // function runs (§4e).
        if (std.mem.eql(u8, k, "anonymous_function")) {
            // The lambda was lowered from its FILE's tree; a re-read
            // statement hands codegen a snippet's node for the same text.
            // Map it back, and match the file as well as the offset -- an
            // offset alone repeats across a unit (`reread_origin`).
            var at: i64 = n.startByte();
            var in_src = n.src;
            // a statement inside a re-read piece (a brace block's body) can
            // be re-read again, so an origin may itself be a snippet
            var hops: u32 = 0;
            while (self.reread_origin.get(@intFromPtr(in_src.ptr))) |o| : (hops += 1) {
                if (hops == 16) break;
                at += o.shift;
                in_src = o.src;
            }
            var lam: ?u32 = null;
            for (self.funcs.items, 0..) |f, i| {
                if (f.lambda_at != null and f.lambda_at.? == at and f.node.src.ptr == in_src.ptr) lam = @intCast(i);
            }
            const li = lam orelse return self.nopeKind(n, "lambda was not lowered");
            const save = self.temp;
            defer self.temp = save;
            // A CAPTURE IS ONLY A NAME THAT RESOLVES TO AN ENCLOSING LOCAL.
            // `scanCaptures` runs before codegen and cannot know that -- its
            // own comment says so -- so it takes every free name, and the
            // build used to do `lookup(cap) orelse continue`, pushing
            // NOTHING for the rest. The closure came out a slot short and
            // the body indexed past it: `n = 10; f = func x { return x + n }`
            // answered R2 where Ring answers 42.
            //
            // A top-level name is a GLOBAL (C-2), and Ring reads a global
            // when the lambda RUNS, not when it is built -- so it was never
            // a capture to begin with. Dropped here, read as a global in the
            // body. The list is rewritten rather than skipped over so that
            // both sides index the same slots; the enclosing function is
            // always emitted before the lambda it contains, so the body sees
            // this list.
            var kept: usize = 0;
            for (self.funcs.items[li].captures.items) |cap| {
                if (self.lookup(cap) == null) continue;
                self.funcs.items[li].captures.items[kept] = cap;
                kept += 1;
            }
            self.funcs.items[li].captures.shrinkRetainingCapacity(kept);
            // b = 1 FLAGS THE VECTOR A CLOSURE (vm.Vec.closure), so type(),
            // isString, isList and isFunction answer for it as Ring answers
            // for its lambda string -- the estate's guards are written
            // `isString(f) and isFunction(f)`.
            _ = try self.emit(.vnew, dst, 1, 1, @intCast(kept + 1));
            const t = try self.tmp();
            // BIASED, so `calli` can tell a closure from a data list --
            // see vm.closure_bias. Ring never has to: its lambda is a string.
            _ = try self.emit(.loadi, t, 0, 0, @intCast(self.funcs.items[li].id + vm.closure_bias));
            _ = try self.emit(.vpush, dst, t, 0, 0);
            for (self.funcs.items[li].captures.items) |cap| {
                const l = self.lookup(cap).?;
                _ = try self.emit(.vpush, dst, l.reg, 1, 0);
            }
            return;
        }
        // `:Name = value` ANYWHERE A VALUE IS WANTED is the two-element
        // list ["name", value] -- Ring's NAMED PARAMETER, measured on 1.27:
        //
        //     f( :From = 3 )      the callee receives ["from", 3]
        //     f( :From = 1 + 2 )  the value is EVALUATED first
        //     y = ( :From = 3 )   outside a call too
        //     if :From = 3        TRUE, because that list is truthy
        //     f( "from" = 3 )     0 -- a STRING on the left is a comparison,
        //     f( x = 3 )          0    and so is a variable. The rule is the
        //                              SYMBOL, not the shape.
        //
        // The grammar hands this over as a `binary_expression` whose left
        // child is a `symbol`, and only the LIST LITERAL path (where it
        // arrives as a `hash_pair`) ever built the pair. Everywhere else it
        // fell through to an equality, so every named argument in the
        // estate arrived as 0 -- and stzListParser.Parse then ran
        // `for i = 3 to 9 step 0`, a loop that appends for ever, which was
        // the last `panic: oom` in the wide clock. About a thousand sites
        // spell an argument this way.
        if ((std.mem.eql(u8, k, "binary_expression") or
            std.mem.eql(u8, k, "assignment_expression")) and
            n.namedChildCount() >= 2 and
            std.mem.eql(u8, opText(n), "=") and
            std.mem.eql(u8, n.namedChild(0).kind(), "symbol"))
        {
            const save = self.temp;
            defer self.temp = save;
            // Built in a TEMP and moved, not built in `dst`: `tmp()` hands
            // out registers above the current mark, and `dst` can BE that
            // mark -- so building in place and then asking for a temp
            // returned the same register, the key overwrote the vector, and
            // `vpush` pushed into a string. A segfault at 0xc, found in
            // stzListParser's `if isList(a) and (IsFrom... or ...)` where
            // the pair was a parameter. The hash_pair path in the list
            // literal below has always done it this way.
            _ = try self.emit(.vnew, dst, 0, 1, 2);
            const kt = try self.tmp();
            try self.expr(n.namedChild(0), kt);
            _ = try self.emit(.vpush, dst, kt, 1, 0);
            const vt = try self.tmp();
            try self.expr(n.namedChild(1), vt);
            _ = try self.emit(.vpush, dst, vt, 1, 0);
            return;
        }
        if (std.mem.eql(u8, k, "list_literal")) {
            // Exact capacity. A literal knows how many elements it has, and
            // the default of 8 gave every [key, value] pair six empty slots
            // -- 96 bytes of slack on a 32-byte payload, which at 200,000
            // pairs was ~25 MB of nothing and most of the gap to the map
            // type's memory gate. The count includes comments, so it can
            // only over-allocate by the odd slot, never under.
            _ = try self.emit(.vnew, dst, 0, 1, @intCast(n.namedChildCount()));
            var e: u32 = 0;
            while (e < n.namedChildCount()) : (e += 1) {
                const save2 = self.temp;
                defer self.temp = save2;
                const el = n.namedChild(e);
                // A comment INSIDE a list literal is a named child, and
                // compiling it as an element refused the whole statement.
                // Softanza annotates its big tables that way, so 83 of
                // them landed in the file's top level and stopped it from
                // running at all -- a `#` in a list was enough to make the
                // library unloadable.
                if (std.mem.eql(u8, el.kind(), "comment")) continue;
                const t = try self.tmp();
                if (std.mem.eql(u8, el.kind(), "hash_pair") and
                    !std.mem.eql(u8, el.namedChild(0).kind(), "symbol"))
                {
                    // ONLY A :SYMBOL KEY BUILDS THE PAIR (F-59, measured in a
                    // list literal on both 1.27 builds): `[ "name" = "M" ]`
                    // and `[ x = 3 ]` are comparisons there as everywhere,
                    // giving [ 0 ] and [ 1 ]. The grammar hands any `k = v`
                    // in a list over as a hash_pair, and this built a pair
                    // from every one (bench/exec/list_pair_key.ring).
                    const kt = try self.tmp();
                    try self.expr(el.namedChild(0), kt);
                    const vt = try self.tmp();
                    try self.expr(el.namedChild(1), vt);
                    _ = try self.emit(.cmpv, t, kt, vt, 0);
                } else if (std.mem.eql(u8, el.kind(), "hash_pair")) {
                    // `:k = v` is sugar for the two-element list ["k", v].
                    // Nothing in Ring hides that: `aH[1][1]` is the key.
                    // RETAINED (c=1), like every other vector born into a
                    // register. Born with rc 0 and left unretained, the
                    // register held a reference the count did not know
                    // about: `ret` swept it to rc 0 and freed the pair the
                    // outer list still pointed at, and the outer's own
                    // release then underflowed the count. ReleaseFast wraps
                    // that to 4 billion and leaks; ReleaseSafe panics.
                    _ = try self.emit(.vnew, t, 0, 1, 2);
                    const kt = try self.tmp();
                    try self.expr(el.namedChild(0), kt);
                    _ = try self.emit(.vpush, t, kt, 1, 0);
                    const vt = try self.tmp();
                    try self.expr(el.namedChild(1), vt);
                    _ = try self.emit(.vpush, t, vt, 1, 0);
                } else {
                    try self.expr(el, t);
                    if (self.needsCopy(el)) _ = try self.emit(.copyv, t, 0, 0, 0);
                }
                _ = try self.emit(.vpush, dst, t, 1, 0);
            }
            return;
        }
        if (std.mem.eql(u8, k, "subscript_expression")) {
            const save = self.temp;
            defer self.temp = save;
            const base = try self.borrowBase(n.namedChild(0));
            const idx = try self.indexReg(n.namedChild(1));
            // Specialise when inference proved what the container is. The
            // dynamic form stays for everything it could not prove, which is
            // where the type-hint channel earns its keep.
            const bc = self.classOf(n.namedChild(0));
            const ec = self.elemOf(n.namedChild(0));
            // A string index into a list is a hash lookup, never a position.
            if (self.classOf(n.namedChild(1)) == .str and bc != .str) {
                _ = try self.emit(.hget, dst, base, idx, 1);
                return;
            }
            switch (bc) {
                .list => _ = try self.emit(.vget, dst, base, idx, if (ec.boxed()) 1 else 0),
                .str => _ = try self.emit(.sgets, dst, base, idx, 0),
                else => _ = try self.emit(.dget, dst, base, idx, 1),
            }
            return;
        }
        if (std.mem.eql(u8, k, "binary_expression")) return self.binary(n, dst);
        // `return This.NumberOfItems() = 0` -- an `assignment_expression`
        // in VALUE position is an EQUALITY. Ring spells assignment and
        // comparison the same way and assignment is a STATEMENT, so",
        // wherever a value is wanted the comparison is the only reading
        // available. The grammar has to guess from shape alone and calls
        // it an assignment; this is where that name stops mattering.
        // `binary` reads the operator off the first anonymous token, which
        // is the `=` either way, so the node needs no reshaping.
        //
        // Measured 2026-09-04: the largest refusal class in Softanza, 289
        // of 933, and every sampled site was this -- IsEmpty() returning
        // `This.NumberOfItems() = 0`, and its like.
        if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() >= 2)
            return self.binary(n, dst);
        if (std.mem.eql(u8, k, "unary_expression") and
            (std.mem.eql(u8, opText(n), "not") or std.mem.eql(u8, opText(n), "!")))
        {
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            try self.expr(n.namedChild(0), t);
            _ = try self.emit(.lnot, dst, t, 0, 0);
            return;
        }
        if (std.mem.eql(u8, k, "unary_expression")) {
            // The operator is CHECKED. This assumed `-x` and negated
            // whatever it was given, so a unary `+` -- which the grammar
            // produces for the leading operand of `"" + a + b` -- was
            // silently compiled as a negation. A wrong answer, not a
            // refusal, which is the worse of the two.
            const uop = opText(n);
            const save = self.temp;
            defer self.temp = save;
            if (std.mem.eql(u8, uop, "+")) return self.expr(n.namedChild(0), dst);
            // `~x` is `x ^ -1`: ~5 is -6 on 1.27, and no opcode is needed.
            if (std.mem.eql(u8, uop, "~")) {
                const t = try self.tmp();
                try self.expr(n.namedChild(0), t);
                const m = try self.tmp();
                _ = try self.emit(.loadi, m, 0, 0, -1);
                _ = try self.emit(.bxor, dst, t, m, 0);
                return;
            }
            if (!std.mem.eql(u8, uop, "-")) return self.nope(n);
            const t = try self.tmp();
            try self.expr(n.namedChild(0), t);
            _ = try self.emit(.loadi, dst, 0, 0, 0);
            // d = 1: a UNARY minus. An object operand is told "neg" with 0
            // (measured on 1.27), not "r-".
            _ = try self.emit(.sub, dst, dst, t, 1);
            return;
        }
        if (std.mem.eql(u8, k, "call_expression")) return self.call(n, dst);

        return self.nope(n);
    }

    fn binary(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        const op = logicOp(opText(n));
        const save = self.temp;
        defer self.temp = save;
        const ln = n.namedChild(0);
        const rn = n.namedChild(1);

        // `and`/`or` as VALUES, not only as conditions -- 2,474 sites in
        // Softanza. Ring yields 1 or 0 (not the operand, unlike Lua and
        // Python), and short-circuits.
        const is_and = std.mem.eql(u8, op, "and");
        const is_or = std.mem.eql(u8, op, "or");
        if (is_and or is_or) {
            const t = try self.tmp();
            try self.expr(ln, t);
            const shortcut = try self.emit(if (is_and) .jfalsy else .jtruthy, t, 0, 0, 0);
            const t2 = try self.tmp();
            try self.expr(rn, t2);
            _ = try self.emit(.truth, dst, t2, 0, 0);
            const done = try self.emit(.jmp, 0, 0, 0, 0);
            self.land(shortcut);
            _ = try self.emit(.loadi, dst, 0, 0, if (is_and) 0 else 1);
            self.land(done);
            return;
        }

        // `a : b` builds an inclusive integer list -- 701 sites remained
        // after and/or, and this is what they are.
        if (std.mem.eql(u8, op, ":")) {
            const lo = try self.tmp();
            const hi = try self.tmp();
            try self.expr(ln, lo);
            try self.expr(rn, hi);
            _ = try self.emit(.range, dst, lo, hi, 0);
            return;
        }

        // comparisons used as values: `x = (a > b)` yields 1 or 0 -- unless
        // an operand may be an OBJECT, whose `operator` answers whatever it
        // likes (F-69): then `cmpv`, which lands that answer
        for ([_][]const u8{ "=", "!=", "<", "<=", ">", ">=" }, 0..) |cmp, ci| {
            if (!std.mem.eql(u8, op, cmp)) continue;
            if (self.classOf(ln) == .ref or self.classOf(rn) == .ref) {
                const lreg = try self.borrowOperand(ln, dst);
                const rreg = if (try self.operandReg(rn)) |r| r else blk: {
                    const t = try self.tmp();
                    try self.expr(rn, t);
                    break :blk t;
                };
                _ = try self.emit(.cmpv, dst, lreg, rreg, @intCast(ci));
                return;
            }
            var nofire = std.ArrayListUnmanaged(u32){};
            defer nofire.deinit(self.scratch);
            try self.cond(n, &nofire);
            _ = try self.emit(.loadi, dst, 0, 0, 1);
            const done = try self.emit(.jmp, 0, 0, 0, 0);
            for (nofire.items) |p| self.land(p);
            _ = try self.emit(.loadi, dst, 0, 0, 0);
            self.land(done);
            return;
        }

        const plus = std.mem.eql(u8, op, "+");
        const minus = std.mem.eql(u8, op, "-");
        const times = std.mem.eql(u8, op, "*");
        const modu = std.mem.eql(u8, op, "%");
        const divd = std.mem.eql(u8, op, "/");

        // Bitwise: register form only, the VM truncates to i64 as Ring
        // does. `^` is XOR in Ring (5 ^ 1 is 4 on 1.27); power is `**`.
        const bit: ?vm.Op = if (std.mem.eql(u8, op, "&")) .band else if (std.mem.eql(u8, op, "|")) .bor else if (std.mem.eql(u8, op, "^")) .bxor else if (std.mem.eql(u8, op, "<<")) .shl else if (std.mem.eql(u8, op, ">>")) .shr else null;
        if (bit) |bo| {
            const lreg = try self.borrowOperand(ln, dst);
            const rreg = if (try self.operandReg(rn)) |r| r else blk: {
                const t = try self.tmp();
                try self.expr(rn, t);
                break :blk t;
            };
            _ = try self.emit(bo, dst, lreg, rreg, 0);
            return;
        }
        if (!(plus or minus or times or modu or divd)) return self.nope(n);

        // ---- immediate forms ------------------------------------------
        // `x % 1000000007` is one instruction, not a load plus an op. `+`
        // and `*` also fold a constant on the LEFT; `-` and `%` do not,
        // because they are not commutative.
        // AN OBJECT ON THE LEFT dispatches to its class's `operator` with
        // the operator's own text (F-69), so `o - 5` may not fold into
        // `addi -5` -- the class would be told "+" -- and a constant on the
        // LEFT of a possible object may not fold either: Ring calls
        // operator("r*", 5) for `5 * o`, and the fold would call "*".
        const may_obj_l = self.classOf(ln) == .ref;
        const may_obj_r = self.classOf(rn) == .ref;
        if (immOf(rn)) |k| if (!divd and !(minus and may_obj_l)) {
            const src = try self.borrowOperand(ln, dst);
            if (plus) {
                _ = try self.emit(.addi, dst, src, 0, k);
                return;
            } else if (minus) {
                _ = try self.emit(.addi, dst, src, 0, -k);
                return;
            } else if (times) {
                _ = try self.emit(.muli, dst, src, 0, k);
                return;
            } else if (k != 0) {
                _ = try self.emit(.modi, dst, src, 0, k);
                return;
            }
        };
        // A constant on the LEFT folds into the immediate form only when
        // the operator is commutative for the operands at hand. `*` is;
        // `+` is not once a string is involved: `1 + "5"` is 6 on Ring and
        // `"5" + 1` is "51", and folding the 1 to the right made rnx say
        // 51 (found 2026-09-11, C-8). So `+` folds a left constant only
        // for a right operand proved numeric.
        if (((plus and self.classOf(rn) == .int) or times) and immOf(ln) != null and !may_obj_r) {
            const k = immOf(ln).?;
            const src = try self.borrowOperand(rn, dst);
            _ = try self.emit(if (plus) .addi else .muli, dst, src, 0, k);
            return;
        }

        // ---- register forms -------------------------------------------
        const lreg = try self.borrowOperand(ln, dst);
        const rreg = if (try self.operandReg(rn)) |r| r else blk: {
            const t = try self.tmp();
            try self.expr(rn, t);
            break :blk t;
        };
        const o: vm.Op = if (plus) .add else if (minus) .sub else if (times) .mul else if (divd) .div else .mod;
        // d bit 4: `aL + [...]` with a list LITERAL on the right, whose
        // `ref()`s Ring pins (F-118, the VM's addSlow)
        _ = try self.emit(o, dst, lreg, rreg, if (plus and std.mem.eql(u8, rn.kind(), "list_literal")) 4 else 0);
    }

    /// The register holding `n`: its own if it is a plain variable,
    /// otherwise `fallback`, into which the value is computed.
    fn borrowOperand(self: *Compiler, n: ts.Node, fallback: u8) Error!u8 {
        if (try self.operandReg(n)) |r| return r;
        try self.expr(n, fallback);
        return fallback;
    }

    fn isThis(self: *Compiler, n: ts.Node) bool {
        // in a brace `self` is the brace object, not the receiver (F-124)
        if (self.selfIsBrace(n) != null) return false;
        // The grammar gives the receiver its own node kinds -- `This` is a
        // `self` wrapping a `this`, not an identifier. Matching only the
        // identifier case refused every one of them.
        const k = n.kind();
        if (std.mem.eql(u8, k, "self") or std.mem.eql(u8, k, "this")) return true;
        if (!std.mem.eql(u8, k, "identifier")) return false;
        const t = n.text();
        return std.ascii.eqlIgnoreCase(t, "this") or std.ascii.eqlIgnoreCase(t, "self");
    }

    fn call(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        // `super.Method(...)` -- the PARENT class's method, on this same
        // receiver. Resolved statically: the parent is known at compile
        // time, so this is a direct call rather than a dispatch, and it
        // cannot be intercepted by an override the way `This.Method()`
        // can.
        if (std.mem.eql(u8, n.namedChild(0).kind(), "member_expression") and
            std.mem.eql(u8, n.namedChild(0).namedChild(0).kind(), "super"))
        {
            const mexp = n.namedChild(0);
            if (self.eval != null) return self.nopeKind(n, "eval: super inside an eval string");
            const cid = self.cur.owner orelse return self.nopeKind(n, "super outside a class");
            const pid = self.classes.items[cid].parent orelse
                return self.nopeKind(n, "super with no parent class");
            const mi = self.methodOf(pid, mexp.namedChild(1).text()) orelse
                return self.nopeKind(n, "super: no such method on the parent");

            var ar = ts.Node{ .raw = undefined, .src = n.src };
            var have = false;
            var q: u32 = 0;
            while (q < n.namedChildCount()) : (q += 1) {
                if (std.mem.eql(u8, n.namedChild(q).kind(), "arguments")) {
                    ar = n.namedChild(q);
                    have = true;
                }
            }
            const argc: u32 = if (have) ar.namedChildCount() else 0;

            const save = self.temp;
            defer self.temp = save;
            const win = try self.tmp();
            _ = try self.emit(.move, win, 0, 1, 0); // r0 is `this`
            var a: u32 = 0;
            while (a < argc) : (a += 1) {
                const r = try self.tmp();
                try self.expr(ar.namedChild(a), r);
            }
            // `super.M(...)` is the one method call that is bound here
            // rather than dispatched, so its count is checked here: R19 or
            // R20 after the arguments, as `userCall` does for a function
            // and as `callm` does at run time for every other method.
            const want = declaredArity(&self.funcs.items[mi]);
            if (argc != want) {
                const er = try self.tmp();
                const msg = if (argc < want)
                    "\"Error (R19) : Calling function with less number of parameters\""
                else
                    "\"Error (R20) : Calling function with extra number of parameters\"";
                _ = try self.emit(.loadk, er, 0, 0, try self.konstIndex(msg));
                _ = try self.emit(.trap, er, 0, 0, 0);
                return;
            }
            _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
            self.atNodeStart(n);
            const site = try self.emit(.call, win, 0, 0, 0);
            try self.fixups.append(self.alloc, .{
                .site = site,
                .fidx = mi,
                .from = self.funcIndex(self.cur),
            });
            try self.cur.calls_static.append(self.alloc, mi);
            _ = try self.emit(.move, dst, win, 1, 0);
            return;
        }
        // `recv.Method(...)` -- the callee is a member expression, not a name
        if (std.mem.eql(u8, n.namedChild(0).kind(), "member_expression")) {
            var ar = ts.Node{ .raw = undefined, .src = n.src };
            var have = false;
            var q: u32 = 0;
            while (q < n.namedChildCount()) : (q += 1) {
                if (std.mem.eql(u8, n.namedChild(q).kind(), "arguments")) {
                    ar = n.namedChild(q);
                    have = true;
                }
            }
            return self.memberCall(n.namedChild(0), ar, if (have) ar.namedChildCount() else 0, dst);
        }
        const callee = n.namedChild(0).text();
        var args = n.field("arguments");
        if (args.isNull()) {
            var i: u32 = 0;
            while (i < n.namedChildCount()) : (i += 1) {
                if (std.mem.eql(u8, n.namedChild(i).kind(), "arguments")) args = n.namedChild(i);
            }
        }
        const argc: u32 = if (args.isNull()) 0 else args.namedChildCount();

        // INSIDE `obj { ... }`, a bare call is the OBJECT's method first --
        // ahead of a global function of the same name (measured on 1.27:
        // with `func m` global and `def m()` on the class, `o { m() }` ran
        // the METHOD). A proved class without such a method goes on to
        // the global, as Ring does; an unproved receiver is asked by name.
        if (self.braces.items.len > 0) {
            const b = self.braces.items[self.braces.items.len - 1];
            var mi_static: ?u32 = null;
            if (b.cid) |cid| mi_static = self.methodOf(cid, callee);
            if (b.cid == null or mi_static != null) {
                const save = self.temp;
                defer self.temp = save;
                const win = try self.tmp();
                _ = try self.emit(.move, win, b.reg, 1, 0);
                var a2: u32 = 0;
                while (a2 < argc) : (a2 += 1) {
                    const r = try self.tmp();
                    try self.expr(args.namedChild(a2), r);
                }
                _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
                const ni = try self.nameIndex(callee);
                if (mi_static) |mi| {
                    try self.cur.calls_static.append(self.alloc, mi);
                } else {
                    try self.cur.calls_named.append(self.alloc, ni);
                }
                self.atNodeStart(n);
                // AN UNPROVED RECEIVER MAY LACK THE METHOD, and Ring then
                // calls the global FUNCTION of that name: `StzLocaleQ(...)
                // { Then(...) }` reaches the harness's Then. `callm` raised
                // R14 there. `callmf` skips the hit path's jump on a miss,
                // and the fallback calls the function on the arguments
                // already in the window (moved down one for a user
                // function's layout; a native takes a register range).
                const fallback: ?*Func = if (mi_static == null) self.findFunc(callee) else null;
                if (mi_static == null and (fallback != null or !builtinNamed(callee))) {
                    _ = try self.emit(.callmf, win, @intCast(argc), 0, ni);
                    const hit = try self.emit(.jmp, 0, 0, 0, 0);
                    if (fallback) |uf| {
                        if (argc != uf.params.len) {
                            const er = try self.tmp();
                            const msg = if (argc < uf.params.len)
                                "\"Error (R19) : Calling function with less number of parameters\""
                            else
                                "\"Error (R20) : Calling function with extra number of parameters\"";
                            _ = try self.emit(.loadk, er, 0, 0, try self.konstIndex(msg));
                            _ = try self.emit(.trap, er, 0, 0, 0);
                        } else {
                            var mv: u32 = 0;
                            while (mv < argc) : (mv += 1) {
                                _ = try self.emit(.move, win + @as(u8, @intCast(mv)), win + @as(u8, @intCast(mv)) + 1, 1, 0);
                            }
                            const site = try self.emit(.call, win, 0, 0, 0);
                            try self.fixups.append(self.alloc, .{
                                .site = site,
                                .fidx = self.funcIndex(uf),
                                .from = self.funcIndex(self.cur),
                            });
                        }
                    } else {
                        const ni2 = try self.nameIndex(callee);
                        try self.natives.append(self.alloc, ni2);
                        _ = try self.emit(.ncall, win, win + 1, @intCast(argc), ni2);
                    }
                    self.land(hit);
                    _ = try self.emit(.move, dst, win, 1, 0);
                    return;
                }
                _ = try self.emit(.callm, win, @intCast(argc), 0, ni);
                _ = try self.emit(.move, dst, win, 1, 0);
                return;
            }
        }

        // INSIDE A METHOD, THE CLASS'S OWN METHOD WINS -- on the NAME
        // alone, ahead of any global of that name, and REGARDLESS OF
        // ARITY. Measured on 1.27: with `func Arity(x)` at global scope
        // and `def Arity()` on the class, a bare `Arity()` in a sibling
        // method runs the METHOD. Arity does not participate.
        //
        // This used to be checked AFTER globals, and that order is what
        // made stzHashList's `Keys()` bind to `func Keys(paList)`, fail
        // on arity, and hold 19,516 functions unusable -- the largest
        // single item in the library once classname was done. It needs
        // the receiver the call site does not mention.
        //
        // EVAL FIRST. The eval compiler has no class table of its own --
        // it asks the VM's dispatch table -- so every rule below that reads
        // `self.classes` (ownMethod, findFunc) would index an empty list.
        // evalCall answers the method-first rule from the VM's tables, then
        // a user function by NAME; false hands the builtins their turn.
        if (self.eval) |ev| {
            if (try self.evalCall(ev, n, callee, args, argc, dst)) return;
        }
        // NOT INSIDE A BRACE (F-124): there a bare call the brace object lacks
        // is the global FUNCTION (or R3), never the method's own class's method
        if (if (self.braces.items.len == 0) self.ownMethod(callee) else null) |mi| {
            const save2 = self.temp;
            defer self.temp = save2;
            const win = try self.tmp();
            _ = try self.emit(.move, win, 0, 1, 0); // r0 is `this`
            var a2: u32 = 0;
            while (a2 < argc) : (a2 += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(a2), r);
            }
            _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
            try self.cur.calls_static.append(self.alloc, mi);
            self.atNodeStart(n);
            _ = try self.emit(.callm, win, @intCast(argc), 0, try self.nameIndex(callee));
            _ = try self.emit(.move, dst, win, 1, 0);
            return;
        }

        // A USER FUNCTION REPLACES A BUILTIN OF THE SAME NAME, entirely.
        // Verified on 1.27: with `func Max(aL)` defined, `Max([3,9,2])`
        // is 9 -- and `max(3, 9)` then raises R20, extra parameters. The
        // builtin is gone, process-wide, because a definition took its
        // name (and names fold case, so max and Max are one name).
        //
        // Checking builtins first was therefore wrong, and it cost 167
        // refusals on Softanza's own Max/Min, which take a LIST where
        // Ring's builtins take two numbers.
        //
        // EVAL: the string's names are declared ahead (F-72), and inside an
        // eval string a user function is reached by NAME -- there is no
        // function table to find it in, and the same rule (user functions
        // before builtins) holds, so it comes first here too.
        if (self.eval == null and std.ascii.eqlIgnoreCase(callee, "eval") and argc == 1 and !args.isNull()) {
            try self.predeclareEval(args.namedChild(0));
        }
        if (self.findFunc(callee)) |uf| return self.userCall(n, uf, args, argc, dst);

        // ---- builtins -------------------------------------------------
        if (std.ascii.eqlIgnoreCase(callee, "len")) {
            const save = self.temp;
            defer self.temp = save;
            const ac = self.classOf(args.namedChild(0));
            const t = try self.borrowBase(args.namedChild(0));
            switch (ac) {
                .list => _ = try self.emit(.vlen, dst, t, 0, 0),
                .str => _ = try self.emit(.slen, dst, t, 0, 0),
                else => _ = try self.emit(.dlen, dst, t, 0, CFN),
            }
            return;
        }

        // `floor(a/b)` is the integer-division idiom and gets one opcode.
        // This used to REFUSE every other shape, which predates real
        // division and the floor builtin -- so `floor(2.9)` was a refusal.
        // It is a fast path now, not a gate: anything else falls through
        // to the general builtin below.
        // F-129: and ONLY when both sides are proved integers. `idiv` reads its
        // operands as integers, so `floor(pw * (log10(hz) - lf) / (lt - lf))`
        // divided 14.15 by 1 -- 1.90 truncated -- and Softanza's spectrum plot
        // put every column at twice its pixel: 154 points drawn of Ring's 442,
        // silently. Anything not proved whole is real division, then floor.
        if (std.ascii.eqlIgnoreCase(callee, "floor") and argc == 1 and
            std.mem.eql(u8, args.namedChild(0).kind(), "binary_expression") and
            std.mem.eql(u8, opText(args.namedChild(0)), "/") and
            exprClass(self, self.cur, args.namedChild(0).namedChild(0)) == .int and
            exprClass(self, self.cur, args.namedChild(0).namedChild(1)) == .int)
        {
            const inner = args.namedChild(0);
            const save = self.temp;
            defer self.temp = save;
            const rhs = try self.tmp();
            try self.expr(inner.namedChild(0), dst);
            try self.expr(inner.namedChild(1), rhs);
            _ = try self.emit(.idiv, dst, dst, rhs, 0);
            return;
        }
        // `list(n)` was built HERE, by a loop of vpush in generated code, and
        // took only its first argument: Ring's `list(r, c)` -- r lists of c
        // zeros -- silently came back one-dimensional, and `list(0)`, a
        // range error on Ring, came back empty. Both forms, and `newlist`,
        // are the builtin table's now (list1 / list2d), one native call each.
        if (std.ascii.eqlIgnoreCase(callee, "add")) {
            // MUST mutate the variable's OWN register, never a copy.
            //
            // Loading the list into a temporary first makes rc >= 2, so
            // copy-on-write correctly concludes the list is shared, clones
            // it, and the append lands in the clone -- which is then thrown
            // away. The list never grows and nothing reports an error.
            //
            // This is the general shape: under COW a compiler needs a notion
            // of a mutable PLACE, not just of an expression. Nested path
            // assignment (`a[i][j] = v`) is the same problem one level down
            // and is still unsupported for exactly this reason.
            const target = args.namedChild(0);
            const save = self.temp;
            defer self.temp = save;
            if (!std.mem.eql(u8, target.kind(), "identifier")) {
                // A PLACE IS ANY EXPRESSION -- see the long note at the
                // indexed assignment. `add(o.aL, 99)` and `add(q.L(), 99)`
                // both append to the original on Ring, and the temporary
                // here IS that list now that nothing clones on a write.
                // A fresh list from a call is appended to and dropped,
                // which is also what Ring does with one.
                const lst = try self.tmp();
                try self.expr(target, lst);
                const v = try self.tmp();
                try self.expr(args.namedChild(1), v);
                if (self.needsCopy(args.namedChild(1))) _ = try self.emit(.copyv, v, 0, 0, 0);
                _ = try self.emit(.vpush, lst, v, 1, CFN);
                return;
            }
            const tname = target.text();
            // EVAL: a target that is no local -- an attribute by name, a global,
            // a name an eval made (F-107) -- read, then appended in place: the
            // read hands back the list itself
            if (self.eval != null and self.lookup(tname) == null and !(tname.len > 1 and tname[0] == '$')) {
                const lst = try self.tmp();
                try self.expr(target, lst);
                const v = try self.tmp();
                try self.expr(args.namedChild(1), v);
                if (self.needsCopy(args.namedChild(1))) _ = try self.emit(.copyv, v, 0, 0, 0);
                _ = try self.emit(.vpush, lst, v, 1, CFN);
                return;
            }
            if (tname.len > 1 and tname[0] == '@') {
                // An attribute is a place too. Borrow it for writing rather
                // than reading it into a temporary, or COW clones it and the
                // append is lost.
                const slot = self.attrSlot(tname) orelse return self.nope(target);
                const lst = try self.tmp();
                _ = try self.emit(.gattrw, lst, 0, 0, @intCast(slot));
                const val = try self.tmp();
                try self.expr(args.namedChild(1), val);
                if (self.needsCopy(args.namedChild(1))) _ = try self.emit(.copyv, val, 0, 0, 0);
                _ = try self.emit(.vpush, lst, val, 1, CFN);
                _ = try self.emit(.loadi, lst, 1, 0, 0); // the borrow ends here
                return;
            }
            // `add($g, x)` and, at the top level, `add(g, x)` (C-2): the global
            // borrowed for writing, exactly as del() borrows it.
            if ((tname.len > 1 and tname[0] == '$') or self.topGlobal(tname)) {
                // a global assigned NOWHERE is Ring's R24, naming it (probed
                // for add, insert and del); one assigned somewhere but unset
                // when this runs is the same error, from ggetw (c = 1: named)
                const gslot = self.knownGlobal(tname) orelse {
                    _ = try self.emit(.r24, 0, 0, 0, @intCast(try self.nameIndex(tname)));
                    return;
                };
                const lst = try self.tmp();
                _ = try self.emit(.ggetw, lst, 0, 1, gslot);
                const gval = try self.tmp();
                try self.expr(args.namedChild(1), gval);
                if (self.needsCopy(args.namedChild(1))) _ = try self.emit(.copyv, gval, 0, 0, 0);
                _ = try self.emit(.vpush, lst, gval, 1, CFN);
                _ = try self.emit(.loadi, lst, 1, 0, 0); // the borrow ends here
                return;
            }
            const l = self.lookup(tname) orelse return self.nope(target);
            const val = try self.tmp();
            try self.expr(args.namedChild(1), val);
            // `add(w, y)` appends a COPY of y on Ring (measured: y[1] = 11
            // afterwards left w[2][1] at 10).
            if (self.needsCopy(args.namedChild(1))) _ = try self.emit(.copyv, val, 0, 0, 0);
            // Conservatively boxed: the element may be a list.
            _ = try self.emit(.vpush, l.reg, val, 1, CFN);
            return;
        }

        // `isGlobal(:$name)` -- has that global been assigned yet?
        //
        // Softanza calls this exactly three times and always with a symbol
        // literal, so the SLOT is decided here and only the has-it-been-set
        // question is left to run time. A name that is no global anywhere
        // folds to 0, which is Ring's answer for a name it has never seen.
        if (std.ascii.eqlIgnoreCase(callee, "isglobal") and argc == 1) {
            var a = args.namedChild(0);
            if (std.mem.eql(u8, a.kind(), "symbol") and a.namedChildCount() > 0)
                a = a.namedChild(0);
            const nm = if (std.mem.eql(u8, a.kind(), "identifier") or
                std.mem.eql(u8, a.kind(), "string"))
                std.mem.trim(u8, a.text(), "\"':")
            else
                return self.nopeKind(n, "isGlobal needs a literal name");
            if (self.knownGlobal(nm)) |slot| {
                _ = try self.emit(.isglob, dst, 0, 0, slot);
            } else {
                _ = try self.emit(.loadi, dst, 0, 0, 0);
            }
            return;
        }

        // `classname(o)` -- Ring returns the class name, LOWERCASED
        // (verified: classname(new P) is "p"). Resolved at COMPILE time
        // from the receiver-class inference: where the class is proved,
        // the answer is a constant. Where it is not, this refuses rather
        // than plumbing a name table into the VM for a case that may not
        // arise -- and the census will say whether it does.
        if (std.ascii.eqlIgnoreCase(callee, "classname") and argc == 1) {
            // Proved receiver: the answer is a constant, so fold it. This
            // is the better code and stays the first choice.
            if (self.eval == null) if (self.recvClass(args.namedChild(0))) |cid| {
                _ = try self.emit(.loadk, dst, 0, 0, try self.classNameKonst(self.classes.items[cid].name));
                return;
            };
            // Not proved. This used to refuse, and the poison ranking
            // measured what that refusal cost: 60 functions failed here and
            // held 5,508 others unusable -- the largest single item in the
            // library by a factor of six. So the class is read at run time
            // from the object itself, which is where Ring reads it too.
            const save = self.temp;
            defer self.temp = save;
            const r = try self.tmp();
            try self.expr(args.namedChild(0), r);
            _ = try self.emit(.clsname, dst, r, 0, try self.konstIndex("\"Bad parameter type!\""));
            return;
        }

        // `del(aList, n)` MUTATES its first argument, so it needs the
        // container's own register rather than a copied value.
        // `insert(list, n, item)` mutates a PLACE, like del and add: a local,
        // an attribute or a global borrowed for writing.
        if (std.ascii.eqlIgnoreCase(callee, "insert") and argc == 3) {
            const tgt = args.namedChild(0);
            const save5 = self.temp;
            defer self.temp = save5;
            var lst: u8 = undefined;
            var borrowed = false;
            const is_place5 = std.mem.eql(u8, tgt.kind(), "identifier");
            const tn = if (is_place5) tgt.text() else "";
            if (!is_place5) {
                // A PLACE IS ANY EXPRESSION -- see the long note at the
                // indexed assignment. Not borrowed: `expr` retains, and
                // the frame sweep balances it.
                lst = try self.tmp();
                try self.expr(tgt, lst);
            } else if ((tn.len > 1 and tn[0] == '$') or self.topGlobal(tn)) {
                const gslot = self.knownGlobal(tn) orelse {
                    _ = try self.emit(.r24, 0, 0, 0, @intCast(try self.nameIndex(tn)));
                    return;
                };
                lst = try self.tmp();
                _ = try self.emit(.ggetw, lst, 0, 1, gslot);
                borrowed = true;
            } else if (tn.len > 1 and tn[0] == '@') {
                const slot = self.attrSlot(tn) orelse return self.nopeKind(tgt, "@attribute outside a class");
                lst = try self.tmp();
                _ = try self.emit(.gattrw, lst, 0, 0, @intCast(slot));
                borrowed = true;
            } else {
                const l = self.lookup(tn) orelse return self.nope(tgt);
                lst = l.reg;
            }
            const pr = try self.tmp();
            try self.expr(args.namedChild(1), pr);
            const vr = try self.tmp();
            try self.expr(args.namedChild(2), vr);
            if (self.needsCopy(args.namedChild(2))) _ = try self.emit(.copyv, vr, 0, 0, 0);
            _ = try self.emit(.vins, lst, pr, vr, 0);
            if (borrowed) _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex("\"\""));
            return;
        }
        if (std.ascii.eqlIgnoreCase(callee, "del") and argc == 2) {
            const tgt = args.namedChild(0);
            if (!std.mem.eql(u8, tgt.kind(), "identifier")) {
                // A PLACE IS ANY EXPRESSION -- see the long note at the
                // indexed assignment. `del( This.HashList(), n)` is the
                // estate's commonest refused call expression.
                const save6 = self.temp;
                defer self.temp = save6;
                const dl = try self.tmp();
                try self.expr(tgt, dl);
                const di = try self.tmp();
                try self.expr(args.namedChild(1), di);
                _ = try self.emit(.vdel, dl, di, 0, 0);
                _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex("\"\""));
                return;
            }
            // `del($g, n)` -- a GLOBAL, borrowed for writing like an append,
            // or copy-on-write clones it and the delete is thrown away.
            // This was the one refusal that poisoned the widget tree's
            // scripted-input reader, and with it the whole renderer.
            if ((tgt.text().len > 1 and tgt.text()[0] == '$') or self.topGlobal(tgt.text())) {
                const gslot = self.knownGlobal(tgt.text()) orelse {
                    _ = try self.emit(.r24, 0, 0, 0, @intCast(try self.nameIndex(tgt.text())));
                    return;
                };
                const save3 = self.temp;
                defer self.temp = save3;
                const lst = try self.tmp();
                _ = try self.emit(.ggetw, lst, 0, 1, gslot);
                const ir2 = try self.tmp();
                try self.expr(args.namedChild(1), ir2);
                _ = try self.emit(.vdel, lst, ir2, 0, 0);
                _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
                return;
            }
            // `del(@attr, n)` -- an ATTRIBUTE, borrowed for writing the way
            // an append borrows it. 58 of Softanza's 83 `identifier`
            // refusals on 2026-09-08 were this one shape: every Remove*,
            // Undo/Redo and cache-eviction method in the library. Probed on
            // 1.27: del on an attribute mutates it in place (len 3 -> 2).
            if (tgt.text().len > 1 and tgt.text()[0] == '@') {
                const slot = self.attrSlot(tgt.text()) orelse
                    return self.nopeKind(tgt, "@attribute outside a class");
                const save4 = self.temp;
                defer self.temp = save4;
                const lst = try self.tmp();
                _ = try self.emit(.gattrw, lst, 0, 0, @intCast(slot));
                const ir3 = try self.tmp();
                try self.expr(args.namedChild(1), ir3);
                _ = try self.emit(.vdel, lst, ir3, 0, 0);
                _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
                return;
            }
            const l = self.lookup(tgt.text()) orelse return self.nope(tgt);
            const save2 = self.temp;
            defer self.temp = save2;
            const ir = try self.tmp();
            try self.expr(args.namedChild(1), ir);
            _ = try self.emit(.vdel, l.reg, ir, 0, 0);
            _ = try self.emit(.loadk, dst, 0, 0, try self.konstIndex("\"\""));
            return;
        }

        // `raise(msg)` stops with the message. try/catch is a separate
        // item; until it lands this is the untried behaviour, which is
        // exactly what Ring does when nothing catches.
        if (std.ascii.eqlIgnoreCase(callee, "raise") and argc == 1) {
            const save2 = self.temp;
            defer self.temp = save2;
            const t = try self.tmp();
            try self.expr(args.namedChild(0), t);
            // the raise reports the CALL's line, after its argument: the
            // five-line `raise(` in stkProfiler is Line 37 on Ring -- the
            // closing paren -- not 33, where it starts
            self.atNode(n);
            // b = 1: this IS Ring's raise(), the one origin it prints.
            _ = try self.emit(.trap, t, 1, 0, 0);
            _ = try self.emit(.loadi, dst, 0, 0, 0);
            return;
        }

        // `substr` wears four signatures (§5.1). Reproduced exactly,
        // because 300K lines depend on it -- and where the role cannot be
        // decided at compile time, the VM decides it by ARGUMENT TYPE, as
        // Ring does. The checker rule for unreadable call sites is a
        // separate deliverable and does not change what runs.
        if (std.ascii.eqlIgnoreCase(callee, "substr") and argc >= 2 and argc <= 3) {
            const save2 = self.temp;
            defer self.temp = save2;
            const a0 = try self.tmp();
            try self.expr(args.namedChild(0), a0);
            const a1 = try self.tmp();
            try self.expr(args.namedChild(1), a1);
            if (argc == 2) {
                // find, or suffix -- decided by the second argument
                if (self.classOf(args.namedChild(1)) == .str) {
                    _ = try self.emit(.sfind, dst, a0, a1, 0);
                } else if (self.classOf(args.namedChild(1)) == .int) {
                    _ = try self.emit(.bcall, dst, a0, 2, @intFromEnum(vm.Builtin.substr2));
                } else {
                    // Unprovable at compile time -- and the two roles
                    // return different KINDS of thing, so guessing is out.
                    // Ring does not guess either: it decides by the
                    // ARGUMENT'S TYPE when the call runs, which is what
                    // `substr3` next door has always done. Refusing here
                    // cost 415 functions on 5 roots, the best
                    // effort-to-payoff item the poison ranking listed.
                    _ = try self.emit(.substr2d, dst, a0, a1, try self.konstIndex("\"Bad parameter type!\""));
                }
                return;
            }
            const a2 = try self.tmp();
            try self.expr(args.namedChild(2), a2);
            _ = try self.emit(.bcall, dst, a0, 3, @intFromEnum(vm.Builtin.substr3));
            return;
        }

        // ---- the general builtin table --------------------------------
        // Name -> id -> one `bcall`. Arity is checked here so a wrong call
        // is a refusal at compile time rather than a panic at run time.
        const table = builtin_table;
        // `ascii(s[i])` on a PROVEN string is the byte in one instruction --
        // the form F-39's bytescan row was designed around. `s[i]` alone is
        // Ring's one-character string (C-3); only this exact shape keeps the
        // byte opcode, so the benchmark keeps its advantage and nothing
        // else pays for it.
        if (std.ascii.eqlIgnoreCase(callee, "ascii") and argc == 1) {
            const a0 = args.namedChild(0);
            if (std.mem.eql(u8, a0.kind(), "subscript_expression") and a0.namedChildCount() == 2 and
                self.classOf(a0.namedChild(0)) == .str)
            {
                const save2 = self.temp;
                defer self.temp = save2;
                const sb = try self.borrowOperand(a0.namedChild(0), dst);
                const si = if (try self.operandReg(a0.namedChild(1))) |r| r else blk: {
                    const t = try self.tmp();
                    try self.expr(a0.namedChild(1), t);
                    break :blk t;
                };
                _ = try self.emit(.sgetb, dst, sb, si, 0);
                return;
            }
        }
        var name_seen = false;
        for (table) |bi| {
            if (!std.ascii.eqlIgnoreCase(callee, bi.name)) continue;
            // one name can carry two arities (find, sort); a name with
            // no matching arity is refused after the loop
            if (argc != bi.argc) {
                name_seen = true;
                continue;
            }
            const save2 = self.temp;
            defer self.temp = save2;
            // Arguments land in consecutive registers, as the opcode expects.
            const abase = self.temp;
            var ai2: u32 = 0;
            while (ai2 < argc) : (ai2 += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(ai2), r);
            }
            self.atNode(n);
            _ = try self.emit(.bcall, dst, abase, @intCast(argc), @intFromEnum(bi.id));
            return;
        }
        if (name_seen) return self.nopeKind(n, "a builtin called with the wrong number of arguments");

        // ---- object-model builtins ------------------------------------
        if (std.ascii.eqlIgnoreCase(callee, "StzRaise") and argc == 1) {
            // The message is EVALUATED. The constant form this replaces
            // could only carry a string literal, so every computed
            // message -- which is most of Softanza's -- became the word
            // "raised".
            const save2 = self.temp;
            defer self.temp = save2;
            const t = try self.tmp();
            try self.expr(args.namedChild(0), t);
            // b = 1: raise() again, by its other path.
            _ = try self.emit(.trap, t, 1, 0, 0);
            return;
        }
        if (std.ascii.eqlIgnoreCase(callee, "isString") or
            std.ascii.eqlIgnoreCase(callee, "isObject") or
            std.ascii.eqlIgnoreCase(callee, "isNumber") or
            std.ascii.eqlIgnoreCase(callee, "isList"))
        {
            const want_tag: i32 = if (std.ascii.eqlIgnoreCase(callee, "isString"))
                @intFromEnum(vm.Tag.str)
            else if (std.ascii.eqlIgnoreCase(callee, "isObject"))
                @intFromEnum(vm.Tag.obj)
            else if (std.ascii.eqlIgnoreCase(callee, "isList"))
                @intFromEnum(vm.Tag.vec)
            else
                @intFromEnum(vm.Tag.int);
            const save2 = self.temp;
            defer self.temp = save2;
            const t = try self.tmp();
            try self.expr(args.namedChild(0), t);
            _ = try self.emit(.istag, dst, t, 0, want_tag);
            return;
        }

        // ---- user functions -------------------------------------------
        if (self.findFunc(callee)) |f| return self.userCall(n, f, args, argc, dst);

        // A name this unit does not define. Ring resolves such names at
        // RUNTIME -- an engine registers them through LoadLib -- so this
        // compiles to a native call rather than refusing, which is what
        // Ring does and what 300K lines assume.
        //
        // It is counted SEPARATELY. Emitting a call to a name nobody has
        // defined is not the same achievement as compiling a statement,
        // and reporting the two together would inflate the census with
        // every typo in the library. §2.6's compile-time answer is the
        // checker listing these before the program runs; the compiler's
        // job here is only to keep Ring's semantics.
        if (argc > 16) return self.nope(n);
        // eval mode: a native the program mentions is a native; a name it
        // never mentions has no index and goes through the string call,
        // where the VM raises Ring's R3 with the name when the line runs
        if (self.eval != null) {
            _ = self.nameIndex(callee) catch |e| {
                if (e != Error.Unsupported) return e;
                self.fail_kind = "";
                self.fail_text = "";
                return self.evalStringCall(n, callee, args, argc, dst);
            };
        }
        // RING LOOKS THE NAME UP WHEN THE CALL STARTS (F-87): an unknown
        // one is R3 before any argument is evaluated, reported on the
        // callee's line. `nchk` there; the call itself at the END, where an
        // error raised INSIDE a native is reported (`left(5,` NL `2)` is
        // the closing line on Ring).
        const ni2 = try self.nameIndex(callee);
        try self.natives.append(self.alloc, ni2);
        self.stmts_native += 1;
        self.atNodeStart(n);
        _ = try self.emit(.nchk, 0, 0, 0, ni2);
        const save3 = self.temp;
        defer self.temp = save3;
        const abase = self.temp;
        var na: u32 = 0;
        while (na < argc) : (na += 1) {
            const r = try self.tmp();
            try self.expr(args.namedChild(na), r);
        }
        self.atNode(n);
        _ = try self.emit(.ncall, dst, abase, @intCast(argc), ni2);
    }

    /// A direct call to a Ring-level function.
    fn userCall(self: *Compiler, n: ts.Node, f: *Func, args: ts.Node, argc: u32, dst: u8) Error!void {
        // `n` is the call expression: its START is the row the call frame
        // reports (atNodeStart, before the emit below).
        if (argc != f.params.len) {
            // RING CHECKS ARGUMENT COUNT AT RUN TIME, NOT COMPILE TIME.
            // Measured on 1.27: a file containing a bad call compiles and
            // runs, an unexecuted bad call costs nothing at all, and an
            // executed one raises R19 (too few) or R20 (too many), both
            // catchable with those exact texts.
            //
            // Refusing here was STRICTER THAN RING, and the poison ranking
            // priced that strictness: one bad call in a branch nothing
            // takes -- `HasKey(x)` in stzRegexMaker against a global that
            // wants two arguments -- held 19,018 functions unusable. A
            // refusal is the safe answer only when the alternative is a
            // wrong one; here the alternative is Ring's own answer.
            const save2 = self.temp;
            defer self.temp = save2;
            // The arguments still evaluate: Ring pushes them before it
            // counts them, so their side effects happen either way.
            var k: u32 = 0;
            while (k < argc) : (k += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(k), r);
            }
            const er = try self.tmp();
            const msg = if (argc < f.params.len)
                "\"Error (R19) : Calling function with less number of parameters\""
            else
                "\"Error (R20) : Calling function with extra number of parameters\"";
            _ = try self.emit(.loadk, er, 0, 0, try self.konstIndex(msg));
            _ = try self.emit(.trap, er, 0, 0, 0);
            return;
        }
        const save = self.temp;
        defer self.temp = save;
        // The window must sit above everything live.
        const win = self.temp;
        var i: u32 = 0;
        while (i < argc) : (i += 1) {
            const r = try self.tmp();
            try self.expr(args.namedChild(i), r);
        }
        _ = self.reg(win);
        self.atNodeStart(n);
        const site = try self.emit(.call, win, 0, 0, 0);
        try self.fixups.append(self.alloc, .{
            .site = site,
            .fidx = self.funcIndex(f),
            .from = self.funcIndex(self.cur),
        });
        _ = try self.emit(.move, dst, win, if (f.ret.boxed()) 1 else 0, 0);
    }

    /// A global's slot if the top level declared one, else null.
    /// A bare name at the TOP LEVEL is a global -- Ring's rule, kept.
    /// Rule A's hazard was a function reaching a caller's variable by
    /// writing a bare name; that stays impossible: inside a function a bare
    /// name is a local and nothing else. At the top level there is no
    /// caller to reach, and `o = new stzList(...)` in a test file is the
    /// most ordinary Ring there is -- every one of Softanza's 5,121 test
    /// files begins that way. Decided 2026-09-09 for the first end-to-end
    /// run; the verdict entry is C-2 in docs/CORRECTIONS.md. A top-level
    /// name that is already a local of main (a `for` variable) stays one.
    fn topGlobal(self: *Compiler, name: []const u8) bool {
        if (name.len == 0) return false;
        if (name[0] == '$' or name[0] == '@' or name[0] == ':') return false;
        if (self.cur.is_main) return self.lookup(name) == null;
        // C-14: A TOP-LEVEL LAMBDA'S BARE NAME IS THE TOP LEVEL'S GLOBAL --
        // for the WRITE as for the read (2026-09-22): the lambda's names
        // are its defining scope's names, and at the top level those are
        // globals. Every write site asks here -- `cWhy = "" + e`,
        // `nFires++`, `aSeen + x`, `add(aSeen, x)` -- so the one answer
        // covers them all. A parameter or a capture of the lambda is the
        // lambda's own, and a name the top level never assigns is a local
        // of the lambda, as a named function's would be (C-2).
        if (self.cur.lambda_at != null and self.lambdaOfMain()) {
            return self.lookup(name) == null and !self.isCapture(name) and self.knownGlobal(name) != null;
        }
        return false;
    }

    fn knownGlobal(self: *Compiler, name: []const u8) ?i32 {
        for (self.globals.items, 0..) |g, i| {
            scans[0] += 1;
            if (std.ascii.eqlIgnoreCase(g, name)) return @intCast(i);
        }
        return null;
    }

    /// The slot for a top-level name, created on first sight.
    /// Case-insensitive, because Ring folds identifier case (§2.5).
    fn globalSlot(self: *Compiler, name: []const u8) !i32 {
        sizes[0] = self.globals.items.len;
        for (self.globals.items, 0..) |g, i| {
            scans[1] += 1;
            if (std.ascii.eqlIgnoreCase(g, name)) return @intCast(i);
        }
        // eval mode: the VM's global table is fixed; a new top-level name
        // needs the literal-prefix declaration (predeclareEval)
        if (self.eval != null) {
            self.fail_text = name;
            self.fail_kind = "eval: a new global";
            return Error.Unsupported;
        }
        try self.globals.append(self.alloc, name);
        return @intCast(self.globals.items.len - 1);
    }

    /// A lower-cased copy in the compiler's arena: the key both indexes
    /// are built on. Lookups fold into a stack buffer instead and only an
    /// INSERT pays for a copy.
    fn foldKey(self: *Compiler, name: []const u8) ![]const u8 {
        const k = try self.alloc.alloc(u8, name.len);
        for (name, 0..) |ch, i| k[i] = std.ascii.toLower(ch);
        return k;
    }

    pub fn nameIndexPub(self: *Compiler, name: []const u8) !u16 {
        return self.nameIndex(name);
    }

    fn nameIndex(self: *Compiler, name: []const u8) !u16 {
        scans[2] += 1;
        sizes[1] = self.names.items.len;
        var buf: [256]u8 = undefined;
        const key = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else try self.foldKey(name);
        if (self.name_index.get(key)) |i| return i;
        // eval mode: the VM's table cannot grow; a name the program never
        // mentions cannot be dispatched on, and says so
        if (self.names_frozen) {
            self.fail_text = name;
            self.fail_kind = "eval: a name the program never mentions";
            return Error.Unsupported;
        }
        try self.names.append(self.alloc, name);
        const idx: u16 = @intCast(self.names.items.len - 1);
        try self.name_index.put(self.alloc, try self.foldKey(name), idx);
        return idx;
    }

    /// Which constants `konstIndex` has in its map -- one flag per entry, so
    /// a PREFIX can restore the map EXACTLY as it was.
    ///
    /// Not every constant is in it. `konstSymbol` appends `:name` after a
    /// linear scan of its own and never touches the map, and `konstNum`
    /// appends numbers. Indexing everything on the way back in therefore
    /// builds a map the original compiler never had: `konstIndex("stzapp")`
    /// would find the SYMBOL `:stzapp` and hand back its entry instead of
    /// appending the string constant it was asked for. Twenty-five class-name
    /// constants went missing that way, which is how this was found.
    pub fn konstIndexed(self: *Compiler, alloc: std.mem.Allocator) ![]u8 {
        const out = try alloc.alloc(u8, self.konst.items.len);
        @memset(out, 0);
        for (self.konst.items, 0..) |v, i| {
            if (v.tag != .str) continue;
            if (self.konst_index.get(v.p.s.ptr[0..v.p.s.len])) |ix| {
                if (ix == @as(i32, @intCast(i))) out[i] = 1;
            }
        }
        return out;
    }

    /// Rebuild the two lookup indexes from the tables they index.
    ///
    /// `names` and `konst` come back from a PREFIX as plain arrays, and both
    /// lookups are map-backed: without this, `nameIndex` would not find a
    /// name the library already has and would append a SECOND entry for it --
    /// which silently changes what `dispatch[class * n_names + name]` means.
    /// The keys are derived here, beside the code that derives them on
    /// insert, so the two cannot drift apart.
    ///
    /// `names` is exact because `nameIndex` is the only thing that appends to
    /// it. `konst` is not, so it takes the flags recorded at save time.
    pub fn reindex(self: *Compiler, konst_flags: []const u8) !void {
        self.name_index.clearRetainingCapacity();
        for (self.names.items, 0..) |n, i| {
            try self.name_index.put(self.alloc, try self.foldKey(n), @intCast(i));
        }
        self.konst_index.clearRetainingCapacity();
        for (self.konst.items, 0..) |v, i| {
            if (v.tag != .str) continue;
            if (i >= konst_flags.len or konst_flags[i] == 0) continue;
            try self.konst_index.put(self.alloc, v.p.s.ptr[0..v.p.s.len], @intCast(i));
        }
    }

    fn findClass(self: *Compiler, name: []const u8) ?*ClassInfo {
        for (self.classes.items) |*c| {
            scans[3] += 1;
            if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        }
        return null;
    }

    /// The slot an `@name` refers to inside the class being compiled.
    /// The slot of `name` on the class being compiled or any ancestor --
    /// slots are inherited, so the index is the same wherever declared.
    /// `self` INSIDE A BRACE IS THE BRACE OBJECT, while `This` stays the
    /// method's (F-124): in `new Pt { ? classname(This), classname(self) }`
    /// inside a method of Host, Ring prints host and pt.
    fn selfIsBrace(self: *Compiler, n: ts.Node) ?u8 {
        if (self.braces.items.len == 0) return null;
        if (!std.ascii.eqlIgnoreCase(n.text(), "self")) return null;
        return self.braces.items[self.braces.items.len - 1].reg;
    }

    fn declaredAttr(self: *Compiler, name: []const u8) ?u32 {
        if (name.len == 0 or name[0] == '@' or name[0] == '$' or name[0] == ':') return null;
        // EVAL: the class table is the VM's, read through evalHasAttr; this
        // compiler's own is empty, and `self.cur.owner` is the CALLER'S
        // class id -- indexing an empty list with it was the fault behind
        // twelve wide-clock rows on 2026-09-25 (on the prefix path, where
        // the caller's locals were absent and evalAssign fell through here).
        if (self.eval != null) return null;
        var probe: ?u16 = self.cur.owner;
        while (probe) |pid| {
            if (self.attrSlotOf(pid, name)) |slot| return slot;
            probe = self.classes.items[pid].parent;
        }
        return null;
    }

    fn attrSlot(self: *Compiler, name: []const u8) ?u32 {
        if (self.eval != null) return null; // see declaredAttr
        const ci = self.cur.owner orelse return null;
        return self.attrSlotOf(ci, name);
    }

    /// The same lookup for a class the receiver was PROVED to hold. Own
    /// attributes only, exactly as the This-only version searched: an
    /// inherited attribute refuses here as it refuses there, so this adds
    /// a receiver and changes no rule.
    fn attrSlotOf(self: *Compiler, cid: u16, name: []const u8) ?u32 {
        for (self.classes.items[cid].attrs.items) |a| {
            scans[6] += 1;
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.slot;
        }
        return null;
    }

    /// `:Symbol` is a STRING, lower-cased. Verified on Ring 1.27:
    /// `type(:Mixed_Case)` is STRING and its value is `mixed_case`, so
    /// `aH[:name]` and `aH["name"]` are the same lookup. 25,121 sites in
    /// Softanza -- the single most-used construct the front end lacked.
    fn konstSymbol(self: *Compiler, raw: []const u8) Error!i32 {
        var t = raw;
        if (t.len > 0 and t[0] == ':') t = t[1..];
        // `: word` is the symbol "word" on Ring: every space and tab between the colon and the word goes (the analysis's 2.14
        // hazard, kept); Ring++ kept them, so `x = : word` was " word" (bench/exec/colon_space.ring, 2026-10-15)
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
        const buf = self.alloc.alloc(u8, t.len) catch return Error.OutOfMemory;
        for (t, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const kb: i32 = if (self.eval) |ev| ev.konst_base else 0;
        for (self.konst.items, 0..) |k, i| {
            if (k.tag == .str and std.mem.eql(u8, k.p.s.ptr[0..k.p.s.len], buf)) return @as(i32, @intCast(i)) + kb;
        }
        const sp = (if (self.eval != null) self.scratch else self.alloc).create(vm.Str) catch return Error.OutOfMemory;
        sp.* = .{ .ptr = buf.ptr, .len = @intCast(buf.len), .rc = 1 };
        self.konst.append(self.alloc, vm.Value.str(sp)) catch return Error.OutOfMemory;
        return @as(i32, @intCast(self.konst.items.len - 1)) + kb;
    }

    /// A numeric constant. Ring has exactly one number type and it is a
    /// double, so this is where every decimal literal lands.
    fn konstNum(self: *Compiler, d: f64) Error!i32 {
        const kb: i32 = if (self.eval) |ev| ev.konst_base else 0;
        for (self.konst.items, 0..) |k, i| {
            if (k.tag == .num and k.p.d == d) return @as(i32, @intCast(i)) + kb;
        }
        self.konst.append(self.alloc, vm.Value.num(d)) catch return Error.OutOfMemory;
        return @as(i32, @intCast(self.konst.items.len - 1)) + kb;
    }

    /// A string constant, deduplicated. Ring escapes are not handled yet;
    /// the literals in the target module have none.
    fn konstIndex(self: *Compiler, raw: []const u8) !i32 {
        var t = raw;
        if (t.len >= 2 and (t[0] == '"' or t[0] == '\'' or t[0] == '`')) t = t[1 .. t.len - 1];
        sizes[3] = self.konst.items.len;
        scans[7] += 1;
        // eval mode: the eval's constants follow the VM's table, so an
        // index is offset by what the table held; the headers come from the
        // scratch arena, since the hook copies the bytes out before it runs
        const kb: i32 = if (self.eval) |ev| ev.konst_base else 0;
        if (self.konst_index.get(t)) |i| return i + kb;
        const sp = try (if (self.eval != null) self.scratch else self.alloc).create(vm.Str);
        sp.* = .{ .ptr = t.ptr, .len = @intCast(t.len), .rc = 1 };
        try self.konst.append(self.alloc, vm.Value.str(sp));
        const idx: i32 = @intCast(self.konst.items.len - 1);
        // Keyed by the STORED bytes: `t` points into a parse tree, and the
        // entry outlives any one node's text. The map holds the LOCAL
        // index; the base is added on the way out, both paths alike.
        try self.konst_index.put(self.alloc, sp.ptr[0..sp.len], idx);
        return idx + kb;
    }

    /// A class's name as Ring's `classname` reports it: LOWERCASED
    /// (verified on 1.27 -- `classname(new Point)` is "point"), and as a
    /// deduplicated string constant.
    ///
    /// The buffer is heap-allocated because `konstIndex` keeps the POINTER
    /// rather than copying the bytes. A stack array here is the bug that
    /// once made `ascii(tab)` return 13.
    fn classNameKonst(self: *Compiler, nm: []const u8) !i32 {
        const buf = self.alloc.alloc(u8, nm.len + 2) catch return Error.OutOfMemory;
        buf[0] = '"';
        for (nm, 0..) |ch, i| buf[i + 1] = std.ascii.toLower(ch);
        buf[nm.len + 1] = '"';
        return self.konstIndex(buf);
    }

    /// `f` points into `funcs.items`, so its index is arithmetic (2.25
    /// billion pointer comparisons before). A pointer from outside the
    /// buffer -- which the old scan would have reached `unreachable` on --
    /// takes the scan and its verdict.
    fn funcIndex(self: *Compiler, f: *Func) u32 {
        scans[4] += 1;
        const base = @intFromPtr(self.funcs.items.ptr);
        const at = @intFromPtr(f);
        const end = base + self.funcs.items.len * @sizeOf(Func);
        if (at >= base and at < end) return @intCast((at - base) / @sizeOf(Func));
        for (self.funcs.items, 0..) |*g, i| {
            if (g == f) return @intCast(i);
        }
        unreachable;
    }

    /// A bare variable can BE the operand register; nothing needs copying
    /// into a temporary first. Every avoided copy is one fewer `move` in a
    /// loop body, and 108 of the first 346 instructions emitted were moves.
    /// Every caller asks at the point the operand is EVALUATED, so the R24
    /// check of a local not proven assigned (F-89) is emitted here, where
    /// the read is. It used to fall back to expr() instead, and that took
    /// a temporary and passed C-11's loop-variable refusal, which this
    /// path never has: `"j=" + j` after an inner loop was refused.
    fn operandReg(self: *Compiler, n: ts.Node) Error!?u8 {
        if (std.mem.eql(u8, n.kind(), "identifier")) {
            if (self.lookup(n.text())) |l| {
                try self.daRead(l, n.text());
                return l.reg;
            }
        }
        return null;
    }

    /// A plain LOCAL read in place, for an operand an opcode only READS -- a subscript's index. `expr` would copy
    /// it into a temporary with a `move`, and every such copy is an unboxed store that pays F-118's release check:
    /// two or three per inner iteration of every kernel but fib (2026-10-15). The same name resolution as `expr`'s
    /// identifier path, in its order, so it answers null wherever that path would do anything but `move dst, l.reg`
    /// -- a character constant, `cCatchError`, a sigil, a top-level global, `This`, a loop variable after its loop
    /// (C-11's refusal stays expr's), eval code -- and the caller takes a temporary as before.
    fn localOperand(self: *Compiler, n: ts.Node, unboxed_only: bool) Error!?u8 {
        if (!std.mem.eql(u8, n.kind(), "identifier") or self.eval != null) return null;
        const nm = n.text();
        if (nm.len == 0 or nm[0] == '@' or nm[0] == '$') return null;
        if (std.ascii.eqlIgnoreCase(nm, "cCatchError") or std.ascii.eqlIgnoreCase(nm, "this") or
            std.ascii.eqlIgnoreCase(nm, "self")) return null;
        if (self.topGlobal(nm) and self.knownGlobal(nm) != null) return null;
        if (self.wasLoopVar(nm)) return null;
        const l = self.lookup(nm) orelse return null;
        if (unboxed_only and l.class.boxed()) return null;
        try self.daRead(l, nm);
        return l.reg;
    }

    /// Can evaluating `n` change a local of this function? An increment can, an eval can (it runs in this frame),
    /// and a brace body is statements. A call cannot: a callee has its own frame and a lambda copies what it
    /// captures. Read before an indexed assignment hands the index's own register to `vset` -- the index is read
    /// AFTER the right-hand side, so a right-hand side that moved it would change which element is written.
    fn mayWriteLocal(n: ts.Node) bool {
        const k = n.kind();
        if (std.mem.eql(u8, k, "postfix_expression") or std.mem.eql(u8, k, "brace_expression") or
            std.mem.eql(u8, k, "new_expression")) return true;
        if (std.mem.eql(u8, k, "identifier") and std.ascii.eqlIgnoreCase(n.text(), "eval")) return true;
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) if (mayWriteLocal(n.child(i))) return true;
        return false;
    }

    /// A subscript's index: the local's own register when `localOperand` allows it, else a temporary.
    fn indexReg(self: *Compiler, n: ts.Node) Error!u8 {
        if (try self.localOperand(n, false)) |r| return r;
        const t = try self.tmp();
        try self.expr(n, t);
        return t;
    }

    /// A small integer literal, for the immediate forms of the arithmetic
    /// opcodes -- the same shape Lua's compiler emits (ADDK/MULK/MODK).
    fn immOf(n: ts.Node) ?i32 {
        if (!std.mem.eql(u8, n.kind(), "number")) return null;
        const v = intLit(n) catch return null;
        if (v > std.math.maxInt(i32) or v < std.math.minInt(i32)) return null;
        return @intCast(v);
    }

    /// Read a container WITHOUT taking a reference to it.
    ///
    /// Copying `aFlag` into a temporary just to index it makes rc == 2, so
    /// the next `aFlag[j] = 1` finds the list shared and copy-on-write clones
    /// it -- 300,000 elements, on every write. Measured: sieve ran 25x slower
    /// than the same algorithm in hand-written bytecode until reads stopped
    /// doing this.
    ///
    /// A read is a BORROW. When the base is a plain variable its own register
    /// is handed to the opcode directly, so no count changes and nothing is
    /// ever spuriously shared.
    /// Does a value read from `n` need Ring's copy before it is STORED?
    /// Yes when it comes out of a place -- a variable, an attribute, an
    /// element -- and may be a list or an object. A fresh value (a call
    /// result, a literal, arithmetic) is nobody else's and is stored as
    /// is; a proved scalar or string never needs one. The opcode itself
    /// is a tag test on anything else, so a wrong "yes" costs one test.
    /// The right-hand side of an ASSIGNMENT, where Ring's copy happens.
    ///
    /// `This` is a value like any other there, and Ring copies it: measured
    /// on 1.27, `mine = This` then `o.mine.mine` is NOT an object, because
    /// the copy was taken of the object as it stood. The grammar gives
    /// `This` its own node kinds, so `needsCopy` -- which named three --
    /// let `_These_ = This` store a REFERENCE. The object then held itself,
    /// and every later copy of it walked that cycle until the native stack
    /// ran out: 34 of the wide clock's 432 died there, saying nothing.
    ///
    /// It is separate from `needsCopy` because the RETURN site must NOT do
    /// this. Copying at the return is too early -- `p.Begin() { ... }`
    /// hands the brace a copy, its hooks fire on that, and `p` never sees
    /// them. Ring copies when the result is ASSIGNED, and bench/exec/
    /// brace_hooks.ring is what said so.
    fn needsCopyAssign(self: *Compiler, n: ts.Node) bool {
        const k = n.kind();
        if (std.mem.eql(u8, k, "self") or std.mem.eql(u8, k, "this")) return true;
        // A CALL'S RESULT copies at the assignment too: `x = P()` where P
        // returns a global, or `r = o.GetL()` where GetL returns an
        // attribute, gives x and r their own copy on Ring. The return
        // itself no longer copies (see return_statement), so this is the
        // one place that keeps `x = P(); x.Bump()` off the original. A
        // FRESH result -- a list the function built -- is not cloned: the
        // copyv opcode skips a value nothing else holds, so this costs
        // nothing where there is nothing to protect.
        if (std.mem.eql(u8, k, "call_expression")) {
            // `y = ref(x)` is Ring's way to NOT copy: y and x are one list
            // after it (measured, bench/exec/reflect.ring). The builtin is
            // the identity; the whole of it is this exemption.
            if (n.namedChildCount() > 0) {
                const cn = n.namedChild(0);
                if (std.mem.eql(u8, cn.kind(), "identifier") and
                    (std.ascii.eqlIgnoreCase(cn.text(), "ref") or std.ascii.eqlIgnoreCase(cn.text(), "reference")) and
                    self.findFunc(cn.text()) == null) return false;
            }
            return switch (self.classOf(n)) {
                .int, .str => false,
                else => true,
            };
        }
        // A BINARY RESULT copies too: `x = aL + 2` appends to aL in place
        // and gives x its own copy on Ring (F-68: aL stays 2 items after
        // add(x, 3)); and an object's `operator` answering `This` gives
        // `p = o + 1` a copy of o (F-69). A fresh string or number is not
        // a copy, and copyv skips a value nothing else holds.
        if (std.mem.eql(u8, k, "binary_expression")) {
            return switch (self.classOf(n)) {
                .int, .str => false,
                else => true,
            };
        }
        return self.needsCopy(n);
    }

    fn needsCopy(self: *Compiler, n: ts.Node) bool {
        const k = n.kind();
        if (!(std.mem.eql(u8, k, "identifier") or std.mem.eql(u8, k, "member_expression") or
            std.mem.eql(u8, k, "subscript_expression"))) return false;
        return switch (self.classOf(n)) {
            .int, .str => false,
            else => true,
        };
    }

    fn borrowBase(self: *Compiler, n: ts.Node) Error!u8 {
        if (std.mem.eql(u8, n.kind(), "identifier")) {
            if (self.lookup(n.text())) |l| {
                try self.daRead(l, n.text());
                return l.reg;
            }
        }
        const t = try self.tmp();
        try self.expr(n, t);
        return t;
    }

    /// The class of an expression, in the function being compiled.
    fn classOf(self: *Compiler, n: ts.Node) Class {
        return exprClass(self, self.cur, n);
    }

    /// For a container expression, the class of what comes OUT of it.
    fn elemOf(self: *Compiler, n: ts.Node) Class {
        if (std.mem.eql(u8, n.kind(), "identifier")) {
            if (self.lookup(n.text())) |l| return l.elem;
        }
        return .unknown;
    }

    /// `new C(args)` -- allocate, then run `init` on it if the class has
    /// one. The object stays in its own register because `init`'s return
    /// value lands on the call window and would otherwise overwrite it.
    /// `obj { ... }`, as Ring 1.27 does it -- measured 2026-09-10 on both
    /// builds, gated by bench/exec/brace.ring:
    ///   the value of the expression is the object;
    ///   inside the block a name is a local first, then the object's
    ///     attribute, then a global; `@x` is the object's attribute;
    ///   a bare call is the object's method first, ahead of a global
    ///     function of that name;
    ///   blocks nest, and `o { } { }` runs both on the same object;
    ///   `This` and `self` are NOT the object (R13 at the top level).
    /// The grammar hands `q = o.Q() { ... }` as a brace_expression whose
    /// receiver is the whole assignment: Ring assigns, then enters the
    /// block on the value, and so does this. Softanza's app tests are
    /// written entirely in this form (`oApp { AddThingQ(:Note) { ... } }`).
    fn braceExpr(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        const prim = n.namedChild(0);
        const save = self.temp;
        defer self.temp = save;
        const objr = try self.tmp();
        var cid: ?u16 = null;
        if (std.mem.eql(u8, prim.kind(), "assignment_expression")) {
            try self.assign(prim);
            try self.expr(prim.namedChild(0), objr);
            cid = self.recvClass(prim.namedChild(0));
        } else {
            try self.expr(prim, objr);
            cid = self.recvClass(prim);
        }
        try self.braceBlock(objr, cid, n, 1);
        _ = try self.emit(.move, dst, objr, 1, 0);
    }

    /// The block itself: statements `from` onward of `holder`, compiled
    /// with the object in `objr`, which `floor` keeps out of every
    /// statement's temporaries -- the same pinning a numeric `for` uses.
    fn braceBlock(self: *Compiler, objr: u8, cid: ?u16, holder: ts.Node, from: u32) Error!void {
        const saved_floor = self.floor;
        defer self.floor = saved_floor;
        self.floor = @max(self.floor, objr + 1);
        try self.braces.append(self.alloc, .{ .reg = objr, .cid = cid });
        defer _ = self.braces.pop();
        try self.braceHook(objr, "bracestart");
        var i: u32 = from;
        while (i < holder.namedChildCount()) : (i += 1) try self.stmt(holder.namedChild(i));
        try self.braceHook(objr, "braceend");
    }

    /// Ring calls two hooks on an object brace, and its parser writes the
    /// guard out in a comment: `if ismethod(self,"bracestart")
    /// bracestart() ok` on `{`, the same for `braceend` on `}`
    /// (src/expr.c:1021 and 1033). Measured on the oracle: nested braces
    /// give [start][start][end][end], and a class with no hook is
    /// untouched.
    ///
    /// Softanza builds on this -- stzApp gathers `Graph = ...` inside the
    /// brace and folds it when the brace closes. Without the hook the fold
    /// never ran and app/02_stzapp_body failed 7 of 12 assertions while
    /// printing MORE lines than Ring, two per failure.
    ///
    /// The call is emitted unconditionally and MAY MISS at run time, as
    /// Ring's does: the receiver's class is not always known here, and
    /// `ismethod` is a runtime question on Ring too.
    fn braceHook(self: *Compiler, objr: u8, name: []const u8) Error!void {
        const save = self.temp;
        defer self.temp = save;
        const w = try self.tmp();
        _ = try self.emit(.move, w, objr, 1, 0);
        _ = try self.emit(.callmq, w, 0, 0, @intCast(try self.nameIndex(name)));
    }

    /// RING'S GETTERS AND SETTERS (F-73). Which rule a dot access carries to
    /// the VM in the `c` of gattrn/sattrn: inside a method the object may
    /// be `This` itself, which never goes through its accessor; anywhere
    /// else every object does.
    fn accMode(self: *Compiler) u8 {
        return if (self.cur.owner != null) vm.ACC_NOT_THIS else vm.ACC_CHECK;
    }
    /// ...and a brace: inside a method, an object of the method's own
    /// class reads its slots (Ring's callmethodinsideclass).
    fn accModeBrace(self: *Compiler) u8 {
        return if (self.cur.owner != null) vm.ACC_BRACE else vm.ACC_CHECK;
    }
    /// Does class `cid` (or a parent) define `get<nm>` (get) or `set<nm>`?
    /// A proved receiver whose class has one cannot use the slot directly:
    /// it takes the by-name path, where the VM applies the whole rule.
    fn hasAccessor(self: *Compiler, cid: u16, nm: []const u8, get: bool) bool {
        var buf: [260]u8 = undefined;
        if (nm.len + 3 > buf.len) return false;
        @memcpy(buf[0..3], if (get) "get" else "set");
        @memcpy(buf[3 .. 3 + nm.len], nm);
        return self.methodOf(cid, buf[0 .. 3 + nm.len]) != null;
    }

    /// The slot of `nm` on class `cid` or any ancestor -- slots are
    /// inherited, so the index is the same wherever it was declared.
    fn braceAttrSlot(self: *Compiler, cid: u16, nm: []const u8) ?u32 {
        if (self.eval != null) return null; // see declaredAttr
        var probe: ?u16 = cid;
        while (probe) |pid| {
            if (self.attrSlotOf(pid, nm)) |slot| return slot;
            probe = self.classes.items[pid].parent;
        }
        return null;
    }

    /// A name inside the block read as the object's attribute. True when
    /// handled. A proved class that has no such attribute anywhere in
    /// its chain answers FALSE, and the caller goes on to Ring's next
    /// rule (a global) -- measured: `o { p = new K }` made a global p.
    /// An unproved receiver is asked by name at run time, and `@x` is
    /// always an attribute (Rule A), by name when not declared.
    fn braceAttrRead(self: *Compiler, nm: []const u8, dst: u8) Error!bool {
        const b = self.braces.items[self.braces.items.len - 1];
        if (b.cid) |cid| {
            if (self.braceAttrSlot(cid, nm)) |slot| {
                if (!self.hasAccessor(cid, nm, true)) {
                    _ = try self.emit(.gattr, dst, b.reg, 0, @intCast(slot));
                    return true;
                }
            } else if (nm[0] != '@') return false;
        }
        _ = try self.emit(.gattrn, dst, b.reg, self.accModeBrace(), try self.nameIndex(nm));
        return true;
    }

    /// The same, written -- plain `=` or a compound form. Same answer.
    fn braceAttrWrite(self: *Compiler, nm: []const u8, op: []const u8, rhs: ts.Node, n: ts.Node) Error!bool {
        const b = self.braces.items[self.braces.items.len - 1];
        var slot: ?u32 = null;
        // the proved slot is used only for a read or write no accessor can
        // intercept; either side having one sends both through the name
        var rslot: ?u32 = null;
        if (b.cid) |cid| {
            slot = self.braceAttrSlot(cid, nm);
            if (slot == null and nm[0] != '@') return false;
            rslot = slot;
            if (slot != null and self.hasAccessor(cid, nm, false)) slot = null;
            if (rslot != null and self.hasAccessor(cid, nm, true)) rslot = null;
        }
        const mode = self.accModeBrace();
        const ni = try self.nameIndex(nm);
        const save = self.temp;
        defer self.temp = save;
        const t = try self.tmp();
        if (std.mem.eql(u8, op, "=")) {
            try self.expr(rhs, t);
            if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
        } else {
            const cur2 = try self.tmp();
            if (rslot) |sl| {
                _ = try self.emit(.gattr, cur2, b.reg, 0, @intCast(sl));
            } else {
                _ = try self.emit(.gattrn, cur2, b.reg, mode, ni);
            }
            try self.expr(rhs, t);
            const o: vm.Op = compoundOp(op) orelse return self.nope(n);
            _ = try self.emit(o, t, cur2, t, 1);
        }
        if (slot) |sl| {
            _ = try self.emit(.sattr, b.reg, t, 0, @intCast(sl));
        } else {
            _ = try self.emit(.sattrn, b.reg, t, mode, ni);
        }
        return true;
    }

    /// `new K` OF A CLASS THE UNIT DOES NOT DEFINE is Ring's R11 where the
    /// line runs: catchable, the name lower-cased, raised BEFORE the
    /// constructor's arguments are evaluated -- ten rows on 1.27, both
    /// builds, bench/exec/new_absent.ring (2026-09-27). It was a REFUSAL,
    /// kept as "commitment #4 earning its keep" because most such sites are
    /// typos (`stzEnity`); but a refusal stopped a top level dead inside its
    /// own `try`, where Ring catches, and F-63's verdict applies: a refusal
    /// is the safe answer only when the alternative is a WRONG one, and this
    /// alternative is Ring's own. The typo-catching is not lost: `rnxc
    /// check` reports it statically (rpp/unknown-class, F-48), and the
    /// census counts these sites APART and lists every one under --all.
    fn absentClass(self: *Compiler, cn: ts.Node) Error!void {
        const raw = cn.text();
        if (self.census) {
            self.absent_classes.append(self.alloc, .{
                .kind = "new: a class the unit does not define -- R11 when the line runs",
                .row = self.rereadRow(cn),
                .text = if (raw.len > 50) raw[0..50] else raw,
                .func = self.cur.name,
                .byte = self.rereadByte(cn),
                .src = self.rereadSrc(cn),
            }) catch {};
        }
        var lb: [200]u8 = undefined;
        const nm = raw[0..@min(raw.len, lb.len)];
        const low = std.ascii.lowerString(lb[0..nm.len], nm);
        const msg = try std.fmt.allocPrint(self.alloc, "\"Error (R11) : Error in class name, class not found: {s}\"", .{low});
        const save = self.temp;
        defer self.temp = save;
        const t = try self.tmp();
        self.atNode(cn);
        _ = try self.emit(.loadk, t, 0, 0, try self.konstIndex(msg));
        _ = try self.emit(.trap, t, 0, 0, 0);
    }

    fn newObj(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        // taken on entry: a `new` nested in the arguments must not see it
        const early = self.new_early;
        self.new_early = null;
        if (self.eval) |ev| return self.newObjEval(ev, n, dst);
        var cn = n.namedChild(0);
        if (std.mem.eql(u8, cn.kind(), "call_expression")) cn = cn.namedChild(0);
        // A class the unit does not define: Ring raises R11 ("class not
        // found") when the line RUNS -- catchable, and invisible until then.
        // See absentClass.
        const ci = self.findClass(cn.text()) orelse return self.absentClass(cn);

        const save = self.temp;
        defer self.temp = save;
        const objr = try self.tmp();
        _ = try self.emit(.newobj, objr, 0, 0, @intCast(ci.id));

        // arguments, if this was `new C(a, b)`
        var args = ts.Node{ .raw = undefined, .src = n.src };
        var have = false;
        // Whether the parentheses were WRITTEN, which is what decides
        // whether `init` runs. `new M()` parses as a bare new_expression --
        // the grammar keeps no trace of an empty pair -- so the source is
        // the only witness. Read to the end of the node, skip blanks on
        // that line, and look for the `(`.
        // The node SPANS the parentheses even when it keeps no child for
        // them, so its own text is the witness -- a class name can hold no
        // `(`, and `new M` without them holds none either.
        var wrote_parens = std.mem.eql(u8, n.kind(), "new_with_parens") or
            std.mem.indexOfScalar(u8, n.text(), '(') != null;
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) {
            const ch = n.namedChild(i);
            if (std.mem.eql(u8, ch.kind(), "arguments")) {
                args = ch;
                have = true;
            } else if (std.mem.eql(u8, ch.kind(), "call_expression")) {
                // `new M()` -- EMPTY parentheses. The parentheses are what
                // decide whether init runs (see below), and an empty pair
                // carries no `arguments` node, so the call_expression itself
                // is the evidence that they were written.
                wrote_parens = true;
                var j: u32 = 0;
                while (j < ch.namedChildCount()) : (j += 1) {
                    if (std.mem.eql(u8, ch.namedChild(j).kind(), "arguments")) {
                        args = ch.namedChild(j);
                        have = true;
                    }
                }
            }
        }
        const argc: u32 = if (have) args.namedChildCount() else 0;

        // The attribute prologue runs BEFORE init, exactly as Ring does:
        // `init` may read or overwrite what the class body set.
        if (ci.attrs_fn) |pfn| {
            // Its own scope: resetting self.temp to `save` here would free
            // the object's register, and the init window below would then be
            // built on top of the receiver it is supposed to pass.
            const s2 = self.temp;
            defer self.temp = s2;
            const win = try self.tmp();
            _ = try self.emit(.move, win, objr, 1, 0);
            _ = self.reg(win + 8);
            self.atNodeStart(n);
            const site = try self.emit(.call, win, 0, 0, 0);
            try self.fixups.append(self.alloc, .{
                .site = site,
                .fidx = pfn,
                .from = self.funcIndex(self.cur),
            });
        }

        // F-91: the TARGET of `x = new K(args)` holds the object from here,
        // before the arguments are evaluated and before init runs. The
        // assignment stores it again at the end -- the same value, and
        // setRegB/gset retain before they release, so the count balances.
        if (early) |e| switch (e) {
            .global => |slot| _ = try self.emit(.gset, objr, 0, 0, slot),
            .local => |lc| {
                _ = try self.emit(.move, lc.reg, objr, if (lc.boxed) 1 else 0, 0);
                self.daWrite(lc.reg);
            },
        };

        // THE PARENTHESES DECIDE WHETHER `init` RUNS AT ALL. Measured on
        // 1.27, 2026-09-10: `new K` leaves a class with `def init(x)` at
        // its declared attribute values -- init is not called, whatever its
        // arity, and `new M` with a zero-parameter init is the same. Only
        // `new K()` calls it (R19 when it wants parameters it did not get),
        // and `new K(9)` passes them. Ring++ called init either way, so
        // `$p = new K` raised R24 on the first line of a program that runs
        // on Ring -- found by the new_with_parens probe, one line above.
        // `new K { ... }`: the grammar hangs the block's statements off the
        // new_expression itself, after the class name and any arguments.
        // They run on the new object, after init (measured).
        var bfrom: ?u32 = null;
        {
            var j: u32 = 0;
            while (j < n.namedChildCount()) : (j += 1) {
                const kk = n.namedChild(j).kind();
                if (std.mem.eql(u8, kk, "qualified_identifier") or std.mem.eql(u8, kk, "identifier") or
                    std.mem.eql(u8, kk, "arguments") or std.mem.eql(u8, kk, "call_expression")) continue;
                bfrom = j;
                break;
            }
        }
        const parens = have or wrote_parens;
        if (!parens) {
            if (bfrom) |f| try self.braceBlock(objr, ci.id, n, f);
            _ = try self.emit(.move, dst, objr, 1, 0);
            return;
        }
        var has_init = false;
        var probe: ?u16 = ci.id;
        while (probe) |pid| {
            const cc = &self.classes.items[pid];
            for (cc.methods.items) |mi| {
                if (std.ascii.eqlIgnoreCase(self.funcs.items[mi].name, "init")) has_init = true;
            }
            probe = cc.parent;
        }
        if (has_init) {
            const win = try self.tmp();
            _ = try self.emit(.move, win, objr, 1, 0);
            var a: u32 = 0;
            while (a < argc) : (a += 1) {
                const r = try self.tmp();
                try self.expr(args.namedChild(a), r);
            }
            _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
            _ = try self.emit(.callm, win, @intCast(argc), 0, try self.nameIndex("init"));
        }
        if (bfrom) |f| try self.braceBlock(objr, ci.id, n, f);
        _ = try self.emit(.move, dst, objr, 1, 0);
    }

    /// `recv.Method(args)` -- the receiver occupies the call window, so the
    /// callee sees it as r0 and its parameters as r1..
    fn memberCall(self: *Compiler, mexp: ts.Node, args: ts.Node, argc: u32, dst: u8) Error!void {
        const mname = mexp.namedChild(1).text();
        const save = self.temp;
        defer self.temp = save;
        const win = try self.tmp();
        try self.expr(mexp.namedChild(0), win);
        var a: u32 = 0;
        while (a < argc) : (a += 1) {
            const r = try self.tmp();
            try self.expr(args.namedChild(a), r);
        }
        _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
        const ni = try self.nameIndex(mname);
        // If the receiver's class is proved, this call can reach exactly
        // one method, so it takes a real edge instead of the same-name
        // rule -- which otherwise poisons every caller of `.Content()`
        // because SOME Content() somewhere did not compile.
        // Dispatch itself is unchanged: callm still resolves at runtime,
        // and the proof only says which method that will find.
        // APPENDED ONCE PER NAME, not once per call site. Both lists are only
        // ever asked "does this contain X" by spreadPoison, so a repeat adds
        // nothing -- and appending per site made these the largest allocation
        // block left in the compiler once rereadSpan's was fixed: a function
        // that calls `.Content()` forty times grew its list through six
        // doublings, each abandoning the last in an arena that never
        // reclaims (measured 2026-09-13). The scan is over DISTINCT names,
        // which is tens of entries, not the call count.
        var edged = false;
        if (self.recvClass(mexp.namedChild(0))) |cid| {
            if (self.methodOf(cid, mname)) |mi| {
                if (std.mem.indexOfScalar(u32, self.cur.calls_static.items, mi) == null)
                    try self.cur.calls_static.append(self.alloc, mi);
                edged = true;
            }
        }
        if (!edged and std.mem.indexOfScalar(u16, self.cur.calls_named.items, ni) == null)
            try self.cur.calls_named.append(self.alloc, ni);
        self.atNodeStart(mexp);
        _ = try self.emit(.callm, win, @intCast(argc), 0, ni);
        _ = try self.emit(.move, dst, win, 1, 0);
    }

    /// The class a receiver expression provably holds, or null.
    /// Deliberately narrow: `new C`, `This`, and a local already proved.
    /// Anything else is null, never a guess.
    fn recvClass(self: *Compiler, n: ts.Node) ?u16 {
        // eval mode proves nothing: its class table is empty, and every
        // proved path indexes it (see declaredAttr)
        if (self.eval != null) return null;
        const k = n.kind();
        if (self.isThis(n)) return self.cur.owner;
        if (std.mem.eql(u8, k, "new_expression") or
            std.mem.eql(u8, k, "new_with_parens"))
        {
            var cn = n.namedChild(0);
            if (std.mem.eql(u8, cn.kind(), "call_expression")) cn = cn.namedChild(0);
            const ci = self.findClass(cn.text()) orelse return null;
            return ci.id;
        }
        if (std.mem.eql(u8, k, "identifier")) {
            const l = self.lookup(n.text()) orelse {
                // A top-level name (C-2: a global) is proved the same way a
                // local is -- every assignment to it, anywhere in the top
                // level, is `new K` of one class. Softanza's app tests bind
                // `oApp = new stzApp("...")` once and then write `oApp { ... }`.
                if (self.cur.is_main and self.topGlobal(n.text())) return self.globalClass(n.text());
                return null;
            };
            if (l.cls_bad) return null;
            return l.cls;
        }
        return null;
    }

    /// The class a TOP-LEVEL name provably holds, cached per name: every
    /// assignment to it in `@@main` -- inside blocks too -- is `new K`
    /// of the same K. One disagreeing or non-`new` assignment is null.
    fn globalClass(self: *Compiler, name: []const u8) ?u16 {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, name);
        if (self.global_cls.get(key)) |v| return v;
        const mf = self.main_fn orelse return null;
        var found: ?u16 = null;
        var bad = false;
        for (self.funcs.items[mf].stmts.items) |st| self.scanAssigns(st, name, &found, &bad);
        const v: ?u16 = if (bad) null else found;
        const owned = self.foldKey(name) catch return v;
        self.global_cls.put(self.alloc, owned, v) catch {};
        return v;
    }

    fn scanAssigns(self: *Compiler, n: ts.Node, name: []const u8, found: *?u16, bad: *bool) void {
        if (std.mem.eql(u8, n.kind(), "assignment_expression") and n.namedChildCount() >= 2 and
            std.mem.eql(u8, n.namedChild(0).kind(), "identifier") and
            std.ascii.eqlIgnoreCase(n.namedChild(0).text(), name))
        {
            const rhs = n.namedChild(n.namedChildCount() - 1);
            const rk = rhs.kind();
            var cid: ?u16 = null;
            if (std.mem.eql(u8, rk, "new_expression") or std.mem.eql(u8, rk, "new_with_parens")) {
                var cn = rhs.namedChild(0);
                if (std.mem.eql(u8, cn.kind(), "call_expression")) cn = cn.namedChild(0);
                if (self.findClass(cn.text())) |ci| cid = ci.id;
            }
            if (cid) |c| {
                if (found.*) |f| {
                    if (f != c) bad.* = true;
                } else found.* = c;
            } else bad.* = true;
        }
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) self.scanAssigns(n.namedChild(i), name, found, bad);
    }

    /// The method `name` as seen by an object of class `cid`, walking the
    /// inheritance chain the way dispatch does.
    /// A method by name on a class or any ancestor.
    ///
    /// This walked every method of every class in the chain, with a
    /// case-insensitive string compare each time: 339 MILLION comparisons in
    /// one compile of the Softanza unit, read off the `scans:` counter
    /// (2026-09-12). One map per class now, flattened over the parent chain
    /// and built on first use.
    ///
    /// Safe to cache because a class's method list is FINAL after collectAll,
    /// which is the only place it is ever appended to, and every methodOf
    /// call happens later, during emission.
    ///
    /// The child wins over an inherited method of the same name, and within a
    /// class the FIRST declared wins -- which is what the walk it replaces did.
    fn methodOf(self: *Compiler, cid: u16, name: []const u8) ?u32 {
        if (self.eval != null) return null; // see declaredAttr
        scans[8] += 1;
        while (self.method_maps.items.len < self.classes.items.len)
            self.method_maps.append(self.alloc, null) catch return null;
        if (self.method_maps.items[cid] == null) {
            var m = std.StringHashMapUnmanaged(u32){};
            var probe: ?u16 = cid;
            while (probe) |p| {
                const cc = &self.classes.items[p];
                for (cc.methods.items) |mi| {
                    const key = self.foldKey(self.funcs.items[mi].name) catch continue;
                    if (m.contains(key)) continue; // child, then first-declared
                    m.put(self.alloc, key, mi) catch {};
                }
                probe = cc.parent;
            }
            self.method_maps.items[cid] = m;
        }
        var buf: [256]u8 = undefined;
        const key = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else return null;
        return self.method_maps.items[cid].?.get(key);
    }

    /// A GLOBAL function by name. Methods are deliberately excluded.
    ///
    /// This searched every func, methods included, so a bare `lower(x)`
    /// could reach an unrelated class's `Lower()` method -- and because a
    /// method's params include `this`, the arity check PASSED and the call
    /// compiled with `x` handed over as the receiver. A silent miscompile,
    /// masked only by builtins being consulted first.
    fn findFunc(self: *Compiler, name: []const u8) ?*Func {
        scans[5] += 1;
        sizes[2] = self.funcs.items.len;
        self.catchUpFuncs() catch return self.findFuncSlow(name);
        var buf: [256]u8 = undefined;
        const key = if (name.len <= buf.len) std.ascii.lowerString(&buf, name) else (self.foldKey(name) catch return self.findFuncSlow(name));
        const i = self.fn_index.get(key) orelse return null;
        return &self.funcs.items[i];
    }

    /// Index every plain function appended since the last lookup.
    fn catchUpFuncs(self: *Compiler) !void {
        while (self.fn_indexed < self.funcs.items.len) : (self.fn_indexed += 1) {
            const f = &self.funcs.items[self.fn_indexed];
            if (f.owner != null) continue;
            const gop = try self.fn_index.getOrPut(self.alloc, try self.foldKey(f.name));
            if (!gop.found_existing) gop.value_ptr.* = @intCast(self.fn_indexed);
        }
    }

    /// The scan the index replaced -- kept as the answer when the index
    /// cannot be built (allocation), so a lookup never guesses.
    fn findFuncSlow(self: *Compiler, name: []const u8) ?*Func {
        for (self.funcs.items) |*f| {
            if (f.owner == null and std.ascii.eqlIgnoreCase(f.name, name)) return f;
        }
        return null;
    }

    /// Inside a method, a bare `Foo()` reaches the class's own `Foo()` --
    /// Ring resolves it that way and so does this, but through the
    /// receiver, never as a plain call.
    fn ownMethod(self: *Compiler, name: []const u8) ?u32 {
        // the eval compiler's class table is empty; evalHasMethod is its answer
        if (self.eval != null) return null;
        const cid = self.cur.owner orelse return null;
        return self.methodOf(cid, name);
    }

    // --------------------------------------------------------- conditions

    /// Emits code that jumps to the returned patch sites when `n` is FALSE.
    fn cond(self: *Compiler, n: ts.Node, out: *std.ArrayListUnmanaged(u32)) Error!void {
        const k = n.kind();
        if (std.mem.eql(u8, k, "parenthesized_expression")) return self.cond(n.namedChild(0), out);

        // An `assignment_expression` HERE is a comparison: Ring spells
        // assignment and equality alike, assignment is a statement, and a
        // condition wants a value. Without this the fallback at the foot
        // of this function called expr(), expr() sent it to binary(),
        // binary() sent `=` back here, and the three recursed until the
        // register file ran out -- 200 frames deep, refused with no
        // reason recorded, because tmp() is one of the two places that
        // return Unsupported without calling nope(). Measured 2026-09-04.
        if (std.mem.eql(u8, k, "binary_expression") or
            (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() >= 2))
        {
            const op = logicOp(opText(n));
            // `if :Name = value` is NOT a comparison: `:Name = value` builds
            // a two-element list wherever a value is wanted, and a non-empty
            // list is TRUE. Measured on 1.27, where that `if` takes its then
            // branch. Sent down the value path so the one rule answers here
            // too.
            if (std.mem.eql(u8, op, "=") and
                std.mem.eql(u8, n.namedChild(0).kind(), "symbol"))
            {
                const save = self.temp;
                defer self.temp = save;
                const t = try self.tmp();
                try self.expr(n, t);
                try out.append(self.scratch, try self.emit(.jfalsy, t, 0, 0, 0));
                return;
            }
            if (std.mem.eql(u8, op, "and")) {
                try self.cond(n.namedChild(0), out);
                try self.cond(n.namedChild(1), out);
                return;
            }
            if (std.mem.eql(u8, op, "or")) {
                // Jump to the body when the left side holds.
                var taken = std.ArrayListUnmanaged(u32){};
                defer taken.deinit(self.scratch);
                var lfalse = std.ArrayListUnmanaged(u32){};
                defer lfalse.deinit(self.scratch);
                try self.cond(n.namedChild(0), &lfalse);
                const j = try self.emit(.jmp, 0, 0, 0, 0);
                try taken.append(self.scratch, j);
                for (lfalse.items) |p| self.land(p);
                try self.cond(n.namedChild(1), out);
                for (taken.items) |p| self.land(p);
                return;
            }

            // A comparison: emit the INVERTED jump, so it fires when false.
            const inv: ?vm.Op = if (std.mem.eql(u8, op, "="))
                .jne
            else if (std.mem.eql(u8, op, "!="))
                .jeq
            else if (std.mem.eql(u8, op, "<"))
                .jge
            else if (std.mem.eql(u8, op, "<="))
                .jgt
            else if (std.mem.eql(u8, op, ">"))
                .jle
            else if (std.mem.eql(u8, op, ">="))
                .jlt
            else
                null;
            if (inv == null) {
                // a non-comparison binary used as a condition: test its
                // truth value rather than refusing
                const save = self.temp;
                defer self.temp = save;
                const t = try self.tmp();
                try self.expr(n, t);
                try out.append(self.scratch, try self.emit(.jfalsy, t, 0, 0, 0));
                return;
            }
            if (inv) |o| {
                const save = self.temp;
                defer self.temp = save;
                const l = if (try self.operandReg(n.namedChild(0))) |rr| rr else blk: {
                    const t = try self.tmp();
                    try self.expr(n.namedChild(0), t);
                    break :blk t;
                };
                const r = if (try self.operandReg(n.namedChild(1))) |rr| rr else blk: {
                    const t = try self.tmp();
                    try self.expr(n.namedChild(1), t);
                    break :blk t;
                };
                // c = 1 SAYS THE JUMP IS INVERTED. An OBJECT operand makes
                // the VM call the class's `operator` with the comparison
                // the SOURCE wrote -- `o < 3` calls operator("<"), never
                // the ">=" this jump tests -- and then jump on the result's
                // FALSITY. Without the flag the inversion would rename the
                // operator (bench/exec/operator.ring).
                try out.append(self.scratch, try self.emit(o, l, r, 1, 0));
                return;
            }
        }

        // Any other expression is a truth test. Ring's truth is emptiness:
        // 0, "" and [] are false, an object is true -- so `jeqi` (int-only)
        // was wrong for every string and list condition.
        const save = self.temp;
        defer self.temp = save;
        const t = try self.tmp();
        try self.expr(n, t);
        try out.append(self.scratch, try self.emit(.jfalsy, t, 0, 0, 0));
    }

    // -------------------------------------------------------- statements

    /// Does `n` mention the identifier `name` (case-insensitively: Ring
    /// identifiers are, F-18) anywhere in its subtree?
    fn mentions(n: ts.Node, name: []const u8) bool {
        if (std.mem.eql(u8, n.kind(), "identifier")) return std.ascii.eqlIgnoreCase(n.text(), name);
        const cnt = n.namedChildCount();
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            if (mentions(n.namedChild(i), name)) return true;
        }
        return false;
    }

    /// Would compiling `rhs` straight into `name`'s register read the
    /// register AFTER writing it? True when the target is mentioned
    /// anywhere except as the bare left operand of a binary expression
    /// whose right operand does not mention it.
    /// `aL + v` APPENDS A COPY of a list or an object on Ring (F-94, both
    /// 1.27 builds): the appended value does not move when the original is
    /// changed after. Softanza's CombinationsXT appends one working list and
    /// then `del`s from it, and History() appends each step's content; both
    /// came back emptied or overwritten. `copyv` copies only what something
    /// else holds, so a fresh literal or call result is pushed as it is, and
    /// a proved scalar or string costs nothing at all.
    fn appendCopy(self: *Compiler, item: ts.Node, val: u8) Error!void {
        switch (self.classOf(item)) {
            .int, .str => {},
            // b = 1 for a list LITERAL: Ring pins every `ref()` inside one
            // that `+` appends (F-118; the VM's pinRefs)
            else => _ = try self.emit(.copyv, val, if (std.mem.eql(u8, item.kind(), "list_literal")) 1 else 0, 0, 0),
        }
    }

    fn isNewExpr(n: ts.Node) bool {
        const k = n.kind();
        return std.mem.eql(u8, k, "new_expression") or std.mem.eql(u8, k, "new_with_parens");
    }

    fn readsTargetLate(rhs: ts.Node, name: []const u8) bool {
        if (!mentions(rhs, name)) return false;
        if (std.mem.eql(u8, rhs.kind(), "binary_expression") and rhs.namedChildCount() >= 2) {
            const left = rhs.namedChild(0);
            const right = rhs.namedChild(1);
            if (std.mem.eql(u8, left.kind(), "identifier") and
                std.ascii.eqlIgnoreCase(left.text(), name) and !mentions(right, name)) return false;
        }
        return true;
    }

    fn assign(self: *Compiler, n: ts.Node) Error!void {
        const lhs = n.namedChild(0);
        const rhs = n.namedChild(1);
        const op = opText(n);

        // eval mode: a target that resolves through the caller's frame --
        // an attribute by name, or a global -- before the ordinary paths
        if (self.eval) |ev| {
            if (try self.evalAssign(ev, n, lhs, rhs, op)) return;
        }

        // Rule A: `$x = ...` writes a GLOBAL, from any scope. That the
        // write is outward is now VISIBLE at the assignment, which is the
        // whole difference from §2.7 -- there the same effect happened to
        // a name that looked local.
        // Inside `obj { ... }` at the TOP LEVEL, a bare name is the object's
        // attribute unless a global of that name already exists (measured:
        // an existing binding keeps winning). The top-level rule below would
        // otherwise claim it first -- which it did: `new K { x = 5 }`
        // compiled to a global write and o.x stayed 0. "Already exists" is
        // judged from what pass A has seen, so a global assigned LATER in
        // the file counts too; Ring decides at the moment the block runs.
        if (std.mem.eql(u8, lhs.kind(), "identifier") and self.braces.items.len > 0 and
            lhs.text().len > 0 and lhs.text()[0] != '$' and lhs.text()[0] != '@' and
            self.lookup(lhs.text()) == null and self.knownGlobal(lhs.text()) == null)
        {
            if (try self.braceAttrWrite(lhs.text(), op, rhs, n)) return;
        }
        if (std.mem.eql(u8, lhs.kind(), "identifier") and
            ((lhs.text().len > 1 and lhs.text()[0] == '$') or self.topGlobal(lhs.text())) and
            self.paramLocal(lhs.text()) == null)
        {
            const slot = try self.globalSlot(lhs.text());
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            if (std.mem.eql(u8, op, "=")) {
                // the global holds the new object while init's arguments
                // run -- and while init runs, which may read it by name
                if (isNewExpr(rhs)) self.new_early = .{ .global = slot };
                try self.expr(rhs, t);
                self.new_early = null; // never outlives its own right-hand side
                if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
            } else {
                const cur2 = try self.tmp();
                _ = try self.emit(.gget, cur2, 0, 0, slot);
                try self.expr(rhs, t);
                const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                // Result goes back into the register the global was read
                // into, and the flag says so: `$s += "x"` can then grow the
                // string in place instead of copying it, which is the
                // difference between linear and quadratic when a program
                // builds text a piece at a time. The store below is
                // self-assignment safe -- gset retains before it releases.
                _ = try self.emit(o, cur2, cur2, t, 2);
                _ = try self.emit(.gset, cur2, 0, 0, slot);
                return;
            }
            _ = try self.emit(.gset, t, 0, 0, slot);
            return;
        }
        // `This.x = v` and `This.x += v`: the slot, and never an accessor --
        // `This` is exempt from Ring's getters and setters (F-73). The
        // compound form was refused until 2026-09-26; it is read, apply,
        // write, as a bare attribute's compound already was.
        if (std.mem.eql(u8, lhs.kind(), "member_expression") and self.isThis(lhs.namedChild(0)) and
            self.eval == null)
        {
            if (self.attrSlot(lhs.namedChild(1).text())) |slot| {
                const save = self.temp;
                defer self.temp = save;
                const t = try self.tmp();
                if (std.mem.eql(u8, op, "=")) {
                    try self.expr(rhs, t);
                    if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
                } else {
                    // A COMPOUND THROUGH `This` READS THROUGH THE GETTER
                    // and writes the slot -- measured on both 1.27 builds:
                    // with getx() answering 42, `This.x += 1` leaves x at
                    // 43 and `This.x *= 2` at 84, while `This.x = This.x
                    // + 1` and a bare `x += 1` read the slot. So the read
                    // is by name with the accessor rule forced on.
                    const cur2 = try self.tmp();
                    _ = try self.emit(.gattrn, cur2, 0, vm.ACC_CHECK, try self.nameIndex(lhs.namedChild(1).text()));
                    try self.expr(rhs, t);
                    const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                    _ = try self.emit(o, t, cur2, t, 1);
                }
                _ = try self.emit(.sattr, 0, t, 0, @intCast(slot));
                return;
            }
            // not declared: the by-name write below, R12 at run time as
            // Ring raises it for an unknown property
        }

        // `o.@attr = v` -- the same proof, the other direction. sattr
        // carries the object in r[a]; the This form passes 0.
        if (std.mem.eql(u8, lhs.kind(), "member_expression")) {
            const aname = lhs.namedChild(1).text();
            if (self.recvClass(lhs.namedChild(0))) |rcid| {
                if (self.attrSlotOf(rcid, aname)) |slot| {
                    // a class with `set<name>` (or, for a compound, `get`)
                    // is written through it: the by-name path below
                    const plain = std.mem.eql(u8, op, "=");
                    if (!self.hasAccessor(rcid, aname, false) and
                        (plain or !self.hasAccessor(rcid, aname, true)))
                    {
                        const save = self.temp;
                        defer self.temp = save;
                        const o = try self.tmp();
                        try self.expr(lhs.namedChild(0), o);
                        const t = try self.tmp();
                        if (plain) {
                            try self.expr(rhs, t);
                            if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
                        } else {
                            const cur2 = try self.tmp();
                            _ = try self.emit(.gattr, cur2, o, 0, @intCast(slot));
                            try self.expr(rhs, t);
                            const opc: vm.Op = compoundOp(op) orelse return self.nope(n);
                            _ = try self.emit(opc, t, cur2, t, 1);
                        }
                        _ = try self.emit(.sattr, o, t, 0, @intCast(slot));
                        return;
                    }
                }
            }
            // Not proved: written by NAME at run time, the twin of the
            // gattrn read, and where Ring's accessor rule is applied. A
            // compound form reads through the getter and writes through
            // the setter -- measured: `o.x += 1` with getx() answering 42
            // hands setx() 43 (row 9 of bench/exec/getset.ring).
            {
                const save = self.temp;
                defer self.temp = save;
                const mode: u8 = if (self.isThis(lhs.namedChild(0))) vm.ACC_RAW else self.accMode();
                const o = try self.tmp();
                try self.expr(lhs.namedChild(0), o);
                const ni = try self.nameIndex(aname);
                const t = try self.tmp();
                if (std.mem.eql(u8, op, "=")) {
                    try self.expr(rhs, t);
                    if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
                } else {
                    const cur2 = try self.tmp();
                    // through `This` the read takes the getter (see above)
                    const rmode: u8 = if (mode == vm.ACC_RAW) vm.ACC_CHECK else mode;
                    _ = try self.emit(.gattrn, cur2, o, rmode, ni);
                    try self.expr(rhs, t);
                    const opc: vm.Op = compoundOp(op) orelse return self.nope(n);
                    _ = try self.emit(opc, t, cur2, t, 1);
                }
                _ = try self.emit(.sattrn, o, t, mode, ni);
                return;
            }
        }

        // An attribute is written by its bare name too -- probed on 1.27:
        // inside a method, `nCount = 99` sets the ATTRIBUTE (This.nCount
        // became 99), it does not make a local. A name already bound as a
        // parameter or by an earlier assignment wins, so the local lookup
        // comes first.
        // A bare name the class DECLARES is that attribute, written as Ring
        // writes it -- in a class-level initialiser (`class B  x = 1`, which
        // runs in the synthetic prologue) and in every method (`cTP = v`,
        // measured on 1.27: the attribute becomes v). This used to hold for
        // the prologue ONLY, so a method's bare write became a local and the
        // attribute silently kept its old value -- Ring said xyz, Ring++ said
        // start, with no error. A local of that name, made by an earlier
        // assignment or a parameter, still wins: `lookup` is consulted first
        // (probed 2026-09-09, a parameter SHIELDS an attribute).
        // NOT INSIDE A BRACE (F-124): there a bare write is the brace object's
        // attribute, or a new local -- never the method's own attribute
        // (`new Local { x = 100 }` in a method of Point leaves self.x alone)
        if (std.mem.eql(u8, lhs.kind(), "identifier") and
            lhs.text().len > 0 and lhs.text()[0] != '@' and lhs.text()[0] != '$' and
            self.lookup(lhs.text()) == null and self.braces.items.len == 0)
        {
            if (self.declaredAttr(lhs.text())) |slot| {
                const save = self.temp;
                defer self.temp = save;
                const t = try self.tmp();
                if (std.mem.eql(u8, op, "=")) {
                    try self.expr(rhs, t);
                    if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
                } else {
                    const cur2 = try self.tmp();
                    _ = try self.emit(.gattr, cur2, 0, 0, @intCast(slot));
                    try self.expr(rhs, t);
                    const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                    _ = try self.emit(o, t, cur2, t, 1);
                }
                _ = try self.emit(.sattr, 0, t, 0, @intCast(slot));
                return;
            }
        }
        // Rule A: `@x = ...` writes an ATTRIBUTE, always. A local can no
        // longer shadow it, and the class body need not have declared it.
        if (std.mem.eql(u8, lhs.kind(), "identifier") and
            lhs.text().len > 1 and lhs.text()[0] == '@')
        {
            if (self.braces.items.len > 0 and try self.braceAttrWrite(lhs.text(), op, rhs, n)) return;
            const slot = self.attrSlot(lhs.text()) orelse
                return self.nopeKind(lhs, "@attribute outside a class");
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            if (std.mem.eql(u8, op, "=")) {
                try self.expr(rhs, t);
                if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
            } else {
                const cur2 = try self.tmp();
                _ = try self.emit(.gattr, cur2, 0, 0, @intCast(slot));
                try self.expr(rhs, t);
                const o: vm.Op = compoundOp(op) orelse return self.nope(n);
                _ = try self.emit(o, t, cur2, t, 1);
            }
            _ = try self.emit(.sattr, 0, t, 0, @intCast(slot));
            return;
        }
        if (std.mem.eql(u8, lhs.kind(), "identifier")) {
            // Inside `obj { ... }`: a name already bound -- a local, or a
            // global at the top level -- keeps winning (measured); any other
            // bare name is the object's attribute. Where Ring would then
            // CREATE a global for a name the object lacks, this writes the
            // attribute by name and the object answers R12: C-6.
            if (self.braces.items.len > 0 and self.lookup(lhs.text()) == null and
                !(self.cur.is_main and self.knownGlobal(lhs.text()) != null))
            {
                if (try self.braceAttrWrite(lhs.text(), op, rhs, n)) return;
            }
            // Rule A: at the top level a name is a global and must say so.
            // C-11: assigning the name REBINDS it -- after its loop it is an
            // ordinary variable again, as Python and Lua allow. Softanza does
            // exactly that at most of the sites the marker first caught
            // (`_i_ = _aMembers_[_k_][_j_]` after a `for _i_` loop, then reads).
            self.unretire(lhs.text());
            // These refusals ARE the migration list -- 975 bare and 250
            // `_x_` assignments, mechanically findable and mechanically
            // fixable by prefixing `$`.
            // (a top-level LOCAL exists: a loop variable, assigned in its body
            // -- `for x in a  x = x * 10 next` -- and that is the loop's own)
            if (self.cur.is_main and self.lookup(lhs.text()) == null) {
                return self.nopeKind(lhs, "top-level assignment needs $ (Rule A)");
            }
            // (C-14, a top-level lambda's bare write to a top-level global,
            // took the global path above through `topGlobal`.)
            // DIVERGENCE, deliberate: a bare name that is neither a local nor
            // an attribute becomes a LOCAL here. Ring writes the CALLER's
            // variable -- probed on 1.27, a method's `nTmp = 12345` reached
            // out and overwrote the caller's `nTmp`. That leak is the entire
            // reason for the `_var_` convention in 300K lines of Softanza;
            // code written to dodge it is collision-free by construction and
            // behaves identically here, with the convention now unnecessary.
            const l = try self.define(lhs.text());
            const target = l.reg;
            if (std.mem.eql(u8, op, "=")) {
                // expr() uses the destination as the ACCUMULATOR for its
                // partial results, so an operand that reads the target after
                // the first write sees the partial, not the variable:
                // `s = left(s, 1) + "|" + substr(s, 2)` gave "||" (found by
                // rpp/tui.ring's Text, 2026-09-03). When the right side
                // mentions the target anywhere but as the bare left operand
                // of a binary expression -- `i = i + 1` keeps its fast path --
                // the value is built in a temp and moved at the end.
                if (readsTargetLate(rhs, lhs.text())) {
                    const save = self.temp;
                    defer self.temp = save;
                    const t = try self.tmp();
                    // `p = new K([1] + p)`: p is the new object while the
                    // arguments run (F-91)
                    if (isNewExpr(rhs)) self.new_early = .{ .local = .{ .reg = target, .boxed = l.class.boxed() } };
                    try self.expr(rhs, t);
                    self.new_early = null; // never outlives its own right-hand side
                    if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, t, 0, 0, 0);
                    _ = try self.emit(.move, target, t, if (l.class.boxed()) 1 else 0, 0);
                    self.daWrite(target);
                    return;
                }
                try self.expr(rhs, target);
                // Ring copies a list or an object into its new variable (C-7).
                if (self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, target, 0, 0, 0);
                // A plain `move` into itself would be dead; expr() already
                // wrote the destination.
                self.daWrite(target);
                return;
            }
            const save = self.temp;
            defer self.temp = save;
            // `x += v` READS x first: Ring's R24 when nothing assigned it
            // (item 7 named this; F-89 closes it)
            try self.daRead(l, lhs.text());
            // `j += i` reads an UNBOXED local in place, as a binary operand is read; a boxed one keeps its
            // temporary, whose count is what stops `s += s` appending a string to itself in place
            const t = if (try self.localOperand(rhs, true)) |r| r else blk: {
                const tt = try self.tmp();
                try self.expr(rhs, tt);
                break :blk tt;
            };
            const o: vm.Op = compoundOp(op) orelse return self.nope(n);
            _ = try self.emit(o, target, target, t, 1);
            self.daWrite(target);
            return;
        }

        if (std.mem.eql(u8, lhs.kind(), "subscript_expression")) {
            // `a[i] += x` -- read the element, apply, write it back.
            var comp: ?vm.Op = null;
            if (!std.mem.eql(u8, op, "=")) {
                comp = compoundOp(op) orelse return self.nope(n);
            }

            // Walk the whole path: `a[i][j][k]` collects the indices from
            // the OUTSIDE in, so they are reversed to get a, i, j, k.
            var idxn: [8]ts.Node = undefined;
            var depth: usize = 0;
            var cur = lhs;
            while (std.mem.eql(u8, cur.kind(), "subscript_expression")) {
                if (depth == idxn.len) return self.nope(cur);
                idxn[depth] = cur.namedChild(1);
                depth += 1;
                cur = cur.namedChild(0);
            }
            const save = self.temp;
            defer self.temp = save;

            // The root of the path may be a local, an attribute or a
            // global. The last two must be BORROWED for writing: reading
            // one takes a reference, rc goes to 2, and the write below
            // then copy-on-writes the container and is lost.
            const is_name = std.mem.eql(u8, cur.kind(), "identifier");
            const base_name = if (is_name) cur.text() else "";
            var root: u8 = undefined;
            var bare_attr = false;
            if (!is_name) {
                // ANY EXPRESSION IS A PLACE. `o.aL[1] = 99`, `q.L()[1] = 99`
                // and `F()[2] = 99` all write through to the original on
                // Ring -- measured, four shapes -- and all three were
                // refused here, because the root had to be a bare name.
                //
                // THE REASON IT HAD TO BE IS GONE. The borrow above exists
                // because reading a container into a temporary took its
                // count to 2 and the write then CLONED it; that was
                // copy-on-write, and C-7 removed it on 2026-09-11, when the
                // copy moved to the assignment. `cowFor` has been the
                // identity function ever since, so a temporary holding a
                // list IS the list. This is the third time a rule outlived
                // the table that described it (`s[i]`, the widening, and
                // now the place) -- the lesson each time is that a
                // correction has to carry the code that encoded the old
                // rule with it.
                //
                // NOT borrowed, and that is the whole difference: `expr`
                // RETAINS what it leaves in the register, so the frame
                // sweep at `ret` balances it. Clearing it the way a borrow
                // is cleared would leak, and adding it to `borrowed` would
                // release a count nobody took.
                root = try self.tmp();
                try self.expr(cur, root);
            } else if (base_name.len > 1 and base_name[0] == '@') {
                const slot = self.attrSlot(base_name) orelse
                    return self.nopeKind(cur, "@attribute outside a class");
                root = try self.tmp();
                _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
            } else if ((base_name.len > 1 and base_name[0] == '$') or self.topGlobal(base_name)) {
                // assigned nowhere: R24, and for a subscripted root Ring's
                // R24 carries NO name (probed, `$zz[1] = 5` and `yy[1] = 5`)
                const gslot = self.knownGlobal(base_name) orelse {
                    _ = try self.emit(.r24, 0, 0, 0, -1);
                    return;
                };
                root = try self.tmp();
                _ = try self.emit(.ggetw, root, 0, 0, gslot);
            } else if (self.lookup(base_name)) |l| {
                root = l.reg;
            } else if (self.declaredAttr(base_name)) |slot| {
                // C-12 on the WRITE paths too. A name the class declares without
                // `@` is that attribute; the read path has honoured that since
                // C-12 landed, but every write path still refused it, so a class
                // written in that style compiled its reads and poisoned the
                // methods that build it -- 87 refusals in one Softanza unit,
                // measured 2026-09-12. Borrowed for writing, exactly as `@attr`
                // is: read one without borrowing and the write copy-on-writes a
                // container that is then thrown away.
                root = try self.tmp();
                _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
                bare_attr = true;
            } else if (self.knownGlobal(base_name) == null) {
                // assigned nowhere and no global: Ring's R24 -- WITHOUT a
                // name for a subscripted root, probed on 1.27 (d = -1)
                _ = try self.emit(.r24, 0, 0, 0, -1);
                return;
            } else {
                return self.nopeKind(cur, "bare name is not a local (Rule A)");
            }

            // Descend to the container that actually holds the target slot,
            // making each level private on the way (see the vgetw opcode).
            var container: u8 = root;
            var borrow: ?u8 = null;
            var borrowed = std.ArrayListUnmanaged(u8){};
            defer borrowed.deinit(self.scratch);
            if (bare_attr or (base_name.len > 1 and (base_name[0] == '@' or base_name[0] == '$')) or self.topGlobal(base_name))
                try borrowed.append(self.scratch, root);
            var k: usize = 0;
            while (k + 1 < depth) : (k += 1) {
                const ir = try self.indexReg(idxn[depth - 1 - k]);
                const t = try self.tmp();
                _ = try self.emit(.vgetw, t, container, ir, 0);
                container = t;
                borrow = t;
                try borrowed.append(self.scratch, t);
            }

            // the index is read by `vset` AFTER the right-hand side runs, so it is read in place only when that
            // side cannot move it
            const idx_local = if (mayWriteLocal(rhs)) null else try self.localOperand(idxn[0], false);
            const idx = idx_local orelse try self.tmp();
            const val = try self.tmp();
            if (idx_local == null) try self.expr(idxn[0], idx);
            try self.expr(rhs, val);
            // A compound operator reads the element first. `vget` sends a
            // STRING index to `hget` in the same registers (a=dst,
            // b=container, c=key), so one instruction serves a list and a
            // hash alike -- and `.add` stays polymorphic, so `+=` on a
            // string element concatenates exactly as Ring's does.
            var src = val;
            if (comp == null and self.needsCopyAssign(rhs)) _ = try self.emit(.copyv, val, 0, 0, 0);
            if (comp) |co| {
                const cell = try self.tmp();
                // RETAINED (d = 1). The compound below writes its result into
                // this same register, and that write RELEASES what the register
                // held -- the list's own element. Read unretained, that release
                // took the element's count to zero while the list still pointed
                // at it. Harmless only for as long as releasing a string leaked
                // its bytes; once release actually freed them, `s[1] += "XY"`
                // used freed memory (found 2026-09-12, cmpd:C6).
                _ = try self.emit(.vget, cell, container, idx, 1);
                _ = try self.emit(co, cell, cell, val, 1);
                src = cell;
            }
            if (self.classOf(idxn[0]) == .str) {
                _ = try self.emit(.hset, container, idx, src, 1);
            } else {
                _ = try self.emit(.vset, container, idx, src, 1);
            }
            // Every borrow ends here: a borrowed register was never
            // retained, and the mask marks every temp as boxed, so leaving
            // one live makes `ret` release it and underflow the refcount.
            for (borrowed.items) |br| _ = try self.emit(.loadi, br, 1, 0, 0);

            // The borrow register points at something it does not own, so it
            // is cleared before the statement ends -- otherwise the frame
            // teardown would release a reference that was never taken.
            if (borrow) |b| _ = try self.emit(.loadi, b, 1, 0, 0);
            return;
        }
        // `F() = v`, `o.M() = v` (F-81): Ring RUNS the call, then the right
        // side, then raises `R34 : Variable is required for the assignment
        // operation` -- unless the result is a list or an object, which it
        // takes silently. Measured on both builds 2026-09-27; max/string/
        // stzSringConstraints.ring:55 is the estate's one such line. NOT
        // reproduced, named: for a list or an object Ring WRITES THROUGH the
        // result, so `o.Me() = 5` with Me returning This replaces o itself.
        // Here that case does nothing; no estate site depends on it.
        if (std.mem.eql(u8, lhs.kind(), "call_expression") and std.mem.eql(u8, op, "=")) {
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            try self.expr(lhs, t);
            const t2 = try self.tmp();
            try self.expr(rhs, t2);
            const tl = try self.tmp();
            _ = try self.emit(.bcall, tl, t, 1, @intFromEnum(vm.Builtin.islist));
            const not_list = try self.emit(.jfalsy, tl, 0, 0, 0);
            const list_end = try self.emit(.jmp, 0, 0, 0, 0);
            self.land(not_list);
            _ = try self.emit(.bcall, tl, t, 1, @intFromEnum(vm.Builtin.isobject));
            const to_raise = try self.emit(.jfalsy, tl, 0, 0, 0);
            const obj_end = try self.emit(.jmp, 0, 0, 0, 0);
            self.land(to_raise);
            _ = try self.emit(.loadk, tl, 0, 0, try self.konstIndex("\"Error (R34) : Variable is required for the assignment operation\""));
            self.atNode(n);
            _ = try self.emit(.trap, tl, 0, 0, 0);
            self.land(list_end);
            self.land(obj_end);
            return;
        }
        return self.nope(n);
    }

    /// Emit `return <expr>` when the parse split the two apart.
    fn returnExpr(self: *Compiler, e: ts.Node) Error!void {
        self.temp = @max(self.floor, self.bottom());
        const t = try self.tmp();
        try self.expr(e, t);
        // an eval string's `return v` is the VALUE of the eval: it halts
        // the nested run rather than popping a frame that was never pushed
        if (self.eval == null) try self.leaveTries(self.try_open);
        _ = try self.emit(if (self.eval != null) .halt else .ret, t, 0, 0, 0);
    }

    fn stmt(self: *Compiler, n: ts.Node) Error!void {
        if (self.depth > 200) return self.nope(n);
        self.lnStmtStart(n);
        const ln_need = self.ln_has_next or self.ln_block_quirk;
        self.ln_has_next = false;
        self.ln_block_quirk = false;
        const tail_save = self.tail;
        defer self.tail = tail_save;
        self.tail = tailOf(self, n);
        const ln_pc = self.here();
        self.stmt_level += 1;
        defer self.stmt_level -= 1;
        // a refused statement's code is cut back: what it left pending
        // names code that is gone
        errdefer {
            if (self.ln_pend) |p| if (p.start >= ln_pc) {
                self.ln_pend = null;
            };
            if (self.ln_open) |o| if (o.start >= ln_pc) {
                self.ln_open = null;
            };
        }
        self.depth += 1;
        defer self.depth -= 1;
        const k = n.kind();
        // every instruction of this statement reports this line and file.
        // A statement the F-58 machinery re-read lives in a snippet buffer
        // (`func __reread()` + the piece), so its own row and source say
        // nothing: the re-read bookkeeping carries the original ones. And
        // a function's statements are in the function's file, whatever
        // buffer a node came from.
        if (self.reread_src) |rs| {
            self.cur_row = self.fileRowOf(n.src, n.startByte()) orelse self.reread_row;
            self.cur_file = self.fileOf(rs.ptr) orelse self.fileOf(self.cur.node.src.ptr) orelse 0;
        } else {
            self.cur_row = n.start().row + 1;
            self.cur_file = self.fileOf(n.src.ptr) orelse self.fileOf(self.cur.node.src.ptr) orelse 0;
        }
        self.temp = @max(self.floor, self.bottom());

        // Structural noise, not code -- checked BEFORE anything else,
        // because a stray `ok` arrives wrapped in an expression_statement
        // and would otherwise be compiled as a variable read.
        if (std.mem.eql(u8, k, "load_statement")) {
            // F-128: a load INSIDE A BLOCK of the top level runs its file's
            // top level here, each time it is reached; a top-level load was
            // spliced already, and one inside a function is left as it was.
            if (self.cur.is_main and self.nested_stmts.count() > 0 and
                !std.mem.eql(u8, n.parent().kind(), "source_file"))
            {
                const from = self.fileOf(n.src.ptr) orelse return;
                const t = loadTarget(self.alloc, from, n) orelse return;
                const loaded = self.nested_stmts.get(@intCast(t)) orelse return;
                for (loaded) |st| try self.stmt(st);
            }
            return;
        }
        if (std.mem.eql(u8, k, "comment")) return;
        {
            var probe = n;
            if (std.mem.eql(u8, k, "expression_statement") and n.namedChildCount() == 1)
                probe = n.namedChild(0);
            // A bare literal on its own line is legal Ring and does
            // nothing -- verified on 1.27. In Softanza these are prose
            // inside comment blocks that were never commented, so the
            // statement is real and the value is discarded.
            const pk = probe.kind();
            if (std.mem.eql(u8, pk, "string") or
                std.mem.eql(u8, pk, "number") or
                std.mem.eql(u8, pk, "symbol")) return;
            if (std.mem.eql(u8, probe.kind(), "identifier")) {
                const t = probe.text();
                for ([_][]const u8{ "ok", "next", "end", "off", "done", "else", "but", "other", "private" }) |w| {
                    if (std.ascii.eqlIgnoreCase(t, w)) return;
                }
                // `next i`: the grammar leaves the `i` as a bare statement after
                // the loop. It is the loop's label, not a read of a variable
                // that is gone (C-11) -- the only bare statement that can name
                // a retired loop variable.
                if (self.wasLoopVar(t)) return;
                // IN A CLASS BODY, A BARE NAME IS A DECLARATION, and Ring
                // gives it a value: the four-byte string "NULL" -- probed on
                // 1.27, `x` alone in the body then `len(x)` is 4 and
                // `type(x)` STRING, and isNull() answers 1 for it. The
                // prologue is that body, so here the statement is the
                // ASSIGNMENT, not a read; compiled as a read it raised R24
                // on its own declaration the moment gattr began checking.
                if (std.mem.eql(u8, self.cur.name, PROLOGUE)) {
                    // `@nBare` and `nBare` are both declarations here.
                    // declaredAttr is the BARE-name resolver and refuses a
                    // sigil by design; attrSlot takes the name as written.
                    // `t.len >= 1`: a lone `@` IS an attribute name in Softanza
                    // (stzChainOfTruth declares `_`, `_@`, `@` and `Q` on four
                    // lines), and declaredAttr refuses any `@`-form.
                    const found = if (t.len >= 1 and t[0] == '@') self.attrSlot(t) else self.declaredAttr(t);
                    if (found) |slot| {
                        const save = self.temp;
                        defer self.temp = save;
                        const r = try self.tmp();
                        _ = try self.emit(.loadk, r, 0, 0, try self.konstIndex("NULL"));
                        _ = try self.emit(.sattr, 0, r, 0, @intCast(slot));
                        return;
                    }
                }
                // A bare NAME on its own line is a read Ring performs and
                // discards: `next i` is `next` and then `i`, and probed on
                // 1.27 a defined name passes while an undefined one is R24.
                // So it compiles as the read -- a local resolves, and an
                // unknown bare name is Rule A's refusal, which is where the
                // four Softanza typos of this shape (`reurn x`, `func@ F()`,
                // `_cResult_ This.SValue()`) are caught rather than run.
                if (std.mem.eql(u8, k, "expression_statement")) {
                    const save = self.temp;
                    defer self.temp = save;
                    const tr = try self.tmp();
                    return self.expr(probe, tr);
                }
            }
        }

        if (std.mem.eql(u8, k, "expression_statement")) {
            var e = n.namedChild(0);
            // `(a.b().c()...)` -- a call chain the re-read wrapped so the
            // grammar could not cut it (parseOne). Parentheses round a CALL
            // change nothing a statement does; round anything else they
            // would (`(x = 1)` compares), so only a call is unwrapped.
            while (std.mem.eql(u8, e.kind(), "parenthesized_expression") and e.namedChildCount() == 1 and
                std.mem.eql(u8, e.namedChild(0).kind(), "call_expression")) e = e.namedChild(0);
            const ek = e.kind();
            if (std.mem.eql(u8, ek, "assignment_expression")) return self.assign(e);
            // `o { ... }` on a line of its own: the block runs and the value
            // (the object) is discarded.
            if (std.mem.eql(u8, ek, "brace_expression")) {
                const t = try self.tmp();
                return self.braceExpr(e, t);
            }
            // Delegated, not handled here: this inline copy only knew
            // how to increment a plain local, so `a[i][j]--` was refused
            // before the full handler below ever saw it.
            if (std.mem.eql(u8, ek, "postfix_expression")) return self.stmt(e);
            if (std.mem.eql(u8, ek, "call_expression")) {
                const t = try self.tmp();
                return self.call(e, t);
            }
            // `call pf()` wrapped in an expression statement -- the grammar
            // does that inside a loop body -- reached the generic refusal
            // below, though the handler existed: 45 sites in Softanza.
            if (std.mem.eql(u8, ek, "call_keyword_expression")) {
                const t = try self.tmp();
                return self.callKeyword(e, t);
            }
            // A line that BEGINS with `+` or `-` is a statement of its own
            // on Ring: evaluated, then discarded. Probed on the oracle
            // 2026-09-08: `x = "a"` / `+ "b"` leaves x as "a". A same-row
            // tail never reaches here -- rejoinTail folds it back into the
            // line the grammar cut it from -- so what arrives is the real
            // Ring statement, and it compiles to what Ring does with it.
            if (isSplitTail(n)) {
                const t = try self.tmp();
                return self.expr(e, t);
            }
            // `aList + item` as a STATEMENT is Ring's append operator, not
            // arithmetic whose result is thrown away. It is the idiom
            // Softanza uses everywhere, and like add() it must mutate the
            // PLACE -- reading the list into a temporary first would make
            // copy-on-write clone it and drop the append.
            if (std.mem.eql(u8, ek, "binary_expression") and
                std.mem.eql(u8, opText(e), "+"))
            {
                // A CHAIN -- `aList + x + y` -- appends both to the same list on
                // Ring (probed 2026-09-08: `a + 2 + 3` leaves len 3, last 3; each
                // `[..]` lands as ONE element). It used to refuse, and the reason
                // was right: evaluating the inner `+` as an expression aliases the
                // vector, copy-on-write clones for the outer append, and the
                // second append is silently lost. So the inner `+` is never
                // evaluated -- the left spine is flattened at compile time and
                // each item is pushed onto the HEAD, in source order, as its
                // own in-place append. A head that is not a place (a string
                // literal, a call) mutates nothing on Ring, so the whole
                // expression is evaluated and discarded, as Ring does.
                var items: [16]ts.Node = undefined;
                var nitems: usize = 0;
                var head = e;
                while (std.mem.eql(u8, head.kind(), "binary_expression") and
                    std.mem.eql(u8, opText(head), "+"))
                {
                    if (nitems == items.len) return self.nope(head);
                    items[nitems] = head.namedChild(1);
                    nitems += 1;
                    head = head.namedChild(0);
                }
                if (!(std.mem.eql(u8, head.kind(), "identifier") or
                    std.mem.eql(u8, head.kind(), "subscript_expression")))
                {
                    const save0 = self.temp;
                    defer self.temp = save0;
                    const t0 = try self.tmp();
                    return self.expr(e, t0);
                }
                var ii: usize = nitems;
                while (ii > 0) {
                    ii -= 1;
                    const item = items[ii];
                    const lhs = head;
                    // `@a[i][2] + x` -- append through a nested PATH. The path
                    // is walked with the same borrow-for-writing route the
                    // assignment path uses, or copy-on-write clones a level
                    // and the append lands in the clone.
                    if (std.mem.eql(u8, lhs.kind(), "subscript_expression")) {
                        const save2 = self.temp;
                        defer self.temp = save2;
                        var idxn: [8]ts.Node = undefined;
                        var depth: usize = 0;
                        var cur = lhs;
                        while (std.mem.eql(u8, cur.kind(), "subscript_expression")) {
                            if (depth == idxn.len) return self.nope(cur);
                            idxn[depth] = cur.namedChild(1);
                            depth += 1;
                            cur = cur.namedChild(0);
                        }
                        if (!std.mem.eql(u8, cur.kind(), "identifier")) return self.nope(cur);
                        const bn = cur.text();
                        var root: u8 = undefined;
                        var bare_attr = false;
                        // EVAL: an attribute of the caller's receiver, by NAME.
                        // A retaining read, not a borrow -- the eval's sweep
                        // releases it -- and since C-7 the list it reads IS
                        // the attribute's list, so the append lands there.
                        var eval_attr = false;
                        if (self.eval) |ev| {
                            if (self.lookup(bn) == null and ((bn.len > 1 and bn[0] == '@') or self.evalHasAttr(ev, bn))) {
                                root = try self.tmp();
                                try self.expr(cur, root);
                                eval_attr = true;
                            }
                        }
                        if (eval_attr) {} else if (bn.len > 1 and bn[0] == '@') {
                            const slot = self.attrSlot(bn) orelse
                                return self.nopeKind(cur, "@attribute outside a class");
                            root = try self.tmp();
                            _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
                        } else if ((bn.len > 1 and bn[0] == '$') or self.topGlobal(bn)) {
                            const gslot = self.knownGlobal(bn) orelse {
                                _ = try self.emit(.r24, 0, 0, 0, -1);
                                return;
                            };
                            root = try self.tmp();
                            _ = try self.emit(.ggetw, root, 0, 0, gslot);
                        } else if (self.lookup(bn)) |l| {
                            root = l.reg;
                        } else if (self.declaredAttr(bn)) |slot| {
                            // C-12 on the WRITE paths too. A name the class declares without
                            // `@` is that attribute; the read path has honoured that since
                            // C-12 landed, but every write path still refused it, so a class
                            // written in that style compiled its reads and poisoned the
                            // methods that build it -- 87 refusals in one Softanza unit,
                            // measured 2026-09-12. Borrowed for writing, exactly as `@attr`
                            // is: read one without borrowing and the write copy-on-writes a
                            // container that is then thrown away.
                            root = try self.tmp();
                            _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
                            bare_attr = true;
                        } else if (self.knownGlobal(bn) == null) {
                            // assigned nowhere, no global: R24 with no name
                            _ = try self.emit(.r24, 0, 0, 0, -1);
                            return;
                        } else {
                            return self.nopeKind(cur, "bare name is not a local (Rule A)");
                        }
                        var container: u8 = root;
                        var borrowed = std.ArrayListUnmanaged(u8){};
                        defer borrowed.deinit(self.scratch);
                        if (!eval_attr and (bare_attr or (bn.len > 1 and (bn[0] == '@' or bn[0] == '$')) or self.topGlobal(bn)))
                            try borrowed.append(self.scratch, root);
                        var lvl: usize = 0;
                        while (lvl < depth) : (lvl += 1) {
                            const ir = try self.tmp();
                            try self.expr(idxn[depth - 1 - lvl], ir);
                            const t2 = try self.tmp();
                            _ = try self.emit(.vgetw, t2, container, ir, 0);
                            container = t2;
                            try borrowed.append(self.scratch, t2);
                        }
                        const val = try self.tmp();
                        try self.expr(item, val);
                        try self.appendCopy(item, val);
                        _ = try self.emit(.vpush, container, val, 1, 0);
                        // Every borrow ends here. A borrowed register was never
                        // retained, and the mask marks every temp as boxed, so
                        // leaving one live makes `ret` release it and underflow
                        // the refcount.
                        for (borrowed.items) |br| _ = try self.emit(.loadi, br, 1, 0, 0);
                        continue;
                    }
                    if (std.mem.eql(u8, lhs.kind(), "identifier")) {
                        const nm = lhs.text();
                        const save = self.temp;
                        defer self.temp = save;
                        // EVAL: `@aAnswers + @result` inside a string stzNatural
                        // builds -- the receiver's attribute by name (see the
                        // subscript case above for why a plain read is right)
                        if (self.eval) |ev| {
                            _ = ev;
                            // an attribute by name, a global, or a name an eval
                            // made (F-107): the read hands back the list itself
                            if (self.lookup(nm) == null and !(nm.len > 1 and nm[0] == '$')) {
                                const lst = try self.tmp();
                                try self.expr(lhs, lst);
                                const val = try self.tmp();
                                try self.expr(item, val);
                                try self.appendCopy(item, val);
                                _ = try self.emit(.vpush, lst, val, 1, 0);
                                continue;
                            }
                        }
                        if (nm.len > 1 and nm[0] == '@') {
                            const slot = self.attrSlot(nm) orelse return self.nope(lhs);
                            const lst = try self.tmp();
                            _ = try self.emit(.gattrw, lst, 0, 0, @intCast(slot));
                            const val = try self.tmp();
                            try self.expr(item, val);
                            try self.appendCopy(item, val);
                            _ = try self.emit(.vpush, lst, val, 1, 0);
                            _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
                            continue;
                        }
                        // `$g + item` -- append to a GLOBAL. Borrowed for
                        // writing like the attribute case above, or
                        // copy-on-write clones the list and the append is lost.
                        if ((nm.len > 1 and nm[0] == '$') or self.topGlobal(nm)) {
                            const gslot = self.knownGlobal(nm) orelse {
                                _ = try self.emit(.r24, 0, 0, 0, @intCast(try self.nameIndex(nm)));
                                return;
                            };
                            const lst = try self.tmp();
                            _ = try self.emit(.ggetw, lst, 0, 1, gslot);
                            const val = try self.tmp();
                            try self.expr(item, val);
                            try self.appendCopy(item, val);
                            _ = try self.emit(.vpush, lst, val, 1, 0);
                            _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
                            continue;
                        }
                        if (self.lookup(nm)) |l| {
                            const val = try self.tmp();
                            try self.expr(item, val);
                            try self.appendCopy(item, val);
                            _ = try self.emit(.vpush, l.reg, val, 1, 0);
                            continue;
                        }

                        // C-12 on the WRITE paths too. A name the class declares without
                        // `@` is that attribute; the read path has honoured that since
                        // C-12 landed, but every write path still refused it, so a class
                        // written in that style compiled its reads and poisoned the
                        // methods that build it -- 87 refusals in one Softanza unit,
                        // measured 2026-09-12. Borrowed for writing, exactly as `@attr`
                        // is: read one without borrowing and the write copy-on-writes a
                        // container that is then thrown away.
                        if (self.declaredAttr(nm)) |slot| {
                            const lst = try self.tmp();
                            _ = try self.emit(.gattrw, lst, 0, 0, @intCast(slot));
                            const val = try self.tmp();
                            try self.expr(item, val);
                            try self.appendCopy(item, val);
                            _ = try self.emit(.vpush, lst, val, 1, 0);
                            _ = try self.emit(.loadi, lst, 1, 0, 0); // borrow ends
                            continue;
                        }
                        // A bare name that is not a local is Rule A's case, and
                        // it must SAY so: reported as `binary_expression` it
                        // looked like a missing feature, and the migration --
                        // which selects on the Rule A message -- skipped every
                        // `aList + item` on a global. Softanza has 128 of them.
                        if (nm.len > 0 and nm[0] != '@' and nm[0] != '$') {
                            // ...unless the name is assigned nowhere and is no
                            // global: then it is Ring's R24, naming it
                            if (self.knownGlobal(nm) == null) {
                                _ = try self.emit(.r24, 0, 0, 0, @intCast(try self.nameIndex(nm)));
                                return;
                            }
                            return self.nopeKind(lhs, if (self.cur.is_main)
                                "top-level bare name needs $ (Rule A)"
                            else
                                "bare name is not a local (Rule A)");
                        }
                    }
                    // a head that is a name but not a place we can write:
                    // the refusals above already said which
                    return self.nope(lhs);
                }
                return;
            }
            // `new K(p)` ON A LINE OF ITS OWN, its value discarded. The
            // estate's type tests are written exactly this way --
            //
            //     try
            //         new stzTable(paTable)
            //         return 1
            //     catch
            //         return 0
            //     done
            //
            // -- where the CONSTRUCTION is the test and the object is
            // thrown away. Six sites in Softanza (stzTable.IsTable,
            // stzEntity.IsEntity, stzSection.IsSection, stzHashList's
            // NumberOfPairsQ and two _normalizeDateTime), every one of
            // them refused, and each took its whole function with it.
            // `init` runs and may raise either way, which is the point.
            if (std.mem.eql(u8, ek, "new_expression") or
                std.mem.eql(u8, ek, "new_with_parens"))
            {
                const t = try self.tmp();
                return self.expr(e, t);
            }
            // A BINARY EXPRESSION AS A STATEMENT is EVALUATED and its value
            // DISCARDED, which is all Ring does with one -- and its errors
            // are then Ring's ordinary runtime errors instead of a refusal.
            // Measured on 1.27: `p - 1` leaves p at 9, `s - "_"` raises R41
            // on a string, `aL - [2]` raises R21 on a list, and an OBJECT
            // dispatches to its class's `operator` method.
            //
            // `+` never arrives here -- the append idiom above returns on
            // every path, and it must, because that one is a PLACE write
            // and not a discarded value.
            //
            // Three sites in Softanza, and all three are latent bugs of the
            // estate's own (`_cMax_ - "_"` where the next line assigns
            // `_cMax_`, a stray `and` chain as the body of a would-be
            // one-line `if`). The point is not that they work; it is that
            // Ring REACHES them and says what is wrong, where a refusal
            // took the whole method away.
            if (std.mem.eql(u8, ek, "binary_expression")) {
                const t = try self.tmp();
                return self.expr(e, t);
            }
            return self.nope(e);
        }

        if (std.mem.eql(u8, k, "call_keyword_expression")) {
            const t = try self.tmp();
            return self.callKeyword(n, t);
        }
        if (std.mem.eql(u8, k, "try_statement")) return self.tryStmt(n);
        if (std.mem.eql(u8, k, "switch_statement")) return self.switchStmt(n);
        if (std.mem.eql(u8, k, "private_section")) return; // a marker, not code
        // `bye` -- Ring stops the program here. A statement, not a call, so
        // it never reached the builtin table.
        if (std.mem.eql(u8, k, "bye_statement")) {
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            _ = try self.emit(.bcall, t, t, 0, @intFromEnum(vm.Builtin.bye));
            return;
        }
        if (std.mem.eql(u8, k, "see_statement")) {
            if (n.namedChildCount() == 0) return;
            // `?` prints WITH a newline; `see` and `put` WITHOUT, in any case
            // of letters -- one node kind, told apart by the first token.
            // Both used to print a newline, which double-spaced every `see
            // x + nl` and would have torn the terminal renderer's in-place
            // repaint. The test was then "the word is lowercase `see`", so
            // `See`, `SEE` and every `put` printed a line again -- Ring's own
            // library writes `See " = " + Sum + nl`. Ring's parser has one
            // branch for K_SEE | K_PUT (vendor/ring-vm/src/stmt.c:382) and
            // another for `?` (:392); bench/exec/see_put.ring pins it.
            const no_nl: u8 = if (n.childCount() > 0 and !std.mem.eql(u8, n.child(0).text(), "?")) 1 else 0;
            const t = try self.tmp();
            try self.expr(n.namedChild(0), t);
            _ = try self.emit(.say, t, 0, no_nl, 0);
            return;
        }
        if (std.mem.eql(u8, k, "loop_statement")) {
            const lv = try self.loopLevel(n, self.continues.items.len);
            try self.leaveTries(self.triesInLoops(lv));
            const j = try self.emit(.jmp, 0, 0, 0, 0);
            try self.continues.items[self.continues.items.len - lv].append(self.alloc, j);
            return;
        }
        if (std.mem.eql(u8, k, "postfix_expression")) {
            // The STATEMENT form -- `n++` and `a[i][2]--`. The VALUE form is
            // in `expr`, where the pre/post question this used to defer is
            // measured and answered: Ring's postfix syntax increments and
            // yields the NEW value. It said the shape was "not written that
            // way in Softanza", and `This.MatchAt(_cStr_, _nStart_++)` is.
            const op = opText(n);
            const one: i32 = if (std.mem.eql(u8, op, "++")) 1 else if (std.mem.eql(u8, op, "--")) -1 else return self.nope(n);
            const tgt = n.namedChild(0);
            if (std.mem.eql(u8, tgt.kind(), "identifier")) self.unretire(tgt.text());
            const save = self.temp;
            defer self.temp = save;

            // `a[i][j]--` and `@a[i]--`: a place, not a variable. The
            // path is walked exactly as the assignment path walks it --
            // borrowing each level for writing -- and the element is read,
            // adjusted and written back.
            if (std.mem.eql(u8, tgt.kind(), "subscript_expression")) {
                var idxn: [8]ts.Node = undefined;
                var depth: usize = 0;
                var cur = tgt;
                while (std.mem.eql(u8, cur.kind(), "subscript_expression")) {
                    if (depth == idxn.len) return self.nope(cur);
                    idxn[depth] = cur.namedChild(1);
                    depth += 1;
                    cur = cur.namedChild(0);
                }
                if (!std.mem.eql(u8, cur.kind(), "identifier")) return self.nope(cur);

                const bn = cur.text();
                var root: u8 = undefined;
                var bare_attr = false;
                if (bn.len > 1 and bn[0] == '@') {
                    const slot = self.attrSlot(bn) orelse
                        return self.nopeKind(cur, "@attribute outside a class");
                    root = try self.tmp();
                    _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
                } else if ((bn.len > 1 and bn[0] == '$') or self.topGlobal(bn)) {
                    const gslot = self.knownGlobal(bn) orelse {
                        _ = try self.emit(.r24, 0, 0, 0, -1);
                        return;
                    };
                    root = try self.tmp();
                    _ = try self.emit(.ggetw, root, 0, 0, gslot);
                } else if (self.lookup(bn)) |l| {
                    root = l.reg;
                } else if (self.declaredAttr(bn)) |slot| {
                    // C-12 on the WRITE paths too. A name the class declares without
                    // `@` is that attribute; the read path has honoured that since
                    // C-12 landed, but every write path still refused it, so a class
                    // written in that style compiled its reads and poisoned the
                    // methods that build it -- 87 refusals in one Softanza unit,
                    // measured 2026-09-12. Borrowed for writing, exactly as `@attr`
                    // is: read one without borrowing and the write copy-on-writes a
                    // container that is then thrown away.
                    root = try self.tmp();
                    _ = try self.emit(.gattrw, root, 0, 0, @intCast(slot));
                    bare_attr = true;
                } else if (self.knownGlobal(bn) == null) {
                    // assigned nowhere, no global: R24 with no name
                    _ = try self.emit(.r24, 0, 0, 0, -1);
                    return;
                } else {
                    return self.nopeKind(cur, "bare name is not a local (Rule A)");
                }

                var container: u8 = root;
                var borrowed = std.ArrayListUnmanaged(u8){};
                defer borrowed.deinit(self.scratch);
                if (bare_attr or (bn.len > 1 and (bn[0] == '@' or bn[0] == '$')) or self.topGlobal(bn))
                    try borrowed.append(self.scratch, root);
                var lvl: usize = 0;
                while (lvl + 1 < depth) : (lvl += 1) {
                    const ir = try self.indexReg(idxn[depth - 1 - lvl]);
                    const t = try self.tmp();
                    _ = try self.emit(.vgetw, t, container, ir, 0);
                    container = t;
                    try borrowed.append(self.scratch, t);
                }

                const idx = try self.indexReg(idxn[0]);
                const cell = try self.tmp();
                // RETAINED (d = 1). The compound below writes its result into
                // this same register, and that write RELEASES what the register
                // held -- the list's own element. Read unretained, that release
                // took the element's count to zero while the list still pointed
                // at it. Harmless only for as long as releasing a string leaked
                // its bytes; once release actually freed them, `s[1] += "XY"`
                // used freed memory (found 2026-09-12, cmpd:C6).
                _ = try self.emit(.vget, cell, container, idx, 1);
                _ = try self.emit(.addi, cell, cell, 1, one);
                _ = try self.emit(.vset, container, idx, cell, 0);
                // Every borrow ends here: a borrowed register was never
                // retained, and the mask marks every temp as boxed, so leaving
                // one live makes `ret` release it and underflow the refcount.
                for (borrowed.items) |br| _ = try self.emit(.loadi, br, 1, 0, 0);
                return;
            }
            if (std.mem.eql(u8, tgt.kind(), "identifier")) {
                // `$g++` -- a global, read, adjusted and written back. It
                // went missing while `$g += 1` worked, which is the same
                // statement said differently, so a program had to know
                // which spelling the compiler happened to accept.
                // `knownGlobal`, not `globalSlot`: incrementing a global
                // nothing has assigned is a mistake worth naming, and the
                // assignment path already names it the same way.
                // ...and a top-level bare name is a global too (C-2): `n++`
                // after `n = 0` at the top level was refused as "identifier n".
                if ((tgt.text().len > 1 and tgt.text()[0] == 36) or self.topGlobal(tgt.text())) {
                    const gslot = self.knownGlobal(tgt.text()) orelse
                        return self.nopeKind(tgt, "$global never assigned");
                    const t = try self.tmp();
                    _ = try self.emit(.gget, t, 0, 0, gslot);
                    _ = try self.emit(.addi, t, t, 1, one);
                    _ = try self.emit(.gset, t, 0, 0, gslot);
                    return;
                }
                if (self.lookup(tgt.text())) |l| {
                    _ = try self.emit(.addi, l.reg, l.reg, 1, one);
                    self.daWrite(l.reg);
                    return;
                }
                if (self.attrSlot(tgt.text())) |slot| {
                    const t = try self.tmp();
                    _ = try self.emit(.gattr, t, 0, 0, @intCast(slot));
                    _ = try self.emit(.addi, t, t, 1, one);
                    _ = try self.emit(.sattr, 0, t, 0, @intCast(slot));
                    return;
                }
                return self.nope(tgt);
            }
            return self.nope(tgt);
        }
        if (std.mem.eql(u8, k, "return_statement")) {
            // IN EVAL MODE a `return` is the eval's VALUE (F-72: `r =
            // eval("return 6")` gives 6; without one, ""), and it HALTS the
            // nested run -- `ret` would pop a frame eval never pushed.
            if (self.eval != null) {
                const save0 = self.temp;
                defer self.temp = save0;
                const t0 = try self.tmp();
                if (retValue(n)) |rv| {
                    try self.expr(rv, t0);
                } else {
                    _ = try self.emit(.loadk, t0, 0, 0, try self.konstIndex("\"\""));
                }
                _ = try self.emit(.halt, t0, 0, 0, 0);
                return;
            }
            const rv = retValue(n) orelse {
                // A BARE `return` yields NULL -- the empty STRING -- on Ring,
                // and this loaded the integer 0. Measured on 1.27 both ways
                // (bench/exec/implicit_return.ring): type STRING, isNull 1,
                // len 0, `= ""` true, where Ring++ answered NUMBER, 0, 1,
                // false. Same for an early `return` inside a branch.
                //
                // THROUGH A TEMPORARY, never r0, and that is not style. r0 of
                // a METHOD is the receiver, and under the TYPED build `loadi`
                // stores without releasing the old value while `loadk`
                // RELEASES it (setRegB's boxed flag) -- so loading the string
                // into r0 would release `this` once more on every method that
                // returns bare: the over-release family that `s[i]` and the
                // widening were. `ret t` is the path `return <expr>` already
                // takes just below, proven on heap values; "" is a pinned
                // constant on top of that.
                // Restored, not reset: mid-body a loop's counter can be live in
                // a register above the locals, so this takes the next free one
                // and gives it back.
                const save0 = self.temp;
                defer self.temp = save0;
                const t0 = try self.tmp();
                _ = try self.emit(.loadk, t0, 0, 0, try self.konstIndex("\"\""));
                try self.leaveTries(self.try_open);
                _ = try self.emit(.ret, t0, 0, 0, 0);
                return;
            };
            const t = try self.tmp();
            try self.expr(rv, t);
            // the value is evaluated INSIDE the try -- an error in it is the
            // try's to catch -- and only then are the handlers left (F-90)
            try self.leaveTries(self.try_open);
            // NO COPY HERE. Ring copies at the ASSIGNMENT and never at the
            // return: `P().Bump()` on a `return $o` mutates the global, and
            // `o.Me().Bump()` on a `return This` mutates o -- probed on 1.27
            // in bench/exec/return_ref.ring, with no assignment anywhere.
            // A copy sat here from 2026-09-11 to 2026-09-21 on the strength
            // of a probe that did `r = o.GetL()`, which measured the
            // assignment and called it the return. The estate's node plane
            // is a singleton reached only through `StzNodePlane().X()`, so
            // every Register, Ask and LastStatus acted on a throwaway, and
            // cluster/d3_supervision ran past 120 s on false liveness.
            // The assignment sites copy a call's result now instead.
            _ = try self.emit(.ret, t, 0, 0, 0);
            return;
        }

        if (std.mem.eql(u8, k, "if_statement")) return self.ifStmt(n, ln_need);
        if (std.mem.eql(u8, k, "while_statement")) return self.whileStmt(n);
        if (std.mem.eql(u8, k, "do_again_statement")) return self.doAgainStmt(n);
        if (std.mem.eql(u8, k, "for_statement")) return if (forIsIn(n)) self.forInStmt(n) else self.forStmt(n);

        if (std.mem.eql(u8, k, "exit_statement")) {
            const lv = try self.loopLevel(n, self.breaks.items.len);
            try self.leaveTries(self.triesInLoops(lv));
            const j = try self.emit(.jmp, 0, 0, 0, 0);
            try self.breaks.items[self.breaks.items.len - lv].append(self.alloc, j);
            return;
        }

        // `give x` -- one line of stdin into x. Under Rule A a `$` name is
        // the global; a bare name is a local, and at the top level it needs
        // its sigil like any other top-level write.
        if (std.mem.eql(u8, k, "give_statement")) {
            if (n.namedChildCount() == 0) return self.nope(n);
            const tgt = n.namedChild(0);
            if (!std.mem.eql(u8, tgt.kind(), "identifier")) return self.nope(tgt);
            const nm = tgt.text();
            const save = self.temp;
            defer self.temp = save;
            const t = try self.tmp();
            _ = try self.emit(.bcall, t, t, 0, @intFromEnum(vm.Builtin.giveline));
            if ((nm.len > 1 and nm[0] == '$') or self.topGlobal(nm)) {
                const gslot = try self.globalSlot(nm);
                _ = try self.emit(.gset, t, 0, 0, gslot);
            } else if (self.cur.is_main) {
                return self.nopeKind(tgt, "top-level assignment needs $ (Rule A)");
            } else {
                const l = try self.define(nm);
                _ = try self.emit(.move, l.reg, t, 1, 0);
            }
            return;
        }

        // Comments and stray tokens.
        if (std.mem.eql(u8, k, "comment")) return;
        return self.nope(n);
    }

    /// Statements are the named children of a block-ish node from `from`
    /// onward, skipping the clause nodes that the caller handles itself.
    fn body(self: *Compiler, n: ts.Node, from: u32) Error!void {
        return self.bodyTo(n, from, n.namedChildCount());
    }

    /// The same, stopping BEFORE `to`. Every other loop carries its test as
    /// the FIRST child; `do ... again <cond>` carries it as the last, so its
    /// body is everything up to it.
    fn bodyTo(self: *Compiler, n: ts.Node, from: u32, to: u32) Error!void {
        var list = std.ArrayListUnmanaged(ts.Node){};
        defer list.deinit(self.alloc);
        var i: u32 = from;
        while (i < to) : (i += 1) {
            const ch = n.namedChild(i);
            const ck = ch.kind();
            if (std.mem.eql(u8, ck, "elseif_clause") or std.mem.eql(u8, ck, "else_clause")) break;
            // Neither of these carries code. Refusing them poisoned the
            // whole enclosing function for a `#` line.
            if (std.mem.eql(u8, ck, "comment") or
                std.mem.eql(u8, ck, "private_section")) continue;
            list.append(self.alloc, ch) catch return Error.OutOfMemory;
        }
        try self.stmtSeq(list.items);
    }

    /// A statement sequence, read the way Ring reads it: a span the grammar
    /// cut or joined across a `+`/`-` (rereadSpan) is compiled as the
    /// statements Ring sees there, everything else as itself. The nested
    /// twin of emitOne's loop -- without it, `return "" + @nRe + "-" +
    /// (-@nIm) + "i"` inside an `if` returned "3-" and evaluated the rest
    /// as a discarded statement: a wrong answer, silently.
    fn stmtSeq(self: *Compiler, list: []const ts.Node) Error!void {
        // F-110: the block's flag, for each of its statements in turn
        const ln_bq = self.ln_block_quirk;
        self.ln_block_quirk = false;
        const seq: ?usize = if (list.len > 0) self.seqOpen(list[0]) else null;
        var el: usize = 0; // the element open since this statement (structure pass)
        defer if (seq != null and list.len > 0) self.seqElem(seq, list, el, list.len - 1);
        var si: usize = 0;
        while (si < list.len) : (si += 1) {
            if (seq != null and si > 0) {
                self.seqElem(seq, list, el, si - 1);
                el = si;
            }
            try self.shareClear(list[si]);
            self.ln_has_next = si + 1 < list.len;
            self.ln_block_quirk = ln_bq;
            if (rereadSpan(self, list, si)) |rr| {
                const st = list[si];
                for (rr.pieces) |piece| {
                    self.ln_has_next = true; // a piece: assumed followed
                    self.ln_block_quirk = ln_bq;
                    // while the piece compiles, refusals name the source line
                    self.reread_src = st.src;
                    self.reread_byte = st.startByte();
                    self.reread_row = st.start().row + 1 + piece.row_off;
                    defer self.reread_src = null;
                    if (piece.as_return) {
                        self.lnStmtStart(piece.node);
                        try self.returnExpr(piece.node);
                        self.daEnd();
                    } else try self.stmt(piece.node);
                }
                si += rr.consumed - 1;
                continue;
            }
            try self.stmt(list[si]);
            if (endsPath(list[si])) self.daEnd();
        }
        self.lnSeqEnd();
    }

    /// A statement after which nothing on this path runs -- return, exit,
    /// loop, bye, and a `raise(...)` statement. Definite assignment (F-89)
    /// lets such a branch drop out where paths meet. A call to a function
    /// that happens to raise is not recognised, which only means a check
    /// more, never one fewer.
    fn endsPath(n: ts.Node) bool {
        const k = n.kind();
        if (std.mem.eql(u8, k, "return_statement") or std.mem.eql(u8, k, "exit_statement") or
            std.mem.eql(u8, k, "loop_statement") or std.mem.eql(u8, k, "bye_statement")) return true;
        var e = n;
        if (std.mem.eql(u8, k, "expression_statement") and n.namedChildCount() > 0) e = n.namedChild(0);
        return std.mem.eql(u8, e.kind(), "call_expression") and e.namedChildCount() > 0 and
            std.ascii.eqlIgnoreCase(e.namedChild(0).text(), "raise");
    }

    /// `call f(a, b)` -- an INDIRECT call through a closure value. The
    /// target is not known at compile time, which is the one place Ring++
    /// cannot resolve a name early; the closure carries its own id.
    fn callKeyword(self: *Compiler, n: ts.Node, dst: u8) Error!void {
        var inner = n.namedChild(0);
        if (std.mem.eql(u8, inner.kind(), "call_keyword_expression")) inner = inner.namedChild(0);
        // `call f(x) = 0` and `call f(x) + 1`: the grammar gives the keyword
        // a BINARY whose left side is the call, and Ring reads it as
        // `(call f(x)) = 0` -- measured on 1.27 (bench/exec/call_binary.ring):
        // a comparison yields 1 or 0, an arithmetic its value. This REFUSED
        // it ("call needs a function call"), and stzRefinableCode's
        // derivation check is written exactly so. The call goes into dst,
        // the right operand into a temporary, and the operator is applied
        // -- `cmpv` for a comparison, the plain opcode for arithmetic.
        if ((std.mem.eql(u8, inner.kind(), "binary_expression") or
            std.mem.eql(u8, inner.kind(), "assignment_expression")) and
            inner.namedChildCount() >= 2 and
            std.mem.eql(u8, inner.namedChild(0).kind(), "call_expression"))
        {
            const op = opText(inner);
            const cmps = [_][]const u8{ "=", "!=", "<", "<=", ">", ">=" };
            var ci: ?u8 = null;
            for (cmps, 0..) |cmp, i| {
                if (std.mem.eql(u8, op, cmp)) ci = @intCast(i);
            }
            const arith: ?vm.Op = if (std.mem.eql(u8, op, "+")) .add else if (std.mem.eql(u8, op, "-")) .sub else if (std.mem.eql(u8, op, "*")) .mul else if (std.mem.eql(u8, op, "/")) .div else if (std.mem.eql(u8, op, "%")) .mod else null;
            if (ci == null and arith == null) return self.nopeKind(n, "call needs a function call");
            const save = self.temp;
            defer self.temp = save;
            try self.callKeywordOn(inner.namedChild(0), dst);
            const t = try self.tmp();
            try self.expr(inner.namedChild(1), t);
            if (ci) |c| {
                _ = try self.emit(.cmpv, dst, dst, t, c);
            } else {
                _ = try self.emit(arith.?, dst, dst, t, 0);
            }
            return;
        }
        return self.callKeywordOn(inner, dst);
    }

    /// The `call` keyword on a bare call expression.
    fn callKeywordOn(self: *Compiler, inner: ts.Node, dst: u8) Error!void {
        if (!std.mem.eql(u8, inner.kind(), "call_expression"))
            return self.nopeKind(inner, "call needs a function call");

        var ar = inner.field("arguments");
        if (ar.isNull()) {
            var q: u32 = 0;
            while (q < inner.namedChildCount()) : (q += 1) {
                if (std.mem.eql(u8, inner.namedChild(q).kind(), "arguments"))
                    ar = inner.namedChild(q);
            }
        }
        const argc: u32 = if (ar.isNull()) 0 else ar.namedChildCount();

        const save = self.temp;
        defer self.temp = save;
        const win = try self.tmp();
        try self.expr(inner.namedChild(0), win); // the closure value
        var a: u32 = 0;
        while (a < argc) : (a += 1) {
            const r = try self.tmp();
            try self.expr(ar.namedChild(a), r);
        }
        _ = self.reg(win + @as(u8, @intCast(argc)) + 8);
        _ = try self.emit(.calli, win, @intCast(argc), 0, 0);
        _ = try self.emit(.move, dst, win, 1, 0);
    }

    /// `try ... catch ... done`, on §2.17's model as far as the grammar
    /// allows today.
    ///
    /// The caught value is bound to a LOCAL named `cCatchError`, not to a
    /// process global. That single change removes what §2.17 calls the
    /// serious defect: in Ring a callee -- including the logging call a
    /// handler makes first -- overwrites the error its caller is
    /// handling, because the binding is shared. Here each handler has its
    /// own register, so there is nothing to overwrite -- for the DIRECT
    /// read inside the handler. A read anywhere else is Ring's process
    /// global, `vm.catch_last`, since C-15 (2026-09-24): every landing
    /// records the error, and the estate reads it through a function.
    ///
    /// Still waiting on a front-end change, priced with multi-value `on`:
    /// `finally` is not a keyword the grammar knows, and `catch e` parses
    /// as a statement that READS `e` rather than as a binding -- so the
    /// typed-catch half of §2.17 cannot be expressed yet.
    fn tryStmt(self: *Compiler, n: ts.Node) Error!void {
        // A FRESH binding per try. `define` returns an existing local of
        // the same name, so naming them all "cCatchError" made nested
        // handlers share one register -- an inner catch then overwrote the
        // outer's error, which is the very defect this construct exists to
        // remove, reproduced one scope down.
        var buf: [24]u8 = undefined;
        const nm = std.fmt.bufPrint(&buf, "cCatchError${d}", .{self.catch_regs.items.len}) catch
            return Error.OutOfMemory;
        const owned = self.alloc.dupe(u8, nm) catch return Error.OutOfMemory;
        const errl = try self.define(owned);

        const arm = try self.emit(.ptry, errl.reg, 0, 0, 0);
        // definite assignment (F-89): the handler can be entered from any
        // point of the try body, so it starts from what held BEFORE it
        const da_in = self.da;

        // the try body runs until the catch clause begins
        var i: u32 = 0;
        var borrowed: [4]u64 = .{ 0, 0, 0, 0 };
        {
            var list = std.ArrayListUnmanaged(ts.Node){};
            defer list.deinit(self.alloc);
            while (i < n.namedChildCount()) : (i += 1) {
                const ch = n.namedChild(i);
                // stop at EITHER clause -- a try may have only a finally
                if (std.mem.eql(u8, ch.kind(), "catch_clause") or
                    std.mem.eql(u8, ch.kind(), "finally_clause")) break;
                list.append(self.alloc, ch) catch return Error.OutOfMemory;
            }
            self.try_open += 1;
            defer self.try_open -= 1;
            try self.try_borrows.append(self.alloc, .{ 0, 0, 0, 0 });
            defer borrowed = self.try_borrows.pop().?;
            try self.stmtSeq(list.items);
        }

        _ = try self.emit(.pend, 0, 0, 0, 0);

        // Find the clauses. `catch` is optional when `finally` is present:
        // cleanup without recovery is a real shape, and the error path is
        // exactly where cleanup must be guaranteed (§2.17).
        var cc: ?ts.Node = null;
        var fc: ?ts.Node = null;
        var q: u32 = i;
        while (q < n.namedChildCount()) : (q += 1) {
            const ch = n.namedChild(q);
            if (std.mem.eql(u8, ch.kind(), "catch_clause")) cc = ch;
            if (std.mem.eql(u8, ch.kind(), "finally_clause")) fc = ch;
        }

        // ---- the normal path: finally, then past the handler ----------
        if (fc) |f| try self.body(f, 0);
        const da_norm = self.da;
        const over = try self.emit(.jmp, 0, 0, 0, 0);

        // ---- the handler ----------------------------------------------
        self.land(arm);
        // End every borrow the body may have left open (try_borrows). Each
        // is a temporary, dead at the handler, so `loadi` with b = 1 -- the
        // raw store that releases nothing, as the normal path's end of a
        // borrow is (every other `loadi` releases what it overwrites since
        // 2026-10-14) -- forgets it; at worst a register a later statement
        // had filled with an OWNED value is forgotten too, a leak on the
        // error path only.
        for (borrowed, 0..) |word, w| {
            var bits = word;
            while (bits != 0) : (bits &= bits - 1) {
                const r: u8 = @intCast(w * 64 + @ctz(bits));
                _ = try self.emit(.loadi, r, 1, 0, 0);
            }
        }
        self.da = da_in;
        self.daWrite(errl.reg);
        if (cc) |c| {
            // `catch(e)` binds the caught value to `e`; plain `catch`
            // leaves it as this handler's cCatchError.
            var body_from: u32 = 0;
            if (c.namedChildCount() > 0 and
                std.mem.eql(u8, c.namedChild(0).kind(), "identifier"))
            {
                const bl = try self.define(c.namedChild(0).text());
                _ = try self.emit(.move, bl.reg, errl.reg, 1, 0);
                self.daWrite(bl.reg);
                body_from = 1;
            }
            try self.catch_regs.append(self.alloc, errl.reg);
            try self.body(c, body_from);
            _ = self.catch_regs.pop();
            // finally runs after the catch too
            if (fc) |f| try self.body(f, 0);
            self.da = DaState.meet(da_norm, self.da);
        } else if (fc) |f| {
            // finally with no catch: run the cleanup, then let the error
            // continue outward. Swallowing it here would turn a `finally`
            // into an accidental `catch`, which is the one thing this
            // construct must never do.
            try self.body(f, 0);
            // A RETHROW, and `finally` is ours, not Ring's, so there is
            // no Ring answer to match. It keeps the origin it had.
            _ = try self.emit(.trap, errl.reg, 1, 0, 0);
            // the error path ends in the rethrow: only the normal one goes on
            self.da = da_norm;
        } else {
            self.da = da_norm;
        }
        self.land(over);
    }

    /// `switch x / on v ... / other ... / off`. No fallthrough on 1.27 --
    /// each `on` is exclusive -- and it matches numbers, strings and
    /// symbols alike. The subject is evaluated ONCE; Ring's own
    /// implementation re-reads it per clause, which is where a switch over
    /// a function call would differ.
    fn switchStmt(self: *Compiler, n: ts.Node) Error!void {
        const save = self.temp;
        defer self.temp = save;

        const subj = try self.tmp();
        try self.expr(n.namedChild(0), subj);
        // Every nested statement resets self.temp to the top of the locals,
        // which is BELOW subj -- so without a floor a clause body reuses the
        // subject's register and the next test compares it against itself.
        // (That is exactly what happened: jne a=2 b=2, always equal.)
        const saved_floor = self.floor;
        defer self.floor = saved_floor;
        self.floor = @max(self.floor, subj + 1);

        var ends = std.ArrayListUnmanaged(u32){};
        defer ends.deinit(self.scratch);

        // definite assignment (F-89): every clause starts from what held
        // after the subject; they meet after the switch, with the no-match
        // path when there is no `other`
        const da_in = self.da;
        var da_out: ?DaState = null;
        var has_other = false;
        defer {
            var r = da_out orelse da_in;
            if (!has_other) r = DaState.meet(r, da_in);
            self.da = r;
        }

        var c: u32 = 1;
        while (c < n.namedChildCount()) : (c += 1) {
            const cl = n.namedChild(c);
            const ck = cl.kind();
            if (std.mem.eql(u8, ck, "comment")) continue;

            if (std.mem.eql(u8, ck, "other_clause")) {
                self.da = da_in;
                try self.body(cl, 0);
                da_out = if (da_out) |o| DaState.meet(o, self.da) else self.da;
                has_other = true;
                continue;
            }
            if (!std.mem.eql(u8, ck, "case_clause")) return self.nope(cl);
            if (cl.namedChildCount() == 0) return self.nope(cl);
            self.da = da_in;

            // `on 1, 2, 3` matches ANY of the values.
            //
            // On 1.27 the same line matches only the FIRST -- M(1) is 100
            // while M(2) and M(3) fall silently to `other` -- and the
            // grammar had no notion of the form either, parsing the commas
            // into an empty identifier and stray statements. The front end
            // now has a `case_values` rule, so there is a correct tree to
            // compile and this is the reading every comparable language
            // gives it (Ruby's `when 1, 2`, Python's `case 1 | 2`).
            //
            // A superset: no WORKING Ring program changes meaning, because
            // a program relying on values 2 and 3 falling through was
            // already not doing what it said.
            const vals = cl.namedChild(0);
            if (!std.mem.eql(u8, vals.kind(), "case_values")) return self.nope(cl);
            const nvals = vals.namedChildCount();
            if (nvals == 0) return self.nope(cl);

            var hits = std.ArrayListUnmanaged(u32){};
            defer hits.deinit(self.scratch);
            var skip: u32 = 0;
            var vi: u32 = 0;
            while (vi < nvals) : (vi += 1) {
                self.temp = self.floor;
                const val = try self.tmp();
                try self.expr(vals.namedChild(vi), val);
                if (vi + 1 == nvals) {
                    // the last value: a miss skips the whole clause
                    skip = try self.emit(.jne, subj, val, 0, 0);
                } else {
                    // any earlier hit jumps straight into the body
                    try hits.append(self.scratch, try self.emit(.jeq, subj, val, 0, 0));
                }
            }
            self.temp = self.floor;
            for (hits.items) |h| self.land(h);

            self.da = da_in;
            try self.body(cl, 1);
            da_out = if (da_out) |o| DaState.meet(o, self.da) else self.da;
            try ends.append(self.scratch, try self.emit(.jmp, 0, 0, 0, 0));
            self.land(skip);
        }
        for (ends.items) |p| self.land(p);
    }

    fn ifStmt(self: *Compiler, n: ts.Node, ln_need: bool) Error!void {
        var ends = std.ArrayListUnmanaged(u32){};
        defer ends.deinit(self.scratch);
        const if_start = self.here();
        // F-110: whether the statement after this if loses its line marker
        // on Ring, and so each branch's end-jump carries the branch's line --
        // when something can read it: a statement after it in its block, or
        // an enclosing if's branch it ends (whose jump it then skips)
        const quirk = ln_need and !linesStatic() and ifMergesNext(n);
        // the clause after child i: the `but`/`else` that ends the branch
        const nextClause = struct {
            fn f(node: ts.Node, after: u32) ?ts.Node {
                var k: u32 = after + 1;
                while (k < node.namedChildCount()) : (k += 1) {
                    const ck = node.namedChild(k).kind();
                    if (std.mem.eql(u8, ck, "elseif_clause") or std.mem.eql(u8, ck, "else_clause")) return node.namedChild(k);
                }
                return null;
            }
        }.f;

        var nofire = std.ArrayListUnmanaged(u32){};
        defer nofire.deinit(self.scratch);
        try self.cond(n.namedChild(0), &nofire);
        // definite assignment (F-89): each branch starts from what held
        // after the condition, and the branches MEET after the statement --
        // with the fall-through when there is no else
        const da_in = self.da;
        self.ln_block_quirk = quirk;
        try self.body(n, 1);
        var da_out = self.da;
        try ends.append(self.scratch, try self.branchEnd(n, 1, nextClause(n, 0), quirk));
        for (nofire.items) |p| self.land(p);

        var has_else = false;
        var i: u32 = 1;
        while (i < n.namedChildCount()) : (i += 1) {
            const ch = n.namedChild(i);
            if (std.mem.eql(u8, ch.kind(), "elseif_clause")) {
                self.da = da_in;
                var nf = std.ArrayListUnmanaged(u32){};
                defer nf.deinit(self.scratch);
                try self.cond(ch.namedChild(0), &nf);
                self.ln_block_quirk = quirk;
                try self.body(ch, 1);
                da_out = DaState.meet(da_out, self.da);
                try ends.append(self.scratch, try self.branchEnd(ch, 1, nextClause(n, i), quirk));
                for (nf.items) |p| self.land(p);
            } else if (std.mem.eql(u8, ch.kind(), "else_clause")) {
                self.da = da_in;
                self.ln_block_quirk = quirk;
                try self.body(ch, 0);
                da_out = DaState.meet(da_out, self.da);
                has_else = true;
                // the else body falls through onto the merged marker, which
                // Ring runs: whatever an earlier pass through a branch left
                // for this depth is cleared (line 0)
                if (quirk) {
                    try ends.append(self.scratch, try self.emit(.jmpl, 0, 0, 0, 0));
                    _ = try self.emit(.lnhi, 0, 0, 0, 0);
                }
            }
        }
        self.da = if (has_else) da_out else DaState.meet(da_out, da_in);
        for (ends.items) |p| self.land(p);
        if (quirk) self.ln_pend = .{ .start = if_start, .end = self.here(), .level = self.stmt_level -| 1 };
    }

    /// `exit N` and `loop N`: which enclosing loop, counted outward from 1.
    /// Measured on both 1.27 builds (bench/exec/exit_levels.ring): `exit 2`
    /// leaves two loops, `exit 3` three, `loop 2` continues the outer loop
    /// with the inner one abandoned. The number was IGNORED until
    /// 2026-09-26 -- every `exit 2` left one loop, so stzNatural's object
    /// scan (`exit 2` on the first literal) ran on to the next creation and
    /// built the second object in place of the first.
    fn loopLevel(self: *Compiler, n: ts.Node, depth: usize) Error!usize {
        var lv: usize = 1;
        if (n.namedChildCount() > 0) {
            const nn = n.namedChild(0);
            if (!std.mem.eql(u8, nn.kind(), "number")) return self.nope(n);
            const v = std.fmt.parseInt(usize, std.mem.trim(u8, nn.text(), " \t\r\n"), 10) catch return self.nope(n);
            lv = if (v == 0) 1 else v;
        }
        if (lv > depth) return self.nopeKind(n, "exit or loop names more loops than enclose it");
        return lv;
    }

    fn whileStmt(self: *Compiler, n: ts.Node) Error!void {
        try self.breaks.append(self.alloc, .{});
        try self.loop_try.append(self.alloc, self.try_open);
        try self.continues.append(self.alloc, .{});
        const top = self.here();
        var nofire = std.ArrayListUnmanaged(u32){};
        defer nofire.deinit(self.scratch);
        try self.cond(n.namedChild(0), &nofire);
        // the body may run no times: nothing it assigns holds after (F-89)
        const da_in = self.da;
        try self.body(n, 1);
        self.da = da_in;
        // `loop` in a while re-tests the condition
        var cont = self.continues.pop().?;
        for (cont.items) |p| self.code.items[p].d = @intCast(top);
        cont.deinit(self.alloc);
        _ = try self.emit(.jmp, 0, 0, 0, @intCast(top));
        for (nofire.items) |p| self.land(p);
        _ = self.loop_try.pop();
        var brk = self.breaks.pop().?;
        for (brk.items) |p| self.land(p);
        brk.deinit(self.alloc);
    }

    /// `do <body> again <cond>` -- Ring's POST-test loop, and the only loop
    /// whose test is the LAST child rather than the first.
    ///
    /// Measured on 1.27, `bench/exec/do_again.ring`: the body runs at least
    /// once (`j = 10` with `again j < 3` still prints 11 and stops), the
    /// condition is tested AFTER the body and the loop repeats while it is
    /// TRUE, `exit` leaves it, and `loop` RESTARTS THE BODY without testing
    /// the condition. This said "jumps to the RE-TEST", from a probe whose
    /// condition was still true at the `loop`, where the two answers agree;
    /// with `loop` while the condition is false Ring runs the body again
    /// (F-125, 2026-10-14: k=10 where the re-test gave 5), and its parser
    /// sets the loop mark to the body's own label (stmt.c, `nMark1`).
    ///
    /// It is not an exotic construct: RING'S OWN STANDARD LIBRARY uses it
    /// twice, in `Split()`, and the estate loads `stdlibcore.ring` on every
    /// program. That whole function was refused until this landed.
    fn doAgainStmt(self: *Compiler, n: ts.Node) Error!void {
        const nc = n.namedChildCount();
        if (nc == 0) return self.nope(n);
        try self.breaks.append(self.alloc, .{});
        try self.loop_try.append(self.alloc, self.try_open);
        try self.continues.append(self.alloc, .{});
        const top = self.here();
        // the body runs once at least, but an `exit` in it can leave early;
        // what held before the loop is what holds after it (F-89, cautious:
        // a read it is wrong about costs a check, never an error)
        const da_in = self.da;
        try self.bodyTo(n, 0, nc - 1);
        self.da = da_in;
        const retest = self.here();
        var nofire = std.ArrayListUnmanaged(u32){};
        defer nofire.deinit(self.scratch);
        // `cond` falls through when TRUE and jumps to `nofire` when false,
        // which is the loop's exit -- the mirror of whileStmt, where the
        // same two edges lead the other way round.
        try self.cond(n.namedChild(nc - 1), &nofire);
        _ = try self.emit(.jmp, 0, 0, 0, @intCast(top));
        for (nofire.items) |p| self.land(p);
        var cont = self.continues.pop().?;
        for (cont.items) |p| self.code.items[p].d = @intCast(top);
        cont.deinit(self.alloc);
        _ = retest;
        _ = self.loop_try.pop();
        var brk = self.breaks.pop().?;
        for (brk.items) |p| self.land(p);
        brk.deinit(self.alloc);
    }

    fn forStmt(self: *Compiler, n: ts.Node) Error!void {
        // for_statement children (named): var, from, to, [step], body...
        const v = n.namedChild(0);
        const from = n.namedChild(1);
        const to = n.namedChild(2);

        // Is there a `step`? The keyword is anonymous, so look for it.
        var has_step = false;
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) {
            if (std.mem.eql(u8, n.child(i).kind(), "step")) has_step = true;
        }
        const step_node = if (has_step) n.namedChild(3) else to;
        const body_from: u32 = if (has_step) 4 else 3;

        // Rule A: a `$` name is a GLOBAL, even as a loop variable. The
        // counter lives in a hidden temporary and the global slot is written
        // at the top of every iteration, so a read anywhere in the body sees
        // it. Before this the variable was defined as a LOCAL named "$x",
        // and the identifier path checks `$` -> global BEFORE locals: an
        // arithmetic operand found the counter register while a list
        // element read the slot the loop never wrote. Two answers for one
        // name in one statement -- and 200,000 pairs with nil values.
        const vname = v.text();
        const var_is_global = vname.len > 1 and vname[0] == '$';
        // And an `@` name is an ATTRIBUTE, even as a loop variable -- the
        // same shape. It was defined as a LOCAL named "@i" here while every
        // read in the body went to the attribute slot, which the loop never
        // wrote: `for @i = 1 to This.CaptureCount()` in stzRegex passed nil
        // to the engine on every iteration, silently, until gattr began
        // raising R24 on a nil slot and three tests stopped on line 852.
        // On Ring `@i` in a method is a plain local; under Rule A it is
        // the attribute, so the attribute is what the loop drives.
        // In a CLASS REGION a bare loop variable is the object's attribute
        // too (F-121: Ring lists `i` among attributes() after `for i = 1 to 3`
        // in the class body, holding 4), so it is driven the same way.
        const region_attr = vname.len > 0 and vname[0] != '$' and vname[0] != '@' and
            std.mem.eql(u8, self.cur.name, PROLOGUE) and self.lookup(vname) == null and self.declaredAttr(vname) != null;
        const var_is_attr = (vname.len > 1 and vname[0] == '@') or region_attr;
        const hidden_ctr = var_is_global or var_is_attr;
        var gslot: i32 = 0;
        var aslot: u32 = 0;
        var ctr: u8 = 0;
        if (var_is_global) {
            gslot = try self.globalSlot(vname);
            self.temp = @max(self.floor, self.localsTop());
            ctr = try self.tmp();
        } else if (var_is_attr) {
            aslot = (if (region_attr) self.declaredAttr(vname) else self.attrSlot(vname)) orelse return self.nopeKind(v, "@attribute outside a class");
            self.temp = @max(self.floor, self.localsTop());
            ctr = try self.tmp();
        } else {
            // the seeded local (low register, classified) the first time the
            // name loops; a fresh one from the temp pool once it was retired
            if (self.loopVarInUse(vname))
                return self.nopeKind(v, "this loop reuses the variable of a loop it sits inside -- on Ring they are one variable and the outer index is destroyed");
            self.unretire(vname);
            const l = try self.define(vname);
            ctr = l.reg;
            // temporaries stay above the variable for the whole loop
            self.temp = @max(self.temp, ctr + 1);
            // The counter is classed an integer, as the classify pass always
            // did: a float loop (`1.5 to 3.5`) is still an unboxed scalar and
            // every opcode checks the tag at run time, so the class is safe,
            // and it is what keeps Sieve's `aFlag[i]` on the typed paths
            // (55 ms; classing it unknown measured 92).
            //
            // BUT NOT OVER A WIDER CLASS. The classifier joins every write to
            // the name, and a loop variable the function ALSO assigns a value
            // of another kind -- stzMathDiagram._MintShape loops `for _v_ = 1
            // to _nV_` and later does `_v_ = This._Prop(...)`, any value -- is
            // a reference there. Forcing int here mid-codegen made every read
            // compiled after this point an unboxed, uncounted copy of whatever
            // the register held. Harmless while an integer store overwrote a
            // register without releasing it; since it releases (F-118's leak
            // fix), it released those uncounted copies and freed a string
            // still in a list: three graphics tests died at a frame sweep
            // (choropleth, gantt, seating; 2026-10-14). A boxed class stays.
            if (!l.class.boxed()) l.class = .int;
        }
        const limit = try self.tmp();
        const stepr = if (has_step) try self.tmp() else 0;
        // Hold the bound (and step) above the body's temporaries.
        const saved_floor = self.floor;
        defer self.floor = saved_floor;
        self.floor = @max(self.floor, if (has_step) stepr + 1 else limit + 1);

        try self.expr(from, ctr);
        if (!hidden_ctr) self.daWrite(ctr);
        try self.expr(to, limit);
        if (has_step) {
            try self.expr(step_node, stepr);
            _ = try self.emit(.forprep, ctr, limit, stepr, 1);
        } else {
            // forprep starts one below (forloop increments before testing)
            // and makes a float bound an integer one for an integer counter,
            // so the loop opcode checks one tag per iteration.
            _ = try self.emit(.forprep, ctr, limit, 0, 0);
        }

        if (!hidden_ctr) try self.active_loops.append(self.alloc, vname);
        defer if (!hidden_ctr) {
            _ = self.active_loops.pop();
        };
        try self.breaks.append(self.alloc, .{});
        try self.loop_try.append(self.alloc, self.try_open);
        try self.continues.append(self.alloc, .{});
        const fj = try self.emit(.jmp, 0, 0, 0, 0);
        const bodyat = self.here();
        // the global (or the attribute) sees the counter before the body
        // reads it, every time
        if (var_is_global) _ = try self.emit(.gset, ctr, 0, 0, gslot);
        if (var_is_attr) _ = try self.emit(.sattr, 0, ctr, 0, @intCast(aslot));
        // the body may run no times (F-89)
        const da_in = self.da;
        try self.body(n, body_from);
        self.da = da_in;
        // `loop` in a for jumps to the step/test instruction, which the
        // forward jump also targets.
        var cont = self.continues.pop().?;
        for (cont.items) |p| self.code.items[p].d = @intCast(self.here());
        cont.deinit(self.alloc);
        self.land(fj);
        if (has_step) {
            _ = try self.emit(.forloops, ctr, limit, stepr, @intCast(bodyat));
        } else {
            _ = try self.emit(.forloop, ctr, limit, 0, @intCast(bodyat));
        }
        // AFTER THE LOOP the variable holds the value that FAILED the test
        // -- n+1 for `1 to n` -- on Ring (probed: 4 after `for x = 1 to 3`).
        // The top-of-body store never sees that value, so it is written
        // here, on the fall-through only: an `exit` jumps past this and the
        // variable keeps the value it had at the exit, which is Ring's
        // answer for that path too.
        if (var_is_global) _ = try self.emit(.gset, ctr, 0, 0, gslot);
        if (var_is_attr) _ = try self.emit(.sattr, 0, ctr, 0, @intCast(aslot));
        _ = self.loop_try.pop();
        var brk = self.breaks.pop().?;
        for (brk.items) |p| self.land(p);
        brk.deinit(self.alloc);
        if (!hidden_ctr) try self.retire(vname);
    }

    /// `for x in c ... next`, as Ring 1.27 runs it (measured 2026-09-11,
    /// bench/exec/forin.ring): x IS the element -- assigning x writes the
    /// list, a nested row writes through -- the container is re-measured
    /// every iteration so an append during the loop is iterated, a string
    /// iterates by character, an empty container runs nothing. After the
    /// loop the variable is gone (C-11; Ring leaves "" here and the last
    /// element after an exit -- two more of 2.12's rules).
    ///
    /// `for x in c step n` (stepinforinloop.ring, F-119): the grammar gives
    /// the step as a third named child, and the body used to start at that
    /// child -- so the step was compiled as the body's first STATEMENT: a
    /// literal discarded, a variable refused, and every element visited. Ring
    /// evaluates the step ONCE, before the loop (its code is inserted ahead
    /// of the loop's label, stmt.c ring_parser_step), starts the index at 1,
    /// re-measures the container every turn, and leaves when the step is 0,
    /// or when it is negative and the index is below the length, or positive
    /// and above it (vmjump.c ring_vm_jumpfor) -- so `step -1` over two or
    /// more elements runs nothing and over one runs once. A fractional step
    /// keeps a fractional index and reads the element at its integer part.
    fn forInStmt(self: *Compiler, n: ts.Node) Error!void {
        const v = n.namedChild(0);
        const src = n.namedChild(1);
        var has_step = false;
        {
            var ci: u32 = 0;
            while (ci < n.childCount()) : (ci += 1) {
                if (std.mem.eql(u8, n.child(ci).kind(), "step")) has_step = true;
            }
        }
        const body_from: u32 = if (has_step) 3 else 2;
        const vname = v.text();
        // the loop's bound is tested at the BOTTOM, after the body, so it took
        // the body's last line; Ring reports a bad container at the `for`
        // line (F-105)
        const for_row = self.cur_row;
        const for_file = self.cur_file;
        if (vname.len > 0 and (vname[0] == '$' or vname[0] == '@'))
            return self.nopeKind(v, "for-in over a $global or @attribute variable");
        if (self.loopVarInUse(vname))
            return self.nopeKind(v, "this loop reuses the variable of a loop it sits inside -- on Ring they are one variable and the outer index is destroyed");
        self.unretire(vname);
        const l = try self.define(vname);
        const xr = l.reg;
        self.temp = @max(self.temp, xr + 1);
        // the container: a plain variable's own register (so an append inside
        // the body is seen), otherwise the value in a pinned temporary
        var holder: u8 = 0;
        var lst: u8 = 0;
        var idx: u8 = 0;
        var lim: u8 = 0;
        var stp: u8 = 0;
        const saved_floor = self.floor;
        defer self.floor = saved_floor;
        if (has_step) {
            // the step first, as Ring runs it: evaluated once, then checked by
            // forprep (a list R28, text that is no number R41, text that is
            // one converted), which also puts the index one step below 1
            stp = try self.tmp();
            idx = try self.tmp();
            lim = try self.tmp();
            try self.expr(n.namedChild(2), stp);
            _ = try self.emit(.loadi, idx, 0, 0, 1);
            _ = try self.emit(.loadi, lim, 0, 0, 0);
            _ = try self.emit(.forprep, idx, lim, stp, 1);
            holder = try self.tmp();
            lst = try self.borrowOperand(src, holder);
            self.floor = @max(self.floor, @max(holder, lim) + 1);
        } else {
            holder = try self.tmp();
            lst = try self.borrowOperand(src, holder);
            idx = try self.tmp();
            lim = try self.tmp();
            self.floor = @max(self.floor, lim + 1);
            _ = try self.emit(.loadi, idx, 0, 0, 0);
        }
        try self.active_loops.append(self.alloc, vname);
        defer _ = self.active_loops.pop();
        try self.breaks.append(self.alloc, .{});
        try self.loop_try.append(self.alloc, self.try_open);
        try self.continues.append(self.alloc, .{});
        // (a step of 0 leaves at once: `forloops` tests it, after the
        // container's own check below, in Ring's order)
        const fj = try self.emit(.jmp, 0, 0, 0, 0);
        const bodyat = self.here();
        _ = try self.emit(.iget, xr, lst, idx, 0);
        // x is assigned at the top of every iteration; the body may run no
        // times at all (F-89)
        const da_in = self.da;
        self.daWrite(xr);
        try self.body(n, body_from);
        self.da = da_in;
        var cont = self.continues.pop().?;
        for (cont.items) |p| self.code.items[p].d = @intCast(self.here());
        cont.deinit(self.alloc);
        _ = try self.emit(.vsetq, lst, idx, xr, 0);
        self.land(fj);
        self.cur_row = for_row;
        self.cur_file = for_file;
        // d = 2: a for-in's bound, R29 on what is no container (F-105)
        _ = try self.emit(.dlen, lim, lst, 0, 2);
        if (has_step) {
            _ = try self.emit(.forloops, idx, lim, stp, @intCast(bodyat));
        } else {
            _ = try self.emit(.forloop, idx, lim, 0, @intCast(bodyat));
        }
        _ = self.loop_try.pop();
        var brk = self.breaks.pop().?;
        for (brk.items) |p| self.land(p);
        brk.deinit(self.alloc);
        try self.retire(vname);
    }
};

// ============================================================ driver ===

/// Ring's annotation vocabulary. Anything unrecognised says nothing rather
/// than claiming something wrong.
fn classOfTypeName(t: []const u8) Class {
    if (std.ascii.eqlIgnoreCase(t, "int")) return .int;
    if (std.ascii.eqlIgnoreCase(t, "number")) return .int;
    if (std.ascii.eqlIgnoreCase(t, "list")) return .list;
    if (std.ascii.eqlIgnoreCase(t, "string")) return .str;
    return .unknown;
}

fn isFuncDef(n: ts.Node) bool {
    return std.mem.eql(u8, n.kind(), "function_definition");
}

var last_fail: struct {
    kind: []const u8 = "",
    row: u32 = 0,
    text: []const u8 = "",
    func: []const u8 = "",
} = .{};

pub fn reportFailure(e: anyerror) void {
    if (last_fail.kind.len == 0) {
        std.debug.print("compile failed: {s}\n", .{@errorName(e)});
        return;
    }
    std.debug.print("compile failed ({s}); last refusal was {s} at line {d}", .{ @errorName(e), last_fail.kind, last_fail.row });
    if (last_fail.func.len > 0) std.debug.print(" in {s}", .{last_fail.func});
    std.debug.print("\n    {s}\n", .{last_fail.text});
}

fn distinctNames(xs: []const u16) usize {
    var n: usize = 0;
    outer: for (xs, 0..) |x, i| {
        for (xs[0..i]) |y| if (x == y) continue :outer;
        n += 1;
    }
    return n;
}

pub const NativeName = struct { name: []const u8, sites: u32 };

pub const Census = struct {
    /// Call sites compiled as native calls, awaiting a LoadLib.
    native_sites: usize = 0,
    /// Distinct names among them.
    native_names: usize = 0,
    /// Every one of them, with its site count -- `rnxc census <root>
    /// --natives`. A name nobody defines compiles to a call resolved at RUN
    /// time against the engine's registry, so a Ring builtin Ring++ lacks
    /// (`dir`, `date`) surfaces only as an R3 when it runs; this is where
    /// the whole list of them can be read before anything runs.
    native_list: []NativeName = &.{},
    classes: usize,
    methods: usize,
    stmts_ok: u32,
    stmts_bad: u32,
    emit_failed: u32 = 0,
    /// functions whose locals share registers (shareFunction), and the registers saved
    shared_funcs: u32 = 0,
    shared_saved: u32 = 0,
    refusals: []Refusal,
    /// `new K` of a class the unit does not define -- COMPILED, to Ring's
    /// run-time R11, and counted here so a typo still shows (absentClass).
    absent_classes: []Refusal = &.{},
};

/// Compile for measurement rather than for running: every refusal is
/// recorded and the next statement is tried anyway, so one pass produces the
/// whole catalogue of what a real module needs.
pub fn census(alloc: std.mem.Allocator, roots: []const ts.Node) !Census {
    var c = Compiler{ .alloc = alloc, .census = true };
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    c.scratch_arena = &scratch_arena;
    c.scratch = scratch_arena.allocator();
    last_fail = .{};
    var tmr = std.time.Timer.start() catch unreachable;
    for (roots) |r| try collectAll(&c, r, alloc);
    try resolveAllSlots(&c, alloc);
    census_ns[0] = tmr.lap();
    capAt(0);
    // Ring runs a loaded file's top level AT the load statement, so the
    // per-file blocks collected above are in the wrong order until this
    // splices them.
    try spliceMain(&c, roots, 0, alloc);
    // RESERVE THE THREE PARALLEL STREAMS BEFORE EMITTING.
    //
    // The compiler allocates from a bump arena, which never reclaims: every
    // time an ArrayList doubles, the buffer it outgrew stays resident for the
    // life of the process. Measured on the Softanza unit with a counting
    // allocator (2026-09-13): 407 MB asked for against about 35 MB of
    // finished structures, and 209 MB of that in the 784 allocations of
    // 64 KB and up -- which is what doubling looks like from the outside.
    //
    // The statement count is known here, and the ratio of instructions to
    // statements is stable at about nine, so one reservation replaces the
    // whole doubling ladder. Over-reserving costs untouched pages; the arena
    // would have committed them on the way up anyway.
    {
        var nstmt: usize = 0;
        for (c.funcs.items) |f| nstmt += f.stmts.items.len;
        const guess = nstmt * 12 + 1024;
        c.code.ensureTotalCapacity(alloc, guess) catch {};
        c.rows.ensureTotalCapacity(alloc, guess) catch {};
        c.files.ensureTotalCapacity(alloc, guess) catch {};
    }

    census_ns[1] = tmr.lap();
    capAt(1);

    // The census must run the pipeline the COMPILER runs, or it measures
    // something nobody ships. That means pass A, the classify fixpoint,
    // and then pass B -- which is where anything needing proof (a
    // specialised vget, a provable receiver class, classname) can finally
    // compile. Counting pass A alone understated every one of those.
    try emitAll(&c);
    census_ns[2] = tmr.lap();
    capAt(2);

    for (c.funcs.items) |*f| {
        for (f.params, 0..) |p, pi| {
            if (pi >= f.hints.len or f.hints[pi] == .unknown) continue;
            for (f.locals.items) |*l| {
                if (std.ascii.eqlIgnoreCase(l.name, p)) {
                    l.class = f.hints[pi];
                    l.declared = true;
                    if (l.class == .list) l.elem = .int;
                }
            }
        }
    }
    openElems(&c, c.prefix_funcs);
    var round: u32 = 0;
    while (round < 8) : (round += 1) {
        var changed = classifyRound(&c) catch false;
        // After round 0 every call site has been seen, so `called` is final
        // and one widening pass is enough. It must happen HERE, with rounds
        // left to run, so a widened parameter reaches its callees.
        if (round == 0) changed = widenEntryParams(&c, 0) or changed;
        if (!changed) break;
    }
    census_ns[3] = tmr.lap();
    capAt(3);
    census_ns[5] = round;

    // pass B is the measurement; pass A's tallies are discarded
    c.code.clearRetainingCapacity();
    c.fixups.clearRetainingCapacity();
    c.refusals.clearRetainingCapacity();
    c.absent_classes.clearRetainingCapacity();
    c.stmts_ok = 0;
    c.stmts_bad = 0;
    c.emit_failed = 0;
    c.stmts_native = 0;
    c.natives.clearRetainingCapacity();
    for (c.funcs.items) |*f| {
        f.poisoned = false;
        f.calls_named.clearRetainingCapacity();
        f.calls_static.clearRetainingCapacity();
    }
    try emitAll(&c);
    census_ns[4] = tmr.lap();
    capAt(4);
    {
        var locals: usize = 0;
        var stmts: usize = 0;
        var cap_locals: usize = 0;
        for (c.funcs.items) |f| {
            locals += f.locals.items.len;
            cap_locals += f.locals.capacity;
            stmts += f.stmts.items.len;
        }
        sizes[4] = c.code.items.len;
        sizes[5] = locals;
        sizes[6] = cap_locals;
        sizes[7] = stmts;
    }
    return .{
        .classes = c.classes.items.len,
        .methods = c.funcs.items.len,
        .stmts_ok = c.stmts_ok,
        .stmts_bad = c.stmts_bad,
        .emit_failed = c.emit_failed,
        .shared_funcs = c.shared_funcs,
        .shared_saved = c.shared_saved,
        .refusals = c.refusals.items,
        .absent_classes = c.absent_classes.items,
        .native_sites = c.stmts_native,
        .native_names = distinctNames(c.natives.items),
        .native_list = try nativeList(&c, alloc),
    };
}

fn nativeList(c: *Compiler, alloc: std.mem.Allocator) ![]NativeName {
    var counts = std.AutoHashMapUnmanaged(u16, u32){};
    defer counts.deinit(alloc);
    for (c.natives.items) |ni| {
        const gop = try counts.getOrPut(alloc, ni);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }
    var out = std.ArrayListUnmanaged(NativeName){};
    var it = counts.iterator();
    while (it.next()) |kv| {
        try out.append(alloc, .{ .name = c.names.items[kv.key_ptr.*], .sites = kv.value_ptr.* });
    }
    return out.toOwnedSlice(alloc);
}

pub fn compileLenient(alloc: std.mem.Allocator, roots: []const ts.Node) !Program {
    return compileWith(alloc, roots, true, false);
}

pub fn compile(alloc: std.mem.Allocator, roots: []const ts.Node) !Program {
    return compileWith(alloc, roots, false, false);
}

/// Lenient, plus the poison ranking and the refusal text that explains
/// each root. Costs one bitset per function, so it is its own entry point.
pub fn compileRanked(alloc: std.mem.Allocator, roots: []const ts.Node) !Program {
    return compileWith(alloc, roots, true, true);
}

/// THE RESOLVED GRAPH, READ OUT (haro/CODEGRAPH.md, rung 4: L2). What the compiler resolved while it emitted -- every function and method,
/// every class with its parent, every call it bound to ONE target (`fixups`: a plain function, a method whose receiver it proved) and
/// every call it could only dispatch by NAME (`calls_named`) -- before the program is finished and the tables are thrown away. Nothing
/// here is a second resolver: the edges are the ones the code was emitted with, so `rnxc graph` cannot disagree with the compiler.
/// Lenient, like the census: a statement that does not compile poisons its function and contributes no edges (the others do), and the
/// poisoned functions are marked, never hidden.
pub const GraphData = struct {
    funcs: []const Func,
    classes: []const ClassInfo,
    fixups: []const Fixup,
    names: []const []const u8,
};

pub fn graphData(alloc: std.mem.Allocator, roots: []const ts.Node) !GraphData {
    var c = Compiler{ .alloc = alloc, .lenient = true, .rank = false, .census = false };
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    c.scratch_arena = &scratch_arena;
    c.scratch = scratch_arena.allocator();
    last_fail = .{};
    try compileFront(&c, roots, roots, 0, alloc);
    return .{ .funcs = c.funcs.items, .classes = c.classes.items, .fixups = c.fixups.items, .names = c.names.items };
}

fn compileWith(alloc: std.mem.Allocator, roots: []const ts.Node, lenient: bool, rank: bool) !Program {
    // `census` is what records refusals, and the ranking has to name WHY
    // each root failed or it is a list of function names and nothing more.
    var c = Compiler{ .alloc = alloc, .lenient = lenient, .rank = rank, .census = rank, .rank_verbose = rank };
    var scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    c.scratch_arena = &scratch_arena;
    c.scratch = scratch_arena.allocator();
    last_fail = .{};
    errdefer last_fail = .{
        .kind = c.fail_kind,
        .row = c.fail_row,
        .text = c.fail_text,
        .func = c.fail_fn,
    };

    try compileFront(&c, roots, roots, 0, alloc);
    return compileFinish(&c, alloc);
}

/// THE LIBRARY, COMPILED ONCE.
///
/// Everything compileWith does except the last step -- the trampolines, the
/// call patching and the object-model tables, which can only be built when
/// the whole program is known. The compiler is kept, its marks set, and a
/// file is compiled ON TOP of it by compileOnto.
///
/// The caller owns `c` and the arena it was given; both must outlive every
/// compileOnto against it.
pub fn compilePrefix(c: *Compiler, roots: []const ts.Node, alloc: std.mem.Allocator) Error!void {
    last_fail = .{};
    // roots[0] is the file that will be compiled ON TOP. The prefix is
    // everything it loads, spliced from the first of them.
    if (roots.len < 2) return;
    try compileFront(c, roots[1..], roots, 1, alloc);
    markPrefix(c);
}

/// The same, for a library compiled ON ITS OWN -- `rnxc prefix stzBase.ring`,
/// where every file of the unit belongs to the prefix and the splice starts
/// at the root like any other compile.
pub fn compilePrefixWhole(c: *Compiler, roots: []const ts.Node, alloc: std.mem.Allocator) Error!void {
    last_fail = .{};
    try compileFront(c, roots, roots, 0, alloc);
    markPrefix(c);
}

fn markPrefix(c: *Compiler) void {
    c.prefix_funcs = c.funcs.items.len;
    c.prefix_classes = c.classes.items.len;
    c.prefix_code = c.code.items.len;
    c.prefix_fixups = c.fixups.items.len;
    // The library's top level is finished. The file compiled on top gets a
    // @@main of its own, and the entry runs the library's and then that one
    // -- which is the order Ring runs them in when the file's first
    // statement is the `load`, and rnxc refuses the prefix when it is not.
    c.prefix_main = c.main_fn;
    c.main_fn = null;
}

/// One file compiled on top of a prefix. Everything below the marks is left
/// exactly as it was; this collects, classifies and emits the file's own
/// functions, classes and top level, and then finishes the program.
///
/// Returns `error.PrefixInapplicable` when this file is one of the cases a
/// prefix cannot answer for. The caller then compiles the unit whole, which
/// is what it did before prefixes existed -- so the fallback is never worse
/// than the old behaviour, only slower than the fast case.
pub fn compileOnto(c: *Compiler, roots: []const ts.Node, start: u32, alloc: std.mem.Allocator) Error!Program {
    last_fail = .{};
    // Everything from `start` is ON TOP: the file named on the command line
    // and whatever it loads that the prefix does not already carry -- every
    // narrated test in the estate loads the library and then the harness.
    // Below `start` sit the library's entries, parallel to load_paths so a
    // load resolves to the right index, and never walked.
    for (roots[start..]) |r| try collectAll(c, r, alloc);
    try resolveAllSlots(c, alloc);
    if (roots.len - start > 1) try spliceMain(c, roots, start, alloc);
    try prefixApplies(c, roots, start, alloc);
    try compileFrontAfterCollect(c, alloc);
    return compileFinish(c, alloc);
}

/// THE TWO WAYS A FILE CAN MEAN SOMETHING DIFFERENT ON TOP OF A PREFIX than
/// it would in a whole-unit compile. Both are about NAMES, and both are
/// checked after this file's definitions are collected and before a single
/// instruction is emitted for them.
///
///   1. A name defined BOTH here and in the library. Collecting a whole unit
///      starts at the root FILE, so the root's definition is collected first
///      and Ring's "the first definition wins" makes it the one that runs --
///      everywhere, the library included. On top of a prefix the library's
///      was collected first, so the winner would change.
///
///   2. A name this file defines that the library CALLED and could not
///      resolve. In a whole-unit compile that call links here; against a
///      prefix it was already compiled as a deferred native and would raise
///      at run time.
///
/// Neither is common -- no Softanza test does either -- and both are cheap
/// to ask. A wrong answer is not worth the milliseconds saved.
/// The name that made the last prefix inapplicable, so the fallback can
/// say WHICH one rather than only that there was one.
pub var prefix_blocked_by: []const u8 = "";

fn prefixApplies(c: *Compiler, roots: []const ts.Node, start: u32, alloc: std.mem.Allocator) Error!void {
    prefix_blocked_by = "";
    if (c.prefix_funcs == 0) return;

    // THE ORDER THE TOP LEVEL RUNS IN, checked by building it rather than by
    // reasoning about it.
    //
    // Ring runs a loaded file's top level AT the load statement, so a file
    // that prints before it loads, or loads twice with code in between,
    // interleaves its own statements with the library's -- and a prefix
    // cannot interleave, it can only come first. Splitting `bench/exec/
    // load_order.ring` this way printed "B inside the loaded file" where
    // Ring prints "A before load" first, which is how this check came to
    // exist rather than the rule of thumb that was here.
    //
    // So: the whole unit's splice order is computed, and the prefix applies
    // only if it is exactly the library's statements followed by this
    // file's. Node identity is (source pointer, start byte).
    // Only when the library's own trees are here to walk, which is the
    // in-process comparison mode. Coming from a FILE they are not -- that is
    // the point of the file -- and the same question is asked before the
    // prefix is opened at all: the library's load must be the first thing in
    // the root (rnxc's tryPrefix).
    if (start == 0) if (c.main_fn) |rm| {
        var ordered = std.ArrayListUnmanaged(ts.Node){};
        defer ordered.deinit(alloc);
        const visited = try alloc.alloc(bool, roots.len);
        defer alloc.free(visited);
        @memset(visited, false);
        try spliceOne(roots, 0, &ordered, visited, alloc);
        for (roots, 0..) |_, i| {
            if (!visited[i]) try spliceOne(roots, @intCast(i), &ordered, visited, alloc);
        }
        const lib = if (c.prefix_main) |pm| c.funcs.items[pm].stmts.items else &.{};
        // The prefix's list came from the splice, which drops the `load`
        // statements and the comments; this file's came straight from the
        // collect, which keeps them. Neither emits anything, so the
        // comparison skips them rather than the compiler removing them.
        var own = std.ArrayListUnmanaged(ts.Node){};
        defer own.deinit(alloc);
        for (c.funcs.items[rm].stmts.items) |st| {
            const k = st.kind();
            if (std.mem.eql(u8, k, "comment") or std.mem.eql(u8, k, "load_statement")) continue;
            try own.append(alloc, st);
        }
        if (ordered.items.len != lib.len + own.items.len) {
            prefix_blocked_by = "the top level does not split in two";
            return Error.PrefixInapplicable;
        }
        for (ordered.items, 0..) |st, i| {
            const want = if (i < lib.len) lib[i] else own.items[i - lib.len];
            if (st.src.ptr != want.src.ptr or st.startByte() != want.startByte()) {
                prefix_blocked_by = "this file's own code runs before what it loads";
                return Error.PrefixInapplicable;
            }
        }
    };

    // Which name indices the library gave up on and deferred to a native.
    var deferred = std.AutoHashMapUnmanaged(u16, void){};
    defer deferred.deinit(c.alloc);
    for (c.natives.items) |ni| deferred.put(c.alloc, ni, {}) catch return Error.OutOfMemory;

    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        if (f.owner != null) continue; // a method is reached by class, not by name
        // The synthetic ones are never called by name: there is deliberately
        // one @@main per top level and the entry trampoline calls both, and
        // a lambda is reached through the closure that carries its id.
        if (std.mem.startsWith(u8, f.name, "@@")) continue;
        if (deferred.contains(f.name_idx)) {
            prefix_blocked_by = f.name;
            return Error.PrefixInapplicable;
        }
        if (c.findFunc(f.name)) |g| {
            // findFunc answers with the FIRST of that name. If that is not
            // this one, the library already has it.
            if (g.id != f.id) {
                prefix_blocked_by = f.name;
                return Error.PrefixInapplicable;
            }
        }
    }
    for (c.classes.items[c.prefix_classes..]) |*ci| {
        for (c.classes.items[0..c.prefix_classes]) |*pc| {
            if (std.ascii.eqlIgnoreCase(pc.name, ci.name)) {
                prefix_blocked_by = ci.name;
                return Error.PrefixInapplicable;
            }
        }
    }
}

fn compileFront(
    c: *Compiler,
    collect: []const ts.Node,
    splice_roots: []const ts.Node,
    splice_start: u32,
    alloc: std.mem.Allocator,
) Error!void {
    for (collect) |r| try collectAll(c, r, alloc);
    try resolveAllSlots(c, alloc);
    // Ring runs a loaded file's top level AT the load statement, so the
    // per-file blocks collected above are in the wrong order until this
    // splices them.
    if (splice_roots.len > 0) try spliceMain(c, splice_roots, splice_start, alloc);
    return compileFrontAfterCollect(c, alloc);
}

/// Everything the front does once the definitions are in: reserve, emit,
/// classify, emit again, spread. Split out so compileOnto can ask whether
/// the prefix APPLIES between the collect and the first instruction emitted
/// on top of it.
fn compileFrontAfterCollect(c: *Compiler, alloc: std.mem.Allocator) Error!void {
    // RESERVE THE THREE PARALLEL STREAMS BEFORE EMITTING.
    //
    // The compiler allocates from a bump arena, which never reclaims: every
    // time an ArrayList doubles, the buffer it outgrew stays resident for the
    // life of the process. Measured on the Softanza unit with a counting
    // allocator (2026-09-13): 407 MB asked for against about 35 MB of
    // finished structures, and 209 MB of that in the 784 allocations of
    // 64 KB and up -- which is what doubling looks like from the outside.
    //
    // The statement count is known here, and the ratio of instructions to
    // statements is stable at about nine, so one reservation replaces the
    // whole doubling ladder. Over-reserving costs untouched pages; the arena
    // would have committed them on the way up anyway.
    {
        var nstmt: usize = 0;
        for (c.funcs.items) |f| nstmt += f.stmts.items.len;
        const guess = nstmt * 12 + 1024;
        c.code.ensureTotalCapacity(alloc, guess) catch {};
        c.rows.ensureTotalCapacity(alloc, guess) catch {};
        c.files.ensureTotalCapacity(alloc, guess) catch {};
    }

    try emitAll(c);

    // ---- seed whatever the source declared -----------------------------
    // A stated type is not a hypothesis, so it is written in before the
    // fixpoint runs and is never widened afterwards.
    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        for (f.params, 0..) |p, pi| {
            if (pi >= f.hints.len or f.hints[pi] == .unknown) continue;
            for (f.locals.items) |*l| {
                if (std.ascii.eqlIgnoreCase(l.name, p)) {
                    l.class = f.hints[pi];
                    l.declared = true;
                    // `list aL` on these kernels means a list of numbers.
                    if (l.class == .list) l.elem = .int;
                }
            }
        }
    }
    // ---- elements this pass cannot see are opened first ---------------
    openElems(c, c.prefix_funcs);

    // ---- classify to a fixpoint, entry points widened INSIDE it -------
    //
    // A parameter is proven int only by the call sites inference can see. A
    // function nothing in this unit calls has none, so assuming int would be
    // a guess -- and a wrong guess drops the retain on a real reference.
    // Sum32 is exactly that case: it takes a list and is only ever called
    // from the host. Every METHOD is that case too, because `findFunc`
    // never resolves one, so no call site of a method is ever observed.
    //
    // This is the pessimism Ring's own type-hint channel removes. `func
    // Sum32(list aL)` would state what inference here has to assume, and
    // study 4.9 is where that lands. Until then, entry points pay.
    //
    // THE WIDENING RUNS AT ROUND 0, NOT AFTER THE LOOP. `called` is a
    // syntactic fact and is final once one full round has walked every call
    // expression, so one pass is enough -- but the rounds after it are what
    // carries a widened parameter into the functions it is PASSED TO. See
    // widenEntryParams for what running it last cost.
    var round: u32 = 0;
    while (round < 8) : (round += 1) {
        var changed = try classifyRound(c);
        if (round == 0) changed = widenEntryParams(c, c.prefix_funcs) or changed;
        if (!changed) break;
    }

    // ---- pass B: recompile now that classes are known -----------------
    //
    // Pass A ran BEFORE the fixpoint, with nothing inferred. Its only job
    // is to populate locals so classify has something to work on, and its
    // refusals are not final -- a statement that needs a proved class
    // (a specialised vget, a receiver class, classname) can only compile
    // here. So its poison is cleared: leaving it set kept every function
    // that inference rescued permanently unusable.
    //
    // WITH A PREFIX, pass B rolls back to the MARK rather than to zero: the
    // library's code is the front of this same stream, and re-emitting it is
    // exactly the work a prefix exists not to do.
    c.code.shrinkRetainingCapacity(c.prefix_code);
    c.rows.shrinkRetainingCapacity(c.prefix_code);
    c.files.shrinkRetainingCapacity(c.prefix_code);
    c.fixups.shrinkRetainingCapacity(c.prefix_fixups);
    c.refusals.clearRetainingCapacity();
    c.absent_classes.clearRetainingCapacity();
    c.stmts_ok = 0;
    c.stmts_bad = 0;
    c.emit_failed = 0;
    c.stmts_native = 0;
    c.natives.clearRetainingCapacity();
    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        f.poisoned = false;
        f.calls_named.clearRetainingCapacity();
        f.calls_static.clearRetainingCapacity();
    }
    try emitAll(c);

    // ---- poison spreads to callers ------------------------------------
    //
    // A function whose body lost a statement is unusable; so is anything
    // that CALLS it, or the wrong answer simply moves one frame up. Direct
    // calls follow a known edge. A method call does not -- the receiver's
    // class is a runtime fact -- so the approximation is: if ANY method of
    // that name is poisoned anywhere, the caller is poisoned too. That is
    // deliberately pessimistic; a wrong answer costs more than a refusal.
    var direct: usize = 0;
    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        // Captured HERE, before the spread, because after it every caller
        // looks identical to the thing that actually broke.
        f.poisoned_own = f.poisoned;
        if (f.poisoned) direct += 1;
    }
    // A prefix counted its own when IT was compiled. The SPREAD runs over
    // everything, because a file compiled on top can be poisoned by what the
    // library could not compile.
    c.spread_direct += direct;
    c.spread_dyn = spreadPoison(c);
}

fn compileFinish(c: *Compiler, alloc: std.mem.Allocator) Error!Program {
    const direct = c.spread_direct;
    const dyn = c.spread_dyn;
    var entry_tramp: ?u32 = null;
    const ranking: Ranking = if (c.rank)
        try rankPoison(c, alloc, 30)
    else
        .{};

    // ---- patch every call site ----------------------------------------
    for (c.fixups.items) |fx| {
        const f = &c.funcs.items[fx.fidx];
        c.code.items[fx.site].b = f.frame;
        // `c` is 8 bits and carries the mask index. A function id past the
        // 64-slot table has no mask to name, so it stores NO_MASK -- and the
        // VM sweeps that frame WHOLE on return. It used to store 0, which
        // names function 0's mask and, for a program of more than 64
        // functions, meant every return swept nothing at all.
        c.code.items[fx.site].c = if (f.id < vm.fn_masks.len) @intCast(f.id) else vm.NO_MASK;
        c.code.items[fx.site].d = @intCast(f.entry);
    }

    // ---- trampolines: one per function, so a host can call in ---------
    const body_end = c.here();
    for (c.funcs.items) |*f| {
        f.tramp = c.here();
        const mid: u8 = if (f.id < vm.fn_masks.len) @intCast(f.id) else vm.NO_MASK;
        _ = try c.emit(.call, 0, f.frame, mid, @intCast(f.entry));
        _ = try c.emit(.halt, 0, 0, 0, 0);
    }

    // ---- the entry -----------------------------------------------------
    //
    // Ring runs a loaded file's top level AT the load statement, so a file
    // whose first statement is `load "stzBase.ring"` runs the library's top
    // level and then its own. With a prefix those are two functions, and
    // this is the one trampoline that runs them in that order.
    //
    // AND THEN RING CALLS Main(). Ten probes on 1.27, in scratchpad/mainp:
    // a plain function named `main` -- in ANY case, Ring folds names -- is
    // called with NO arguments once the top level has run to completion;
    // top-level code runs FIRST and Main after it; a Main defined in a
    // LOADED file is called just the same; a METHOD of that name is not
    // called at all; and an uncaught raise in the top level means Main
    // never runs, which falls out of this placement rather than needing a
    // check. Two functions of that name are a C22 redefinition on Ring, a
    // rule of its own we do not implement; the first is taken here.
    //
    // THE CALL SITE RING REPORTS IS THE `func Main` LINE ITSELF, in Main's
    // own file. Probed both ways: a file that is nothing but `func Main`
    // at line 1 answers `Called from line 1`, and one whose top level is
    // line 1 and whose `func Main` is line 2 answers `Called from line 2`
    // -- so it is the declaration, not the top of the file, and the row
    // below is the function node's own start. `In function main()` IS
    // printed for an error inside it, which is why main_fn carries a
    // sentinel when there is no top level rather than naming Main.
    //
    // A Main that DECLARES parameters is still called without any, and
    // raises R19 at that same site.
    const user_main: ?u32 = blk: {
        for (c.funcs.items, 0..) |*f, i| {
            if (f.owner != null) continue; // a METHOD named Main is not it
            if (f.is_main) continue; // the synthetic @@main
            if (f.lambda_at != null) continue; // a lowered lambda
            if (!f.emitted) continue; // never compiled: nothing to call
            if (std.ascii.eqlIgnoreCase(f.name, "main")) break :blk @intCast(i);
        }
        break :blk null;
    };
    if (c.prefix_main != null or user_main != null) {
        entry_tramp = c.here();
        if (c.prefix_main) |pm| {
            const pf = &c.funcs.items[pm];
            const pmid: u8 = if (pf.id < vm.fn_masks.len) @intCast(pf.id) else vm.NO_MASK;
            _ = try c.emit(.call, 0, pf.frame, pmid, @intCast(pf.entry));
        }
        if (c.main_fn) |rm| {
            const rf = &c.funcs.items[rm];
            const rmid: u8 = if (rf.id < vm.fn_masks.len) @intCast(rf.id) else vm.NO_MASK;
            _ = try c.emit(.call, 0, rf.frame, rmid, @intCast(rf.entry));
        }
        if (user_main) |um| {
            const uf = &c.funcs.items[um];
            c.cur_row = uf.node.start().row + 1;
            c.cur_file = c.fileOf(uf.node.src.ptr) orelse 0;
            if (uf.params.len != 0) {
                // The same answer userCall gives a call of the wrong arity,
                // for the same reason: Ring counts at RUN time.
                const msg = "\"Error (R19) : Calling function with less number of parameters\"";
                _ = try c.emit(.loadk, 0, 0, 0, try c.konstIndex(msg));
                _ = try c.emit(.trap, 0, 0, 0, 0);
            } else {
                const umid: u8 = if (uf.id < vm.fn_masks.len) @intCast(uf.id) else vm.NO_MASK;
                _ = try c.emit(.call, 0, uf.frame, umid, @intCast(uf.entry));
            }
        }
        _ = try c.emit(.halt, 0, 0, 0, 0);
    }

    // ---- hand the masks to the VM -------------------------------------
    // The boxed-register masks are read by the TYPED build too -- the one
    // the gate uses -- not only by the deferred one, which is what the note
    // here used to claim. The table is 64 entries, sized for the six
    // hand-written kernels and never for a compiled program, so all but the
    // first 64 functions have no mask. They are marked NO_MASK now and their
    // frames are swept whole on return; before, a missing mask meant
    // sweeping NOTHING, and every call in every real program leaked its
    // registers (found 2026-09-12).
    for (c.funcs.items) |f| {
        if (f.id < vm.fn_masks.len) vm.fn_masks[f.id] = f.mask;
    }

    // ---- and the object-model tables ----------------------------------
    // Dispatch is a dense (class x name) table so a method call is one
    // indexed load. A linear scan would make every call O(methods), which is
    // the cost this whole project exists to remove.
    if (c.classes.items.len > 0) {
        const ncls = c.classes.items.len;
        // Every attribute name is a name too, so `o.attr` resolved at run
        // time (gattrn) can find it; interned BEFORE the dispatch table is
        // sized, so the two tables agree on what a name index is.
        for (c.classes.items) |ci| {
            for (ci.attrs.items) |a| _ = try c.nameIndex(a.name);
        }
        const nnm = c.names.items.len;
        vm.n_names = @intCast(nnm);
        const tab = try alloc.alloc(u32, ncls * nnm);
        @memset(tab, 0);
        var mt = std.ArrayListUnmanaged(vm.MethodEnt){};
        for (c.classes.items) |ci| {
            for (ci.methods.items) |mi| {
                const f = c.funcs.items[mi];
                const mmid: u8 = if (f.id < vm.fn_masks.len) @intCast(f.id) else vm.NO_MASK;
                const ar = declaredArity(&f);
                const np: u8 = if (ar < vm.unchecked_arity) @intCast(ar) else vm.unchecked_arity;
                try mt.append(alloc, .{ .entry = f.entry, .frame = f.frame, .id = mmid, .nparams = np });
                tab[@as(usize, ci.id) * nnm + f.name_idx] = @intCast(mt.items.len);
            }
        }
        // A child inherits every method its parent defines and does not
        // override -- resolved here, once, rather than walked at every call.
        for (c.classes.items) |ci| {
            var p = ci.parent;
            while (p) |pid| {
                const par = c.classes.items[pid];
                var nm: usize = 0;
                while (nm < nnm) : (nm += 1) {
                    const dstv = @as(usize, ci.id) * nnm + nm;
                    if (tab[dstv] == 0) tab[dstv] = tab[@as(usize, par.id) * nnm + nm];
                }
                p = par.parent;
            }
        }
        vm.dispatch = tab;
        vm.method_tab = try mt.toOwnedSlice(alloc);
        const cs = try alloc.alloc(u32, ncls);
        for (c.classes.items, 0..) |ci, ix| cs[ix] = @intCast(ci.attrs.items.len);
        vm.class_slots = cs;

        // Attribute name -> slot per class, for the run-time path. Own
        // attributes first, then each ancestor's that the class did not
        // redeclare -- the same walk the dispatch table makes for methods.
        {
            var ents = std.ArrayListUnmanaged(vm.AttrEnt){};
            const from = try alloc.alloc(u32, ncls + 1);
            for (c.classes.items, 0..) |ci, ix| {
                from[ix] = @intCast(ents.items.len);
                for (ci.attrs.items) |a| {
                    try ents.append(alloc, .{ .name = try c.nameIndex(a.name), .slot = a.slot });
                }
                var p = ci.parent;
                while (p) |pid| {
                    for (c.classes.items[pid].attrs.items) |a| {
                        const ni = try c.nameIndex(a.name);
                        var have = false;
                        var q = from[ix];
                        while (q < ents.items.len) : (q += 1) {
                            if (ents.items[q].name == ni) have = true;
                        }
                        if (!have) try ents.append(alloc, .{ .name = ni, .slot = a.slot });
                    }
                    p = c.classes.items[pid].parent;
                }
            }
            from[ncls] = @intCast(ents.items.len);
            vm.attr_from = from;
            vm.attr_ent = try ents.toOwnedSlice(alloc);
        }

        // Each class's lowercased name, as a constant, so `clsname` is a
        // table read at run time. Built here rather than lazily because
        // `konst` is handed to the VM immediately below and must be final.
        const ck = try alloc.alloc(u32, ncls);
        for (c.classes.items, 0..) |ci, ix| ck[ix] = @intCast(try c.classNameKonst(ci.name));
        vm.class_konst = ck;

        // Reflection's two facts the dispatch table cannot say: a class's
        // PARENT, and the class that DEFINES each function (0xFFFF for a
        // plain function). `methods(o)` lists a class's own methods in
        // definition order before its parent's, as Ring does, and needs
        // both (2026-09-23).
        const cp = try alloc.alloc(u16, ncls);
        for (c.classes.items, 0..) |ci, ix| cp[ix] = if (ci.parent) |p| @intCast(p) else 0xFFFF;
        vm.class_parent = cp;
    }
    {
        const fo = try alloc.alloc(u16, c.funcs.items.len);
        for (c.funcs.items, 0..) |f, ix| fo[ix] = if (f.owner) |o| o else 0xFFFF;
        vm.fn_owner = fo;
    }
    {
        // RING'S AUTOMATIC GETTERS AND SETTERS (F-73): `o.x` calls getx()
        // and `o.x = v` calls setx(v) when the object's class has them. Per
        // attribute NAME, the name index of `get<name>` and `set<name>`, or
        // NONE -- so the VM asks one table and one dispatch cell, and a
        // name no class ever pairs with an accessor costs a single load.
        const nn = c.names.items.len;
        const ag = try alloc.alloc(u32, nn);
        const as = try alloc.alloc(u32, nn);
        @memset(ag, vm.ACC_NONE);
        @memset(as, vm.ACC_NONE);
        var buf: [256]u8 = undefined;
        for (c.names.items, 0..) |nm, i| {
            if (nm.len <= 3 or nm.len > buf.len) continue;
            const is_get = std.ascii.eqlIgnoreCase(nm[0..3], "get");
            if (!is_get and !std.ascii.eqlIgnoreCase(nm[0..3], "set")) continue;
            const key = std.ascii.lowerString(&buf, nm[3..]);
            const ai = c.name_index.get(key) orelse continue;
            if (is_get) ag[ai] = @intCast(i) else as[ai] = @intCast(i);
        }
        vm.acc_get = ag;
        vm.acc_set = as;
    }
    vm.konst = c.konst.items;

    // THE LOCALS TABLES for eval (F-72): by function id, every local's
    // name, register and boxed flag, parameters first as they sit in r0..
    const locals_tab = blk: {
        var mx: usize = 0;
        for (c.funcs.items) |f| mx = @max(mx, f.id);
        const from = alloc.alloc(u32, mx + 2) catch unreachable;
        @memset(from, 0);
        var total: usize = 0;
        for (c.funcs.items) |f| total += f.locals.items.len;
        const names = alloc.alloc([]const u8, total) catch unreachable;
        const regs = alloc.alloc(u8, total) catch unreachable;
        const boxed = alloc.alloc(bool, total) catch unreachable;
        // functions are appended in id order, but count per id first so a
        // gap in ids (none expected) cannot misplace a table
        var per = alloc.alloc(u32, mx + 1) catch unreachable;
        @memset(per, 0);
        for (c.funcs.items) |f| per[f.id] = @intCast(f.locals.items.len);
        var acc: u32 = 0;
        for (0..mx + 1) |id| {
            from[id] = acc;
            acc += per[id];
        }
        from[mx + 1] = acc;
        for (c.funcs.items) |f| {
            var at: usize = from[f.id];
            for (f.locals.items) |l| {
                names[at] = l.name;
                regs[at] = l.reg;
                boxed[at] = l.class.boxed();
                at += 1;
            }
        }
        break :blk .{ .from = from, .names = names, .regs = regs, .boxed = boxed };
    };

    return .{
        .code = c.code.items,
        .funcs = c.funcs.items,
        .rows = c.rows.items,
        .files = c.files.items,
        .fn_of = fnOfTable(alloc, c.funcs.items, c.code.items.len, body_end) catch &.{},
        // A SENTINEL, not 0, when the file has no top level at all. The VM
        // reads this as "the frame that is the top level", printing the
        // file alone where every other frame gets `In function f()`. Zero
        // names function 0, which in a file that is one `func Main` IS
        // Main -- and Ring prints `In function main()` for an error inside
        // it (probed 2026-09-22).
        .main_fn = c.main_fn orelse std.math.maxInt(u32),
        .names = c.names.items,
        .nglobals = c.globals.items.len,
        .global_names = c.globals.items,
        .fn_entry = blk: {
            var mx: usize = 0;
            for (c.funcs.items) |f| mx = @max(mx, f.id);
            const t = alloc.alloc(u32, mx + 1) catch unreachable;
            @memset(t, 0);
            for (c.funcs.items) |f| t[f.id] = f.entry;
            break :blk t;
        },
        .fn_frame = blk: {
            var mx: usize = 0;
            for (c.funcs.items) |f| mx = @max(mx, f.id);
            const t = alloc.alloc(u8, mx + 1) catch unreachable;
            @memset(t, 0);
            for (c.funcs.items) |f| t[f.id] = f.frame;
            break :blk t;
        },
        .fn_local_from = locals_tab.from,
        .local_names = locals_tab.names,
        .local_regs = locals_tab.regs,
        .local_boxed = locals_tab.boxed,
        .class_attrs_fn = blk: {
            const t = alloc.alloc(u32, c.classes.items.len) catch unreachable;
            for (c.classes.items, 0..) |ci, ix| t[ix] = ci.attrs_fn orelse 0xFFFFFFFF;
            break :blk t;
        },
        .poisoned_direct = direct,
        .poisoned_dynamic = dyn,
        .ranking = ranking,
        .entry_tramp = entry_tramp,
    };
}

/// Collect everything, in SOURCE ORDER.
///
/// Headers (`func`, `def`, `class`) and loose statements are gathered into
/// one list sorted by byte offset, and each statement is given to the header
/// that most recently preceded it. That is Ring's own rule (F-21) and it is
/// the only one this grammar respects: it scatters a construct's later
/// statements after the function, after the method, and after a nested
/// class back into the enclosing one.
fn collectAll(c: *Compiler, root: ts.Node, alloc: std.mem.Allocator) Error!void {
    // This runs ONCE PER FILE, and the unit is 606 of them. Everything below
    // that walks `c.funcs` walks only the functions THIS file adds -- the
    // lambda lowering and the Rule A scan used to start from 0, so each
    // file re-walked every statement of every file before it: 606 x
    // 114,796 subtrees, both passes idempotent, 79 of the 95 s a census
    // took (measured 2026-09-10, `collect:` line). The core unit has 28
    // files, which is why it never showed there.
    const first_fn = c.funcs.items.len;
    var pieces = std.ArrayListUnmanaged(Piece){};
    var ctm = std.time.Timer.start() catch unreachable;
    try gatherPieces(root, &pieces, alloc);
    collect_ns[0] += ctm.lap();
    std.mem.sort(Piece, pieces.items, {}, lessPiece);
    collect_ns[1] += ctm.lap();
    const abs_from = c.absorbed.items.len;
    // `return func t { ... }`: a bare return with a braced definition on its row. The definition and everything inside it leave the pieces (they are the
    // lambda's, not a function of the file's and not statements of the enclosing one); the return stays, and says where its text really ends.
    {
        var w: usize = 0;
        var r: usize = 0;
        while (r < pieces.items.len) : (r += 1) {
            const p = pieces.items[r];
            if (p.kind == .stmt and r + 1 < pieces.items.len and std.mem.eql(u8, p.node.kind(), "return_statement") and
                retValue(p.node) == null and pieces.items[r + 1].kind == .func and isBracedDef(pieces.items[r + 1].node) and
                pieces.items[r + 1].node.start().row == p.node.end().row)
            {
                const def = pieces.items[r + 1].node;
                const lam_end = bracedDefEnd(def);
                try c.ret_ext.put(alloc, nodeKey(p.node), lam_end);
                try c.absorbed.append(alloc, .{ .ret_start = p.off, .src = p.node.src, .def = def });
                pieces.items[w] = p;
                w += 1;
                r += 1;
                while (r + 1 < pieces.items.len and pieces.items[r + 1].off < lam_end) r += 1;
                continue;
            }
            pieces.items[w] = p;
            w += 1;
        }
        pieces.shrinkRetainingCapacity(w);
    }

    // pass 1: every class, so `from` can be resolved and methods can be owned
    for (pieces.items) |p| {
        if (p.kind != .class) continue;
        var ci = ClassInfo{
            .name = p.node.namedChild(0).text(),
            .node = p.node,
            .id = @intCast(c.classes.items.len),
        };
        // Attributes are declared between `class C` and its first `def` --
        // and AGAIN after a `private` marker that follows methods: probed on
        // 1.27, `@d@ = 7` written after `private` after two defs is a real
        // attribute (reads back 7). A statement in any other position after
        // a def is that method's, or fell out of it (F-58), never the class's.
        var attr_ctx = true;
        // The class's direct children, and then -- when the grammar made a
        // `private_section` node -- that node's children, which are the
        // rest of the class. One flat walk over both, in order.
        var seq = std.ArrayListUnmanaged(ts.Node){};
        defer seq.deinit(alloc);
        {
            var k0: u32 = 1;
            while (k0 < p.node.namedChildCount()) : (k0 += 1) {
                const ch0 = p.node.namedChild(k0);
                try seq.append(alloc, ch0);
                if (std.mem.eql(u8, ch0.kind(), "private_section")) {
                    var k1: u32 = 0;
                    while (k1 < ch0.namedChildCount()) : (k1 += 1) try seq.append(alloc, ch0.namedChild(k1));
                }
            }
        }
        for (seq.items) |ch| {
            const ck = ch.kind();
            if (std.mem.eql(u8, ck, "class_definition") or
                std.mem.eql(u8, ck, "function_definition"))
            {
                attr_ctx = false;
                continue;
            }
            if (std.mem.eql(u8, ck, "class_parent")) {
                ci.parent_name = ch.namedChild(0).text();
                continue;
            }
            if (isPrivateMarker(ch)) {
                attr_ctx = true;
                continue;
            }
            if (!attr_ctx) continue;
            // a loop or an `if` in the region: the names it assigns are
            // attributes too, in their place in the source (F-121)
            if (!std.mem.eql(u8, ck, "expression_statement")) {
                try regionNamesInto(&ci, ch, alloc);
                continue;
            }
            const e = ch.namedChild(0);
            var nm: []const u8 = "";
            if (std.mem.eql(u8, e.kind(), "identifier")) {
                nm = e.text();
            } else if (std.mem.eql(u8, e.kind(), "assignment_expression") and
                std.mem.eql(u8, e.namedChild(0).kind(), "identifier"))
            {
                nm = e.namedChild(0).text();
            }
            // `@name` is Softanza's CONVENTION, not Ring syntax -- `@` is
            // simply legal in an identifier. Ring declares an attribute with
            // a bare name in the class body, and both forms create the
            // property: probed on 1.27, `attributes()` lists `nBare` (no
            // initialiser, value NULL) alongside `nInit = 7`, in a private
            // section as well as a public one.
            if (nm.len > 0) try ci.attrs.append(alloc, .{ .name = nm, .slot = 0 });
        }
        try c.classes.append(alloc, ci);
    }

    collect_ns[2] += ctm.lap();
    for (c.classes.items) |*ci| {
        if (ci.parent_name.len == 0) continue;
        for (c.classes.items) |*p| {
            if (std.ascii.eqlIgnoreCase(p.name, ci.parent_name)) ci.parent = p.id;
        }
    }
    // (slots are resolved after collectAll's Rule A pre-pass, below)

    collect_ns[3] += ctm.lap();
    // pass 2: functions and methods, each owning the statements that follow
    // `@@main` holds EVERY file's top-level statements, and it is made by the first file that has one: a later file only appends to it, from here.
    const main_start: usize = if (c.main_fn) |mi| c.funcs.items[mi].stmts.items.len else 0;
    var cur_fn: ?usize = null;
    var cur_class: ?u16 = null;
    // The prologue must exist before pass 2 can be walked twice, so the
    // inheritance graft happens after it, below.
    for (pieces.items) |p| {
        switch (p.kind) {
            .class => {
                cur_fn = null;
                cur_class = null;
                for (c.classes.items) |*ci| {
                    if (ci.node.startByte() == p.off) cur_class = ci.id;
                }
            },
            .func => {
                const owner = cur_class;
                try startFunc(c, p.node, owner, alloc);
                cur_fn = c.funcs.items.len - 1;
                if (owner) |oid| try c.classes.items[oid].methods.append(alloc, @intCast(cur_fn.?));
            },
            .stmt => {
                // `private` after methods hands the class back its
                // attribute-declaring context (probed on 1.27, see pass 1):
                // what follows belongs to the class, not to the last def.
                if (cur_class != null and isPrivateMarker(p.node)) {
                    cur_fn = null;
                    continue;
                }
                if (cur_fn) |fi| {
                    try c.funcs.items[fi].stmts.append(alloc, p.node);
                } else if (cur_class == null) {
                    // Top level: a statement belonging to no function and
                    // no class. These were dropped entirely, so a file's
                    // own code never ran and its globals never existed.
                    if (c.main_fn == null) {
                        var mparams = std.ArrayListUnmanaged([]const u8){};
                        var mhints = std.ArrayListUnmanaged(Class){};
                        try c.funcs.append(alloc, .{
                            .name = MAIN,
                            .node = p.node,
                            .params = try mparams.toOwnedSlice(alloc),
                            .id = @intCast(c.funcs.items.len),
                            .body_from = std.math.maxInt(u32),
                            .stmts = .{},
                            .hints = try mhints.toOwnedSlice(alloc),
                            .owner = null,
                            .name_idx = try c.nameIndex(MAIN),
                            .called = true,
                            .is_main = true,
                        });
                        c.main_fn = @intCast(c.funcs.items.len - 1);
                    }
                    try c.funcs.items[c.main_fn.?].stmts.append(alloc, p.node);
                } else if (cur_class) |cid| {
                    // Between `class C` and its first `def` -- an attribute
                    // initialiser. Assignments are taken, and so is a BARE
                    // DECLARATION: on Ring `x` alone gives the attribute the
                    // four-byte string "NULL" (probed, len 4, type STRING,
                    // isNull 1). This used to say a bare declaration "needs no
                    // code, the slot is already nil" -- true until gattr began
                    // raising R24 on a nil slot, from which moment a declared
                    // attribute read as never assigned. stmt() emits the
                    // store when the prologue is compiled. `private` and the
                    // other markers are filtered there, not here.
                    //
                    // AND EVERY OTHER STATEMENT OF THE REGION RUNS TOO (F-121).
                    // Ring runs the whole class region at each `new`, in order,
                    // before init -- a `?`, a call, a loop, an `if`,
                    // `AddAttribute(self, ...)` -- and every name it assigns,
                    // a loop's variable included, is an attribute of the
                    // object. Only assignments and bare declarations were
                    // taken here, and the rest was dropped without a word:
                    // Softanza's one such line, `vr(:say)` in stzExtinPerl's
                    // class say, never ran.
                    try registerRegionNames(c, cid, p.node, alloc);
                    const is_expr = std.mem.eql(u8, p.node.kind(), "expression_statement") and p.node.namedChildCount() > 0;
                    const e = if (is_expr) p.node.namedChild(0) else p.node;
                    const is_id = is_expr and std.mem.eql(u8, e.kind(), "identifier");
                    const is_asg = is_expr and std.mem.eql(u8, e.kind(), "assignment_expression");
                    // REGISTER THE NAME HERE TOO. The class walk that collects
                    // attributes follows the TREE, and the tree puts a second
                    // class -- and the `private` section that FOLLOWS it --
                    // inside the FIRST class's private section (everything
                    // after `private` is that section, to the end of the
                    // file). So the second class's own `oZip` was never
                    // collected, every method's read of it was a Rule A
                    // refusal, and its declaration -- fed to the right
                    // prologue by THIS pass, which follows the file as Ring
                    // does -- refused itself. Registered where it is fed,
                    // the prologue and the attribute list cannot disagree.
                    // Ring's own ziplib.ring is that shape (class zip, then
                    // class ZipEntry ending in `private` / `oZip`).
                    const declared: []const u8 = if (is_id) e.text() else if (is_asg and std.mem.eql(u8, e.namedChild(0).kind(), "identifier")) e.namedChild(0).text() else "";
                    if (declared.len > 0) {
                        const ci = &c.classes.items[cid];
                        var have = false;
                        for (ci.attrs.items) |a| {
                            if (std.ascii.eqlIgnoreCase(a.name, declared)) have = true;
                        }
                        if (!have) try ci.attrs.append(alloc, .{ .name = declared, .slot = 0 });
                    }
                    const fi = c.classes.items[cid].attrs_fn orelse blk: {
                        try newPrologue(c, cid, alloc);
                        break :blk c.classes.items[cid].attrs_fn.?;
                    };
                    try c.funcs.items[fi].stmts.append(alloc, p.node);
                }
            },
        }
    }

    var cid: u16 = 0;
    _ = &cid; // classes are grafted by resolveAllSlots, after every file is in

    // ---- lambdas become ordinary functions -----------------------------
    //
    // Done here, before slots and before codegen, because the enclosing
    // function's locals must already be known for capture analysis and
    // the synthetic function must exist before anything calls it.
    {
        var fi: usize = first_fn;
        while (fi < c.funcs.items.len) : (fi += 1) {
            var si: usize = 0;
            while (si < c.funcs.items[fi].stmts.items.len) : (si += 1) {
                const st = c.funcs.items[fi].stmts.items[si];
                try lowerLambdas(c, @intCast(fi), st, alloc);
            }
        }
        // A LATER FILE'S TOP LEVEL. Its statements were appended to `@@main`, which stands BEFORE `first_fn`, so the walk above never saw them: a lambda at the
        // top level of a loaded file (`fOne = func t { ... }`) was not lowered and its statement was refused, while the same line in the root worked. Found
        // 2026-10-05, making bench/exec/lambda_offset.ring.
        if (c.main_fn) |mi| {
            if (mi < first_fn) {
                var si: usize = main_start;
                while (si < c.funcs.items[mi].stmts.items.len) : (si += 1) {
                    try lowerLambdas(c, mi, c.funcs.items[mi].stmts.items[si], alloc);
                }
            }
        }
        // the lambdas `return func t { ... }` hid from the tree: each belongs to the function that holds its return
        var ai: usize = abs_from;
        while (ai < c.absorbed.items.len) : (ai += 1) {
            const ab = c.absorbed.items[ai];
            var owner: ?usize = null;
            var fj: usize = if (c.main_fn) |mi| @min(mi, first_fn) else first_fn;
            while (fj < c.funcs.items.len and owner == null) : (fj += 1) {
                for (c.funcs.items[fj].stmts.items) |st| {
                    if (st.startByte() == ab.ret_start and st.src.ptr == ab.src.ptr and std.mem.eql(u8, st.kind(), "return_statement")) owner = fj;
                }
            }
            const oi = owner orelse return Error.Unsupported;
            c.absorbed.items[ai].owner = @intCast(oi);
            try lowerOneLambda(c, @intCast(oi), ab.def, alloc);
        }
    }

    // ---- Rule A's pre-pass --------------------------------------------
    // (runs before resolveSlots, which fixes each class's slot count)
    //
    // Every `@name` a method mentions IS an attribute of its class, and
    // every `$name` anything assigns IS a global. Both are collected
    // before slots are resolved, because an object's slot count is fixed
    // at that point and a name discovered during codegen would arrive too
    // late. This is what makes 766 previously-refused `@name` reads
    // compile: the class need not have declared them.
    for (c.funcs.items[first_fn..]) |*f| {
        for (f.stmts.items) |st| try ruleAScan(c, f, st, alloc);
    }

    try resolveAllSlots(c, alloc);
    collect_ns[4] += ctm.lap();
}

/// Find every `anonymous_function` under `n` and lower it to a real
/// function. Recurses so a lambda inside a lambda is reached.
fn lowerLambdas(c: *Compiler, owner_fi: u32, n: ts.Node, alloc: std.mem.Allocator) Error!void {
    if (std.mem.eql(u8, n.kind(), "anonymous_function")) {
        try lowerOneLambda(c, owner_fi, n, alloc);
        return;
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        try lowerLambdas(c, owner_fi, n.namedChild(i), alloc);
    }
}

fn lowerOneLambda(c: *Compiler, owner_fi: u32, n: ts.Node, alloc: std.mem.Allocator) Error!void {
    // "Already lowered" is the same offset IN THE SAME FILE: a byte offset
    // alone repeats across a 606-file unit, and matching on it alone would
    // skip a lambda that merely sits where another file's did.
    const at: u32 = n.startByte();
    for (c.funcs.items) |f| {
        if (f.lambda_at != null and f.lambda_at.? == at and f.node.src.ptr == n.src.ptr) return;
    }

    // params: r0 is the closure, so declared parameters start at r1
    var params = std.ArrayListUnmanaged([]const u8){};
    var hints = std.ArrayListUnmanaged(Class){};
    try params.append(alloc, "@@clos");
    try hints.append(alloc, .list);
    var body_from: u32 = 0;
    var i: u32 = 0;
    if (std.mem.eql(u8, n.kind(), "function_definition")) {
        // `return func t { ... }` as the grammar read it (see `Compiler.absorbed`): the NAME is the lambda's one parameter
        try params.append(alloc, n.namedChild(0).text());
        try hints.append(alloc, .unknown);
        body_from = 1;
        i = n.namedChildCount();
    }
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        if (!std.mem.eql(u8, ch.kind(), "param_list")) continue;
        var p: u32 = 0;
        while (p < ch.namedChildCount()) : (p += 1) {
            try params.append(alloc, ch.namedChild(p).text());
            try hints.append(alloc, .unknown);
        }
        body_from = i + 1;
        break;
    }

    // NAMED BY WHERE IT IS IN ITS FILE, not by how many functions came
    // before it and not by which file that is.
    //
    // A lambda's name reaches the user: Ring's call chain prints it. It was
    // the index in `funcs`, so the same lambda in the same file was
    // `@@lambda5` compiled as a whole unit and `@@lambda45305` compiled on
    // top of a prefix -- the same code, two reports. The FILE index is no
    // better: the library takes indices 0..611 in one and the file being
    // compiled is 0 in the other. The byte offset is the one thing that does
    // not move, and it also stops every later lambda's name shifting when a
    // function is added earlier in the file.
    //
    // Two lambdas in two files can share it. Nothing looks a lambda up by
    // name -- a closure carries the function id -- and the name is for the
    // error report, which names the file beside it.
    var nm_buf: [40]u8 = undefined;
    const nm = std.fmt.bufPrint(&nm_buf, "@@lambda{d}", .{n.startByte()}) catch
        return Error.OutOfMemory;
    const owned = alloc.dupe(u8, nm) catch return Error.OutOfMemory;

    const idx: u32 = @intCast(c.funcs.items.len);
    try c.funcs.append(alloc, .{
        .name = owned,
        .node = n,
        .params = try params.toOwnedSlice(alloc),
        .id = idx,
        .body_from = std.math.maxInt(u32),
        .stmts = .{},
        .hints = try hints.toOwnedSlice(alloc),
        .owner = null,
        .name_idx = try c.nameIndex(owned),
        .called = true,
        .lambda_at = at,
        .encl = owner_fi,
    });

    // the body: every child after the param list
    var b: u32 = body_from;
    while (b < n.namedChildCount()) : (b += 1) {
        try c.funcs.items[idx].stmts.append(alloc, n.namedChild(b));
    }

    // CAPTURES: a bare name READ in the body that is neither one of this
    // lambda's parameters nor assigned inside it. Deliberately
    // self-contained -- an earlier version asked whether the name was a
    // local of the ENCLOSING function, which is unknowable here: locals
    // are populated by codegen, and this pre-pass runs before it. That
    // version captured parameters and silently missed locals.
    //
    // Rule A is what makes the self-contained rule sound: a bare name is
    // a local, so a bare name this lambda does not define must come from
    // outside it.
    var assigned = std.ArrayListUnmanaged([]const u8){};
    defer assigned.deinit(alloc);
    for (c.funcs.items[idx].stmts.items) |st| {
        try scanAssigned(c, &assigned, st, alloc);
    }
    for (c.funcs.items[idx].stmts.items) |st| {
        try scanCaptures(c, assigned.items, idx, st, alloc);
    }

    // lambdas nested inside this one
    for (c.funcs.items[idx].stmts.items) |st| {
        try lowerLambdas(c, idx, st, alloc);
    }
}

/// Names this lambda assigns, which are its own locals rather than
/// captures.
fn scanAssigned(c: *Compiler, out: *std.ArrayListUnmanaged([]const u8), n: ts.Node, alloc: std.mem.Allocator) Error!void {
    if (std.mem.eql(u8, n.kind(), "assignment_expression") and n.namedChildCount() > 0) {
        const lhs = n.namedChild(0);
        if (std.mem.eql(u8, lhs.kind(), "identifier")) {
            try out.append(alloc, lhs.text());
        }
    }
    // A loop variable is seeded like any assigned name, so the classify pass
    // -- which reasons by NAME before any code exists -- knows it and every
    // value derived from it (`k = i * i`) as an integer: without the seed
    // Sieve lost its typed paths and ran 62 -> 90 ms. The loop itself takes
    // the seeded local as its variable and RETIRES it after (C-11), so no
    // local of that name is left to answer a read after the loop.
    if (std.mem.eql(u8, n.kind(), "for_statement") and n.namedChildCount() > 0) {
        const v = n.namedChild(0);
        if (std.mem.eql(u8, v.kind(), "identifier")) try out.append(alloc, v.text());
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        try scanAssigned(c, out, n.namedChild(i), alloc);
    }
}

fn scanCaptures(c: *Compiler, assigned: []const []const u8, lam: u32, n: ts.Node, alloc: std.mem.Allocator) Error!void {
    const k = n.kind();
    // a callee NAME is not a capture -- but a callee that is a member
    // expression has a receiver, and the receiver is a value: in
    // `func { _me_.Tick() }` (stzSoundTransport:261) `_me_` was never
    // captured because the whole of `_me_.Tick` was skipped as the callee.
    if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() > 0) {
        const callee = n.namedChild(0);
        if (!std.mem.eql(u8, callee.kind(), "identifier")) {
            try scanCaptures(c, assigned, lam, callee, alloc);
        }
        var ai: u32 = 1;
        while (ai < n.namedChildCount()) : (ai += 1) {
            try scanCaptures(c, assigned, lam, n.namedChild(ai), alloc);
        }
        return;
    }
    // `o.Method` -- the receiver is a value, the member is a name
    if (std.mem.eql(u8, k, "member_expression") and n.namedChildCount() > 0) {
        try scanCaptures(c, assigned, lam, n.namedChild(0), alloc);
        return;
    }
    if (std.mem.eql(u8, k, "identifier")) {
        const nm = n.text();
        if (nm.len == 0 or nm[0] == '@' or nm[0] == '$') return;
        for (c.funcs.items[lam].params) |p| {
            if (std.ascii.eqlIgnoreCase(p, nm)) return;
        }
        for (assigned) |a| {
            if (std.ascii.eqlIgnoreCase(a, nm)) return;
        }
        for (c.funcs.items[lam].captures.items) |cap| {
            if (std.ascii.eqlIgnoreCase(cap, nm)) return;
        }
        try c.funcs.items[lam].captures.append(alloc, nm);
        return;
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        try scanCaptures(c, assigned, lam, n.namedChild(i), alloc);
    }
}

/// Walk a statement, registering `@attr` against the owning class and
/// `$global` against the program. Purely lexical -- no inference.
fn ruleAScan(c: *Compiler, f: *Func, n: ts.Node, alloc: std.mem.Allocator) Error!void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "identifier")) {
        const nm = n.text();
        if (nm.len > 1 and nm[0] == '@') {
            if (f.owner) |oid| {
                const ci = &c.classes.items[oid];
                for (ci.attrs.items) |a| {
                    if (std.ascii.eqlIgnoreCase(a.name, nm)) return;
                }
                try ci.attrs.append(alloc, .{ .name = nm, .slot = 0 });
            }
            return;
        }
        if (nm.len > 1 and nm[0] == '$') {
            for (c.globals.items) |g| {
                if (std.ascii.eqlIgnoreCase(g, nm)) return;
            }
            try c.globals.append(alloc, nm);
            return;
        }
        return;
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        try ruleAScan(c, f, n.namedChild(i), alloc);
    }
}

/// Every name a class-region statement assigns becomes an attribute of the
/// object, as Ring's region is the object's own scope (F-121): `total = 0`,
/// a `z` assigned inside an `if`, a numeric loop's variable. In source order,
/// which is the order attributes() lists them on Ring for straight-line code.
/// Not inside a brace (`new Friend { name = "a" }` and `o { v = 2 }` write
/// the OTHER object), a lambda or a nested definition. A `$name` is the
/// global (Rule A), and a for-in's variable stays the prologue's local.
fn registerRegionNames(c: *Compiler, cid: u16, n: ts.Node, alloc: std.mem.Allocator) !void {
    try regionNamesInto(&c.classes.items[cid], n, alloc);
}

/// The walk itself, for a class not yet in `c.classes` (pass 1 builds it
/// locally) as well as one that is.
fn regionNamesInto(ci: anytype, n: ts.Node, alloc: std.mem.Allocator) !void {
    const k = n.kind();
    // (a private_section is walked statement by statement by its caller)
    if (std.mem.eql(u8, k, "new_expression") or std.mem.eql(u8, k, "brace_expression") or
        std.mem.eql(u8, k, "anonymous_function") or std.mem.eql(u8, k, "function_definition") or
        std.mem.eql(u8, k, "class_definition") or std.mem.eql(u8, k, "private_section")) return;
    var name: []const u8 = "";
    if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() > 0 and
        std.mem.eql(u8, n.namedChild(0).kind(), "identifier")) name = n.namedChild(0).text();
    // `this.name = v` and `self.name = v` in the region declare `name` too
    // (Ring's oop-36 sample: the class body sets this.name and this.version)
    if (std.mem.eql(u8, k, "assignment_expression") and n.namedChildCount() > 0 and
        std.mem.eql(u8, n.namedChild(0).kind(), "member_expression"))
    {
        const m = n.namedChild(0);
        if (m.namedChildCount() == 2) {
            const recv = m.namedChild(0).text();
            if ((std.ascii.eqlIgnoreCase(recv, "this") or std.ascii.eqlIgnoreCase(recv, "self")) and
                std.mem.eql(u8, m.namedChild(1).kind(), "identifier")) name = m.namedChild(1).text();
        }
    }
    if (std.mem.eql(u8, k, "for_statement") and !Compiler.forIsIn(n) and n.namedChildCount() > 0 and
        std.mem.eql(u8, n.namedChild(0).kind(), "identifier")) name = n.namedChild(0).text();
    if (name.len > 0 and name[0] != '$') {
        var have = false;
        for (ci.attrs.items) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) have = true;
        }
        if (!have) try ci.attrs.append(alloc, .{ .name = name, .slot = 0 });
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) try regionNamesInto(ci, n.namedChild(i), alloc);
}

/// Create the synthetic prologue method for a class. It takes only the
/// receiver, so its register 0 is the object whose slots it fills.
fn newPrologue(c: *Compiler, cid: u16, alloc: std.mem.Allocator) !void {
    var params = std.ArrayListUnmanaged([]const u8){};
    var hints = std.ArrayListUnmanaged(Class){};
    try params.append(alloc, "this");
    try hints.append(alloc, .ref);
    try c.funcs.append(alloc, .{
        .name = PROLOGUE,
        .node = c.classes.items[cid].node,
        .params = try params.toOwnedSlice(alloc),
        .id = @intCast(c.funcs.items.len),
        .body_from = std.math.maxInt(u32), // statements come positionally
        .stmts = .{},
        .hints = try hints.toOwnedSlice(alloc),
        .owner = cid,
        .name_idx = try c.nameIndex(PROLOGUE),
        .called = true,
    });
    c.classes.items[cid].attrs_fn = @intCast(c.funcs.items.len - 1);
}

/// A child runs its parent's initialisers first. Slots are inherited, so
/// the parent's statements can simply be copied in front of the child's --
/// one call at the `new` site then covers the whole chain.
fn graftPrologue(c: *Compiler, cid: u16, alloc: std.mem.Allocator) !void {
    // Rebuilt every pass, for the reason resolveAllSlots exists: a parent
    // read AFTER its child was frozen with a one-shot flag, and the child's
    // instances then started life without the parent's initialisers -- the
    // parent's own `cTag = "parent"` read back as R24, uninitialised.
    if (c.classes.items[cid].graft_pass == c.resolve_pass) return;
    if (c.classes.items[cid].grafting) return; // a cycle in `from`
    c.classes.items[cid].grafting = true;
    defer c.classes.items[cid].grafting = false;
    c.classes.items[cid].graft_pass = c.resolve_pass;
    c.classes.items[cid].parent_prologue = null;
    const pid = c.classes.items[cid].parent orelse return;
    try graftPrologue(c, pid, alloc);
    const pfn = c.classes.items[pid].attrs_fn orelse return;
    if (c.funcs.items[pfn].stmts.items.len == 0) {
        // compiled already (the prefix) but nothing to copy: call it instead
        if (c.funcs.items[pfn].emitted) {
            if (c.classes.items[cid].attrs_fn == null) try newPrologue(c, cid, alloc);
            c.classes.items[cid].parent_prologue = pfn;
        }
        return;
    }
    if (c.classes.items[cid].attrs_fn == null) try newPrologue(c, cid, alloc);
    const cfn = c.classes.items[cid].attrs_fn.?;
    // The class's OWN statements are whatever follows the ones an earlier
    // pass copied in front of them.
    const g = c.classes.items[cid].grafted;
    var merged = std.ArrayListUnmanaged(ts.Node){};
    for (c.funcs.items[pfn].stmts.items) |st| try merged.append(alloc, st);
    const from_parent: u32 = @intCast(merged.items.len);
    for (c.funcs.items[cfn].stmts.items[g..]) |st| try merged.append(alloc, st);
    c.funcs.items[cfn].stmts.deinit(alloc);
    c.funcs.items[cfn].stmts = merged;
    c.classes.items[cid].grafted = from_parent;
}

/// The number of arguments a call must pass: a method's `params` begins
/// with the receiver (`this`, register 0, added by startFunc), which no
/// call spells.
fn declaredArity(f: *const Func) usize {
    const recv = f.owner != null and f.params.len > 0 and std.mem.eql(u8, f.params[0], "this");
    return f.params.len - @intFromBool(recv);
}

/// Register a function or method. A method's register 0 is the receiver, so
/// its declared parameters start at r1.
fn startFunc(c: *Compiler, n: ts.Node, owner: ?u16, alloc: std.mem.Allocator) !void {
    const name = n.namedChild(0).text();
    var params = std.ArrayListUnmanaged([]const u8){};
    var hints = std.ArrayListUnmanaged(Class){};
    if (owner != null) {
        try params.append(alloc, "this");
        try hints.append(alloc, .ref);
    }
    var from: u32 = 1;
    if (n.namedChildCount() > 1 and std.mem.eql(u8, n.namedChild(1).kind(), "param_list")) {
        const pl = n.namedChild(1);
        var p: u32 = 0;
        while (p < pl.namedChildCount()) : (p += 1) {
            const pn = pl.namedChild(p);
            if (std.mem.eql(u8, pn.kind(), "typed_parameter")) {
                try params.append(alloc, pn.namedChild(1).text());
                try hints.append(alloc, classOfTypeName(pn.namedChild(0).text()));
            } else {
                try params.append(alloc, pn.text());
                try hints.append(alloc, .unknown);
            }
        }
        from = 2;
    }
    // The body arrives entirely from collectAll's positional pass, so a
    // statement the tree DID nest is not also added here and compiled twice.
    const stmts = std.ArrayListUnmanaged(ts.Node){};
    try c.funcs.append(alloc, .{
        .name = name,
        .node = n,
        .params = try params.toOwnedSlice(alloc),
        .id = @intCast(c.funcs.items.len),
        .body_from = from,
        .stmts = stmts,
        .hints = try hints.toOwnedSlice(alloc),
        .owner = owner,
        .name_idx = try c.nameIndex(name),
        // A METHOD IS NEVER "CALLED" AS FAR AS INFERENCE CAN SEE, and this
        // said the opposite. `called` has exactly one reader: the rule that
        // widens a parameter to `.ref` when no call site was observed. Only
        // promoteCallArgs sets it, and it resolves plain names through
        // findFunc -- which skips every method (catchUpFuncs and
        // findFuncSlow both test `owner == null`). So a method's parameter
        // classes came from ASSIGNMENTS IN ITS OWN BODY alone, with nothing
        // to say what a caller passes.
        //
        // `def Parse(pnStart, pnEnd, pnStep)` holding `pnEnd = len(aList)`
        // -- in a branch that never ran -- was enough to prove pnEnd an
        // integer. It was then cleared from the frame mask, so the list the
        // caller passed was never retained and the frame sweep freed it
        // with the caller still holding it. The key inside it came back as
        // pointer-shaped bytes, and only the LAST argument survived,
        // because only its register had not yet been reused.
        .called = false,
    });
}

/// Link every `from <name>` and lay out every class, parents first.
///
/// It runs AFTER all the files are collected, and that is the whole point:
/// a class may name a parent that has not been read yet. Softanza loads
/// `number/stzListOfNumbers.ring` at line 58 of stzBase and the `stzList`
/// it inherits from at line 253, so the child was frozen with no parent,
/// its own twelve attributes, and none of stzList's eighty-four. The
/// inherited method `_EngineListFromContent` then read `@aContent` at slot
/// 39 of an object that had twelve, and five tests in the wide clock died
/// on the same line.
fn resolveAllSlots(c: *Compiler, alloc: std.mem.Allocator) !void {
    for (c.classes.items) |*ci| {
        if (ci.parent_name.len == 0) continue;
        for (c.classes.items) |*p| {
            if (std.ascii.eqlIgnoreCase(p.name, ci.parent_name)) ci.parent = p.id;
        }
    }
    c.resolve_pass += 1;
    for (c.classes.items) |*ci| try resolveSlots(c, ci, alloc);
    var gi: u16 = 0;
    while (gi < c.classes.items.len) : (gi += 1) try graftPrologue(c, gi, alloc);
}

fn resolveSlots(c: *Compiler, ci: *ClassInfo, alloc: std.mem.Allocator) !void {
    if (ci.pass == c.resolve_pass) return;
    if (ci.resolving) return; // a cycle in `from` -- lay it out as its own
    ci.resolving = true;
    defer ci.resolving = false;
    ci.pass = c.resolve_pass;

    // What this class DECLARES is whatever follows the prefix an earlier
    // pass copied in from the parent.
    var own = std.ArrayListUnmanaged(Attr){};
    defer own.deinit(alloc);
    for (ci.attrs.items[ci.inherited..]) |a| try own.append(alloc, a);

    var out = std.ArrayListUnmanaged(Attr){};
    var inherited: u32 = 0;
    if (ci.parent) |pid| {
        const p = &c.classes.items[pid];
        try resolveSlots(c, p, alloc);
        // inherited slots keep their indices, so a parent method compiled
        // once works on any child
        for (p.attrs.items) |a| try out.append(alloc, a);
        inherited = @intCast(out.items.len);
    }
    // RING MERGES A REDECLARED ATTRIBUTE, measured on 1.27: a child that
    // names one of its parent's again gets ONE property, not two, and both
    // classes' methods read and write the same storage. `stzListOfNumbers`
    // redeclares `@aContent`, which is exactly the shape.
    outer: for (own.items) |a| {
        for (out.items) |b| {
            if (std.ascii.eqlIgnoreCase(a.name, b.name)) continue :outer;
        }
        try out.append(alloc, a);
    }
    ci.attrs.deinit(alloc);
    ci.attrs = out;
    ci.inherited = inherited;
    for (ci.attrs.items, 0..) |*a, idx| a.slot = @intCast(idx);
}

/// One CONSTRUCT, and what building it would free. Ranking single roots
/// understates a construct badly: `classname()` is eleven separate roots,
/// and a function held by two of them is freed by neither alone.
pub const GroupRank = struct {
    key: []const u8,
    roots: u32,
    unlocked: u32,
    /// One root carrying this key, so an entry names a place to go rather
    /// than a category to think about.
    example_fn: []const u8 = "",
    example_row: u32 = 0,
    example_text: []const u8 = "",
};

pub const Ranking = struct {
    roots: []PoisonRank = &.{},
    groups: []GroupRank = &.{},
};

/// The construct a refusal is really about. Two `call_expression`s are the
/// same row in a census and completely different work, so calls group by
/// CALLEE -- `classname` is one job, `substr` is another.
fn constructKey(kind: []const u8, text: []const u8) []const u8 {
    if (!std.mem.eql(u8, kind, "call_expression")) return kind;
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return kind;
    var s = open;
    while (s > 0) {
        const ch = text[s - 1];
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '@') break;
        s -= 1;
    }
    return if (s == open) kind else text[s..open];
}

/// One root function, and how much of the library it is holding hostage.
pub const PoisonRank = struct {
    /// Functions that become usable if THIS one is fixed, this one included.
    unlocked: u32,
    name: []const u8,
    /// Why its own body failed -- the first refusal recorded against it.
    kind: []const u8 = "",
    row: u32 = 0,
    text: []const u8 = "",
};

fn orRow(dst: []u64, di: usize, src: []const u64, si: usize, w: usize) bool {
    var ch = false;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const before = dst[di * w + i];
        const after = before | src[si * w + i];
        if (after != before) {
            dst[di * w + i] = after;
            ch = true;
        }
    }
    return ch;
}

/// Rank the own-body failures by how many functions each one is holding
/// hostage, greedily.
///
/// The census says 98% of statements compile while only 36% of functions
/// are usable, and the gap is entirely propagation: 824 own-body failures
/// poison 27,062 functions. So the useful question is not "what is
/// refused" but "WHICH refusals are load-bearing".
///
/// A function is freed by fixing root r only if r is the ONLY root that
/// reaches it -- freeing one of two captors frees nobody. So this
/// propagates a SET of roots per function instead of a boolean, over the
/// same three edge kinds `spreadPoison` uses, and reads the answer off the
/// sets with exactly one member. Clearing a root's bit everywhere is
/// exactly the state after fixing it, because the sets are unions along
/// edges -- so the greedy pass needs no second fixpoint.
fn rankPoison(c: *Compiler, alloc: std.mem.Allocator, take: usize) !Ranking {
    var roots = std.ArrayListUnmanaged(u32){};
    defer roots.deinit(alloc);
    for (c.funcs.items, 0..) |f, i| {
        if (f.poisoned_own) try roots.append(alloc, @intCast(i));
    }
    const nr = roots.items.len;
    if (nr == 0) return .{};

    const nf = c.funcs.items.len;
    const w = (nr + 63) / 64;
    const sets = try alloc.alloc(u64, nf * w);
    defer alloc.free(sets);
    @memset(sets, 0);
    for (roots.items, 0..) |fi, r| {
        sets[@as(usize, fi) * w + r / 64] |= @as(u64, 1) << @intCast(r % 64);
    }

    const nnm = if (c.names.items.len == 0) 1 else c.names.items.len;
    const name_sets = try alloc.alloc(u64, nnm * w);
    defer alloc.free(name_sets);

    var round: u32 = 0;
    const t_fix = std.time.milliTimestamp();
    while (round < 64) : (round += 1) {
        var changed = false;
        @memset(name_sets, 0);
        for (c.funcs.items, 0..) |g, gi| {
            if (g.owner == null or g.name_idx >= nnm) continue;
            _ = orRow(name_sets, g.name_idx, sets, gi, w);
        }
        for (c.fixups.items) |fx| {
            if (orRow(sets, fx.from, sets, fx.fidx, w)) changed = true;
        }
        for (c.funcs.items, 0..) |f, i| {
            for (f.calls_static.items) |mi| {
                if (orRow(sets, i, sets, mi, w)) changed = true;
            }
            for (f.calls_named.items) |ni| {
                if (ni < nnm and orRow(sets, i, name_sets, ni, w)) changed = true;
            }
        }
        if (!changed) break;
    }
    if (c.rank_verbose) {
        var edges: usize = c.fixups.items.len;
        for (c.funcs.items) |f| edges += f.calls_static.items.len + f.calls_named.items.len;
        std.debug.print(
            "  [rank] roots {d}  words/set {d}  edges {d}  rounds {d}  fixpoint {d} ms\n",
            .{ nr, w, edges, round + 1, std.time.milliTimestamp() - t_fix },
        );
    }

    // ---- the same sets, read by CONSTRUCT --------------------------------
    //
    // Done before the per-root greedy, because that one destroys the sets.
    const keys = try alloc.alloc([]const u8, nr);
    defer alloc.free(keys);
    for (roots.items, 0..) |fi, r| {
        keys[r] = "unknown";
        for (c.refusals.items) |rf| {
            if (std.ascii.eqlIgnoreCase(rf.func, c.funcs.items[fi].name)) {
                keys[r] = constructKey(rf.kind, rf.text);
                break;
            }
        }
    }

    var groups = std.ArrayListUnmanaged(GroupRank){};
    {
        // DISTINCT keys, each with the fixed set of roots carrying it. The
        // first version of this scanned all 824 roots per greedy step and
        // ran for over ten minutes: 14 billion word operations for an answer
        // that needs 40 keys, not 824 roots. A group is chosen or not chosen
        // as a whole, so its root mask never changes and is built once.
        var kname = std.ArrayListUnmanaged([]const u8){};
        defer kname.deinit(alloc);
        var kcount = std.ArrayListUnmanaged(u32){};
        defer kcount.deinit(alloc);
        const kof = try alloc.alloc(u32, nr);
        defer alloc.free(kof);
        for (keys, 0..) |k, r| {
            var found: ?u32 = null;
            for (kname.items, 0..) |kk, ki| {
                if (std.mem.eql(u8, kk, k)) {
                    found = @intCast(ki);
                    break;
                }
            }
            if (found) |ki| {
                kof[r] = ki;
                kcount.items[ki] += 1;
            } else {
                kof[r] = @intCast(kname.items.len);
                try kname.append(alloc, k);
                try kcount.append(alloc, 1);
            }
        }
        const nk = kname.items.len;

        // only functions that are actually held need looking at
        var held = std.ArrayListUnmanaged(u32){};
        defer held.deinit(alloc);
        for (c.funcs.items, 0..) |f, i| {
            if (f.poisoned) try held.append(alloc, @intCast(i));
        }

        const done = try alloc.alloc(bool, nk);
        defer alloc.free(done);
        @memset(done, false);
        const work = try alloc.alloc(u64, nf * w);
        defer alloc.free(work);
        @memcpy(work, sets);

        // Count every key in ONE pass over the held functions instead of
        // scanning all held functions once per key. Softanza has hundreds of
        // distinct callees, so the per-key loop was ~3 billion word ops; this
        // asks each held function which keys hold it and stops at the second
        // distinct one, which is where nearly all of them stop.
        const counts_k = try alloc.alloc(u32, nk);
        defer alloc.free(counts_k);

        var g: usize = 0;
        while (g < take) : (g += 1) {
            @memset(counts_k, 0);
            for (held.items) |fi| {
                var only: ?u32 = null;
                var multi = false;
                var i: usize = 0;
                while (i < w and !multi) : (i += 1) {
                    var bits = work[@as(usize, fi) * w + i];
                    while (bits != 0) {
                        const r = i * 64 + @ctz(bits);
                        const k = kof[r];
                        if (only == null) {
                            only = k;
                        } else if (only.? != k) {
                            multi = true;
                            break;
                        }
                        bits &= bits - 1;
                    }
                }
                if (!multi) {
                    if (only) |k| counts_k[k] += 1;
                }
            }

            var best: usize = 0;
            var best_n: u32 = 0;
            for (counts_k, 0..) |n, ki| {
                if (!done[ki] and n > best_n) {
                    best_n = n;
                    best = ki;
                }
            }
            if (best_n == 0) break;

            var ge = GroupRank{
                .key = kname.items[best],
                .roots = kcount.items[best],
                .unlocked = best_n,
            };
            for (kof, 0..) |ko, r| {
                if (ko != best) continue;
                const fname = c.funcs.items[roots.items[r]].name;
                for (c.refusals.items) |rf| {
                    if (!std.ascii.eqlIgnoreCase(rf.func, fname)) continue;
                    ge.example_fn = fname;
                    ge.example_row = rf.row;
                    ge.example_text = rf.text;
                    break;
                }
                break;
            }
            try groups.append(alloc, ge);
            done[best] = true;
            for (kof, 0..) |ko, r| {
                if (ko != best) continue;
                const m = ~(@as(u64, 1) << @intCast(r % 64));
                for (held.items) |fj| work[@as(usize, fj) * w + r / 64] &= m;
            }
        }
    }

    // ---- greedy: take the biggest, clear it, look again ------------------
    var out = std.ArrayListUnmanaged(PoisonRank){};
    const counts = try alloc.alloc(u32, nr);
    defer alloc.free(counts);
    const fixed = try alloc.alloc(bool, nr);
    defer alloc.free(fixed);
    @memset(fixed, false);

    var k: usize = 0;
    while (k < take) : (k += 1) {
        @memset(counts, 0);
        var fi: usize = 0;
        while (fi < nf) : (fi += 1) {
            // exactly one root reaches this function?
            var total: u32 = 0;
            var which: usize = 0;
            var i: usize = 0;
            while (i < w) : (i += 1) {
                const bits = sets[fi * w + i];
                if (bits == 0) continue;
                total += @popCount(bits);
                if (total > 1) break;
                which = i * 64 + @ctz(bits);
            }
            if (total == 1) counts[which] += 1;
        }

        var best: usize = 0;
        var best_n: u32 = 0;
        for (counts, 0..) |n, r| {
            if (!fixed[r] and n > best_n) {
                best_n = n;
                best = r;
            }
        }
        if (best_n == 0) break;

        const bf = roots.items[best];
        var e = PoisonRank{ .unlocked = best_n, .name = c.funcs.items[bf].name };
        for (c.refusals.items) |rf| {
            if (std.ascii.eqlIgnoreCase(rf.func, e.name)) {
                e.kind = rf.kind;
                e.row = rf.row;
                e.text = rf.text;
                break;
            }
        }
        try out.append(alloc, e);

        fixed[best] = true;
        const mask = ~(@as(u64, 1) << @intCast(best % 64));
        var fj: usize = 0;
        while (fj < nf) : (fj += 1) sets[fj * w + best / 64] &= mask;
    }
    return .{
        .roots = try out.toOwnedSlice(alloc),
        .groups = try groups.toOwnedSlice(alloc),
    };
}

fn spreadPoison(c: *Compiler) usize {
    // Which METHOD NAMES have at least one poisoned implementation. Rebuilt
    // once per round: checking it per call site instead would be O(n^2) on
    // 43,000 functions, which is minutes rather than milliseconds.
    const nnm = c.names.items.len;
    const bad_name = c.alloc.alloc(bool, if (nnm == 0) 1 else nnm) catch return 0;
    defer c.alloc.free(bad_name);

    var dynamic_hits: usize = 0;
    var round: u32 = 0;
    while (round < 64) : (round += 1) {
        var changed = false;

        @memset(bad_name, false);
        for (c.funcs.items) |g| {
            if (g.poisoned and g.owner != null and g.name_idx < nnm) bad_name[g.name_idx] = true;
        }

        // direct calls: a caller inherits its callee's poison
        for (c.fixups.items) |fx| {
            if (c.funcs.items[fx.fidx].poisoned and !c.funcs.items[fx.from].poisoned) {
                c.funcs.items[fx.from].poisoned = true;
                changed = true;
            }
        }

        // method calls whose receiver class was proved: one real edge
        for (c.funcs.items, 0..) |f, i| {
            if (f.poisoned) continue;
            for (f.calls_static.items) |mi| {
                if (c.funcs.items[mi].poisoned) {
                    c.funcs.items[i].poisoned = true;
                    changed = true;
                    break;
                }
            }
        }

        // dynamic method calls: the receiver's class is a runtime fact, so
        // any same-named method being poisoned poisons the caller
        for (c.funcs.items, 0..) |f, i| {
            if (f.poisoned) continue;
            for (f.calls_named.items) |ni| {
                if (ni < nnm and bad_name[ni]) {
                    c.funcs.items[i].poisoned = true;
                    dynamic_hits += 1;
                    changed = true;
                    break;
                }
            }
        }

        if (!changed) break;
    }
    return dynamic_hits;
}

/// Emit every function. In lenient mode a function whose codegen fails is
/// marked unusable and the rest still compile -- one unsupported construct
/// must not cost the whole library.
// A per-function arena probe lived here for one afternoon and was WRONG, in
// a way worth recording. ArenaAllocator grows by allocating a new chunk about
// the size of everything before it, so `queryCapacity` climbs in doublings:
// the probe reported that `AddRoute` -- a one-line function -- allocated
// 196 MB, when all it had done was be the function that crossed a chunk
// boundary. Attributing memory to a caller by watching an arena's capacity
// does not work. The counting allocator in rnxc.zig, which tallies what was
// actually ASKED for, is what replaced it.
/// EVAL (F-72): compile `src` in the frame `ev` describes. The persistent
/// eval Compiler's per-call lists are cleared (their capacity kept, so a
/// loop that evals per item allocates nothing new); its name table and
/// globals were seeded once from the VM's and are frozen. Returns the code
/// from address 0, the constants to append (headers in the scratch arena,
/// bytes in the snippet: the caller copies them out), and the high mark.
/// RING'S REPORT OF AN EVAL STRING THAT DOES NOT PARSE (F-108, measured on
/// 1.27): `eval Line (N) Error (Cxx) : <message>` for each line with an error,
/// in order, then `eval errors count : K` -- every line starting with a
/// newline -- and R42 is raised after it, catchable. An unclosed structure is
/// reported at the string's LAST line, where Ring's parser ran out of input
/// (`if` on line 2 of three is C3 on line 3); an error token at its own line.
/// An unclosed string literal is the scanner's error, in its own form, and
/// stops before any parse. The codes are read off tree-sitter's MISSING
/// tokens and ERROR nodes; whatever none of them names is C27.
fn evalSyntaxReport(c: *Compiler, root: ts.Node, src: []const u8) Error!void {
    const SynErr = struct { line: u32, msg: []const u8 };
    var errs = std.ArrayListUnmanaged(SynErr){};
    defer errs.deinit(c.alloc);
    var trimmed = src;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) trimmed = trimmed[0 .. trimmed.len - 1];
    var last: u32 = 1;
    for (trimmed) |ch| {
        if (ch == '\n') last += 1;
    }
    var s1_line: ?u32 = null;
    const W = struct {
        fn closer(k: []const u8) ?[]const u8 {
            const tab = [_][2][]const u8{
                .{ "ok", "Error (C3) : Unclosed control structure, 'ok' is missing" },
                .{ "end", "Error (C4) : Unclosed control structure, 'end' is missing" },
                .{ "next", "Error (C5) : Unclosed control structure, next is missing" },
                .{ "again", "Error (C21) : Unclosed control structure, 'again' is missing" },
                .{ "catch", "Error (C14) : Try/Catch miss the Catch keyword!" },
                .{ "done", "Error (C15) : Try/Catch miss the Done keyword!" },
                .{ "off", "Error (C17) : Switch statement without OFF" },
                .{ "}", "Error (C18) : Missing closing brace for the block opened!" },
            };
            for (tab) |e| {
                if (std.ascii.eqlIgnoreCase(k, e[0])) return e[1];
            }
            return null;
        }
        fn opener(k: []const u8) ?[]const u8 {
            const tab = [_][2][]const u8{
                .{ "if", "ok" },     .{ "while", "end" }, .{ "for", "next" }, .{ "do", "again" },
                .{ "try", "catch" }, .{ "switch", "off" }, .{ "{", "}" },
            };
            for (tab) |e| {
                if (std.ascii.eqlIgnoreCase(k, e[0])) return closer(e[1]);
            }
            return null;
        }
        /// The structure a MISSING closer belongs to decides the code, not the
        /// token tree-sitter's recovery happened to pick (`}` for an open
        /// `for`, since the grammar has a braced for too).
        fn ofStructure(k: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, k, "if_statement")) return closer("ok");
            if (std.mem.eql(u8, k, "while_statement")) return closer("end");
            if (std.mem.eql(u8, k, "for_statement") or std.mem.eql(u8, k, "for_in_statement")) return closer("next");
            if (std.mem.eql(u8, k, "do_again_statement")) return closer("again");
            if (std.mem.eql(u8, k, "switch_statement")) return closer("off");
            if (std.mem.eql(u8, k, "anonymous_function")) return closer("}");
            return null;
        }
        fn walk(n: ts.Node, lastl: u32, out: *std.ArrayListUnmanaged(SynErr), a: std.mem.Allocator, s1: *?u32, structure: []const u8) !void {
            const row: u32 = @intCast(n.start().row);
            const line: u32 = if (row < 1) 1 else @min(row, lastl);
            if (n.isMissing()) {
                const k = n.kind();
                if (std.mem.eql(u8, k, "'") or std.mem.eql(u8, k, "\"") or std.mem.eql(u8, k, "`")) {
                    if (s1.* == null) s1.* = line;
                } else if (std.mem.eql(u8, k, ")")) {
                    try out.append(a, .{ .line = line, .msg = "Error (C8) : Parentheses ')' is missing" });
                } else if (std.mem.eql(u8, k, "]")) {
                    try out.append(a, .{ .line = line, .msg = "Error (C7) : Error in list items" });
                } else if (closer(k)) |m| {
                    // try's own two keep their own codes; the rest go by the
                    // structure they close
                    const mm = if (std.ascii.eqlIgnoreCase(k, "catch") or std.ascii.eqlIgnoreCase(k, "done")) m else (ofStructure(structure) orelse m);
                    try out.append(a, .{ .line = lastl, .msg = mm });
                } else {
                    try out.append(a, .{ .line = line, .msg = "Error (C27) : Syntax Error!" });
                }
                return;
            }
            if (n.isError()) {
                // a token inside the ERROR node names the structure left open:
                // a keyword (reported at the last line), or a list's `[` or a
                // call's `(` (at their own line)
                var i: u32 = 0;
                while (i < n.childCount()) : (i += 1) {
                    const ck = n.child(i).kind();
                    if (std.mem.eql(u8, ck, "[")) {
                        try out.append(a, .{ .line = line, .msg = "Error (C7) : Error in list items" });
                        return;
                    }
                    if (std.mem.eql(u8, ck, "(")) {
                        try out.append(a, .{ .line = line, .msg = "Error (C8) : Parentheses ')' is missing" });
                        return;
                    }
                    if (opener(ck)) |m| {
                        try out.append(a, .{ .line = lastl, .msg = m });
                        return;
                    }
                }
                try out.append(a, .{ .line = line, .msg = "Error (C27) : Syntax Error!" });
                return;
            }
            // an unclosed literal: a string node that runs to the end of the text
            if (std.mem.eql(u8, n.kind(), "string") and n.hasError()) {
                if (s1.* == null) s1.* = line;
                return;
            }
            const k = n.kind();
            const st = if (ofStructure(k) != null) k else structure;
            var i: u32 = 0;
            while (i < n.childCount()) : (i += 1) try walk(n.child(i), lastl, out, a, s1, st);
        }
    };
    try W.walk(root, last, &errs, c.alloc, &s1_line, "");
    c.eval_report.clearRetainingCapacity();
    const w = c.eval_report.writer(c.alloc);
    if (s1_line) |l| {
        try w.print("Error (S1) In file: eval \nIn Line ({d}) Literal not closed \nCalled from other source code file", .{l});
        return;
    }
    if (errs.items.len == 0) try errs.append(c.alloc, .{ .line = 1, .msg = "Error (C27) : Syntax Error!" });
    std.mem.sort(SynErr, errs.items, {}, struct {
        fn lt(_: void, x: SynErr, y: SynErr) bool {
            return x.line < y.line;
        }
    }.lt);
    var count: u32 = 0;
    var prev: u32 = 0;
    for (errs.items) |e| {
        if (e.line == prev) continue; // one a line, as Ring reports them
        prev = e.line;
        count += 1;
        try w.print("\neval Line ({d}) {s}\n", .{ e.line, e.msg });
    }
    try w.print("\neval errors count : {d} \n", .{count});
}

pub fn compileEval(c: *Compiler, src: []const u8, ev: *EvalCtx, locals: []const LocalSpec) Error!EvalOut {
    // THE SCRATCH ARENA IS THE CALLER'S TO RESET, before it allocates
    // `locals` from it. This reset it here, so the snippet below landed on
    // the first LocalSpec -- register 0, the first parameter -- and every
    // parameter read inside an eval string was "not a local" while the
    // locals beside it worked (2026-09-25, RNXC_TRACE_EVAL showed the
    // bindings right and the compile wrong).
    c.eval = ev;
    defer c.eval = null;
    c.code.clearRetainingCapacity();
    c.rows.clearRetainingCapacity();
    c.files.clearRetainingCapacity();
    c.fixups.clearRetainingCapacity();
    c.natives.clearRetainingCapacity();
    c.konst.clearRetainingCapacity();
    c.konst_index.clearRetainingCapacity();
    c.active_loops.clearRetainingCapacity();
    c.retired.clearRetainingCapacity();
    c.braces.clearRetainingCapacity();
    c.catch_regs.clearRetainingCapacity();
    c.breaks.clearRetainingCapacity();
    c.continues.clearRetainingCapacity();
    c.loop_try.clearRetainingCapacity();
    c.try_open = 0;
    c.try_borrows.clearRetainingCapacity();
    c.depth = 0;
    c.reread_src = null;

    const snippet = std.mem.concat(c.scratch, u8, &.{ "func __eval()\n", src, "\n" }) catch return Error.OutOfMemory;
    if (c.eval_parser == null) c.eval_parser = ts.Parser.init();
    const tree = c.eval_parser.?.parse(snippet) orelse return Error.Unsupported;
    defer tree.deinit();
    const root = tree.root();
    // A STRING THAT DOES NOT PARSE is Ring's compile report, then R42 (F-108)
    if (root.hasError()) {
        try evalSyntaxReport(c, root, src);
        c.fail_kind = "eval-syntax";
        return Error.Unsupported;
    }

    // ONE Func, reused: its lists keep their buffers
    if (c.funcs.items.len == 0) {
        try c.funcs.append(c.alloc, .{
            .name = "@@eval",
            .node = root,
            .params = &.{},
            .id = 0,
            .body_from = 0,
            .stmts = .{},
            .hints = &.{},
            .owner = null,
            .name_idx = 0,
            .called = true,
        });
    }
    const f = &c.funcs.items[0];
    f.node = root;
    f.owner = ev.owner;
    f.is_main = ev.is_main;
    f.lambda_at = null;
    f.locals.clearRetainingCapacity();
    f.captures.clearRetainingCapacity();
    f.calls_named.clearRetainingCapacity();
    f.calls_static.clearRetainingCapacity();
    for (locals) |l| {
        try f.locals.append(c.alloc, .{ .name = l.name, .reg = l.reg, .class = if (l.boxed) .ref else .int, .declared = true });
    }
    c.cur = f;
    c.high = ev.frame;
    c.floor = 0;
    c.temp = ev.frame;
    ev.next_reg = ev.frame;

    // every statement, in order, inside the func or fallen out beside it
    // (the grammar leaks a body's later statements to file level, F-21)
    var pending_return: ?u32 = null; // the row a bare `return` ended on
    var i: u32 = 0;
    while (i < root.namedChildCount()) : (i += 1) {
        const top = root.namedChild(i);
        if (std.mem.eql(u8, top.kind(), "function_definition")) {
            var ci: u32 = 0;
            while (ci < top.namedChildCount()) : (ci += 1) {
                const s = top.namedChild(ci);
                const sk = s.kind();
                if (std.mem.eql(u8, sk, "identifier") or std.mem.eql(u8, sk, "param_list") or
                    std.mem.eql(u8, sk, "comment")) continue;
                try evalStmt(c, s, &pending_return);
            }
        } else if (!std.mem.eql(u8, top.kind(), "comment")) {
            try evalStmt(c, top, &pending_return);
        }
    }
    if (pending_return != null) {
        // a bare `return` that ended the string: the eval's value is ""
        c.temp = @max(c.floor, c.bottom());
        const t = try c.tmp();
        _ = try c.emit(.loadk, t, 0, 0, try c.konstIndex("\"\""));
        _ = try c.emit(.halt, t, 0, 0, 0);
    }
    c.temp = @max(c.floor, c.bottom());
    const t = try c.tmp();
    _ = try c.emit(.loadk, t, 0, 0, try c.konstIndex("\"\""));
    _ = try c.emit(.halt, t, 0, 0, 0);
    return .{ .code = c.code.items, .konst = c.konst.items, .high = c.high };
}

/// One statement of an eval string. A function or class defined inside is
/// not in the first version (no estate site does it, F-72's census) and
/// says so; a bare `return` followed by an expression statement is the
/// split `return <expr>` the grammar produces, rejoined as emitOne does.
fn evalStmt(c: *Compiler, s: ts.Node, pending_return: *?u32) Error!void {
    const k = s.kind();
    if (std.mem.eql(u8, k, "function_definition") or std.mem.eql(u8, k, "class_definition") or
        std.mem.eql(u8, k, "method_definition"))
    {
        c.fail_kind = "eval: a function or class defined inside eval";
        c.fail_text = k;
        return Error.Unsupported;
    }
    if (pending_return.*) |ret_row| {
        pending_return.* = null;
        // only a statement on the SAME row is the split `return <expr>`; a
        // `return` that ends its line is Ring's bare return (stmt.c:931)
        if (std.mem.eql(u8, k, "expression_statement") and s.namedChildCount() == 1 and s.start().row == ret_row) {
            return c.returnExpr(s.namedChild(0));
        }
        // a bare return on its own: value "", and the rest never runs
        c.temp = @max(c.floor, c.bottom());
        const t = try c.tmp();
        _ = try c.emit(.loadk, t, 0, 0, try c.konstIndex("\"\""));
        _ = try c.emit(.halt, t, 0, 0, 0);
    }
    if (std.mem.eql(u8, k, "return_statement") and s.namedChildCount() == 0) {
        pending_return.* = s.end().row;
        return;
    }
    try c.stmt(s);
}

fn emitAll(c: *Compiler) !void {
    // From the prefix mark: everything below it is already emitted, and its
    // code sits at the front of the stream where its entries point.
    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        var res = emitOne(c, f);
        // ITS LOCALS DID NOT FIT THE WINDOW: share registers, then emit again
        // (shareFunction). This runs once per function, in pass A, whose code
        // is thrown away; pass B emits with the shared registers.
        if (f.window_full and !f.share_tried and c.eval == null) {
            f.share_tried = true;
            if (shareFunction(c, f)) res = emitOne(c, f);
        }
        res catch |e| {
            // THE CENSUS TOO. It is not lenient, so an Unsupported escaping
            // one function returned out of this loop -- and every caller in
            // the census wrote `emitAll(&c) catch {}`, so the functions after
            // it were never emitted, never counted, and the census printed
            // what it had as if it were the whole. 48,125 statements went
            // that way on 2026-09-23 while the gate reported PASS. A
            // measurement must count what it cannot do, not stop at it.
            if (e != Error.Unsupported or !(c.lenient or c.census)) return e;
            f.poisoned = true;
            c.emit_failed += 1;
        };
    }
}

/// A statement the compiler could not compile becomes a RAISE where it
/// stood, not a hole. Measured on 2026-09-04, before this existed: a
/// function whose `$acc++` was refused still ran, still returned the right
/// value for the statements that did compile, and silently left $acc
/// unchanged -- Ring said 1, Ring++ said 0, no error, "TOP LEVEL RAN TO
/// COMPLETION". A refusal is a thing the census already knows at compile
/// time; leaving it silent at run time is the one place this project does
/// the thing its own discipline forbids -- skipping a gate without saying
/// so. Now the program stops where the wall actually is.
///
/// Whatever the failed statement half-emitted is rolled back first,
/// including any call fixups pointing into it: a partly-emitted `if` can
/// leave a forward jump whose target is never patched, and truncating both
/// arrays together is what keeps the stream honest.
fn refusalTrap(c: *Compiler, st: ts.Node, mark: u32, fxmark: usize) void {
    c.code.shrinkRetainingCapacity(mark);
    // rows and files are PARALLEL to code (C-8): rolling back the code
    // without them shifted every later instruction's row and file by the
    // length of whatever the refused statement half-emitted, and the drift
    // grew with each refusal -- an R21 inside stzLog.Where() was reported
    // in stzBpmnDiagram.ring (found 2026-09-11). One truncation, three
    // arrays.
    c.rows.shrinkRetainingCapacity(mark);
    c.files.shrinkRetainingCapacity(mark);
    c.fixups.shrinkRetainingCapacity(fxmark);
    // Name the REFUSAL, not the statement around it -- its construct, its
    // text, its own line, and its own file, which is not always the file
    // the enclosing statement is in.
    const kind = if (c.last_kind.len > 0) c.last_kind else st.kind();
    const row = if (c.last_kind.len > 0) c.last_row else st.start().row + 1;
    const where = blk: {
        const p = c.last_fail_src orelse st.src.ptr;
        const fi = c.fileOf(p) orelse break :blk "";
        break :blk if (fi < load_paths.len) std.fs.path.basename(load_paths[fi]) else "";
    };
    const msg = (if (where.len > 0 and c.last_text.len > 0)
        std.fmt.allocPrint(
            c.alloc,
            "Ring++ refused this statement ({s} `{s}`, line {d} of {s}) and did not compile it -- running past it would give a wrong answer",
            .{ kind, c.last_text, row, where },
        )
    else
        std.fmt.allocPrint(
            c.alloc,
            "Ring++ refused this statement ({s}, line {d}) and did not compile it -- running past it would give a wrong answer",
            .{ kind, row },
        )) catch return;
    // cleared so the NEXT statement's trap cannot inherit this one
    c.last_kind = "";
    c.last_text = "";
    c.last_fail_src = null;
    const k = c.konstIndex(msg) catch return;
    const save = c.temp;
    defer c.temp = save;
    const t = c.tmp() catch return; // no register to build it in: leave the hole
    _ = c.emit(.loadk, t, 0, 0, k) catch return;
    _ = c.emit(.trap, t, 0, 0, 0) catch return;
}

/// Is this statement the tail the grammar leaves behind when it cuts a line
/// at a `+` or `-`: an expression statement holding nothing but a unary
/// expression with one of those two operators?
/// A statement whose text ENDS in `.` is not a statement: the member
/// access has no name yet. The grammar produces one when it cuts a call
/// chain -- `return This.CtxQ().TraceId()` comes back as a bare `return`,
/// then `This.CtxQ()` holding the dangling dot, then `TraceId()` alone,
/// re-anchored to This. So the next statement on that row CONTINUES this
/// one, and the span has to swallow it (found 2026-09-12; it is why
/// stzStopwatch.TraceId() returned an object where Ring returns a string).
///
/// Safe by construction: extending the span only asks for the joined text
/// to be re-read, and a join that does not parse backs the whole re-read
/// out, leaving the statements exactly as they were.
fn danglingDot(n: ts.Node) bool {
    const e = n.endByte();
    return e > 0 and e <= n.src.len and n.src[e - 1] == @as(u8, @intCast(46));
}

/// The value a `return` carries, or null when it is BARE. Ring's parser looks
/// at the very next token after the keyword and, finding the end of the line,
/// returns NULL (vendor/ring-vm/src/stmt.c:931); whatever stands on a later
/// row is a statement of its own that never runs. This grammar reads a newline
/// as an extra, so it hangs the NEXT ROW's expression on the `return` -- and a
/// comment on the way is the first named child. Same row or nothing.
fn retValue(n: ts.Node) ?ts.Node {
    if (n.childCount() == 0) return null;
    const row = n.child(0).end().row;
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        if (std.mem.eql(u8, ch.kind(), "comment")) continue;
        return if (ch.start().row == row) ch else null;
    }
    return null;
}

fn isSplitTail(n: ts.Node) bool {
    if (!std.mem.eql(u8, n.kind(), "expression_statement") or n.namedChildCount() != 1) return false;
    // The unary is the LEFTMOST leaf: `+ @nRe + "-" + (-@nIm) + "i"` parses
    // as binary(binary(unary(+ @nRe), "-"), ...) -- walk down the left spine.
    var e = n.namedChild(0);
    while (std.mem.eql(u8, e.kind(), "binary_expression") and e.namedChildCount() > 0) e = e.namedChild(0);
    if (!std.mem.eql(u8, e.kind(), "unary_expression")) return false;
    const op = Compiler.opText(e);
    return std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-");
}

/// The last statement of a method inside a class does not reliably stay
/// whole in the parse. `return "" + @nRe + "-" + (-@nIm) + "i"` comes back
/// as `return ""` followed by a SECOND statement, `+ @nRe + ... + "i"` -- a
/// unary plus on its own, which the compiler refused. Measured 2026-09-08
/// with `rnxc poison`: that one shape held 19,398 of Softanza's 21,823
/// unusable functions. The cut lands at a different `+` from one line to the
/// next (after the first parenthesis in stzTime:502, after `_cMid_` in
/// stzString:5746), which is what a GLR tie-break looks like from outside.
///
/// Ring reads the line greedily: on ONE row, `return E1 + E2` is one
/// expression, always (probed on the oracle). So the faithful repair is to
/// read it the same way -- take the text from this statement to the last
/// same-row tail, parse it again inside a `func`, where the grammar keeps
/// it whole, and compile THAT. A tail on a LATER row is left alone: on Ring
/// a line beginning with `+` is a statement of its own, evaluated and
/// discarded, and stmt() compiles it so.
///
/// And the grammar errs the other way too: `x = "a"` on one line and
/// `+ "b"` on the next come back JOINED as `x = "a" + "b"`, where Ring
/// leaves x as "a" and evaluates `+ "b"` as a statement of its own (probed
/// 2026-09-08: P5, P7, P8, P9). Ring's rule is the newline: it ends the
/// statement unless the line is unfinished -- a trailing operator, a comma,
/// an open bracket. So the text is cut at every newline that follows a
/// finished term and precedes a `+` or `-`, and each piece is read alone.
///
/// Returns the statements Ring reads in that span, in order, and how many
/// entries of f.stmts the span covers; null when there is nothing to re-read
/// or a piece did not come back as one statement spanning its text -- then
/// the original refusal stands, named, rather than a guess being compiled.
const Reread = struct {
    node: ts.Node,
    /// row of the piece within the original statement, for honest refusals
    row_off: u32,
    /// The grammar cut `return <expr>` into a bare return and the
    /// expression -- even alone in a func, for `return "" + @nRe + "-" +
    /// (-@nIm) + "i"` -- so the piece is the expression and the statement
    /// to emit is a return of it.
    as_return: bool = false,
};

const Parsed = struct { node: ts.Node, as_return: bool };

/// See `Compiler.reread_origin`.
const RereadOrigin = struct { src: []const u8, shift: i64 };

/// See `Compiler.absorbed`. `owner` is the function whose statement the bare return is, found once pass 2 has filed it.
const Absorbed = struct { ret_start: u32, src: []const u8, def: ts.Node, owner: u32 = std.math.maxInt(u32) };

/// A node's own address in its file: a key that two files cannot share.
fn nodeKey(n: ts.Node) usize {
    return @intFromPtr(n.src.ptr) +% n.startByte();
}

/// The end of the lambda a braced definition stands for: its closing brace (what the grammar hung after it is the enclosing function's).
fn bracedDefEnd(n: ts.Node) u32 {
    var end: u32 = n.endByte();
    var i: u32 = 0;
    while (i < n.childCount()) : (i += 1) {
        if (std.mem.eql(u8, n.child(i).kind(), "}")) end = n.child(i).endByte();
    }
    return end;
}

/// `func t {` -- a definition whose name is followed by a brace: the shape of a one-parameter lambda the grammar read as a function. A real definition
/// is `func Name(...)`, or `func Name` and a newline.
fn isBracedDef(n: ts.Node) bool {
    if (!std.mem.eql(u8, n.kind(), "function_definition") or n.namedChildCount() == 0) return false;
    const id = n.namedChild(0);
    if (!std.mem.eql(u8, id.kind(), "identifier")) return false;
    var e: usize = id.endByte();
    while (e < n.src.len and (n.src[e] == ' ' or n.src[e] == '\t')) e += 1;
    return e < n.src.len and n.src[e] == '{';
}

fn isTermEnd(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '"' or ch == '\'' or ch == '`' or
        ch == ')' or ch == ']' or ch == '}';
}

/// The keyword a statement leads with, when its payload is one expression.
/// These are the statements the grammar cuts at a `+`.
fn leadingKeyword(piece: []const u8) ?usize {
    if (piece.len > 0 and piece[0] == '?') return 1;
    for ([_][]const u8{ "return", "see", "give" }) |kw| {
        if (piece.len > kw.len and std.ascii.eqlIgnoreCase(piece[0..kw.len], kw) and
            (piece[kw.len] == ' ' or piece[kw.len] == '\t')) return kw.len;
    }
    return null;
}

/// Parse one statement's text alone and hand back the one statement in it.
///
/// The plain form is tried first. When the grammar cuts THAT too -- a long
/// `return "" + len(a) + " " + a[1] + ...` comes back as a return holding
/// the first three terms and an orphaned `+ a[1] + ...` beside it, even
/// alone in a function (F-58's tie-break, one level down) -- the payload is
/// parenthesised and parsed again: a `parenthesized_expression` cannot be
/// cut, and `expr` unwraps it. Found 2026-09-10, when such a line returned
/// "3 " and evaluated the rest as a discarded statement.
/// `src` and `at` say where `piece` stands in its file: byte `at` of `src`
/// is `piece[0]`. Each parse below records how its offsets map back.
fn parseOne(c: *Compiler, piece: []const u8, src: []const u8, at: u32) ?Parsed {
    if (parseSnippet(c, piece, src, @as(i64, at))) |p| return p;
    const kw = leadingKeyword(piece) orelse {
        // A CALL CHAIN THE GRAMMAR CUTS AT A `.`, however it is re-read:
        // nine links in statement position -- `IsQ().TheQ().LengthQ()...
        // .OrNot()`, nnl_narrated.ring:298 -- come back as `IsQ().` and a
        // bare `TheQ()...`, and the bare call bound the global TheQ(p) and
        // raised R19. Eight links parse whole, and so does the same chain
        // as an assignment's value. In parentheses it cannot be cut. Taken
        // ONLY when what the parentheses hold is a call: `(x = 1)` would
        // turn an assignment into a comparison (2026-09-26).
        const wrapped = std.mem.concat(c.alloc, u8, &.{ "(", piece, ")" }) catch return null;
        const p = parseSnippet(c, wrapped, src, @as(i64, at) - 1) orelse return null;
        if (!std.mem.eql(u8, p.node.kind(), "expression_statement") or p.node.namedChildCount() != 1) return null;
        const pe = p.node.namedChild(0);
        if (!std.mem.eql(u8, pe.kind(), "parenthesized_expression") or pe.namedChildCount() != 1) return null;
        if (!std.mem.eql(u8, pe.namedChild(0).kind(), "call_expression")) return null;
        return p;
    };
    const rest = std.mem.trim(u8, piece[kw..], " \t\r\n");
    if (rest.len == 0) return null;
    const wrapped = std.mem.concat(c.alloc, u8, &.{ piece[0..kw], " (", rest, ")" }) catch return null;
    // `rest` stands at byte kw + 2 of what is parsed and at its own place in
    // the piece; only it can hold a lambda, so its mapping is the one kept
    const rest_at: i64 = @as(i64, at) + @as(i64, @intCast(@intFromPtr(rest.ptr) - @intFromPtr(piece.ptr)));
    return parseSnippet(c, wrapped, src, rest_at - @as(i64, @intCast(kw + 2)));
}

/// `body_at`: the byte of `src` that byte 0 of `piece` stands for.
fn parseSnippet(c: *Compiler, piece: []const u8, src: []const u8, body_at: i64) ?Parsed {
    const head = "func __reread()\n";
    const snippet = std.mem.concat(c.alloc, u8, &.{ head, piece, "\n" }) catch return null;
    if (c.rejoin_parser == null) c.rejoin_parser = ts.Parser.init();
    const tree = c.rejoin_parser.?.parse(snippet) orelse return null;
    c.rejoin_trees.append(c.alloc, tree) catch return null;
    c.reread_origin.put(c.alloc, @intFromPtr(snippet.ptr), .{
        .src = src,
        .shift = body_at - @as(i64, head.len),
    }) catch return null;
    const want_end: u32 = @intCast(snippet.len - 1);
    const root = tree.root();
    // Every statement-shaped node, in order, inside the func or fallen out
    // beside it. One spanning the text is the answer; a bare `return`
    // followed by an expression spanning the rest is `return <expr>`.
    var found: [2]ts.Node = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (i < root.namedChildCount() and n < 2) : (i += 1) {
        const top = root.namedChild(i);
        if (std.mem.eql(u8, top.kind(), "function_definition")) {
            var ci: u32 = 0;
            while (ci < top.namedChildCount() and n < 2) : (ci += 1) {
                const s = top.namedChild(ci);
                const sk = s.kind();
                if (std.mem.eql(u8, sk, "identifier") or std.mem.eql(u8, sk, "param_list") or
                    std.mem.eql(u8, sk, "comment")) continue;
                found[n] = s;
                n += 1;
            }
        } else if (!std.mem.eql(u8, top.kind(), "comment")) {
            found[n] = top;
            n += 1;
        }
    }
    if (n == 0) return null;
    if (found[0].endByte() == want_end) return .{ .node = found[0], .as_return = false };
    if (n == 2 and std.mem.eql(u8, found[0].kind(), "return_statement") and
        found[0].namedChildCount() == 0 and
        std.mem.eql(u8, found[1].kind(), "expression_statement") and
        found[1].namedChildCount() == 1 and found[1].endByte() == want_end)
    {
        return .{ .node = found[1].namedChild(0), .as_return = true };
    }
    return null;
}

/// A `comment` node whose parent is an EXPRESSION -- the only place one
/// breaks an operand index. A comment between statements is a sibling of
/// them and every statement walk already skips it.
fn exprComment(n: ts.Node, depth: u32) bool {
    if (depth > 200) return false;
    const k = n.kind();
    const exprish = std.mem.endsWith(u8, k, "_expression") or std.mem.eql(u8, k, "arguments") or
        std.mem.eql(u8, k, "list_literal");
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        if (std.mem.eql(u8, ch.kind(), "comment")) {
            if (exprish) return true;
            continue;
        }
        if (exprComment(ch, depth + 1)) return true;
    }
    return false;
}

/// Every comment under `n`, overwritten with spaces in `buf` (which starts
/// at byte `base` of the source). Newlines survive, so rows do not move.
fn blankComments(n: ts.Node, base: u32, buf: []u8, depth: u32) void {
    if (depth > 200) return;
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        if (std.mem.eql(u8, ch.kind(), "comment")) {
            const s = ch.startByte();
            const e = ch.endByte();
            if (s < base or e > base + buf.len) continue;
            for (buf[s - base .. e - base]) |*p| {
                if (p.* != '\n' and p.* != '\r') p.* = ' ';
            }
            continue;
        }
        blankComments(ch, base, buf, depth + 1);
    }
}

fn rereadSpan(c: *Compiler, stmts: []const ts.Node, si: usize) ?struct { pieces: []const Reread, consumed: usize } {
    const st = stmts[si];
    const k = st.kind();
    if (!(std.mem.eql(u8, k, "return_statement") or
        std.mem.eql(u8, k, "expression_statement") or
        std.mem.eql(u8, k, "see_statement"))) return null;
    // the span: this statement and every same-row tail the grammar cut off
    // -- a leading-operator piece, or the expression a bare `return` lost
    // (`return X + "." +` in an else clause came back as `return` and `X +
    // "." + ...` side by side; on one row that is one statement)
    const bare_return = std.mem.eql(u8, k, "return_statement") and st.namedChildCount() == 0;
    // A DANGLING DOT JOINS ACROSS ROWS: a line ending in `.` is unfinished
    // on Ring, so `oBrain.Know("a", "b").` newline `Know("c", "d")` is one
    // chain -- the grammar cut it into a bare `Know(...)`, R3 "know", and
    // the capstone stopped there (2026-09-24). The other joins stay on one
    // row, as Ring's newline rule says.
    var j = si + 1;
    while (j < stmts.len and
        (danglingDot(stmts[j - 1]) or
            (stmts[j].start().row == stmts[j - 1].end().row and
                (isSplitTail(stmts[j]) or
                    (j == si + 1 and bare_return and std.mem.eql(u8, stmts[j].kind(), "expression_statement")))))) : (j += 1)
    {}
    const a = st.startByte();
    // a bare return that absorbed a lambda the grammar read as a definition: its text runs to the definition's end (`Compiler.absorbed`)
    const ext_end: ?u32 = if (bare_return) c.ret_ext.get(nodeKey(st)) else null;
    const b = if (ext_end) |e| @max(stmts[j - 1].endByte(), e) else stmts[j - 1].endByte();
    if (b <= a or b > st.src.len) return null;
    var text = st.src[a..b];
    // A COMMENT INSIDE AN EXPRESSION (2026-09-27). Ring's scanner drops a
    // comment wherever a newline may stand -- between the lines of a `+`
    // continuation, among arguments, in a list literal -- and the grammar
    // keeps it as a NODE, so `namedChild(1)` of a binary expression was the
    // comment, not the right operand. stzUiDocument.ToFixture has eight `#`
    // lines inside one `+` chain. The comment bytes are blanked -- newlines
    // kept, so every row still maps -- and the span is read again. The byte
    // test first: nearly no statement holds a `#` or a `/` at all.
    var blanked = false;
    if (std.mem.indexOfAny(u8, text, "#/") != null and exprComment(st, 0)) {
        const copy = c.alloc.dupe(u8, text) catch return null;
        blankComments(st, a, copy, 0);
        text = copy;
        blanked = true;
    }
    // cut it where Ring does: at a newline after a finished term, before a
    // leading + or -
    // ONE BUFFER, REUSED. This list used to be created fresh on every call,
    // and the call returns null a few lines below for almost every statement
    // in the corpus -- so the buffer was allocated and abandoned. In a bump
    // arena nothing is reclaimed, and it came to 603,936 requests of 128
    // bytes, 77 MB, the single largest block of allocation in the compiler
    // (measured 2026-09-13 with a stack trace at the site, after a size
    // histogram said only "128 bytes, very often").
    //
    // Safe to share: `starts` is used only inside this function, and the one
    // call it makes while the buffer is live -- parseOne -- parses a snippet
    // and never compiles, so it cannot re-enter here. The pieces it returns
    // are copied into `out` before any caller runs a statement.
    c.scratch_starts.clearRetainingCapacity();
    const starts = &c.scratch_starts;
    starts.append(c.alloc, 0) catch return null;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\n') continue;
        var p = i;
        while (p > line_start and (text[p - 1] == ' ' or text[p - 1] == '\t' or text[p - 1] == '\r')) p -= 1;
        const finished = p > line_start and isTermEnd(text[p - 1]);
        var q = i + 1;
        while (q < text.len and (text[q] == ' ' or text[q] == '\t' or text[q] == '\r')) q += 1;
        const leads = q < text.len and (text[q] == '+' or text[q] == '-');
        if (finished and leads) starts.append(c.alloc, q) catch return null;
        line_start = i + 1;
    }
    if (j == si + 1 and starts.items.len == 1 and !blanked and ext_end == null) return null;
    var out = std.ArrayListUnmanaged(Reread){};
    for (starts.items, 0..) |s0, pi| {
        const s1 = if (pi + 1 < starts.items.len) starts.items[pi + 1] else text.len;
        const piece = std.mem.trim(u8, text[s0..s1], " \t\r\n");
        if (piece.len == 0) continue;
        // blanking keeps every byte where it was, so a piece of `text` is at
        // the same distance from `a` in the file
        const piece_at: u32 = a + @as(u32, @intCast(@intFromPtr(piece.ptr) - @intFromPtr(text.ptr)));
        const p = parseOne(c, piece, st.src, piece_at) orelse return null;
        var row_off: u32 = 0;
        for (text[0..s0]) |ch| {
            if (ch == '\n') row_off += 1;
        }
        out.append(c.alloc, .{ .node = p.node, .row_off = row_off, .as_return = p.as_return }) catch return null;
    }
    if (out.items.len == 0) return null;
    if (j > si + 1) c.rejoined += 1;
    if (starts.items.len > 1) c.resplit += 1;
    return .{ .pieces = out.items, .consumed = j - si };
}

/// A statement that failed with NOTHING recorded -- an Unsupported from a
/// path that returns it bare. The census counted it and named nothing: 134
/// statements of the base unit on 2026-09-27, invisible in every table,
/// because every table is built from the recorded refusals. It names the
/// statement now, so a count and its list cannot disagree.
fn noteUnnamed(c: *Compiler, st: ts.Node, nref: usize) void {
    if (!c.census or c.refusals.items.len != nref) return;
    const t0 = st.text();
    // the one bare Unsupported measured so far: `define` and `tmp` at the
    // edge of the register window. stzDiagram.ToCanvasXT is 3,909 lines
    // with about 630 locals, and Ring has no limit to match.
    const full = c.cur.window_full or c.cur.locals.items.len >= MAXREG;
    c.refusals.append(c.alloc, .{
        .kind = if (full) "the register window is full (200 locals and temporaries)" else "unsupported, no cause recorded",
        .row = st.start().row + 1,
        .text = if (t0.len > 50) t0[0..50] else t0,
        .func = c.cur.name,
        .byte = st.startByte(),
        .src = st.src,
    }) catch {};
}

/// THE REGISTER WINDOW (2026-10-18). An instruction names a register in a
/// byte and MAXREG is 200, so a function gets one register per local only up
/// to there. stzDiagram.ToCanvasXT has 618 locals in 3,909 lines, and Ring
/// has no such limit, so it was refused -- yet no more than about fifty of
/// them are in use over any one stretch of it. Its locals SHARE registers.
///
/// A local's STRETCH: the statements, in one sequence the emitter walks,
/// from the one holding its first use to the one holding its last -- in the
/// innermost sequence that holds every use and that NO loop encloses. Such a
/// sequence runs at most once per call, its statements in order, and nothing
/// jumps into its middle (Ring has no goto), so control that has left a
/// stretch never comes back into it. Two locals whose stretches do not
/// overlap may share a register: each sees its own writes, and nothing else,
/// from the start of its stretch on. The start clears the register
/// (`loadi` then `nilr`, releasing what the last owner left) and definite assignment
/// forgets it, so a read before the local's own first assignment is still R24
/// (`chkl`), as on Ring. A local used inside a loop gets the whole loop.
///
/// What keeps a register of its own: a parameter; a name used inside a lambda
/// (a capture is taken by name); a local with no use in the body. Not tried
/// at all: a function holding an eval (it binds locals by name at run time),
/// the top level, a class region. The positions come from the compiler's own
/// walk -- a STRUCTURE pass of emitOne whose code is thrown away -- so a
/// sequence is exactly what the emitter treats as one; a statement it did not
/// walk into counts whole, which can only lengthen a stretch.
///
/// Every function that fits the window compiles exactly as before.
const SHARE_PROV: usize = 140;
const SHARE_TEMPS: usize = 40;

/// RNXC_TRACE_SHARE=1: say, on stderr, what shareFunction decided and why.
var g_share_trace: ?bool = null;
fn shareNote(f: *const Func, comptime why: []const u8, args: anytype) void {
    const on = g_share_trace orelse blk: {
        const b = std.process.hasEnvVarConstant("RNXC_TRACE_SHARE");
        g_share_trace = b;
        break :blk b;
    };
    if (on) std.debug.print("share {s}: " ++ why ++ "\n", .{f.name} ++ args);
}

fn shareFunction(c: *Compiler, f: *Func) bool {
    if (f.is_main or f.calls_eval or f.stmts.items.len == 0 or std.mem.eql(u8, f.name, PROLOGUE)) {
        shareNote(f, "not tried (main {}, eval {}, statements {d})", .{ f.is_main, f.calls_eval, f.stmts.items.len });
        return false;
    }
    const a = c.alloc;
    const np = f.params.len;
    if (np + 8 >= SHARE_PROV or f.locals.items.len < np) {
        shareNote(f, "not tried ({d} parameters, {d} locals)", .{ np, f.locals.items.len });
        return false;
    }
    for (f.params, 0..) |p, i| {
        if (!std.ascii.eqlIgnoreCase(f.locals.items[i].name, p)) {
            shareNote(f, "not tried: local {d} is {s}, parameter {s}", .{ i, f.locals.items[i].name, p });
            return false;
        }
    }
    const snap = a.dupe(Local, f.locals.items) catch return false;
    const snap_top = f.reg_top;
    const restore = struct {
        fn go(cc: *Compiler, ff: *Func, s: []const Local, top: u16) void {
            ff.locals.clearRetainingCapacity();
            ff.locals.appendSlice(cc.alloc, s) catch {};
            ff.reg_top = top;
        }
    }.go;

    // 1. the structure pass, on provisional registers that stay in the window
    for (f.locals.items[np..], np..) |*l, i| l.reg = @intCast(np + (i - np) % (SHARE_PROV - np));
    f.reg_top = @intCast(@min(f.locals.items.len, SHARE_PROV));
    var rec = std.ArrayListUnmanaged(SeqRec){};
    const code0 = c.code.items.len;
    const rows0 = c.rows.items.len;
    const files0 = c.files.items.len;
    const fix0 = c.fixups.items.len;
    const ref0 = c.refusals.items.len;
    c.share_rec = &rec;
    c.share_loop_base = c.loop_try.items.len;
    emitOne(c, f) catch {};
    c.share_rec = null;
    c.code.shrinkRetainingCapacity(code0);
    c.rows.shrinkRetainingCapacity(@min(rows0, c.rows.items.len));
    c.files.shrinkRetainingCapacity(@min(files0, c.files.items.len));
    c.fixups.shrinkRetainingCapacity(@min(fix0, c.fixups.items.len));
    c.refusals.shrinkRetainingCapacity(@min(ref0, c.refusals.items.len));

    // 2. every use of every name in the body, by position; names used inside
    // a lambda apart
    var uses = std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u32)){};
    var in_lambda = std.StringHashMapUnmanaged(void){};
    const Item = struct { n: ts.Node, lam: bool };
    var stack = std.ArrayListUnmanaged(Item){};
    for (f.stmts.items) |st| stack.append(a, .{ .n = st, .lam = false }) catch return false;
    while (stack.pop()) |it| {
        const k = it.n.kind();
        const lam = it.lam or std.mem.eql(u8, k, "anonymous_function");
        if (std.mem.eql(u8, k, "identifier")) {
            const low = std.ascii.allocLowerString(a, it.n.text()) catch return false;
            if (lam) {
                in_lambda.put(a, low, {}) catch return false;
            } else {
                const g = uses.getOrPut(a, low) catch return false;
                if (!g.found_existing) g.value_ptr.* = .{};
                g.value_ptr.append(a, it.n.startByte()) catch return false;
            }
        }
        var i: u32 = 0;
        while (i < it.n.namedChildCount()) : (i += 1)
            stack.append(a, .{ .n = it.n.namedChild(i), .lam = lam }) catch return false;
    }

    // 3. each local's stretch
    const Iv = struct { s: u32, e: u32, key: u64, li: usize };
    var ivs = std.ArrayListUnmanaged(Iv){};
    var own = std.ArrayListUnmanaged(usize){};
    for (f.locals.items[np..], np..) |l, li| {
        const low = std.ascii.allocLowerString(a, l.name) catch return false;
        const us = uses.get(low);
        if (in_lambda.contains(low) or us == null or us.?.items.len == 0) {
            own.append(a, li) catch return false;
            continue;
        }
        var umin: u32 = std.math.maxInt(u32);
        var umax: u32 = 0;
        for (us.?.items) |u| {
            umin = @min(umin, u);
            umax = @max(umax, u);
        }
        var best: ?Iv = null;
        for (rec.items) |sq| {
            const sp = sq.spans.items;
            if (sq.depth != 0 or sp.len == 0) continue;
            if (umin < sp[0][0] or umax >= sp[sp.len - 1][1]) continue;
            var lo: usize = sp.len;
            var hi: usize = 0;
            var ok = true;
            for (us.?.items) |u| {
                const ix = spanOf(sp, u) orelse {
                    ok = false;
                    break;
                };
                lo = @min(lo, ix);
                hi = @max(hi, ix);
            }
            if (!ok) continue;
            const cand = Iv{ .s = sp[lo][0], .e = sp[hi][1], .key = sq.keys.items[lo], .li = li };
            if (best == null or cand.e - cand.s < best.?.e - best.?.s) best = cand;
        }
        if (best) |b| ivs.append(a, b) catch return false else own.append(a, li) catch return false;
    }

    // 4. colour the stretches: sorted by start, each takes the lowest
    // register whose last stretch has ended
    std.mem.sort(Iv, ivs.items, {}, struct {
        fn lt(_: void, x: Iv, y: Iv) bool {
            return x.s < y.s or (x.s == y.s and x.li < y.li);
        }
    }.lt);
    var ends = std.ArrayListUnmanaged(u32){};
    const colour = a.alloc(usize, ivs.items.len) catch return false;
    for (ivs.items, 0..) |iv, ii| {
        var pick: ?usize = null;
        for (ends.items, 0..) |e, ci| {
            if (e <= iv.s) {
                pick = ci;
                break;
            }
        }
        if (pick) |ci| {
            ends.items[ci] = iv.e;
            colour[ii] = ci;
        } else {
            ends.append(a, iv.e) catch return false;
            colour[ii] = ends.items.len - 1;
        }
    }
    const top = np + ends.items.len + own.items.len;
    shareNote(f, "{d} locals, {d} sequences walked: {d} stretches in {d} registers, {d} of their own, {d} parameters", .{ f.locals.items.len, rec.items.len, ivs.items.len, ends.items.len, own.items.len, np });
    if (top + SHARE_TEMPS > MAXREG) {
        shareNote(f, "does not fit: {d} registers + {d} for temporaries > {d}", .{ top, SHARE_TEMPS, MAXREG });
        restore(c, f, snap, snap_top);
        return false;
    }

    // 5. install
    const tbl = a.create(ShareTable) catch return false;
    tbl.* = .{};
    for (ivs.items, 0..) |iv, ii| {
        const r: u8 = @intCast(np + colour[ii]);
        f.locals.items[iv.li].reg = r;
        const g = tbl.getOrPut(a, iv.key) catch return false;
        if (!g.found_existing) g.value_ptr.* = .{};
        var dup = false;
        for (g.value_ptr.items) |x| dup = dup or x == r;
        if (!dup) g.value_ptr.append(a, r) catch return false;
    }
    for (own.items, 0..) |li, j| f.locals.items[li].reg = @intCast(np + ends.items.len + j);
    f.reg_top = @intCast(top);
    f.share = tbl;
    f.window_full = false;
    c.shared_funcs += 1;
    c.shared_saved += @intCast(f.locals.items.len -| top);
    return true;
}

/// The element of a sequence that holds byte `u`, by binary search (the
/// elements are in order and do not overlap).
fn spanOf(sp: []const [2]u32, u: u32) ?usize {
    var lo: usize = 0;
    var hi: usize = sp.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (sp[mid][0] <= u) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const ix = lo - 1;
    return if (u < sp[ix][1]) ix else null;
}

fn emitOne(c: *Compiler, f: *Func) Error!void {
    // Everything the per-statement lists took for the LAST function is
    // reclaimed here. They are function-local to a one, and on the main
    // arena none of them was ever given back.
    if (c.scratch_arena) |sa| _ = sa.reset(.retain_capacity);
    // C-11 state is per emission: this function is re-emitted every pass,
    // so clear its retired names and the open-loop stack before it runs
    // (a refused loop never reaches its own pop).
    c.active_loops.clearRetainingCapacity();
    {
        var ri: usize = 0;
        while (ri < c.retired.items.len) {
            if (c.retired.items[ri].fi == f.id) {
                _ = c.retired.swapRemove(ri);
            } else ri += 1;
        }
    }
    {
        c.cur = f;
        c.high = 0;
        c.floor = 0;
        // Params occupy r0..r(n-1); `define` is idempotent so pass B reuses
        // exactly the registers pass A handed out.
        for (f.params) |p| _ = try c.define(p);
        c.temp = c.localsTop();
        const code_start = c.here();
        f.entry = c.here();
        f.emitted = true;
        // DEFINITE ASSIGNMENT starts with the parameters (F-89). The entry
        // is a placeholder jump: if the body turns out to need no `nilr`,
        // the entry moves past it and the function pays nothing; if it
        // does, the placeholder jumps to the clearing code appended after
        // the body, which jumps back.
        c.da_on = c.eval == null and !f.is_main and !f.calls_eval and
            !std.mem.eql(u8, f.name, PROLOGUE);
        c.da = .{};
        c.da_flag = .{ 0, 0, 0, 0 };
        for (f.params) |p| {
            if (c.lookup(p)) |pl| c.da.add(pl.reg);
        }
        const da_ph: ?u32 = if (c.da_on) try c.emit(.jmp, 0, 0, 0, 0) else null;
        // A FUNCTION HOLDING AN EVAL STARTS EACH CALL FRESH (F-107): the names
        // an eval made in an earlier call -- or in a frame an error unwound at
        // this depth -- are dropped, and its locals are nil, so a read before
        // any assignment is R24 as on Ring (it read a stale value as NULL).
        if (f.calls_eval and !f.is_main and c.eval == null) {
            const np: usize = f.params.len;
            const nl: usize = f.locals.items.len;
            const cnt: usize = if (nl > np) @min(nl - np, 255) else 0;
            _ = try c.emit(.dvclr, @intCast(@min(np, 255)), @intCast(cnt), 0, 0);
        }
        c.ln_pend = null;
        c.ln_open = null;
        c.stmt_level = 0;
        // A prologue whose parent arrived compiled (the prefix) calls the
        // parent's prologue first, as a `new` site calls a prologue: the
        // receiver in a window above the frame. See ClassInfo.parent_prologue.
        if (f.owner) |oc| {
            if (std.mem.eql(u8, f.name, PROLOGUE)) {
                if (c.classes.items[oc].parent_prologue) |ppf| {
                    const s2 = c.temp;
                    defer c.temp = s2;
                    const win = try c.tmp();
                    _ = try c.emit(.move, win, 0, 1, 0);
                    _ = c.reg(win + 8);
                    c.atNodeStart(c.classes.items[oc].node);
                    const site = try c.emit(.call, win, 0, 0, 0);
                    try c.fixups.append(c.alloc, .{ .site = site, .fidx = ppf, .from = c.funcIndex(f) });
                }
            }
        }
        const ln_lo = c.here();
        // the function body is a sequence too (structure pass, shareFunction)
        const bseq: ?usize = if (f.stmts.items.len > 0) c.seqOpen(f.stmts.items[0]) else null;
        var bel: usize = 0;
        defer if (bseq != null) c.seqElem(bseq, f.stmts.items, bel, f.stmts.items.len - 1);
        var si: usize = 0;
        while (si < f.stmts.items.len) : (si += 1) {
            const st = f.stmts.items[si];
            // F-128: a file only a load inside a block reaches runs there, not here
            if (f.is_main and c.nested_skip.count() > 0 and c.nested_skip.contains(stmtKey(st))) continue;
            if (bseq != null and si > 0) {
                c.seqElem(bseq, f.stmts.items, bel, si - 1);
                bel = si;
            }
            try c.shareClear(st);
            c.ln_has_next = si + 1 < f.stmts.items.len;
            c.ln_block_quirk = false;
            // A span the grammar read differently from Ring -- a line cut in
            // two at a `+`/`-`, or two lines joined across a newline -- is
            // re-read the way Ring reads it and compiled piece by piece.
            if (rereadSpan(c, f.stmts.items, si)) |rr| {
                for (rr.pieces) |piece| {
                    // while the piece compiles, refusals name the source line
                    c.reread_src = st.src;
                    c.reread_byte = st.startByte();
                    c.reread_row = st.start().row + 1 + piece.row_off;
                    defer c.reread_src = null;
                    c.ln_has_next = true; // a piece: assumed followed
                    if (piece.as_return) c.lnStmtStart(piece.node);
                    if (c.census or c.lenient) {
                        const mark = c.here();
                        const fxmark = c.fixups.items.len;
                        const nref = c.refusals.items.len;
                        (if (piece.as_return) c.returnExpr(piece.node) else c.stmt(piece.node)) catch |e| {
                            if (e != Error.Unsupported) return e;
                            noteUnnamed(c, st, nref);
                            c.stmts_bad += 1;
                            f.poisoned = true;
                            refusalTrap(c, st, mark, fxmark);
                            continue;
                        };
                        c.stmts_ok += 1;
                    } else if (piece.as_return) {
                        try c.returnExpr(piece.node);
                    } else try c.stmt(piece.node);
                }
                si += rr.consumed - 1;
                continue;
            }
            // `return <expr>` inside a class method parses as a BARE return
            // followed by an orphaned expression statement. Rejoin them, or
            // every method silently returns nothing -- but only when the
            // statement stands on the SAME row. Ring's `return` looks at the
            // very next token and, finding the end of the line, returns NULL
            // (vendor/ring-vm/src/stmt.c:931): what follows on a later row --
            // after an `end` or a comment or nothing -- is a statement of its
            // own that never runs. This joined it from any row, so `return`,
            // `end`, `5` answered 5 where Ring answers the empty string
            // (bench/exec/bare_return.ring).
            if (std.mem.eql(u8, st.kind(), "return_statement") and st.namedChildCount() == 0 and
                si + 1 < f.stmts.items.len and
                std.mem.eql(u8, f.stmts.items[si + 1].kind(), "expression_statement") and
                f.stmts.items[si + 1].start().row == st.end().row)
            {
                c.lnStmtStart(st);
                if (c.census or c.lenient) {
                    const mark = c.here();
                    const fxmark = c.fixups.items.len;
                    const nref = c.refusals.items.len;
                    c.returnExpr(f.stmts.items[si + 1].namedChild(0)) catch |e| {
                        if (e != Error.Unsupported) return e;
                        noteUnnamed(c, f.stmts.items[si + 1], nref);
                        c.stmts_bad += 1;
                        f.poisoned = true;
                        refusalTrap(c, f.stmts.items[si + 1], mark, fxmark);
                        si += 1;
                        continue;
                    };
                    c.stmts_ok += 1;
                } else try c.returnExpr(f.stmts.items[si + 1].namedChild(0));
                si += 1;
                continue;
            }
            if (c.census or c.lenient) {
                const mark = c.here();
                const fxmark = c.fixups.items.len;
                const nref = c.refusals.items.len;
                c.stmt(st) catch |e| {
                    if (e != Error.Unsupported) return e;
                    noteUnnamed(c, st, nref);
                    c.stmts_bad += 1;
                    f.poisoned = true;
                    refusalTrap(c, st, mark, fxmark);
                    continue;
                };
                c.stmts_ok += 1;
            } else try c.stmt(st);
        }
        c.lnSeqEnd();
        lnThread(c, ln_lo);
        // A FUNCTION THAT RUNS OFF ITS END RETURNS NULL -- the empty STRING.
        //
        // This said "returns 0, as Ring's does", and Ring does not. Measured
        // on 1.27 for a function and a method alike: type STRING, isNull 1,
        // len 0. The line read like a fact and was the fourth such comment in
        // a fortnight to encode a wrong rule (`// a byte`, `// or COW clones
        // it`, "not written that way in Softanza"). Every function and method
        // without a return, across the whole estate, answered 0 -- silently,
        // so `isNull(F())`, `F() = ""` and `len(F())` were all wrong on it,
        // and two narrated tests asserting "X() returns nothing" failed.
        //
        // Through a temporary and not r0, for the reason given at the bare
        // `return` above: r0 of a method is the receiver, and `loadk` there
        // would release it. The type table moves with this, in classifyRound
        // -- a rule and the class that describes it are one change.
        //
        // THE TEMPORARY COMES FROM THE BOTTOM, and the first version of this
        // lost the census 48,125 statements by not doing so. `c.temp` is set
        // once, before the body, and never reset between statements, so after
        // a long body it can sit at MAXREG -- and a fresh `tmp()` then failed
        // HERE, outside the per-statement catch that turns a failure into a
        // refusal, where the census's emitAll treats it as fatal and stops
        // emitting every function after it. The gate PASSED over that: its
        // census step reports the number and compares it with nothing. It was
        // caught by the number looking wrong -- 70,512 against 118,637 -- and
        // settled by one A/B on the same tree.
        //
        // The bottom is safe only HERE. Once the body has ended every
        // temporary is dead; mid-body a `for` loop's counter is live across
        // its statements, which is why the bare `return` above does not do
        // this. A function whose LOCALS alone fill the window gets the old
        // instruction rather than an abort: a wrong value in a case no census
        // has seen, instead of a lost library.
        c.temp = c.localsTop();
        if (c.tmp()) |tr| {
            _ = try c.emit(.loadk, tr, 0, 0, try c.konstIndex("\"\""));
            _ = try c.emit(.ret, tr, 0, 0, 0);
        } else |_| {
            _ = try c.emit(.loadi, 0, 0, 0, 0);
            _ = try c.emit(.ret, 0, 0, 0, 0);
        }

        f.frame = c.high + 1;
        // Sound and cheap: every register in the frame is treated as able to
        // hold a reference EXCEPT the named locals inference proved to be
        // integers. Temporaries are conservatively boxed, so nothing leaks;
        // sharpening this is what better inference buys.
        var m: u64 = if (f.frame >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(f.frame)) - 1;
        // a register leaves the mask only when NO local in it can hold a
        // reference -- locals that share one (shareFunction) are judged together
        var held: u64 = 0;
        for (f.locals.items) |l| {
            if (l.class.boxed() and l.reg < 64) held |= @as(u64, 1) << @intCast(l.reg);
        }
        for (f.locals.items) |l| {
            if (!l.class.boxed() and l.reg < 64) m &= ~(@as(u64, 1) << @intCast(l.reg));
        }
        m |= held & (if (f.frame >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(f.frame)) - 1);
        f.mask = m;

        if (da_ph) |ph| {
            const any = (c.da_flag[0] | c.da_flag[1] | c.da_flag[2] | c.da_flag[3]) != 0;
            if (!any) {
                f.entry = ph + 1;
            } else {
                c.land(ph);
                var r: u16 = 0;
                while (r < 256) : (r += 1) {
                    if ((c.da_flag[r >> 6] >> @intCast(r & 63)) & 1 == 1)
                        _ = try c.emit(.nilr, @intCast(r), 0, 0, 0);
                }
                _ = try c.emit(.jmp, 0, 0, 0, @intCast(ph + 1));
            }
        }
        c.da_on = false;

        // THE UNCHECKED TWINS. Since F-118 an unboxed store releases a counted value it overwrites. An
        // arithmetic opcode whose destination is one of its OPERANDS -- `n = n + 1`, `nAcc += x * y` -- needs no
        // such check on its fast paths: those run only after the operand's tag was tested numeric, and the value
        // overwritten IS that operand. So it becomes its twin, which stores without the check; the slow paths
        // (a numeric string, a concatenation, an append, an operator call) store through the checked path in both.
        // A destination merely OUTSIDE the frame mask (an integer local) is NOT enough, and that was the first rule
        // (2026-10-14): at a function's entry its registers overlap the caller's call window, where a dead
        // temporary of the caller's can still hold a counted value, so the first store into an integer local is the
        // one that releases it. Not for eval code, whose registers are the caller's. `c` of an immediate form is a
        // flag, not a register.
        if (c.eval == null) {
            var pc: usize = code_start;
            while (pc < c.code.items.len) : (pc += 1) {
                const in = &c.code.items[pc];
                const both = in.a == in.b or in.a == in.c;
                in.op = switch (in.op) {
                    .add => if (both) .add_u else continue,
                    .sub => if (both) .sub_u else continue,
                    .mul => if (both) .mul_u else continue,
                    .addi => if (in.a == in.b) .addi_u else continue,
                    .muli => if (in.a == in.b) .muli_u else continue,
                    .modi => if (in.a == in.b) .modi_u else continue,
                    .idivi => if (in.a == in.b) .idivi_u else continue,
                    else => continue,
                };
            }
        }
    }
}

/// A parameter no observed call site can speak for is a REFERENCE.
///
/// THIS BELONGS INSIDE THE FIXPOINT, and running it after was a defect of
/// its own. `called` is a syntactic fact, complete after one full
/// classifyRound, so a single widening pass is enough -- but the rounds
/// AFTER it are the whole point, because a widened parameter has to reach
/// the functions it is PASSED TO. Run last, it never does.
///
/// What that cost: `a++` proved a method's parameter an integer, and
/// promoteCallArgs carried that integer into a callee's own parameter.
/// The widening then raised the method's and left the callee's behind, so
/// the callee copied a list with `move c=0` -- no retain -- into a register
/// its frame mask releases anyway. One release too many, every call. It is
/// the `s[i]` defect of 2026-09-19 reached from the other end: a register
/// in the mask holding a value nobody retained.
/// The `arguments` node of a call, or null for a bare name.
fn argsOf(n: ts.Node) ?ts.Node {
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        if (std.mem.eql(u8, n.namedChild(i).kind(), "arguments")) return n.namedChild(i);
    }
    return null;
}

/// What a local assigned from `rhs` holds as ELEMENTS, as far as this pass
/// can see. Ring copies at the assignment (C-7), so the contents are the
/// right-hand side's as they stand: `list(n)` is zeros, `list(r, c)` and
/// `newlist` are lists of zeros, a literal holds its members, another local
/// holds what it was proved to hold. Bottom only for `[]`. Anything else --
/// a call's result, a subscript, an attribute, a global -- is decided
/// somewhere this pass does not look, and is `ref`, the top.
fn rhsElem(c: *Compiler, f: *Func, rhs: ts.Node) Class {
    const k = rhs.kind();
    if (std.mem.eql(u8, k, "parenthesized_expression") and rhs.namedChildCount() > 0)
        return rhsElem(c, f, rhs.namedChild(0));
    if (std.mem.eql(u8, k, "list_literal")) {
        var e: Class = .unknown;
        var i: u32 = 0;
        while (i < rhs.namedChildCount()) : (i += 1) {
            const el = rhs.namedChild(i);
            if (std.mem.eql(u8, el.kind(), "comment")) continue;
            e = e.join(exprClass(c, f, el));
        }
        return e;
    }
    if (std.mem.eql(u8, k, "call_expression")) {
        const callee = rhs.namedChild(0).text();
        if (c.findFunc(callee) == null) {
            if (std.ascii.eqlIgnoreCase(callee, "list")) {
                const argc: u32 = if (argsOf(rhs)) |a| a.namedChildCount() else 0;
                return if (argc >= 2) .list else .int;
            }
            if (std.ascii.eqlIgnoreCase(callee, "newlist")) return .list;
        }
        return .ref;
    }
    if (std.mem.eql(u8, k, "identifier")) {
        const save = c.cur;
        defer c.cur = save;
        c.cur = f;
        if (c.lookup(rhs.text())) |l| {
            return switch (l.class) {
                .list => l.elem,
                .unknown => .unknown,
                else => .ref,
            };
        }
        return .ref;
    }
    return .ref;
}

/// ELEMENTS THIS PASS CANNOT SEE ARE OPENED TO `ref` BEFORE THE FIXPOINT.
///
/// A local's element class is sound only when EVERY write into the list is
/// one the classify walk observes: `aL[i] = v`, `add(aL, v)`, `insert`, and
/// `aL + v` as a statement. Four ways a list is filled without any of those
/// being seen, each of which left a specific claim standing over contents
/// it did not describe:
///
///   a PARAMETER: its contents are the caller's. `p[1] = 0` in the body
///       proved p a list of integers, and p[2] -- "b" from the caller --
///       was read into an unboxed register.
///   a list PASSED TO A CALL: by reference on Ring (C-7), so the callee
///       may fill it. `add(aL, 1)` then `Fill(aL)` then `return aL[2]`
///       read a heap string with no retain, the frame sweep freed the list
///       and the string with it, and the caller printed freed memory --
///       then spun for ever in exit (bench/exec/elem_sound.ring, 2026-09-24).
///   a FOR-IN variable that the body writes: it is written back into the
///       container (`vsetq`), so `for x in aL  x = "s"  next` fills aL
///       with strings.
///   a LAMBDA that names the local: the closure holds the same vector.
///
/// `aL + v` NESTED in an expression appends in place too (measured on 1.27
/// in an assignment, a print and a condition), and only the statement form
/// is observed. `eval` may do anything, so it opens every local of its
/// function. A user function is a call; a name in the builtin table is not,
/// except `add` / `insert` (observed, when they sit under an expression
/// statement or a return -- the only places promoteCallArgs walks) and
/// `ref` / `reference`, which hand the list out; a name that is neither is
/// a native, and a native escapes. A DECLARED `list aL` is the programmer's
/// statement and is left as it is.
///
/// `ref` is the top of the lattice and `join` never lowers, so this runs
/// once, before round 0, and the fixpoint cannot take it back.
fn openElems(c: *Compiler, from: usize) void {
    for (c.funcs.items[from..]) |*f| {
        c.cur = f;
        for (f.params) |p| openLocalElem(c, p);
        for (f.stmts.items) |st| openElemsIn(c, f, st, false, false);
        for (c.absorbed.items) |ab| {
            if (ab.owner == f.id) openIdentsIn(c, ab.def);
        }
    }
}

fn openLocalElem(c: *Compiler, name: []const u8) void {
    if (c.lookup(name)) |l| {
        if (!l.declared) l.elem = .ref;
    }
}

fn openAllElems(f: *Func) void {
    for (f.locals.items) |*l| {
        if (!l.declared) l.elem = .ref;
    }
}

/// Every local of `f` to the top of the lattice: `ref` never lowers, so the
/// fixpoint keeps it. A declared class is the programmer's statement.
fn openAllLocals(f: *Func) void {
    for (f.locals.items) |*l| {
        if (!l.declared) l.class = .ref;
    }
}

/// Every identifier under `n` that is a local of the current function.
fn openIdentsIn(c: *Compiler, n: ts.Node) void {
    if (std.mem.eql(u8, n.kind(), "identifier")) {
        openLocalElem(c, n.text());
        return;
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) openIdentsIn(c, n.namedChild(i));
}

/// Does the body of `n` (children from `from`) write the variable `name`?
fn writesName(n: ts.Node, from: u32, name: []const u8) bool {
    var i: u32 = from;
    while (i < n.namedChildCount()) : (i += 1) {
        const ch = n.namedChild(i);
        const k = ch.kind();
        if (ch.namedChildCount() > 0 and
            (std.mem.eql(u8, k, "assignment_expression") or
                std.mem.eql(u8, k, "postfix_expression") or
                std.mem.eql(u8, k, "give_statement")))
        {
            const t = ch.namedChild(0);
            if (std.mem.eql(u8, t.kind(), "identifier") and std.ascii.eqlIgnoreCase(t.text(), name)) return true;
        }
        if (writesName(ch, 0, name)) return true;
    }
    return false;
}

/// `observed`: under an expression statement or a return, where classify
/// walks calls. `top_plus`: this node is the whole of an expression
/// statement, so a `+` here is the observed append.
fn openElemsIn(c: *Compiler, f: *Func, n: ts.Node, observed: bool, top_plus: bool) void {
    const k = n.kind();
    if (std.mem.eql(u8, k, "expression_statement")) {
        var i: u32 = 0;
        while (i < n.namedChildCount()) : (i += 1) openElemsIn(c, f, n.namedChild(i), true, i == 0);
        return;
    }
    const obs = observed or std.mem.eql(u8, k, "return_statement");
    if (std.mem.eql(u8, k, "anonymous_function")) {
        openIdentsIn(c, n);
        return;
    }
    if (std.mem.eql(u8, k, "call_expression") and n.namedChildCount() > 0) {
        const callee = n.namedChild(0).text();
        var escapes = true;
        if (c.findFunc(callee) == null) {
            if (std.ascii.eqlIgnoreCase(callee, "eval")) {
                // C-9 revised: a function that calls eval keeps EVERY local
                // boxed. The string may store anything into any of them, and
                // a register the frame mask believes unboxed would then hold
                // a value nobody releases. The specialisation it loses is
                // priced in CLAUDE.md under item 5.
                openAllElems(f);
                openAllLocals(f);
                f.calls_eval = true;
                escapes = false;
            } else if (std.ascii.eqlIgnoreCase(callee, "add") or std.ascii.eqlIgnoreCase(callee, "insert")) {
                escapes = !obs;
            } else if (std.ascii.eqlIgnoreCase(callee, "ref") or std.ascii.eqlIgnoreCase(callee, "reference")) {
                escapes = true;
            } else if (builtinNamed(callee)) {
                escapes = false;
            }
        }
        if (escapes) {
            if (argsOf(n)) |args| {
                var i: u32 = 0;
                while (i < args.namedChildCount()) : (i += 1) {
                    const a = args.namedChild(i);
                    if (std.mem.eql(u8, a.kind(), "identifier")) openLocalElem(c, a.text());
                }
            }
        }
    }
    if (std.mem.eql(u8, k, "binary_expression") and !top_plus and n.namedChildCount() > 0 and
        std.mem.eql(u8, Compiler.opText(n), "+"))
    {
        const l0 = n.namedChild(0);
        if (std.mem.eql(u8, l0.kind(), "identifier")) openLocalElem(c, l0.text());
    }
    if (std.mem.eql(u8, k, "for_statement") and Compiler.forIsIn(n) and n.namedChildCount() > 1) {
        const v = n.namedChild(0);
        const src = n.namedChild(1);
        if (std.mem.eql(u8, src.kind(), "identifier") and writesName(n, 2, v.text())) openLocalElem(c, src.text());
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) openElemsIn(c, f, n.namedChild(i), obs, false);
}

fn widenEntryParams(c: *Compiler, from: usize) bool {
    var changed = false;
    for (c.funcs.items[from..]) |*f| {
        if (f.called) continue;
        for (f.params) |p| {
            for (f.locals.items) |*l| {
                if (std.ascii.eqlIgnoreCase(l.name, p) and !l.declared and l.class != .ref) {
                    l.class = .ref;
                    changed = true;
                }
            }
        }
    }
    return changed;
}

/// One round of "which locals can hold a reference". Returns true if
/// anything changed, so the caller can iterate to a fixpoint.
fn classifyRound(c: *Compiler) Error!bool {
    var changed = false;
    for (c.funcs.items[c.prefix_funcs..]) |*f| {
        c.cur = f;
        for (f.stmts.items) |st| {
            changed = (try classifyStmt(c, f, st)) or changed;
        }
        // RUNNING OFF THE END IS A RETURN TOO, and it was not in this table
        // at all. Only `return_statement`s joined into `ret`, so a function
        // typed `.int` by its `return n` that could ALSO fall off its end was
        // an integer here while the fall-off path handed back... 0, which
        // happened to agree. Now it hands back "" (Ring's NULL), and every
        // caller of such a function would go on believing int: `exprClass`
        // types `x = F()` from `ret`, so x would sit in an unboxed register
        // and `x + 1` would be specialised as integer arithmetic on a
        // string. The silent-corruption shape, from the other end.
        //
        // Joined unless the body provably cannot fall off -- its last
        // statement is a `return`. Conservative on purpose: an if/else whose
        // every branch returns is treated as able to fall off, which costs
        // integer specialisation there and never costs correctness.
        if (!endsInReturn(f)) {
            const rc2 = f.ret.join(.str);
            if (rc2 != f.ret) {
                f.ret = rc2;
                changed = true;
            }
        }
    }
    return changed;
}

/// Does this function's body END in a `return`, so that running off its end
/// is unreachable? Trailing comments do not count as statements.
fn endsInReturn(f: *const Func) bool {
    var i = f.stmts.items.len;
    while (i > 0) {
        i -= 1;
        const k = f.stmts.items[i].kind();
        if (std.mem.eql(u8, k, "comment")) continue;
        return std.mem.eql(u8, k, "return_statement");
    }
    return false;
}

fn walkClassify(c: *Compiler, f: *Func, n: ts.Node, from: u32) Error!bool {
    var changed = false;
    var i: u32 = from;
    while (i < n.namedChildCount()) : (i += 1) {
        changed = (try classifyStmt(c, f, n.namedChild(i))) or changed;
    }
    return changed;
}

fn joinLocal(c: *Compiler, f: *Func, name: []const u8, cl: Class) bool {
    const save = c.cur;
    defer c.cur = save;
    c.cur = f;
    if (c.lookup(name)) |l| {
        const n = l.class.join(cl);
        if (n != l.class) {
            l.class = n;
            return true;
        }
    }
    return false;
}

/// Join a class into a local's ELEMENT class.
fn joinElem(c: *Compiler, f: *Func, name: []const u8, cl: Class) bool {
    const save = c.cur;
    defer c.cur = save;
    c.cur = f;
    if (c.lookup(name)) |l| {
        const n = l.elem.join(cl);
        if (n != l.elem) {
            l.elem = n;
            return true;
        }
    }
    return false;
}

fn classifyStmt(c: *Compiler, f: *Func, ch: ts.Node) Error!bool {
    var changed = false;
    {
        const k = ch.kind();

        // The VM's numeric `for` steps an integer, and `x++` / `x += n` can
        // only mean one on this subset. Both are facts, not guesses.
        // a NUMERIC loop's variable is an integer (a for-in's is its element)
        if (std.mem.eql(u8, k, "for_statement") and !Compiler.forIsIn(ch)) {
            changed = joinLocal(c, f, ch.namedChild(0).text(), .int) or changed;
        }
        // A FOR-IN VARIABLE HOLDS THE CONTAINER'S ELEMENTS: `iget` fills
        // it and `vsetq` writes it back. Nothing joined it before, so a
        // body that set `x = 0` proved x an integer, its register left the
        // boxed mask, and iget then put whatever the list held into it.
        if (std.mem.eql(u8, k, "for_statement") and Compiler.forIsIn(ch) and ch.namedChildCount() > 1) {
            changed = joinLocal(c, f, ch.namedChild(0).text(), rhsElem(c, f, ch.namedChild(1))) or changed;
        }
        if (std.mem.eql(u8, k, "expression_statement")) {
            const e0 = ch.namedChild(0);
            if (std.mem.eql(u8, e0.kind(), "postfix_expression")) {
                changed = joinLocal(c, f, e0.namedChild(0).text(), .int) or changed;
            }
            // `aL + v` as a statement appends v to aL in place (measured on
            // 1.27: list + x appends, in every position). The statement form
            // is observed here; a nested one is opened by openElemsIn.
            if (std.mem.eql(u8, e0.kind(), "binary_expression") and e0.namedChildCount() > 1 and
                std.mem.eql(u8, Compiler.opText(e0), "+") and
                std.mem.eql(u8, e0.namedChild(0).kind(), "identifier"))
            {
                changed = joinElem(c, f, e0.namedChild(0).text(), exprClass(c, f, e0.namedChild(1))) or changed;
            }
            if (std.mem.eql(u8, e0.kind(), "assignment_expression")) {
                const op = Compiler.opText(e0);
                if (!std.mem.eql(u8, op, "=") and
                    std.mem.eql(u8, e0.namedChild(0).kind(), "identifier"))
                {
                    changed = joinLocal(c, f, e0.namedChild(0).text(), .int) or changed;
                }
            }
        }

        if (std.mem.eql(u8, k, "expression_statement")) {
            const e = ch.namedChild(0);
            if (std.mem.eql(u8, e.kind(), "assignment_expression")) {
                const lhs = e.namedChild(0);
                const rc = exprClass(c, f, e.namedChild(1));
                if (std.mem.eql(u8, lhs.kind(), "identifier")) {
                    if (c.lookup(lhs.text())) |l| {
                        // Which class, if this assignment proves one. An
                        // assignment that proves nothing marks the local
                        // unprovable -- silence is the unsafe direction.
                        if (!l.cls_bad) {
                            const save_cur = c.cur;
                            c.cur = f;
                            const got = c.recvClass(e.namedChild(1));
                            c.cur = save_cur;
                            if (got) |g| {
                                if (l.cls) |had| {
                                    if (had != g) {
                                        l.cls_bad = true;
                                        l.cls = null;
                                        changed = true;
                                    }
                                } else {
                                    l.cls = g;
                                    changed = true;
                                }
                            } else if (exprClass(c, f, e.namedChild(1)) == .ref or l.cls != null) {
                                // an object from somewhere unprovable, or a
                                // second assignment we cannot vouch for
                                l.cls_bad = true;
                                l.cls = null;
                                changed = true;
                            }
                        }
                        const nc = l.class.join(rc);
                        if (nc != l.class) {
                            l.class = nc;
                            changed = true;
                        }
                        // What the assignment says about x's ELEMENTS. Ring
                        // copies at the assignment (C-7), so x's contents are
                        // the right-hand side's contents as they stand:
                        // `list(n)` zeros, a literal's members, another
                        // local's elements -- and for everything else, a
                        // call's result, a subscript, an attribute, ANYTHING.
                        // This used to join only `list(n)` and leave the rest
                        // at bottom, so `x = F()` then `add(x, 1)` called x
                        // a list of integers whatever F had put in it.
                        {
                            const ne = l.elem.join(rhsElem(c, f, e.namedChild(1)));
                            if (ne != l.elem) {
                                l.elem = ne;
                                changed = true;
                            }
                        }
                        // `aRow = aA[i]` needs no special case: exprClass on
                        // a subscript already returns the container's element
                        // class, so aRow becomes .list here and its own
                        // elements are `ref` -- enough to specialise the
                        // container access, not the element's type.
                    }
                } else if (std.mem.eql(u8, lhs.kind(), "subscript_expression")) {
                    // a[i] = v  ->  a's elements can be whatever v is
                    const b = lhs.namedChild(0);
                    if (std.mem.eql(u8, b.kind(), "identifier")) {
                        if (c.lookup(b.text())) |l| {
                            const ne = l.elem.join(rc);
                            if (ne != l.elem) {
                                l.elem = ne;
                                changed = true;
                            }
                        }
                    }
                }
            }
            changed = (try promoteCallArgs(c, f, e)) or changed;
        } else if (std.mem.eql(u8, k, "return_statement")) {
            if (retValue(ch)) |rv| {
                const rc2 = f.ret.join(exprClass(c, f, rv));
                if (rc2 != f.ret) {
                    f.ret = rc2;
                    changed = true;
                }
            } else {
                // A bare `return` yields NULL, the empty STRING (measured on
                // 1.27). This joined `.int` -- "bare `return` yields 0" -- and
                // would have gone on calling such a function an integer after
                // the codegen above it stopped returning one.
                // Unless it is a `return func t { ... }` the grammar cut: it returns the closure, a reference.
                const rc2 = f.ret.join(if (c.ret_ext.contains(nodeKey(ch))) Class.ref else Class.str);
                if (rc2 != f.ret) {
                    f.ret = rc2;
                    changed = true;
                }
            }
            changed = (try promoteCallArgs(c, f, ch)) or changed;
        } else if (std.mem.endsWith(u8, k, "_expression") or std.mem.eql(u8, k, "list_literal")) {
            // AN EXPRESSION THAT IS NOT A STATEMENT -- an `if` or `while`
            // condition, the value of `?`, a `for` bound, a `switch` value.
            // Its calls are call sites like any other, and they were NOT
            // observed: only expression statements and returns reached
            // promoteCallArgs. A function called in both kinds of place had
            // its parameter narrowed from half its call sites -- Ring's
            // stdlibcore RandomItem was typed `aList (int)` from
            // `randomitem(5)` while `? ... randomitem([1, 2, 3])` handed it a
            // list, unretained in a register no sweep would release
            // (stdlib_core.ring row 06, found 2026-10-14). Joins only widen.
            changed = (try promoteCallArgs(c, f, ch)) or changed;
        } else {
            // if / while / for / clauses: recurse over their statements.
            changed = (try walkClassify(c, f, ch, 0)) or changed;
        }
    }
    return changed;
}

/// The `i`-th argument of an `arguments` node as Ring counts them: a COMMENT
/// among the arguments is a node to the grammar and nothing to Ring, whose
/// scanner drops it (F-80) -- and codegen compiles such a call from its
/// re-read copy, comments blanked. `Sum3(1,  # one` / `2,` / `3)` reached
/// this walk as four arguments, so `b` was typed from the COMMENT (`ref`) and
/// `c` from the 2, while the code ran Sum3(1, 2, 3): the same program typed
/// two ways depending on where a comment stood, which the fmt court's D step
/// caught on bench/exec/lambda_reread.ring (2026-10-10).
fn argAt(args: ts.Node, i: u32) ?ts.Node {
    var seen: u32 = 0;
    var k: u32 = 0;
    while (k < args.namedChildCount()) : (k += 1) {
        const a = args.namedChild(k);
        if (std.mem.eql(u8, a.kind(), "comment")) continue;
        if (seen == i) return a;
        seen += 1;
    }
    return null;
}

/// A parameter is a reference if ANY call site hands it one.
fn promoteCallArgs(c: *Compiler, f: *Func, n: ts.Node) Error!bool {
    var changed = false;
    if (std.mem.eql(u8, n.kind(), "call_expression")) {
        const callee = n.namedChild(0).text();
        // add(aL, v) and insert(aL, i, v) are the observed appends; the
        // value's class joins aL's elements. openElemsIn relies on this
        // walk seeing every one under an expression statement or a return.
        const is_add = std.ascii.eqlIgnoreCase(callee, "add");
        if (is_add or std.ascii.eqlIgnoreCase(callee, "insert")) {
            const vi: u32 = if (is_add) 1 else 2;
            var aidx: u32 = 0;
            var ok = false;
            var q: u32 = 0;
            while (q < n.namedChildCount()) : (q += 1) {
                if (std.mem.eql(u8, n.namedChild(q).kind(), "arguments")) {
                    aidx = q;
                    ok = true;
                }
            }
            if (ok) {
                const ar = n.namedChild(aidx);
                if (argAt(ar, vi)) |vnode| {
                    const tgt = argAt(ar, 0).?;
                    if (std.mem.eql(u8, tgt.kind(), "identifier")) {
                        const save = c.cur;
                        defer c.cur = save;
                        c.cur = f;
                        if (c.lookup(tgt.text())) |l| {
                            const vc = exprClass(c, f, vnode);
                            const ne = l.elem.join(vc);
                            if (ne != l.elem) {
                                l.elem = ne;
                                changed = true;
                            }
                            const nl = l.class.join(.list);
                            if (nl != l.class) {
                                l.class = nl;
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
        if (c.findFunc(callee)) |g| {
            g.called = true;
            var a: u32 = 0;
            var args_idx: u32 = 0;
            var found = false;
            var ai: u32 = 0;
            while (ai < n.namedChildCount()) : (ai += 1) {
                if (std.mem.eql(u8, n.namedChild(ai).kind(), "arguments")) {
                    args_idx = ai;
                    found = true;
                }
            }
            if (found) {
                const args = n.namedChild(args_idx);
                while (a < g.params.len) : (a += 1) {
                    const an = argAt(args, a) orelse break;
                    const ac = exprClass(c, f, an);
                    for (g.locals.items) |*l| {
                        if (std.ascii.eqlIgnoreCase(l.name, g.params[a])) {
                            const nc = l.class.join(ac);
                            if (nc != l.class) {
                                l.class = nc;
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
    }
    var i: u32 = 0;
    while (i < n.namedChildCount()) : (i += 1) {
        changed = (try promoteCallArgs(c, f, n.namedChild(i))) or changed;
    }
    return changed;
}

fn exprClass(c: *Compiler, f: *Func, n: ts.Node) Class {
    const k = n.kind();
    if (std.mem.eql(u8, k, "number")) {
        // A decimal is not an int, and saying it is would let the boxed-
        // register mask miss it.
        const t = std.mem.trim(u8, n.text(), " \t\r\n");
        if (std.fmt.parseInt(i64, t, 10)) |_| return .int else |_| return .unknown;
    }
    if (std.mem.eql(u8, k, "boolean")) return .int;
    if (std.mem.eql(u8, k, "null")) return .str;
    if (std.mem.eql(u8, k, "string") or std.mem.eql(u8, k, "symbol")) return .str;
    if (std.mem.eql(u8, k, "list_literal")) return .list;
    if (std.mem.eql(u8, k, "subscript_expression")) {
        // What comes out of a container is its element class -- the second
        // level of inference that makes `aRow = aA[i]` then `aRow[k]`
        // compile to specialised opcodes.
        const base = n.namedChild(0);
        if (std.mem.eql(u8, base.kind(), "identifier")) {
            const save = c.cur;
            defer c.cur = save;
            c.cur = f;
            if (c.lookup(base.text())) |l| {
                // `s[i]` IS A ONE-CHARACTER STRING -- C-3, taken 2026-09-09.
                // This line still said `.int`, F-54's byte, and the runtime
                // had moved without it. A local assigned from it was then
                // believed UNBOXED, so `move` was emitted with no retain,
                // and the frame sweep released a string nobody had retained.
                // Over four calls a shared constant's count walked 4 -> 0
                // and it was FREED -- with its bytes, which for a constant
                // are the SOURCE TEXT. The five hard faults in the wide
                // clock were all the read after that.
                //
                // MONOTONE IN THE BASE'S CLASS, or the fixpoint keeps a
                // stale claim. This returned `l.elem` for every non-string
                // base, and an element class nothing has revealed is the
                // lattice's BOTTOM -- so when a call site walked early made
                // pv a string, `a = pv[i]` joined `str`; when a later site
                // widened pv to `ref`, pv[i] fell to bottom and `str` was
                // never taken back. len(a) then compiled as a STRING length
                // and raised "Bad parameter type!" on a pair, at
                // stzOutputSchema.ring:1110, and agentic/agentfile stopped
                // there (2026-09-24). A rule's answer may only rise as its
                // inputs rise: str -> str, list -> its elements, unknown ->
                // unknown, and anything wider -> ref, the top.
                return switch (l.class) {
                    .str => .str,
                    .list => l.elem,
                    .unknown => .unknown,
                    else => .ref,
                };
            }
        }
        return .ref;
    }
    if (std.mem.eql(u8, k, "parenthesized_expression")) return exprClass(c, f, n.namedChild(0));
    if (std.mem.eql(u8, k, "binary_expression")) {
        const op = Compiler.opText(n);
        if (std.mem.eql(u8, op, ":")) return .list;
        // `:Name = value` is Ring's NAMED PARAMETER and builds a two-element
        // LIST (F-59), so the register holding it holds a REFERENCE. Saying
        // `int` here -- which the comparison rule below does -- is the exact
        // trap the paragraph under `+` describes: an uncounted register
        // holding a counted value, and a use-after-free at the frame's exit.
        // It cost a day: the pair was freed by the callee's frame sweep with
        // nobody balancing it, and `if isList(a) and (f(a) or g(a))`
        // segfaulted at 0xc -- while the POISONING HEAP, which never reuses
        // freed memory, made it pass.
        if (std.mem.eql(u8, op, "=") and n.namedChildCount() >= 2 and
            std.mem.eql(u8, n.namedChild(0).kind(), "symbol")) return .list;
        // `/` is real division on 1.27 (3/2 is 1.50), so its result is not
        // provably a whole number and must not claim the int fast path.
        if (std.mem.eql(u8, op, "/")) return .unknown;
        // `+` is polymorphic on the LEFT operand (measured on 1.27: str + x
        // concatenates, list + x appends, num + str is a number or R41).
        // Saying "int" here typed `s = left(s, 1) + "|" + substr(s, 2)` as
        // an int: an uncounted register holding counted strings, and a
        // use-after-free at the frame's exit (found by rpp/tui.ring's Text,
        // 2026-09-03). The left operand's class decides; anything not
        // provably numeric is a reference.
        // AN OBJECT OPERAND DISPATCHES TO ITS CLASS'S `operator` (F-69), on
        // either side (`5 + o` calls operator("r+", 5)), and the method
        // returns whatever it likes -- Softanza's return `This`. So an
        // operand that MAY be an object -- class `ref` -- makes the result
        // `ref`, for every operator, a comparison as a value included
        // (`cmpv` lands the operator's own answer there).
        const rc0 = if (n.namedChildCount() > 1) exprClass(c, f, n.namedChild(1)) else .unknown;
        if (std.mem.eql(u8, op, "+")) {
            const lc = exprClass(c, f, n.namedChild(0));
            if (rc0 == .ref) return .ref;
            if (lc == .str) return .str;
            if (lc == .list) return .list;
            if (lc == .ref or lc == .unknown) return .ref;
            // a number plus a STRING is text when the string is the newline
            // alone (F-98), so the answer may be a string: never `.int`,
            // whose register is not counted. A rule and the class that
            // describes it are one change.
            if (rc0 == .str) return .ref;
            return .int;
        }
        const lc0 = exprClass(c, f, n.namedChild(0));
        if (lc0 == .ref or rc0 == .ref) return .ref;
        return .int; // the rest of arithmetic and logic yield numbers
    }
    if (std.mem.eql(u8, k, "unary_expression")) {
        // `-o` is operator("neg", 0) on an object, and answers anything
        if (n.namedChildCount() > 0 and exprClass(c, f, n.namedChild(0)) == .ref) return .ref;
        return .int;
    }
    if (std.mem.eql(u8, k, "identifier")) {
        const save = c.cur;
        defer c.cur = save;
        c.cur = f;
        if (c.lookup(n.text())) |l| return l.class;
        // A name this pass cannot resolve -- a $global, or a local not yet
        // defined -- is a REFERENCE, never an int. `.int` is the one class
        // that switches refcounting OFF, so it must never be a default:
        // guessing it for an unknown name means a heap value gets stored
        // without a retain and released without ever having been counted.
        //
        // Measured 2026-09-04 (F-53). `Choice(cName, aItems)` was called as
        // `Choice(:file, $files)`; the global argument classified as int, so
        // the parameter did, so its register was outside the boxed mask, so
        // `move` copied a live vector without retaining it -- and a string
        // three frees later went to rc -1. `Menu`, the same signature one
        // line below, was correct only because it happens to write
        // `aItems[1]`, which proves the parameter is a list.
        return .ref;
    }
    if (std.mem.eql(u8, k, "call_expression")) {
        const callee = n.namedChild(0).text();
        if (std.ascii.eqlIgnoreCase(callee, "list") or std.ascii.eqlIgnoreCase(callee, "newlist")) return .list;
        if (std.ascii.eqlIgnoreCase(callee, "char") or
            std.ascii.eqlIgnoreCase(callee, "lower") or
            std.ascii.eqlIgnoreCase(callee, "upper") or
            std.ascii.eqlIgnoreCase(callee, "trim") or
            std.ascii.eqlIgnoreCase(callee, "left") or
            std.ascii.eqlIgnoreCase(callee, "right") or
            std.ascii.eqlIgnoreCase(callee, "copy") or
            std.ascii.eqlIgnoreCase(callee, "string")) return .str;
        if (std.ascii.eqlIgnoreCase(callee, "fabs") or
            std.ascii.eqlIgnoreCase(callee, "max") or
            std.ascii.eqlIgnoreCase(callee, "min") or
            std.ascii.eqlIgnoreCase(callee, "number") or
            std.ascii.eqlIgnoreCase(callee, "islist") or
            std.ascii.eqlIgnoreCase(callee, "isstring") or
            std.ascii.eqlIgnoreCase(callee, "isnumber") or
            std.ascii.eqlIgnoreCase(callee, "isnull") or
            std.ascii.eqlIgnoreCase(callee, "ascii")) return .int;
        if (std.ascii.eqlIgnoreCase(callee, "len")) return .int;
        if (std.ascii.eqlIgnoreCase(callee, "floor")) return .int;
        if (c.findFunc(callee)) |g| return g.ret;
        return .ref;
    }
    return .ref;
}
