// rnx -- the Ring++ VM. Begun 2026-08-29 as rnx-spike, Stage 1 of the independence study.
//
// A register VM with 16-byte tagged values, contiguous vectors, immutable
// by-reference strings, and threaded dispatch (Zig labeled switch). The six
// F-39 algorithms are hand-compiled to its bytecode at the same op
// granularity Lua 5.4's compiler emits from bench.lua:
//   - numeric `for` is a fused opcode with the limit computed once (FORLOOP)
//   - `while i <= #a` re-evaluates the length every iteration (merge does)
//   - constants in hot ops ride as immediates (Lua: ADDK/MULK/MODK/IDIVK)
//   - no strength reduction, no hoisting the source didn't write
// One deliberate divergence, reported honestly: bytescan uses a byte-index
// OPCODE because Ring's s[i] is an operator, where Lua's string.byte is a
// stdlib CALL. That row measures a language-design difference on purpose.
//
// Kill criterion (study 4.6/8): any compute row worse than 3x Lua -> stop.

const std = @import("std");
const web = @import("web.zig");
pub const native = @import("native.zig");
const config = @import("config");

/// Reference counting + real frees. See build.zig for the three variants.
const RC = config.rc;
/// Allocate through mimalloc instead of a never-freeing bump arena.
const MI = config.mi;
/// Typed registers: the compiler marks which registers and which writes can
/// carry a heap reference, and everything else becomes a plain store with no
/// refcount traffic. This is what study 4.9's gradual types buy at runtime.
const TYPED = config.typed;

/// Deferred counting (Deutsch-Bobrow): register writes adjust NO counts at
/// all -- registers are uncounted roots. Only heap-to-heap edges are counted.
/// An object at zero goes to a zero-count table and is freed only after a
/// root scan proves no register holds it.
const DEFER = config.deferred;
/// Copy-on-write. Ring's assignment COPIES a list; `b = a` then `b[1] = 9`
/// must leave `a` alone. Sharing until the first write makes that semantics
/// cost a pointer instead of a memcpy -- and it is what lets Softanza's
/// ~300K lines keep meaning what they mean. The shared test is `rc > 1`, so COW
/// requires reference counts that include registers.
const COW = config.cow;

/// Zero-count table: objects that MIGHT be garbage. Every vector enters at
/// birth (rc 0) and leaves only when a root scan clears it.
var zct: [8192]*Vec = undefined;
var zct_len: u32 = 0;
var zct_tmp: [8192]*Vec = undefined;
/// Registers scanned as roots. Frames nil their boxed registers on return, so
/// every .vec found in this window is live -- never a dangling pointer.
const ROOT_SCAN = 2048;

/// Per-function bitmask of registers that may hold a heap reference. Only
/// these are swept when a call frame is torn down. Index = function id,
/// carried in the call instruction's `c` field.
pub var fn_masks: [64]u64 = .{0} ** 64;

// ---------------------------------------------------- the host list API
//
// An engine building or reading a Ring list calls back into the VM through
// native.HostApi. These are those callbacks. They need the VM, and the
// runtime is single-threaded and does not re-enter a native call, so the
// active VM is a global set once before an engine can reach any of them.
// See native.zig for the ownership rule; it is one sentence and these
// functions are the whole of its implementation.
var active_vm: ?*VM = null;

fn hostListNew() callconv(.c) native.RppList {
    const vm = active_vm orelse return null;
    const v = vm.newVec(8);
    // The build reference. A vector born rc 0 is exactly what a deferred
    // collection frees, and pushing to it allocates -- so an in-progress
    // list with no reference is a list that can vanish mid-build.
    v.rc += 1;
    return v;
}

fn hostListPushNum(l: native.RppList, x: f64) callconv(.c) void {
    const vm = active_vm orelse return;
    const v: *Vec = @ptrCast(@alignCast(l orelse return));
    vm.vecPushB(v, VM.narrow(x), false);
}

fn hostListPushStr(l: native.RppList, p: [*]const u8, n: u32) callconv(.c) void {
    const vm = active_vm orelse return;
    const v: *Vec = @ptrCast(@alignCast(l orelse return));
    // Copied, as every string crossing this boundary is.
    vm.vecPushB(v, Value.str(vm.newStr(p[0..n])), true);
}

fn hostListPushList(l: native.RppList, inner: native.RppList) callconv(.c) void {
    const vm = active_vm orelse return;
    const v: *Vec = @ptrCast(@alignCast(l orelse return));
    const iv: *Vec = @ptrCast(@alignCast(inner orelse return));
    // TRANSFER: the inner list's build reference becomes the parent slot's.
    // Retaining here instead would leave every nested list one count high
    // for ever, which is a leak that no test can see.
    vm.vecPushB(v, Value.vec(iv), false);
}

fn hostListLen(l: native.RppList) callconv(.c) u32 {
    const v: *Vec = @ptrCast(@alignCast(l orelse return 0));
    return v.len;
}

/// 1-based, as Ring counts.
fn hostItem(l: native.RppList, i: u32) ?Value {
    const v: *Vec = @ptrCast(@alignCast(l orelse return null));
    if (i < 1 or i > v.len) return null;
    return v.ptr[i - 1];
}

fn hostListTag(l: native.RppList, i: u32) callconv(.c) u32 {
    const it = hostItem(l, i) orelse return @intFromEnum(native.Tag.nil);
    return @intFromEnum(switch (it.tag) {
        .int => native.Tag.int,
        .num => native.Tag.num,
        .str => native.Tag.str,
        .vec => native.Tag.list,
        .obj => native.Tag.obj,
        else => native.Tag.nil,
    });
}

fn hostListNum(l: native.RppList, i: u32) callconv(.c) f64 {
    const it = hostItem(l, i) orelse return 0;
    return switch (it.tag) {
        .int => @floatFromInt(it.p.i),
        .num => it.p.d,
        else => 0,
    };
}

fn hostListStr(l: native.RppList, i: u32, out_len: *u32) callconv(.c) [*]const u8 {
    out_len.* = 0;
    const it = hostItem(l, i) orelse return "";
    if (it.tag != .str) return "";
    out_len.* = it.p.s.len;
    return it.p.s.ptr;
}

fn hostListList(l: native.RppList, i: u32) callconv(.c) native.RppList {
    const it = hostItem(l, i) orelse return null;
    if (it.tag != .vec) return null;
    return it.p.v;
}

/// Fill the vtable and name the VM the callbacks act on. Called before an
/// engine can be handed the table -- that is, from `LoadLib`.
pub fn hostInstall(vm: *VM) void {
    active_vm = vm;
    native.host_api = .{
        .register = &native.register,
        .list_new = &hostListNew,
        .list_push_num = &hostListPushNum,
        .list_push_str = &hostListPushStr,
        .list_push_list = &hostListPushList,
        .list_len = &hostListLen,
        .list_tag = &hostListTag,
        .list_num = &hostListNum,
        .list_str = &hostListStr,
        .list_list = &hostListList,
    };
}

// -------------------------------------------------------------- mimalloc
//
// Declared extern rather than @cImport'd: only four entry points are used
// and this keeps the header out of the build. Unreferenced externs create
// no link dependency, so the arena build does not need mimalloc present.

extern fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
extern fn mi_realloc_aligned(p: ?*anyopaque, newsize: usize, alignment: usize) ?*anyopaque;
extern fn mi_free(p: ?*anyopaque) void;

// -------------------------------------------------------------- C runtime
//
// Ring's date, time, environment and shell builtins ARE C's: localtime,
// strftime, mktime, getenv, _putenv_s, system (vendor/ring-vm/src/
// genlib_e.c, os_e.c). The oracle is built by the same `zig cc` against the
// same mingw runtime, so calling them here gives byte-identical answers --
// `%c`, `%x`, `%Z` and the day names included -- where reimplementing
// strftime would be a second, drifting copy. libc is already linked.
//
// ON WINDOWS the plain names are the 32-BIT time functions: mingw's headers
// map `localtime`/`mktime`/`time` to `_localtime64`/`_mktime64`/`_time64`
// by inline wrappers, and the exported plain symbols take a 32-bit time_t.
// So the 64-bit ones are bound by name.
//
// `CTm` carries padding: glibc's struct tm has two more fields than C's
// nine, and mktime WRITES them.
const CTm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    _pad: [4]u64 = .{ 0, 0, 0, 0 },
};
const is_win = @import("builtin").os.tag == .windows;
const c_time = if (is_win) struct {
    extern "c" fn _time64(t: ?*i64) i64;
    extern "c" fn _localtime64(t: *const i64) ?*CTm;
    extern "c" fn _mktime64(tm: *CTm) i64;
    fn now() i64 {
        return _time64(null);
    }
    fn local(t: *const i64) ?*CTm {
        return _localtime64(t);
    }
    fn mk(tm: *CTm) i64 {
        return _mktime64(tm);
    }
} else struct {
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn localtime(t: *const i64) ?*CTm;
    extern "c" fn mktime(tm: *CTm) i64;
    fn now() i64 {
        return time(null);
    }
    fn local(t: *const i64) ?*CTm {
        return localtime(t);
    }
    fn mk(tm: *CTm) i64 {
        return mktime(tm);
    }
};
extern "c" fn strftime(buf: [*]u8, max: usize, fmt: [*:0]const u8, tm: *const CTm) usize;
// clock() IS C's clock(), as Ring's is, and clockspersecond() its
// CLOCKS_PER_SEC. They mean different things per platform and a program
// measured there reads the platform's meaning: on Windows' C runtime WALL
// time since the process started, in milliseconds; on glibc and macOS the
// process's CPU time, in microseconds -- so a 120 ms sleep reads 125 on the
// Windows oracle and 0 on the Linux one. Our own wall-clock milliseconds
// agreed on Windows and answered 1 on Linux (bench/exec/builtins2.ring's
// syssleep row, the first Linux run, 2026-09-28).
extern "c" fn clock() c_long;
const clocks_per_sec: i64 = if (is_win) 1000 else 1_000_000;

// THE MATHS BUILTINS ARE THE C LIBRARY'S, as Ring's are (math_e.c calls
// sin, exp, pow ...). Zig's @exp and std.math.pow are accurate but NOT the
// same function: glibc's exp and Zig's differ in the last bits
// (6.25008906842049772 against ...683 for exp(1.8326)), and so do the
// Windows runtime's pow and Zig's. numeric_embedding trains a small network
// for 400 epochs on data made with sin and cos, and on Linux that last-bit
// difference was an assertion Ring passes and Ring++ failed, three runs of
// three (2026-09-28). fabs, floor, ceil and sqrt are exact under IEEE and
// stay Zig's.
//
// ON LINUX THE NAMES ALONE ARE NOT ENOUGH: Zig's compiler-rt defines exp,
// sin, log ... inside the binary, the link resolves them there, and only
// pow was imported from glibc -- so exp still answered Zig's digits. glibc's
// own functions are taken from libm.so.6 by name, once each (glibcFn); the
// Linux oracle imports exactly those (exp@GLIBC_2.29, sin@GLIBC_2.2.5 ...).
const F1 = *const fn (f64) callconv(.c) f64;
const F2 = *const fn (f64, f64) callconv(.c) f64;

fn glibcFn(comptime T: type, comptime name: [:0]const u8) T {
    // THE NAME IS PART OF THE CACHE'S TYPE ON PURPOSE: a struct declared here
    // is memoised on what it captures, and capturing T alone gave sin, cos
    // and exp ONE slot -- cos(x) answered sin(x) on the first build of this.
    const S = struct {
        const which = name;
        var f: ?T = null;
    };
    if (S.f) |f| return f;
    const h = std.c.dlopen("libm.so.6", .{ .NOW = true }) orelse @panic("libm.so.6 not found");
    const p = std.c.dlsym(h, name) orelse @panic("libm.so.6 has no " ++ name);
    S.f = @ptrCast(@alignCast(p));
    return S.f.?;
}

fn libm1(comptime name: [:0]const u8, x: f64) f64 {
    if (comptime host_os == .linux) return glibcFn(F1, name)(x);
    return @field(libm, name)(x);
}

fn libm2(comptime name: [:0]const u8, x: f64, y: f64) f64 {
    if (comptime host_os == .linux) return glibcFn(F2, name)(x, y);
    return @field(libm, name)(x, y);
}

const libm = struct {
    extern "c" fn sin(x: f64) f64;
    extern "c" fn cos(x: f64) f64;
    extern "c" fn tan(x: f64) f64;
    extern "c" fn asin(x: f64) f64;
    extern "c" fn acos(x: f64) f64;
    extern "c" fn atan(x: f64) f64;
    extern "c" fn atan2(y: f64, x: f64) f64;
    extern "c" fn sinh(x: f64) f64;
    extern "c" fn cosh(x: f64) f64;
    extern "c" fn tanh(x: f64) f64;
    extern "c" fn log(x: f64) f64;
    extern "c" fn log10(x: f64) f64;
    extern "c" fn exp(x: f64) f64;
    extern "c" fn pow(x: f64, y: f64) f64;
};
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;
const c_env = if (is_win) struct {
    extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
    fn set(n: [*:0]const u8, v: [*:0]const u8) c_int {
        return _putenv_s(n, v);
    }
    // Ring's own Windows unsetenv (os_e.c) is _putenv_s(name, ""): an empty
    // value REMOVES the variable there.
    fn unset(n: [*:0]const u8) c_int {
        return _putenv_s(n, "");
    }
} else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    fn set(n: [*:0]const u8, v: [*:0]const u8) c_int {
        return setenv(n, v, 1);
    }
    fn unset(n: [*:0]const u8) c_int {
        return unsetenv(n);
    }
};

// C's stdio, as Ring's file functions call it (file_e.c) -- text mode on
// Windows included, which is why a file Softanza writes with fopen "w" has
// CR LF line ends on both runtimes. FILE* is opaque here.
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn fflush(f: *anyopaque) c_int;
extern "c" fn fwrite(p: [*]const u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fread(p: [*]u8, sz: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fgetc(f: *anyopaque) c_int;
extern "c" fn fputc(ch: c_int, f: *anyopaque) c_int;
extern "c" fn fputs(s: [*:0]const u8, f: *anyopaque) c_int;
extern "c" fn fgets(s: [*]u8, n: c_int, f: *anyopaque) ?[*]u8;
extern "c" fn fseek(f: *anyopaque, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(f: *anyopaque) c_long;
extern "c" fn rewind(f: *anyopaque) void;
extern "c" fn feof(f: *anyopaque) c_int;
extern "c" fn ferror(f: *anyopaque) c_int;
extern "c" fn clearerr(f: *anyopaque) void;
extern "c" fn ungetc(ch: c_int, f: *anyopaque) c_int;
extern "c" fn tmpfile() ?*anyopaque;
extern "c" fn freopen(path: [*:0]const u8, mode: [*:0]const u8, f: *anyopaque) ?*anyopaque;
extern "c" fn perror(s: [*:0]const u8) void;
extern "c" fn fgetpos(f: *anyopaque, pos: *anyopaque) c_int;
extern "c" fn fsetpos(f: *anyopaque, pos: *const anyopaque) c_int;
const c_wfopen = if (is_win) struct {
    extern "c" fn _wfopen(path: [*:0]const u16, mode: [*:0]const u16) ?*anyopaque;
} else struct {};

/// Ring's fopen (general.c ring_general_fopen): on Windows the UTF-8 path
/// goes to _wfopen as UTF-16, so a non-ASCII name opens; plain fopen when
/// the conversion fails, as Ring falls back.
fn ringFopen(path: []const u8, mode: []const u8) ?*anyopaque {
    if (path.len == 0 or mode.len == 0) return null;
    var pb: [4096]u8 = undefined;
    var mb: [64]u8 = undefined;
    const pz = cz(&pb, path) orelse return null;
    const mz = cz(&mb, mode) orelse return null;
    if (is_win and path.len < 2048) {
        var wp: [2048:0]u16 = undefined;
        var wm: [64:0]u16 = undefined;
        const np = std.unicode.utf8ToUtf16Le(&wp, path) catch return fopen(pz, mz);
        const nm = std.unicode.utf8ToUtf16Le(&wm, mode) catch return fopen(pz, mz);
        if (np >= wp.len or nm >= wm.len) return fopen(pz, mz);
        wp[np] = 0;
        wm[nm] = 0;
        return c_wfopen._wfopen(@ptrCast(&wp), @ptrCast(&wm));
    }
    return fopen(pz, mz);
}

/// `s` NUL-terminated in `buf`, for a C call; null if it does not fit or
/// holds a NUL of its own (C would read it as shorter than it is).
fn cz(buf: []u8, s: []const u8) ?[*:0]const u8 {
    if (s.len + 1 > buf.len or std.mem.indexOfScalar(u8, s, 0) != null) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Ring's date test for adddays/diffdays (genlib_e.c:2629): ten characters,
/// dd?mm?yyyy with / - . or space as the separator, a real day of a real
/// month, February 29 only in a leap year.
fn ringIsDate(s: []const u8) bool {
    if (s.len != 10) return false;
    for ([_]usize{ 0, 1, 3, 4, 6, 7, 8, 9 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    for ([_]usize{ 2, 5 }) |i| switch (s[i]) {
        '/', '-', '.', ' ' => {},
        else => return false,
    };
    const d = ringDateField(s, 0, 2);
    const m = ringDateField(s, 3, 2);
    const y = ringDateField(s, 6, 4);
    if (d < 1 or d > 31 or m < 1 or m > 12 or y < 1) return false;
    const dim = [_]i32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (d > dim[@intCast(m - 1)] and !(d == 29 and m == 2 and ringLeap(y))) return false;
    return true;
}
fn ringDateField(s: []const u8, at: usize, n: usize) i32 {
    return std.fmt.parseInt(i32, s[at .. at + n], 10) catch 0;
}
fn ringLeap(y: i32) bool {
    if (@rem(y, 400) == 0) return true;
    if (@rem(y, 100) == 0) return false;
    return @rem(y, 4) == 0;
}

var mi_dummy: u8 = 0;

fn miAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    return @ptrCast(mi_malloc_aligned(len, alignment.toByteUnits()));
}
fn miResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false; // force remap; mi_expand's semantics are not worth the subtlety here
}
fn miRemap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(mi_realloc_aligned(memory.ptr, new_len, alignment.toByteUnits()));
}
fn miFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    mi_free(memory.ptr);
}
const mi_vtable = std.mem.Allocator.VTable{
    .alloc = miAlloc,
    .resize = miResize,
    .remap = miRemap,
    .free = miFree,
};
pub const mi_allocator = std.mem.Allocator{ .ptr = @ptrCast(&mi_dummy), .vtable = &mi_vtable };

// ---- the poisoning heap, for finding a use-after-free ------------------
//
// A freed block is FILLED WITH A POISON BYTE and then QUARANTINED -- never
// handed back. So a pointer used after its owner freed it reads 0xDD rather
// than whatever the allocator recycled into that address, and the bug stops
// depending on what ran before it.
//
// That dependence is the whole reason this exists. perf/seams' federation
// call returns one byte, ASCII 13, where Ring returns an empty string -- and
// inserting a single unrelated call earlier in the program makes it correct.
// A symptom that moves when unrelated allocations move is not a wrong code
// path; it is a stale pointer reading recycled memory (2026-09-14).
//
// `remap` is refused as well as `resize`, so a grown buffer always moves and
// the old one is poisoned -- a stale pointer into a list that outgrew its
// storage is exactly the shape being hunted.
//
// It never returns memory to the OS, so it is for a probe run, not for the
// gate: RNXC_POISON=1 in the environment turns it on.
pub var poison_on: bool = false;

/// RNXC_NOINPLACE=1: never grow a string in its own buffer.
///
/// The in-place append is this runtime's sharpest edge -- "aliasing is the
/// whole risk" -- so a switch that turns it off is the first question to ask
/// of any corrupted string. It earned its keep on 2026-09-15: app/06 passed
/// under it and failed without it, which said the damage was in the string
/// path and not in the tables, and the ADD trace below then showed the bytes
/// arriving already wrong. (The append was innocent: it was a bridge
/// answering out of a dead stack frame. Turning it off merely moved the
/// allocations.)
pub var no_inplace: bool = false;

/// RNXC_TRACE_ADD=1: every string append of a middling size -- what it was
/// appending to, what it was appending, the refcount and capacity the
/// in-place decision was made on, and the buffer address.
///
/// This is what named the defect of 2026-09-15: the lengths were all right
/// and the RIGHT-HAND BYTES were already garbage, which pointed past the
/// append entirely, at whoever produced the value.
pub var trace_add: bool = false;
pub const POISON_FREED: u8 = 0xDD;

fn poisonAlloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
    return miAlloc(ctx, len, a, ra);
}
fn poisonResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
fn poisonRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null; // force alloc + copy + free, so the old block gets poisoned
}
fn poisonFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    @memset(memory, POISON_FREED);
    // quarantined on purpose: not given back, so the address is never reused
}
const poison_vtable = std.mem.Allocator.VTable{
    .alloc = poisonAlloc,
    .resize = poisonResize,
    .remap = poisonRemap,
    .free = poisonFree,
};
pub const poison_allocator = std.mem.Allocator{ .ptr = @ptrCast(&mi_dummy), .vtable = &poison_vtable };

/// The VM heap: poisoning when asked for, mimalloc otherwise.
pub fn vmHeap() std.mem.Allocator {
    return if (poison_on) poison_allocator else mi_allocator;
}

// ---- tracing a return -------------------------------------------------
//
// `RNXC_TRACE_RET=<function name>` prints, for every `ret` executed inside a
// function of that name, what is being returned, what lands in the caller's
// register, and WHAT THE CALLER DOES NEXT.
//
// The last of those is the point. perf/seams has a value that is provably
// correct inside a function and wrong at the call site, with nothing in
// between -- probes on both sides of the `ret` read an empty string, and the
// caller reads one byte. Something between the two reads a different
// register than the one the result was written to, and printing the
// caller's next instruction is what shows it (2026-09-14).
pub var trace_ret_name: []const u8 = "";
pub var g_trace_native: bool = false;
/// WHERE IS IT HANGING? `RNXC_WATCHDOG=<seconds>` reports the Ring line and
/// the call chain once the program has run that long, the way any error
/// does, and stops. A DEADLINE rather than a count of steps, because a
/// count cannot tell honest work from a runaway: the first version of this
/// counted backward branches, and both the hanging program AND the working
/// one spent it in the same place -- the library's own top level, building
/// its tables in long correct loops. Time is the discriminator a hang
/// actually has. Off unless asked for, like RNXC_TRACE_RET.
pub var g_watchdog_s: i64 = 0;
pub var g_watchdog_at: i64 = 0;
var g_wd_tick: u32 = 0;

/// Start the clock. Called where the VM begins a top level, so that
/// compiling 613 files does not count against a program's running time --
/// and called from EVERY such place: arming it at one of the two cost an
/// hour, because `rnxc <file>` goes through the other one and the
/// diagnostic simply stayed quiet, which reads exactly like a diagnostic
/// that has nothing to report.
pub fn armWatchdog() void {
    if (g_watchdog_s > 0) g_watchdog_at = std.time.milliTimestamp() + g_watchdog_s * 1000;
}

/// How many native libraries LoadLib has opened. It is the payload of a
/// DLL value, so two libraries are two different values.
var libs_loaded: i64 = 0;

var tr_buf: [160]u8 = undefined;

fn describeValue(v: Value) []const u8 {
    return switch (v.tag) {
        .nil => "nil",
        .int => std.fmt.bufPrint(&tr_buf, "int {d}", .{v.p.i}) catch "int ?",
        .num => std.fmt.bufPrint(&tr_buf, "num {d}", .{v.p.d}) catch "num ?",
        .str => std.fmt.bufPrint(&tr_buf, "str len={d} rc={d} first={d} ptr=0x{x}", .{
            v.p.s.len,
            v.p.s.rc,
            if (v.p.s.len > 0) v.p.s.ptr[0] else @as(u8, 0),
            @intFromPtr(v.p.s.ptr),
        }) catch "str ?",
        .vec => std.fmt.bufPrint(&tr_buf, "vec len={d}", .{v.p.v.len}) catch "vec ?",
        .obj => "obj",
        .dll => "dll",
        .cptr => "cptr",
    };
}

// ---------------------------------------------------------------- values

/// `dll` is a loaded native LIBRARY, and it is here because Ring has the
/// same idea: `LoadLib` answers a value whose `type()` is "DLL", for which
/// `isPointer` is TRUE and `isNumber` FALSE, and which cannot even be
/// concatenated (R21 on 1.27). Ours returned the integer 1, so a faithful
/// `isPointer` would have answered FALSE for a library that HAD loaded --
/// and stzGraph._EngineAvailable() would have switched the whole engine
/// graph path off in silence, which is what its own comment warns about.
/// An ENGINE handle is a different thing and stays a NUMBER, as it is on
/// Ring (`o.Engine()` is type NUMBER, isPointer 0).
///
/// `cptr` is Ring's C POINTER (2026-09-23): what fopen answers. Its payload
/// indexes `VM.cptrs`, which holds the pointer and its KIND -- "file" for a
/// FILE* -- because Ring's `type(fp)` is that kind, lowercase, and every copy
/// of a handle must see fclose NULL it (Ring sets the argument's pointer to
/// NULL, and a NULL pointer is FALSE in an `if`). Measured on 1.27
/// (bench/exec/file_stdio.ring): type "file", isPointer 1, isList 0, never
/// equal to "", R21 in arithmetic, printed as address / kind / status.
pub const Tag = enum(u32) { nil, int, num, str, vec, obj, dll, cptr };

/// An object: a class id plus a flat slot array, one slot per attribute.
///
/// This is the whole point of the redesign applied to Ring's object model.
/// Ring stores an object as a LIST of attribute lists, so reading `@oString`
/// walks a list looking for a name. Here the compiler resolves `@oString` to
/// a slot INDEX, and the read is one load.
pub const Obj = struct {
    slots: [*]Value,
    nslots: u32,
    class: u16,
    /// Ring's reference, as `Vec.rref`: a referenced object is shared, not
    /// copied, by every later transfer (0 none, 1 referenced, 2 pinned).
    rref: u8 = 0,
    rc: u32 = 0,
    mark: u32 = 0,
    /// Attributes `addattribute` gave THIS object (Ring's is per object,
    /// measured: another instance of the class does not have it), as
    /// [name, value, name, value ...], names lower-cased. Consulted by the
    /// by-name paths when the class's own table misses; copied with the
    /// object and released with it.
    extra: ?*Vec = null,
};

/// Dispatch: `class_of(receiver)` x `name index` -> method, in one lookup.
/// A linear scan over a method list would make every call O(methods), which
/// is the very cost this project exists to remove.
pub var dispatch: []u32 = &.{}; // 0 = absent, else method index + 1
pub var n_names: u32 = 0;
/// Ring's `decimals(n)`: the places every non-whole number prints with,
/// in `?`, in a concatenation and in string(). A mutable process-global
/// -- the analysis's 2.10 -- reproduced because the estate SETS it at
/// load (`StzDecimals(2)`, stzNumber.ring:91) and byte-identity with
/// the oracle depends on it. Measured 2026-09-11: default 2; 0..90,
/// else R33; a whole number prints without a point at any setting.
pub var g_decimals: usize = 2;

/// A non-whole number with g_decimals places, rounded HALF TO EVEN from
/// the exact binary value -- C-1's decision and what the oracle prints
/// (2.5 -> 2, 0.125 -> 0.12, 2.675 -> 2.67). std.fmt.float.render at a
/// precision rounds the shortest decimal STRING half up instead (3,
/// 0.13, 2.68), so up to 15 places the digits are made here; past that
/// the scaling is inexact and render stands (decimals(20) then prints
/// the expansion Ring prints).
pub fn fmtDecimals(buf: []u8, f: f64) []const u8 {
    const p = g_decimals;
    if (!std.math.isFinite(f)) {
        return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = p }) catch "0";
    }
    // f = m * 2^-k exactly, k in 1..1074 for a non-whole finite double
    const bits: u64 = @bitCast(@abs(f));
    const exp_field: u64 = (bits >> 52) & 0x7ff;
    var m: u128 = bits & ((@as(u64, 1) << 52) - 1);
    var e: i32 = undefined;
    if (exp_field == 0) {
        e = -1074; // subnormal
    } else {
        m |= @as(u128, 1) << 52;
        e = @as(i32, @intCast(exp_field)) - 1075;
    }
    if (e >= 0) {
        // A WHOLE DOUBLE PAST 2^53-1, which numText sends here because Ring
        // prints it through "%.Nf" (general.c:343): its EXACT decimal value,
        // then N zeros. render printed the shortest digits padded with
        // zeros instead -- 2^63 came out 9223372036854776000 where Ring
        // says 9223372036854775808. m * 2^e, in base-1e9 limbs.
        var limbs: [40]u32 = undefined;
        var nlimb: usize = 0;
        var mm: u64 = @intCast(m);
        while (mm != 0 or nlimb == 0) {
            limbs[nlimb] = @intCast(mm % 1_000_000_000);
            mm /= 1_000_000_000;
            nlimb += 1;
        }
        var t: i32 = 0;
        while (t < e) : (t += 1) {
            var carry: u64 = 0;
            for (limbs[0..nlimb]) |*l| {
                const v = @as(u64, l.*) * 2 + carry;
                l.* = @intCast(v % 1_000_000_000);
                carry = v / 1_000_000_000;
            }
            if (carry != 0) {
                if (nlimb == limbs.len) return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = p }) catch "0";
                limbs[nlimb] = @intCast(carry);
                nlimb += 1;
            }
        }
        var w: usize = 0;
        if (f < 0) {
            buf[w] = '-';
            w += 1;
        }
        const top = std.fmt.bufPrint(buf[w..], "{d}", .{limbs[nlimb - 1]}) catch return "0";
        w += top.len;
        var li: usize = nlimb - 1;
        while (li > 0) {
            li -= 1;
            const piece = std.fmt.bufPrint(buf[w..], "{d:0>9}", .{limbs[li]}) catch return "0";
            w += piece.len;
        }
        // Ring's buffer is RING_MEDIUMBUF, 128 bytes; past it Ring prints
        // "%.90e" instead. Not reproduced -- a number near 1e125 -- and
        // render answers in its own shape there (named in CLAUDE.md).
        if (w + 1 + p >= 128) return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = p }) catch "0";
        if (p == 0) return buf[0..w];
        if (w + 1 + p > buf.len) return "0";
        buf[w] = '.';
        w += 1;
        @memset(buf[w .. w + p], '0');
        return buf[0 .. w + p];
    }
    if (e < -120) {
        // too small for u128: render
        return std.fmt.float.render(buf, f, .{ .mode = .decimal, .precision = p }) catch "0";
    }
    const k: u7 = @intCast(-e);
    const one: u128 = @as(u128, 1) << k;
    const mask: u128 = one - 1;
    var ip: u128 = m >> k;
    var rem: u128 = m & mask;
    // p fraction digits, exactly
    var digits: [96]u8 = undefined;
    var i: usize = 0;
    while (i < p) : (i += 1) {
        rem *= 10;
        digits[i] = @intCast(rem >> k);
        rem &= mask;
    }
    // the rest of the remainder decides: > half up, < half down, = half even
    var up = false;
    if (rem * 2 > one) {
        up = true;
    } else if (rem * 2 == one) {
        const last: u128 = if (p == 0) ip else digits[p - 1];
        up = (last % 2) == 1;
    }
    if (up) {
        var j: usize = p;
        var carry = true;
        while (carry and j > 0) {
            j -= 1;
            if (digits[j] == 9) {
                digits[j] = 0;
            } else {
                digits[j] += 1;
                carry = false;
            }
        }
        if (carry) ip += 1;
    }
    var n: usize = 0;
    if (f < 0) {
        if (n >= buf.len) return "0";
        buf[n] = '-';
        n += 1;
    }
    const ipt = std.fmt.bufPrint(buf[n..], "{d}", .{ip}) catch return "0";
    n += ipt.len;
    if (p == 0) return buf[0..n];
    if (n + 1 + p > buf.len) return "0";
    buf[n] = '.';
    n += 1;
    i = 0;
    while (i < p) : (i += 1) {
        buf[n] = '0' + digits[i];
        n += 1;
    }
    return buf[0..n];
}
/// Per-method: where it starts, how big its frame is, its mask id.
/// A dispatch-table entry. `id` names the boxed-register mask for the
/// deferred-counting build only, so it is bounded to the mask table
/// rather than truncated -- a truncated id would select ANOTHER
/// function's mask.
/// `id` indexes `fn_masks`, or is NO_MASK when the method's id is past that
/// table -- then the frame is swept whole on return.
/// `shift`: a PLAIN function attached by addmethod (2026-09-23). Its
/// parameters start at r0, where a method's start at r1 behind the
/// receiver, so `callm` moves the arguments down one register on entry.
/// `nparams` is the method's declared parameter count, which `callm`,
/// `callmq` and `callmf` compare with the call's argument count before the
/// frame is pushed: Ring raises R19 (too few) or R20 (too many) at the
/// call, catchable, and never enters the method (measured on both 1.27
/// builds, 2026-09-30, for a method, `init`, `super` and a brace hook).
/// `unchecked_arity` for an entry whose count the VM does not know -- one
/// that addmethod builds at run time.
pub const MethodEnt = struct { entry: u32, frame: u8, id: u8, shift: bool = false, nparams: u8 = unchecked_arity };
pub const unchecked_arity: u8 = 0xff;
pub var method_tab: []MethodEnt = &.{};
/// Ring's automatic getters and setters (F-73): per attribute name index,
/// the name index of `get<name>` / `set<name>`, ACC_NONE when the program
/// has no such name. Built by compileFinish, carried by the image.
pub const ACC_NONE: u32 = 0xFFFF_FFFF;
pub var acc_get: []const u32 = &.{};
pub var acc_set: []const u32 = &.{};
/// What an attribute access by name carries in its `c`, from the compiler:
/// which of Ring's rules for calling an accessor applies at that site.
pub const ACC_CHECK: u8 = 0; // any object: its accessor if its class has one
pub const ACC_RAW: u8 = 1; // syntactically `This`: never
pub const ACC_NOT_THIS: u8 = 2; // in a method: never when the object IS r0
pub const ACC_BRACE: u8 = 3; // a brace in a method: never on r0's own class
/// Methods attached at run time, per class, lower-cased, for ismethod and
/// methods() -- a name the program never mentions has no dispatch column.
pub const DynMethod = struct { cls: u16, name: []const u8, slot: u32 };
pub var dyn_methods: std.ArrayListUnmanaged(DynMethod) = .{};
/// `clock()` counts from here, so it starts near zero as Ring's does
/// rather than reporting the epoch in milliseconds.
/// The OS this build targets, for the platform predicates.
const host_os = @import("builtin").os.tag;

// ---- console primitives: the widget-tree contract's gate 3 --------------
//
// Measured 2026-09-03 (ringpp bench/console_probe.py): in conhost, VT
// processing is OFF by default and Ring 1.27 cannot switch it on, so a
// pure-Ring renderer prints literal escape characters in a plain cmd.exe
// window. A process CAN switch it on itself, and can read one key without
// Enter, in conhost and Windows Terminal alike -- one kernel32 call each.
// So those calls live here, in the one binary, behind four builtins:
//
//     tui_init()   enable VT out + raw in; 1 if it worked, 0 if there is
//                  no console (a pipe) -- the renderer then stays line-driven
//     tui_key()    one key, no Enter. A character comes back as itself; a
//                  key that is not a character comes back NAMED: <enter>,
//                  <esc>, <tab>, <backspace>, <up> <down> <left> <right>,
//                  <home> <end> <delete>, <f1>..<f12>. Under a pipe it reads
//                  one byte of stdin, so the plumbing is testable headless.
//     tui_size()   [columns, rows] of the window; [0, 0] without a console
//     tui_done()   put both modes back exactly as found
//
// The kernel32 functions are declared here rather than taken from std, so
// the four calls are exactly the four the probe measured and nothing else.
// The POSIX branch (termios) is written to the same shape but has NOT been
// measured on this machine; it is compiled only on a non-Windows target.

const ConsoleState = struct { in_mode: u32 = 0, out_mode: u32 = 0, active: bool = false };
pub var console: ConsoleState = .{};
var keybuf: [16]u8 = undefined;

const KeyEventRecord = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: u16,
    dwControlKeyState: u32,
};
/// EventType, then a 16-byte union of which only the key event is read.
const InputRecord = extern struct { EventType: u16, _pad: u16, Event: KeyEventRecord };
const Coord = extern struct { X: i16, Y: i16 };
const SmallRect = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const Csbi = extern struct {
    dwSize: Coord,
    dwCursorPosition: Coord,
    wAttributes: u16,
    srWindow: SmallRect,
    dwMaximumWindowSize: Coord,
};

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(h: ?*anyopaque, mode: *u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleMode(h: ?*anyopaque, mode: u32) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleInputW(h: ?*anyopaque, buf: [*]InputRecord, n: u32, read: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleScreenBufferInfo(h: ?*anyopaque, info: *Csbi) callconv(.winapi) i32;

const STD_IN: u32 = 0xFFFFFFF6; // -10
const STD_OUT: u32 = 0xFFFFFFF5; // -11
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;
const ENABLE_VT_OUT: u32 = 0x0004;

fn tuiInit() i64 {
    if (comptime host_os != .windows) return tuiInitPosix();
    const hout = GetStdHandle(STD_OUT);
    const hin = GetStdHandle(STD_IN);
    var om: u32 = 0;
    var im: u32 = 0;
    // not a console -- a pipe, a file -- and that is a 0, not an error
    if (GetConsoleMode(hout, &om) == 0 or GetConsoleMode(hin, &im) == 0) return 0;
    console.out_mode = om;
    console.in_mode = im;
    if (SetConsoleMode(hout, om | ENABLE_VT_OUT) == 0) return 0;
    if (SetConsoleMode(hin, im & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)) == 0) {
        _ = SetConsoleMode(hout, om);
        return 0;
    }
    console.active = true;
    return 1;
}

fn tuiDone() void {
    if (!console.active) return;
    if (comptime host_os != .windows) {
        tuiDonePosix();
    } else {
        _ = SetConsoleMode(GetStdHandle(STD_OUT), console.out_mode);
        _ = SetConsoleMode(GetStdHandle(STD_IN), console.in_mode);
    }
    console.active = false;
}

fn tuiSize() [2]i64 {
    if (comptime host_os != .windows) return .{ 0, 0 };
    var info: Csbi = undefined;
    if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUT), &info) == 0) return .{ 0, 0 };
    return .{
        @as(i64, info.srWindow.Right) - info.srWindow.Left + 1,
        @as(i64, info.srWindow.Bottom) - info.srWindow.Top + 1,
    };
}

fn keyName(vk: u16) ?[]const u8 {
    return switch (vk) {
        0x25 => "<left>",
        0x26 => "<up>",
        0x27 => "<right>",
        0x28 => "<down>",
        0x24 => "<home>",
        0x23 => "<end>",
        0x2E => "<delete>",
        0x21 => "<pageup>",
        0x22 => "<pagedown>",
        0x70 => "<f1>",
        0x71 => "<f2>",
        0x72 => "<f3>",
        0x73 => "<f4>",
        0x74 => "<f5>",
        0x75 => "<f6>",
        0x76 => "<f7>",
        0x77 => "<f8>",
        0x78 => "<f9>",
        0x79 => "<f10>",
        0x7A => "<f11>",
        0x7B => "<f12>",
        else => null,
    };
}

/// One key. Blocks. Returns a slice into `keybuf`, which the caller copies.
const ctrl_names = [_][]const u8{
    "<ctrl-a>", "<ctrl-b>", "<ctrl-c>", "<ctrl-d>", "<ctrl-e>", "<ctrl-f>", "<ctrl-g>",
    "<ctrl-h>", "<ctrl-i>", "<ctrl-j>", "<ctrl-k>", "<ctrl-l>", "<ctrl-m>", "<ctrl-n>",
    "<ctrl-o>", "<ctrl-p>", "<ctrl-q>", "<ctrl-r>", "<ctrl-s>", "<ctrl-t>", "<ctrl-u>",
    "<ctrl-v>", "<ctrl-w>", "<ctrl-x>", "<ctrl-y>", "<ctrl-z>",
};

fn tuiKey() []const u8 {
    if (!console.active) {
        // headless: one byte of stdin, "" at end of input
        const n = std.fs.File.stdin().read(keybuf[0..1]) catch 0;
        return if (n == 0) "" else keybuf[0..1];
    }
    if (comptime host_os != .windows) return tuiKeyPosix();
    const hin = GetStdHandle(STD_IN);
    var rec: [1]InputRecord = undefined;
    var got: u32 = 0;
    while (true) {
        if (ReadConsoleInputW(hin, &rec, 1, &got) == 0 or got == 0) return "";
        const r = rec[0];
        if (r.EventType != 1 or r.Event.bKeyDown == 0) continue;
        const ch = r.Event.UnicodeChar;
        switch (ch) {
            // 13 is Enter; 10 is what Ctrl+Enter delivers on a Windows console.
            // Found live 2026-09-03: it fell through as a one-character key and
            // the editor inserted a raw line feed INSIDE a line.
            13, 10 => return "<enter>",
            27 => return "<esc>",
            9 => return "<tab>",
            8 => return "<backspace>",
            0 => {
                if (keyName(r.Event.wVirtualKeyCode)) |nm| return nm;
                continue; // shift, ctrl, alt on their own
            },
            // Ctrl+letter arrives as 1..26. Named, never text: a program can
            // bind <ctrl-s>, and an editor must never insert it.
            1...7, 11, 12, 14...26 => return ctrl_names[ch - 1],
            // any other control character is nothing a widget can type
            28...31, 127 => continue,
            else => {
                if (ch >= 0xD800 and ch <= 0xDFFF) continue; // half a surrogate pair
                const n = std.unicode.utf8Encode(@intCast(ch), keybuf[0..4]) catch continue;
                return keybuf[0..n];
            },
        }
    }
}

// ---- the POSIX shape, compiled only off Windows and NOT measured here ----
var posix_saved: if (host_os != .windows) std.posix.termios else u8 = undefined;

fn tuiInitPosix() i64 {
    if (comptime host_os == .windows) return 0;
    const t = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return 0;
    posix_saved = t;
    var raw = t;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch return 0;
    console.active = true;
    return 1;
}

fn tuiDonePosix() void {
    if (comptime host_os == .windows) return;
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, posix_saved) catch {};
}

fn tuiKeyPosix() []const u8 {
    if (comptime host_os == .windows) return "";
    const n = std.posix.read(std.posix.STDIN_FILENO, keybuf[0..1]) catch 0;
    if (n == 0) return "";
    return switch (keybuf[0]) {
        13, 10 => "<enter>",
        27 => "<esc>",
        9 => "<tab>",
        127, 8 => "<backspace>",
        else => keybuf[0..1],
    };
}

pub var vm_start_ms: i64 = 0;
/// `tempname()`'s own draw, kept apart from `random()` so making a name
/// never moves the program's random sequence -- Ring's tmpnam does not.
pub var rng = std.Random.DefaultPrng.init(0x5eed5eed);

// random() AND srandom() ARE C's rand() AND srand(), as Ring's are
// (vendor/ring-vm/src/math_e.c:463, :508), and Ring seeds rand() from the
// CLOCK, in seconds, before it runs a program (state.c:532). Ring++ drew
// from Zig's generator under a fixed seed -- chosen 2026-09-02 with 32 other
// builtins and never recorded as a decision -- so every run of every
// program drew the SAME numbers, where Ring draws new ones each second: an
// id or a name made with random() repeated across runs. After srandom(n)
// both draw C's own sequence for n, which is what an oracle can check
// (bench/exec/random_c.ring); on Windows the oracle's C runtime and the
// official build's agree on it.
extern "c" fn rand() c_int;
extern "c" fn srand(seed: c_uint) void;

/// Called once, as the process starts -- Ring's `srand(time(NULL))`.
pub fn seedRandom() void {
    srand(@truncate(@as(u64, @bitCast(std.time.timestamp()))));
}

fn dirExists(p: []const u8) bool {
    var d = std.fs.cwd().openDir(p, .{}) catch return false;
    d.close();
    return true;
}

/// Attribute count per class, for `new`.
pub var class_slots: []u32 = &.{};
/// Per global slot, the name as written (`$c`), so a read of one nothing
/// has assigned can raise Ring's R24 NAMING it. Built by the compiler
/// from its slot table, copied at the freeze, carried by the image.
pub var global_names: []const []const u8 = &.{};

/// Attribute NAME -> slot, per class, for `o.attr` where o's class is not
/// provable at the site -- a receiver that came in as a parameter, or
/// through a global. Ring resolves every property by name at run time;
/// this does it only where the compiler could not do better, and it is a
/// scan over the class's own few attributes, not a table the size of
/// (classes x names). A miss is Ring's R12, with the name.
pub const AttrEnt = struct { name: u16, slot: u32 };
pub var attr_from: []u32 = &.{}; // per class: first index into attr_ent; len ncls + 1
pub var attr_ent: []AttrEnt = &.{};

pub fn attrLookup(cls: u16, name: u32) ?u32 {
    if (cls + 1 >= attr_from.len) return null;
    var i = attr_from[cls];
    const end = attr_from[cls + 1];
    while (i < end) : (i += 1) {
        if (attr_ent[i].name == name) return attr_ent[i].slot;
    }
    return null;
}
/// Constant index of each class's LOWERCASED name, for `clsname`. Built
/// once at compile time so the runtime answer is a table read, not a
/// string build -- Ring lowercases the name too (verified on 1.27:
/// `classname(new Point)` is "point").
pub var class_konst: []u32 = &.{};
/// Per class, its parent's id, 0xFFFF for none; per function id, the class
/// that defines it, 0xFFFF for a plain function. For reflection: `methods`,
/// `ismethod`, `addmethod` (2026-09-23).
pub var class_parent: []u16 = &.{};
pub var fn_owner: []u16 = &.{};
/// Per class, the function id of its attribute prologue, 0xFFFFFFFF for
/// none: `new K` compiled inside eval calls it directly (F-72).
pub var class_attrs_fn: []const u32 = &.{};
/// String constants referenced by `loadk`.
pub var konst: []Value = &.{};
/// How much of `konst`'s buffer is usable: 0 until eval first grows it.
/// The frozen table is exact, so the first eval copies it with headroom.
pub var konst_cap: usize = 0;

/// What `eval` hands the compiler side (rnxc.zig registers the hook; a VM
/// with none raises R3, as before). `caller_fid` is the function whose
/// frame the string runs in, or EVAL_NESTED for an eval inside eval'd code.
pub const EvalHook = *const fn (vm_: *VM, src: []const u8, caller_fid: u32, base: u32, fsp: u32, hsp: u32) Value;
pub const EVAL_NESTED: u32 = 0xFFFFFFFF;

/// The builtin vocabulary, by id.
///
/// One `bcall` opcode dispatching on an id scales to the census's long
/// tail (145 names used across Softanza) without an opcode each. The
/// order here IS the census's frequency order, so the hottest names sit
/// together at the front of the switch.
pub const Builtin = enum(u16) {
    // strings
    char, // char(n)          -> one-character string
    lower,
    upper,
    trim,
    left, // left(s, n)
    right, // right(s, n)
    copystr, // copy(s, n)    -> s repeated n times
    // numbers
    fabs,
    max,
    min,
    number, // number(x)      -> numeric value of a string
    sysargv, // the process arguments as Ring lists them: [exe, script, args...]
    // type predicates: islist(x) isstring(x) isnumber(x) -> 1 or 0. Any
    // argument is legal, so they take no string pre-check.
    islist,
    isstring,
    isnumber,
    isnull, // isNull(x)     -> 1 for "" and for the string "NULL" in any case, else 0 (probed on 1.27: 0, [], an object are 0)
    string, // string(x)      -> decimal text of a number
    typeof, // type(x)        -> NUMBER / STRING / LIST / OBJECT, as Ring names them
    decimals, // decimals(n)  -> sets g_decimals; R33 outside 0..90
    // The plain builtins the estate calls (censused 2026-09-11: 81 names
    // absent at 1,666 sites), each measured on 1.27 (bench/exec/builtins2.ring).
    find2, // find(list, v)        -> 1-based index or 0; STRICT type (find(a, "20") is 0)
    find3, // find(list, v, col)   -> the same, comparing each row's column
    sort1, // sort(list)           -> a NEW sorted list (numbers by value, strings by bytes)
    sort2, // sort(list, col)      -> the same, by a column
    reverse, // reverse(x)         -> a new reversed list, or a reversed string
    isobject, // isobject(x)
    ispointer, // ispointer(x) -- TRUE only for a loaded library, as Ring
    isalpha, // isalpha(s)         -> every byte a letter, and s not empty
    islower, // islower(s)
    isupper, // isupper(s)
    isalnum, // isalnum(s)
    isdigit, // isdigit(s)
    hex, // hex(n)                 -> lowercase, no prefix (hex(255) is "ff")
    dec, // dec(s)                 -> the number a hex string names, either case
    filename, // filename()        -> the script as it was given
    syssleep, // syssleep(ms)      -> sleeps that many MILLISECONDS (measured: 300 -> 304 ms)
    removefile, // remove(cFile)   -> DELETES a file; "" always, even when absent
    attributes, // attributes(o)   -> the object's attribute names, lowercased, parent first
    ascii, // ascii(x)        -> byte of a 1-char string, or x if already one
    ceil,
    floor,
    sqrt,
    strcmp, // strcmp(a, b)    -> -1 / 0 / 1, case-SENSITIVE (ASCII order)
    // substr wears four signatures. §5.1 calls that role-punning and it
    // is; reproduced exactly here because 300K lines depend on it, and
    // the checker gets the rule that names ambiguous call sites.
    substr2, // substr(s, n)          -> the suffix from position n, "" past the end
    substr3, // substr(s, n, len) OR substr(s, find, replace) -- BY TYPE
    substr4, // substr(s, find, repl) -- the explicit 3-arg replace
    // files. `read` on a missing file is R35 in Ring, so it traps here
    // rather than returning "" -- a silent empty file is the worse of
    // the two failures.
    fexists, // fexists(path) -> 1 / 0
    readf, // read(path)     -> contents
    writef, // write(path, s) -> ""
    loadlib, // LoadLib(path) -> 1 / 0, and registers the engine's functions
    // ---- what RUNNING Softanza actually asked for -------------------
    // Not chosen from Ring's manual: chosen by counting the calls
    // Softanza makes to builtins this VM lacks, after discarding the 60
    // names it defines itself (those resolve to its own code, not here).
    // clock 391, clockspersecond 177, sin 104, direxists 99, currentdir
    // 93, pow 57, cos 53, random 36, str2list 23, log10 15.
    // Every one measured against 1.27 before it was written.
    clock, // clock()            -> milliseconds; clockspersecond() is 1000
    clockspersecond,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    atan2, // atan2(y, x)
    sinh,
    cosh,
    tanh,
    log, // natural log
    log10,
    exp,
    pow, // pow(x, y)
    direxists, // direxists(path)    -> 1 / 0
    currentdir, // currentdir()       -> the working directory
    exefolder,
    random, // random(n)          -> 0..n INCLUSIVE, verified on 1.27
    random0, // random()          -> rand() itself
    srandom, // srandom(seed)      -> reseeds, returns nothing useful
    nothing, // nothing()          -> a NUMBER (0), not a null
    str2list, // str2list(s)        -> split on newline
    version, // version()          -> "1.27"
    bye, // `bye` -- end the program here, as Ring does
    // Platform flags. Read off the BUILD TARGET, not hardcoded, so a
    // Linux build answers as a Linux Ring does. On 1.27 here: iswindows
    // and iswindows64 are 1, every other one is 0.
    iswindows,
    iswindows64,
    islinux,
    ismacosx,
    isfreebsd,
    isunix,
    isandroid,
    ismsdos,
    // The console primitives -- contract gate 3, measured before they were
    // written. See the block above `tuiInit`.
    tui_init,
    tui_key,
    tui_size,
    tui_done,
    // The browser primitives -- contract 5.1's socket. See src/web.zig for
    // why `web_wait` hands back the WHOLE form rather than one event.
    web_serve,
    web_wait,
    web_done,
    web_bye,
    // `give x`: one line of stdin, without its newline; "" at end of input.
    giveline,
    // The system builtins Softanza calls and Ring++ lacked -- found by
    // `rnxc census --natives` on 2026-09-23, each measured on 1.27
    // (bench/exec/sys_builtins.ring, 35 rows, official build and oracle
    // agreeing). The time ones call the C runtime Ring itself calls.
    dir, // dir(path)            -> [[name, isFolder], ...], "." and ".." left out
    date, // date()              -> "dd/mm/yyyy", local time
    time, // time()              -> "hh:mm:ss"
    timelist, // timelist()      -> 21 strftime fields, Ring's order
    adddays, // adddays(d, n)    -> "dd/mm/yyyy", Ring's own day arithmetic
    diffdays, // diffdays(a, b)  -> days from b to a, through mktime
    sysget, // sysget(name)      -> the variable, or ""
    sysset, // sysset(n, v)      -> 1 / 0
    sysunset, // sysunset(n)     -> 1 / 0
    tempname, // tempname()      -> a fresh path in the temp folder
    chdir, // chdir(path)        -> 0, or -1
    exefilename, // exefilename() -> this executable's full path
    getpathtype, // getpathtype(p) -> 0 none, 1 file, 2 folder
    windowsnl, // windowsnl()    -> CR LF
    system, // system(cmd)       -> the command's exit status
    rename, // rename(a, b)      -> 0, or -1 (and -1 when b exists, as C's does)
    // Ring's C-style file functions over C's own stdio (bench/exec/file_stdio.ring).
    // A handle is a `cptr` of kind "file"; a NULL one raises Ring's
    // "Error in parameter, NULL pointer!".
    fopen, // fopen(path, mode)   -> a file pointer, NULL if it cannot open
    fclose, // fclose(fp)         -> 0, and the pointer is NULL after
    fflush, // fflush(fp)
    fwrite, // fwrite(fp, s)      -> bytes written
    fread, // fread(fp, n)        -> up to n bytes, or the NUMBER 0 at the end
    fgetc, // fgetc(fp)           -> one character, or the NUMBER -1 at the end
    fputc, // fputc(fp, c)        -> 1 / 0
    fputs, // fputs(fp, s)        -> 1 / 0
    fgets, // fgets(fp, n)        -> a line with its newline, or the NUMBER 0
    fseek, // fseek(fp, off, whence) -> 0 / non-zero
    ftell, // ftell(fp)
    rewind, // rewind(fp)
    feof, // feof(fp)
    ferror, // ferror(fp)
    clearerr, // clearerr(fp)
    ungetc, // ungetc(fp, c)      -> 1 / 0
    tempfile, // tempfile()       -> a file pointer on a fresh temporary file
    freopen, // freopen(path, mode, fp)
    perror, // perror(s)          -> the C error text, on stderr
    fgetpos, // fgetpos(fp)       -> a pointer of kind "filepos"
    fsetpos, // fsetpos(fp, pos)
    // The small conversions (bench/exec/conv_builtins.ring, 36 rows).
    isspace, // C's tests, every byte, "" is 0 -- as isalpha
    isgraph,
    ispunct,
    iscntrl,
    isprint,
    isxdigit,
    hex2str, // hex2str("4142")   -> "AB"; odd length and a non-hex digit raise
    list2str1, // list2str(l)     -> the items joined by newlines
    list2str2, // list2str(l, from)
    list2str3, // list2str(l, from, to)
    assert, // assert(x)          -> R48 when x is 0, "", [] or a NULL pointer
    int2bytes, // int2bytes(n)    -> 4 bytes, a C int
    bytes2int,
    float2bytes, // 4 bytes, a C float
    bytes2float,
    double2bytes, // 8 bytes, a C double
    bytes2double,
    unsigned2, // unsigned(n, "~")
    unsigned3, // unsigned(a, b, op) -- 64-bit unsigned arithmetic
    list1, // list(n) / newlist(n) -> n zeros; n < 1 is a RANGE error, as Ring's
    list2d, // list(r, c) / newlist(r, c) -> r lists of c zeros
    // Reflection (bench/exec/reflect.ring), over the tables the VM carries.
    ismethod, // ismethod(o, name) -> 1 / 0, any case, inherited included
    isfunction, // isfunction(name) -> a USER function, not a builtin
    methods, // methods(o)        -> own methods in definition order, then the parent's
    getattribute, // getattribute(o, name) -> the value, or R12
    setattribute, // setattribute(o, name, v)
    isattribute, // isattribute(o, name)
    functions, // functions()     -> the user functions, lower-cased
    classes, // classes()         -> the classes, lower-cased
    globals, // globals()         -> the global names
    prevfilename, // prevfilename() -> the caller's file
    packages, // packages()       -> the package names
    addattribute, // addattribute(o, name | [names]) -> THIS object only
    addmethod, // addmethod(o, name, fn) -> the whole CLASS; a method name does nothing
    refv, // ref(x) / reference(x) -> x itself; `y = ref(x)` is not copied
    refcount, // refcount(x)
    catchlast, // cCatchError read outside a catch body: the last error caught anywhere
    eval, // eval(code): the string compiled at run time in the CALLER's frame (F-72)
    find4, // find(list, v, col, cAttr) -> a list of OBJECTS searched on one attribute
    // Ring's second spellings (list_e.c registers `newlist` and `reference`
    // beside `list` and `ref`): the same code, an id of their own only so an
    // error raised inside one is reported by the name it was called with,
    // `In reference()` (F-102).
    newlist1,
    newlist2d,
    reference,
};

/// The name Ring gives a builtin's C frame in an error report -- `In
/// find()` (VM.cfnAt) -- which is the name it was called by, lower-cased.
/// null for what is no C function on Ring: a variable read (sysargv,
/// cCatchError), a statement (bye, give), and eval, whose code runs after
/// the C function has returned and so shows no frame (F-102). `newlist` and
/// `reference` have ids of their own for exactly this.
pub fn builtinRingName(b: Builtin) ?[]const u8 {
    return switch (b) {
        .sysargv, .catchlast, .bye, .giveline, .eval => null,
        .copystr => "copy",
        .typeof => "type",
        .find2, .find3, .find4 => "find",
        .sort1, .sort2 => "sort",
        .removefile => "remove",
        .substr2, .substr3, .substr4 => "substr",
        .readf => "read",
        .writef => "write",
        .random0 => "random",
        .list2str1, .list2str2, .list2str3 => "list2str",
        .unsigned2, .unsigned3 => "unsigned",
        .list1, .list2d => "list",
        .newlist1, .newlist2d => "newlist",
        .refv => "ref",
        .reference => "reference",
        else => @tagName(b),
    };
}

/// Internal dispatch targets. The compiler never emits these; they exist so
/// a check deep inside an opcode can hand control to one shared handler
/// instead of repeating the unwind. `continue :dispatch .raise` is the goto
/// Zig does not otherwise have.
pub const RAISE: Op = .raise;

// `rc` is dead weight in the non-RC builds — kept in the struct so the two
// builds have identical object layout and the A/B measures the refcount
// TRAFFIC, not a change in cache footprint.
/// `cap` is the size of the buffer `ptr` owns, when this string allocated one
/// with room to spare. Zero means "the buffer is exactly len bytes, or is not
/// ours at all" -- which is every constant, since those point into the source
/// text. Only the self-append path below ever sets it, so a constant can
/// never be grown in place.
pub const Str = struct { ptr: [*]const u8, len: u32, rc: u32 = 0, cap: u32 = 0 };

/// A CONSTANT IS PINNED, not merely expected to balance. The free path says
/// a constant "never reaches zero and this line never sees it" -- which was
/// an invariant nothing checked, and one unbalanced release broke it. On the
/// WARM path that is not even a free of an allocation: every constant's
/// bytes point INTO one shared blob, so it hands the allocator an interior
/// pointer, and the process then spins for ever inside exit. Cold, the same
/// release frees a real buffer and nothing shows.
///
/// So constants start here instead of at 1. Retain and release still pair
/// normally; the count simply cannot walk to zero, which makes the free
/// path's comment true by construction. An imbalance is a leak now, not a
/// corrupted heap. `rc == 1` reads false for a constant, which is the right
/// answer for the in-place append too -- a literal must never be grown
/// through, and `cap == 0` already said so.
pub const konst_rc: u32 = 1 << 30;
pub const Vec = struct {
    ptr: [*]Value,
    len: u32,
    cap: u32,
    rc: u32 = 0,
    /// The deferred sweep's mark; it only ever holds 0 or 1, so u16 makes
    /// room for `closure` in the same 32-byte header.
    mark: u16 = 0,
    /// THIS VECTOR IS A LAMBDA -- `[func_id + closure_bias, captures...]`,
    /// set by `vnew` with b = 1 at the closure build and carried by every
    /// copy. On Ring a lambda IS a string, "_ring_anonymous_func_NNN", and
    /// the estate's guards are written that way: `isString(f) and
    /// isFunction(f)` (stzReactiveObject.Watch). So to `type()`, `isString`,
    /// `isList` and `isFunction` a closure answers as Ring's lambda does --
    /// STRING, 1, 0, 1 -- while its list shape stays for `calli`. A flag,
    /// not the biased id alone: a list of epoch seconds starts with an
    /// integer above 2^30 too, and would have read as a lambda.
    closure: bool = false,
    /// RING'S REFERENCE (Ring 1.21's `ref()`), F-118. 0: none. 1: set by
    /// `ref()`/`reference()` -- every copy SHARES this vector instead of
    /// cloning it (an assignment, a list literal's item, `+`, add(), an
    /// indexed store, a sublist of a list being copied: Ring's
    /// `ring_list_isref_gc` test at each of its copy sites, vmstack.c:252,
    /// vmlists.c:103/120/404/530, vmexpr.c:1226, vmfuncs.c:628) while it has
    /// a second NAMED holder; with one left an assignment copies again and
    /// the state drops to 0 (`copyv`, `release`). 2: PINNED -- shared for
    /// good, which is what Ring does to a reference that went through `+`
    /// inside a list literal (`aL + ["k", ref(o)]`: its count is left one
    /// high, measured on both builds, and Softanza's stkMemory relies on
    /// exactly that shape). In the header's spare byte: still 32 bytes.
    rref: u8 = 0,
    /// The map type's index, when this vector is used as a hash list.
    /// Null for every plain list; 8 bytes of header for all of them, and
    /// the slots only for the ones that are keyed. See HIndex.
    idx: ?*HIndex = null,
};

/// The map type (charter §6 item 7), built the way the charter requires:
/// the hash list STAYS a vector of [key, value] pairs, so `m[i][1]` and
/// `m[i][2]` keep working for the 3,429 sites that read pairs by position,
/// and keyed lookup gains an index beside it rather than a new shape.
///
/// Open addressing on a case-insensitive hash of the key. Each slot holds
/// the pair's POSITION + 1 (0 = empty), so the index is 4 bytes per slot
/// at half load -- about 8 bytes per entry. Built lazily on the first
/// keyed lookup past HINDEX_MIN pairs (a linear scan wins below that),
/// grown by rebuilding, and DROPPED by any positional mutation that can
/// move a pair (vdel, positional vset); an appended pair is added in
/// place. A copy-on-write clone starts without one.
///
/// Read-never-writes is unchanged: a missing key yields "" and the list is
/// left alone -- the registered divergence from Ring, which inserts.
pub const HIndex = struct { slots: []u32, count: u32 };
pub const HINDEX_MIN: u32 = 8;

/// FNV-1a over the LOWERED bytes. Ring's key compare is case-insensitive
/// -- `aH["Name"]` finds the key stored as "name" -- so the hash is too.
fn keyHash(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |c| {
        h ^= std.ascii.toLower(c);
        h *%= 0x100000001b3;
    }
    return h;
}

pub const Value = extern struct {
    p: extern union { i: i64, d: f64, s: *Str, v: *Vec, o: *Obj },
    tag: Tag,
    _r: u32 = 0,

    pub inline fn int(x: i64) Value {
        return .{ .p = .{ .i = x }, .tag = .int };
    }
    /// Ring has exactly one number type and it is a double (§4.5), so
    /// every decimal literal becomes one of these. Integers keep the .int
    /// tag: the arithmetic opcodes have a fast path for them.
    pub inline fn num(x: f64) Value {
        return .{ .p = .{ .d = x }, .tag = .num };
    }
    pub inline fn nil() Value {
        return .{ .p = .{ .i = 0 }, .tag = .nil };
    }
    pub inline fn vec(v: *Vec) Value {
        return .{ .p = .{ .v = v }, .tag = .vec };
    }
    pub inline fn str(s: *Str) Value {
        return .{ .p = .{ .s = s }, .tag = .str };
    }
    pub inline fn object(o: *Obj) Value {
        return .{ .p = .{ .o = o }, .tag = .obj };
    }
    /// A loaded native library. The payload is a serial, not an OS handle:
    /// nothing in Ring or in the estate reads it -- `isPointer` and
    /// `!= NULL` are the whole of what a program may ask.
    pub inline fn dllh(id: i64) Value {
        return .{ .p = .{ .i = id }, .tag = .dll };
    }
    pub inline fn cptrh(id: i64) Value {
        return .{ .p = .{ .i = id }, .tag = .cptr };
    }
};

/// One of Ring's C pointers: the pointer, NULL once closed, and its kind.
pub const CPtr = struct { ptr: ?*anyopaque, kind: []const u8 };
/// Every C pointer the program has made. An entry is never reused, so a
/// stale handle can only ever find its own pointer, NULL after fclose. A
/// FILE* is NOT closed when the last value naming it goes, as Ring's
/// managed pointer would be; Softanza closes what it opens, and the C
/// runtime flushes every open stream at exit.
pub var cptr_tab: std.ArrayListUnmanaged(CPtr) = .{};

/// The index of an added attribute's VALUE in `o.extra`, any case, or null.
fn extraAt(o: *Obj, name: []const u8) ?u32 {
    const ex = o.extra orelse return null;
    var i: u32 = 0;
    while (i + 1 < ex.len) : (i += 2) {
        const k = ex.ptr[i];
        if (k.tag == .str and std.ascii.eqlIgnoreCase(k.p.s.ptr[0..k.p.s.len], name)) return i + 1;
    }
    return null;
}

fn cptrOf(v: Value) ?*anyopaque {
    if (v.tag != .cptr or v.p.i < 0 or v.p.i >= cptr_tab.items.len) return null;
    return cptr_tab.items[@intCast(v.p.i)].ptr;
}

comptime {
    if (@sizeOf(Value) != 16) @compileError("Value must be 16 bytes");
}

// ------------------------------------------------------------ bytecode

pub const Op = enum(u8) {
    halt, // return r[a]
    loadi, // r[a] = d
    move, // r[a] = r[b]
    add, // r[a] = r[b] + r[c]
    sub,
    mul,
    mod, // floor-mod (operands non-negative here)
    // Ring's `/` is real division even on two integers: 3/2 is 1.50,
    // verified on 1.27. There is no integer division operator.
    div,
    idiv, // floor division
    addi, // r[a] = r[b] + d
    muli,
    modi,
    idivi,
    jmp, // pc = d
    jlt, // if r[a] <  r[b] -> pc = d
    jle,
    jgt,
    jge,
    jeq,
    jne,
    jeqi, // if r[a] == c (u8 imm) -> pc = d
    jnei,
    jgti,
    forprep, // loop entry: r[b] made an int bound when r[a] is int; r[a] -= step (r[c] when d != 0, else 1)
    forloop, // r[a] += 1;    if r[a] <= r[b] -> pc = d
    forloops, // r[a] += r[c]; if r[a] <= r[b] -> pc = d
    vnew, // r[a] = new vec
    vpush, // push r[b] onto vec r[a]
    vget, // r[a] = r[b][r[c]]   (1-based, bounds-checked)
    vset, // r[a][r[b]] = r[c]
    vlen, // r[a] = #r[b]
    sgetb, // r[a] = byte(r[b], r[c])  (1-based) -- what `ascii(s[i])` compiles to
    sgets, // r[a] = one-character STRING r[b][r[c]] -- what `s[i]` is on Ring (F-54, C-3)
    slen, // r[a] = #r[b]  (string)
    call, // window a, entry d
    ret, // result r[a]
    // Dynamic get/len: dispatch on the tag because the front end cannot yet
    // prove whether a value is a vector or a string. Hand-written programs
    // keep using vget/vlen, so adding these does not perturb any earlier
    // measurement. Specialising them where inference DOES know the type is
    // the next win, and is exactly the lever the RC work already identified.
    dget, // r[a] = r[b][r[c]]  -- vector element, or string BYTE
    dlen, // r[a] = #r[b]       -- vector length, or string length
    // Get-for-WRITE: the interior step of `a[i][j] = v`.
    //
    // Under copy-on-write a plain read cannot be used to reach a nested
    // container, because writing through the value it returns would land in
    // a private clone and vanish. This makes the path private on the way
    // down -- the container first, then the element -- and hands back a
    // BORROW: the register points at the element without counting it, so
    // the following vset still sees rc == 1 and mutates in place.
    vgetw, // r[a] = &r[b][r[c]], both levels made private first
    // A builtin call: r[a] = builtin_d(r[b] .. r[b+c-1]).
    bcall,
    // Ring truth: 0, "" and [] are false; objects are true.
    jfalsy, // if !truthy(r[a]) -> pc = d
    jtruthy, // if  truthy(r[a]) -> pc = d
    truth, // r[a] = truthy(r[b]) ? 1 : 0
    lnot, // r[a] = truthy(r[b]) ? 0 : 1
    // `? x` -- Ring prints a scalar and a newline, and a list one element
    // per line (verified: `? [1,2]` emits "1\n2\n").
    say,
    // `a : b` -- an inclusive integer range as a list.
    range,
    // Ring's hash list is a list of two-element lists, and `aH[:key]` is a
    // LINEAR scan of it with a case-insensitive key compare. These keep
    // that identity -- `aH[1][1]` must still be the first key -- and stay
    // off the integer path, which is the hot one.
    hget, // r[a] = value of key r[c] in vec r[b], or "" when absent
    hset, // key r[b] in vec r[a] = r[c], appending a pair when absent
    // del(list, n) MUTATES its first argument, so it takes the container's
    // register rather than a copied value.
    vdel, // remove item r[b] (1-based) from vec r[a]
    // substr(s, needle) -- the FIND role, whose answer is a position, or
    // 0 for a miss. §5's "0 with three meanings" lives here.
    sfind, // r[a] = 1-based position of r[c] in r[b], or 0

    // ---- the object model -------------------------------------------
    loadk, // r[a] = konst[d]              -- string constants
    newobj, // r[a] = new object of class d, all slots nil
    gattr, // r[a] = obj(r[b]).slots[d]    -- slot resolved at COMPILE time
    sattr, // obj(r[a]).slots[d] = r[b]
    callm, // window a, argc b, name index d; receiver in r[window]
    // A call to a name this unit does not define -- an engine function,
    // registered at RUNTIME by LoadLib. Ring resolves these names at
    // runtime too, so this is faithful rather than lenient; what Ring++
    // adds is that the checker can list every unresolved one before the
    // program runs.
    ncall, // r[a] = native_d(r[b] .. r[b+c-1])
    // try/catch. `ptry` arms a handler whose catch block is at d and
    // whose error binding is register a (frame-relative); `pend` disarms
    // it at the end of the try body.
    ptry,
    pend,
    // Call a CLOSURE: r[a] holds [func_id, captures...], the arguments
    // sit at r[a+1 .. a+b], and the callee gets the closure in its r0.
    calli,
    // `$x` -- Ring's explicit global. One slot per name, resolved to an
    // INDEX at compile time, so a global read is a load rather than the
    // name search Ring performs (§4.6).
    gget, // r[a] = globals[d]
    gset, // globals[d] = r[a]
    // A global read IN A CLASS BODY (the attribute prologue): the global
    // when it is set, otherwise Ring's class-region rule (F-70) -- the
    // object GAINS an attribute of that name holding NULL, and that is the
    // value. c = 0: d is the global's slot; c = 1: no slot exists, d is the
    // name's index.
    ggeta,
    // raise(msg) / StzRaise(msg): stop, with the message in r[a].
    // A REGISTER, not a constant: Softanza builds its messages, and the
    // constant form could only carry a literal, so every computed message
    // was being replaced by the word "raised".
    // try/catch is a separate item; until it lands, this is the untried
    // behaviour, which is what Ring does when nothing catches.
    trap,
    istag, // r[a] = (tag(r[b]) == d) -- isString / isObject / isList
    // Get an ATTRIBUTE for writing. Same reasoning as vgetw one level over:
    // `add(@aSeen, x)` must not read the attribute into a temporary first,
    // because that makes rc 2 and copy-on-write then sends the append into a
    // clone that is thrown away. Makes the slot's value private, hands back
    // a borrow.
    gattrw, // r[a] = &obj(r[b]).slots[d]
    // A global borrowed for WRITING, same reasoning as gattrw one level
    // out: reading it would take a reference, and the next write would
    // then copy-on-write the container and throw the assignment away.
    ggetw, // r[a] = &globals[d]
    // `classname(o)` where the receiver's class was NOT proved at compile
    // time -- which the poison ranking says is the single biggest blocker
    // in Softanza, 60 roots holding 5,508 functions.
    //
    // r[a] = the lowercased class name of the object in r[b], read from
    // the constant table through `class_konst`, so no allocation and no
    // refcount traffic. `d` is the constant index of Ring's own message
    // for the non-object case, which this RAISES rather than answers:
    // measured on 1.27, classname(42) is "Bad parameter type!", not "".
    clsname,
    // `substr(s, x)` with two arguments, where x's type is not knowable
    // at compile time. r[a] = find-or-suffix, decided by r[c]'s TYPE at
    // run time -- exactly as `substr3` already decides its own role.
    // `d` is the constant index of Ring's message for a type that is
    // neither a string nor a number.
    //
    // Measured on 1.27: substr(s, "3") is a FIND returning 0, NOT the
    // suffix from position 3. The decision is the value's type, never
    // whether it happens to look numeric.
    substr2d,
    // Never emitted. A check inside any opcode sets `pending` and does
    // `continue :dispatch .raise` to reach the one unwind, instead of a
    // sixth hand-written copy of it.
    raise,
    // Never emitted either: an arithmetic, comparison or subscript opcode
    // that met an OBJECT operand fills `pend_op` and continues here, which
    // calls the class's `operator(cOp, x)` and lands the result where the
    // opcode would have put its own (F-69, bench/exec/operator.ring).
    opcall,
    // A comparison as a VALUE where an operand may be an object: r[a] =
    // r[b] OP r[c], OP by d (0 `=`, 1 `!=`, 2 `<`, 3 `<=`, 4 `>`, 5 `>=`).
    // 1 or 0 for plain values; for an object on the left, the operator's
    // OWN answer -- `Show(o = 10)` prints the string the method returned
    // on Ring. The fused jumps stay the path when no operand can be one.
    cmpv,
    // `isGlobal(:$name)` -- 1 if that global has been ASSIGNED by the time
    // this runs, 0 otherwise. `d` is the global's slot.
    //
    // It has to be assignment and not "is the slot non-nil", because
    // measured on 1.27 `$x = NULL` still answers 1: the global exists even
    // when its value is nothing. Softanza's three call sites are all
    // initialise-once guards, so answering from the slot's VALUE would
    // re-initialise a global someone had deliberately set to NULL.
    isglob,
    // Bitwise, on the number truncated to i64 -- Ring's own reading,
    // probed on the oracle 2026-09-08: `2.5 & 1` is 0, `"6" & 3` is 2,
    // `1 << 32` is 4294967296, `-1 >> 1` is -1 (arithmetic), `~5` is -6.
    // Softanza has ~22 sites (TOTP, OIDC, passkeys, UUID variants, UTF-8
    // lead bytes) and not one compiled before these existed.
    band, // r[a] = r[b] & r[c]
    bor,
    bxor,
    shl, // r[a] = r[b] << (r[c] & 63)
    shr, // arithmetic
    // `o.attr` by NAME, resolved at run time from the object's class --
    // the path taken when the compiler could not prove the class at the
    // site. R12 with the name on a miss, as Ring.
    gattrn, // r[a] = r[b].names[d]
    sattrn, // r[a].names[d] = r[b]
    // Ring's assignment: a list or an object is COPIED, deeply, at every
    // transfer into a variable, an attribute, an element, a literal or a
    // return -- and passed by REFERENCE to a parameter and as `this`.
    // Emitted by the compiler after a read out of a variable-like place
    // at a store site; a scalar or a string passes through untouched.
    // Measured on 1.27, both builds, 2026-09-10 (bench/exec/copy.ring).
    copyv, // r[a] = deep copy of r[a] when it is a list or an object (C-7)
    vins, // insert(list, n, item): r[c] goes into r[a] AFTER position r[b] (0 = first)
    iget, // r[a] = r[b][r[c]] for `for x in`: a list element BY REFERENCE, a string's one-char string
    vsetq, // r[a][r[b]] = r[c] when r[a] is a list and r[b] in range, else nothing: for-in's write-back
    /// Ring raises R24 when an uninitialised variable is READ -- `? NOTSET`
    /// alone is enough, probed on 1.27 -- and names it, folded to lower
    /// case. A top-level bare name assigned nowhere compiles to this, so
    /// the statements before it run and the program stops exactly where
    /// Ring stops. d = index into the name table.
    r24,
    /// `nl`, `tab` and `cr` are Ring's predefined character constants, and an
    /// ASSIGNMENT SHADOWS THEM -- but only from the assignment onwards, so it
    /// is a RUNTIME question, not a compile-time one. The constant is loaded
    /// first and this overwrites it when the global has actually been set.
    /// d = the global slot.
    gorc,
    /// `callm` that is allowed to MISS: if the receiver is not an object,
    /// or its class has no such method, it does nothing and falls through.
    /// Ring's brace hooks are exactly this -- its parser emits
    /// `if ismethod(self,"braceend") braceend() ok` around every object
    /// brace (src/expr.c:1033) -- and most classes have no hook at all.
    callmq,
    /// `callmq` for a BARE CALL INSIDE `obj { ... }` whose receiver's class
    /// is not known at compile time: the object's method if it has one, else
    /// the global FUNCTION of that name -- Ring's rule, measured (a class
    /// without `Then` inside `StzLocaleQ(...) { Then(...) }` reaches the
    /// harness's global Then). On a miss it SKIPS the instruction after it,
    /// which the compiler makes the hit path's jump over the fallback.
    callmf,
    /// A NATIVE'S NAME, looked up where Ring looks it up: when the call
    /// STARTS, before its arguments (F-87). `Nope(Say("x"))` raises R3 and
    /// never says x on both 1.27 builds, on the callee's line where the
    /// arguments span several. A hit is cached per name index, so the
    /// `ncall` after it reads one slot where it scanned the registered
    /// names in order -- 2,495 in the engine's census of 2026-09-09.
    nchk,
    /// A LOCAL read that the compiler could not prove assigned on every
    /// path to it: R24 naming it (d, a name index) if the register still
    /// holds nil. Ring raises R24 the moment an unassigned variable is read
    /// (F-89); a register is nil here only when nothing has assigned it,
    /// because `nilr` clears exactly these locals when the function starts.
    chkl,
    /// Store nil in r[a] WITHOUT releasing what was there: run once at the
    /// entry of a function that has a `chkl`, on the locals it checks.
    /// Those registers belong to no live frame -- the previous frame's
    /// `ret` released every boxed value it held, and an unboxed one holds
    /// no reference -- so a release here would be a second release.
    nilr,
    /// A NAME AN EVAL MADE AT RUN TIME (F-107). Ring's eval creates a
    /// variable in the frame it runs in -- `eval(cName + " = 7")` then
    /// `eval("? " + cName)` prints 7, and the function's own code can read
    /// it -- and at the top level a GLOBAL every function can read. Such a
    /// name exists nowhere in the program text, so it has no register, no
    /// slot and often no name index: it lives in VM.dyn, keyed by the frame
    /// depth (0 = the globals). d = a string constant, the name.
    ///   dvget  r[a] = the name -- this frame's, then a global; R24 naming it
    ///          otherwise. c & 1: in a method, an attribute the object gained
    ///          (addattribute, F-70) first, as `r24` does.
    ///   dvset  the name = r[a], in this frame -- or, c = 1, as a GLOBAL
    ///          (depth 0): an eval whose caller is the top level, which runs
    ///          one frame down, under the entry trampoline's call
    ///   dvclr  at the entry of a function holding an eval: a fresh scope --
    ///          every name made at this depth or deeper is dropped, and the
    ///          registers r[a .. a+b) (its locals) are nil without a release,
    ///          as `nilr` leaves them, so a read before any eval is R24.
    dvget,
    dvset,
    dvclr,
    /// THE LINE RING CARRIES PAST AN `ok` (F-110). Ring's line is the last
    /// NEWLINE instruction it ran, and a newline that follows another is
    /// MERGED into it (codegen.c:134) -- so the marker of the first statement
    /// after `if ... else ... ok` is the else body's own last marker, and the
    /// end-jump of every earlier branch lands PAST it. Reached that way, the
    /// statement reports the line of the `else`/`but` that ended the branch
    /// (both 1.27 builds, bench/exec/else_line.ring). Ring++'s lines are a
    /// static table, so the path is recorded where Ring's would differ:
    ///   jmpl   pc = d, after noting for this frame depth that pcs in
    ///          [d, code[pc+1].d) report line a | b<<8 | c<<16 (0: none --
    ///          the else body's end, which must clear what an earlier pass
    ///          through a branch left)
    ///   lnhi   the data word after a jmpl, never run: d = the region's end
    jmpl,
    lnhi,
    // UNCHECKED TWINS (2026-10-15): the same handlers, for an instruction whose destination is one of its own
    // operands, so the value a fast path overwrites is the operand it has just tested numeric and the store skips
    // the release check F-118 put on every unboxed store. Chosen per instruction by the compiler (emitOne), never
    // written by hand; the slow paths store through the checked path in both.
    add_u, sub_u, mul_u, addi_u, muli_u, modi_u, idivi_u,
};

/// What `jmpl` recorded, per frame depth: the line a report gives for a pc
/// in [lo, hi). Static memory: one VM per process, and a depth past the end
/// (deeper than Ring's own R4 limit) records nothing.
pub const LnOvr = struct { line: u32 = 0, lo: u32 = 0, hi: u32 = 0, srow: u32 = 0 };
pub var g_ln_ovr: [1100]LnOvr = [_]LnOvr{.{}} ** 1100;

pub const Instr = extern struct { op: Op, a: u8, b: u8, c: u8, d: i32 };

/// A CLOSURE is `[func_id, captured...]`, and a Ring list is a list -- so
/// without this the two are the same shape and `call aList()` reaches
/// `fn_entry[aList[1]]`, calling whatever function that happens to be.
///
/// On RING they are never confused, because a Ring lambda is a STRING (its
/// generated name) and a list is always `Error (R32) : The CALL command
/// expect a variable contains string`. Ours is a list, so the id is stored
/// BIASED and `calli` refuses anything that is not -- which gets R32 to the
/// same programs Ring gives it to.
///
/// 2^30: it fits `Instr.d` (an i32) beside any real function id, and a data
/// list whose first element lands in [2^30, 2^30 + functions) is not a
/// thing a program writes by accident.
pub const closure_bias: i64 = 1 << 30;


comptime {
    if (@sizeOf(Instr) != 8) @compileError("Instr must be 8 bytes");
}

// ------------------------------------------------------------------ vm

/// `full` -- this callee has no entry in the 64-slot mask table (its id is
/// past the end), so its return sweeps the WHOLE frame instead of a mask.
/// Sweeping nothing, which is what a missing mask used to mean, left every
/// register of every call in a real program unreleased.
/// A PROGRAM'S OUTPUT GOES TO STDOUT, as Ring's does -- `?`, `see`, and
/// the runtime error report alike. It went through outPrint, which
/// is stderr, until 2026-09-12; at a terminal that looks identical, and it
/// breaks every caller that CAPTURES the output. Softanza's load driver
/// spawns children that print `DUR: ...` and folds their stdout: it folded
/// zero on every run, so throughput read 0 req/s.
///
/// Buffered, so `?` in a loop is not a syscall per line, and flushed before
/// every exit -- an unflushed buffer on the error path loses the report,
/// which is the one line that must never be lost.
var out_buf: [64 * 1024]u8 = undefined;
var out_fw: ?std.fs.File.Writer = null;

pub fn outw() *std.Io.Writer {
    if (out_fw == null) out_fw = std.fs.File.stdout().writer(&out_buf);
    return &out_fw.?.interface;
}

pub fn outPrint(comptime fmt: []const u8, args: anytype) void {
    outw().print(fmt, args) catch {};
}

pub fn outFlush() void {
    if (out_fw != null) out_fw.?.interface.flush() catch {};
}

/// A CRASH MUST NOT SWALLOW THE PROGRAM'S OUTPUT.
///
/// Ring prints what ran and then reports the error. We buffer stdout 64 KB
/// at a time, and neither `@panic` nor a hard fault ever flushed it -- so a
/// test that printed 120 correct lines and then died printed NOTHING, and
/// read in the clock exactly like one that never started. Measured
/// 2026-09-15 on the wide clock: 80 of 432 tests produced no output at all,
/// and every one of them was a crash of some kind.
///
/// `flushForPanic` is what the root modules install. It runs once -- a
/// panic inside the flush must not recurse -- and then hands over to Zig's
/// own reporting, which is what prints the message and the trace.
var panicking = false;

pub fn flushForPanic() void {
    if (panicking) return;
    panicking = true;
    outFlush();
}

/// Route a hard fault through the panic path too, so a segfault reports
/// itself instead of exiting 139 in silence. ReleaseSafe installs this
/// itself; ReleaseFast -- which is what every measurement runs -- does not,
/// which is why ~46 of those 80 had no message at all.
///
/// A fault does NOT go through the `panic` interface on Windows: the
/// vectored handler prints and aborts on its own. So this adds one of its
/// own FIRST, which flushes the program's output and then lets the search
/// continue to Zig's, which does the reporting.
///
/// AND AN ENGINE LIBRARY'S PANIC ENDS IN `abort()` (2026-10-09). A panic
/// inside a native library -- the engine is built ReleaseSafe, so it checks
/// -- prints its own trace and aborts, which is SIGABRT on POSIX: neither
/// our panic interface nor the segfault handler sees it, and the buffered
/// output went with the process. neural/semantic_retrieval on Linux: the
/// engine panics in buildBackbone on BOTH runtimes, Ring had already
/// printed three passing assertions, and Ring++ printed nothing. glibc's
/// abort() runs a SIGABRT handler and still terminates when it returns, as
/// Zig's own abort() does without libc, so the handler only flushes; the
/// exit is unchanged. NOT COVERED ON WINDOWS: Zig's abort() there is
/// ExitProcess(3), which no handler sees.
pub fn armFaultReporting() void {
    if (host_os == .windows) {
        _ = std.os.windows.kernel32.AddVectoredExceptionHandler(1, flushFirst);
    } else {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = flushOnAbort },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.ABRT, &act, null);
    }
    std.debug.attachSegfaultHandler();
}

fn flushOnAbort(_: i32) callconv(.c) void {
    flushForPanic();
}

fn flushFirst(info: *std.os.windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const code = info.ExceptionRecord.ExceptionCode;
    // Only the ones that end the process. A debugger breakpoint or a
    // first-chance exception something else will handle must not make us
    // flush half a line and carry on.
    switch (code) {
        std.os.windows.EXCEPTION_ACCESS_VIOLATION,
        std.os.windows.EXCEPTION_ILLEGAL_INSTRUCTION,
        std.os.windows.EXCEPTION_STACK_OVERFLOW,
        std.os.windows.EXCEPTION_DATATYPE_MISALIGNMENT,
        => flushForPanic(),
        else => {},
    }
    return 0; // EXCEPTION_CONTINUE_SEARCH
}

/// `lkind`: where an OPERATOR call's result goes when the frame returns
/// (see `.opcall`). 0 is an ordinary call; 1 lands the result in the
/// caller's register named by the calling opcode's `a`; 2 and 3 are a
/// fused comparison that jumps to that opcode's `d` when the result is
/// truthy (2) or falsy (3); 4 drops it (an operator as a statement). The
/// register and the target are READ OFF THE INSTRUCTION at `ret_pc - 1`
/// rather than stored: two more fields took the frame from 24 to 32 bytes
/// and cost fib 5% (measured). `size` is a byte because every frame is.
pub const Frame = struct { ret_pc: u32, base: u32, mask: u64, size: u8, full: bool = false, lkind: u8 = 0 };

/// `c` in a `.call`, and `MethodEnt.id`, are 8 bits: this is the value that
/// means "no mask for this one".
pub const NO_MASK: u8 = 0xFF;

/// One armed `try`. `errreg` is where the caught value is bound, which
/// is a register in the handler's own frame -- NOT a process global.
/// That is the whole of §2.17's fourth point: a callee can no longer
/// overwrite the error its caller is handling, because there is nothing
/// shared to overwrite.
pub const Handler = struct { catch_pc: u32, fsp: u32, base: u32, errreg: u8 };

/// An `eval` in progress: its own pc and the frame depth its code runs at
/// (VM.eval_sites).
pub const EvalSite = struct { pc: u32, fsp: u32 };

/// A variable an eval made at run time (Op.dvget): its frame depth, its
/// name lower-cased (owned), its value (held once).
pub const DynVar = struct { depth: u32, name: []u8, val: Value };

/// What an opcode hands `.opcall` (see VM.op_name_idx): the receiver, the
/// argument, the operator's text, and how the answer lands -- `kind` as
/// in Frame.lkind; the register or the jump target is the calling
/// instruction's own `a` or `d`.
pub const PendOp = struct {
    recv: Value = Value.nil(),
    arg: Value = Value.nil(),
    name: []const u8 = "",
    kind: u8 = 0,
    /// 0 an operator call; 1 a GETTER (no argument); 2 a SETTER (the
    /// value). For 1 and 2 the method is already resolved, in `ment`.
    acc: u8 = 0,
    ment: MethodEnt = .{ .entry = 0, .frame = 0, .id = 0 },
};

pub const VM = struct {
    code: []const Instr,
    regs: []Value,
    frames: []Frame,
    alloc: std.mem.Allocator,
    /// What `sysargv` answers: [exe, script, args...], the shape Ring 1.27
    /// gives it. Empty when nobody set it -- a bench or a `call` -- and
    /// the builtin then returns an empty list rather than guessing.
    argv: []const []const u8 = &.{},
    /// THE LAST ERROR ANY HANDLER CAUGHT, process-wide -- what Ring's
    /// `cCatchError` is everywhere. Measured on 1.27 (bench/exec/
    /// catch_error_global.ring): the string "NULL" before any catch, then
    /// the last caught message, readable from any function until the next
    /// catch overwrites it. Inside a catch BODY `cCatchError` stays the
    /// handler's own register (§2.17: a callee's catch cannot overwrite the
    /// error its caller is handling -- Ring's does, measured, and that one
    /// row is the divergence C-15 keeps); every other read is this slot.
    /// Softanza reads it through `CatchError()` in stkRingFuncs.ring, a
    /// function, from inside its handlers. nil until the first catch.
    catch_last: Value = Value.nil(),
    /// RING'S OPERATOR OVERLOADING, measured on 1.27 (F-69, bench/exec/
    /// operator.ring, 36 rows): an object on the LEFT of any operator --
    /// `+ - * / % & | ^ << >> = != < <= > >= []` -- calls its class's
    /// `operator(cOp, x)` with the operator's own text and the right
    /// operand, and the call's value is the expression's value; `-o` is
    /// operator("neg", 0); an object on the RIGHT of an arithmetic,
    /// bitwise or ordering operator is called with "r" in front ("r+",
    /// "r<"), except that a LIST on the left of `+` appends it, and `=` /
    /// `!=` with the object on the right compare plainly (0 and 1); a
    /// class with no `operator` raises R50, except for `=` / `!=`, which
    /// compare plainly. Softanza's stzList, stzString, stzHashList and
    /// stzDuration are all written against this, and until 2026-09-24 every
    /// `o[:key]`, `Q(aL) * n` and `oDuration + 1800` was R21 or "Bad
    /// parameter type!" here -- a fifth of the missing assertion passes.
    /// `op_name_idx` is the name-table index of "operator", looked up once;
    /// `pend_op` is what the opcode that met the object hands to `.opcall`.
    op_name_idx: ?u32 = null,
    pend_op: PendOp = .{},
    /// The 256 one-character strings, made on first use and pinned, so
    /// `s[i]` (C-3) costs a table read and not an allocation per index.
    one_char: [256]?*Str = [_]?*Str{null} ** 256,
    /// Which globals have been ASSIGNED, for `isGlobal`. Separate from the
    /// values because `$x = NULL` still answers 1 on Ring 1.27 -- the
    /// global exists even when its value is nothing, so the slot's content
    /// cannot answer the question. Empty is safe: isGlobal then says 0,
    /// which is what an unassigned global should say anyway.
    globals_set: []bool = &.{},
    /// The message the next `continue :dispatch .raise` will report.
    pending: []const u8 = "",
    /// Storage for a message that names something -- R14 carries the method
    /// name -- since `pending` is only a slice.
    pending_buf: [256]u8 = undefined,
    /// An ENGINE's error message, copied out of the call's result before the
    /// raise (F-103): an engine's text has no fixed bound, so not pending_buf.
    native_err: std.ArrayListUnmanaged(u8) = .{},
    /// Names an eval made at run time, with the frame depth they belong to
    /// (0 = the globals) -- see Op.dvget. Few, and looked up only by code
    /// an eval reaches, so a list.
    dyn: std.ArrayListUnmanaged(DynVar) = .{},
    /// The raise in flight came from inside a native, so the report names it
    /// (`In stzenginelistfindallw()`); false for the R3 an `ncall` raises at
    /// a name nothing registered, and cleared when any raise is caught.
    native_raise: bool = false,
    /// The raise in flight is R42, an eval string that did not parse: raised
    /// INSIDE eval(), so the report says `In eval()` (F-108) -- unlike an
    /// error escaping eval'd code, which Ring runs after eval() returned.
    eval_c_err: bool = false,
    /// Each native's function once found, by NAME INDEX (`nchk`, `ncall`).
    /// A miss is never cached: LoadLib may register the name later, and
    /// Ring resolves it at the call. A library is never unloaded, so a hit
    /// stays true.
    ncache: []?native.RppFn = &.{},
    /// Reused buffer for builtins that build a string before newStr copies
    /// it -- replaceAll and friends. Cleared per call, never freed.
    scratch: std.ArrayListUnmanaged(u8) = .{},
    /// Name table, so `ncall` can report and resolve by name.
    names: []const []const u8 = &.{},
    /// `$x` globals, one slot per distinct name.
    globals: []Value = &.{},
    /// Armed try/catch handlers, innermost last.
    handlers: []Handler = &.{},
    /// Entry address and frame size per function id, so a closure can be
    /// called without knowing its target at compile time.
    fn_entry: []const u32 = &.{},
    fn_frame: []const u8 = &.{},
    /// Every function's locals (name, register, boxed), by function id --
    /// see compile.Program.fn_local_from. What eval binds a string to.
    fn_local_from: []const u32 = &.{},
    local_names: []const []const u8 = &.{},
    local_regs: []const u8 = &.{},
    local_boxed: []const bool = &.{},
    /// EVAL (F-72). `eval_hook` compiles a string in the caller's frame and
    /// runs it through `runFrom`; `hsp_floor` is the handler depth at the
    /// eval site, so an error nobody inside the eval catches RETURNS to the
    /// eval opcode (`eval_escaped`, `pending` set) instead of dying, and the
    /// outer loop raises it there -- the caller's `try` catches it, as
    /// Ring's does. `code_cap` is the usable size of `code`'s buffer, 0
    /// until the first eval copies the frozen code with headroom.
    eval_hook: ?EvalHook = null,
    hsp_floor: u32 = 0,
    eval_escaped: bool = false,
    /// True only while `+` copies a list LITERAL it appends: a referenced
    /// value met inside is pinned (Vec.rref = 2), as Ring leaves it (F-118).
    pin_refs: bool = false,
    code_cap: usize = 0,
    /// The eval calls in progress, innermost last: each `eval`'s own pc and
    /// the frame depth it runs in. Eval'd code is appended past `rows`, so
    /// an error inside it had no line and no function -- `Line 0`, `in
    /// file`, every frame below it lost. Ring reports EVERY line of an
    /// eval'd string at the line of the eval CALL, inside the caller's
    /// function, and shows no `eval()` frame (F-102, measured on 1.27);
    /// `sitePc` maps a pc in eval'd code back to that call through here.
    /// 32 is the hook's own depth limit, past which it raises R4.
    eval_sites: [32]EvalSite = undefined,
    eval_nsites: u32 = 0,
    /// Ring's runtime error report needs these; a driver that does not
    /// fill them (the benchmarks) gets the bare `Error:` line instead.
    rows: []const u32 = &.{},
    files: []const u16 = &.{},
    fn_of: []const u32 = &.{},
    fn_names: []const []const u8 = &.{},
    /// Lower-cased function name -> id, built on the first `call name()`.
    fn_index: ?std.StringHashMapUnmanaged(u32) = null,
    /// Lower-cased NAME -> its index in `names`, built on the first
    /// reflection call (ismethod, getattribute ...). The compiler's name
    /// table already folds case, so one index per spelling.
    name_lc: ?std.StringHashMapUnmanaged(u32) = null,
    fn_method: []const bool = &.{},
    file_names: []const []const u8 = &.{},
    main_fn: u32 = 0,

    pub fn newVec(self: *VM, cap0: u32) *Vec {
        const v = self.alloc.create(Vec) catch @panic("oom");
        const cap = if (cap0 == 0) 8 else cap0;
        const items = self.alloc.alloc(Value, cap) catch @panic("oom");
        // Born with rc 0: the first setReg/retain that stores it takes the
        // reference. Host-created vectors are retained explicitly instead.
        v.* = .{ .ptr = items.ptr, .len = 0, .cap = cap, .rc = 0 };
        // Deferred counting tracks every zero-count object, new ones included:
        // a vector held only by a register has rc 0 and would otherwise never
        // be considered for collection at all.
        if (DEFER) {
            if (zct_len == zct.len) self.zctFlush();
            zct[zct_len] = v;
            zct_len += 1;
        }
        return v;
    }

    pub fn vecPush(self: *VM, v: *Vec, x: Value) void {
        self.vecPushB(v, x, true);
    }

    fn vecPushB(self: *VM, v: *Vec, x: Value, boxed: bool) void {
        if (v.len == v.cap) {
            const ncap = v.cap * 2;
            const items = self.alloc.alloc(Value, ncap) catch @panic("oom");
            @memcpy(items[0..v.len], v.ptr[0..v.len]);
            // Only the owning build gives the old buffer back. The arena and
            // mi-no-rc builds leak it, which is the point of the comparison.
            if (RC) self.alloc.free(v.ptr[0..v.cap]);
            v.ptr = items.ptr;
            v.cap = ncap;
        }
        if (!TYPED or boxed) retain(x);
        v.ptr[v.len] = x;
        v.len += 1;
    }

    // ------------------------------------------------------ refcounting
    //
    // Every one of these is a no-op branch folded away at comptime in the
    // non-RC builds, so both binaries run the same instruction stream apart
    // from the counting itself.

    inline fn retain(v: Value) void {
        if (!RC) return;
        switch (v.tag) {
            .vec => v.p.v.rc += 1,
            .obj => v.p.o.rc += 1,
            .str => v.p.s.rc += 1,
            else => {},
        }
    }

    /// `call cName()` where cName is a STRING: Ring resolves it as a
    /// FUNCTION NAME at run time, and that is a feature the estate uses --
    /// a router keeps its handlers as names and calls them. Probed on 1.27:
    /// `g = "hello"` then `call g()` is `Error (R3) : Calling Function
    /// without definition: hello`, so the lookup happens and the miss is R3.
    ///
    /// Built ONCE, into a map, because the alternative is a linear scan
    /// over 45,000 names per call -- the shape this project has had to
    /// remove from the compiler twice (findFunc, collectAll) and will not
    /// put into the VM.
    fn funcByName(self: *VM, name: []const u8) ?u32 {
        if (self.fn_index == null) {
            var m = std.StringHashMapUnmanaged(u32){};
            var i: u32 = 0;
            while (i < self.fn_names.len) : (i += 1) {
                const nm = self.fn_names[i];
                if (nm.len == 0 or nm.len > 250) continue;
                // A METHOD IS NOT A FUNCTION BY NAME (F-92). `call "f"()` and
                // a bare call inside eval reach functions only, as on Ring;
                // this map held methods too, so an eval in stzObject.IfQ
                // asking for NumberOfItems() ran stzIntSeq's METHOD as a plain
                // function, with no receiver -- "Bad parameter type!".
                if (i < fn_owner.len and fn_owner[i] != 0xFFFF) continue;
                const key = self.alloc.alloc(u8, nm.len) catch continue;
                for (nm, 0..) |ch, k| key[k] = std.ascii.toLower(ch);
                // Ring folds case AND takes the FIRST definition of a name,
                // which is what the compiler's own lookup does.
                if (m.contains(key)) {
                    self.alloc.free(key);
                    continue;
                }
                m.put(self.alloc, key, i) catch {
                    self.alloc.free(key);
                    continue;
                };
            }
            self.fn_index = m;
        }
        var low: [250]u8 = undefined;
        if (name.len == 0 or name.len > low.len) return null;
        for (name, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        return self.fn_index.?.get(low[0..name.len]);
    }

    /// The name table's index for `name`, any case, or null if the program
    /// never mentions the name -- then no class can have such a method or
    /// attribute either, since both are compiled from names.
    fn nameIdx(self: *VM, name: []const u8) ?u32 {
        if (self.name_lc == null) {
            var m = std.StringHashMapUnmanaged(u32){};
            for (self.names, 0..) |nm, i| {
                if (nm.len == 0 or nm.len > 250) continue;
                const key = self.alloc.alloc(u8, nm.len) catch continue;
                for (nm, 0..) |ch, k| key[k] = std.ascii.toLower(ch);
                if (m.contains(key)) {
                    self.alloc.free(key);
                    continue;
                }
                m.put(self.alloc, key, @intCast(i)) catch {
                    self.alloc.free(key);
                    continue;
                };
            }
            self.name_lc = m;
        }
        var low: [250]u8 = undefined;
        if (name.len == 0 or name.len > low.len) return null;
        for (name, 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        return self.name_lc.?.get(low[0..name.len]);
    }

    /// The `operator` method of an object's class, if the class has one.
    /// The accessor Ring would call for this attribute access, or null.
    /// Measured on both 1.27 builds (bench/exec/getset.ring): any object
    /// but the method's own `This` goes through `get<name>()` for a read
    /// and `set<name>(v)` for a write when its class has one; a brace
    /// inside a method of the object's own class reads the slot
    /// (vendor/ring-vm/src/vmvars.c:226-283, vmoop.c:770-818).
    fn accessorOf(self: *VM, o: *Obj, nidx: u32, get: bool, mode: u8, base: u32) ?MethodEnt {
        const tab = if (get) acc_get else acc_set;
        if (nidx >= tab.len) return null;
        const mi = tab[nidx];
        if (mi == ACC_NONE) return null;
        const key = @as(u32, o.class) * n_names + mi;
        if (key >= dispatch.len) return null;
        const slot = dispatch[key];
        if (slot == 0) return null;
        if (mode == ACC_NOT_THIS or mode == ACC_BRACE) {
            const r0 = self.regs[base];
            if (r0.tag == .obj) {
                if (mode == ACC_NOT_THIS and r0.p.o == o) return null;
                if (mode == ACC_BRACE and r0.p.o.class == o.class) return null;
            }
        }
        return method_tab[slot - 1];
    }

    fn operatorOf(self: *VM, o: *Obj) ?MethodEnt {
        if (self.op_name_idx == null) self.op_name_idx = self.nameIdx("operator") orelse 0xFFFF_FFFF;
        const ni = self.op_name_idx.?;
        if (ni == 0xFFFF_FFFF) return null;
        const key = @as(u32, o.class) * n_names + ni;
        if (key >= dispatch.len) return null;
        const slot = dispatch[key];
        if (slot == 0) return null;
        return method_tab[slot - 1];
    }

    /// An arithmetic opcode met a non-number: is one side an OBJECT, so the
    /// class's `operator` decides? Fills `pend_op` and says so. `name` is
    /// the operator as written, `rname` its reversed form for an object on
    /// the right; `land` the opcode's destination register (frame-relative).
    inline fn opWant(self: *VM, x: Value, y: Value, name: []const u8, rname: []const u8) bool {
        if (x.tag == .obj) {
            self.pend_op = .{ .recv = x, .arg = y, .name = name, .kind = 1 };
            return true;
        }
        if (y.tag == .obj) {
            // a LIST on the left of `+` appends the object; no dispatch
            if (x.tag == .vec and name.len == 1 and name[0] == '+') return false;
            self.pend_op = .{ .recv = y, .arg = x, .name = rname, .kind = 1 };
            return true;
        }
        return false;
    }

    /// The same for a fused comparison jump. `src` is the comparison the
    /// SOURCE wrote (the compiler inverts the jump; c = 1 says so, and the
    /// caller has already un-inverted the name); the jump is taken when the
    /// operator's answer is truthy (not inverted) or falsy (inverted).
    inline fn opWantJump(self: *VM, x: Value, y: Value, src: []const u8, rsrc: []const u8, inverted: bool) bool {
        const kind: u8 = if (inverted) 3 else 2;
        if (x.tag == .obj) {
            self.pend_op = .{ .recv = x, .arg = y, .name = src, .kind = kind};
            return true;
        }
        if (y.tag == .obj) {
            // `5 = o` and `5 != o` compare plainly on Ring: no dispatch
            if (src[0] == '=' or src[0] == '!') return false;
            self.pend_op = .{ .recv = y, .arg = x, .name = rsrc, .kind = kind};
            return true;
        }
        return false;
    }

    /// Give the object a per-object attribute `nm` holding NULL, unless its
    /// class or the object already has one. Shared by `addattribute` and by
    /// the class-region read (`ggeta`).
    fn ensureExtra(self: *VM, o: *Obj, nm: []const u8) void {
        if (self.nameIdx(nm)) |ni| {
            if (attrLookup(o.class, ni) != null) return;
        }
        if (extraAt(o, nm) != null) return;
        if (o.extra == null) {
            const ex = self.newVec(4);
            retain(Value.vec(ex));
            o.extra = ex;
        }
        var lb: [256]u8 = undefined;
        const n = @min(nm.len, lb.len);
        for (nm[0..n], 0..) |ch, i| lb[i] = std.ascii.toLower(ch);
        self.vecPushB(o.extra.?, Value.str(self.newStr(lb[0..n])), true);
        self.vecPushB(o.extra.?, Value.str(self.newStr("NULL")), true);
    }

    /// Every handler landing records the error it caught (see catch_last).
    fn noteCaught(self: *VM, err: Value) void {
        retain(err);
        self.release(self.catch_last);
        self.catch_last = err;
    }

    /// A user-written name, lower-cased: skips the compiler's own synthetic
    /// functions (`@@main`, `@@lambda14`, class prologues), which Ring does
    /// not have and reflection must not show. SYNTHETIC IS `@@`, not `@`:
    /// Softanza defines 2,166 functions named `@IsNumber`, `@IsListOfStrings`
    /// and so on, and the first version skipped them all -- so its
    /// constraint engine reported `no @isnumber() predicate exists` and two
    /// tests stopped without an error line (2026-09-24).
    fn reflectName(nm: []const u8, buf: []u8) ?[]const u8 {
        if (nm.len == 0 or nm.len > buf.len or std.mem.startsWith(u8, nm, "@@")) return null;
        for (nm, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return buf[0..nm.len];
    }

    fn release(self: *VM, v: Value) void {
        if (!RC) return;
        switch (v.tag) {
            .vec => {
                const o = v.p.v;
                o.rc -= 1;
                // Under deferred counting the object is already in the table;
                // reaching zero just makes it a candidate, not garbage.
                if (o.rc == 0 and !DEFER) self.freeVec(o) else if (o.rc == 1 and o.rref == 1) o.rref = 0;
            },
            .obj => {
                const o = v.p.o;
                o.rc -= 1;
                // one holder left: no longer Ring's reference (vmgc.c:429-433),
                // unless pinned
                if (o.rc == 0 and !DEFER) self.freeObj(o) else if (o.rc == 1 and o.rref == 1) o.rref = 0;
            },
            .str => {
                const o = v.p.s;
                o.rc -= 1;
                if (o.rc == 0) {
                    // THE BYTES TOO. This destroyed the header and leaked the
                    // buffer, which an arena hid completely: `_s_ += "x"` 400,000
                    // times at the top level leaked every intermediate string --
                    // 80 GB of them -- and died as `panic: oom` inside the
                    // concatenation (perf/engine_senses, found 2026-09-12).
                    // Every Str the VM makes owns a buffer of exactly `len`
                    // (newStr, the concat path, reverse). A CONSTANT's Str points
                    // into the source text instead, and the compiler pins it at
                    // rc = 1 -- every retain/release pairs -- so it never reaches
                    // zero and this line never sees it.
                    // Freed at the size ALLOCATED, which is `cap` when this
                    // string has room to spare -- handing an allocator a
                    // different length than it gave out is a bug even when
                    // it happens to survive.
                    const owned = if (o.cap > o.len) o.cap else o.len;
                    if (owned > 0) self.alloc.free(@constCast(o.ptr[0..owned]));
                    self.alloc.destroy(o);
                }
            },
            else => {},
        }
    }

    /// Mark every vector reachable from a register, then free the zero-count
    /// entries nothing points to. Entries that survive stay in the table: with
    /// registers uncounted, nothing else would ever reconsider them.
    fn zctFlush(self: *VM) void {
        const n = zct_len;
        @memcpy(zct_tmp[0..n], zct[0..n]);
        zct_len = 0; // frees below may re-enter the table

        var i: u32 = 0;
        while (i < ROOT_SCAN) : (i += 1) {
            const r = self.regs[i];
            if (r.tag == .vec) r.p.v.mark = 1;
        }

        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const o = zct_tmp[k];
            if (o.rc == 0 and o.mark == 0) {
                self.freeVec(o);
            } else {
                o.mark = 0;
                if (zct_len < zct.len) {
                    zct[zct_len] = o;
                    zct_len += 1;
                }
            }
        }
    }

    /// Allocate an owned string. Immutable by construction, so callers
    /// share it by reference from here on.
    /// A number as Ring writes it when it lands in a string. Measured on
    /// 1.27: 3 -> "3", -2 -> "-2", 1.5 -> "1.50", and 3.0 -> "3" -- a
    /// float with no fractional part loses the decimals, so this cannot
    /// simply always print two.
    pub fn numText(v: Value, buf: []u8) []const u8 {
        if (v.tag == .int) return std.fmt.bufPrint(buf, "{d}", .{v.p.i}) catch "0";
        const f = asF64(v);
        if (f == @floor(f) and @abs(f) <= 9007199254740991.0) {
            return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(f))}) catch "0";
        }
        return fmtDecimals(buf, f);
    }

    // Ring's own messages, measured on 1.27 rather than invented, because
    // Softanza catches these and shows them to people.
    const R1 = "Error (R1) : Can't divide by zero";
    const R2 = "Error (R2) : Array Access (Index out of range)";
    const R21 = "Error (R21) : Using operator with values of incorrect type";
    const R50 = "Error (R50) : Object does not support operator overloading";
    const R24 = "Error (R24) : Using uninitialized variable";
    const R41 = "Error (R41) : Invalid numeric string";
    const R28 = "Error (R28) : Using bad data type as step value";
    const NULLPTR = "Error in parameter, NULL pointer!";
    const R29 = "Error (R29) : Using bad data type in for loop";
    const BADPARAM = "Bad parameter type!";
    const BADRANGE = "Bad parameters value, error in range!";
    const R35 = "Error (R35) : Can't create/open the file";
    const R4 = "Error (R4) : Stack Overflow";
    const R19 = "Error (R19) : Calling function with less number of parameters";
    const R20 = "Error (R20) : Calling function with extra number of parameters";

    /// RING RAISES R4 RATHER THAN DYING, and it is an ordinary catchable
    /// error: probed on 1.27, a self-recursive function stops at 998 frames
    /// entered, prints `Error (R4) : Stack Overflow`, and the program goes
    /// on after the catch. The guard sits on Ring's operand stack
    /// (RING_VM_STACK_CHECKOVERFLOW, 1000, vendor/ring-vm/include/vm.h:11);
    /// ours has register windows instead, so the equivalent is the FRAME.
    ///
    /// 1000 and not 998 because the number that matches the oracle is the
    /// one MEASURED through the same probe: counting frames entered, Ring
    /// answers 998 and we answered 996 at this constant, the two the top
    /// level and its trampoline hold. Copying Ring's header constant would
    /// have been off by that much.
    const max_frames_ring: u32 = 1000;

    /// The same answer for a copy that will not end. Ring has no cycle
    /// detection in `ring_list_copy_gc` either, so there is no behaviour to
    /// match here -- only the difference between telling the program and
    /// killing the process. Chosen against what real data reaches: a
    /// 4,000-deep nested list copies fine and the estate's deepest object
    /// graph is 13.
    const clone_max_depth: u32 = 5000;

    const ArithOp = enum { sub, mul, div, band, bor, bxor, shl, shr };

    /// A double as the i64 Ring's bitwise operators see: truncated, and
    /// pinned at the ends rather than undefined past them.
    inline fn truncI64(f: f64) i64 {
        if (std.math.isNan(f)) return 0;
        if (f >= 9.2e18) return std.math.maxInt(i64);
        if (f <= -9.2e18) return std.math.minInt(i64);
        return @intFromFloat(f);
    }

    inline fn bitOp(op: ArithOp, a: i64, b: i64) i64 {
        return switch (op) {
            .band => a & b,
            .bor => a | b,
            .bxor => a ^ b,
            .shl => a << @as(u6, @intCast(b & 63)),
            .shr => a >> @as(u6, @intCast(b & 63)),
            else => unreachable,
        };
    }

    /// A numeric string converts, on EITHER side: measured on 1.27,
    /// `"5" - 3` is 2 and `3 - "5"` is -2. Anything else is not a number.
    fn coerceNum(v: Value) ?f64 {
        if (v.tag == .int or v.tag == .num) return asF64(v);
        if (v.tag == .str) return ringNumText(strOf(v));
        return null;
    }

    /// A string as a NUMBER, by Ring's one rule -- `ring_vm_stringtonum`,
    /// vendor/ring-vm/src/vmexpr.c:892 -- which arithmetic, `=`/`!=` and
    /// `<`/`<=`/`>`/`>=` all use on Ring. Null means "not a number":
    /// arithmetic and ordering answer R41 for it, equality answers false.
    ///
    ///   ""              is 0 -- "Support converting NULL to Zero". So
    ///                   `0 = ""` is TRUE, and so is `0 = NULL`: the estate
    ///                   tests an engine handle with `if h = ""`, and a failed
    ///                   compile hands back the handle 0.
    ///   leading space   skipped, by strtod's own set: space, tab, LF, VT, FF,
    ///                   CR (`1 - (char(11) + "7")` is -6)
    ///   trailing space  allowed only from ring_general_looksempty's set:
    ///                   space, CR, LF, tab -- `5 = "5" + char(11)` is false
    ///   "   "           NOT 0: strtod converts nothing, and only the truly
    ///                   empty string is NULL. R41 in arithmetic.
    ///   "1_000"         not a number: strtod stops at the `_`. Zig's
    ///                   parseFloat would take it as a digit separator.
    ///
    /// Every row measured on 1.27 (bench/exec/num_text.ring), official build
    /// and oracle alike. ONE function for all three, because the rule is one
    /// on Ring: equality and ordering had their own and neither knew about
    /// "" or the spaces -- the third correction this month whose old rule
    /// outlived it in a sibling.
    ///
    /// NOT reproduced: a text that overflows a double ("1e999") is a
    /// catchable numeric-overflow error on Ring, and one that underflows is
    /// an underflow error; here they are inf and 0. Named, not measured.
    inline fn ringNumText(s: []const u8) ?f64 {
        if (s.len == 0) return 0;
        var i: usize = 0;
        while (i < s.len and switch (s[i]) {
            ' ', '\t', '\n', 11, 12, '\r' => true,
            else => false,
        }) i += 1;
        var j: usize = s.len;
        while (j > i and switch (s[j - 1]) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        }) j -= 1;
        const t = s[i..j];
        if (t.len == 0) return null;
        if (std.mem.indexOfScalar(u8, t, '_') != null) return null;
        return std.fmt.parseFloat(f64, t) catch null;
    }

    /// `-`, `*` and `/` once the numeric fast path has declined them.
    /// Unlike `+`, none of these concatenate or append -- measured on
    /// 1.27, a non-numeric string is R41, a list is R21, and dividing by
    /// zero is R1. All three used to @panic instead, which is a crash
    /// where Ring has a catchable error.
    fn arithSlow(self: *VM, dstreg: u32, op: ArithOp, x: Value, y: Value) ?[]const u8 {
        if (x.tag == .nil or y.tag == .nil) return R24;
        if (x.tag == .vec or x.tag == .obj or y.tag == .vec or y.tag == .obj) return R21;
        const xf = coerceNum(x) orelse return R41;
        const yf = coerceNum(y) orelse return R41;
        switch (op) {
            .sub => self.setRegB(dstreg, narrow(xf - yf), false),
            .mul => self.setRegB(dstreg, narrow(xf * yf), false),
            .div => {
                if (yf == 0) return R1;
                self.setRegB(dstreg, narrow(xf / yf), false);
            },
            // a numeric string is a number here too: `"6" & 3` is 2 on 1.27
            .band, .bor, .bxor, .shl, .shr => self.setRegB(dstreg, Value.int(bitOp(op, truncI64(xf), truncI64(yf))), false),
        }
        return null;
    }

    /// Ring's `+` once the numeric fast path has declined it. Writes
    /// r[dstreg] and returns null, or returns Ring's error text.
    ///
    /// Measured on 1.27, and `+` IS NOT SYMMETRIC -- the LEFT operand
    /// picks the meaning:
    ///   string + anything-but-a-list  -> concatenate
    ///   list   + anything             -> APPEND AS ONE ITEM, mutating the
    ///                                    left list ([1,2]+[3,4] is len 3)
    ///   number + numeric string       -> add;  non-numeric is R41
    ///   number + list, string + list  -> R21
    /// `compound` says this is `+=` rather than `+`. Measured on 1.27
    /// (F-51): the two are NOT the same operator. `+` appends to a list and
    /// `+=` raises R21 on one, while both concatenate a string. Ring++
    /// appended for either, in every kind of place, which is the dangerous
    /// direction -- Ring stops, Ring++ carries on with a changed list.
    /// `flag` is the instruction's d field: 0 plain, 1 compound, and 2 for
    /// the one shape the compiler can vouch for -- a compound assignment to
    /// a GLOBAL, where the left operand was read out of the very slot this
    /// result is about to be stored back into. That is what makes an
    /// in-place append sound at a refcount of two: the only two holders are
    /// that global and the register just read from it.
    fn addSlow(self: *VM, dstreg: u32, lreg: u32, x: Value, y: Value, flag: i32) ?[]const u8 {
        // bit 4: the right operand is a list LITERAL (F-118, pinRefs)
        const compound = (flag & 3) != 0;
        const from_global = (flag & 3) == 2;
        const literal = (flag & 4) != 0;
        // An UNASSIGNED value reaching `+`. Ring cannot get here -- reading
        // an uninitialised variable is R24 before any operator sees it --
        // so this reports R24 rather than guessing. It used to fall into
        // the number path and panic with "expected a number", which is a
        // crash where Ring has a catchable error.
        if (x.tag == .nil or y.tag == .nil) return R24;
        if (x.tag == .str) {
            if (y.tag == .vec or y.tag == .obj) return R21;
            // Anything that is neither text nor a number -- a closure, a
            // pointer -- is R21 on Ring. It used to reach numText and panic.
            if (!(y.tag == .str or isNum(y))) return R21;
            // 128: Ring's own RING_MEDIUMBUF; a whole double past 2^53
            // prints its full expansion and 40 bytes cut 1e40 short
            var nb: [128]u8 = undefined;
            const rhs = if (y.tag == .str) strOf(y) else numText(y, &nb);
            const l = strOf(x);
            const need = l.len + rhs.len;
            // `s = s + t` AND `s += t` GROW IN PLACE when nothing else holds
            // s. Every concatenation used to allocate a fresh buffer and copy
            // both sides, which makes building a string one piece at a time
            // quadratic: `_s_ += "x"` 400,000 times copied about 80 GB and
            // took 1.32 s, against 0.02 s on Ring -- 66x, measured
            // 2026-09-13 from perf/engine_senses, which builds exactly that.
            //
            // Safe under two conditions together: the result goes back to the
            // register the left side came from, so no other register can be
            // looking at the old value, and the refcount is 1, so no list,
            // attribute or frame holds it either. A constant has cap 0 and
            // fails the capacity test, so its source bytes are never written.
            const self_append = !no_inplace and dstreg == lreg and (x.p.s.rc == 1 or (from_global and x.p.s.rc == 2));
            if (trace_add and l.len < 300 and l.len + rhs.len >= 50) {
                std.debug.print("ADD dst={d} l={d} rc={d} cap={d} +{d} inplace={} ptr={x} [{s}] rhs=[{s}]\n", .{ dstreg, l.len, x.p.s.rc, x.p.s.cap, rhs.len, self_append and x.p.s.cap >= need, @intFromPtr(x.p.s.ptr), l[0..@min(l.len, 24)], rhs[0..@min(rhs.len, 24)] });
            }
            if (self_append and x.p.s.cap >= need) {
                const p = @constCast(x.p.s.ptr);
                @memcpy(p[l.len..need], rhs);
                x.p.s.len = @intCast(need);
                return null; // dstreg already holds this very string
            }
            // Headroom only for that shape; an ordinary `a + b` allocates
            // exactly what it needs and wastes nothing.
            const nbytes = if (self_append) @max(need, l.len + l.len / 2 + 32) else need;
            const buf = self.alloc.alloc(u8, nbytes) catch @panic("oom");
            @memcpy(buf[0..l.len], l);
            @memcpy(buf[l.len..need], rhs);
            const sp = self.alloc.create(Str) catch @panic("oom");
            sp.* = .{ .ptr = buf.ptr, .len = @intCast(need), .rc = 0, .cap = @intCast(nbytes) };
            self.setRegB(dstreg, Value.str(sp), true);
            return null;
        }
        if (x.tag == .vec) {
            // `aList += x` is not an append: Ring raises here (F-51).
            if (compound) return R21;
            // A LIST OR AN OBJECT IS APPENDED AS A COPY (F-94): `c = a + b`
            // leaves a[1] unchanged when b changes, on both 1.27 builds.
            // Always, not only when the count says shared: the operand
            // often comes straight from a named local's register, which
            // holds it at a count of one and goes on living. A closure is
            // the exception -- on Ring a lambda is a string, nothing to copy.
            if ((y.tag == .vec and !y.p.v.closure) or y.tag == .obj) {
                self.pin_refs = literal;
                const c = self.cloneDeep(y);
                self.pin_refs = false;
                if (self.pending.len != 0) {
                    const e = self.pending;
                    self.pending = "";
                    return e;
                }
                self.vecPushB(self.cowFor(lreg, x), c, true);
                self.setRegB(dstreg, self.regs[lreg], true);
                return null;
            }
            const boxed = y.tag == .str or y.tag == .vec or y.tag == .obj;
            self.vecPushB(self.cowFor(lreg, x), y, boxed);
            self.setRegB(dstreg, self.regs[lreg], true);
            return null;
        }
        if (isNum(x)) {
            if (y.tag != .str) return R21;
            // A NUMBER PLUS NL IS TEXT (F-98): when the right string is
            // EXACTLY "\n", ring_vm_sum answers the number's text and the
            // newline (vmexpr.c:27) -- Softanza writes `? n + NL` across its
            // suite, and the conversion below raised R41 on it. Not for `+=`,
            // which is R41 on both 1.27 builds (bench/exec/plus_nl.ring).
            const ys = strOf(y);
            if (!compound and ys.len == 1 and ys[0] == '\n') {
                var nb: [128]u8 = undefined;
                const t = numText(x, &nb);
                const buf = self.alloc.alloc(u8, t.len + 1) catch @panic("oom");
                @memcpy(buf[0..t.len], t);
                buf[t.len] = '\n';
                const sp = self.alloc.create(Str) catch @panic("oom");
                sp.* = .{ .ptr = buf.ptr, .len = @intCast(t.len + 1), .rc = 0, .cap = @intCast(t.len + 1) };
                self.setRegB(dstreg, Value.str(sp), true);
                return null;
            }
            const f = coerceNum(y) orelse return R41;
            self.setRegB(dstreg, narrow(asF64(x) + f), false);
            return null;
        }
        return R21;
    }

    fn markGlobal(self: *VM, slot: usize) void {
        if (slot < self.globals_set.len) self.globals_set[slot] = true;
    }

    /// The interned one-character string for a byte, pinned by one extra
    /// retain so no release can ever free it.
    fn oneChar(self: *VM, b: u8) *Str {
        if (self.one_char[b]) |s| return s;
        const s = self.newStr(&[_]u8{b});
        retain(Value.str(s));
        self.one_char[b] = s;
        return s;
    }

    fn newStr(self: *VM, bytes: []const u8) *Str {
        const sp = self.alloc.create(Str) catch @panic("oom");
        const buf = self.alloc.alloc(u8, bytes.len) catch @panic("oom");
        @memcpy(buf, bytes);
        sp.* = .{ .ptr = buf.ptr, .len = @intCast(bytes.len), .rc = 0 };
        return sp;
    }

    /// Every occurrence of `needle` in `hay` replaced by `with`.
    /// The buffer is owned by the VM's scratch arena and copied by newStr.
    fn replaceAll(self: *VM, hay: []const u8, needle: []const u8, with: []const u8) []const u8 {
        if (needle.len == 0) return hay;
        self.scratch.clearRetainingCapacity();
        var i: usize = 0;
        while (i < hay.len) {
            if (i + needle.len <= hay.len and std.mem.eql(u8, hay[i .. i + needle.len], needle)) {
                self.scratch.appendSlice(self.alloc, with) catch @panic("oom");
                i += needle.len;
            } else {
                self.scratch.append(self.alloc, hay[i]) catch @panic("oom");
                i += 1;
            }
        }
        return self.scratch.items;
    }

    /// A path as the OS wants it. Ring strings are not NUL-terminated,
    /// and std.fs takes a slice, so this is just a bounds-checked copy
    /// into scratch -- but it keeps the file builtins from aliasing a
    /// string the program still owns.
    fn zpath(self: *VM, p: []const u8) []const u8 {
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.alloc, p) catch @panic("oom");
        return self.scratch.items;
    }

    fn strOf(v: Value) []const u8 {
        if (v.tag != .str) @panic("builtin: expected a string");
        return v.p.s.ptr[0..v.p.s.len];
    }

    /// A count, an index or a character code: Ring TRUNCATES a fraction
    /// here -- char(65.9) is "A", left("hello", 2.9) is "he". Anything that
    /// is not a number cannot reach this, because the builtin dispatch
    /// checks first and raises "Bad parameter type!" as 1.27 does.
    ///
    /// It replaced `numOf`, which answered for `.int` and a numeric string
    /// and PANICKED on everything else -- so a float crashed the process
    /// (19 of the 432 tests in the wide clock) and a list crashed it where
    /// Ring raises.
    fn truncArg(v: Value) i64 {
        return truncI64(asF64(v));
    }

    /// An uncaught error, reported exactly as Ring 1.27 reports it
    /// (measured 2026-09-11, bench/exec/err_*.ring):
    ///
    ///     <blank>
    ///     Line N Error (Rk) : message <space>
    ///     In function f() in file F        (or "In method m()"; names lowercased)
    ///     <blank>
    ///     Called from line L In function g() in file F
    ///     <blank>
    ///     Called from line L in file F     (the top level, last, no newline)
    ///
    /// An error at the top level is the first line then `in file F`. Ring
    /// exits 1. For `Bad parameter type!` Ring prints NOTHING and exits
    /// 0 -- a defect not reproduced: it is reported like the rest.
    /// A jump target, checked when it goes BACKWARD. Every loop closes with
    /// a backward branch, so the watchdog sits there and never touches the
    /// hot path of straight-line code. The clock is read once every 65,536
    /// of them, so a running program pays an add and a test.
    ///
    /// A CALL is not a loop, whatever its target's address: the first
    /// version of this checked calls too, and `if CheckParams()` -- a call
    /// to a function defined earlier in the same file -- read as a backward
    /// branch. It reported honest code, twice.
    inline fn loopStep(self: *VM, to: u32, from: u32, fsp: u32) u32 {
        if (g_watchdog_at != 0 and to <= from) self.wdTick(from, fsp);
        return to;
    }

    /// The watchdog's one check. It sits at backward branches AND at the
    /// call opcodes, because a backward branch alone was not enough: the
    /// listparser hang went round for five minutes without taking one, and
    /// a diagnostic that cannot see the thing being hunted is worse than
    /// none -- it reads as an alibi.
    /// THE WINDOW IS A RATE ASSUMPTION, and 65,536 was the wrong one: the
    /// cycle being hunted turned round about 140 times a second, so the
    /// FIRST clock read would have come eight minutes in, and a 40 s
    /// watchdog looked like a watchdog that did not work. 256 costs a
    /// clock read per 256 steps in a tight loop -- and the clock here is
    /// a read of a shared page, not a syscall -- and sees a loop that
    /// turns once a second inside five minutes.
    inline fn wdTick(self: *VM, pc: u32, fsp: u32) void {
        g_wd_tick +%= 1;
        if (g_wd_tick & 0xff == 0 and std.time.milliTimestamp() >= g_watchdog_at) {
            self.dieRing("Ring++ diagnostic: watchdog -- still running here", pc, fsp);
        }
    }

    fn dieRing(self: *VM, msg: []const u8, pc: u32, fsp: u32) noreturn {
        self.dieRingFrom(msg, pc, fsp, false);
    }

    /// Ring's R24 for a variable nothing has assigned, worded as Ring words
    /// it: the name folded to lower case, sigil and all -- `$c`, `@nunset`.
    /// Probed on 1.27, eleven rows in bench/exec/r24_read.ring: raised AT
    /// THE READ, catchable, whether the read is alone, in a comparison, a
    /// subscript, a concatenation or an argument. Sets `pending`; the
    /// caller jumps to `.raise`.
    /// The native name index `d` stands for, from the cache or found and
    /// cached; null while nothing has registered it. native.find walks the
    /// whole registry, case-folding, so it is paid once per name.
    fn nativeOf(self: *VM, d: usize) ?native.RppFn {
        if (self.ncache.len == 0 and self.names.len != 0) {
            if (self.alloc.alloc(?native.RppFn, self.names.len)) |c| {
                @memset(c, null);
                self.ncache = c;
            } else |_| {}
        }
        if (d < self.ncache.len) {
            if (self.ncache[d]) |f| return f;
        }
        const f = native.find(self.names[d]) orelse return null;
        if (d < self.ncache.len) self.ncache[d] = f;
        return f;
    }

    /// Ring's R3 for a function nothing defines -- catchable (measured: `try
    /// x = nosuch() catch` catches it), the name lowercased as Ring prints
    /// it. Sets `pending`; the caller jumps to `.raise`.
    fn r3Named(self: *VM, nm: []const u8) void {
        var low: [128]u8 = undefined;
        const n = @min(nm.len, low.len);
        for (nm[0..n], 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        self.pending = std.fmt.bufPrint(&self.pending_buf, "Error (R3) : Calling Function without definition: {s}", .{low[0..n]}) catch "Error (R3) : Calling Function without definition";
    }

    fn dynFind(self: *VM, depth: u32, nm: []const u8) ?usize {
        for (self.dyn.items, 0..) |dv, i| {
            if (dv.depth == depth and std.ascii.eqlIgnoreCase(dv.name, nm)) return i;
        }
        return null;
    }

    /// A run-time name's value: this frame's (when `local`), then a global's.
    fn dynRead(self: *VM, nm: []const u8, fsp: u32, local: bool) ?Value {
        if (self.dyn.items.len == 0) return null;
        if (local) {
            if (self.dynFind(fsp, nm)) |i| return self.dyn.items[i].val;
        }
        if (self.dynFind(0, nm)) |i| return self.dyn.items[i].val;
        return null;
    }

    fn konstName(i: i32) []const u8 {
        if (i < 0 or i >= konst.len or konst[@intCast(i)].tag != .str) return "?";
        const s0 = konst[@intCast(i)].p.s;
        return s0.ptr[0..s0.len];
    }

    fn r24Named(self: *VM, nm: []const u8) void {
        var lower: [128]u8 = undefined;
        const ln = @min(nm.len, lower.len);
        for (nm[0..ln], 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
        self.pending = std.fmt.bufPrint(&self.pending_buf, "Error (R24) : Using uninitialized variable: {s}", .{lower[0..ln]}) catch "Error (R24) : Using uninitialized variable";
    }

    /// The name of attribute `slot` on class `cls`, walking the class's
    /// entries -- the ERROR path only, so a read that succeeds never pays.
    fn attrNameOf(self: *VM, cls: usize, slot: u32) []const u8 {
        if (cls + 1 < attr_from.len) {
            var i = attr_from[cls];
            const end = attr_from[cls + 1];
            while (i < end) : (i += 1) {
                if (attr_ent[i].slot == slot) {
                    const ni = attr_ent[i].name;
                    return if (ni < self.names.len) self.names[ni] else "?";
                }
            }
        }
        return "?";
    }

    /// The pc whose line and function a report gives for `pc`, run at frame
    /// depth `fsp`. Real code is itself. Eval'd code sits past `rows`, and
    /// Ring reports every line of it at the line of the eval CALL, in the
    /// caller's function, with no `eval()` frame (F-102, 1.27): so it is the
    /// innermost eval in progress at that depth -- and, an eval inside
    /// eval'd code being eval'd code too, that one's call in turn.
    /// The line a report gives for `pc` at frame depth `fsp`: the static
    /// table, unless a `jmpl` said this frame reached it the way Ring reaches
    /// the first statement after an `ok` -- past its line marker (F-110) --
    /// and the code is on that statement's first line, before any newline
    /// whose marker Ring would run.
    fn reportRow(self: *VM, pc: u32, fsp: u32) u32 {
        const row = if (pc < self.rows.len) self.rows[pc] else 0;
        if (fsp < g_ln_ovr.len) {
            const o = g_ln_ovr[fsp];
            if (o.line != 0 and pc >= o.lo and pc < o.hi and row == o.srow) return o.line;
        }
        return row;
    }

    fn sitePc(self: *VM, pc0: u32, fsp: u32) u32 {
        var pc = pc0;
        var i = self.eval_nsites;
        while (pc >= self.rows.len and i > 0) {
            i -= 1;
            if (self.eval_sites[i].fsp == fsp) pc = self.eval_sites[i].pc;
        }
        return pc;
    }

    /// The C function an error at `pc` was raised INSIDE, as Ring names it
    /// in front of the first frame: `In find() In method m() in file F`,
    /// and `In left() in file F` at the top level (vmerror.c:155, the frame
    /// a C function holds while it runs; F-102, 33 shapes on 1.27). Only an
    /// error the builtin itself raises: an operator's (R21), one before the
    /// call (R3 at the name, R24 at an argument), and anything escaping an
    /// eval string -- whose code Ring runs after eval() has returned -- get
    /// none. `vpush` and `dlen` also serve a list literal, `aL[i] + v` and
    /// a for-in loop, so they stand for add() and len() only where the
    /// compiler says so in `d`.
    fn cfnAt(self: *VM, pc: u32, low: *[128]u8) ?[]const u8 {
        if (pc >= self.code.len) return null;
        const in = self.code[pc];
        return switch (in.op) {
            // an engine function, by the name it was called with, lower-cased
            // as Ring's scanner leaves every identifier -- only when the raise
            // came from inside it (F-103)
            .ncall => blk: {
                if (!self.native_raise or in.d < 0 or in.d >= self.names.len) break :blk null;
                const nm = self.names[@intCast(in.d)];
                const n = @min(nm.len, low.len);
                for (nm[0..n], 0..) |ch, i| low[i] = std.ascii.toLower(ch);
                break :blk low[0..n];
            },
            .bcall => blk: {
                if (in.d < 0 or in.d >= @typeInfo(Builtin).@"enum".fields.len) break :blk null;
                const b: Builtin = @enumFromInt(@as(u16, @intCast(in.d)));
                if (b == .eval) break :blk if (self.eval_c_err) "eval" else null;
                break :blk builtinRingName(b);
            },
            .vdel => "del",
            .vins => "insert",
            .clsname => "classname",
            .substr2d => "substr",
            .vpush => if (in.d == 1) "add" else null,
            .dlen => if (in.d == 1) "len" else null,
            else => null,
        };
    }

    /// `raised` -- the error came from Ring's `raise()`, which puts a frame
    /// of its own in front of the reporting one: `In raise() In function
    /// f() in file F`, and `In raise() in file F` at the top level
    /// (measured 2026-09-11 on the oracle).
    fn dieRingFrom(self: *VM, msg: []const u8, pc0: u32, fsp: u32, raised: bool) noreturn {
        if (self.rows.len == 0 or self.fn_of.len == 0) {
            outPrint("Error: {s}\n", .{msg});
            outFlush();
            std.process.exit(1);
        }
        // Through outPrint, like every `?` before it: one buffer, so
        // the report follows the program's output instead of overtaking
        // it (it did, on 2026-09-11, ahead of 76 warnings).
        const pc = self.sitePc(pc0, fsp);
        var cfn_low: [128]u8 = undefined;
        const row = self.reportRow(pc, fsp);
        const fi = if (pc < self.files.len) self.files[pc] else 0;
        outPrint("\nLine {d} {s} \n", .{ row, msg });
        var f = if (pc < self.fn_of.len) self.fn_of[pc] else self.main_fn;
        if (raised) {
            outPrint("In raise() ", .{});
        } else if (self.cfnAt(pc0, &cfn_low)) |cf| {
            outPrint("In {s}() ", .{cf});
        }
        if (f == self.main_fn or f >= self.fn_names.len) {
            outPrint("in file {s} ", .{self.fileName(fi)});
            outFlush();
            std.process.exit(1);
        }
        self.printFn(f, fi);
        // the chain: each frame's return address, minus one, is the call
        var k = fsp;
        while (k > 0) : (k -= 1) {
            // the call ran at depth k-1, in eval'd code when it came from one
            const call_pc = self.sitePc(self.frames[k - 1].ret_pc -| 1, k - 1);
            const crow = self.reportRow(call_pc, k - 1);
            const cfi = if (call_pc < self.files.len) self.files[call_pc] else 0;
            f = if (call_pc < self.fn_of.len) self.fn_of[call_pc] else self.main_fn;
            if (f == self.main_fn or f >= self.fn_names.len) {
                outPrint("\nCalled from line {d} in file {s} ", .{ crow, self.fileName(cfi) });
                break;
            }
            outPrint("\nCalled from line {d} ", .{crow});
            self.printFn(f, cfi);
        }
        outFlush();
        // Under either diagnostic, say that the report is finished and the
        // exit is ours to make. A program that printed its whole error and
        // then hung looked exactly like one still running, and this is the
        // line that told the two apart: it was the LAST thing on stderr,
        // so the spin was inside process exit and not in any Ring code.
        if (g_watchdog_s > 0 or g_trace_native) {
            std.debug.print("  -- report complete, calling exit(1)\n", .{});
        }
        std.process.exit(1);
    }

    fn fileName(self: *VM, fi: u16) []const u8 {
        return if (fi < self.file_names.len) self.file_names[fi] else "?";
    }

    /// `In function f() in file F` / `In method m() in file F`, lowercased.
    fn printFn(self: *VM, f: u32, fi: u16) void {
        const is_m = f < self.fn_method.len and self.fn_method[f];
        outPrint("In {s} ", .{if (is_m) "method" else "function"});
        var low: [128]u8 = undefined;
        const nm = self.fn_names[f];
        const n = @min(nm.len, low.len);
        for (nm[0..n], 0..) |ch, i| low[i] = std.ascii.toLower(ch);
        outPrint("{s}() in file {s}\n", .{ low[0..n], self.fileName(fi) });
    }

    /// Ring's copy: a list or an object, and every list or object inside
    /// it, made private. Strings are immutable and shared by reference;
    /// scalars are values. Probed on 1.27: `q = h; q.o2.x = 3` leaves
    /// h.o2.x at 0 -- the copy reaches nested objects, as it reaches
    /// nested lists (NOTES.md, Decision 4).
    fn cloneDeep(self: *VM, v: Value) Value {
        return self.cloneDeepD(v, 0);
    }

    fn cloneDeepD(self: *VM, v: Value, d: u32) Value {
        if (d > clone_max_depth) {
            // Ring has no cycle detection in its own copy either, so this
            // is not a place where matching it is possible: what matters is
            // that the process SURVIVES and the program is told, the way
            // Ring tells it about R4. Reached only by a graph that holds
            // itself -- 34 of the 432 did, through `_These_ = This`, and
            // every one of them took the process down with no message.
            self.pending = R4;
            return Value.nil();
        }
        switch (v.tag) {
            .vec => {
                const src = v.p.v;
                // Ring's reference is copied BY REFERENCE, at any depth
                // (vmlists.c:530): the caller's retain makes it one more holder.
                // Inside a list literal appended with `+`, Ring pins it.
                if (src.rref != 0) {
                    if (self.pin_refs and d > 0) src.rref = 2;
                    return v;
                }
                const c = self.newVec(if (src.len == 0) 8 else src.len);
                c.closure = src.closure;
                var i: u32 = 0;
                while (i < src.len) : (i += 1) {
                    const e = self.cloneDeepD(src.ptr[i], d + 1);
                    retain(e);
                    c.ptr[i] = e;
                }
                c.len = src.len;
                return Value.vec(c);
            },
            .obj => {
                const src = v.p.o;
                if (src.rref != 0) {
                    if (self.pin_refs and d > 0) src.rref = 2;
                    return v;
                }
                const o = self.alloc.create(Obj) catch @panic("oom");
                const sl = self.alloc.alloc(Value, if (src.nslots == 0) 1 else src.nslots) catch @panic("oom");
                var i: u32 = 0;
                while (i < src.nslots) : (i += 1) {
                    const e = self.cloneDeepD(src.slots[i], d + 1);
                    retain(e);
                    sl[i] = e;
                }
                o.* = .{ .slots = sl.ptr, .nslots = src.nslots, .class = src.class, .rc = 0 };
                if (src.extra) |ex| {
                    const cv = self.cloneDeepD(Value.vec(ex), d + 1);
                    retain(cv);
                    o.extra = cv.p.v;
                }
                return Value.object(o);
            },
            else => return v,
        }
    }

    /// RING'S COUNT of a list or an object: its NAMED holders -- variables,
    /// list items, attributes -- which is what Ring's nReferenceCount + 1
    /// counts (vmgc.c:677) and what decides whether `ref()`'s sharing still
    /// holds. The VM's own count also counts TEMPORARIES in registers, so
    /// those are taken off: every register of a live frame that holds the
    /// value and is not one of its function's locals. Parameters are locals
    /// here and Ring does not count one (it is a pointer to the caller's), so
    /// a referenced value whose last outside holder passed it into the
    /// running function reads one high. Walks the live frames: called only
    /// for a referenced value about to be shared, and by refcount().
    fn ringHolders(self: *VM, v: Value, fsp: u32, pc: u32, cur_base: u32) u32 {
        const rc: u32 = if (v.tag == .vec) v.p.v.rc else v.p.o.rc;
        var n = rc;
        var k: u32 = 0;
        while (k < fsp) : (k += 1) {
            // frames[k] is the function the k-th call entered -- its size and
            // its mask -- and the CALLER's base; its own base is the one the
            // next call saved, or the running one at the top
            const fr = self.frames[k];
            const own: u32 = if (k + 1 < fsp) self.frames[k + 1].base else cur_base;
            const at: u32 = if (k + 1 < fsp) self.frames[k + 1].ret_pc -| 1 else pc;
            const fid: u32 = if (at < self.fn_of.len) self.fn_of[at] else std.math.maxInt(u32);
            const lo: u32 = if (fid + 1 < self.fn_local_from.len) self.fn_local_from[fid] else 0;
            const hi: u32 = if (fid + 1 < self.fn_local_from.len) self.fn_local_from[fid + 1] else 0;
            var r: u32 = 0;
            while (r < fr.size) : (r += 1) {
                const x = self.regs[own + r];
                if (x.tag != v.tag) continue;
                if (if (v.tag == .vec) x.p.v != v.p.v else x.p.o != v.p.o) continue;
                var local = false;
                for (self.local_regs[lo..hi]) |lr| {
                    if (lr == r) {
                        local = true;
                        break;
                    }
                }
                if (!local and n > 0) n -= 1;
            }
        }
        return n;
    }

    /// Pin every reference inside a list literal that `+` appends (F-118):
    /// a referenced value found is pinned and not entered (Ring copies it by
    /// reference and stops there, vmlists.c:530); anything else is walked.
    fn pinRefs(self: *VM, v: Value, d: u32) void {
        if (d > clone_max_depth) return;
        switch (v.tag) {
            .vec => {
                const s = v.p.v;
                if (d > 0 and s.rref != 0) {
                    s.rref = 2;
                    return;
                }
                for (s.ptr[0..s.len]) |e| self.pinRefs(e, d + 1);
            },
            .obj => {
                const o = v.p.o;
                if (d > 0 and o.rref != 0) {
                    o.rref = 2;
                    return;
                }
                for (o.slots[0..o.nslots]) |e| self.pinRefs(e, d + 1);
            },
            else => {},
        }
    }

    fn cloneVec(self: *VM, v: *Vec) *Vec {
        const c = self.newVec(if (v.len == 0) 8 else v.len);
        c.closure = v.closure;
        @memcpy(c.ptr[0..v.len], v.ptr[0..v.len]);
        c.len = v.len;
        // The copy holds its own reference to every element it shares.
        var i: u32 = 0;
        while (i < v.len) : (i += 1) retain(c.ptr[i]);
        return c;
    }

    /// A write NEVER clones any more (C-7, 2026-09-11). It used to, when
    /// the vector was shared (`rc > 1`) -- Decision 4's copy-on-write --
    /// and that was wrong for the one sharing Ring does by reference: a
    /// parameter. `f(a)` with `l[1] = 99` inside left the caller's a at 1
    /// (Ring: 99), and `add(l, 3)` inside a callee grew a clone that was
    /// thrown away. The copy Ring makes happens at the ASSIGNMENT now
    /// (`copyv`), eagerly, so by the time anything writes, a shared
    /// vector is shared only by borrowers who are meant to see the write.
    /// The -Dcow build option is kept so the A/B build names stay stable;
    /// it no longer changes behaviour.
    inline fn cowFor(self: *VM, reg: u32, vv: Value) *Vec {
        _ = self;
        _ = reg;
        return vv.p.v;
    }

    fn freeObj(self: *VM, o: *Obj) void {
        var i: u32 = 0;
        while (i < o.nslots) : (i += 1) self.release(o.slots[i]);
        if (o.extra) |ex| self.release(Value.vec(ex));
        self.alloc.free(o.slots[0..if (o.nslots == 0) 1 else o.nslots]);
        self.alloc.destroy(o);
    }

    fn freeVec(self: *VM, v: *Vec) void {
        var i: u32 = 0;
        while (i < v.len) : (i += 1) self.release(v.ptr[i]);
        self.alloc.free(v.ptr[0..v.cap]);
        self.alloc.destroy(v);
    }

    /// Write path used when the compiler knows whether this destination can
    /// carry a heap reference. `boxed=false` under TYPED means: the register
    /// holds an int here and forever, so neither the old nor the new value can
    /// be a pointer and the whole retain/release pair disappears.
    inline fn setRegB(self: *VM, i: u32, v: Value, boxed: bool) void {
        if (RC and !DEFER and (!TYPED or boxed)) {
            const old = self.regs[i];
            retain(v);
            self.regs[i] = v;
            self.release(old);
        } else {
            // An UNBOXED store -- an integer, a number, a borrow -- takes no
            // count of what it stores, but it still RELEASES a counted value
            // it overwrites. It did not, and a temporary that held a list or
            // an object from an earlier statement leaked that count for good
            // whenever an integer landed on it: `n = len(Make())` then
            // `y = [10]` kept every list Make() built (170 bytes a call, 70 MB
            // for 200,000 calls against Ring's 18), and a global read into
            // one gained a phantom holder per call -- which made Ring's count
            // of a `ref()` wrong (F-118). The one store that must NOT release
            // is the end of a borrow, which the borrowed value was never
            // counted for: `loadi` with b = 1 (`rawStore`).
            // One unsigned compare (str, vec and obj are tags 3..5), the
            // release out of line. The COMPARE is the cost, not the release:
            // with the call turned into a plain store the kernels still read
            // 5-7% slower (2026-10-15). It was bought back by not storing --
            // a local index is read in place rather than copied into a
            // temporary, and an arithmetic op whose destination is its own
            // operand runs an unchecked twin (emitOne). Four kernels now read
            // 0.55-1.02x the build before F-118; fib 1.04-1.09x, against
            // 1.00-1.04x with this check removed altogether (CLAUDE.md).
            const old = self.regs[i];
            self.regs[i] = v;
            if (RC and !DEFER and @intFromEnum(old.tag) -% 3 < 3) {
                @branchHint(.unlikely);
                self.releaseCold(old);
            }
        }
    }

    /// The unboxed store with the release check compiled out when `unchecked` -- an unchecked twin's
    /// destination is the operand its fast path has just tested numeric, so what it overwrites holds no count.
    inline fn setRegU(self: *VM, i: u32, v: Value, comptime unchecked: bool) void {
        if (unchecked) {
            self.regs[i] = v;
        } else self.setRegB(i, v, false);
    }

    noinline fn releaseCold(self: *VM, v: Value) void {
        self.release(v);
    }

    /// The single write path for the register file. Retain BEFORE release so
    /// that `x = x` on the last reference does not free what it is copying.
    pub inline fn setReg(self: *VM, i: u32, v: Value) void {
        if (RC) {
            const old = self.regs[i];
            retain(v);
            self.regs[i] = v;
            self.release(old);
        } else {
            self.regs[i] = v;
        }
    }

    /// Ring-compatible equality, for the COMPATIBILITY build.
    ///
    /// int==int numerically; str==str by content; and mixed str/int
    /// compares NUMERICALLY when the string parses as a number, which is
    /// why Ring answers true for `1 = "01.01"`. That coercion is a defect
    /// in the critical analysis (verdict: break with a rule) -- it is
    /// reproduced here because the mission is "run the 300K lines as-is"
    /// first, and a strict build flag is where it gets removed.
    /// find()'s equality: the SAME kind and the same value -- measured,
    /// find(a, "20") in a list holding 20 is 0; a list or an object only
    /// finds itself (find(n, [3,4]) is 0 on Ring).
    fn strictEq(a: Value, b: Value) bool {
        if (isNum(a) and isNum(b)) return asF64(a) == asF64(b);
        if (a.tag == .str and b.tag == .str) {
            const x = a.p.s;
            const y = b.p.s;
            return x.len == y.len and std.mem.eql(u8, x.ptr[0..x.len], y.ptr[0..y.len]);
        }
        if (a.tag == .vec and b.tag == .vec) {
            // two lambda values name one function: equal, as in valEq (F-122)
            const x = a.p.v;
            const y = b.p.v;
            if (x.closure and y.closure and x.len > 0 and y.len > 0) return strictEq(x.ptr[0], y.ptr[0]);
            return x == y;
        }
        if (a.tag == .obj and b.tag == .obj) return a.p.o == b.p.o;
        return false;
    }

    /// sort()'s order: numbers by value, strings by bytes (case-sensitive:
    /// "Abc" sorts A, b, c), a number before a string; with a column, the
    /// row's element there. Not stable, as Ring's is not (analysis 2.16).
    fn sortKey(v: Value, col: i64) Value {
        if (col >= 1 and v.tag == .vec and col <= v.p.v.len) return v.p.v.ptr[@intCast(col - 1)];
        return v;
    }
    fn sortLess(col: i64, a: Value, b: Value) bool {
        const x = sortKey(a, col);
        const y = sortKey(b, col);
        if (isNum(x) and isNum(y)) return asF64(x) < asF64(y);
        if (x.tag == .str and y.tag == .str) return std.mem.order(u8, x.p.s.ptr[0..x.p.s.len], y.p.s.ptr[0..y.p.s.len]) == .lt;
        if (isNum(x) and y.tag == .str) return true;
        return false;
    }

    fn valEq(a: Value, b: Value) bool {
        if (a.tag == .int and b.tag == .int) return a.p.i == b.p.i;
        if (a.tag == .str and b.tag == .str) {
            const x = a.p.s;
            const y = b.p.s;
            if (x.len != y.len) return false;
            return std.mem.eql(u8, x.ptr[0..x.len], y.ptr[0..y.len]);
        }
        // Ring has ONE number type -- a double -- and compares by VALUE, not
        // by how the value happens to be stored: `2.0 = 2` is true, so is
        // `4/2 = 2` (probed on 1.27, bench/exec/num_eq.ring).
        //
        // There was NO `.num` case here at all, so every equality involving a
        // non-whole number answered false: `1.5 = 1.5` was false, `if x = 1.5`
        // took the else branch, and `!=` on two equal floats answered TRUE.
        // The A/B suite never caught it because its modules compare integers.
        // Found 2026-09-12 from perf/tracing_tail, where the estate asks
        // `aT[1][:durMs] = 1.5` and got false for a value that printed 1.50.
        if (isNum(a) and isNum(b)) return asF64(a) == asF64(b);
        // Ring's implicit conversion: a numeric string equals its number.
        if (a.tag == .str and isNum(b)) return strNumEq(a.p.s, asF64(b));
        if (isNum(a) and b.tag == .str) return strNumEq(b.p.s, asF64(a));
        // Lists and objects compare by identity here; Ring answers 0 for
        // list-vs-list even when contents match (analysis 2.4).
        if (a.tag == .vec and b.tag == .vec) {
            // TWO LAMBDA VALUES ARE EQUAL WHEN THEY NAME ONE FUNCTION (F-122).
            // On Ring a lambda IS the string of its generated name, so `f3 =
            // f1` then `f1 = f3` is 1 and find() finds it; ours is the vector
            // [id + bias, captures...], and the assignment copies it, so the
            // identity test said 0. The id in slot 0 decides, as the name does
            // on Ring; what a closure captured is not part of Ring's value.
            const x = a.p.v;
            const y = b.p.v;
            if (x.closure and y.closure and x.len > 0 and y.len > 0) return valEq(x.ptr[0], y.ptr[0]);
            return x == y;
        }
        if (a.tag == .obj and b.tag == .obj) return a.p.o == b.p.o;
        return false;
    }

    /// Ring's rule (ringNumText): "" equals 0, spaces around a number are
    /// allowed, and a text that is not wholly a number equals nothing --
    /// `0 = "abc"` is false, which is the case vmexpr.c:319 guards.
    fn strNumEq(sp: *Str, n: f64) bool {
        const f = ringNumText(sp.ptr[0..sp.len]) orelse return false;
        return f == n;
    }

    /// Ring's error when `<` and friends are handed something they cannot
    /// order, measured on 1.27: a list is R21, and a non-numeric string
    /// against a number is R41 -- Ring reads the string as a number and
    /// says so when it cannot. Null when the pair is fine.
    ///
    /// Checked by the CALLER, because valCmp is a plain function and cannot
    /// reach the dispatch loop's unwind.
    fn cmpCheck(a: Value, b: Value) ?[]const u8 {
        if (a.tag == .nil or b.tag == .nil) return R24;
        if (a.tag == .vec or a.tag == .obj or b.tag == .vec or b.tag == .obj) return R21;
        if (a.tag == .str and b.tag == .str) return null;
        if (isNum(a) and isNum(b)) return null;
        const sv = if (a.tag == .str) a else b;
        _ = ringNumText(sv.p.s.ptr[0..sv.p.s.len]) orelse return R41;
        return null;
    }

    /// Ordering: numeric when both are ints, lexicographic for two
    /// strings. Anything else is a type error rather than a silent answer.
    fn valCmp(a: Value, b: Value) i32 {
        if (a.tag == .int and b.tag == .int) {
            if (a.p.i < b.p.i) return -1;
            if (a.p.i > b.p.i) return 1;
            return 0;
        }
        if (isNum(a) and isNum(b)) {
            const x = asF64(a);
            const y = asF64(b);
            if (x < y) return -1;
            if (x > y) return 1;
            return 0;
        }
        if (a.tag == .str and b.tag == .str) {
            const x = a.p.s.ptr[0..a.p.s.len];
            const y = b.p.s.ptr[0..b.p.s.len];
            return switch (std.mem.order(u8, x, y)) {
                .lt => -1,
                .gt => 1,
                .eq => 0,
            };
        }
        // A number against a numeric string orders as two numbers: `5 < "6"`
        // is 1 on 1.27. cmpCheck has already turned every text that is not a
        // number into R41, so both conversions succeed here. This line was a
        // @panic until 2026-09-23 -- cmpCheck let a numeric string through and
        // then this killed the process, inside a `try` or not.
        if ((a.tag == .str and isNum(b)) or (isNum(a) and b.tag == .str)) {
            const x = if (a.tag == .str) ringNumText(a.p.s.ptr[0..a.p.s.len]) orelse 0 else asF64(a);
            const y = if (b.tag == .str) ringNumText(b.p.s.ptr[0..b.p.s.len]) orelse 0 else asF64(b);
            if (x < y) return -1;
            if (x > y) return 1;
            return 0;
        }
        @panic("comparison: unsupported operand types");
    }

    /// `?` ends with a newline; `see` does not. Verified on 1.27, and the
    /// difference is what lets `see x + nl` build a line and a renderer
    /// repaint in place.
    /// A list's items, a line each, nested lists and objects flattened in
    /// place with no newline of their own (F-106).
    fn sayItems(self: *VM, v: Value) void {
        var i: u32 = 0;
        while (i < v.p.v.len) : (i += 1) {
            const e = v.p.v.ptr[i];
            if (e.tag == .vec) {
                self.sayItems(e);
            } else if (e.tag == .obj) {
                self.sayAttrs(e.p.o);
            } else self.sayValue(e, true);
        }
    }

    /// AN OBJECT PRINTS AS ITS ATTRIBUTES, as Ring prints one (F-106,
    /// measured on 1.27): a line `name: value` each, the name lower-cased,
    /// in the object's own order -- the parent's first, then the class's,
    /// then any addattribute() gave it -- a list attribute as `[This
    /// Attribute Contains A List]` and an object one as `Object...`. Ring++
    /// printed `<object>`; six rows of the wide suite print one.
    fn sayAttrs(self: *VM, o: *Obj) void {
        var low: [128]u8 = undefined;
        var i: u32 = 0;
        while (i < o.nslots) : (i += 1) {
            const nm = self.attrNameOf(o.class, i);
            const n = @min(nm.len, low.len);
            for (nm[0..n], 0..) |ch, k| low[k] = std.ascii.toLower(ch);
            outPrint("{s}: ", .{low[0..n]});
            self.sayAttrValue(o.slots[i]);
        }
        if (o.extra) |ex| {
            var k: u32 = 0;
            while (k + 1 < ex.len) : (k += 2) {
                const key = ex.ptr[k];
                if (key.tag == .str) outPrint("{s}: ", .{key.p.s.ptr[0..key.p.s.len]});
                self.sayAttrValue(ex.ptr[k + 1]);
            }
        }
    }

    fn sayAttrValue(self: *VM, v: Value) void {
        switch (v.tag) {
            .vec, .cptr => outPrint("[This Attribute Contains A List]\n", .{}),
            .obj => outPrint("Object...\n", .{}),
            .nil => outPrint("\n", .{}),
            else => self.sayValue(v, true),
        }
    }

    fn sayValue(self: *VM, v: Value, nl: bool) void {
        const end: []const u8 = if (nl) "\n" else "";
        switch (v.tag) {
            // Ring will not even concatenate one (R21), so nothing in the
            // estate prints it; this says what it is rather than nothing.
            .dll => outPrint("[DLL]{s}", .{end}),
            // Ring's C pointer IS a three-item list, and prints as one: the
            // address, the kind, the status -- a line each, under ? and see.
            .cptr => {
                const kind = if (v.p.i >= 0 and v.p.i < cptr_tab.items.len) cptr_tab.items[@intCast(v.p.i)].kind else "";
                outPrint("{X:0>16}\n{s}\n0\n{s}", .{ @intFromPtr(cptrOf(v)), kind, end });
            },
            .int => outPrint("{d}{s}", .{ v.p.i, end }),
            // Ring prints a whole-valued number without a point (`? 1.5*2`
            // is `3`), and otherwise to decimals() places -- 2 by default,
            // verified on 1.27 (`? 0.1+0.2` is `0.30`). decimals() being a
            // mutable process-global is §2.10's defect, not reproduced here:
            // Ring++ prints the default and does not offer the global.
            // (the bound is Ring's own, +/-(2^53-1), ring.h:120 -- it was
            // 1e15 here, which printed 1e15..2^53 with decimals)
            .num => if (v.p.d == @trunc(v.p.d) and @abs(v.p.d) <= 9007199254740991.0)
                outPrint("{d}{s}", .{ @as(i64, @intFromFloat(v.p.d)), end })
            else
                printDec(v.p.d, end),
            .str => outPrint("{s}{s}", .{ v.p.s.ptr[0..v.p.s.len], end }),
            .vec => {
                // Ring lists one element per line under both forms, a nested
                // list's in place -- and `?` then ENDS the list with its own
                // newline, a blank line after it; `see` adds none, and `? []`
                // is that newline alone (F-106, measured on 1.27). Ring++ left
                // it out, and no instrument saw it: every one of them compared
                // lines with the blank ones dropped.
                self.sayItems(v);
                outPrint("{s}", .{end});
            },
            .obj => {
                self.sayAttrs(v.p.o);
                outPrint("{s}", .{end});
            },
            .nil => outPrint("NULL{s}", .{end}),
        }
    }

    fn printDec(d: f64, end: []const u8) void {
        var b: [128]u8 = undefined;
        const t = fmtDecimals(&b, d);
        outPrint("{s}{s}", .{ t, end });
    }

    var empty_str = Str{ .ptr = "", .len = 0, .rc = 2 };

    // ---- the map index ---------------------------------------------------

    fn hindexDrop(self: *VM, v: *Vec) void {
        if (v.idx) |ix| {
            self.alloc.free(ix.slots);
            self.alloc.destroy(ix);
            v.idx = null;
        }
    }

    fn hindexInsert(ix: *HIndex, key: []const u8, pos: u32) void {
        const mask = ix.slots.len - 1;
        var s: usize = @intCast(keyHash(key) & mask);
        while (ix.slots[s] != 0) s = (s + 1) & mask;
        ix.slots[s] = pos + 1;
        ix.count += 1;
    }

    /// Slots at least 2x the pairs, so the probe chains stay short.
    fn hindexBuild(self: *VM, v: *Vec) void {
        var cap: usize = 16;
        while (cap < @as(usize, v.len) * 2) cap *= 2;
        const slots = self.alloc.alloc(u32, cap) catch @panic("oom");
        @memset(slots, 0);
        const ix = self.alloc.create(HIndex) catch @panic("oom");
        ix.* = .{ .slots = slots, .count = 0 };
        var i: u32 = 0;
        while (i < v.len) : (i += 1) {
            const e = v.ptr[i];
            if (e.tag != .vec or e.p.v.len < 2) continue;
            const kk = e.p.v.ptr[0];
            if (kk.tag != .str) continue;
            hindexInsert(ix, kk.p.s.ptr[0..kk.p.s.len], i);
        }
        v.idx = ix;
    }

    /// hfind through the index once there is one. Every hit is re-checked
    /// against the pair it names, so a slot that has gone stale can only
    /// miss, never answer wrongly.
    fn hfindFast(self: *VM, v: *Vec, key: *Str) ?u32 {
        if (v.len < HINDEX_MIN) return hfind(v, key);
        if (v.idx == null) self.hindexBuild(v);
        const ix = v.idx.?;
        const seek = key.ptr[0..key.len];
        const mask = ix.slots.len - 1;
        var s: usize = @intCast(keyHash(seek) & mask);
        while (ix.slots[s] != 0) : (s = (s + 1) & mask) {
            const pos = ix.slots[s] - 1;
            if (pos < v.len) {
                const e = v.ptr[pos];
                if (e.tag == .vec and e.p.v.len >= 2) {
                    const kk = e.p.v.ptr[0];
                    if (kk.tag == .str and std.ascii.eqlIgnoreCase(kk.p.s.ptr[0..kk.p.s.len], seek)) return pos;
                }
            }
        }
        return null;
    }

    /// An APPENDED pair joins the index in place; past half load the index
    /// is rebuilt from the vector, which already holds the new pair.
    fn hindexAdd(self: *VM, v: *Vec, key: *Str, pos: u32) void {
        const ix = v.idx orelse return;
        if ((@as(usize, ix.count) + 1) * 2 > ix.slots.len) {
            self.hindexDrop(v);
            self.hindexBuild(v);
            return;
        }
        hindexInsert(ix, key.ptr[0..key.len], pos);
    }

    /// Ring's key compare is case-insensitive -- `aH["Name"]` finds the key
    /// `:Name` stored as "name" -- while plain string `=` is case-SENSITIVE
    /// (`:Foo = "Foo"` is 0 on 1.27). Two rules for one operator.
    fn hfind(v: *Vec, key: *Str) ?u32 {
        const seek = key.ptr[0..key.len];
        var i: u32 = 0;
        while (i < v.len) : (i += 1) {
            const e = v.ptr[i];
            if (e.tag != .vec or e.p.v.len < 2) continue; // a plain element
            const kk = e.p.v.ptr[0];
            if (kk.tag != .str) continue;
            if (std.ascii.eqlIgnoreCase(kk.p.s.ptr[0..kk.p.s.len], seek)) return i;
        }
        return null;
    }

    /// Ring's truth, verified on 1.27: an empty string and an empty list
    /// are FALSE, a non-empty one is TRUE, 0 is false, an object is true.
    /// This is the "philosophy of presence" the estate's truthness
    /// narration describes -- reproduced exactly, because 300K lines
    /// depend on it, while the type-level defect (no boolean at all) is a
    /// separate verdict.
    fn truthy(v: Value) bool {
        return switch (v.tag) {
            .nil => false,
            .int => v.p.i != 0,
            .num => v.p.d != 0,
            .str => v.p.s.len != 0,
            .vec => v.p.v.len != 0,
            .obj, .dll => true,
            // a NULL pointer is FALSE -- after fclose, and after a failed open
            .cptr => cptrOf(v) != null,
        };
    }

    inline fn asInt(x: Value) i64 {
        // Ring has ONE number type and it is a double (§4.5); .int here is
        // an internal fast path, not a language-level distinction. So a
        // whole-valued double used as an index or a count is legitimate.
        if (x.tag == .int) return x.p.i;
        if (x.tag == .num) return @intFromFloat(x.p.d);
        @panic("expected a number");
    }

    inline fn isNum(x: Value) bool {
        return x.tag == .int or x.tag == .num;
    }

    inline fn asF64(x: Value) f64 {
        return switch (x.tag) {
            .int => @floatFromInt(x.p.i),
            .num => x.p.d,
            else => @panic("expected a number"),
        };
    }

    /// A double whose value is a whole number goes back on the int path.
    /// Ring cannot tell the difference -- `type()` says NUMBER either way --
    /// and it keeps indices, counts and loop bounds off the slow path.
    /// A `for` bound or step: a number stays as it is, a text converts in
    /// place by Ring's rule, anything else is `bad`. setReg releases the
    /// string the temporary held.
    fn forOperand(self: *VM, i: u32, bad: []const u8) ?[]const u8 {
        const v = self.regs[i];
        if (isNum(v)) return null;
        if (v.tag != .str) return bad;
        const f = ringNumText(v.p.s.ptr[0..v.p.s.len]) orelse return R41;
        self.setReg(i, narrow(f));
        return null;
    }

    /// A new C pointer value -- see `cptr_tab`.
    fn newCptr(self: *VM, p: ?*anyopaque, kind: []const u8) Value {
        cptr_tab.append(self.alloc, .{ .ptr = p, .kind = kind }) catch @panic("oom");
        return Value.cptrh(@intCast(cptr_tab.items.len - 1));
    }

    /// The FILE* a file function was handed, or null -- for a NULL pointer
    /// AND for a pointer of another kind, which Ring's GETCPOINTER also
    /// answers NULL for; the caller tells a non-pointer (Bad parameter
    /// type!) from those (NULL pointer).
    fn fileArg(v: Value) ?*anyopaque {
        if (v.tag != .cptr or v.p.i < 0 or v.p.i >= cptr_tab.items.len) return null;
        const e = cptr_tab.items[@intCast(v.p.i)];
        if (!std.mem.eql(u8, e.kind, "file")) return null;
        return e.ptr;
    }

    inline fn narrow(d: f64) Value {
        if (d == @trunc(d) and @abs(d) < 9.007199254740992e15) {
            return Value.int(@intFromFloat(d));
        }
        return Value.num(d);
    }

    /// RING'S NUMBERS ARE DOUBLES, and an integer here is only this VM's
    /// cheaper spelling of one -- exact while it stays within +/-(2^53-1),
    /// the range Ring itself prints as an integer (RING_LONGLONG_HIGHVALUE,
    /// vendor/ring-vm/include/ring.h:120). Past it the answer is the DOUBLE
    /// Ring computes. Measured on both 1.27 builds (bench/exec/big_int.ring):
    /// `2147483647 * 1103515245` is 2369780942852698624 there and was
    /// ...515 here, exact; seventy doublings are 1.18e21 there and were -1
    /// here, wrapped. A 32-bit LCG in plain Ring arithmetic -- the shape
    /// Softanza's tests generate their data with -- therefore gave a
    /// different sequence, and numeric_embedding a different dataset.
    ///
    /// `r` is the exact result when `ov` is 0, and its conversion to f64
    /// rounds it exactly as Ring's double operation rounds; an overflow
    /// takes the double operation itself.
    const INT_EXACT: u64 = 9007199254740991;
    /// |r| <= 2^53-1, as one unsigned compare: the hot paths' only test.
    inline fn inExact(r: i64) bool {
        return @as(u64, @bitCast(r +% @as(i64, INT_EXACT))) <= 2 * INT_EXACT;
    }
    fn intSlow(r: i64, ov: u1, x: i64, y: i64, comptime op: u8) Value {
        if (ov == 0) return Value.num(@floatFromInt(r));
        const xf: f64 = @floatFromInt(x);
        const yf: f64 = @floatFromInt(y);
        return Value.num(switch (op) {
            '+' => xf + yf,
            '-' => xf - yf,
            else => xf * yf,
        });
    }

    pub fn run(self: *VM, entry: u32) Value {
        return self.runFrom(entry, 0, 0, 0);
    }

    /// The hook's way to raise at the eval site (a compile refusal, a
    /// shape not supported): the same path an unhandled error takes.
    pub fn evalEscapePub(self: *VM, msg: []const u8) Value {
        return self.evalEscape(msg);
    }

    /// The eval hook's view of the VM: a name's index, a function by name,
    /// a value held across a sweep, and the sweep of the eval's registers.
    pub fn nameIdxPub(self: *VM, name: []const u8) ?u32 {
        return self.nameIdx(name);
    }
    pub fn funcByNamePub(self: *VM, name: []const u8) ?u32 {
        return self.funcByName(name);
    }
    pub fn holdValue(v: Value) void {
        retain(v);
    }
    pub fn newStrPub(self: *VM, bytes: []const u8) *Str {
        return self.newStr(bytes);
    }
    pub fn dropValue(self: *VM, v: Value) void {
        self.release(v);
    }
    /// Release and clear registers [from, to]: what an eval used above the
    /// caller's frame, which no frame sweep would ever reach.
    /// AN ERROR'S UNWOUND FRAMES ARE FORGOTTEN, NOT RELEASED. The frames
    /// between the handler and the error are never swept, so their registers
    /// kept what they held -- counted values, and a borrow (`ggetw`, `gattrw`,
    /// `vgetw`) a callee had open when it raised, which nothing ever counted.
    /// A later call's frame lands on those registers, and its first store
    /// that releases what it overwrites freed that borrow's list under its
    /// owner: stdlib_core's `randomitem` row after two caught raises inside
    /// library functions (2026-10-14). Cleared raw from the handler frame's
    /// top to the highest register an unwound frame reached: a counted value
    /// there is forgotten, a leak on the error path only -- the rule the try
    /// landing already states. `fsp` and `base` are the RAISING frame's, read
    /// before the landing resets them; frames[k] carries the size of the
    /// function the k-th call entered, and that function's own base is the
    /// one the next call saved (or the raiser's). The bound is computed here,
    /// on the error path, because a mark kept at every call cost the call.
    /// An eval's temporaries are inside the bound: its caller's recorded
    /// size grows for the eval's life (runEval).
    inline fn forgetUnwound(self: *VM, h: Handler, fsp: u32, base: u32) void {
        const lo: u32 = h.base + (if (h.fsp > 0) @as(u32, self.frames[h.fsp - 1].size) else 0);
        var hw = lo;
        var k = h.fsp;
        while (k < fsp) : (k += 1) {
            const own: u32 = if (k + 1 < fsp) self.frames[k + 1].base else base;
            hw = @max(hw, own + @as(u32, self.frames[k].size));
        }
        var r = lo;
        while (r < hw and r < self.regs.len) : (r += 1) self.regs[r] = Value.nil();
    }

    pub fn clearRegs(self: *VM, from: u32, to: u32) void {
        var r = from;
        while (r <= to and r < self.regs.len) : (r += 1) {
            const old = self.regs[r];
            self.regs[r] = Value.nil();
            if (RC and !DEFER) self.release(old);
        }
    }

    /// An unhandled error inside an eval: recorded, and the nested run
    /// returns to the eval opcode, which raises it in the outer loop.
    fn evalEscape(self: *VM, msg: []const u8) Value {
        if (msg.ptr != &self.pending_buf) {
            self.pending = std.fmt.bufPrint(&self.pending_buf, "{s}", .{msg}) catch msg;
        } else self.pending = msg;
        self.eval_escaped = true;
        return Value.nil();
    }

    /// Grow `code` so `n` more instructions fit, copying the frozen table
    /// with headroom the first time. The OLD buffer is never freed: the
    /// loop that called eval holds a slice of it and only ever indexes its
    /// own instructions, all below the old length -- so a grow leaks one
    /// buffer, and it happens once per doubling, not per eval.
    pub fn codeRoom(self: *VM, n: usize) void {
        const need = self.code.len + n;
        if (need <= self.code_cap) return;
        var cap = if (self.code_cap == 0) self.code.len + 65536 else self.code_cap * 2;
        while (cap < need) cap *= 2;
        const buf = self.alloc.alloc(Instr, cap) catch @panic("oom");
        @memcpy(buf[0..self.code.len], self.code);
        self.code = buf[0..self.code.len];
        self.code_cap = cap;
    }

    /// Append eval'd code; the entry is where it starts.
    pub fn appendCode(self: *VM, instrs: []const Instr) u32 {
        self.codeRoom(instrs.len);
        const at: u32 = @intCast(self.code.len);
        const buf: [*]Instr = @constCast(self.code.ptr);
        @memcpy(buf[self.code.len .. self.code.len + instrs.len], instrs);
        self.code = self.code.ptr[0 .. self.code.len + instrs.len];
        return at;
    }

    pub fn truncateCode(self: *VM, len: usize) void {
        self.code = self.code.ptr[0..len];
    }

    /// The same for the constant table: a constant eval adds is a heap
    /// string held once by the table; truncating releases it, and a
    /// variable that kept it keeps it.
    pub fn appendKonst(self: *VM, v: Value) i32 {
        if (konst.len + 1 > konst_cap) {
            var cap = if (konst_cap == 0) konst.len + 4096 else konst_cap * 2;
            while (cap < konst.len + 1) cap *= 2;
            const buf = self.alloc.alloc(Value, cap) catch @panic("oom");
            @memcpy(buf[0..konst.len], konst);
            konst = buf[0..konst.len];
            konst_cap = cap;
        }
        retain(v);
        konst = konst.ptr[0 .. konst.len + 1];
        konst[konst.len - 1] = v;
        return @intCast(konst.len - 1);
    }

    pub fn truncateKonst(self: *VM, len: usize) void {
        while (konst.len > len) {
            self.release(konst[konst.len - 1]);
            konst = konst.ptr[0 .. konst.len - 1];
        }
    }

    /// The dispatch loop, entered at `entry` with the given base and frame
    /// and handler depths: `run` for a program (all zero), eval for a
    /// string running in its caller's frame (the caller's, with
    /// `hsp_floor` at its handler depth).
    pub fn runFrom(self: *VM, entry: u32, base0: u32, fsp0: u32, hsp0: u32) Value {
        const code = self.code;
        const regs = self.regs;
        var pc: u32 = entry;
        var base: u32 = base0;
        var fsp: u32 = fsp0;
        var hsp: u32 = hsp0;

        dispatch: switch (code[pc].op) {
            .halt => {
                return regs[base + code[pc].a];
            },
            .loadi => {
                const in = code[pc];
                // b = 1: the END OF A BORROW (ggetw, gattrw, vgetw stored a
                // value they never counted), so nothing is released
                if (in.b == 1) regs[base + in.a] = Value.int(in.d) else self.setRegB(base + in.a, Value.int(in.d), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .move => {
                const in = code[pc];
                self.setRegB(base + in.a, regs[base + in.b], in.c != 0);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .add, .add_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                if (x.tag == .int and y.tag == .int) {
                    const r = x.p.i +% y.p.i;
                    if (inExact(r)) {
                        self.setRegU(base + in.a, Value.int(r), op == .add_u);
                    } else {
                        @branchHint(.cold);
                        self.setRegU(base + in.a, intSlow(r, 0, x.p.i, y.p.i, '+'), op == .add_u);
                    }
                } else if (isNum(x) and isNum(y)) {
                    self.setRegU(base + in.a, narrow(asF64(x) + asF64(y)), op == .add_u);
                } else {
                    // Not both numbers. This PANICKED, which meant every
                    // string concatenation and every list append written
                    // as an expression compiled cleanly and then died --
                    // invisible to the census, which measures compiling,
                    // and to `usable`, which measures the same thing.
                    if (self.opWant(x, y, "+", "r+")) continue :dispatch .opcall;
                    if (self.addSlow(base + in.a, base + in.b, x, y, in.d)) |e| {
                        const err = Value.str(self.newStr(e));
                        if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(e); self.dieRing(e, pc, fsp); }
                        hsp -= 1;
                        const h = self.handlers[hsp];
                        self.forgetUnwound(h, fsp, base);
                        fsp = h.fsp;
                        base = h.base;
                        self.setRegB(base + h.errreg, err, true);
                        self.noteCaught(err);
                        pc = h.catch_pc;
                        continue :dispatch code[pc].op;
                    }
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .div => {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                if (isNum(x) and isNum(y) and asF64(y) != 0) {
                    self.setRegB(base + in.a, narrow(asF64(x) / asF64(y)), false);
                } else if (self.opWant(x, y, "/", "r/")) {
                    continue :dispatch .opcall;
                } else if (self.arithSlow(base + in.a, .div, x, y)) |e| {
                    const err = Value.str(self.newStr(e));
                    if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(e); self.dieRing(e, pc, fsp); }
                    hsp -= 1;
                    const h = self.handlers[hsp];
                    self.forgetUnwound(h, fsp, base);
                    fsp = h.fsp;
                    base = h.base;
                    self.setRegB(base + h.errreg, err, true);
                    self.noteCaught(err);
                    pc = h.catch_pc;
                    continue :dispatch code[pc].op;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .sub, .sub_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                if (x.tag == .int and y.tag == .int) {
                    const r = x.p.i -% y.p.i;
                    if (inExact(r)) {
                        self.setRegU(base + in.a, Value.int(r), op == .sub_u);
                    } else {
                        @branchHint(.cold);
                        self.setRegU(base + in.a, intSlow(r, 0, x.p.i, y.p.i, '-'), op == .sub_u);
                    }
                } else if (isNum(x) and isNum(y)) {
                    self.setRegU(base + in.a, narrow(asF64(x) - asF64(y)), op == .sub_u);
                } else if (in.d == 1 and y.tag == .obj) {
                    // a UNARY minus (the compiler's `0 - x` with d = 1):
                    // Ring calls operator("neg", 0)
                    self.pend_op = .{ .recv = y, .arg = Value.int(0), .name = "neg", .kind = 1 };
                    continue :dispatch .opcall;
                } else if (self.opWant(x, y, "-", "r-")) {
                    continue :dispatch .opcall;
                } else if (self.arithSlow(base + in.a, .sub, x, y)) |e| {
                    const err = Value.str(self.newStr(e));
                    if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(e); self.dieRing(e, pc, fsp); }
                    hsp -= 1;
                    const h = self.handlers[hsp];
                    self.forgetUnwound(h, fsp, base);
                    fsp = h.fsp;
                    base = h.base;
                    self.setRegB(base + h.errreg, err, true);
                    self.noteCaught(err);
                    pc = h.catch_pc;
                    continue :dispatch code[pc].op;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .band, .bor, .bxor, .shl, .shr => |bop| {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                const aop: ArithOp = switch (bop) {
                    .band => .band,
                    .bor => .bor,
                    .bxor => .bxor,
                    .shl => .shl,
                    .shr => .shr,
                    else => unreachable,
                };
                if (isNum(x) and isNum(y)) {
                    self.setRegB(base + in.a, Value.int(bitOp(aop, asInt(x), asInt(y))), false);
                } else if (self.opWant(x, y, switch (bop) {
                    .band => "&",
                    .bor => "|",
                    .bxor => "^",
                    .shl => "<<",
                    else => ">>",
                }, switch (bop) {
                    .band => "r&",
                    .bor => "r|",
                    .bxor => "r^",
                    .shl => "r<<",
                    else => "r>>",
                })) {
                    continue :dispatch .opcall;
                } else if (self.arithSlow(base + in.a, aop, x, y)) |e| {
                    const err = Value.str(self.newStr(e));
                    if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(e); self.dieRing(e, pc, fsp); }
                    hsp -= 1;
                    const h = self.handlers[hsp];
                    self.forgetUnwound(h, fsp, base);
                    fsp = h.fsp;
                    base = h.base;
                    self.setRegB(base + h.errreg, err, true);
                    self.noteCaught(err);
                    pc = h.catch_pc;
                    continue :dispatch code[pc].op;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .mul, .mul_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                if (x.tag == .int and y.tag == .int) {
                    const rr = @mulWithOverflow(x.p.i, y.p.i);
                    if (rr[1] == 0 and inExact(rr[0])) {
                        self.setRegU(base + in.a, Value.int(rr[0]), op == .mul_u);
                    } else {
                        @branchHint(.cold);
                        self.setRegU(base + in.a, intSlow(rr[0], rr[1], x.p.i, y.p.i, '*'), op == .mul_u);
                    }
                } else if (isNum(x) and isNum(y)) {
                    self.setRegU(base + in.a, narrow(asF64(x) * asF64(y)), op == .mul_u);
                } else if (self.opWant(x, y, "*", "r*")) {
                    continue :dispatch .opcall;
                } else if (self.arithSlow(base + in.a, .mul, x, y)) |e| {
                    const err = Value.str(self.newStr(e));
                    if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(e); self.dieRing(e, pc, fsp); }
                    hsp -= 1;
                    const h = self.handlers[hsp];
                    self.forgetUnwound(h, fsp, base);
                    fsp = h.fsp;
                    base = h.base;
                    self.setRegB(base + h.errreg, err, true);
                    self.noteCaught(err);
                    pc = h.catch_pc;
                    continue :dispatch code[pc].op;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .mod => {
                const in = code[pc];
                if ((regs[base + in.b].tag == .obj or regs[base + in.c].tag == .obj) and
                    self.opWant(regs[base + in.b], regs[base + in.c], "%", "r%")) continue :dispatch .opcall;
                const x = asInt(regs[base + in.b]);
                const y = asInt(regs[base + in.c]);
                if (y == 0) {
                    self.pending = R1;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, Value.int(@rem(x, y)), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .idiv => {
                const in = code[pc];
                const xv = regs[base + in.b];
                const yv = regs[base + in.c];
                if (xv.tag != .int or yv.tag != .int) {
                    // F-129: the compiler emits this for `floor(a/b)` only
                    // when both are proved whole; should a real number still
                    // arrive, it is floor of the REAL quotient, as the builtin
                    // computes it -- never the truncated operands.
                    if (!isNum(xv) or !isNum(yv)) {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    }
                    const fy = asF64(yv);
                    if (fy == 0) {
                        self.pending = R1;
                        continue :dispatch .raise;
                    }
                    self.setRegB(base + in.a, narrow(@floor(asF64(xv) / fy)), false);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                const x = xv.p.i;
                const y = yv.p.i;
                if (y == 0) {
                    self.pending = R1;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, Value.int(@divFloor(x, y)), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .addi, .addi_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                if (x.tag != .int) {
                    // The immediate opcodes are the integer fast path, but
                    // inference cannot always prove an operand is whole --
                    // `a = 0.5` then `a * 4` lands here. Fall back rather
                    // than kill the process.
                    if (x.tag == .obj) {
                        // the compiler folds no `-` into addi when the left
                        // operand may be an object, so this is always "+".
                        // INSIDE the slow branch: checked ahead of the
                        // integer path it cost fib 23% (measured).
                        self.pend_op = .{ .recv = x, .arg = Value.int(in.d), .name = "+", .kind = 1 };
                        continue :dispatch .opcall;
                    }
                    if (!isNum(x)) {
                        // A string or a list on the left: `s + 3` is a
                        // concatenation and `aList + 3` is an append, and
                        // both used to die here.
                        // `.addi` is the folded form of a plain `+` with a constant, and
                        // `aList + 5` must still append. No compound assignment
                        // emits it: those carry the operand in a register.
                        if (self.addSlow(base + in.a, base + in.b, x, Value.int(in.d), @intFromBool(in.c != 0))) |e| {
                            const err = Value.str(self.newStr(e));
                            if (hsp == self.hsp_floor) {
                                if (self.hsp_floor != 0) return self.evalEscape(e);
                                outPrint("Error: {s}\n", .{e});
                                outFlush();
                                std.process.exit(1);
                            }
                            hsp -= 1;
                            const h = self.handlers[hsp];
                            self.forgetUnwound(h, fsp, base);
                            fsp = h.fsp;
                            base = h.base;
                            self.setRegB(base + h.errreg, err, true);
                            self.noteCaught(err);
                            pc = h.catch_pc;
                            continue :dispatch code[pc].op;
                        }
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                    self.setRegU(base + in.a, narrow(asF64(x) + @as(f64, @floatFromInt(in.d))), op == .addi_u);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                const r = x.p.i +% @as(i64, in.d);
                if (inExact(r)) {
                    self.setRegU(base + in.a, Value.int(r), op == .addi_u);
                } else {
                    @branchHint(.cold);
                    self.setRegU(base + in.a, intSlow(r, 0, x.p.i, in.d, '+'), op == .addi_u);
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .muli, .muli_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                if (x.tag != .int) {
                    // The immediate opcodes are the integer fast path, but
                    // inference cannot always prove an operand is whole --
                    // `a = 0.5` then `a * 4` lands here. Fall back rather
                    // than kill the process.
                    if (x.tag == .obj) {
                        self.pend_op = .{ .recv = x, .arg = Value.int(in.d), .name = "*", .kind = 1 };
                        continue :dispatch .opcall;
                    }
                    if (!isNum(x)) {
                        // `2 * " 3 "` is 6 on Ring: a numeric string is a
                        // number to `*`. The slow path knows the rules and
                        // raises R41/R21 where Ring does; it used to be
                        // BADPARAM here regardless (found 2026-09-11).
                        if (self.arithSlow(base + in.a, .mul, x, Value.int(in.d))) |e| {
                            self.pending = e;
                            continue :dispatch .raise;
                        }
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                    self.setRegU(base + in.a, narrow(asF64(x) * @as(f64, @floatFromInt(in.d))), op == .muli_u);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                const rr = @mulWithOverflow(x.p.i, @as(i64, in.d));
                if (rr[1] == 0 and inExact(rr[0])) {
                    self.setRegU(base + in.a, Value.int(rr[0]), op == .muli_u);
                } else {
                    @branchHint(.cold);
                    self.setRegU(base + in.a, intSlow(rr[0], rr[1], x.p.i, in.d, '*'), op == .muli_u);
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .modi, .modi_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                if (x.tag != .int) {
                    if (x.tag == .obj) {
                        self.pend_op = .{ .recv = x, .arg = Value.int(in.d), .name = "%", .kind = 1 };
                        continue :dispatch .opcall;
                    }
                    if (!isNum(x)) {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    }
                    self.setRegU(base + in.a, narrow(@rem(asF64(x), @as(f64, @floatFromInt(in.d)))), op == .modi_u);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                self.setRegU(base + in.a, Value.int(@rem(x.p.i, in.d)), op == .modi_u);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            inline .idivi, .idivi_u => |op| {
                const in = code[pc];
                const x = regs[base + in.b];
                if (x.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                self.setRegU(base + in.a, Value.int(@divFloor(x.p.i, in.d)), op == .idivi_u);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .jmp => {
                pc = self.loopStep(@intCast(code[pc].d), pc, fsp);
                continue :dispatch code[pc].op;
            },
            .jmpl => {
                const in = code[pc];
                const dw = code[pc + 1];
                if (fsp < g_ln_ovr.len) g_ln_ovr[fsp] = .{
                    .line = @as(u32, in.a) | (@as(u32, in.b) << 8) | (@as(u32, in.c) << 16),
                    .lo = @intCast(in.d),
                    // 0 until the compiler knew the region: empty, as hi < lo
                    .hi = @intCast(@max(dw.d, 0)),
                    .srow = @as(u32, dw.a) | (@as(u32, dw.b) << 8) | (@as(u32, dw.c) << 16),
                };
                pc = @intCast(in.d);
                continue :dispatch code[pc].op;
            },
            .lnhi => {
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .jlt => {
                const in = code[pc];
                // an OBJECT operand is cmpCheck's error case already, so the
                // operator dispatch lives on that path and the numbers pay
                // nothing (checked ahead of it, sieve read +24%)
                if (cmpCheck(regs[base + in.a], regs[base + in.b])) |e| {
                    if (self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) ">=" else "<", if (in.c != 0) "r>=" else "r<", in.c != 0)) continue :dispatch .opcall;
                    self.pending = e;
                    continue :dispatch .raise;
                }
                if (valCmp(regs[base + in.a], regs[base + in.b]) < 0) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jle => {
                const in = code[pc];
                if (cmpCheck(regs[base + in.a], regs[base + in.b])) |e| {
                    if (self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) ">" else "<=", if (in.c != 0) "r>" else "r<=", in.c != 0)) continue :dispatch .opcall;
                    self.pending = e;
                    continue :dispatch .raise;
                }
                if (valCmp(regs[base + in.a], regs[base + in.b]) <= 0) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jgt => {
                const in = code[pc];
                if (cmpCheck(regs[base + in.a], regs[base + in.b])) |e| {
                    if (self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) "<=" else ">", if (in.c != 0) "r<=" else "r>", in.c != 0)) continue :dispatch .opcall;
                    self.pending = e;
                    continue :dispatch .raise;
                }
                if (valCmp(regs[base + in.a], regs[base + in.b]) > 0) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jge => {
                const in = code[pc];
                if (cmpCheck(regs[base + in.a], regs[base + in.b])) |e| {
                    if (self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) "<" else ">=", if (in.c != 0) "r<" else "r>=", in.c != 0)) continue :dispatch .opcall;
                    self.pending = e;
                    continue :dispatch .raise;
                }
                if (valCmp(regs[base + in.a], regs[base + in.b]) >= 0) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jeq => {
                const in = code[pc];
                if ((regs[base + in.a].tag == .obj or regs[base + in.b].tag == .obj) and
                    self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) "!=" else "=", "", in.c != 0)) continue :dispatch .opcall;
                if (valEq(regs[base + in.a], regs[base + in.b])) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jne => {
                const in = code[pc];
                if ((regs[base + in.a].tag == .obj or regs[base + in.b].tag == .obj) and
                    self.opWantJump(regs[base + in.a], regs[base + in.b], if (in.c != 0) "=" else "!=", "", in.c != 0)) continue :dispatch .opcall;
                if (!valEq(regs[base + in.a], regs[base + in.b])) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jeqi => {
                const in = code[pc];
                if (asInt(regs[base + in.a]) == in.c) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jnei => {
                const in = code[pc];
                if (asInt(regs[base + in.a]) != in.c) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jgti => {
                const in = code[pc];
                if (asInt(regs[base + in.a]) > in.c) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .forprep => {
                const in = code[pc];
                const has_step = in.d != 0;
                // Ring's `for`, measured on 1.27 (bench/exec/for_text.ring):
                // the START must already be a number -- text, even "1", is
                // R29, and so is a list; the BOUND and the STEP convert like
                // any operand (ringNumText): "3" is 3, "" is 0, a text that is
                // not a number is R41, and a list is R29 for the bound and R28
                // for the step. All of it answered `Bad parameter type!`
                // until 2026-09-23. The bound and the step are temporaries
                // (compile.zig forStatement), so converting them in place
                // leaves the variables they were read from alone -- a bound
                // variable that held "2" still holds the STRING "2" after.
                // THE STEP IS CHECKED FIRST, then the bound, then the start
                // (F-115, 17 shapes on 1.27): `for i = :FirstRow to :LastRow`
                // is R41 from the bound, not R29 from the start.
                if (has_step) {
                    if (self.forOperand(base + in.c, R28)) |e| {
                        self.pending = e;
                        continue :dispatch .raise;
                    }
                }
                if (self.forOperand(base + in.b, R29)) |e| {
                    self.pending = e;
                    continue :dispatch .raise;
                }
                if (!isNum(regs[base + in.a])) {
                    self.pending = R29;
                    continue :dispatch .raise;
                }
                const av = &regs[base + in.a];
                const bv = &regs[base + in.b];
                const sv: Value = if (has_step) regs[base + in.c] else Value.int(1);
                if (av.tag == .int and sv.tag == .int) {
                    // an integer counter: the bound becomes an integer once, so
                    // the loop compares integers without looking at tags
                    if (bv.tag == .num) {
                        const f = if (sv.p.i >= 0) @floor(bv.p.d) else @ceil(bv.p.d);
                        bv.* = Value.int(@intFromFloat(f));
                    }
                    av.p.i -= sv.p.i;
                } else {
                    av.* = Value.num(asF64(av.*) - asF64(sv));
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .forloop => {
                const in = code[pc];
                const av = &regs[base + in.a];
                const bv = regs[base + in.b];
                if (av.tag == .int) {
                    // forprep made the bound an integer for an integer counter
                    av.p.i += 1;
                    if (av.p.i <= bv.p.i) {
                        pc = self.loopStep(@intCast(in.d), pc, fsp);
                    } else pc += 1;
                    continue :dispatch code[pc].op;
                }
                // `for i = 1.5 to 3.5` ran 1.5, 2.5, 3.5 on Ring and HUNG here: the
                // counter was stepped as an integer bit pattern (found 2026-09-11).
                if (!isNum(av.*) or !isNum(bv)) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const nx = asF64(av.*) + 1;
                av.* = narrow(nx);
                if (nx <= asF64(bv)) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .forloops => {
                const in = code[pc];
                const av = &regs[base + in.a];
                const sv = regs[base + in.c];
                const bv = regs[base + in.b];
                if (!(av.tag == .int and sv.tag == .int)) {
                    if (!isNum(av.*) or !isNum(bv) or !isNum(sv)) {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    }
                    const fstep = asF64(sv);
                    const nx = asF64(av.*) + fstep;
                    av.* = narrow(nx);
                    const fmore = if (fstep > 0) nx <= asF64(bv) else if (fstep < 0) nx >= asF64(bv) else false;
                    if (fmore) {
                        pc = self.loopStep(@intCast(in.d), pc, fsp);
                    } else pc += 1;
                    continue :dispatch code[pc].op;
                }
                const step = sv.p.i;
                av.p.i += step;
                // The test follows the SIGN of the step: `for j = 5 to 1
                // step -1` ran zero times here while Ring ran it five, and
                // Softanza's engine discovery walks a path backwards with
                // exactly that loop (stkRingLibs.ring) -- found 2026-09-09
                // on the first end-to-end run.
                // A STEP OF 0 LEAVES AT ONCE: Ring's one loop test
                // (vmjump.c ring_vm_jumpfor) exits when the step is 0, so
                // `for i = 1 to 3 step 0` runs nothing there, and here it ran
                // for ever (F-119).
                const more = if (step > 0) av.p.i <= regs[base + in.b].p.i else if (step < 0) av.p.i >= regs[base + in.b].p.i else false;
                if (more) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .vnew => {
                const in = code[pc];
                const nv = self.newVec(@intCast(in.d));
                // b = 1: the closure build (see Vec.closure)
                if (in.b != 0) nv.closure = true;
                self.setRegB(base + in.a, Value.vec(nv), in.c != 0);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vpush => {
                const in = code[pc];
                const vv = regs[base + in.a];
                if (vv.tag == .obj) {
                    // `o + item` as a STATEMENT on an object: the class's
                    // operator("+", item), its answer discarded (lkind 4)
                    self.pend_op = .{ .recv = vv, .arg = regs[base + in.b], .name = "+", .kind = 4 };
                    continue :dispatch .opcall;
                }
                if (vv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                self.vecPushB(self.cowFor(base + in.a, vv), regs[base + in.b], in.c != 0);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vget => {
                const in = code[pc];
                const vv = regs[base + in.b];
                const iv = regs[base + in.c];
                if (vv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                // A STRING index on a list is a keyed lookup -- decided at
                // run time, which is the map type's dynamic path and the one
                // panic the sweep left in place. hget's operands sit in the
                // same registers (a=dst, b=container, c=key), so it is the
                // same instruction from here on.
                if (iv.tag == .str) continue :dispatch .hget;
                if (iv.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = vv.p.v;
                const idx = iv.p.i;
                if (idx < 1 or idx > v.len) {
                    self.pending = R2;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, v.ptr[@intCast(idx - 1)], in.d != 0);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vset => {
                const in = code[pc];
                const vv = regs[base + in.a];
                const iv = regs[base + in.b];
                if (vv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                // A STRING index on a list is a keyed write: hset's operands
                // sit in the same registers (a=container, b=key, c=value).
                if (iv.tag == .str) continue :dispatch .hset;
                if (iv.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = self.cowFor(base + in.a, vv);
                // a positional write may replace a PAIR: the index is stale
                self.hindexDrop(v);
                const idx = iv.p.i;
                if (idx < 1 or idx > v.len) {
                    self.pending = R2;
                    continue :dispatch .raise;
                }
                const nv = regs[base + in.c];
                if (!TYPED or in.d != 0) {
                    retain(nv);
                    self.release(v.ptr[@intCast(idx - 1)]);
                }
                v.ptr[@intCast(idx - 1)] = nv;
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vlen => {
                const in = code[pc];
                const vv = regs[base + in.b];
                if (vv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, Value.int(vv.p.v.len), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .sgetb => {
                const in = code[pc];
                const sv = regs[base + in.b];
                const iv = regs[base + in.c];
                if (sv.tag != .str or iv.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const s = sv.p.s;
                const idx = iv.p.i;
                if (idx < 1 or idx > s.len) {
                    self.pending = R2;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, Value.int(s.ptr[@intCast(idx - 1)]), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .sgets => {
                // Ring's `s[i]`: a one-character string. The byte form above
                // stays for `ascii(s[i])`, which the compiler recognises, so
                // bytescan keeps its opcode and everything else keeps Ring.
                const in = code[pc];
                const sv = regs[base + in.b];
                const iv = regs[base + in.c];
                if (sv.tag != .str or iv.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const s = sv.p.s;
                const idx = iv.p.i;
                if (idx < 1 or idx > s.len) {
                    self.pending = R2;
                    continue :dispatch .raise;
                }
                const at: usize = @intCast(idx - 1);
                self.setRegB(base + in.a, Value.str(self.oneChar(s.ptr[at])), true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .slen => {
                const in = code[pc];
                const sv = regs[base + in.b];
                if (sv.tag != .str) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, Value.int(sv.p.s.len), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .jfalsy => {
                const in = code[pc];
                if (!truthy(regs[base + in.a])) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .jtruthy => {
                const in = code[pc];
                if (truthy(regs[base + in.a])) {
                    pc = self.loopStep(@intCast(in.d), pc, fsp);
                } else pc += 1;
                continue :dispatch code[pc].op;
            },
            .truth => {
                const in = code[pc];
                self.setRegB(base + in.a, Value.int(if (truthy(regs[base + in.b])) 1 else 0), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .lnot => {
                const in = code[pc];
                self.setRegB(base + in.a, Value.int(if (truthy(regs[base + in.b])) 0 else 1), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .say => {
                const in = code[pc];
                self.sayValue(regs[base + in.a], in.c == 0); // c=1 is `see`: no newline
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .range => {
                // `a : b`, as Ring 1.27 answers it (measured 2026-09-10 on both
                // builds, bench/exec/range.ring):
                //   numbers   start at trunc(a) and step by one while still
                //             within b -- so 5:1 is [5,4,3,2,1], 2.7:5 is
                //             [2,3,4,5] and 3:1.5 is [3,2]. It used to read
                //             hi < lo as EMPTY, and asInt a string as a panic.
                //   one-char  "0":"9" is the ten one-character strings, by
                //   strings   byte, in either direction. Softanza writes
                //             `$_acDecimalchars = "0" : "9"` at load, in
                //             stzCharData.ring:884 -- the line every engine-
                //             less run died on.
                //   else      Bad parameter type!, which is Ring's answer to
                //             1:"5" -- and Ring++'s to the shapes Ring answers
                //             inconsistently ("ab":"cd" is ["a","b"], "abc":"z"
                //             is R34, "x":5 is ["x"]). CORRECTIONS C-5.
                const in = code[pc];
                const lv = regs[base + in.b];
                const hv = regs[base + in.c];
                if (isNum(lv) and isNum(hv)) {
                    const hi_f = asF64(hv);
                    var x: i64 = @intFromFloat(@trunc(asF64(lv)));
                    const span: f64 = @abs(hi_f - @as(f64, @floatFromInt(x))) + 1;
                    const v = self.newVec(if (span < 8) 8 else @intFromFloat(span));
                    if (@as(f64, @floatFromInt(x)) <= hi_f) {
                        while (@as(f64, @floatFromInt(x)) <= hi_f) : (x += 1) self.vecPushB(v, Value.int(x), false);
                    } else {
                        while (@as(f64, @floatFromInt(x)) >= hi_f) : (x -= 1) self.vecPushB(v, Value.int(x), false);
                    }
                    self.setRegB(base + in.a, Value.vec(v), true);
                } else if (lv.tag == .str and hv.tag == .str and lv.p.s.len == 1 and hv.p.s.len == 1) {
                    const a: i32 = lv.p.s.ptr[0];
                    const b: i32 = hv.p.s.ptr[0];
                    const v = self.newVec(@intCast(@abs(b - a) + 1));
                    var c: i32 = a;
                    // RETAINED (true), as every other holder of a oneChar
                    // string is. The pin keeps the cache's copy alive only
                    // while each holder counts itself: pushed without a
                    // retain, every freed "A":"L" list released each of its
                    // strings once more than it held, the pin drained, and
                    // the cache handed out freed memory -- reassigning
                    // `o = new P("A":"L")` printed garbage and spun at exit
                    // (bench/exec/char_range_free.ring). Since 2026-09-10.
                    if (a <= b) {
                        while (c <= b) : (c += 1) self.vecPushB(v, Value.str(self.oneChar(@intCast(c))), true);
                    } else {
                        while (c >= b) : (c -= 1) self.vecPushB(v, Value.str(self.oneChar(@intCast(c))), true);
                    }
                    self.setRegB(base + in.a, Value.vec(v), true);
                } else {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .hget => {
                const in = code[pc];
                const cv = regs[base + in.b];
                const kv = regs[base + in.c];
                if (cv.tag == .obj) {
                    // `o[:key]` on an OBJECT: operator("[]", key)
                    self.pend_op = .{ .recv = cv, .arg = kv, .name = "[]", .kind = 1 };
                    continue :dispatch .opcall;
                }
                if (cv.tag != .vec or kv.tag != .str) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const at = self.hfindFast(cv.p.v, kv.p.s);
                if (at) |i| {
                    self.setRegB(base + in.a, cv.p.v.ptr[i].p.v.ptr[1], in.d != 0);
                } else {
                    // DIVERGENCE, deliberate: Ring INSERTS the key here, on a
                    // read (probed on 1.27: len 3 -> 4). Ring++ returns the
                    // empty string and leaves the list alone. See the commit.
                    self.setRegB(base + in.a, Value.str(&empty_str), in.d != 0);
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .hset => {
                const in = code[pc];
                const cv = regs[base + in.a];
                const kv = regs[base + in.b];
                if (cv.tag != .vec or kv.tag != .str) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = self.cowFor(base + in.a, cv);
                const nv = regs[base + in.c];
                if (self.hfindFast(v, kv.p.s)) |i| {
                    const pair = v.ptr[i].p.v;
                    retain(nv);
                    self.release(pair.ptr[1]);
                    pair.ptr[1] = nv;
                } else {
                    const pair = self.newVec(2);
                    self.vecPushB(pair, kv, true);
                    self.vecPushB(pair, nv, true);
                    // boxed=TRUE: the container takes a reference, exactly as
                    // it does for the key and the value. Born with rc 0 and
                    // stored without one, the pair was freed by the
                    // container's own release and underflowed the count.
                    self.vecPushB(v, Value.vec(pair), true);
                    self.hindexAdd(v, kv.p.s, v.len - 1);
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .iget => {
                // `for x in c`: the element itself (a list element by reference,
                // as Ring binds it -- measured 2026-09-11: assigning x writes the
                // list, a nested row writes through) or a string's character.
                const in = code[pc];
                const cv = regs[base + in.b];
                const iv = regs[base + in.c];
                // a fractional `step` keeps a fractional index, and Ring reads
                // the element at its integer part (F-119: step 1.5 visits
                // 1 2 4 5 7 8 10)
                const idx: i64 = switch (iv.tag) {
                    .int => iv.p.i,
                    .num => if (std.math.isFinite(iv.p.d) and @abs(iv.p.d) < 9.0e15) @intFromFloat(@trunc(iv.p.d)) else {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    },
                    else => {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    },
                };
                if (cv.tag == .vec) {
                    if (idx < 1 or idx > cv.p.v.len) {
                        self.pending = R2;
                        continue :dispatch .raise;
                    }
                    self.setRegB(base + in.a, cv.p.v.ptr[@intCast(idx - 1)], true);
                } else if (cv.tag == .str) {
                    if (idx < 1 or idx > cv.p.s.len) {
                        self.pending = R2;
                        continue :dispatch .raise;
                    }
                    self.setRegB(base + in.a, Value.str(self.oneChar(cv.p.s.ptr[@intCast(idx - 1)])), true);
                } else if (cv.tag == .obj) {
                    // `for x in o`: each item is operator("[]", i) (F-105)
                    self.pend_op = .{ .recv = cv, .arg = iv, .name = "[]", .kind = 1 };
                    continue :dispatch .opcall;
                } else {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vsetq => {
                // for-in's write-back: what the body left in x goes back into
                // the element, so `x = x * 10` in the body changes the list as
                // it does on Ring. A string container takes nothing, and nor
                // does an object: its items came from operator("[]"), and Ring
                // writes nothing back (F-105).
                const in = code[pc];
                const cv = regs[base + in.a];
                const iv = regs[base + in.b];
                // the integer part of a fractional index, as iget reads it
                const ii: i64 = switch (iv.tag) {
                    .int => iv.p.i,
                    .num => if (std.math.isFinite(iv.p.d) and @abs(iv.p.d) < 9.0e15) @intFromFloat(@trunc(iv.p.d)) else 0,
                    else => 0,
                };
                if (cv.tag == .vec and ii >= 1 and ii <= cv.p.v.len) {
                    const at: usize = @intCast(ii - 1);
                    const nv = regs[base + in.c];
                    retain(nv);
                    self.release(cv.p.v.ptr[at]);
                    cv.p.v.ptr[at] = nv;
                    self.hindexDrop(cv.p.v);
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vins => {
                // insert(list, n, item) puts item AFTER position n -- measured:
                // insert([1,2,3], 1, 9) is [1,9,2,3]; n = 0 puts it first.
                const in = code[pc];
                const cv = regs[base + in.a];
                if (cv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = cv.p.v;
                if (!isNum(regs[base + in.b])) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const pos = asInt(regs[base + in.b]);
                if (pos < 0 or pos > v.len) {
                    self.pending = BADRANGE;
                    continue :dispatch .raise;
                }
                const item = regs[base + in.c];
                self.vecPushB(v, Value.nil(), false);
                var k: u32 = v.len - 1;
                while (k > pos) : (k -= 1) v.ptr[k] = v.ptr[k - 1];
                retain(item);
                v.ptr[@intCast(pos)] = item;
                self.hindexDrop(v);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vdel => {
                const in = code[pc];
                const cv = regs[base + in.a];
                if (cv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                // A position that is not a number -- a numeric string
                // included -- is Ring's "Bad parameter type!", catchable
                // (both 1.27 builds). It panicked here, and `insert` beside
                // it already had this check: found 2026-09-30 when eight
                // natural-language tests reached a del() they used to die
                // of heap corruption before reaching.
                if (!isNum(regs[base + in.b])) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = self.cowFor(base + in.a, cv);
                const idx = asInt(regs[base + in.b]);
                if (idx < 1 or idx > v.len) {
                    self.pending = BADRANGE;
                    continue :dispatch .raise;
                }
                const at: u32 = @intCast(idx - 1);
                self.release(v.ptr[at]);
                var k: u32 = at;
                while (k + 1 < v.len) : (k += 1) v.ptr[k] = v.ptr[k + 1];
                v.len -= 1;
                // every pair after `at` just moved: the index is stale
                self.hindexDrop(v);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .sfind => {
                const in = code[pc];
                const hay = strOf(regs[base + in.b]);
                const needle = strOf(regs[base + in.c]);
                const at = std.mem.indexOf(u8, hay, needle);
                // 0 for "not found" -- a number standing for absence, in a
                // 1-indexed language. Reproduced, and flagged in §5.
                self.setRegB(base + in.a, Value.int(if (at) |p| @as(i64, @intCast(p + 1)) else 0), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .calli => {
                if (g_watchdog_at != 0) self.wdTick(pc, fsp);
                const in = code[pc];
                const cv = regs[base + in.a];
                // RING HAS TWO ANSWERS HERE and this had neither -- it
                // panicked, and three tests in the wide clock died on it.
                // Probed on 1.27, both catchable, the program running on:
                //
                //   call n()  where n is a NUMBER or a LIST
                //       Error (R32) : The CALL command expect a variable
                //       contains string
                //   call s()  where s is a STRING
                //       the string is a FUNCTION NAME. It is called, and a
                //       miss is R3 with the name.
                //
                // The estate uses the string form: a router keeps its
                // handlers by name and calls them.
                var fid: usize = 0;
                if (cv.tag == .str) {
                    const nm = strOf(cv);
                    const found = self.funcByName(nm) orelse {
                        var low: [128]u8 = undefined;
                        const n = @min(nm.len, low.len);
                        for (nm[0..n], 0..) |ch, i| low[i] = std.ascii.toLower(ch);
                        self.pending = std.fmt.bufPrint(&self.pending_buf, "Error (R3) : Calling Function without definition: {s}", .{low[0..n]}) catch "Error (R3) : Calling Function without definition";
                        continue :dispatch .raise;
                    };
                    fid = found;
                    // A NAMED function's parameters start at r0; a lambda's
                    // start at r1, because r0 carries the closure. `calli`
                    // lays the window out the lambda's way -- the callee
                    // value at `a`, the arguments after it -- so calling a
                    // named function through it needs the arguments slid
                    // down one, or every one of them arrives in the wrong
                    // register and the first parameter is the NAME. Through
                    // setRegB, so the counts stay paired.
                    const argc2: u32 = in.b;
                    var k: u32 = 0;
                    while (k < argc2) : (k += 1) {
                        self.setRegB(base + in.a + k, regs[base + in.a + k + 1], true);
                    }
                    self.setRegB(base + in.a + argc2, Value.nil(), true);
                } else if (cv.tag != .vec or cv.p.v.len == 0) {
                    self.pending = "Error (R32) : The CALL command expect a variable contains string";
                    continue :dispatch .raise;
                } else {
                    const raw = asInt(cv.p.v.ptr[0]);
                    if (cv.p.v.ptr[0].tag != .int or raw < closure_bias) {
                        // A LIST, not a closure -- Ring's R32, for the same
                        // programs Ring gives it to.
                        self.pending = "Error (R32) : The CALL command expect a variable contains string";
                        continue :dispatch .raise;
                    }
                    fid = @intCast(raw - closure_bias);
                }
                if (fid >= self.fn_entry.len) @panic("call: no such function");
                if (fsp >= max_frames_ring) {
                    self.pending = R4;
                    continue :dispatch .raise;
                }
                self.frames[fsp] = .{
                    .ret_pc = pc + 1,
                    .base = base,
                    .size = self.fn_frame[fid],
                    .mask = if (fid < fn_masks.len) fn_masks[fid] else 0,
                    .full = fid >= fn_masks.len,
                };
                fsp += 1;
                base += in.a;
                pc = self.fn_entry[fid];
                continue :dispatch code[pc].op;
            },
            .ptry => {
                const in = code[pc];
                if (hsp == self.handlers.len) @panic("handler overflow");
                self.handlers[hsp] = .{
                    .catch_pc = @intCast(in.d),
                    .fsp = fsp,
                    .base = base,
                    .errreg = in.a,
                };
                hsp += 1;
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .pend => {
                if (hsp > 0) hsp -= 1;
                pc += 1;
                continue :dispatch code[pc].op;
            },
            // The one unwind. Every type and range check in this VM reaches
            // it with `self.pending = <Ring's message>` rather than calling
            // @panic, because a panic is a crash standing where Ring raises
            // something a program can catch -- and Softanza catches these
            // and shows them to people.
            .raise => {
                const err = Value.str(self.newStr(self.pending));
                if (hsp == self.hsp_floor) { if (self.hsp_floor != 0) return self.evalEscape(self.pending); self.dieRing(self.pending, pc, fsp); }
                // SPENT once it is raised. It was never cleared while every
                // reader set it and jumped here in the same breath; the
                // first reader to set it and then LOOK -- copyv, checking
                // whether the clone gave up -- saw the last caught error
                // still sitting there and raised it again, on the next
                // object built after a caught Stack Overflow.
                self.pending = "";
                self.native_raise = false;
                self.eval_c_err = false;
                hsp -= 1;
                const h = self.handlers[hsp];
                self.forgetUnwound(h, fsp, base);
                fsp = h.fsp;
                base = h.base;
                self.setRegB(base + h.errreg, err, true);
                self.noteCaught(err);
                pc = h.catch_pc;
                continue :dispatch code[pc].op;
            },
            .trap => {
                const in = code[pc];
                const err = regs[base + in.a];
                if (hsp == self.hsp_floor) {
                    if (self.hsp_floor != 0) return self.evalEscape(if (err.tag == .str) strOf(err) else "raised");
                    // Nothing is handling it -- Ring's behaviour when
                    // nothing catches, plus the origin, which Ring prints
                    // for an uncaught error and withholds from a handler.
                    //
                    // `b` SAYS WHETHER THIS IS A raise(). Ring prints
                    // `In raise()` for its own raise() and for nothing
                    // else: an R19 from a call of the wrong arity reports
                    // `in file m13.ring` alone (probed 2026-09-22), and we
                    // printed `In raise()` on every one of them, because
                    // one opcode carries both and it always claimed the
                    // louder origin. Every error the COMPILER builds --
                    // R19/R20, a refusal, the auto-Main arity check --
                    // passes 0 now.
                    self.dieRingFrom(if (err.tag == .str) strOf(err) else "raised", pc, fsp, in.b == 1);
                }
                hsp -= 1;
                const h = self.handlers[hsp];
                self.forgetUnwound(h, fsp, base);
                // Unwind to the handler's frame. Registers are uncounted,
                // so nothing is released here for the same reason `ret`
                // releases nothing -- only the boxed slots are cleared.
                fsp = h.fsp;
                base = h.base;
                self.setRegB(base + h.errreg, err, err.tag == .str or err.tag == .vec);
                self.noteCaught(err);
                pc = h.catch_pc;
                continue :dispatch code[pc].op;
            },
            .substr2d => {
                const in = code[pc];
                const sv = strOf(regs[base + in.b]);
                const av = regs[base + in.c];
                if (av.tag == .str) {
                    // FIND: the 1-based position, 0 when absent.
                    const at = std.mem.indexOf(u8, sv, strOf(av));
                    self.setRegB(base + in.a, Value.int(if (at) |p| @as(i64, @intCast(p + 1)) else 0), false);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                if (av.tag == .int or av.tag == .num) {
                    // SUFFIX from a 1-based position. Past the end is "",
                    // not an error -- verified on 1.27.
                    const i = asInt(av);
                    const res = if (i < 1 or i > sv.len) "" else sv[@intCast(i - 1)..];
                    self.setRegB(base + in.a, Value.str(self.newStr(res)), true);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                // Neither. Ring raises here (a list gives "Bad parameter
                // type!"), so this raises, sharing trap's unwind.
                const err = konst[@intCast(in.d)];
                if (hsp == self.hsp_floor) {
                    if (self.hsp_floor != 0) return self.evalEscape(if (err.tag == .str) strOf(err) else "raised");
                    self.dieRingFrom(if (err.tag == .str) strOf(err) else "raised", pc, fsp, false);
                }
                hsp -= 1;
                const h = self.handlers[hsp];
                self.forgetUnwound(h, fsp, base);
                fsp = h.fsp;
                base = h.base;
                self.setRegB(base + h.errreg, err, err.tag == .str or err.tag == .vec);
                self.noteCaught(err);
                pc = h.catch_pc;
                continue :dispatch code[pc].op;
            },
            .clsname => {
                const in = code[pc];
                const rv = regs[base + in.b];
                if (rv.tag == .obj) {
                    const cls: usize = rv.p.o.class;
                    if (cls < class_konst.len) {
                        self.setRegB(base + in.a, konst[class_konst[cls]], true);
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                }
                // Not an object (or a class with no name recorded). Ring
                // raises here, so this raises -- answering "" would let a
                // comparison against a class name silently succeed, and a
                // wrong answer costs more than an error. Same unwind as
                // `trap`, because it IS the same event.
                const err = konst[@intCast(in.d)];
                if (hsp == self.hsp_floor) {
                    if (self.hsp_floor != 0) return self.evalEscape(if (err.tag == .str) strOf(err) else "raised");
                    self.dieRingFrom(if (err.tag == .str) strOf(err) else "raised", pc, fsp, false);
                }
                hsp -= 1;
                const h = self.handlers[hsp];
                self.forgetUnwound(h, fsp, base);
                fsp = h.fsp;
                base = h.base;
                self.setRegB(base + h.errreg, err, err.tag == .str or err.tag == .vec);
                self.noteCaught(err);
                pc = h.catch_pc;
                continue :dispatch code[pc].op;
            },
            .chkl => {
                const in = code[pc];
                if (regs[base + in.a].tag == .nil) {
                    @branchHint(.cold);
                    if (in.c == 1) {
                        // eval code reading the caller's local: its name is a
                        // string constant (the frozen name table may lack it)
                        self.r24Named(konstName(in.d));
                    } else {
                        const nd: usize = @intCast(in.d);
                        self.r24Named(if (nd < self.names.len) self.names[nd] else "?");
                    }
                    continue :dispatch .raise;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .nilr => {
                regs[base + code[pc].a] = Value.nil();
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .dvget => {
                const in = code[pc];
                const nm = konstName(in.d);
                if (in.c & 1 != 0 and regs[base].tag == .obj) {
                    if (extraAt(regs[base].p.o, nm)) |ei| {
                        self.setRegB(base + in.a, regs[base].p.o.extra.?.ptr[ei], true);
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                }
                if (self.dynRead(nm, fsp, true)) |dv| {
                    self.setRegB(base + in.a, dv, true);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                self.r24Named(nm);
                continue :dispatch .raise;
            },
            .dvset => {
                const in = code[pc];
                const nm = konstName(in.d);
                const nv = regs[base + in.a];
                const depth: u32 = if (in.c == 1) 0 else fsp;
                retain(nv);
                if (self.dynFind(depth, nm)) |i| {
                    self.release(self.dyn.items[i].val);
                    self.dyn.items[i].val = nv;
                } else {
                    const own = self.alloc.alloc(u8, nm.len) catch @panic("oom");
                    for (nm, 0..) |ch, k| own[k] = std.ascii.toLower(ch);
                    self.dyn.append(self.alloc, .{ .depth = depth, .name = own, .val = nv }) catch @panic("oom");
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .dvclr => {
                const in = code[pc];
                if (self.dyn.items.len != 0) {
                    var i: usize = 0;
                    while (i < self.dyn.items.len) {
                        if (self.dyn.items[i].depth >= fsp) {
                            const dv = self.dyn.swapRemove(i);
                            self.release(dv.val);
                            self.alloc.free(dv.name);
                        } else i += 1;
                    }
                }
                var r: u32 = 0;
                while (r < in.b) : (r += 1) regs[base + in.a + r] = Value.nil();
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .nchk => {
                const nd: usize = @intCast(code[pc].d);
                if (self.nativeOf(nd) == null) {
                    self.r3Named(self.names[nd]);
                    continue :dispatch .raise;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .ncall => {
                if (g_watchdog_at != 0) self.wdTick(pc, fsp);
                const in = code[pc];
                const nm = self.names[@intCast(in.d)];
                // `nchk` has normally found it already; a call reached
                // without one (a brace's method-miss fallback) raises the
                // same R3 here.
                const f = self.nativeOf(@intCast(in.d)) orelse {
                    self.r3Named(nm);
                    self.native_raise = false;
                    continue :dispatch .raise;
                };
                var buf: [16]native.RppVal = undefined;
                const n_args: u32 = @min(in.c, 16);
                var i: u32 = 0;
                while (i < n_args) : (i += 1) {
                    const v = regs[base + in.b + i];
                    buf[i] = switch (v.tag) {
                        .int => native.RppVal.int(v.p.i),
                        .num => native.RppVal.num(v.p.d),
                        .str => native.RppVal.str(v.p.s.ptr[0..v.p.s.len]),
                        // BORROWED for the call: the caller's register holds
                        // it, so it cannot go away while the engine reads it.
                        .vec => native.RppVal.list(v.p.v),
                        else => native.RppVal{},
                    };
                }
                var out = native.RppVal{};
                hostInstall(self);
                if (g_trace_native) {
                    outFlush();
                    // The ARGUMENTS and a RETURN marker, because the name
                    // alone could not say whether a wedged program was
                    // inside the last call or past it -- and "the trace
                    // stops at StzEngineStringFree" means two different
                    // defects depending on which.
                    std.debug.print("NCALL {s}(", .{nm});
                    var ai: u32 = 0;
                    while (ai < n_args) : (ai += 1) {
                        if (ai != 0) std.debug.print(", ", .{});
                        switch (@as(native.Tag, @enumFromInt(buf[ai].tag))) {
                            .int, .handle => std.debug.print("{d}", .{buf[ai].asInt()}),
                            .num => std.debug.print("{d}", .{buf[ai].asNum()}),
                            .str => std.debug.print("\"{s}\"", .{buf[ai].asStr()}),
                            else => std.debug.print("<{d}>", .{buf[ai].tag}),
                        }
                    }
                    std.debug.print(")\n", .{});
                }
                if (f(&buf, n_args, &out) != 0) {
                    // AN ENGINE'S ERROR IS A RING ERROR (F-103). A bridge
                    // raises with ring_vm_error and Ring reports the text as
                    // it stands -- `Line N <message>`, `In <name>()` -- and
                    // lets a `try` catch it. This ended the process with
                    // `Error: native call failed`, which no try could see and
                    // which named no cause. The message comes back in `out`,
                    // a string (src/native.zig); an engine built before that
                    // leaves `out` empty and still raises, under that line.
                    if (out.tag == @intFromEnum(native.Tag.str) and out.len > 0) {
                        self.native_err.clearRetainingCapacity();
                        self.native_err.appendSlice(self.alloc, out.asStr()) catch @panic("oom");
                        self.pending = self.native_err.items;
                    } else {
                        self.pending = std.fmt.bufPrint(&self.pending_buf, "Error: native call failed: {s}", .{nm}) catch "Error: native call failed";
                    }
                    self.native_raise = true;
                    if (g_trace_native) std.debug.print("  fail {s}: {s}\n", .{ nm, self.pending });
                    continue :dispatch .raise;
                }
                if (g_trace_native) std.debug.print("  ret {s}\n", .{nm});
                // A returned string is COPIED here, so the engine may point
                // at its own arena and reuse it the moment we return.
                const rv: Value = switch (@as(native.Tag, @enumFromInt(out.tag))) {
                    .int, .handle => Value.int(out.asInt()),
                    .num => narrow(out.asNum()),
                    .str => Value.str(self.newStr(out.asStr())),
                    .list => blk: {
                        const lv: *Vec = @ptrCast(@alignCast(out.asList() orelse break :blk Value.str(&empty_str)));
                        break :blk Value.vec(lv);
                    },
                    // `obj` is a list item's tag only (native.zig); a native
                    // that answered it answered nothing, which is NULL
                    .nil, .obj => Value.str(&empty_str),
                };
                self.setRegB(base + in.a, rv, rv.tag == .str or rv.tag == .vec);
                // The build reference the engine held (list_new) is spent:
                // the register owns the list now. Released AFTER the store,
                // so the count never touches zero in between.
                if (rv.tag == .vec) self.release(rv);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .gget => {
                const in = code[pc];
                const slot: usize = @intCast(in.d);
                // A READ OF A VARIABLE NOTHING HAS ASSIGNED is Ring's R24, at
                // the read, catchable, naming it. Raised HERE rather than by
                // whatever operator met the nil later: a comparison let it
                // through silently, a subscript called it a bad parameter,
                // and the R24 the operators did raise carried no name -- so
                // the line never matched Ring's, which is how six tests
                // differed on `Using uninitialized variable: $c`. The bit
                // tested is the one `gorc` already reads; a set global pays
                // one predictable branch.
                if (slot < self.globals_set.len and !self.globals_set[slot]) {
                    const nm = if (slot < global_names.len) global_names[slot] else "?";
                    // in a METHOD (c = 1): an attribute of that name the
                    // object gained -- F-70's class-region rule, or
                    // addattribute -- is what Ring finds before the global
                    if (in.c == 1 and regs[base].tag == .obj) {
                        if (extraAt(regs[base].p.o, nm)) |ei| {
                            self.setRegB(base + in.a, regs[base].p.o.extra.?.ptr[ei], true);
                            pc += 1;
                            continue :dispatch code[pc].op;
                        }
                    }
                    self.r24Named(nm);
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, self.globals[slot], true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .ggeta => {
                const in = code[pc];
                var nm: []const u8 = "?";
                if (in.c == 0) {
                    const slot: usize = @intCast(in.d);
                    if (slot < self.globals_set.len and self.globals_set[slot]) {
                        self.setRegB(base + in.a, self.globals[slot], true);
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                    if (slot < global_names.len) nm = global_names[slot];
                } else if (in.d >= 0 and in.d < self.names.len) {
                    nm = self.names[@intCast(in.d)];
                }
                // Ring's class-region rule (F-70): the read CREATES the
                // attribute, NULL, on the object being built (r0 = This)
                if (regs[base].tag == .obj) self.ensureExtra(regs[base].p.o, nm);
                self.setRegB(base + in.a, Value.str(self.newStr("NULL")), true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .gset => {
                const in = code[pc];
                const nv = regs[base + in.a];
                retain(nv);
                self.release(self.globals[@intCast(in.d)]);
                self.globals[@intCast(in.d)] = nv;
                self.markGlobal(@intCast(in.d));
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .isglob => {
                const in = code[pc];
                const slot: usize = @intCast(in.d);
                const yes = slot < self.globals_set.len and self.globals_set[slot];
                self.setRegB(base + in.a, Value.int(if (yes) 1 else 0), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .bcall => {
                const in = code[pc];
                const A = base + in.b; // first argument register
                const which: Builtin = @enumFromInt(@as(u16, @intCast(in.d)));
                // Builtins whose first argument MUST be a string. `strOf`
                // panics on anything else and is a plain function, so it
                // cannot reach the unwind -- the check belongs here, where
                // it can. Measured on 1.27: upper(5) is
                // "Bad parameter type!", not a crash.
                switch (which) {
                    .lower,
                    .upper,
                    .trim,
                    .left,
                    .right,
                    .copystr,
                    .strcmp,
                    .substr2,
                    .substr3,
                    .substr4,
                    .str2list,
                    .web_wait,
                    .web_bye,
                    .fexists,
                    .readf,
                    .writef,
                    .loadlib,
                    .direxists,
                    => {
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    else => {},
                }
                // And the ones whose argument must be a NUMBER. `numOf`
                // panicked on anything that was not an int or a numeric
                // string -- so a FLOAT crashed the process, which is 19 of
                // the 432 tests in the wide clock, and a list crashed it
                // where Ring raises.
                //
                // Measured on 1.27: a numeric STRING is not accepted here
                // either. `fabs("1.5")` is "Bad parameter type!", and so
                // are max("1",2), char("65") and left("hello","2"). Only
                // `number` takes a string at all.
                switch (which) {
                    .char, .fabs, .web_serve => {
                        if (!isNum(regs[A])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .max, .min => {
                        if (!isNum(regs[A]) or !isNum(regs[A + 1])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    // The maths family, measured on both 1.27 builds
                    // (2026-09-30): a string -- "16" included -- or a list
                    // is "Bad parameter type!", catchable. They panicked in
                    // asF64, and a panic cannot be caught: Softanza's
                    // semantic resolver probes stzNumber's methods inside a
                    // try, and MostSquareLikeFactors() hands sqrt() a
                    // number's string content -- eight tests died there.
                    .ceil, .floor, .sqrt, .sin, .cos, .tan, .asin, .acos, .atan,
                    .sinh, .cosh, .tanh, .log, .log10, .exp,
                    => {
                        if (!isNum(regs[A])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .atan2, .pow => {
                        if (!isNum(regs[A]) or !isNum(regs[A + 1])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .left, .right, .copystr => {
                        if (!isNum(regs[A + 1])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .number => {
                        if (!isNum(regs[A]) and regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    else => {},
                }
                var out: Value = Value.int(0);
                switch (which) {
                    .char => {
                        var one: [1]u8 = .{@intCast(@as(u8, @truncate(@as(u64, @bitCast(truncArg(regs[A]))))))};
                        out = Value.str(self.newStr(&one));
                    },
                    .sysargv => {
                        const v = self.newVec(@intCast(self.argv.len));
                        for (self.argv) |a| self.vecPush(v, Value.str(self.newStr(a)));
                        out = Value.vec(v);
                    },
                    .lower, .upper => {
                        const src = strOf(regs[A]);
                        const buf = self.alloc.alloc(u8, src.len) catch @panic("oom");
                        defer self.alloc.free(buf);
                        for (src, 0..) |ch, i| {
                            buf[i] = if (which == .lower) std.ascii.toLower(ch) else std.ascii.toUpper(ch);
                        }
                        out = Value.str(self.newStr(buf));
                    },
                    .trim => {
                        const src = strOf(regs[A]);
                        out = Value.str(self.newStr(std.mem.trim(u8, src, " \t\r\n")));
                    },
                    .left => {
                        const src = strOf(regs[A]);
                        var n: usize = @intCast(@max(0, truncArg(regs[A + 1])));
                        if (n > src.len) n = src.len;
                        out = Value.str(self.newStr(src[0..n]));
                    },
                    .right => {
                        const src = strOf(regs[A]);
                        var n: usize = @intCast(@max(0, truncArg(regs[A + 1])));
                        if (n > src.len) n = src.len;
                        out = Value.str(self.newStr(src[src.len - n ..]));
                    },
                    .copystr => {
                        const src = strOf(regs[A]);
                        const n: usize = @intCast(@max(0, truncArg(regs[A + 1])));
                        const buf = self.alloc.alloc(u8, src.len * n) catch @panic("oom");
                        defer self.alloc.free(buf);
                        var i: usize = 0;
                        while (i < n) : (i += 1) @memcpy(buf[i * src.len ..][0..src.len], src);
                        out = Value.str(self.newStr(buf));
                    },
                    // A FRACTION SURVIVES these three: fabs(-1.5) is 1.50
                    // on 1.27, not 1. They returned Value.int, so each one
                    // truncated even when it did not crash.
                    .fabs => out = narrow(@abs(asF64(regs[A]))),
                    .max => out = narrow(@max(asF64(regs[A]), asF64(regs[A + 1]))),
                    .min => out = narrow(@min(asF64(regs[A]), asF64(regs[A + 1]))),
                    // `number` is the one that takes a string, and an
                    // unparseable one is R41 -- the same answer the plus
                    // operator gives. An empty string is 0, which coerceNum
                    // already knows (measured: number("") is 0).
                    .number => {
                        if (regs[A].tag == .str) {
                            const f = coerceNum(regs[A]) orelse {
                                self.pending = R41;
                                continue :dispatch .raise;
                            };
                            out = narrow(f);
                        } else out = narrow(asF64(regs[A]));
                    },
                    // a lambda is a STRING on Ring and answers so here (Vec.closure)
                    .islist => out = Value.int(if (regs[A].tag == .vec and !regs[A].p.v.closure) 1 else 0),
                    .isstring => out = Value.int(if (regs[A].tag == .str or (regs[A].tag == .vec and regs[A].p.v.closure)) 1 else 0),
                    .isnumber => out = Value.int(if (regs[A].tag == .int or regs[A].tag == .num) 1 else 0),
                    .isnull => out = Value.int(switch (regs[A].tag) {
                        .nil => @as(i64, 1),
                        .str => @as(i64, if (regs[A].p.s.len == 0 or std.ascii.eqlIgnoreCase(strOf(regs[A]), "null")) 1 else 0),
                        else => @as(i64, 0),
                    }),
                    .ascii => {
                        // `ascii(s[i])` already holds a byte (dget on a
                        // string yields the code), while `ascii(char(65))`
                        // holds a one-character string. Both are ordinary
                        // in Ring code, so both are accepted.
                        const v = regs[A];
                        out = switch (v.tag) {
                            .int => v,
                            .str => Value.int(if (v.p.s.len == 0) 0 else v.p.s.ptr[0]),
                            else => {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            },
                        };
                    },
                    .string => {
                        // string(x): a number as Ring writes it, decimals() and
                        // all (numText); a string is itself. It went through
                        // numOf, which panicked on a float: `string(1/3)`.
                        const v = regs[A];
                        if (v.tag == .str) {
                            out = v;
                        } else if (isNum(v)) {
                            var buf: [128]u8 = undefined;
                            out = Value.str(self.newStr(numText(v, &buf)));
                        } else {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .typeof => {
                        // Ring's names, measured 2026-09-10 on both builds: 1,
                        // 1.5 and true are NUMBER; NULL is STRING (it is the
                        // empty string, the analysis's 3.1); a list is LIST; an
                        // object OBJECT. An anonymous function is STRING on Ring,
                        // and since 2026-09-24 here too: the closure vector is
                        // flagged (Vec.closure) and answers as Ring's lambda does.
                        // Softanza calls type() at 34 sites; the VM had no such
                        // builtin and the call was "without definition".
                        const nm: []const u8 = switch (regs[A].tag) {
                            .int, .num => "NUMBER",
                            .str, .nil => "STRING",
                            .vec => if (regs[A].p.v.closure) "STRING" else "LIST",
                            .obj => "OBJECT",
                            .dll => "DLL",
                            // the pointer's KIND, as Ring names it: "file"
                            .cptr => if (regs[A].p.i >= 0 and regs[A].p.i < cptr_tab.items.len) cptr_tab.items[@intCast(regs[A].p.i)].kind else "",
                        };
                        out = Value.str(self.newStr(nm));
                    },
                    .decimals => {
                        const v = regs[A];
                        const ok = isNum(v) and asF64(v) >= 0 and asF64(v) <= 90;
                        if (!ok) {
                            self.pending = "Error (R33) : Bad decimals number (correct range >= 0 and <= 90)";
                            continue :dispatch .raise;
                        }
                        g_decimals = @intFromFloat(asF64(v));
                        out = Value.str(&empty_str);
                    },
                    .find2, .find3 => |fk| {
                        const lv = regs[A];
                        const needle = regs[A + 1];
                        if (lv.tag != .vec) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const col: i64 = if (fk == .find3) (if (isNum(regs[A + 2])) asInt(regs[A + 2]) else 0) else 0;
                        var found: i64 = 0;
                        var i: u32 = 0;
                        while (i < lv.p.v.len) : (i += 1) {
                            var item = lv.p.v.ptr[i];
                            if (fk == .find3) {
                                if (item.tag != .vec or col < 1 or col > item.p.v.len) continue;
                                item = item.p.v.ptr[@intCast(col - 1)];
                            }
                            if (strictEq(item, needle)) {
                                found = i + 1;
                                break;
                            }
                        }
                        out = Value.int(found);
                    },
                    .find4 => {
                        // Ring's list-of-objects form (rlist.c:1247), rule for
                        // rule, bench/exec/find_attr.ring: a column above 0 or
                        // nothing; column 1 is the element itself, N the N-th
                        // item of a sub-list; the attribute name folded, the
                        // value compared exactly; a string only meets a string,
                        // a number a number, a list or an object the SAME one;
                        // an object without the attribute is R12 at once.
                        const lv = regs[A];
                        const needle = regs[A + 1];
                        if (lv.tag != .vec or regs[A + 3].tag != .str or
                            !(needle.tag == .str or isNum(needle) or needle.tag == .vec or needle.tag == .obj))
                        {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        if (!isNum(regs[A + 2]) or asF64(regs[A + 2]) < 0) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const col: i64 = asInt(regs[A + 2]);
                        const an = strOf(regs[A + 3]);
                        const ani = self.nameIdx(an);
                        var found: i64 = 0;
                        var i: u32 = 0;
                        while (col > 0 and i < lv.p.v.len) : (i += 1) {
                            var item = lv.p.v.ptr[i];
                            if (col > 1) {
                                if (item.tag != .vec or col > item.p.v.len) continue;
                                item = item.p.v.ptr[@intCast(col - 1)];
                            }
                            if (item.tag != .obj) continue;
                            const o = item.p.o;
                            var av: Value = undefined;
                            if (if (ani) |n| attrLookup(o.class, n) else null) |s| {
                                if (s >= o.nslots) {
                                    self.pending = "Error (R12) : Error in property name, property not found";
                                    continue :dispatch .raise;
                                }
                                av = o.slots[s];
                            } else if (extraAt(o, an)) |x| {
                                av = o.extra.?.ptr[x];
                            } else {
                                self.pending = "Error (R12) : Error in property name, property not found";
                                continue :dispatch .raise;
                            }
                            const hit = switch (needle.tag) {
                                .str => av.tag == .str and std.mem.eql(u8, strOf(av), strOf(needle)),
                                .vec => av.tag == .vec and av.p.v == needle.p.v,
                                .obj => av.tag == .obj and av.p.o == needle.p.o,
                                else => isNum(av) and asF64(av) == asF64(needle),
                            };
                            if (hit) {
                                found = i + 1;
                                break;
                            }
                        }
                        out = Value.int(found);
                    },
                    .sort1, .sort2 => |sk| {
                        const lv = regs[A];
                        if (lv.tag != .vec) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const col: i64 = if (sk == .sort2) (if (isNum(regs[A + 1])) asInt(regs[A + 1]) else 0) else 0;
                        const src = lv.p.v;
                        const nv = self.newVec(if (src.len == 0) 8 else src.len);
                        var i: u32 = 0;
                        while (i < src.len) : (i += 1) {
                            const e = self.cloneDeep(src.ptr[i]);
                            retain(e);
                            nv.ptr[i] = e;
                        }
                        nv.len = src.len;
                        std.sort.pdq(Value, nv.ptr[0..nv.len], col, sortLess);
                        out = Value.vec(nv);
                    },
                    .reverse => {
                        const v = regs[A];
                        if (v.tag == .vec) {
                            const src = v.p.v;
                            const nv = self.newVec(if (src.len == 0) 8 else src.len);
                            var i: u32 = 0;
                            while (i < src.len) : (i += 1) {
                                const e = self.cloneDeep(src.ptr[src.len - 1 - i]);
                                retain(e);
                                nv.ptr[i] = e;
                            }
                            nv.len = src.len;
                            out = Value.vec(nv);
                        } else if (v.tag == .str) {
                            const s = v.p.s.ptr[0..v.p.s.len];
                            const b = self.alloc.alloc(u8, s.len) catch @panic("oom");
                            for (s, 0..) |ch, i| b[s.len - 1 - i] = ch;
                            const sp = self.alloc.create(Str) catch @panic("oom");
                            sp.* = .{ .ptr = b.ptr, .len = @intCast(b.len), .rc = 0 };
                            out = Value.str(sp);
                        } else {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                    },
                    .isobject => out = Value.int(if (regs[A].tag == .obj) 1 else 0),
                    // Measured on 1.27 with the real engine: 0 for 5, 0,
                    // "abc", "", [1,2] and NULL; 1 for a LoadLib handle;
                    // and 0 for an ENGINE handle, which is a NUMBER there
                    // exactly as it is here.
                    .ispointer => out = Value.int(if (regs[A].tag == .dll or regs[A].tag == .cptr) 1 else 0),
                    .isalpha, .islower, .isupper, .isalnum, .isdigit, .isspace, .isgraph, .ispunct, .iscntrl, .isprint, .isxdigit => |ck| {
                        // Ring's isfunc (genlib_e.c:1227): C's test on EVERY
                        // byte, and "" is 0.
                        const v = regs[A];
                        if (v.tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = v.p.s.ptr[0..v.p.s.len];
                        var ok = s.len > 0;
                        for (s) |ch| {
                            const c = switch (ck) {
                                .isalpha => std.ascii.isAlphabetic(ch),
                                .islower => std.ascii.isLower(ch),
                                .isupper => std.ascii.isUpper(ch),
                                .isalnum => std.ascii.isAlphanumeric(ch),
                                .isspace => std.ascii.isWhitespace(ch),
                                .isgraph => ch > 0x20 and ch < 0x7f,
                                .ispunct => ch > 0x20 and ch < 0x7f and !std.ascii.isAlphanumeric(ch),
                                .iscntrl => std.ascii.isControl(ch),
                                .isprint => std.ascii.isPrint(ch),
                                .isxdigit => std.ascii.isHex(ch),
                                else => std.ascii.isDigit(ch),
                            };
                            if (!c) ok = false;
                        }
                        out = Value.int(if (ok) 1 else 0);
                    },
                    .hex => {
                        if (!isNum(regs[A])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var buf: [32]u8 = undefined;
                        const n = asInt(regs[A]);
                        const txt = std.fmt.bufPrint(&buf, "{x}", .{@as(u64, @bitCast(n))}) catch "0";
                        out = Value.str(self.newStr(txt));
                    },
                    .dec => {
                        const v = regs[A];
                        if (v.tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const n = std.fmt.parseInt(i64, v.p.s.ptr[0..v.p.s.len], 16) catch 0;
                        out = Value.int(n);
                    },
                    .removefile => {
                        // Ring's `remove` takes ONE argument and is C's remove():
                        // it deletes a FILE. Measured 2026-09-12: it returns the
                        // empty string, returns it for a file that does not exist
                        // too, and a non-string is Bad parameter type!. (A user
                        // function named Remove still wins -- findFunc is
                        // consulted before this table.)
                        const v = regs[A];
                        if (v.tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var buf: [4096]u8 = undefined;
                        const p = v.p.s.ptr[0..v.p.s.len];
                        if (p.len < buf.len) {
                            @memcpy(buf[0..p.len], p);
                            std.fs.cwd().deleteFile(buf[0..p.len]) catch {};
                        }
                        out = Value.str(&empty_str);
                    },
                    .attributes => {
                        // Ring's reflection: the attribute NAMES of an object,
                        // LOWERCASED, the parent's before the class's own, an
                        // empty list for a class that declares none (measured on
                        // both builds). The per-class table already carries the
                        // inherited entries, so slot order is the answer.
                        const v = regs[A];
                        if (v.tag != .obj) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const cls = v.p.o.class;
                        const lo = if (cls + 1 < attr_from.len) attr_from[cls] else 0;
                        const hi = if (cls + 1 < attr_from.len) attr_from[cls + 1] else 0;
                        const nv = self.newVec(if (hi > lo) hi - lo else 8);
                        var slot: u32 = 0;
                        while (slot < v.p.o.nslots) : (slot += 1) {
                            var i = lo;
                            while (i < hi) : (i += 1) {
                                if (attr_ent[i].slot != slot) continue;
                                const nm = if (attr_ent[i].name < self.names.len) self.names[attr_ent[i].name] else "";
                                var low: [128]u8 = undefined;
                                const n = @min(nm.len, low.len);
                                for (nm[0..n], 0..) |ch, k| low[k] = std.ascii.toLower(ch);
                                const e = Value.str(self.newStr(low[0..n]));
                                retain(e);
                                nv.ptr[nv.len] = e;
                                nv.len += 1;
                                break;
                            }
                        }
                        // then the attributes addattribute gave this object,
                        // in the order they were added (measured: last)
                        if (v.p.o.extra) |ex| {
                            var xi: u32 = 0;
                            while (xi + 1 < ex.len) : (xi += 2) self.vecPushB(nv, ex.ptr[xi], true);
                        }
                        out = Value.vec(nv);
                    },
                    .syssleep => {
                        if (!isNum(regs[A])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const ms = asInt(regs[A]);
                        if (ms > 0) std.Thread.sleep(@as(u64, @intCast(ms)) * std.time.ns_per_ms);
                        out = Value.str(&empty_str);
                    },
                    .filename => {
                        out = Value.str(self.newStr(if (self.argv.len > 1) self.argv[1] else ""));
                    },
                    .ceil => out = narrow(@ceil(asF64(regs[A]))),
                    .floor => out = narrow(@floor(asF64(regs[A]))),
                    .sqrt => out = narrow(@sqrt(asF64(regs[A]))),
                    .strcmp => {
                        const x = strOf(regs[A]);
                        const y = strOf(regs[A + 1]);
                        out = Value.int(switch (std.mem.order(u8, x, y)) {
                            .lt => -1,
                            .eq => 0,
                            .gt => 1,
                        });
                    },
                    .substr2 => {
                        // substr(s, n): the suffix from 1-based n. Past the
                        // end is "" -- verified, NOT an error.
                        const sv = strOf(regs[A]);
                        const i = asInt(regs[A + 1]);
                        if (i < 1 or i > sv.len) {
                            out = Value.str(self.newStr(""));
                        } else {
                            out = Value.str(self.newStr(sv[@intCast(i - 1)..]));
                        }
                    },
                    .substr3 => {
                        // The role is decided by the SECOND argument's type,
                        // at run time, exactly as Ring does it. This is the
                        // punning §5.1 measures, reproduced rather than
                        // guessed at.
                        const sv = strOf(regs[A]);
                        if (regs[A + 1].tag == .str) {
                            out = Value.str(self.newStr(self.replaceAll(sv, strOf(regs[A + 1]), strOf(regs[A + 2]))));
                        } else {
                            const i = asInt(regs[A + 1]);
                            const ln = asInt(regs[A + 2]);
                            if (i < 1 or i > sv.len or ln <= 0) {
                                out = Value.str(self.newStr(""));
                            } else {
                                const from: usize = @intCast(i - 1);
                                var to: usize = from + @as(usize, @intCast(ln));
                                if (to > sv.len) to = sv.len;
                                out = Value.str(self.newStr(sv[from..to]));
                            }
                        }
                    },
                    .fexists => {
                        const path = self.zpath(strOf(regs[A]));
                        if (std.fs.cwd().openFile(path, .{})) |f| {
                            f.close();
                            out = Value.int(1);
                        } else |_| {
                            out = Value.int(0);
                        }
                    },
                    // A FILE THAT WILL NOT OPEN IS Ring's R35, raised by the C
                    // function and CATCHABLE (file_e.c:494 and :532; F-103):
                    // `In read() In function f()`. Both ended the process here,
                    // with an `Error:` line no try could see.
                    .readf => {
                        const path = self.zpath(strOf(regs[A]));
                        const f = std.fs.cwd().openFile(path, .{}) catch {
                            self.pending = R35;
                            continue :dispatch .raise;
                        };
                        defer f.close();
                        const sz = f.getEndPos() catch 0;
                        const buf = self.alloc.alloc(u8, @intCast(sz)) catch @panic("oom");
                        defer self.alloc.free(buf);
                        const got = f.readAll(buf) catch 0;
                        out = Value.str(self.newStr(buf[0..got]));
                    },
                    .writef => {
                        // the TEXT must be a string too (file_e.c:529);
                        // strOf panics on anything else
                        if (regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const path = self.zpath(strOf(regs[A]));
                        const f = std.fs.cwd().createFile(path, .{}) catch {
                            self.pending = R35;
                            continue :dispatch .raise;
                        };
                        defer f.close();
                        f.writeAll(strOf(regs[A + 1])) catch {};
                        out = Value.str(&empty_str);
                    },
                    .loadlib => {
                        // RING EITHER ANSWERS A LIBRARY OR RAISES, and it
                        // tells its two failures apart -- dll_e.c:51 and
                        // :57. R38 when it cannot open the file at all
                        // (missing, or not a library); R46 when it opened
                        // it and found no init function. Both print
                        // `Library File : <path>` first, and both are
                        // CATCHABLE: measured on 1.27, the program runs on
                        // after the catch.
                        //
                        // THIS USED TO ANSWER NULL INSTEAD, on the grounds
                        // that Ring "has no case for you could load this
                        // and I cannot". That was wrong, and R46 is the
                        // case: Ring looks for `ringlib_init` where this VM
                        // looks for `rpp_init`, and the rest is the same
                        // situation. The one word is all we change, and the
                        // message names the symbol actually looked for
                        // rather than Ring's -- an error that lies about
                        // what it wanted is worse than one that differs.
                        //
                        // What it costs: a tree of Ring-ABI DLLs -- Mansour's
                        // own engine build -- now STOPS the program at the
                        // first load instead of routing it to the fallback.
                        // That is exactly what Ring does with a library
                        // missing its init, so the forgiving answer was
                        // never Ring's; it was ours.
                        const path = self.zpath(strOf(regs[A]));
                        // The engine is handed the host vtable HERE, so it
                        // must be filled and pointed at this VM first.
                        hostInstall(self);
                        switch (native.loadLib(self.alloc, path)) {
                            .ok => {
                                // A DLL value, not 1: Ring answers something
                                // whose type() is "DLL" and for which
                                // isPointer is true, and
                                // stzGraph._EngineAvailable() asks that.
                                libs_loaded += 1;
                                out = Value.dllh(libs_loaded);
                            },
                            // Ring cannot open it either -- a missing file,
                            // or a file that is not a library. Byte for
                            // byte Ring's answer, and catchable as Ring's.
                            .cannot_open => {
                                outPrint("\nLibrary File : {s}", .{path});
                                self.pending = "Error (R38) : Runtime Error in loading the dynamic library";
                                continue :dispatch .raise;
                            },
                            // IT OPENED AND IT IS NOT OURS -- Ring's R46,
                            // raised strictly, at Mansour's decision of
                            // 2026-09-19 with the price already measured in
                            // front of him: the wide clock goes from 159
                            // agreeing to ZERO, because `ring_libzip.dll`
                            // is Ring's own zip extension, vendored here,
                            // loaded by stzFile.ring on every Softanza
                            // program, and it carries `ringlib_init` where
                            // this VM looks for `rpp_init`.
                            //
                            // That is not a regression to be worked around.
                            // It is the FIRST commitment made visible: a
                            // Ring extension is a reach outside this
                            // repository, and answering NULL hid it behind
                            // a fallback. What Softanza's zip runs on under
                            // Ring++ is the design item in
                            // vendor/ring-ext/ringzip/NOTES.md, and this
                            // error is what makes it unavoidable.
                            //
                            // The message names `rpp_init`, the symbol this
                            // runtime actually looked for, where Ring's
                            // names `ringlib_init`. An error that lies
                            // about what it wanted is worse than one that
                            // differs by a word.
                            .no_init => {
                                outPrint("\nLibrary File : {s}", .{path});
                                self.pending = "Error (R46) : The dynamic library doesn't contain the rpp_init() function!";
                                continue :dispatch .raise;
                            },
                        }
                    },
                    .clock => out = Value.int(clock()),
                    .clockspersecond => out = Value.int(clocks_per_sec),
                    .sin => out = narrow(libm1("sin", asF64(regs[A]))),
                    .cos => out = narrow(libm1("cos", asF64(regs[A]))),
                    .tan => out = narrow(libm1("tan", asF64(regs[A]))),
                    .asin => out = narrow(libm1("asin", asF64(regs[A]))),
                    .acos => out = narrow(libm1("acos", asF64(regs[A]))),
                    .atan => out = narrow(libm1("atan", asF64(regs[A]))),
                    .atan2 => out = narrow(libm2("atan2", asF64(regs[A]), asF64(regs[A + 1]))),
                    .sinh => out = narrow(libm1("sinh", asF64(regs[A]))),
                    .cosh => out = narrow(libm1("cosh", asF64(regs[A]))),
                    .tanh => out = narrow(libm1("tanh", asF64(regs[A]))),
                    .log => out = narrow(libm1("log", asF64(regs[A]))),
                    .log10 => out = narrow(libm1("log10", asF64(regs[A]))),
                    .exp => out = narrow(libm1("exp", asF64(regs[A]))),
                    .pow => out = narrow(libm2("pow", asF64(regs[A]), asF64(regs[A + 1]))),
                    .direxists => out = Value.int(if (dirExists(self.zpath(strOf(regs[A])))) 1 else 0),
                    .currentdir => {
                        var buf: [4096]u8 = undefined;
                        const p = std.process.getCwd(&buf) catch "";
                        out = Value.str(self.newStr(p));
                    },
                    .exefolder => {
                        // Ring's ends with the separator (measured 2026-09-10 on
                        // both builds: `\`; currentdir() does NOT), and the estate
                        // spells every path from it as `exefolder() + "x"`. Found
                        // as the one character by which 80 engine-discovery
                        // warnings differed between the oracle and rnx.
                        var buf: [4096]u8 = undefined;
                        const p = std.fs.selfExeDirPath(&buf) catch "";
                        if (p.len > 0 and p.len < buf.len) {
                            buf[p.len] = std.fs.path.sep;
                            out = Value.str(self.newStr(buf[0 .. p.len + 1]));
                        } else out = Value.str(self.newStr(p));
                    },
                    .random0 => out = Value.int(rand()),
                    .random => {
                        // Ring's ring_vm_math_random, line for line: rand()
                        // FIRST -- a call that then raises has used a number
                        // up -- then rand() % (n + 1) on n cut toward zero,
                        // 0 for 0, and the NEGATED draw for a negative n
                        // (random(-5) is -4 on 1.27, where this said 0).
                        const r: i64 = rand();
                        const v = regs[A];
                        if (!isNum(v)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const n = asF64(v);
                        if (n != n or n > 2147483647.0 or n < -2147483648.0) {
                            self.pending = BADRANGE;
                            continue :dispatch .raise;
                        }
                        if (n > 0) {
                            out = Value.int(@rem(r, @as(i64, @intFromFloat(n)) + 1));
                        } else if (n == 0) {
                            out = Value.int(0);
                        } else {
                            out = Value.int(-@rem(r, @as(i64, @intFromFloat(-n)) + 1));
                        }
                    },
                    .srandom => {
                        const v = regs[A];
                        if (!isNum(v)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const n = asF64(v);
                        if (!(n >= 0 and n <= 4294967295.0)) {
                            self.pending = BADRANGE;
                            continue :dispatch .raise;
                        }
                        srand(@intFromFloat(n));
                        // Ring's srandom returns nothing: NULL, "" (F-66)
                        out = Value.str(self.newStr(""));
                    },
                    .nothing => out = Value.int(0),
                    .iswindows => out = Value.int(if (host_os == .windows) 1 else 0),
                    .iswindows64 => out = Value.int(if (host_os == .windows and @sizeOf(usize) == 8) 1 else 0),
                    .islinux => out = Value.int(if (host_os == .linux) 1 else 0),
                    .ismacosx => out = Value.int(if (host_os == .macos) 1 else 0),
                    .isfreebsd => out = Value.int(if (host_os == .freebsd) 1 else 0),
                    .isunix => out = Value.int(if (host_os == .windows) 0 else 1),
                    // Ring answers 0 for both on this host; neither is
                    // distinguishable from the target alone, so neither is
                    // invented.
                    .isandroid => out = Value.int(0),
                    .ismsdos => out = Value.int(0),
                    .version => out = Value.str(self.newStr("1.27")),
                    // Ring ends the program on `bye`, wherever it stands --
                    // inside a function, an if, a loop. Nothing unwinds and
                    // nothing after it runs.
                    .bye => {
                        outFlush();
                        std.process.exit(0);
                    },
                    .tui_init => out = Value.int(tuiInit()),
                    .tui_done => {
                        tuiDone();
                        out = Value.int(0);
                    },
                    .tui_size => {
                        const s = tuiSize();
                        const v = self.newVec(2);
                        self.vecPushB(v, Value.int(s[0]), false);
                        self.vecPushB(v, Value.int(s[1]), false);
                        out = Value.vec(v);
                    },
                    .tui_key => out = Value.str(self.newStr(tuiKey())),
                    .web_serve => out = Value.int(web.serve(@intCast(@max(0, @min(65535, truncArg(regs[A])))))),
                    .web_done => {
                        web.done();
                        out = Value.int(0);
                    },
                    .web_bye => {
                        web.bye(strOf(regs[A]));
                        out = Value.int(0);
                    },
                    .web_wait => {
                        // the page in, the browser's whole form out, as
                        // [ [name, value], ... ] in document order. An
                        // empty list means the listener is gone.
                        const v = self.newVec(4);
                        if (web.wait(strOf(regs[A]))) {
                            var i: usize = 0;
                            while (i < web.count()) : (i += 1) {
                                const pair = self.newVec(2);
                                self.vecPushB(pair, Value.str(self.newStr(web.key(i))), true);
                                self.vecPushB(pair, Value.str(self.newStr(web.value(i))), true);
                                self.vecPushB(v, Value.vec(pair), true);
                            }
                        }
                        out = Value.vec(v);
                    },
                    .giveline => {
                        // `give x`: one line of stdin, no newline, "" at EOF.
                        // Byte at a time, so nothing past the newline is
                        // consumed -- the next give, or tui_key under a
                        // pipe, must still see it.
                        var buf: [4096]u8 = undefined;
                        var n: usize = 0;
                        const stdin = std.fs.File.stdin();
                        while (n < buf.len) {
                            var one: [1]u8 = undefined;
                            const got = stdin.read(&one) catch 0;
                            if (got == 0 or one[0] == '\n') break;
                            buf[n] = one[0];
                            n += 1;
                        }
                        if (n > 0 and buf[n - 1] == '\r') n -= 1;
                        out = Value.str(self.newStr(buf[0..n]));
                    },
                    .str2list => {
                        const s = strOf(regs[A]);
                        const v = self.newVec(4);
                        var it = std.mem.splitScalar(u8, s, '\n');
                        while (it.next()) |line| {
                            self.vecPushB(v, Value.str(self.newStr(line)), true);
                        }
                        out = Value.vec(v);
                    },
                    .substr4 => {
                        const sv = strOf(regs[A]);
                        out = Value.str(self.newStr(self.replaceAll(sv, strOf(regs[A + 1]), strOf(regs[A + 2]))));
                    },
                    // ---- the system builtins, 2026-09-23 (bench/exec/sys_builtins.ring)
                    .dir => {
                        // [[name, isFolder], ...] in the OPERATING SYSTEM'S
                        // order, "." and ".." left out -- Ring's FindFirstFile
                        // loop (file_e.c:779). Names come back UTF-8, where
                        // Ring's ANSI FindFirstFile gives the code page's
                        // bytes for a non-ASCII name: Softanza's strings are
                        // UTF-8, so this is the answer it can use.
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var d = std.fs.cwd().openDir(strOf(regs[A]), .{ .iterate = true }) catch {
                            self.pending = "Error, Couldn't open the directory";
                            continue :dispatch .raise;
                        };
                        defer d.close();
                        const v = self.newVec(8);
                        var it = d.iterate();
                        while (it.next() catch null) |e| {
                            const pair = self.newVec(2);
                            self.vecPushB(pair, Value.str(self.newStr(e.name)), true);
                            self.vecPushB(pair, Value.int(if (e.kind == .directory) 1 else 0), false);
                            self.vecPushB(v, Value.vec(pair), true);
                        }
                        out = Value.vec(v);
                    },
                    .date, .time => {
                        const t = c_time.now();
                        const tm = c_time.local(&t) orelse {
                            self.pending = "Error: Timer Overflow!";
                            continue :dispatch .raise;
                        };
                        var buf: [64]u8 = undefined;
                        const n = strftime(&buf, buf.len, if (which == .date) "%d/%m/%Y" else "%H:%M:%S", tm);
                        out = Value.str(self.newStr(buf[0..n]));
                    },
                    .timelist => {
                        // Ring's 21 fields, in Ring's order (genlib_e.c:2394).
                        const t = c_time.now();
                        const tm = c_time.local(&t) orelse {
                            self.pending = "Error: Timer Overflow!";
                            continue :dispatch .raise;
                        };
                        const fmts = [_][*:0]const u8{ "%a", "%A", "%b", "%B", "%c", "%d", "%H", "%I", "%j", "%m", "%M", "%p", "%S", "%U", "%w", "%x", "%X", "%y", "%Y", "%Z", "%%" };
                        const v = self.newVec(fmts.len);
                        var buf: [128]u8 = undefined;
                        for (fmts) |f| {
                            const n = strftime(&buf, buf.len, f, tm);
                            self.vecPushB(v, Value.str(self.newStr(buf[0..n])), true);
                        }
                        out = Value.vec(v);
                    },
                    .adddays => {
                        // Ring's own day arithmetic, ported line for line
                        // (genlib_e.c:2483) -- not a calendar library's,
                        // whose answer at the edges could differ.
                        if (regs[A].tag != .str or !isNum(regs[A + 1])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = strOf(regs[A]);
                        if (!ringIsDate(s)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const dd = asF64(regs[A + 1]);
                        if (dd != dd or dd < -2147483617.0 or dd > 2147483616.0) {
                            self.pending = BADRANGE;
                            continue :dispatch .raise;
                        }
                        var day: i64 = ringDateField(s, 0, 2) + @as(i64, @intFromFloat(dd));
                        var mon: i64 = ringDateField(s, 3, 2);
                        var yr: i64 = ringDateField(s, 6, 4);
                        const dim = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
                        var n = dim[@intCast(mon - 1)];
                        if (mon == 2 and ringLeap(@intCast(yr))) n = 29;
                        while (day > n) {
                            day -= n;
                            mon += 1;
                            if (mon == 13) {
                                mon = 1;
                                yr += 1;
                            }
                            n = dim[@intCast(mon - 1)];
                            if (mon == 2 and ringLeap(@intCast(yr))) n = 29;
                        }
                        while (day < 1) {
                            mon -= 1;
                            if (mon == 0) {
                                mon = 12;
                                yr -= 1;
                            }
                            n = dim[@intCast(mon - 1)];
                            if (mon == 2 and ringLeap(@intCast(yr))) n = 29;
                            day = n - @as(i64, @intCast(@abs(day)));
                        }
                        var buf: [32]u8 = undefined;
                        const txt = std.fmt.bufPrint(&buf, "{d:0>2}/{d:0>2}/{d:0>4}", .{ @as(u64, @intCast(day)), @as(u64, @intCast(mon)), @as(u64, @intCast(@max(0, yr))) }) catch "";
                        out = Value.str(self.newStr(txt));
                    },
                    .diffdays => {
                        // Through mktime, as Ring's is (genlib_e.c:2554), so a
                        // span across a clock change rounds the way Ring's does.
                        if (regs[A].tag != .str or regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var ts: [2]i64 = undefined;
                        for ([_]u32{ 0, 1 }) |k| {
                            const s = strOf(regs[A + k]);
                            if (!ringIsDate(s)) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            var tm = CTm{};
                            tm.tm_mday = ringDateField(s, 0, 2);
                            tm.tm_mon = ringDateField(s, 3, 2) - 1;
                            tm.tm_year = ringDateField(s, 6, 4) - 1900;
                            tm.tm_isdst = -1;
                            const tv = c_time.mk(&tm);
                            if (tv == -1 or tm.tm_year > 1097) {
                                self.pending = BADRANGE;
                                continue :dispatch .raise;
                            }
                            ts[k] = tv;
                        }
                        const secs: f64 = @floatFromInt(ts[0] - ts[1]);
                        out = narrow(@ceil(@ceil(secs) / 86400.0));
                    },
                    .sysget => {
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var nb: [1024]u8 = undefined;
                        const name = cz(&nb, strOf(regs[A])) orelse {
                            out = Value.str(&empty_str);
                            self.setRegB(base + in.a, out, true);
                            pc += 1;
                            continue :dispatch code[pc].op;
                        };
                        const got = getenv(name);
                        out = if (got) |p| Value.str(self.newStr(std.mem.span(p))) else Value.str(&empty_str);
                    },
                    .sysset, .sysunset => {
                        if (regs[A].tag != .str or (which == .sysset and regs[A + 1].tag != .str)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var nb: [1024]u8 = undefined;
                        var vb: [32768]u8 = undefined;
                        const name = cz(&nb, strOf(regs[A]));
                        var ok = false;
                        if (name) |nm| {
                            if (which == .sysset) {
                                if (cz(&vb, strOf(regs[A + 1]))) |val| ok = c_env.set(nm, val) == 0;
                            } else ok = c_env.unset(nm) == 0;
                        }
                        out = Value.int(if (ok) 1 else 0);
                    },
                    .tempname => {
                        // A fresh path in the TEMP folder. Ring's Windows build
                        // answers C's tmpnam -- "\s2f4.", a name at the root of
                        // the drive, where an ordinary account often cannot
                        // write -- and Softanza writes the file it names. The
                        // temp folder is the answer it can use; on Linux Ring
                        // itself uses /tmp/ringtempXXXXXX.
                        var dirbuf: [4096]u8 = undefined;
                        var dirlen: usize = 0;
                        for ([_][*:0]const u8{ "TEMP", "TMP", "TMPDIR" }) |ev| {
                            if (getenv(ev)) |p| {
                                const s = std.mem.span(p);
                                if (s.len > 0 and s.len < dirbuf.len) {
                                    @memcpy(dirbuf[0..s.len], s);
                                    dirlen = s.len;
                                    break;
                                }
                            }
                        }
                        const dirp: []const u8 = if (dirlen > 0) dirbuf[0..dirlen] else if (is_win) "." else "/tmp";
                        var name: [4200]u8 = undefined;
                        var txt: []const u8 = "";
                        var tries: u32 = 0;
                        while (tries < 100) : (tries += 1) {
                            const r = rng.random().int(u32);
                            txt = std.fmt.bufPrint(&name, "{s}{c}ringtemp{x:0>8}", .{ dirp, std.fs.path.sep, r }) catch "";
                            if (std.fs.cwd().access(txt, .{})) |_| continue else |_| break;
                        }
                        out = Value.str(self.newStr(txt));
                    },
                    .chdir => {
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        out = Value.int(if (std.process.changeCurDir(strOf(regs[A]))) |_| 0 else |_| -1);
                    },
                    .exefilename => {
                        var buf: [4096]u8 = undefined;
                        const p = std.fs.selfExePath(&buf) catch "";
                        out = Value.str(self.newStr(p));
                    },
                    .getpathtype => {
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const p = strOf(regs[A]);
                        out = Value.int(if (std.fs.cwd().statFile(p)) |st| switch (st.kind) {
                            .file => 1,
                            .directory => 2,
                            else => -1, // RING_PATHTYPE_NOTKNOWN
                        } else |_| if (dirExists(p)) 2 else 0);
                    },
                    .windowsnl => out = Value.str(self.newStr("\r\n")),
                    .system => {
                        // C's system(), as Ring's (os_e.c:221). The command
                        // writes to OUR stdout directly, so what this program
                        // printed first is flushed first, or it would come out
                        // after the command's own output.
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = strOf(regs[A]);
                        const buf = self.alloc.alloc(u8, s.len + 1) catch @panic("oom");
                        defer self.alloc.free(buf);
                        outFlush();
                        out = Value.int(if (cz(buf, s)) |cmd| system(cmd) else -1);
                    },
                    .rename => {
                        // C's rename answers 0 or -1 and, on Windows, will not
                        // replace a file that exists; std.fs's would. So the
                        // existing target is refused first, as Ring's is.
                        if (regs[A].tag != .str or regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const from = strOf(regs[A]);
                        const to = strOf(regs[A + 1]);
                        const exists = if (std.fs.cwd().access(to, .{})) |_| true else |_| false;
                        out = Value.int(if (exists) -1 else if (std.fs.cwd().rename(from, to)) |_| 0 else |_| -1);
                    },
                    // ---- Ring's C-style file functions (bench/exec/file_stdio.ring)
                    .fopen => {
                        if (regs[A].tag != .str or regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        out = self.newCptr(ringFopen(strOf(regs[A]), strOf(regs[A + 1])), "file");
                    },
                    .tempfile => out = self.newCptr(tmpfile(), "file"),
                    .fclose, .fflush, .fgetc, .ftell, .rewind, .feof, .ferror, .clearerr, .fgetpos => {
                        const fp = fileArg(regs[A]) orelse {
                            self.pending = if (regs[A].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        switch (which) {
                            .fclose => {
                                out = Value.int(fclose(fp));
                                // Ring NULLs the argument's pointer (file_e.c:72): a
                                // second fclose raises, and `if fp` is false after.
                                cptr_tab.items[@intCast(regs[A].p.i)].ptr = null;
                            },
                            .fflush => out = Value.int(fflush(fp)),
                            .fgetc => {
                                const ch = fgetc(fp);
                                if (ch < 0) {
                                    out = Value.int(-1);
                                } else {
                                    const one = [1]u8{@intCast(ch & 0xff)};
                                    out = Value.str(self.newStr(&one));
                                }
                            },
                            .ftell => out = Value.int(ftell(fp)),
                            .rewind => {
                                rewind(fp);
                                out = Value.str(&empty_str);
                            },
                            .feof => out = Value.int(feof(fp)),
                            .ferror => out = Value.int(ferror(fp)),
                            .clearerr => {
                                clearerr(fp);
                                out = Value.str(&empty_str);
                            },
                            .fgetpos => {
                                // a C fpos_t, which Ring hands back as a pointer
                                // of kind "filepos". 32 bytes covers glibc's.
                                const pos = self.alloc.alignedAlloc(u8, .@"16", 32) catch @panic("oom");
                                const r = fgetpos(fp, @ptrCast(pos.ptr));
                                out = if (r == 0) self.newCptr(@ptrCast(pos.ptr), "filepos") else Value.int(r);
                            },
                            else => unreachable,
                        }
                    },
                    .fwrite, .fputc, .fputs, .ungetc => {
                        const fp = fileArg(regs[A]) orelse {
                            self.pending = if (regs[A].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        if (regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = strOf(regs[A + 1]);
                        switch (which) {
                            .fwrite => out = Value.int(@intCast(fwrite(s.ptr, 1, s.len, fp))),
                            .fputc, .ungetc => {
                                if (s.len == 0) {
                                    out = Value.int(0);
                                } else {
                                    const r = if (which == .fputc) fputc(s[0], fp) else ungetc(s[0], fp);
                                    out = Value.int(if (r >= 0) 1 else 0);
                                }
                            },
                            .fputs => {
                                // C's fputs stops at a NUL, as Ring's GETSTRING does
                                const n = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
                                const buf = self.alloc.alloc(u8, n + 1) catch @panic("oom");
                                defer self.alloc.free(buf);
                                @memcpy(buf[0..n], s[0..n]);
                                buf[n] = 0;
                                out = Value.int(if (fputs(@ptrCast(buf.ptr), fp) >= 0) 1 else 0);
                            },
                            else => unreachable,
                        }
                    },
                    .fread, .fgets => {
                        const fp = fileArg(regs[A]) orelse {
                            self.pending = if (regs[A].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        if (!isNum(regs[A + 1])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const nf = asF64(regs[A + 1]);
                        if (nf != nf or nf < 1 or nf > 2147483647.0) {
                            self.pending = "Buffer size must be >= 1";
                            continue :dispatch .raise;
                        }
                        const n: usize = @intFromFloat(nf);
                        const buf = self.alloc.alloc(u8, n + 1) catch @panic("oom");
                        defer self.alloc.free(buf);
                        if (which == .fread) {
                            const got = fread(buf.ptr, 1, n, fp);
                            out = if (got == 0) Value.int(0) else Value.str(self.newStr(buf[0..got]));
                        } else {
                            // fgets reads at most n-1 characters, as C's does
                            if (fgets(buf.ptr, @intCast(n), fp)) |_| {
                                const len = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse n;
                                out = Value.str(self.newStr(buf[0..len]));
                            } else out = Value.int(0);
                        }
                    },
                    .fseek => {
                        const fp = fileArg(regs[A]) orelse {
                            self.pending = if (regs[A].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        if (!isNum(regs[A + 1]) or !isNum(regs[A + 2])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const off = asF64(regs[A + 1]);
                        const wh = asF64(regs[A + 2]);
                        if (off != off or wh != wh or @abs(off) > 2147483647.0 or wh < 0 or wh > 2) {
                            self.pending = BADRANGE;
                            continue :dispatch .raise;
                        }
                        out = Value.int(fseek(fp, @intFromFloat(off), @intFromFloat(wh)));
                    },
                    .freopen => {
                        if (regs[A].tag != .str or regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const fp = fileArg(regs[A + 2]) orelse {
                            self.pending = if (regs[A + 2].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        var pb: [4096]u8 = undefined;
                        var mb: [64]u8 = undefined;
                        const pz = cz(&pb, strOf(regs[A])) orelse {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        };
                        const mz = cz(&mb, strOf(regs[A + 1])) orelse {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        };
                        out = self.newCptr(freopen(pz, mz, fp), "file");
                    },
                    .perror => {
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var sb: [4096]u8 = undefined;
                        if (cz(&sb, strOf(regs[A]))) |z| perror(z);
                        out = Value.str(&empty_str);
                    },
                    .fsetpos => {
                        const fp = fileArg(regs[A]) orelse {
                            self.pending = if (regs[A].tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        const pv = regs[A + 1];
                        const pos = if (pv.tag == .cptr and pv.p.i >= 0 and pv.p.i < cptr_tab.items.len and
                            std.mem.eql(u8, cptr_tab.items[@intCast(pv.p.i)].kind, "filepos")) cptr_tab.items[@intCast(pv.p.i)].ptr else null;
                        const pp = pos orelse {
                            self.pending = if (pv.tag == .cptr) NULLPTR else BADPARAM;
                            continue :dispatch .raise;
                        };
                        out = Value.int(fsetpos(fp, pp));
                    },
                    // ---- the small conversions (bench/exec/conv_builtins.ring)
                    .hex2str => {
                        // genlib_e.c hex2str: pairs of hex digits; a SPACE as a
                        // pair's second character stands for 0; an odd length
                        // and a non-hex digit each raise their own error.
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = strOf(regs[A]);
                        if (s.len % 2 != 0) {
                            self.pending = "Bad parameters value, error in length!";
                            continue :dispatch .raise;
                        }
                        const buf = self.alloc.alloc(u8, s.len / 2) catch @panic("oom");
                        defer self.alloc.free(buf);
                        var i: usize = 0;
                        while (i < s.len) : (i += 2) {
                            const hi = std.fmt.charToDigit(s[i], 16) catch {
                                self.pending = "Bad parameter value!";
                                continue :dispatch .raise;
                            };
                            const lo: u8 = if (s[i + 1] == ' ') 0 else std.fmt.charToDigit(s[i + 1], 16) catch {
                                self.pending = "Bad parameter value!";
                                continue :dispatch .raise;
                            };
                            buf[i / 2] = (hi << 4) | lo;
                        }
                        out = Value.str(self.newStr(buf));
                    },
                    .list2str1, .list2str2, .list2str3 => {
                        if (regs[A].tag != .vec) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const v = regs[A].p.v;
                        var from: usize = 1;
                        var to: usize = v.len;
                        if (which != .list2str1) {
                            if (!isNum(regs[A + 1])) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            const f = asF64(regs[A + 1]);
                            if (f != f or f < 1 or f > @as(f64, @floatFromInt(v.len))) {
                                self.pending = BADRANGE;
                                continue :dispatch .raise;
                            }
                            from = @intFromFloat(f);
                        }
                        if (which == .list2str3) {
                            if (!isNum(regs[A + 2])) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            const t = asF64(regs[A + 2]);
                            if (t != t or t < @as(f64, @floatFromInt(from)) or t > @as(f64, @floatFromInt(v.len))) {
                                self.pending = BADRANGE;
                                continue :dispatch .raise;
                            }
                            to = @intFromFloat(t);
                        }
                        if (v.len == 0 or from > to) {
                            if (v.len == 0 and which == .list2str1) {
                                out = Value.str(&empty_str);
                            } else {
                                self.pending = BADRANGE;
                                continue :dispatch .raise;
                            }
                        } else {
                            var acc = std.ArrayListUnmanaged(u8){};
                            defer acc.deinit(self.alloc);
                            var k = from;
                            while (k <= to) : (k += 1) {
                                const e = v.ptr[k - 1];
                                if (k > from) acc.append(self.alloc, '\n') catch @panic("oom");
                                if (e.tag == .str) {
                                    acc.appendSlice(self.alloc, e.p.s.ptr[0..e.p.s.len]) catch @panic("oom");
                                } else if (isNum(e)) {
                                    var nb: [128]u8 = undefined;
                                    acc.appendSlice(self.alloc, numText(e, &nb)) catch @panic("oom");
                                }
                            }
                            out = Value.str(self.newStr(acc.items));
                        }
                    },
                    .assert => {
                        // genlib_e.c assert: 0, "", [] and a NULL pointer FAIL
                        // (R48); an object is not a type it takes.
                        const v = regs[A];
                        const pass = switch (v.tag) {
                            .int, .num => asF64(v) != 0,
                            .str => v.p.s.len != 0,
                            .vec => v.p.v.len != 0,
                            .cptr => cptrOf(v) != null,
                            .dll => true,
                            else => {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            },
                        };
                        if (!pass) {
                            self.pending = "Error (R48) : Assertion Failed!";
                            continue :dispatch .raise;
                        }
                        out = Value.str(&empty_str);
                    },
                    .int2bytes, .float2bytes, .double2bytes => {
                        if (!isNum(regs[A])) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const f = asF64(regs[A]);
                        switch (which) {
                            .int2bytes => {
                                if (f != f or f < -2147483648.0 or f > 2147483647.0) {
                                    self.pending = BADRANGE;
                                    continue :dispatch .raise;
                                }
                                const b = std.mem.toBytes(@as(i32, @intFromFloat(f)));
                                out = Value.str(self.newStr(&b));
                            },
                            .float2bytes => {
                                const b = std.mem.toBytes(@as(f32, @floatCast(f)));
                                out = Value.str(self.newStr(&b));
                            },
                            else => {
                                const b = std.mem.toBytes(f);
                                out = Value.str(self.newStr(&b));
                            },
                        }
                    },
                    .bytes2int, .bytes2float, .bytes2double => {
                        const nbytes: usize = if (which == .bytes2double) 8 else 4;
                        if (regs[A].tag != .str or regs[A].p.s.len != nbytes) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const s = strOf(regs[A]);
                        out = switch (which) {
                            .bytes2int => Value.int(std.mem.readInt(i32, s[0..4], .little)),
                            .bytes2float => narrow(@floatCast(@as(f32, @bitCast(std.mem.readInt(u32, s[0..4], .little))))),
                            else => narrow(@bitCast(std.mem.readInt(u64, s[0..8], .little))),
                        };
                    },
                    .unsigned2, .unsigned3 => {
                        // math_e.c unsigned: 64-bit unsigned arithmetic, each
                        // number 0 .. 2^64, the operator on either side.
                        const nargs: u32 = if (which == .unsigned2) 2 else 3;
                        var nums: [2]u64 = .{ 0, 0 };
                        var nn: usize = 0;
                        var op: []const u8 = "";
                        var ops: usize = 0;
                        var k: u32 = 0;
                        while (k < nargs) : (k += 1) {
                            const v = regs[A + k];
                            if (isNum(v)) {
                                const f = asF64(v);
                                if (f != f or f < 0 or f > 18446744073709551615.0) {
                                    self.pending = BADRANGE;
                                    continue :dispatch .raise;
                                }
                                if (nn < 2) nums[nn] = @intFromFloat(@min(f, 18446744073709549568.0));
                                nn += 1;
                            } else if (v.tag == .str) {
                                op = strOf(v);
                                ops += 1;
                            } else {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                        }
                        // the operator must be first or last, the rest numbers
                        const opfirst = regs[A].tag == .str;
                        const oplast = regs[A + nargs - 1].tag == .str;
                        if (ops != 1 or !(opfirst or oplast) or nn != nargs - 1) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const a = nums[0];
                        const b = nums[1];
                        var r: u64 = 0;
                        if (which == .unsigned2) {
                            if (!std.mem.eql(u8, op, "~")) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            r = ~a;
                        } else if (std.mem.eql(u8, op, ">>") or std.mem.eql(u8, op, "<<")) {
                            if (b >= 64) {
                                self.pending = "Error (R51) : Value Error";
                                continue :dispatch .raise;
                            }
                            r = if (op[0] == '>') a >> @intCast(b) else a << @intCast(b);
                        } else if (std.mem.eql(u8, op, "+")) {
                            r = a +% b;
                        } else if (std.mem.eql(u8, op, "-")) {
                            r = a -% b;
                        } else if (std.mem.eql(u8, op, "*")) {
                            r = a *% b;
                        } else if (std.mem.eql(u8, op, "/")) {
                            if (b == 0) {
                                self.pending = R1;
                                continue :dispatch .raise;
                            }
                            r = a / b;
                        } else if (std.mem.eql(u8, op, "^")) {
                            r = a ^ b;
                        } else if (std.mem.eql(u8, op, "<")) {
                            r = @intFromBool(a < b);
                        } else if (std.mem.eql(u8, op, ">")) {
                            r = @intFromBool(a > b);
                        } else if (std.mem.eql(u8, op, "<=")) {
                            r = @intFromBool(a <= b);
                        } else if (std.mem.eql(u8, op, ">=")) {
                            r = @intFromBool(a >= b);
                        } else if (std.mem.eql(u8, op, "=")) {
                            r = @intFromBool(a == b);
                        } else if (std.mem.eql(u8, op, "!=")) {
                            r = @intFromBool(a != b);
                        } else if (std.mem.eql(u8, op, "&")) {
                            r = a & b;
                        } else if (std.mem.eql(u8, op, "|")) {
                            r = a | b;
                        } else if (std.mem.eql(u8, op, "~")) {
                            r = ~a;
                        } else {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        out = narrow(@floatFromInt(r));
                    },
                    .list1, .list2d, .newlist1, .newlist2d => {
                        // list_e.c ring_vm_listfuncs_list: each size 1 or more,
                        // else a RANGE error -- list(0) included.
                        const two = which == .list2d or which == .newlist2d;
                        if (!isNum(regs[A]) or (two and !isNum(regs[A + 1]))) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const r = asF64(regs[A]);
                        const c = if (two) asF64(regs[A + 1]) else 1;
                        if (r != r or c != c or r < 1 or c < 1 or r > 1e9 or c > 1e9 or r * c > 1e9) {
                            self.pending = BADRANGE;
                            continue :dispatch .raise;
                        }
                        const nr: u32 = @intFromFloat(r);
                        const nc: u32 = @intFromFloat(c);
                        const v = self.newVec(nr);
                        var i: u32 = 0;
                        while (i < nr) : (i += 1) {
                            if (two) {
                                const row = self.newVec(nc);
                                var j: u32 = 0;
                                while (j < nc) : (j += 1) self.vecPushB(row, Value.int(0), false);
                                self.vecPushB(v, Value.vec(row), true);
                            } else self.vecPushB(v, Value.int(0), false);
                        }
                        out = Value.vec(v);
                    },
                    // ---- reflection (bench/exec/reflect.ring)
                    .ismethod, .isattribute, .getattribute, .setattribute => {
                        const ov = regs[A];
                        if (ov.tag != .obj or regs[A + 1].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const cls = ov.p.o.class;
                        const ni = self.nameIdx(strOf(regs[A + 1]));
                        if (which == .ismethod) {
                            var has = false;
                            if (ni) |n| {
                                const key = @as(u32, cls) * n_names + n;
                                has = key < dispatch.len and dispatch[key] != 0;
                            }
                            if (!has) {
                                for (dyn_methods.items) |dm| {
                                    if (dm.cls == cls and std.ascii.eqlIgnoreCase(dm.name, strOf(regs[A + 1]))) has = true;
                                }
                            }
                            out = Value.int(if (has) 1 else 0);
                        } else {
                            const sl: ?u32 = if (ni) |n| attrLookup(cls, n) else null;
                            const xi: ?u32 = if (sl == null) extraAt(ov.p.o, strOf(regs[A + 1])) else null;
                            if (which == .isattribute) {
                                out = Value.int(if (sl != null or xi != null) 1 else 0);
                            } else if (xi) |x| {
                                const ex = ov.p.o.extra.?;
                                if (which == .getattribute) {
                                    out = ex.ptr[x];
                                } else {
                                    const nv = regs[A + 2];
                                    retain(nv);
                                    self.release(ex.ptr[x]);
                                    ex.ptr[x] = nv;
                                    out = Value.str(&empty_str);
                                }
                            } else {
                                // Ring's getattribute/setattribute miss is R12
                                // WITHOUT the name, where `o.nope` names it --
                                // both measured on 1.27.
                                const s = sl orelse {
                                    self.pending = "Error (R12) : Error in property name, property not found";
                                    continue :dispatch .raise;
                                };
                                if (s >= ov.p.o.nslots) {
                                    self.pending = "Error (R12) : Error in property name, property not found";
                                    continue :dispatch .raise;
                                }
                                if (which == .getattribute) {
                                    out = ov.p.o.slots[s];
                                    if (out.tag == .nil) out = Value.str(&empty_str);
                                } else {
                                    const nv = regs[A + 2];
                                    retain(nv);
                                    self.release(ov.p.o.slots[s]);
                                    ov.p.o.slots[s] = nv;
                                    out = Value.str(&empty_str);
                                }
                            }
                        }
                    },
                    .methods => {
                        // Ring's order: the class's OWN methods in definition
                        // order, then its parent's that it did not redefine,
                        // and up -- `attributes` is the other way round.
                        const ov = regs[A];
                        if (ov.tag != .obj) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const v = self.newVec(8);
                        var seen = std.StringHashMapUnmanaged(void){};
                        defer seen.deinit(self.alloc);
                        var k: u16 = ov.p.o.class;
                        var guard: u32 = 0;
                        while (k != 0xFFFF and guard < 64) : (guard += 1) {
                            for (fn_owner, 0..) |owner, fid| {
                                if (owner != k or fid >= self.fn_names.len) continue;
                                var nb: [256]u8 = undefined;
                                const nm = reflectName(self.fn_names[fid], &nb) orelse continue;
                                if (seen.contains(nm)) continue;
                                const key = self.alloc.dupe(u8, nm) catch @panic("oom");
                                seen.put(self.alloc, key, {}) catch @panic("oom");
                                self.vecPushB(v, Value.str(self.newStr(nm)), true);
                            }
                            // then what addmethod attached to this class (measured:
                            // after the class's own, before the parent's)
                            for (dyn_methods.items) |dm| {
                                if (dm.cls != k or seen.contains(dm.name)) continue;
                                const key = self.alloc.dupe(u8, dm.name) catch @panic("oom");
                                seen.put(self.alloc, key, {}) catch @panic("oom");
                                self.vecPushB(v, Value.str(self.newStr(dm.name)), true);
                            }
                            k = if (k < class_parent.len) class_parent[k] else 0xFFFF;
                        }
                        var it = seen.keyIterator();
                        while (it.next()) |kp| self.alloc.free(kp.*);
                        out = Value.vec(v);
                    },
                    .eval => {
                        // eval(code): the string compiled at run time and run in
                        // THIS frame (F-72, C-9 revised) by the hook rnxc.zig
                        // registers; a VM without one answers Ring's R3. The
                        // hook runs the code through runFrom with the handler
                        // floor at this depth; an error nothing inside caught
                        // comes back as `eval_escaped`, and is raised here --
                        // so the caller's own try catches it, as on Ring.
                        if (regs[A].tag != .str) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const hook = self.eval_hook orelse {
                            self.pending = "Error (R3) : Calling Function without definition: eval";
                            continue :dispatch .raise;
                        };
                        const caller: u32 = if (pc < self.fn_of.len) self.fn_of[pc] else EVAL_NESTED;
                        // where the eval'd code's own lines are reported
                        // (sitePc); popped on every way back here, and an
                        // error that dies inside never comes back
                        const pushed = self.eval_nsites < self.eval_sites.len;
                        if (pushed) {
                            self.eval_sites[self.eval_nsites] = .{ .pc = pc, .fsp = fsp };
                            self.eval_nsites += 1;
                        }
                        const v = hook(self, strOf(regs[A]), caller, base, fsp, hsp);
                        if (pushed) self.eval_nsites -= 1;
                        if (self.eval_escaped) {
                            self.eval_escaped = false;
                            continue :dispatch .raise;
                        }
                        // the hook hands the value back HELD once (it had to
                        // survive the sweep of the eval's registers); the
                        // store takes its own reference and the hold is
                        // dropped, so dst owns exactly one
                        self.setRegB(base + in.a, v, true);
                        self.release(v);
                        pc += 1;
                        continue :dispatch code[pc].op;
                    },
                    .catchlast => {
                        if (self.catch_last.tag == .nil) {
                            out = Value.str(self.newStr("NULL"));
                        } else {
                            retain(self.catch_last);
                            out = self.catch_last;
                        }
                    },
                    .isfunction => {
                        // A LAMBDA IS 1, measured on 1.27: `f = func { }` then
                        // isfunction(f) -- the string names a generated function.
                        // Here the closure vector (Vec.closure). It raised "Bad
                        // parameter type!" on every Softanza watcher and computed
                        // attribute until 2026-09-24 (bench/exec/lambda_value.ring).
                        if (regs[A].tag == .vec and regs[A].p.v.closure) {
                            out = Value.int(1);
                        } else {
                            if (regs[A].tag != .str) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            // a USER function -- `isfunction("len")` is 0 on 1.27
                            var has = false;
                            if (self.funcByName(strOf(regs[A]))) |fid| {
                                const is_m = fid < self.fn_method.len and self.fn_method[fid];
                                has = !is_m and fid < self.fn_names.len and self.fn_names[fid].len > 0 and !std.mem.startsWith(u8, self.fn_names[fid], "@@");
                            }
                            out = Value.int(if (has) 1 else 0);
                        }
                    },
                    .functions => {
                        const v = self.newVec(64);
                        var seen = std.StringHashMapUnmanaged(void){};
                        defer seen.deinit(self.alloc);
                        for (self.fn_names, 0..) |fnm, fid| {
                            if (fid < self.fn_method.len and self.fn_method[fid]) continue;
                            if (fid < fn_owner.len and fn_owner[fid] != 0xFFFF) continue;
                            var nb: [256]u8 = undefined;
                            const nm = reflectName(fnm, &nb) orelse continue;
                            if (seen.contains(nm)) continue;
                            const key = self.alloc.dupe(u8, nm) catch @panic("oom");
                            seen.put(self.alloc, key, {}) catch @panic("oom");
                            self.vecPushB(v, Value.str(self.newStr(nm)), true);
                        }
                        var it = seen.keyIterator();
                        while (it.next()) |kp| self.alloc.free(kp.*);
                        out = Value.vec(v);
                    },
                    .classes => {
                        const v = self.newVec(@intCast(@max(1, class_konst.len)));
                        for (class_konst) |ki| {
                            if (ki < konst.len) self.vecPushB(v, konst[ki], true);
                        }
                        out = Value.vec(v);
                    },
                    .globals => {
                        // Ring's globals() is DYNAMIC: the globals created so
                        // far, lower-cased -- one name at a program's first
                        // statement (measured). So only the slots already SET.
                        const v = self.newVec(16);
                        for (global_names, 0..) |gn, gi| {
                            if (gi >= self.globals_set.len or !self.globals_set[gi]) continue;
                            var nb: [256]u8 = undefined;
                            if (gn.len == 0 or gn.len > nb.len) continue;
                            for (gn, 0..) |ch, i| nb[i] = std.ascii.toLower(ch);
                            self.vecPushB(v, Value.str(self.newStr(nb[0..gn.len])), true);
                        }
                        out = Value.vec(v);
                    },
                    .prevfilename => {
                        // Ring answers its cPrevFileName: the file execution
                        // came FROM. Here: the caller's file inside a function,
                        // the current file at the top level.
                        const at: u32 = if (fsp > 0) self.frames[fsp - 1].ret_pc -| 1 else pc;
                        const fi = if (at < self.files.len) self.files[at] else 0;
                        out = Value.str(self.newStr(std.fs.path.basename(self.fileName(fi))));
                    },
                    .packages => out = Value.vec(self.newVec(1)),
                    .addattribute => {
                        // PER OBJECT (measured: another instance of the class
                        // does not get it). A name or a list of names; one the
                        // object already has is left alone. The new attribute
                        // starts as NULL, the empty string.
                        const ov = regs[A];
                        const nv = regs[A + 1];
                        if (ov.tag != .obj or (nv.tag != .str and nv.tag != .vec)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        const o = ov.p.o;
                        const count: u32 = if (nv.tag == .str) 1 else nv.p.v.len;
                        var k: u32 = 0;
                        while (k < count) : (k += 1) {
                            const one = if (nv.tag == .str) nv else nv.p.v.ptr[k];
                            if (one.tag != .str) {
                                self.pending = BADPARAM;
                                continue :dispatch .raise;
                            }
                            self.ensureExtra(o, strOf(one));
                        }
                        out = Value.str(&empty_str);
                    },
                    .addmethod => {
                        // For the whole CLASS (measured: another object has it
                        // too). The target is a PLAIN function's name or an
                        // anonymous function; a METHOD's name, or a name that
                        // is nothing, does nothing at all -- Ring raises nothing
                        // and adds nothing, so an alias made that way is an R14
                        // when it is called, on both runtimes.
                        const ov = regs[A];
                        const nv = regs[A + 1];
                        const tv = regs[A + 2];
                        if (ov.tag != .obj or nv.tag != .str or (tv.tag != .str and tv.tag != .vec)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        var fid: ?u32 = null;
                        var shift = false;
                        if (tv.tag == .str) {
                            if (self.funcByName(strOf(tv))) |f| {
                                const is_m = f < self.fn_method.len and self.fn_method[f];
                                if (!is_m) {
                                    fid = f;
                                    shift = true;
                                }
                            }
                        } else if (tv.p.v.len >= 1 and tv.p.v.ptr[0].tag == .int) {
                            // a closure: [biased id, captures...]. Its parameters
                            // already start at r1, behind a method's receiver.
                            const raw = tv.p.v.ptr[0].p.i - closure_bias;
                            if (raw >= 0 and raw < self.fn_entry.len) fid = @intCast(raw);
                        }
                        if (fid) |f| {
                            const cls = ov.p.o.class;
                            const nt = self.alloc.alloc(MethodEnt, method_tab.len + 1) catch @panic("oom");
                            @memcpy(nt[0..method_tab.len], method_tab);
                            nt[method_tab.len] = .{ .entry = self.fn_entry[f], .frame = self.fn_frame[f], .id = NO_MASK, .shift = shift };
                            method_tab = nt;
                            const slot: u32 = @intCast(method_tab.len);
                            if (self.nameIdx(strOf(nv))) |ni| {
                                const key = @as(u32, cls) * n_names + ni;
                                if (key < dispatch.len) dispatch[key] = slot;
                            }
                            var lb: [256]u8 = undefined;
                            const nm = strOf(nv);
                            const n = @min(nm.len, lb.len);
                            for (nm[0..n], 0..) |ch, i| lb[i] = std.ascii.toLower(ch);
                            dyn_methods.append(self.alloc, .{ .cls = cls, .name = self.alloc.dupe(u8, lb[0..n]) catch @panic("oom"), .slot = slot }) catch @panic("oom");
                        }
                        out = Value.str(&empty_str);
                    },
                    // a LIST or an object, or "Bad parameter type!" (list_e.c:737;
                    // a lambda is a string on Ring, so its closure vector too)
                    .refv, .reference => {
                        const rv = regs[A];
                        if (!((rv.tag == .vec and !rv.p.v.closure) or rv.tag == .obj)) {
                            self.pending = BADPARAM;
                            continue :dispatch .raise;
                        }
                        // Ring's lNewRef (vmgc.c:703): from here every transfer
                        // shares it, until one named holder is left (`copyv`)
                        if (rv.tag == .vec) {
                            if (rv.p.v.rref == 0) rv.p.v.rref = 1;
                        } else if (rv.p.o.rref == 0) rv.p.o.rref = 1;
                        out = rv;
                    },
                    // Ring counts the NAMED holders (vmgc.c:677); the VM's
                    // count less the temporaries is that (`ringHolders`)
                    .refcount => out = Value.int(switch (regs[A].tag) {
                        .vec, .obj => @max(1, self.ringHolders(regs[A], fsp, pc, base)),
                        // anything that is not a list is 1 on Ring (list_e.c:757);
                        // a string's count here is the VM's, and a constant's is
                        // the pin (konst_rc), 2^30 and more
                        else => 1,
                    }),
                }
                // An integer result takes the unboxed store, which releases a
                // list or an object it overwrites (setRegB): the destination is
                // a temporary that may still hold one from an earlier statement
                // (`x = ref(a)` leaves it in r0, `? refcount(a)` lands its
                // integer there). The counted path would be correct too; it is
                // a full retain and release for every integer a builtin answers.
                self.setRegB(base + in.a, out, out.tag != .int);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .dget => {
                const in = code[pc];
                const cv = regs[base + in.b];
                const iv = regs[base + in.c];
                // The DYNAMIC get is what an unproven container compiles to
                // -- every global, every parameter of unknown class -- so
                // this, not vget, is the map type's real front door. A
                // string index on a list is a keyed lookup; hget's operands
                // sit in the same registers.
                if (iv.tag == .str and cv.tag == .vec) continue :dispatch .hget;
                // `o[i]` and `o[:key]` on an OBJECT: operator("[]", i)
                if (cv.tag == .obj) {
                    self.pend_op = .{ .recv = cv, .arg = iv, .name = "[]", .kind = 1 };
                    continue :dispatch .opcall;
                }
                if (iv.tag != .int) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const idx = iv.p.i;
                switch (cv.tag) {
                    .vec => {
                        const v = cv.p.v;
                        if (idx < 1 or idx > v.len) {
                            self.pending = R2;
                            continue :dispatch .raise;
                        }
                        self.setRegB(base + in.a, v.ptr[@intCast(idx - 1)], in.d != 0);
                    },
                    .str => {
                        const st = cv.p.s;
                        if (idx < 1 or idx > st.len) {
                            self.pending = R2;
                            continue :dispatch .raise;
                        }
                        // A Ring s[i] IS a one-character string (F-54 -> C-3,
                        // 2026-09-09). The byte form broke the first Softanza
                        // program to run here: `_cDir_[_i_] = "\"` never held,
                        // the engine path was rebuilt from numbers, and no
                        // engine was found.
                        const at: usize = @intCast(idx - 1);
                        self.setRegB(base + in.a, Value.str(self.oneChar(st.ptr[at])), true);
                    },
                    else => {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    },
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .vgetw => {
                const in = code[pc];
                const cv = regs[base + in.b];
                const iv = regs[base + in.c];
                if (cv.tag != .vec) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const v = cv.p.v;
                var e: Value = undefined;
                if (iv.tag == .str) {
                    // `$aRules[:dag] + x` -- a KEYED place borrowed for writing:
                    // the pair's value, by reference. It was BADPARAM here, and
                    // Softanza's stzGraphRule.ring registers every rule that
                    // way at load (found 2026-09-11).
                    const at = self.hfindFast(v, iv.p.s) orelse {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    };
                    const pair = v.ptr[at];
                    if (pair.tag != .vec or pair.p.v.len < 2) {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    }
                    e = pair.p.v.ptr[1];
                } else {
                    if (iv.tag != .int) {
                        self.pending = BADPARAM;
                        continue :dispatch .raise;
                    }
                    const idx = iv.p.i;
                    if (idx < 1 or idx > v.len) {
                        self.pending = R2;
                        continue :dispatch .raise;
                    }
                    e = v.ptr[@intCast(idx - 1)];
                }
                // No clone of a shared element any more (C-7): a nested list
                // shared with a parameter is meant to be written through.
                // Deliberately no retain. See the opcode comment: this is a
                // borrow, and the compiler clears the register afterwards so
                // frame teardown never releases what it does not own.
                regs[base + in.a] = e;
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .dlen => {
                const in = code[pc];
                const cv = regs[base + in.b];
                const n: i64 = switch (cv.tag) {
                    .vec => cv.p.v.len,
                    .str => cv.p.s.len,
                    // AN OBJECT IS ASKED ITS LENGTH (F-105): Ring calls the
                    // class's operator("len", 0) for len(o) and before every
                    // turn of `for x in o` (genlib_e.c:1098, vmstack.c:794),
                    // and R50 without one.
                    .obj => {
                        self.pend_op = .{ .recv = cv, .arg = Value.int(0), .name = "len", .kind = 1 };
                        continue :dispatch .opcall;
                    },
                    else => {
                        // a for-in's bound (d = 2) is R29 on Ring; len()'s is
                        // "Bad parameter type!"
                        self.pending = if (in.d == 2) R29 else BADPARAM;
                        continue :dispatch .raise;
                    },
                };
                self.setRegB(base + in.a, Value.int(n), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .loadk => {
                const in = code[pc];
                self.setRegB(base + in.a, konst[@intCast(in.d)], true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .newobj => {
                const in = code[pc];
                const cls: u16 = @intCast(in.d);
                const nsl = class_slots[cls];
                const o = self.alloc.create(Obj) catch @panic("oom");
                const sl = self.alloc.alloc(Value, if (nsl == 0) 1 else nsl) catch @panic("oom");
                @memset(sl, Value.nil());
                o.* = .{ .slots = sl.ptr, .nslots = nsl, .class = cls, .rc = 0 };
                if (DEFER) {
                    // objects join the zero-count table like vectors do
                }
                self.setRegB(base + in.a, Value.object(o), true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .gattr => {
                const in = code[pc];
                const rv = regs[base + in.b];
                if (rv.tag != .obj) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const o = rv.p.o;
                const sl: u32 = @intCast(in.d);
                if (sl >= o.nslots) {
                    // A slot the COMPILER resolved against a class the
                    // object turned out not to have: ours, not the
                    // program's. It is raised rather than panicked so the
                    // report carries the Ring line and call chain, which is
                    // what named the five tests that shared one site --
                    // stzList.ring:1593, slot 39 of a 12-slot object.
                    self.pending = std.fmt.allocPrint(self.alloc, "Ring++ internal: attribute slot {d} of {d} on class {d}", .{ sl, o.nslots, o.class }) catch "Ring++ internal: attribute slot";
                    continue :dispatch .raise;
                }
                const av = o.slots[sl];
                // Never assigned -- `newobj` fills every slot with nil, and
                // Ring's NULL is the empty STRING, so nil can only mean no
                // assignment ever ran. R24 with the attribute's name, as Ring
                // raises it (`@nunset`); a bare declaration (`x` alone in the
                // class body) is an assignment of the four-byte string "NULL"
                // on Ring and is not this case.
                if (av.tag == .nil) {
                    self.r24Named(self.attrNameOf(o.class, sl));
                    continue :dispatch .raise;
                }
                self.setRegB(base + in.a, av, true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .copyv => {
                const in = code[pc];
                const v = regs[base + in.a];
                if (v.tag == .vec or v.tag == .obj) {
                    // A value NOTHING ELSE HOLDS is not cloned. The register
                    // being assigned from is one holder; at rc 1 it is the
                    // only one, and a copy would be indistinguishable from
                    // the original to every observer -- Ring's assignment
                    // copy exists so that two names never share, and here
                    // there is no second name. This is what makes copying at
                    // every `x = f()` free when f built its result: only a
                    // returned global, attribute or `This` (rc >= 2) pays.
                    // Under deferred counting rc is not that fact, so the
                    // clone is unconditional there, as before.
                    const shared = if (RC and !DEFER)
                        (if (v.tag == .vec) v.p.v.rc > 1 else v.p.o.rc > 1)
                    else
                        true;
                    // ...and Ring's reference is assigned BY REFERENCE
                    // (vmstack.c:252) -- while it has a second named holder:
                    // with one, Ring copies again (usingref-02), and so here.
                    // A pinned one is shared whatever its holders (F-118).
                    var rref = if (v.tag == .vec) v.p.v.rref else v.p.o.rref;
                    if (rref == 1 and self.ringHolders(v, fsp, pc, base) <= 1) {
                        rref = 0;
                        if (v.tag == .vec) v.p.v.rref = 0 else v.p.o.rref = 0;
                    }
                    // b = 1: a list LITERAL appended by `aL + [...]` -- Ring
                    // pins every reference inside it (measured: V3, V15)
                    if (in.b == 1) self.pinRefs(v, 0);
                    if (shared and rref == 0) {
                        const c = self.cloneDeep(v);
                        if (self.pending.len != 0) continue :dispatch .raise;
                        self.setRegB(base + in.a, c, true);
                    }
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .sattr => {
                const in = code[pc];
                const rv = regs[base + in.a];
                if (rv.tag != .obj) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const o = rv.p.o;
                const sl: u32 = @intCast(in.d);
                if (sl >= o.nslots) @panic("sattr: slot out of range");
                const nv = regs[base + in.b];
                retain(nv);
                self.release(o.slots[sl]);
                o.slots[sl] = nv;
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .gattrn, .sattrn => |aop| {
                const in = code[pc];
                const rv = regs[base + (if (aop == .gattrn) in.b else in.a)];
                if (rv.tag != .obj) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const o = rv.p.o;
                const nidx: u32 = @intCast(in.d);
                const found_slot = attrLookup(o.class, nidx);
                // THE ATTRIBUTE FIRST, THEN ITS ACCESSOR: a `get<name>`
                // with no attribute of that name is Ring's R12 all the same
                // (row 2 of bench/exec/getset.ring), so the check waits
                // until the attribute is known to exist -- declared, or
                // given to this one object by addattribute.
                if (in.c != ACC_RAW and (found_slot != null or
                    extraAt(o, if (nidx < self.names.len) self.names[nidx] else "") != null))
                {
                    if (self.accessorOf(o, nidx, aop == .gattrn, in.c, base)) |m| {
                        self.pend_op = if (aop == .gattrn)
                            .{ .recv = rv, .kind = 1, .acc = 1, .ment = m }
                        else
                            .{ .recv = rv, .arg = regs[base + in.b], .kind = 4, .acc = 2, .ment = m };
                        continue :dispatch .opcall;
                    }
                }
                const sl = found_slot orelse {
                    // an attribute addattribute gave this one object
                    const nm0 = if (nidx < self.names.len) self.names[nidx] else "";
                    if (extraAt(o, nm0)) |xi| {
                        const ex = o.extra.?;
                        if (aop == .gattrn) {
                            self.setRegB(base + in.a, ex.ptr[xi], true);
                        } else {
                            const nv = regs[base + in.b];
                            retain(nv);
                            self.release(ex.ptr[xi]);
                            ex.ptr[xi] = nv;
                        }
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                    // Ring's own words, lower-cased name and all -- probed
                    // on 1.27: `o.nope` is "property not found: nope".
                    var lower: [64]u8 = undefined;
                    const nm = if (nidx < self.names.len) self.names[nidx] else "?";
                    const n = @min(nm.len, lower.len);
                    for (nm[0..n], 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
                    self.pending = std.fmt.bufPrint(&self.pending_buf, "Error (R12) : Error in property name, property not found: {s}", .{lower[0..n]}) catch "Error (R12) : Error in property name, property not found";
                    continue :dispatch .raise;
                };
                if (sl >= o.nslots) @panic("gattrn: slot out of range");
                if (aop == .gattrn) {
                    self.setRegB(base + in.a, o.slots[sl], true);
                } else {
                    const nv = regs[base + in.b];
                    retain(nv);
                    self.release(o.slots[sl]);
                    o.slots[sl] = nv;
                }
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .r24 => {
                const in = code[pc];
                // d < 0: Ring's R24 WITHOUT a name, which is what `x[1] = 5`
                // on a variable nothing assigned raises (probed on 1.27)
                if (in.d < 0) {
                    self.pending = "Error (R24) : Using uninitialized variable";
                    continue :dispatch .raise;
                }
                const nidx: u32 = @intCast(in.d);
                const nm = if (nidx < self.names.len) self.names[nidx] else "?";
                // in a METHOD (c & 1): an attribute the object gained is what
                // Ring finds before it raises -- the rule `gget` follows
                if (in.c & 1 != 0 and regs[base].tag == .obj) {
                    if (extraAt(regs[base].p.o, nm)) |ei| {
                        self.setRegB(base + in.a, regs[base].p.o.extra.?.ptr[ei], true);
                        pc += 1;
                        continue :dispatch code[pc].op;
                    }
                }
                // ...and a name an eval made (F-107): in a function holding an
                // eval (c & 2) its frame's, and in any function a global a
                // top-level eval made
                if (self.dynRead(nm, fsp, in.c & 2 != 0)) |dv| {
                    self.setRegB(base + in.a, dv, true);
                    pc += 1;
                    continue :dispatch code[pc].op;
                }
                self.r24Named(nm);
                continue :dispatch .raise;
            },
            .gorc => {
                const in = code[pc];
                const slot: usize = @intCast(in.d);
                if (slot < self.globals_set.len and self.globals_set[slot])
                    self.setRegB(base + in.a, self.globals[slot], true);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .callmq, .callmf => |mop| {
                if (g_watchdog_at != 0) self.wdTick(pc, fsp);
                // The brace hooks. A miss is the normal case, so it is not
                // an error: fall through to the next instruction -- or, for
                // callmf, over it, to the fallback the compiler laid out.
                const in = code[pc];
                const win = base + in.a;
                const rv = regs[win];
                const miss_step: u32 = if (mop == .callmf) 2 else 1;
                if (rv.tag != .obj) {
                    pc += miss_step;
                    continue :dispatch code[pc].op;
                }
                const key = @as(u32, rv.p.o.class) * n_names + @as(u32, @intCast(in.d));
                const slot = dispatch[key];
                if (slot == 0) {
                    pc += miss_step;
                    continue :dispatch code[pc].op;
                }
                const m = method_tab[slot - 1];
                // A HIT with the wrong count is Ring's R19/R20, not a miss:
                // a brace hook declaring a parameter it is never given
                // raises R19 on both 1.27 builds.
                if (m.nparams != in.b and m.nparams != unchecked_arity) {
                    @branchHint(.cold);
                    self.pending = if (in.b < m.nparams) R19 else R20;
                    continue :dispatch .raise;
                }
                if (fsp >= max_frames_ring) {
                    self.pending = R4;
                    continue :dispatch .raise;
                }
                if (win + m.frame + 16 > regs.len) @panic("register overflow");
                if (m.shift and in.b > 0) {
                    // a plain function attached by addmethod: its parameters
                    // start at r0. The arguments move down one register, each
                    // still held once; the receiver's reference is dropped,
                    // as a method's frame would have dropped it at `ret`.
                    // With NO arguments nothing moves, and the receiver stays
                    // in r0 -- which is what `This` in the function reads.
                    const recv = regs[win];
                    var ai: u32 = 0;
                    while (ai < in.b) : (ai += 1) regs[win + ai] = regs[win + 1 + ai];
                    regs[win + in.b] = Value.nil();
                    self.release(recv);
                }
                self.frames[fsp] = .{
                    .ret_pc = pc + 1,
                    .base = base,
                    .size = m.frame,
                    .mask = if (m.id == NO_MASK) 0 else fn_masks[m.id],
                    .full = m.id == NO_MASK,
                };
                fsp += 1;
                base = win;
                pc = m.entry;
                continue :dispatch code[pc].op;
            },
            .cmpv => {
                const in = code[pc];
                const x = regs[base + in.b];
                const y = regs[base + in.c];
                const names = [_][]const u8{ "=", "!=", "<", "<=", ">", ">=" };
                const rnames = [_][]const u8{ "", "", "r<", "r<=", "r>", "r>=" };
                const k: usize = @intCast(in.d);
                if (x.tag == .obj) {
                    self.pend_op = .{ .recv = x, .arg = y, .name = names[k], .kind = 1 };
                    continue :dispatch .opcall;
                }
                if (y.tag == .obj and k >= 2) {
                    self.pend_op = .{ .recv = y, .arg = x, .name = rnames[k], .kind = 1 };
                    continue :dispatch .opcall;
                }
                var t: bool = undefined;
                if (k < 2) {
                    t = valEq(x, y) == (k == 0);
                } else {
                    if (cmpCheck(x, y)) |e| {
                        self.pending = e;
                        continue :dispatch .raise;
                    }
                    const c = valCmp(x, y);
                    t = switch (k) {
                        2 => c < 0,
                        3 => c <= 0,
                        4 => c > 0,
                        else => c >= 0,
                    };
                }
                self.setRegB(base + in.a, Value.int(if (t) 1 else 0), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .opcall => {
                // Ring's operator overloading (VM.op_name_idx). The window
                // sits just past the current frame -- every register the
                // function uses is below `frames[fsp-1].size` -- and the
                // frame records where the answer lands (Frame.lkind).
                const p = self.pend_op;
                const m = if (p.acc != 0) p.ment else self.operatorOf(p.recv.p.o) orelse {
                    // `=` and `!=` on a class without `operator` compare
                    // plainly (measured: `w = 1` is 0); everything else is
                    // Ring's R50.
                    if (p.name[0] == '=' or p.name[0] == '!') {
                        const eq = valEq(p.recv, p.arg);
                        const t = if (p.name[0] == '=') eq else !eq;
                        if (p.kind == 1) {
                            self.setRegB(base + code[pc].a, Value.int(if (t) 1 else 0), false);
                            pc += 1;
                        } else if (p.kind >= 2 and p.kind <= 3) {
                            const taken = if (p.kind == 2) t else !t;
                            pc = if (taken) self.loopStep(@intCast(code[pc].d), pc, fsp) else pc + 1;
                        } else pc += 1;
                        continue :dispatch code[pc].op;
                    }
                    self.pending = R50;
                    continue :dispatch .raise;
                };
                if (fsp >= max_frames_ring) {
                    self.pending = R4;
                    continue :dispatch .raise;
                }
                const cur: u32 = if (fsp > 0) self.frames[fsp - 1].size else 64;
                const win = base + cur;
                if (win + m.frame + 16 > regs.len) @panic("register overflow");
                if (p.acc == 0) {
                    self.setRegB(win, p.recv, true);
                    self.setRegB(win + 1, Value.str(self.newStr(p.name)), true);
                    self.setRegB(win + 2, p.arg, true);
                } else if (p.acc == 2 and m.shift) {
                    // a plain function attached by addmethod: its first
                    // parameter is r0, so the value goes there, not `This`
                    self.setRegB(win, p.arg, true);
                } else {
                    self.setRegB(win, p.recv, true);
                    if (p.acc == 2) self.setRegB(win + 1, p.arg, true);
                }
                self.frames[fsp] = .{
                    .ret_pc = pc + 1,
                    .base = base,
                    .size = m.frame,
                    .mask = if (m.id == NO_MASK) 0 else fn_masks[m.id],
                    .full = m.id == NO_MASK,
                    .lkind = p.kind,
                };
                fsp += 1;
                base = win;
                pc = m.entry;
                continue :dispatch code[pc].op;
            },
            .callm => {
                if (g_watchdog_at != 0) self.wdTick(pc, fsp);
                const in = code[pc];
                const win = base + in.a;
                const rv = regs[win];
                if (rv.tag != .obj) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const key = @as(u32, rv.p.o.class) * n_names + @as(u32, @intCast(in.d));
                const slot = dispatch[key];
                if (slot == 0) {
                    // Ring's own words, lower-cased name and all -- probed
                    // on 1.27: it is R14, it is CATCHABLE, and the program
                    // carries on after the catch. We killed the process.
                    const nidx: u32 = @intCast(in.d);
                    var lower: [128]u8 = undefined;
                    const nm = if (nidx < self.names.len) self.names[nidx] else "?";
                    const ln = @min(nm.len, lower.len);
                    for (nm[0..ln], 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
                    self.pending = std.fmt.bufPrint(&self.pending_buf, "Error (R14) : Calling Method without definition: {s}", .{lower[0..ln]}) catch "Error (R14) : Calling Method without definition";
                    continue :dispatch .raise;
                }
                const m = method_tab[slot - 1];
                if (m.nparams != in.b and m.nparams != unchecked_arity) {
                    @branchHint(.cold);
                    self.pending = if (in.b < m.nparams) R19 else R20;
                    continue :dispatch .raise;
                }
                if (fsp >= max_frames_ring) {
                    self.pending = R4;
                    continue :dispatch .raise;
                }
                if (win + m.frame + 16 > regs.len) @panic("register overflow");
                if (m.shift and in.b > 0) {
                    // a plain function attached by addmethod: its parameters
                    // start at r0. The arguments move down one register, each
                    // still held once; the receiver's reference is dropped,
                    // as a method's frame would have dropped it at `ret`.
                    // With NO arguments nothing moves, and the receiver stays
                    // in r0 -- which is what `This` in the function reads.
                    const recv = regs[win];
                    var ai: u32 = 0;
                    while (ai < in.b) : (ai += 1) regs[win + ai] = regs[win + 1 + ai];
                    regs[win + in.b] = Value.nil();
                    self.release(recv);
                }
                self.frames[fsp] = .{
                    .ret_pc = pc + 1,
                    .base = base,
                    .size = m.frame,
                    .mask = if (m.id == NO_MASK) 0 else fn_masks[m.id],
                    .full = m.id == NO_MASK,
                };
                fsp += 1;
                base = win;
                pc = m.entry;
                continue :dispatch code[pc].op;
            },
            .ggetw => {
                const in = code[pc];
                // Borrowed for WRITING -- `$aList + item`. The write goes
                // INTO the value, so a global nothing has assigned yet is
                // Ring's R24, not a nil for vpush or vset to call a bad
                // parameter (probed on 1.27, 2026-09-27): named for `g + v`,
                // add, insert and del (c = 1), unnamed for a subscripted
                // root (c = 0). An unset global holds nil, so the test is
                // on the tag of the value this opcode loads anyway, and the
                // set-bit is read only then: the first form read the bit on
                // every write and cost `$aL[i] = v` about 1.5 ns (19 -> 22
                // ms for 2,000,000, minima of fifteen rounds).
                const gs: usize = @intCast(in.d);
                // No clone of a shared list (C-7): a register holding the
                // same list -- a for-in over a global, `for x in b` with
                // `add(b, 9)` inside -- is meant to see the append. It cloned
                // when rc > 1, and the loop counted the original (found
                // 2026-09-11).
                const e = self.globals[gs];
                if (e.tag == .nil) {
                    @branchHint(.cold);
                    if (gs < self.globals_set.len and !self.globals_set[gs]) {
                        if (in.c == 1) {
                            self.r24Named(if (gs < global_names.len) global_names[gs] else "?");
                        } else {
                            self.pending = "Error (R24) : Using uninitialized variable";
                        }
                        continue :dispatch .raise;
                    }
                }
                self.setRegB(base + in.a, e, false); // borrowed, no retain
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .gattrw => {
                const in = code[pc];
                const rv = regs[base + in.b];
                if (rv.tag != .obj) {
                    self.pending = BADPARAM;
                    continue :dispatch .raise;
                }
                const o = rv.p.o;
                const sl: u32 = @intCast(in.d);
                if (sl >= o.nslots) @panic("gattrw: slot out of range");
                // no clone of a shared list any more (C-7), as in ggetw
                const e = o.slots[sl];
                regs[base + in.a] = e; // borrow: the slot owns it
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .istag => {
                const in = code[pc];
                const t = @intFromEnum(regs[base + in.b].tag);
                self.setRegB(base + in.a, Value.int(if (t == in.d) 1 else 0), false);
                pc += 1;
                continue :dispatch code[pc].op;
            },
            .call => {
                if (g_watchdog_at != 0) self.wdTick(pc, fsp);
                const in = code[pc];
                if (fsp >= max_frames_ring) {
                    self.pending = R4;
                    continue :dispatch .raise;
                }
                if (base + in.a + 64 > regs.len) @panic("register overflow");
                self.frames[fsp] = .{
                    .ret_pc = pc + 1,
                    .base = base,
                    .size = in.b,
                    .mask = if (in.c == NO_MASK) 0 else fn_masks[in.c],
                    .full = in.c == NO_MASK,
                };
                fsp += 1;
                base += in.a;
                pc = @intCast(in.d);
                continue :dispatch code[pc].op;
            },
            .ret => {
                const in = code[pc];
                const result = regs[base + in.a];
                fsp -= 1;
                const fr = self.frames[fsp];
                const tracing = blk: {
                    if (trace_ret_name.len == 0) break :blk false;
                    const fi = if (pc < self.fn_of.len) self.fn_of[pc] else self.main_fn;
                    const nm = if (fi < self.fn_names.len) self.fn_names[fi] else "";
                    break :blk std.ascii.eqlIgnoreCase(nm, trace_ret_name);
                };
                if (tracing) {
                    outFlush();
                    std.debug.print("\nTRACE ret: pc={d} a={d} base={d} size={d} full={} -> caller pc={d}\n", .{ pc, in.a, base, fr.size, fr.full, fr.ret_pc });
                    std.debug.print("      returning   {s}\n", .{describeValue(result)});
                    const nx = code[fr.ret_pc];
                    std.debug.print("      caller next {s} a={d} b={d} c={d} d={d}   (its base={d})\n", .{ @tagName(nx.op), nx.a, nx.b, nx.c, nx.d, fr.base });
                    std.debug.print("      result lands at regs[{d}]; caller will read regs[{d}]\n", .{ base, fr.base + nx.b });
                }
                if (RC and DEFER) {
                    // Registers are uncounted, so a return neither retains nor
                    // releases. It only clears the boxed slots, which is what
                    // keeps the root scan free of stale pointers.
                    var m = fr.mask;
                    if (fr.full) {
                        var i: u32 = 0;
                        while (i < fr.size) : (i += 1) regs[base + i] = Value.nil();
                    }
                    while (m != 0) {
                        const b = @ctz(m);
                        m &= m - 1;
                        regs[base + b] = Value.nil();
                    }
                    regs[base] = result;
                } else if (RC and TYPED) {
                    // Sweep only the registers the compiler says can hold a
                    // reference. fib's mask is empty, so its returns cost
                    // nothing at all -- which is the whole point. Where there
                    // is NO mask (a function past the 64-slot table, which is
                    // most of them in a real program) the frame is swept whole:
                    // slower, and correct. It used to sweep nothing.
                    retain(result);
                    if (fr.full) {
                        var i: u32 = 0;
                        while (i < fr.size) : (i += 1) {
                            self.release(regs[base + i]);
                            regs[base + i] = Value.nil();
                        }
                    } else {
                        var m = fr.mask;
                        while (m != 0) {
                            const b = @ctz(m);
                            m &= m - 1;
                            self.release(regs[base + b]);
                            regs[base + b] = Value.nil();
                        }
                    }
                    regs[base] = result;
                    if (tracing) std.debug.print("      after write regs[{d}] = {s}\n", .{ base, describeValue(regs[base]) });
                } else if (RC) {
                    retain(result); // survives the sweep below
                    var i: u32 = 0;
                    while (i < fr.size) : (i += 1) {
                        self.release(regs[base + i]);
                        regs[base + i] = Value.nil();
                    }
                    regs[base] = result; // carries the retain taken above
                } else {
                    regs[base] = result; // result lands at window start
                }
                const cbase = base;
                pc = fr.ret_pc;
                base = fr.base;
                if (fr.lkind != 0) {
                    // an OPERATOR call: the answer leaves the window (with
                    // the reference the sweep above gave it) and goes where
                    // the opcode that met the object would have put its own
                    const r = regs[cbase];
                    regs[cbase] = Value.nil();
                    const caller = code[fr.ret_pc - 1]; // the opcode that met the object
                    if (fr.lkind == 1) {
                        const dst = base + caller.a;
                        if (RC and !DEFER) {
                            const old = regs[dst];
                            regs[dst] = r;
                            self.release(old);
                        } else regs[dst] = r;
                    } else if (fr.lkind == 4) {
                        // a statement: the answer is dropped
                        if (RC and !DEFER) self.release(r);
                    } else {
                        const t = truthy(r);
                        if (RC and !DEFER) self.release(r);
                        const taken = if (fr.lkind == 2) t else !t;
                        if (taken) pc = self.loopStep(@intCast(caller.d), pc - 1, fsp);
                    }
                }
                continue :dispatch code[pc].op;
            },
        }
    }
};

// ------------------------------------------------------------ assembler

const Asm = struct {
    code: std.ArrayListUnmanaged(Instr) = .{},
    alloc: std.mem.Allocator,

    fn here(self: *Asm) u32 {
        return @intCast(self.code.items.len);
    }
    fn emit(self: *Asm, op: Op, a: u8, b: u8, c: u8, d: i32) u32 {
        const at = self.here();
        self.code.append(self.alloc, .{ .op = op, .a = a, .b = b, .c = c, .d = d }) catch @panic("oom");
        return at;
    }
    /// forward jump/branch: emit with d=0, patch later via land()
    fn fwd(self: *Asm, op: Op, a: u8, b: u8, c: u8) u32 {
        return self.emit(op, a, b, c, 0);
    }
    fn land(self: *Asm, at: u32) void {
        self.code.items[at].d = @intCast(self.here());
    }
};

// ------------------------------------------------- the six programs
//
// Register plans are written as comments above each function. Programs
// are assembled into ONE code array; function entries are recorded and
// used as CALL targets.

const Prog = struct {
    code: []Instr,
    sieve: u32,
    matmul: u32,
    fib_top: u32,
    msort_top: u32,
    sum32: u32,
    binsearch: u32,
    bytescan: u32,
    strpass: u32,
    strfind: u32,
    cowtest: u32,
};

fn buildPrograms(alloc: std.mem.Allocator) Prog {
    var a = Asm{ .alloc = alloc };
    const MOD: i32 = 1000000007;

    // ---- fib: r0 = n. `if n < 2 return n; return fib(n-1)+fib(n-2)`
    const fib = a.here();
    {
        const rec = a.fwd(.jgti, 0, 0, 1); // n > 1 -> recurse
        _ = a.emit(.ret, 0, 0, 0, 0);
        a.land(rec);
        _ = a.emit(.addi, 2, 0, 0, -1); // window 2: arg = n-1
        _ = a.emit(.call, 2, 4, 0, @intCast(fib)); // callee frame = 4 regs
        _ = a.emit(.move, 1, 2, 0, 0); // save fib(n-1)
        _ = a.emit(.addi, 3, 0, 0, -2); // window 3: arg = n-2
        _ = a.emit(.call, 3, 4, 0, @intCast(fib));
        _ = a.emit(.add, 0, 1, 3, 0);
        _ = a.emit(.ret, 0, 0, 0, 0);
    }

    // ---- merge: r0=a r1=b -> out. While-loops re-evaluate #a/#b every
    // iteration, exactly as bench.lua's merge does.
    const merge = a.here();
    {
        _ = a.emit(.vnew, 2, 0, 1, 0); // out
        _ = a.emit(.loadi, 3, 0, 0, 1); // i
        _ = a.emit(.loadi, 4, 0, 0, 1); // j
        const w1 = a.here();
        _ = a.emit(.vlen, 5, 0, 0, 0);
        const x1 = a.fwd(.jgt, 3, 5, 0); // i > #a -> drain b side
        _ = a.emit(.vlen, 5, 1, 0, 0);
        const x2 = a.fwd(.jgt, 4, 5, 0); // j > #b -> drain a side
        _ = a.emit(.vget, 6, 0, 3, 0); // a[i]
        _ = a.emit(.vget, 7, 1, 4, 0); // b[j]
        const tb = a.fwd(.jgt, 6, 7, 0); // a[i] > b[j] -> take b
        _ = a.emit(.vpush, 2, 6, 0, 0);
        _ = a.emit(.addi, 3, 3, 0, 1);
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w1));
        a.land(tb);
        _ = a.emit(.vpush, 2, 7, 0, 0);
        _ = a.emit(.addi, 4, 4, 0, 1);
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w1));
        a.land(x1);
        a.land(x2);
        // drain a: while i <= #a
        const w2 = a.here();
        _ = a.emit(.vlen, 5, 0, 0, 0);
        const x3 = a.fwd(.jgt, 3, 5, 0);
        _ = a.emit(.vget, 6, 0, 3, 0);
        _ = a.emit(.vpush, 2, 6, 0, 0);
        _ = a.emit(.addi, 3, 3, 0, 1);
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w2));
        a.land(x3);
        // drain b: while j <= #b
        const w3 = a.here();
        _ = a.emit(.vlen, 5, 1, 0, 0);
        const x4 = a.fwd(.jgt, 4, 5, 0);
        _ = a.emit(.vget, 6, 1, 4, 0);
        _ = a.emit(.vpush, 2, 6, 0, 0);
        _ = a.emit(.addi, 4, 4, 0, 1);
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w3));
        a.land(x4);
        _ = a.emit(.ret, 2, 0, 0, 0);
    }

    // ---- mergesort: r0=l. r1=#l r2=mid r3=left r4=i r5=right r6=tmp
    const msort = a.here();
    {
        _ = a.emit(.vlen, 1, 0, 0, 0);
        const go = a.fwd(.jgti, 1, 0, 1); // #l > 1 -> sort
        _ = a.emit(.ret, 0, 0, 0, 0);
        a.land(go);
        _ = a.emit(.idivi, 2, 1, 0, 2); // mid = #l // 2
        _ = a.emit(.vnew, 3, 0, 1, 0); // left
        _ = a.emit(.loadi, 4, 0, 0, 0);
        const f1j = a.fwd(.jmp, 0, 0, 0);
        const b1 = a.here();
        _ = a.emit(.vget, 6, 0, 4, 0);
        _ = a.emit(.vpush, 3, 6, 0, 0);
        a.land(f1j);
        _ = a.emit(.forloop, 4, 2, 0, @intCast(b1)); // i = 1..mid
        _ = a.emit(.vnew, 5, 0, 1, 0); // right
        _ = a.emit(.move, 4, 2, 0, 0); // i = mid (forloop makes mid+1)
        const f2j = a.fwd(.jmp, 0, 0, 0);
        const b2 = a.here();
        _ = a.emit(.vget, 6, 0, 4, 0);
        _ = a.emit(.vpush, 5, 6, 0, 0);
        a.land(f2j);
        _ = a.emit(.forloop, 4, 1, 0, @intCast(b2)); // i = mid+1..#l
        _ = a.emit(.move, 7, 3, 1, 0); // sort left -- a VECTOR moves
        _ = a.emit(.call, 7, 9, 2, @intCast(msort));
        _ = a.emit(.move, 3, 7, 1, 0);
        _ = a.emit(.move, 7, 5, 1, 0); // sort right
        _ = a.emit(.call, 7, 9, 2, @intCast(msort));
        _ = a.emit(.move, 8, 7, 1, 0); // merge(left', right')
        _ = a.emit(.move, 7, 3, 1, 0);
        _ = a.emit(.call, 7, 8, 1, @intCast(merge));
        _ = a.emit(.ret, 7, 0, 0, 0);
    }

    // ---- sieve top-level: r0 = n
    const sieve = a.here();
    {
        _ = a.emit(.vnew, 1, 0, 1, 0); // flag
        _ = a.emit(.loadi, 2, 0, 0, 0); // const 0
        _ = a.emit(.loadi, 3, 0, 0, 0); // i
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.vpush, 1, 2, 0, 0);
        a.land(fj);
        _ = a.emit(.forloop, 3, 0, 0, @intCast(b)); // flag[1..n] = 0
        _ = a.emit(.loadi, 2, 0, 0, 0); // count = 0
        _ = a.emit(.loadi, 3, 0, 0, 1); // i starts at 2 via forloop
        _ = a.emit(.loadi, 7, 0, 0, 1); // const 1
        const fj2 = a.fwd(.jmp, 0, 0, 0);
        const b2 = a.here();
        _ = a.emit(.vget, 4, 1, 3, 0); // flag[i]
        const skip = a.fwd(.jnei, 4, 0, 0); // flag[i] != 0 -> next i
        _ = a.emit(.addi, 2, 2, 0, 1); // count += 1
        _ = a.emit(.mul, 5, 3, 3, 0); // j = i*i
        const skip2 = a.fwd(.jgt, 5, 0, 0); // j > n -> next i
        const b3 = a.here();
        _ = a.emit(.vset, 1, 5, 7, 0); // flag[j] = 1
        _ = a.emit(.forloops, 5, 0, 3, @intCast(b3)); // j += i while j <= n
        a.land(skip);
        a.land(skip2);
        a.land(fj2);
        _ = a.emit(.forloop, 3, 0, 0, @intCast(b2)); // i = 2..n
        _ = a.emit(.halt, 2, 0, 0, 0);
    }

    // ---- matmul top-level: r0 = n
    const matmul = a.here();
    {
        _ = a.emit(.vnew, 1, 0, 1, 0); // a
        _ = a.emit(.vnew, 2, 0, 1, 0); // b
        _ = a.emit(.loadi, 3, 0, 0, 0); // i
        const f1j = a.fwd(.jmp, 0, 0, 0);
        const b1 = a.here();
        _ = a.emit(.vnew, 5, 0, 1, 0); // row of a
        _ = a.emit(.vnew, 6, 0, 1, 0); // row of b
        _ = a.emit(.loadi, 4, 0, 0, 0); // j
        const f2j = a.fwd(.jmp, 0, 0, 0);
        const b2 = a.here();
        _ = a.emit(.add, 7, 3, 4, 0);
        _ = a.emit(.modi, 7, 7, 0, 7); // (i+j)%7
        _ = a.emit(.vpush, 5, 7, 0, 0);
        _ = a.emit(.mul, 7, 3, 4, 0);
        _ = a.emit(.modi, 7, 7, 0, 5); // (i*j)%5
        _ = a.emit(.vpush, 6, 7, 0, 0);
        a.land(f2j);
        _ = a.emit(.forloop, 4, 0, 0, @intCast(b2));
        _ = a.emit(.vpush, 1, 5, 1, 0); // pushing a ROW VECTOR -> boxed
        _ = a.emit(.vpush, 2, 6, 1, 0);
        a.land(f1j);
        _ = a.emit(.forloop, 3, 0, 0, @intCast(b1));
        // acc loop
        _ = a.emit(.loadi, 9, 0, 0, 0); // acc
        _ = a.emit(.loadi, 3, 0, 0, 0); // i
        const f3j = a.fwd(.jmp, 0, 0, 0);
        const b3 = a.here();
        _ = a.emit(.vget, 5, 1, 3, 1); // row = a[i] -- a VECTOR
        _ = a.emit(.loadi, 4, 0, 0, 0); // j
        const f4j = a.fwd(.jmp, 0, 0, 0);
        const b4 = a.here();
        _ = a.emit(.loadi, 10, 0, 0, 0); // s = 0
        _ = a.emit(.loadi, 11, 0, 0, 0); // k
        const f5j = a.fwd(.jmp, 0, 0, 0);
        const b5 = a.here();
        _ = a.emit(.vget, 7, 5, 11, 0); // row[k] -- an int
        _ = a.emit(.vget, 12, 2, 11, 1); // b[k] is a VECTOR -> boxed, own reg
        _ = a.emit(.vget, 8, 12, 4, 0); // b[k][j] -- an int
        _ = a.emit(.mul, 7, 7, 8, 0);
        _ = a.emit(.add, 10, 10, 7, 0);
        a.land(f5j);
        _ = a.emit(.forloop, 11, 0, 0, @intCast(b5));
        _ = a.emit(.add, 7, 3, 4, 0); // i+j
        _ = a.emit(.mul, 7, 10, 7, 0); // s*(i+j)
        _ = a.emit(.add, 9, 9, 7, 0);
        _ = a.emit(.modi, 9, 9, 0, MOD);
        a.land(f4j);
        _ = a.emit(.forloop, 4, 0, 0, @intCast(b4));
        a.land(f3j);
        _ = a.emit(.forloop, 3, 0, 0, @intCast(b3));
        _ = a.emit(.halt, 9, 0, 0, 0);
    }

    // ---- fib top-level: r0 = n
    const fib_top = a.here();
    {
        _ = a.emit(.call, 0, 4, 0, @intCast(fib));
        _ = a.emit(.halt, 0, 0, 0, 0);
    }

    // ---- mergesort top-level: r0 = data vec
    const msort_top = a.here();
    {
        _ = a.emit(.call, 0, 9, 2, @intCast(msort));
        _ = a.emit(.halt, 0, 0, 0, 0);
    }

    // ---- sum32 top-level: r0 = vec
    const sum32 = a.here();
    {
        _ = a.emit(.loadi, 1, 0, 0, 0); // h
        _ = a.emit(.vlen, 2, 0, 0, 0);
        _ = a.emit(.loadi, 3, 0, 0, 0); // i
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.vget, 4, 0, 3, 0);
        _ = a.emit(.muli, 5, 1, 0, 31);
        _ = a.emit(.add, 5, 5, 4, 0);
        _ = a.emit(.modi, 1, 5, 0, MOD);
        a.land(fj);
        _ = a.emit(.forloop, 3, 2, 0, @intCast(b));
        _ = a.emit(.halt, 1, 0, 0, 0);
    }

    // ---- binsearchall top-level: r0 = sorted vec, r1 = query count
    const binsearch = a.here();
    {
        _ = a.emit(.loadi, 2, 0, 0, 0); // hits
        _ = a.emit(.vlen, 3, 0, 0, 0); // n
        _ = a.emit(.loadi, 4, 0, 0, 0); // q
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.muli, 5, 4, 0, 7919); // q*7919
        _ = a.emit(.muli, 6, 3, 0, 2); // n*2 (per query, as Lua writes it)
        _ = a.emit(.mod, 5, 5, 6, 0); // target
        _ = a.emit(.loadi, 7, 0, 0, 1); // lo
        _ = a.emit(.move, 8, 3, 0, 0); // hi
        const w = a.here();
        const done = a.fwd(.jgt, 7, 8, 0); // lo > hi -> next query
        _ = a.emit(.add, 9, 7, 8, 0);
        _ = a.emit(.idivi, 9, 9, 0, 2); // mid
        _ = a.emit(.vget, 10, 0, 9, 0); // sorted[mid]
        const hit = a.fwd(.jeq, 10, 5, 0);
        const ghi = a.fwd(.jge, 10, 5, 0); // not less -> hi side
        _ = a.emit(.addi, 7, 9, 0, 1); // lo = mid+1
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w));
        a.land(ghi);
        _ = a.emit(.addi, 8, 9, 0, -1); // hi = mid-1
        _ = a.emit(.jmp, 0, 0, 0, @intCast(w));
        a.land(hit);
        _ = a.emit(.addi, 2, 2, 0, 1); // hits += 1
        a.land(done);
        a.land(fj);
        _ = a.emit(.forloop, 4, 1, 0, @intCast(b)); // q = 1..queries
        _ = a.emit(.halt, 2, 0, 0, 0);
    }

    // ---- cowtest: Ring's assignment semantics, in six instructions.
    //   a = [1,2,3];  b = a;  b[1] = 99;  return a[1]
    // Ring answers 1 -- assignment copies. Reference semantics answer 99.
    // This is not a benchmark, it is a correctness gate on the design.
    const cowtest = a.here();
    {
        _ = a.emit(.vnew, 0, 0, 1, 0);
        _ = a.emit(.loadi, 5, 0, 0, 1);
        _ = a.emit(.vpush, 0, 5, 0, 0);
        _ = a.emit(.loadi, 5, 0, 0, 2);
        _ = a.emit(.vpush, 0, 5, 0, 0);
        _ = a.emit(.loadi, 5, 0, 0, 3);
        _ = a.emit(.vpush, 0, 5, 0, 0);
        _ = a.emit(.move, 1, 0, 1, 0); // b = a
        _ = a.emit(.loadi, 2, 0, 0, 1); // index 1
        _ = a.emit(.loadi, 3, 0, 0, 99);
        _ = a.emit(.vset, 1, 2, 3, 0); // b[1] = 99
        _ = a.emit(.vget, 4, 0, 2, 0); // read a[1]
        _ = a.emit(.halt, 4, 0, 0, 0);
    }

    // ---- flen(s): the whole point of the string workload. Ring copies the
    // string onto the VM stack to make this call (F-1/F-5, ~2200x); an
    // immutable by-reference string passes 8 bytes. r0 = str, r1 = length.
    const flen = a.here();
    {
        _ = a.emit(.slen, 1, 0, 0, 0);
        _ = a.emit(.ret, 1, 0, 0, 0);
    }

    // ---- strpass top-level: r0 = str, r1 = reps. Calls flen n times.
    // r13 = total, r14 = i, r15 = call window (holds the string -> boxed).
    const strpass = a.here();
    {
        _ = a.emit(.loadi, 13, 0, 0, 0);
        _ = a.emit(.loadi, 14, 0, 0, 0);
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.move, 15, 0, 1, 0); // arg = the string, a REFERENCE
        _ = a.emit(.call, 15, 2, 3, @intCast(flen));
        _ = a.emit(.add, 13, 13, 15, 0);
        a.land(fj);
        _ = a.emit(.forloop, 14, 1, 0, @intCast(b));
        _ = a.emit(.halt, 13, 0, 0, 0);
    }

    // ---- strfind top-level: r0 = haystack, r1 = needle. Naive search,
    // byte by byte, so every runtime does the same work. High registers
    // (r13+) keep it clear of the vectors the other programs leave behind.
    const strfind = a.here();
    {
        _ = a.emit(.slen, 13, 0, 0, 0); // n
        _ = a.emit(.slen, 14, 1, 0, 0); // m
        _ = a.emit(.sub, 15, 13, 14, 0);
        _ = a.emit(.addi, 15, 15, 0, 1); // limit = n - m + 1
        _ = a.emit(.loadi, 16, 0, 0, 0); // count
        _ = a.emit(.loadi, 17, 0, 0, 0); // i
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.loadi, 18, 0, 0, 0); // j
        const gj = a.fwd(.jmp, 0, 0, 0);
        const inner = a.here();
        _ = a.emit(.add, 19, 17, 18, 0);
        _ = a.emit(.addi, 19, 19, 0, -1); // i + j - 1
        _ = a.emit(.sgetb, 20, 0, 19, 0);
        _ = a.emit(.sgetb, 21, 1, 18, 0);
        const miss = a.fwd(.jne, 20, 21, 0);
        a.land(gj);
        _ = a.emit(.forloop, 18, 14, 0, @intCast(inner));
        _ = a.emit(.addi, 16, 16, 0, 1); // full match
        a.land(miss);
        a.land(fj);
        _ = a.emit(.forloop, 17, 15, 0, @intCast(b));
        _ = a.emit(.halt, 16, 0, 0, 0);
    }

    // ---- bytescan top-level: r0 = str
    const bytescan = a.here();
    {
        _ = a.emit(.loadi, 1, 0, 0, 0); // h
        _ = a.emit(.slen, 2, 0, 0, 0);
        _ = a.emit(.loadi, 3, 0, 0, 0); // i
        const fj = a.fwd(.jmp, 0, 0, 0);
        const b = a.here();
        _ = a.emit(.sgetb, 4, 0, 3, 0);
        _ = a.emit(.muli, 1, 1, 0, 131);
        _ = a.emit(.add, 1, 1, 4, 0);
        _ = a.emit(.modi, 1, 1, 0, MOD);
        a.land(fj);
        _ = a.emit(.forloop, 3, 2, 0, @intCast(b));
        _ = a.emit(.halt, 1, 0, 0, 0);
    }

    // Which registers of each function can hold a heap reference. A typed
    // front end derives these; here they are declared, and the CHECK values
    // plus the peak-RSS figure are what verify them.
    fn_masks[0] = 0; // fib: every register it touches holds an int
    fn_masks[1] = (@as(u64, 1) << 0) | (@as(u64, 1) << 1) | (@as(u64, 1) << 2); // merge: a, b, out
    fn_masks[2] = (@as(u64, 1) << 0) | (@as(u64, 1) << 3) | (@as(u64, 1) << 5) |
        (@as(u64, 1) << 7) | (@as(u64, 1) << 8); // msort: l, left, right, window, saved
    fn_masks[3] = (@as(u64, 1) << 0); // flen: r0 is the string

    return .{
        .code = a.code.items,
        .sieve = sieve,
        .matmul = matmul,
        .fib_top = fib_top,
        .msort_top = msort_top,
        .sum32 = sum32,
        .binsearch = binsearch,
        .bytescan = bytescan,
        .strpass = strpass,
        .strfind = strfind,
        .cowtest = cowtest,
    };
}

// -------------------------------------------------------------- harness

/// Peak resident set, read from /proc on Linux and Android. The arena build
/// never gives memory back, so this is the second dimension of the A/B.
fn reportPeakRss() void {
    const f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return;
    var it = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmHWM:")) {
            std.debug.print("PEAKRSS {s}\n", .{std.mem.trim(u8, line[6..], " \t")});
            return;
        }
    }
}

fn report(name: []const u8, best_ns: u64, check: i64) void {
    const h: u64 = (best_ns + 5_000) / 10_000; // ns -> hundredths of ms, rounded
    std.debug.print("CHECK {s} {d}\n", .{ name, check });
    std.debug.print("TIME  {s} {d}.{d:0>2}\n", .{ name, h / 100, h % 100 });
}

/// `rnx <bench> [reps]` runs ONE benchmark, so a simpleperf profile is not
/// polluted by the other five. No arguments = all six, exactly as before.
fn want(filter: ?[]const u8, name: []const u8) bool {
    if (filter) |f| return std.mem.eql(u8, f, name);
    return true;
}

/// Flush the program's output before reporting a panic: a crash must not
/// swallow what already ran. See flushForPanic.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ra: ?usize) noreturn {
        flushForPanic();
        std.debug.defaultPanic(msg, ra);
    }
}.f);

pub fn main() !void {
    armFaultReporting();
    var backing = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer backing.deinit();
    const host = if (MI) mi_allocator else backing.allocator();

    const argv = try std.process.argsAlloc(host);
    const filter: ?[]const u8 = if (argv.len > 1) argv[1] else null;
    const REPS: usize = if (argv.len > 2) (std.fmt.parseInt(usize, argv[2], 10) catch 3) else 3;

    var timer = try std.time.Timer.start();

    const prog = buildPrograms(host);

    const regs = try host.alloc(Value, 65536);
    @memset(regs, Value.nil());
    const frames = try host.alloc(Frame, 4096);

    std.debug.print("rnx-spike register VM (Zig, ReleaseFast)\n", .{});
    std.debug.print("==============================================\n\n", .{});

    // Each rep runs in a fresh arena so allocation cost is paid inside the
    // timed region (as Lua pays its allocator+GC) but memory stays flat.
    const Bench = struct {
        fn once(entry: u32, args: []const Value, regs_: []Value, frames_: []Frame, code: []const Instr) Value {
            if (MI) {
                // No wholesale teardown: memory comes back only if refcounts
                // bring it back. That is the whole point of the comparison.
                var vm = VM{ .code = code, .regs = regs_, .frames = frames_, .alloc = mi_allocator };
                for (args, 0..) |v, i| vm.setReg(@intCast(i), v);
                return vm.run(entry);
            } else {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                var vm = VM{ .code = code, .regs = regs_, .frames = frames_, .alloc = arena.allocator() };
                for (args, 0..) |v, i| vm.setReg(@intCast(i), v);
                return vm.run(entry);
            }
        }
    };

    // sieve(300000)
    if (want(filter, "sieve")) {
        var best: u64 = std.math.maxInt(u64);
        var check: i64 = 0;
        for (0..REPS) |_| {
            timer.reset();
            const v = Bench.once(prog.sieve, &.{Value.int(300000)}, regs, frames, prog.code);
            const t = timer.read();
            if (t < best) best = t;
            check = v.p.i;
        }
        report("sieve", best, check);
    }

    // matmul(80)
    if (want(filter, "matmul")) {
        var best: u64 = std.math.maxInt(u64);
        var check: i64 = 0;
        for (0..REPS) |_| {
            timer.reset();
            const v = Bench.once(prog.matmul, &.{Value.int(80)}, regs, frames, prog.code);
            const t = timer.read();
            if (t < best) best = t;
            check = v.p.i;
        }
        report("matmul", best, check);
    }

    // fib(25)
    if (want(filter, "fib")) {
        var best: u64 = std.math.maxInt(u64);
        var check: i64 = 0;
        for (0..REPS) |_| {
            timer.reset();
            const v = Bench.once(prog.fib_top, &.{Value.int(25)}, regs, frames, prog.code);
            const t = timer.read();
            if (t < best) best = t;
            check = v.p.i;
        }
        report("fib", best, check);
    }

    // mergesort(8000): data built OUTSIDE the timed region, as in bench.lua.
    // The sorted result is verified host-side, then summed for the check.
    var sorted_keep: ?*Vec = null;
    if (want(filter, "mergesort") or want(filter, "binsearch")) {
        var best: u64 = std.math.maxInt(u64);
        for (0..REPS) |_| {
            // data vec lives in a per-rep arena; the LAST rep's arena is
            // kept alive (never deinit'd -- host arena) for binsearch.
            var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
            const data = vm.newVec(8000);
            var i: i64 = 1;
            while (i <= 8000) : (i += 1) vm.vecPush(data, Value.int(@rem(i * 7919, 100003)));
            vm.setReg(0, Value.vec(data));
            timer.reset();
            const v = vm.run(prog.msort_top);
            const t = timer.read();
            if (t < best) best = t;
            sorted_keep = v.p.v;
        }
        const s = sorted_keep.?;
        var k: u32 = 1;
        while (k < s.len) : (k += 1) {
            if (s.ptr[k].p.i < s.ptr[k - 1].p.i) @panic("unsorted!");
        }
        // check = sum32(sorted), run through the VM like Lua runs sum32
        var vm2 = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
        vm2.setReg(0, Value.vec(s));
        const chk = vm2.run(prog.sum32);
        // binsearch needs the sorted vector, so this block runs for it too —
        // but only mergesort's own selection prints a mergesort line.
        if (want(filter, "mergesort")) report("mergesort", best, chk.p.i);
    }

    // binsearchall(sorted, 6000)
    if (want(filter, "binsearch")) {
        var best: u64 = std.math.maxInt(u64);
        var check: i64 = 0;
        for (0..REPS) |_| {
            var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
            vm.setReg(0, Value.vec(sorted_keep.?));
            vm.setReg(1, Value.int(6000));
            timer.reset();
            const v = vm.run(prog.binsearch);
            const t = timer.read();
            if (t < best) best = t;
            check = v.p.i;
        }
        report("binsearch", best, check);
    }

    // bytescan: "the quick brown fox " x 4000, built outside the timed region
    if (want(filter, "bytescan")) {
        const part = "the quick brown fox ";
        const big = try host.alloc(u8, part.len * 4000);
        var off: usize = 0;
        while (off < big.len) : (off += part.len) @memcpy(big[off .. off + part.len], part);
        const s = try host.create(Str);
        s.* = .{ .ptr = big.ptr, .len = @intCast(big.len) };

        var best: u64 = std.math.maxInt(u64);
        var check: i64 = 0;
        for (0..REPS) |_| {
            var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
            vm.setReg(0, Value.str(s));
            timer.reset();
            const v = vm.run(prog.bytescan);
            const t = timer.read();
            if (t < best) best = t;
            check = v.p.i;
        }
        report("bytescan", best, check);
    }

    // ---- Ring's assignment semantics. Prints the answer rather than
    // asserting it, so a build that gets it WRONG is visible in the output
    // instead of dying -- the whole point is to compare configurations.
    if (want(filter, "cowtest")) {
        var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
        const v = vm.run(prog.cowtest);
        std.debug.print("COWTEST a[1]={d}  (Ring semantics: 1, reference semantics: 99)\n", .{v.p.i});
    }

    // ---- the string workload. 1 MB, built outside every timed region.
    // This is the founding thesis of the whole project (F-1/F-5): a Ring
    // string is copied every time it crosses a call boundary; a reference
    // is not. Nothing else in the six algorithms tests it.
    if (want(filter, "strpass") or want(filter, "strfind")) {
        const part = "the quick brown fox ";
        const big = try host.alloc(u8, part.len * 50000); // 1,000,000 bytes
        var off: usize = 0;
        while (off < big.len) : (off += part.len) @memcpy(big[off .. off + part.len], part);
        const hay = try host.create(Str);
        hay.* = .{ .ptr = big.ptr, .len = @intCast(big.len) };
        const needle = try host.create(Str);
        needle.* = .{ .ptr = "fox".ptr, .len = 3 };

        if (want(filter, "strpass")) {
            var best: u64 = std.math.maxInt(u64);
            var check: i64 = 0;
            for (0..REPS) |_| {
                var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
                vm.setReg(0, Value.str(hay));
                vm.setReg(1, Value.int(2000));
                timer.reset();
                const v = vm.run(prog.strpass);
                const t = timer.read();
                if (t < best) best = t;
                check = v.p.i;
            }
            report("strpass", best, check);
        }

        if (want(filter, "strfind")) {
            var best: u64 = std.math.maxInt(u64);
            var check: i64 = 0;
            for (0..REPS) |_| {
                var vm = VM{ .code = prog.code, .regs = regs, .frames = frames, .alloc = host };
                vm.setReg(0, Value.str(hay));
                vm.setReg(1, Value.str(needle));
                timer.reset();
                const v = vm.run(prog.strfind);
                const t = timer.read();
                if (t < best) best = t;
                check = v.p.i;
            }
            report("strfind", best, check);
        }
    }

    reportPeakRss();
    std.debug.print("\nSUITE OK\n", .{});
}
