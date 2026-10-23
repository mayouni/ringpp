//! The host's HANDLE TABLE: one table for the whole process, offered to every native library through the
//! HostApi (src/native.zig, ABI 3), so an id minted in one engine DLL means the same object in every other,
//! and the VM knows when an object is gone.
//!
//! Asked for by stzlib-security on 2026-10-22 (RINGPP-HOST-HANDLES-01 and RINGPP-CPTR-RETIRE-01), from
//! SECURITY-R16 -- a Ring copy of a destroyed engine object read freed, reused memory, no error:
//!
//!   * each engine DLL had its OWN table (the backend is compiled INTO every domain), so an id could not cross
//!     DLLs and a perf family's child histogram, made in stz_perf.dll and read in stz_histogram.dll, had to stay a
//!     raw pointer; and before that, ids in the Ring++ backend were the raw ADDRESS carried in an f64, which
//!     nothing could retire: every copy of the number read the memory after it was freed;
//!   * a library that frees an object had no way to tell the host.
//!
//! THE ID is `generation * 2^32 + (slot + 1)`, exact in an f64 (20 bits of generation: 2^52 < 2^53) and the
//! SAME encoding stzlib's own per-DLL table uses (engine/src/ring_api.zig), so a fresh slot's first id is the
//! old 1-based number. A release bumps the slot's generation, so every copy of the old id is STALE: it resolves
//! to nothing, and a stale release is ignored, so a copy can neither read nor free a slot that now belongs to
//! another object. The generation wraps after 2^20 reuses of one slot; an id that old could name a new tenant.
//! Free slots are reused in the order they were freed (FIFO), not at once, to spread that out.
//!
//!   store(ptr)         the id of ptr; a pointer that is already LIVE gets the id it has (one object, one id,
//!                      however often it is returned). 0 for a null pointer or when the table cannot grow
//!   resolve(id)        the pointer, or null: id 0, malformed, never issued, released or retired
//!   state(id)          live | stale | unknown -- so a bridge can raise for a STALE use and stay quiet for NULL
//!   release(id)        retire the id (every copy goes stale) and answer the pointer, for the caller to free
//!   retirePtr(ptr)     the library freed ptr without holding the id: retire the id it has, if any
//!
//! Thread-safe: a mutex round every call (the reactor and the pools have threads of their own).
const std = @import("std");

/// 20 bits: 2^20 * 2^32 = 2^52, below the 2^53 an f64 carries exactly.
pub const GEN_MASK: u32 = 0xFFFFF;
const MAX_EXACT: f64 = 9007199254740991.0;

pub const State = enum(c_int) { unknown = 0, live = 1, stale = 2 };

const Slot = struct { ptr: ?*anyopaque = null, gen: u32 = 0, live: bool = false, issued: bool = false };

pub const Table = struct {
    alloc: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    slots: std.ArrayListUnmanaged(Slot) = .{},
    free: std.ArrayListUnmanaged(u32) = .{},
    free_head: usize = 0,
    by_addr: std.AutoHashMapUnmanaged(usize, u32) = .{},

    pub fn init(alloc: std.mem.Allocator) Table {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Table) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
        self.by_addr.deinit(self.alloc);
    }

    fn makeId(slot: usize, gen: u32) f64 {
        const v: u64 = (@as(u64, gen) << 32) | @as(u64, @intCast(slot + 1));
        return @floatFromInt(v);
    }

    const Parsed = struct { slot: usize, gen: u32 };

    fn parse(self: *const Table, id: f64) ?Parsed {
        if (!(id >= 1) or id > MAX_EXACT) return null; // also catches NaN
        const v: u64 = @intFromFloat(id);
        if (@as(f64, @floatFromInt(v)) != id) return null; // a fraction is not an id
        const low: u64 = v & 0xFFFFFFFF;
        const gen: u32 = @intCast(v >> 32);
        if (low == 0 or low > self.slots.items.len) return null;
        return .{ .slot = @intCast(low - 1), .gen = gen };
    }

    pub fn store(self: *Table, ptr: ?*anyopaque) f64 {
        const raw = ptr orelse return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        const addr = @intFromPtr(raw);
        if (self.by_addr.get(addr)) |s| {
            const sl = self.slots.items[s];
            if (sl.live) return makeId(s, sl.gen);
        }
        const idx: u32 = blk: {
            if (self.free_head < self.free.items.len) {
                const s = self.free.items[self.free_head];
                self.free_head += 1;
                if (self.free_head > 1024 and self.free_head * 2 > self.free.items.len) { // compact the queue
                    const rest = self.free.items.len - self.free_head;
                    std.mem.copyForwards(u32, self.free.items[0..rest], self.free.items[self.free_head..]);
                    self.free.shrinkRetainingCapacity(rest);
                    self.free_head = 0;
                }
                break :blk s;
            }
            if (self.slots.items.len >= 0xFFFFFFFE) return 0;
            self.slots.append(self.alloc, .{}) catch return 0;
            break :blk @intCast(self.slots.items.len - 1);
        };
        self.by_addr.put(self.alloc, addr, idx) catch {
            // could not index it: give the slot back untouched
            self.free.append(self.alloc, idx) catch {};
            return 0;
        };
        const sl = &self.slots.items[idx];
        sl.ptr = raw;
        sl.live = true;
        sl.issued = true;
        return makeId(idx, sl.gen);
    }

    pub fn resolve(self: *Table, id: f64) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.parse(id) orelse return null;
        const sl = self.slots.items[p.slot];
        if (sl.live and sl.gen == p.gen) return sl.ptr;
        return null;
    }

    pub fn state(self: *Table, id: f64) State {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.parse(id) orelse return .unknown;
        const sl = self.slots.items[p.slot];
        if (sl.live and sl.gen == p.gen) return .live;
        if (sl.issued) return .stale;
        return .unknown;
    }

    fn retireSlot(self: *Table, idx: u32) void {
        const sl = &self.slots.items[idx];
        if (sl.ptr) |pp| _ = self.by_addr.remove(@intFromPtr(pp));
        sl.ptr = null;
        sl.live = false;
        sl.gen = (sl.gen + 1) & GEN_MASK;
        self.free.append(self.alloc, idx) catch {}; // the slot is lost for reuse if this fails; it is never wrongly live
    }

    pub fn release(self: *Table, id: f64) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        const p = self.parse(id) orelse return null;
        const sl = self.slots.items[p.slot];
        if (!(sl.live and sl.gen == p.gen)) return null; // a stale or unknown release does nothing
        const ptr = sl.ptr;
        self.retireSlot(@intCast(p.slot));
        return ptr;
    }

    /// True if the pointer had a live id and it was retired.
    pub fn retirePtr(self: *Table, ptr: ?*anyopaque) bool {
        const raw = ptr orelse return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.by_addr.get(@intFromPtr(raw)) orelse return false;
        if (!self.slots.items[s].live) return false;
        self.retireSlot(s);
        return true;
    }

    /// How many ids are live (tests, and a program that wants to know what it leaks).
    pub fn liveCount(self: *Table) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.by_addr.count();
    }
};

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn fake(n: usize) *anyopaque {
    return @ptrFromInt(0x1000 + n * 16);
}

test "an id resolves to its pointer, and a fresh slot's first id is the 1-based number" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const a = t.store(fake(1));
    const b = t.store(fake(2));
    try testing.expectEqual(@as(f64, 1), a);
    try testing.expectEqual(@as(f64, 2), b);
    try testing.expectEqual(fake(1), t.resolve(a).?);
    try testing.expectEqual(fake(2), t.resolve(b).?);
}

test "a null pointer is no handle, and neither is id 0, a fraction, a negative, NaN or a huge number" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    _ = t.store(fake(1));
    try testing.expectEqual(@as(f64, 0), t.store(null));
    for ([_]f64{ 0, 0.5, 1.5, -1, std.math.nan(f64), std.math.inf(f64), 1e300, 9007199254740992.0 }) |bad| {
        try testing.expect(t.resolve(bad) == null);
        try testing.expectEqual(State.unknown, t.state(bad));
        try testing.expect(t.release(bad) == null);
    }
    try testing.expectEqual(@as(usize, 1), t.liveCount());
}

test "one object, one id, however often it is stored" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const a = t.store(fake(7));
    try testing.expectEqual(a, t.store(fake(7)));
    try testing.expectEqual(@as(usize, 1), t.liveCount());
}

test "a release stales every copy, answers the pointer once, and a second release does nothing" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const id = t.store(fake(3));
    const copy = id; // a Ring copy of the number
    try testing.expectEqual(State.live, t.state(copy));
    try testing.expectEqual(fake(3), t.release(id).?);
    try testing.expect(t.resolve(copy) == null);
    try testing.expectEqual(State.stale, t.state(copy));
    try testing.expect(t.release(copy) == null);
    try testing.expectEqual(@as(usize, 0), t.liveCount());
}

test "a stale copy cannot read or free the object that took its slot" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const old = t.store(fake(1));
    try testing.expect(t.release(old) != null);
    // with a FIFO free list the freed slot is reused only after the others; fill until it is
    var reused = false;
    var i: usize = 0;
    var ids: [8]f64 = undefined;
    while (i < ids.len) : (i += 1) {
        ids[i] = t.store(fake(100 + i));
        if ((@as(u64, @intFromFloat(ids[i])) & 0xFFFFFFFF) == 1) reused = true;
    }
    try testing.expect(reused);
    try testing.expect(t.resolve(old) == null); // old names slot 1 at generation 0; the tenant is generation 1
    try testing.expect(t.release(old) == null); // ...and cannot free it
    try testing.expectEqual(@as(usize, ids.len), t.liveCount());
}

test "retiring by address stales the id of a pointer the library freed" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    const id = t.store(fake(9));
    try testing.expect(t.retirePtr(fake(9)));
    try testing.expect(t.resolve(id) == null);
    try testing.expectEqual(State.stale, t.state(id));
    try testing.expect(!t.retirePtr(fake(9))); // already gone
    try testing.expect(!t.retirePtr(fake(10))); // never stored
    try testing.expect(!t.retirePtr(null));
    // the same address can be stored again: a new generation, a new id
    const again = t.store(fake(9));
    try testing.expect(again != id);
    try testing.expectEqual(fake(9), t.resolve(again).?);
    try testing.expect(t.resolve(id) == null);
}

test "an id never exceeds what an f64 carries exactly, even at the last generation" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    var last: f64 = 0;
    var i: u32 = 0;
    // push one slot's generation to the mask and over: store, release, store, release ...
    while (i < GEN_MASK + 3) : (i += 1) {
        last = t.store(fake(1));
        try testing.expect(last <= MAX_EXACT);
        try testing.expectEqual(fake(1), t.resolve(last).?);
        _ = t.release(last);
    }
    try testing.expect(t.resolve(last) == null);
}

test "an id the table never issued is unknown, not stale" {
    var t = Table.init(testing.allocator);
    defer t.deinit();
    _ = t.store(fake(1));
    try testing.expectEqual(State.unknown, t.state(makeIdForTest(5, 0))); // slot 5 does not exist
    try testing.expectEqual(State.stale, t.state(makeIdForTest(0, 7))); // slot 0 exists and was issued: this generation is not its own
}

fn makeIdForTest(slot: usize, gen: u32) f64 {
    return Table.makeId(slot, gen);
}

test "threads storing and releasing together leave the table consistent" {
    var t = Table.init(std.heap.page_allocator);
    defer t.deinit();
    const Worker = struct {
        fn run(tt: *Table, base: usize) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                const id = tt.store(@ptrFromInt(0x100000 + (base * 4096 + i) * 16));
                if (id != 0) {
                    if (tt.resolve(id) == null) @panic("a live id did not resolve");
                    _ = tt.release(id);
                }
            }
        }
    };
    var ths: [4]std.Thread = undefined;
    for (&ths, 0..) |*th, k| th.* = try std.Thread.spawn(.{}, Worker.run, .{ &t, k });
    for (ths) |th| th.join();
    try testing.expectEqual(@as(usize, 0), t.liveCount());
}
