//! A SECOND engine DLL, for the host's handle table (ABI 3). `bridge_demo.zig` mints an id for an object; this
//! library, a different DLL with its own copy of the backend, reads and frees it. Before the host kept the table
//! (2026-10-22) each DLL had its own, an id could not cross, and a perf family's child histogram -- made in
//! stz_perf.dll, read in stz_histogram.dll -- had to be a raw pointer that nothing could retire (SECURITY-R16).
//!
//!     zig build-lib -dynamic -OReleaseFast -lc bench/bridge_demo_b.zig --name rppbridge_b
//!
//! Run by bench/bridge.ring.
const std = @import("std");
const R = @import("ring_api_rpp.zig");

const Obj = struct { n: i64 };

/// Reads the object an id in ANOTHER DLL named. A stale id raises, as stzlib's bridges do (getHandleOrRaise).
fn bridgeBRead(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandleOrRaise(p, 1, "object") orelse {
        R.ring_vm_api_retnumber(p, -1);
        return;
    };
    const o: *Obj = @ptrCast(@alignCast(raw));
    R.ring_vm_api_retnumber(p, @floatFromInt(o.n));
}

/// Frees an object another DLL made: the id goes stale for every copy, in every DLL, before the memory goes.
fn bridgeBFree(p: *anyopaque) callconv(.c) void {
    const raw = R.getHandleOrRaise(p, 1, "object") orelse return;
    R.releaseParam(p, 1);
    std.heap.c_allocator.destroy(@as(*Obj, @ptrCast(@alignCast(raw))));
    R.ring_vm_api_retnumber(p, 0);
}

const regs = [_]R.Reg{
    .{ .name = "BridgeBRead", .func = &bridgeBRead },
    .{ .name = "BridgeBFree", .func = &bridgeBFree },
};

export fn rpp_init(h: *const R.HostApi) callconv(.c) c_int {
    R.setHost(h);
    var dummy: u8 = 0;
    R.registerAll(@ptrCast(&dummy), &regs);
    return 0;
}

export fn rpp_abi_version() callconv(.c) u32 {
    return 3;
}
