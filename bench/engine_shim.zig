//! A reference Ring++ engine, exercising the whole native ABI.
//!
//! This is the shape Softanza's Zig engine gains: ONE new file beside the
//! existing Ring-ABI entry point, exporting `rpp_init`. The engine's real
//! functions are untouched -- this only publishes them under the Ring++
//! calling convention.
//!
//! Build (nothing else needed -- no Ring headers, no C++ toolchain):
//!
//!     zig build-lib -dynamic -OReleaseFast bench/engine_shim.zig \
//!         --name rppdemo
//!
//! It reproduces the handle protocol Softanza already uses:
//!
//!     h = StzEngineString(s)        string -> handle
//!     r = StzEngineStringToUpper(h) handle -> handle
//!     c = StzEngineStringData(r)    handle -> string
//!         StzEngineStringFree(r)    handle -> void

const std = @import("std");

// ---- the ABI, copied verbatim; an engine needs no other Ring++ header --

const Tag = enum(u32) { nil = 0, int = 1, num = 2, str = 3, handle = 4, list = 5 };

const RppVal = extern struct {
    bits: u64 = 0,
    tag: u32 = @intFromEnum(Tag.nil),
    len: u32 = 0,
};

const RppFn = *const fn (args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int;
const RppRegister = *const fn (name: [*:0]const u8, f: RppFn) callconv(.c) void;
const RppList = ?*anyopaque;

/// What the VM offers. An engine that moves only numbers, strings and
/// handles uses `register` and ignores the rest; lists need these because
/// a list belongs to the VM's allocator and never crosses.
const HostApi = extern struct {
    register: RppRegister,
    list_new: *const fn () callconv(.c) RppList,
    list_push_num: *const fn (RppList, f64) callconv(.c) void,
    list_push_str: *const fn (RppList, [*]const u8, u32) callconv(.c) void,
    list_push_list: *const fn (RppList, RppList) callconv(.c) void,
    list_len: *const fn (RppList) callconv(.c) u32,
    list_tag: *const fn (RppList, u32) callconv(.c) u32,
    list_num: *const fn (RppList, u32) callconv(.c) f64,
    list_str: *const fn (RppList, u32, *u32) callconv(.c) [*]const u8,
    list_list: *const fn (RppList, u32) callconv(.c) RppList,
};

/// Kept from `rpp_init`. This is the whole of what an engine stores.
var host: *const HostApi = undefined;

fn asStr(v: RppVal) []const u8 {
    const p: [*]const u8 = @ptrFromInt(v.bits);
    return p[0..v.len];
}

// ---- the engine's own state -------------------------------------------

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// A handle is an ordinary heap pointer. The VM never touches it; Ring
/// code frees it, exactly as it does today.
const Str = struct { buf: []u8 };

/// Scratch for values returned to the VM. The VM copies a returned string
/// before the call returns, so this may be reused immediately.
var out_buf: [4096]u8 = undefined;

fn engineString(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1 or args[0].tag != @intFromEnum(Tag.str)) return 1;
    const a = gpa.allocator();
    const s = a.create(Str) catch return 1;
    const src = asStr(args[0]);
    s.buf = a.alloc(u8, src.len) catch return 1;
    @memcpy(s.buf, src);
    out.* = .{ .bits = @intFromPtr(s), .tag = @intFromEnum(Tag.handle) };
    return 0;
}

fn engineStringToUpper(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const src: *Str = @ptrFromInt(args[0].bits);
    const a = gpa.allocator();
    const s = a.create(Str) catch return 1;
    s.buf = a.alloc(u8, src.buf.len) catch return 1;
    for (src.buf, 0..) |ch, i| s.buf[i] = std.ascii.toUpper(ch);
    out.* = .{ .bits = @intFromPtr(s), .tag = @intFromEnum(Tag.handle) };
    return 0;
}

fn engineStringData(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const s: *Str = @ptrFromInt(args[0].bits);
    const n = @min(s.buf.len, out_buf.len);
    @memcpy(out_buf[0..n], s.buf[0..n]);
    out.* = .{
        .bits = @intFromPtr(&out_buf),
        .tag = @intFromEnum(Tag.str),
        .len = @intCast(n),
    };
    return 0;
}

fn engineStringLen(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const s: *Str = @ptrFromInt(args[0].bits);
    out.* = .{ .bits = @bitCast(@as(i64, @intCast(s.buf.len))), .tag = @intFromEnum(Tag.int) };
    return 0;
}

fn engineStringFree(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const s: *Str = @ptrFromInt(args[0].bits);
    const a = gpa.allocator();
    a.free(s.buf);
    a.destroy(s);
    out.* = .{};
    return 0;
}

/// A double in, a double out -- proving the numeric path as well.
fn engineHypot(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const x: f64 = if (args[0].tag == @intFromEnum(Tag.num))
        @bitCast(args[0].bits)
    else
        @floatFromInt(@as(i64, @bitCast(args[0].bits)));
    const y: f64 = if (args[1].tag == @intFromEnum(Tag.num))
        @bitCast(args[1].bits)
    else
        @floatFromInt(@as(i64, @bitCast(args[1].bits)));
    out.* = .{ .bits = @bitCast(@sqrt(x * x + y * y)), .tag = @intFromEnum(Tag.num) };
    return 0;
}

// ---- lists, the half a scalar ABI cannot carry ------------------------

/// A list in, a number out: sum every number in it, recursing into nested
/// lists. Proves list_len, list_tag, list_num and list_list.
fn sumOf(l: RppList) f64 {
    var total: f64 = 0;
    var i: u32 = 1;
    const n = host.list_len(l);
    while (i <= n) : (i += 1) {
        switch (@as(Tag, @enumFromInt(host.list_tag(l, i)))) {
            .int, .num => total += host.list_num(l, i),
            .list => total += sumOf(host.list_list(l, i)),
            else => {},
        }
    }
    return total;
}

fn engineListSum(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1 or args[0].tag != @intFromEnum(Tag.list)) return 1;
    const l: RppList = @ptrFromInt(args[0].bits);
    out.* = .{ .bits = @bitCast(sumOf(l)), .tag = @intFromEnum(Tag.num) };
    return 0;
}

/// A number in, a list out: [n, "n items", [1..n]]. Proves list_new,
/// all three pushes, and the ownership rule -- the inner list's build
/// reference is TRANSFERRED by list_push_list and must not be reused.
fn engineListMake(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const n: u32 = @intCast(@as(i64, @bitCast(args[0].bits)));
    const top = host.list_new();
    host.list_push_num(top, @floatFromInt(n));
    var lab: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&lab, "{d} items", .{n}) catch return 1;
    host.list_push_str(top, txt.ptr, @intCast(txt.len));
    const inner = host.list_new();
    var i: u32 = 1;
    while (i <= n) : (i += 1) host.list_push_num(inner, @floatFromInt(i));
    host.list_push_list(top, inner); // inner is the parent's now
    out.* = .{ .bits = @intFromPtr(top), .tag = @intFromEnum(Tag.list) };
    return 0;
}

/// A list in, a list out -- the shape most of Softanza's 21 list bridges
/// have: read every string, hand back the upper-cased ones.
fn engineListUpper(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1 or args[0].tag != @intFromEnum(Tag.list)) return 1;
    const l: RppList = @ptrFromInt(args[0].bits);
    const res = host.list_new();
    var i: u32 = 1;
    const n = host.list_len(l);
    while (i <= n) : (i += 1) {
        if (@as(Tag, @enumFromInt(host.list_tag(l, i))) != .str) continue;
        var len: u32 = 0;
        const p = host.list_str(l, i, &len);
        const m = @min(len, out_buf.len);
        for (p[0..m], 0..) |ch, k| out_buf[k] = std.ascii.toUpper(ch);
        host.list_push_str(res, &out_buf, m);
    }
    out.* = .{ .bits = @intFromPtr(res), .tag = @intFromEnum(Tag.list) };
    return 0;
}

// ---- the one symbol Ring++ looks for ----------------------------------

export fn rpp_abi_version() callconv(.c) u32 {
    return 2;
}

export fn rpp_init(h: *const HostApi) callconv(.c) c_int {
    host = h;
    const reg = h.register;
    reg("StzEngineString", &engineString);
    reg("StzEngineStringToUpper", &engineStringToUpper);
    reg("StzEngineStringData", &engineStringData);
    reg("StzEngineStringLen", &engineStringLen);
    reg("StzEngineStringFree", &engineStringFree);
    reg("StzEngineHypot", &engineHypot);
    reg("StzEngineListSum", &engineListSum);
    reg("StzEngineListMake", &engineListMake);
    reg("StzEngineListUpper", &engineListUpper);
    return 0;
}
