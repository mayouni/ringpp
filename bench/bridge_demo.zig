//! A Softanza-shaped bridge, unchanged, running on Ring++.
//!
//! Every line of this file is written the way `engine/src/ring_bridge_*.zig`
//! is written: `const R = @import(...)`, functions of the shape
//! `fn (p: *anyopaque) callconv(.c) void`, arguments read with
//! `R.ring_vm_api_get*`, results returned with `R.ring_vm_api_ret*`, handles
//! through `R.retHandle` / `R.getHandle`, lists through `R.gl`,
//! `R.ringListSize`, `R.ring_list_gettype_gc`, `R.ring_list_getitem_gc` and
//! the `R.ring_vm_api_newlist` / `R.ring_list_add*` family -- and a `regs`
//! table handed to `R.registerAll`.
//!
//! The ONLY difference from a real bridge is the import: `ring_api_rpp.zig`
//! instead of `ring_api.zig`. That is the whole claim being tested -- that
//! the boundary is one module, and a second backend of it carries the
//! engine across without touching a bridge.
//!
//! Build:
//!
//!     zig build-lib -dynamic -OReleaseFast -lc bench/bridge_demo.zig \
//!         --name rppbridge
//!
//! Run: `bench/bridge.ring` on rnxc. It checks every answer and prints
//! BRIDGE OK.

const std = @import("std");
const R = @import("ring_api_rpp.zig");

// ---- scalars ----------------------------------------------------------

fn bridgeAdd(p: *anyopaque) callconv(.c) void {
    if (R.ring_vm_api_paracount(p) != 2) {
        R.ring_vm_error(p, "BridgeAdd expects 2 parameters");
        return;
    }
    const a = R.ring_vm_api_getnumber(p, 1);
    const b = R.ring_vm_api_getnumber(p, 2);
    R.ring_vm_api_retnumber(p, a + b);
}

var upper_buf: [4096]u8 = undefined;

fn bridgeUpper(p: *anyopaque) callconv(.c) void {
    if (R.ring_vm_api_isstring(p, 1) == 0) {
        R.ring_vm_error(p, "BridgeUpper expects a string");
        return;
    }
    const s = R.ring_vm_api_getstring(p, 1);
    const n = @min(@as(usize, R.ring_vm_api_getstringsize(p, 1)), upper_buf.len);
    for (s[0..n], 0..) |ch, i| upper_buf[i] = std.ascii.toUpper(ch);
    R.ring_vm_api_retstring2(p, &upper_buf, @intCast(n));
}

/// A bridge that answers out of a STACK buffer, which is how the engine's
/// own bridges are written: `var buf: [128]u8 = undefined;` then
/// `rs2(p, &buf, n)` -- stz_crypto's random hex, verbatim in shape. Ring's
/// `ring_vm_api_retstring` copies the bytes inside the call, so the buffer
/// dying at the return costs nothing there, and every bridge is written
/// against that contract.
///
/// This backend stored the POINTER and left the copy to the VM, which
/// happens after the bridge has returned: the answer came back with its
/// first bytes overwritten by whatever the VM pushed next and its tail
/// intact. A session token read `sess_0r>Z0...` and app/06_stzsuperapp
/// failed on SQL that did not parse (2026-09-15). Every existing probe
/// here answered out of a STATIC buffer, so none of them could see it.
/// The answer is built in an INNER frame and that frame is then written
/// over before the bridge returns. Without it the guard proves nothing:
/// with the defect deliberately put back, a buffer in the bridge's own
/// frame still happened to survive the copy, and every check passed.
fn fillFromStack(p: *anyopaque, n: usize) void {
    var buf: [128]u8 = undefined;
    const take = @min(n, buf.len);
    for (0..take) |i| buf[i] = "0123456789abcdef"[i % 16];
    R.ring_vm_api_retstring2(p, &buf, @intCast(take));
}

fn bridgeStackStr(p: *anyopaque) callconv(.c) void {
    const n: usize = @intFromFloat(R.ring_vm_api_getnumber(p, 1));
    fillFromStack(p, n);
    // The inner frame is gone; this is what the next thing to use the stack
    // does to it. A backend that kept the pointer answers with this.
    var scribble: [512]u8 = undefined;
    for (&scribble) |*b| b.* = 0x5A;
    std.mem.doNotOptimizeAway(&scribble);
}

// ---- handles, the protocol Softanza actually uses ---------------------

const Counter = struct { n: i64 };

fn bridgeCounterNew(p: *anyopaque) callconv(.c) void {
    const a = std.heap.c_allocator;
    const c = a.create(Counter) catch {
        R.ring_vm_error(p, "out of memory");
        return;
    };
    c.n = @intFromFloat(R.ring_vm_api_getnumber(p, 1));
    R.retHandle(p, c);
}

fn bridgeCounterBump(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandle(p, 1) orelse {
        R.ring_vm_error(p, "bad counter handle");
        return;
    };
    const c: *Counter = @ptrCast(@alignCast(raw));
    c.n += @intFromFloat(R.ring_vm_api_getnumber(p, 2));
    R.ring_vm_api_retnumber(p, @floatFromInt(c.n));
}

fn bridgeCounterFree(p: *anyopaque) callconv(.c) void {
    const raw = R.releaseHandle(p, 1) orelse return;
    const c: *Counter = @ptrCast(@alignCast(raw));
    std.heap.c_allocator.destroy(c);
    R.ring_vm_api_retnumber(p, 0);
}

// ---- objects on the HOST's handle table (ABI 3, 2026-10-22) -----------
//
// The security branch's bridge shape (stzlib a8e48c99): an object crosses as a checked id, a destroy stales every
// copy before the memory goes, and a stale use is a Ring error. Written with the three names it uses:
// retHandleOnce, releaseParam, getHandleOrRaise. bridge_demo_b.zig is a SECOND DLL that reads and frees them.

const Obj = struct { n: i64 };

fn bridgeObjNew(p: *anyopaque) callconv(.c) void {
    const o = std.heap.c_allocator.create(Obj) catch {
        R.ring_vm_error(p, "out of memory");
        return;
    };
    o.n = @intFromFloat(R.ring_vm_api_getnumber(p, 1));
    R.retHandleOnce(p, o);
}

fn bridgeObjRead(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandleOrRaise(p, 1, "object") orelse {
        R.ring_vm_api_retnumber(p, -1);
        return;
    };
    R.ring_vm_api_retnumber(p, @floatFromInt(@as(*Obj, @ptrCast(@alignCast(raw))).n));
}

/// What a bridge written the OLD way asks: `getcpointer`. A stale id is NULL, not an error.
fn bridgeObjPeek(p: *anyopaque) callconv(.c) void {
    const raw = R.ring_vm_api_getcpointer(p, 1, "Obj") orelse {
        R.ring_vm_api_retnumber(p, -1);
        return;
    };
    R.ring_vm_api_retnumber(p, @floatFromInt(@as(*Obj, @ptrCast(@alignCast(raw))).n));
}

fn bridgeObjFree(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandleOrRaise(p, 1, "object") orelse return;
    R.releaseParam(p, 1);
    std.heap.c_allocator.destroy(@as(*Obj, @ptrCast(@alignCast(raw))));
    R.ring_vm_api_retnumber(p, 0);
}

/// A library that frees a pointer WITHOUT keeping the id it handed out (a child freed with its parent): it tells
/// the host by ADDRESS (RINGPP-CPTR-RETIRE-01), and every copy of the id goes stale.
fn bridgeObjFreeRaw(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandle(p, 1) orelse return;
    std.heap.c_allocator.destroy(@as(*Obj, @ptrCast(@alignCast(raw))));
    R.ring_vm_api_retnumber(p, if (R.retirePtr(raw)) 1 else 0);
}

/// The same object returned again: one object, one id.
fn bridgeObjSame(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandle(p, 1) orelse {
        R.ring_vm_api_retnumber(p, 0);
        return;
    };
    R.retHandleOnce(p, raw);
}

// ---- reading a list ---------------------------------------------------

/// Sum every number, recursing into sublists -- the shape 21 of Softanza's
/// bridges have, written with Ring's item protocol.
fn sumList(pList: *anyopaque) f64 {
    var total: f64 = 0;
    const n = R.ringListSize(pList);
    var i: c_uint = 1;
    while (i <= n) : (i += 1) {
        switch (R.ring_list_gettype_gc(null, pList, i)) {
            R.ITEMTYPE_NUMBER => {
                const it = R.ring_list_getitem_gc(null, pList, i) orelse continue;
                total += R.ring_item_getnumber(it);
            },
            R.ITEMTYPE_LIST => {
                const sub = R.ring_list_getlist_gc(null, pList, i) orelse continue;
                total += sumList(sub);
            },
            else => {},
        }
    }
    return total;
}

fn bridgeListSum(p: *anyopaque) callconv(.c) void {
    if (R.il(p, 1) == 0) {
        R.ring_vm_error(p, "BridgeListSum expects a list");
        return;
    }
    const l = R.gl(p, 1) orelse return;
    R.ring_vm_api_retnumber(p, sumList(l));
}

/// Total length of every string in the list -- exercises the item string
/// readers, which are the ones with no Ring++ counterpart.
fn bridgeListChars(p: *anyopaque) callconv(.c) void {
    const l = R.gl(p, 1) orelse {
        R.ring_vm_error(p, "BridgeListChars expects a list");
        return;
    };
    var total: c_uint = 0;
    const n = R.ringListSize(l);
    var i: c_uint = 1;
    while (i <= n) : (i += 1) {
        if (R.ring_list_isstring_gc(null, l, i) == 0) continue;
        const it = R.ring_list_getitem_gc(null, l, i) orelse continue;
        total += R.ringItemStringSize(it);
    }
    R.ring_vm_api_retnumber(p, @floatFromInt(total));
}

// ---- building a list --------------------------------------------------

/// `[n, "n items", [1..n]]` -- a number, a string and a NESTED list, built
/// with Ring's write API.
fn bridgeListMake(p: *anyopaque) callconv(.c) void {
    const n: c_uint = @intFromFloat(R.ring_vm_api_getnumber(p, 1));
    const top = R.ring_vm_api_newlist(p) orelse return;
    R.ring_list_adddouble(top, @floatFromInt(n));
    var lab: [32]u8 = undefined;
    const txt = std.fmt.bufPrint(&lab, "{d} items", .{n}) catch return;
    R.ring_list_addstring2(top, txt.ptr, @intCast(txt.len));
    const inner = R.ring_list_newlist(top) orelse return;
    var i: c_uint = 1;
    while (i <= n) : (i += 1) R.ring_list_adddouble(inner, @floatFromInt(i));
    R.ring_vm_api_retlist(p, top);
}

/// A list in and a list out: the upper-cased strings.
fn bridgeListUpper(p: *anyopaque) callconv(.c) void {
    const l = R.gl(p, 1) orelse {
        R.ring_vm_error(p, "BridgeListUpper expects a list");
        return;
    };
    const res = R.ring_vm_api_newlist(p) orelse return;
    const n = R.ringListSize(l);
    var i: c_uint = 1;
    while (i <= n) : (i += 1) {
        if (R.ring_list_isstring_gc(null, l, i) == 0) continue;
        const it = R.ring_list_getitem_gc(null, l, i) orelse continue;
        const sp = R.ringItemStringPtr(it) orelse continue;
        const m = @min(@as(usize, R.ringItemStringSize(it)), upper_buf.len);
        for (sp[0..m], 0..) |ch, k| upper_buf[k] = std.ascii.toUpper(ch);
        R.ring_list_addstring2(res, &upper_buf, @intCast(m));
    }
    R.ring_vm_api_retlist(p, res);
}

// ---- a bridge that panics ----------------------------------------------

/// Panics, as an engine bridge does when one of its own checks fails --
/// neural/semantic_retrieval on Linux panics in buildBackbone this way. The
/// library's panic prints its trace and aborts; what bench/abort_flush.py
/// asks is whether the lines the PROGRAM printed before the call survive.
fn bridgePanic(p: *anyopaque) callconv(.c) void {
    _ = p;
    @panic("BridgePanic: a library's own panic, as an engine's would be");
}

// ---- the table, exactly as a bridge declares it ------------------------

const regs = [_]R.Reg{
    .{ .name = "BridgeAdd", .func = &bridgeAdd },
    .{ .name = "BridgeUpper", .func = &bridgeUpper },
    .{ .name = "BridgeStackStr", .func = &bridgeStackStr },
    .{ .name = "BridgeCounterNew", .func = &bridgeCounterNew },
    .{ .name = "BridgeCounterBump", .func = &bridgeCounterBump },
    .{ .name = "BridgeCounterFree", .func = &bridgeCounterFree },
    .{ .name = "BridgeObjNew", .func = &bridgeObjNew },
    .{ .name = "BridgeObjRead", .func = &bridgeObjRead },
    .{ .name = "BridgeObjPeek", .func = &bridgeObjPeek },
    .{ .name = "BridgeObjFree", .func = &bridgeObjFree },
    .{ .name = "BridgeObjFreeRaw", .func = &bridgeObjFreeRaw },
    .{ .name = "BridgeObjSame", .func = &bridgeObjSame },
    .{ .name = "BridgeListSum", .func = &bridgeListSum },
    .{ .name = "BridgeListChars", .func = &bridgeListChars },
    .{ .name = "BridgeListMake", .func = &bridgeListMake },
    .{ .name = "BridgeListUpper", .func = &bridgeListUpper },
    .{ .name = "BridgePanic", .func = &bridgePanic },
};

/// What each DLL gains beside `ringlib_init`. Two lines, and it hands the
/// same table to the same `registerAll`.
export fn rpp_init(h: *const R.HostApi) callconv(.c) c_int {
    R.setHost(h);
    var dummy: u8 = 0;
    R.registerAll(@ptrCast(&dummy), &regs);
    return 0;
}

export fn rpp_abi_version() callconv(.c) u32 {
    return 3;
}
