//! Softanza's engine boundary, implemented over Ring++ instead of Ring.
//!
//! Softanza's Zig engine is 92 DLLs. Every one of them is a Ring EXTENSION:
//! its bridge files call Ring's C API, so none can load into a VM that is
//! not Ring's. Censused 2026-09-09 (`bench/engine_census.py`), the whole
//! boundary is ONE module -- `engine/src/ring_api.zig`, 233 lines, 37 names
//! -- imported as `R` by all 88 bridges, which declare no extern of their
//! own. So the way across is not 92 rewrites and not a generator: it is a
//! SECOND BACKEND of that one module, chosen at build time.
//!
//! This is that backend. It exports the same 37 names with the same
//! signatures, implemented over the Ring++ native ABI (`src/native.zig`).
//! **No bridge file changes.** `registerAll` and `Reg` keep their shape, so
//! each DLL gains `rpp_init` beside `ringlib_init` and calls the same table.
//!
//! WHAT THE CENSUS SAID IT HAD TO CARRY: 942 scalar and handle call sites,
//! 833 list ones. Both are here.
//!
//! THREE THINGS THAT LOOK HARD AND ARE NOT:
//!
//!   * HANDLES ARE ALREADY NUMBERS. `retHandle` stores a pointer in an
//!     engine-side table and returns the integer id as a NUMBER; `getHandle`
//!     reads a number and resolves it. Nothing about that touches Ring, so
//!     the handle half is copied from `ring_api.zig` verbatim and the ABI
//!     needs no pointer type at all.
//!   * `p` IS OPAQUE. Every bridge function is `fn (p: *anyopaque) void`
//!     and only ever hands `p` back to this module. So `p` becomes a
//!     pointer to the call's own arguments; nothing else notices.
//!   * ONE TRAMPOLINE TABLE. A Ring++ native takes (args, argc, out) and a
//!     Ring bridge takes (p), so each registered function needs an adapter
//!     that knows WHICH bridge it belongs to. `RppFn` carries no context,
//!     so the adapters are generated at comptime, one per slot, and
//!     `registerAll` fills the slots. MAX_FUNCS covers the largest DLL
//!     (stz_string registers 534).
//!
//! AND ONE THAT IS. Ring's list readers hand back an ITEM pointer and the
//! engine then reads Ring's own struct layout through it (`ringItemStringPtr`
//! casts and dereferences). Ring++ has no item pointers and shares no
//! layout, so `ring_list_getitem_gc` returns a shim -- a (list, index) pair
//! from a small ring buffer -- and the item readers resolve through it. An
//! item is read immediately after it is fetched, in every one of the 28
//! call sites, so a cycling buffer is enough; it is sized far above the
//! deepest use.

const std = @import("std");

// ---- the Ring++ native ABI, copied verbatim ---------------------------
// An engine needs no Ring++ header; these twenty lines are the whole of it.

pub const Tag = enum(u32) { nil = 0, int = 1, num = 2, str = 3, handle = 4, list = 5, obj = 6 };

pub const RppVal = extern struct {
    bits: u64 = 0,
    tag: u32 = @intFromEnum(Tag.nil),
    len: u32 = 0,
};

pub const RppFn = *const fn (args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int;
pub const RppRegister = *const fn (name: [*:0]const u8, f: RppFn) callconv(.c) void;
pub const RppList = ?*anyopaque;

pub const HostApi = extern struct {
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
    // ABI 3 (2026-10-22): the HOST's handle table -- src/handles.zig, src/native.zig has the contract.
    handle_store: *const fn (?*anyopaque) callconv(.c) f64,
    handle_resolve: *const fn (f64) callconv(.c) ?*anyopaque,
    handle_state: *const fn (f64) callconv(.c) c_int,
    handle_release: *const fn (f64) callconv(.c) ?*anyopaque,
    handle_retire: *const fn (?*anyopaque) callconv(.c) c_int,
};

var host: *const HostApi = undefined;

// ---- the call context, which is what `p` really is --------------------

const Ctx = struct {
    args: [*]const RppVal,
    argc: u32,
    out: *RppVal,
    failed: bool = false,
};

inline fn ctxOf(p: *anyopaque) *Ctx {
    return @ptrCast(@alignCast(p));
}

/// Ring numbers its parameters from 1.
inline fn arg(p: *anyopaque, n: c_int) RppVal {
    const c = ctxOf(p);
    if (n < 1 or @as(u32, @intCast(n)) > c.argc) return .{};
    return c.args[@intCast(n - 1)];
}

// ---- scalars ----------------------------------------------------------

pub fn ring_vm_api_paracount(p: *anyopaque) c_int {
    return @intCast(ctxOf(p).argc);
}

pub fn ring_vm_api_isstring(p: *anyopaque, n: c_int) c_int {
    return if (arg(p, n).tag == @intFromEnum(Tag.str)) 1 else 0;
}

pub fn ring_vm_api_isnumber(p: *anyopaque, n: c_int) c_int {
    const t = arg(p, n).tag;
    return if (t == @intFromEnum(Tag.int) or t == @intFromEnum(Tag.num)) 1 else 0;
}

/// Ring's pointers reach this engine as handle IDS, which are numbers --
/// see the handle table below. So this answers for the shape the engine
/// actually receives.
pub fn ring_vm_api_ispointer(p: *anyopaque, n: c_int) c_int {
    return ring_vm_api_isnumber(p, n);
}

// RING'S STRINGS ARE NUL-TERMINATED AND OURS ARE NOT.
//
// A Ring string carries a trailing zero; ours carries a length and stops
// exactly at it, and a string CONSTANT points into the middle of the source
// text. So handing this pointer straight to a C API that expects a C string
// reads past the end of the value -- into the next constant, or off the end
// of a buffer.
//
// Most bridges take the pointer WITH `getstringsize` and never notice. The
// ones that do not are the ones that call a C library: sqlite's open got a
// database name that ran on into whatever followed it and answered "Could
// not open database ':memory:'" (found 2026-09-13, two of the 34).
//
// Eight rotating buffers, because a bridge may fetch several strings in one
// call -- the widest in this engine takes three. They grow to the largest
// string a program passes and are then reused, so this costs one copy per
// fetch and no allocation in steady state.
var sbuf: [8][]u8 = .{&[_]u8{}} ** 8;
var sbuf_next: usize = 0;

pub fn ring_vm_api_getstring(p: *anyopaque, n: c_int) [*]const u8 {
    const v = arg(p, n);
    if (v.tag != @intFromEnum(Tag.str)) return "";
    const src: [*]const u8 = @ptrFromInt(v.bits);
    const len: usize = v.len;
    const slot = sbuf_next % sbuf.len;
    sbuf_next += 1;
    if (sbuf[slot].len < len + 1) {
        const alloc = std.heap.c_allocator;
        const bigger = alloc.alloc(u8, len + 1) catch return "";
        if (sbuf[slot].len > 0) alloc.free(sbuf[slot]);
        sbuf[slot] = bigger;
    }
    if (len > 0) @memcpy(sbuf[slot][0..len], src[0..len]);
    sbuf[slot][len] = 0;
    return sbuf[slot].ptr;
}

pub fn ring_vm_api_getstringsize(p: *anyopaque, n: c_int) c_uint {
    const v = arg(p, n);
    return if (v.tag == @intFromEnum(Tag.str)) v.len else 0;
}

pub fn ring_vm_api_getnumber(p: *anyopaque, n: c_int) f64 {
    const v = arg(p, n);
    return switch (@as(Tag, @enumFromInt(v.tag))) {
        .num => @bitCast(v.bits),
        .int, .handle => @floatFromInt(@as(i64, @bitCast(v.bits))),
        else => 0,
    };
}

pub fn ring_vm_api_retnumber(p: *anyopaque, n: f64) void {
    ctxOf(p).out.* = .{ .bits = @bitCast(n), .tag = @intFromEnum(Tag.num) };
}

pub fn ring_vm_api_retstring(p: *anyopaque, s: [*:0]const u8) void {
    const sl = std.mem.span(s);
    ring_vm_api_retstring2(p, sl.ptr, @intCast(sl.len));
}

/// A RETURNED string is COPIED here, and that is not an optimisation to
/// remove.
///
/// Ring's own `ring_vm_api_retstring` copies the bytes into the VM's string
/// inside the call, so a bridge may answer with a STACK buffer -- and they
/// do, idiomatically: `var buf: [128]u8 = undefined;` then
/// `rs2(p, &buf, n)`, which is exactly how stz_crypto returns a random hex
/// string. This used to store the POINTER and leave the copy to the VM,
/// which happens after the bridge has returned and its frame is gone: the
/// first bytes came back overwritten with whatever the VM pushed next,
/// pointer-shaped, and the tail survived. A session token read
/// `sess_0r>Z0...` and the SQL built from it did not parse (found
/// 2026-09-15 from app/06_stzsuperapp).
///
/// Four rotating buffers, the same shape as getstring's eight: one would do,
/// since a bridge returns one value, but a bridge that calls this twice must
/// not have its first answer moved under it either.
var rbuf: [4][]u8 = .{&[_]u8{}} ** 4;
var rbuf_next: usize = 0;

pub fn ring_vm_api_retstring2(p: *anyopaque, s: [*]const u8, len: c_uint) void {
    const n: usize = len;
    const slot = rbuf_next % rbuf.len;
    rbuf_next += 1;
    if (rbuf[slot].len < n + 1) {
        const alloc = std.heap.c_allocator;
        const bigger = alloc.alloc(u8, n + 1) catch {
            ctxOf(p).out.* = .{ .bits = 0, .tag = @intFromEnum(Tag.str), .len = 0 };
            return;
        };
        if (rbuf[slot].len > 0) alloc.free(rbuf[slot]);
        rbuf[slot] = bigger;
    }
    if (n > 0) @memcpy(rbuf[slot][0..n], s[0..n]);
    rbuf[slot][n] = 0;
    ctxOf(p).out.* = .{
        .bits = @intFromPtr(rbuf[slot].ptr),
        .tag = @intFromEnum(Tag.str),
        .len = @intCast(n),
    };
}

/// A bridge's error, as Ring raises it: the text recorded here, and the
/// call's wrapper hands it back in `out` with a failing return code, so the
/// VM raises it catchably, `In <name>()` in front (F-103). Until 2026-10-09
/// the text was kept "so a future ABI can carry it" and the process ended
/// with `native call failed`. Static, so it outlives the call; the VM copies
/// it at once. 4 KB: Ring keeps the whole message, and so should this.
pub var last_error: [4096]u8 = undefined;
pub var last_error_len: usize = 0;

pub fn ring_vm_error(p: *anyopaque, cStr: [*:0]const u8) void {
    const m = std.mem.span(cStr);
    const n = @min(m.len, last_error.len);
    @memcpy(last_error[0..n], m[0..n]);
    last_error_len = n;
    ctxOf(p).failed = true;
}

// ---- handles ----------------------------------------------------------
//
// THE HOST'S TABLE (ABI 3, 2026-10-22). A handle is an id the HOST minted: `generation * 2^32 + slot + 1`, a
// number, exact in an f64 (src/handles.zig). Three earlier designs, each replaced for a reason:
//
//   1. a table in THIS file, as ring_api.zig has: this file is compiled INTO EVERY domain DLL, so each had its own
//      and id 5 from stz_perf was another object in stz_histogram -- every histogram counted 0 (found 2026-09-12);
//   2. the raw ADDRESS carried in the f64 (2026-09-12 to 2026-10-22): ids now crossed DLLs, but nothing could
//      retire one -- a Ring copy of the number read the memory after the owner freed it, no error, and once the
//      memory was reused the copy read ANOTHER object (SECURITY-R16, stzlib-security, measured on Ring++ too);
//   3. this: one table in the host, so an id crosses DLLs and the VM knows when an object is gone. A release bumps
//      the slot's generation, so every copy of the old id is STALE: it resolves to nothing, and a stale release
//      is ignored.
//
// `ring_vm_api_getcpointer` on a stale id answers NULL, as RINGPP-CPTR-RETIRE-01 asked; a bridge that wants the
// stale use to be an ERROR calls `getHandleOrRaise`. A library that frees a pointer WITHOUT holding its id
// (a child object freed with its parent) calls `retirePtr(ptr)`.
pub fn storeHandle(ptr: ?*anyopaque) f64 {
    return host.handle_store(ptr);
}

pub fn resolveHandle(id: f64) ?*anyopaque {
    return host.handle_resolve(id);
}

/// Retire the id: every copy of it goes stale. A stale or unknown id releases nothing.
pub fn releaseSlot(id: f64) void {
    _ = host.handle_release(id);
}

/// The library freed `ptr` without holding the id it was handed out under: retire that id, if it has one.
pub fn retirePtr(ptr: ?*anyopaque) bool {
    return host.handle_retire(ptr) != 0;
}

pub fn retHandle(p: *anyopaque, ptr: ?*anyopaque) void {
    ring_vm_api_retnumber(p, storeHandle(ptr));
}

/// One object, one id, however often it is returned. The host's table does that for every pointer, so this is
/// `retHandle`; the name stays because stzlib's bridges call it.
pub fn retHandleOnce(p: *anyopaque, ptr: ?*anyopaque) void {
    retHandle(p, ptr);
}

pub fn getHandle(p: *anyopaque, n: c_int) ?*anyopaque {
    return resolveHandle(ring_vm_api_getnumber(p, n));
}

/// Resolve and retire in one: the pointer for the caller to free, and every copy of the id stale from here on.
pub fn releaseHandle(p: *anyopaque, n: c_int) ?*anyopaque {
    return host.handle_release(ring_vm_api_getnumber(p, n));
}

/// Retire the id in param n -- every copy of it goes stale. Call it in a destroy, after reading the pointer and
/// before freeing it. NULL ("") and other non-numbers are not handles and release nothing.
pub fn releaseParam(p: *anyopaque, n: c_int) void {
    if (ring_vm_api_isnumber(p, n) == 0) return;
    releaseSlot(ring_vm_api_getnumber(p, n));
}

/// `getHandle` for an object whose stale use must be an ERROR rather than a silent null: a nonzero NUMBER that no
/// longer resolves raises in Ring. NULL ("") or anything that is not a number is not a handle at all.
pub fn getHandleOrRaise(p: *anyopaque, n: c_int, comptime what: []const u8) ?*anyopaque {
    if (ring_vm_api_isnumber(p, n) == 0) return null;
    const id = ring_vm_api_getnumber(p, n);
    if (id == 0) return null;
    const ptr = resolveHandle(id);
    if (ptr == null) ring_vm_error(p, "This " ++ what ++ " was destroyed: a copy of it holds a handle that is no longer valid.");
    return ptr;
}

/// Present for source compatibility; the handle wrappers above are what every bridge actually calls. A stale id
/// answers NULL.
pub fn ring_vm_api_retcpointer(p: *anyopaque, ptr: ?*anyopaque, _: [*:0]const u8) void {
    retHandle(p, ptr);
}

pub fn ring_vm_api_getcpointer(p: *anyopaque, n: c_int, _: [*:0]const u8) ?*anyopaque {
    return getHandle(p, n);
}

// ---- lists: reading ---------------------------------------------------
//
// Ring's item type constants, which the bridges compare against directly
// (`!= ITEMTYPE_LIST`). From Ring's own ritem.h.

pub const ITEMTYPE_STRING: c_uint = 1;
pub const ITEMTYPE_NUMBER: c_uint = 2;
pub const ITEMTYPE_LIST: c_uint = 4;

/// A stand-in for Ring's item pointer: which list, and which 1-based index.
/// Handed out from a cycling buffer because an item is read immediately
/// after it is fetched -- all 28 call sites do -- and never stored.
const Item = struct { list: RppList, idx: u32 };
const ITEM_SHIMS = 256;
var item_ring: [ITEM_SHIMS]Item = undefined;
var item_at: usize = 0;

fn newItem(l: RppList, i: u32) *Item {
    const s = &item_ring[item_at];
    item_at = (item_at + 1) % ITEM_SHIMS;
    s.* = .{ .list = l, .idx = i };
    return s;
}

inline fn itemOf(p: *anyopaque) *Item {
    return @ptrCast(@alignCast(p));
}

pub fn ring_vm_api_getlist(p: *anyopaque, n: c_int) ?*anyopaque {
    const v = arg(p, n);
    if (v.tag != @intFromEnum(Tag.list)) return null;
    return @ptrFromInt(v.bits);
}

pub fn ring_vm_api_islist(p: *anyopaque, n: c_int) c_int {
    return if (arg(p, n).tag == @intFromEnum(Tag.list)) 1 else 0;
}

// ---- an OBJECT inside a list ------------------------------------------
//
// Ring lays an object out as a LIST whose first two items are the pairs
// ["self", ...] and ["super", ...], and the engine's marshallers treat that
// exact shape as an opaque leaf (`isRingObjectList`) that keeps its
// POSITION. A Ring++ object is not a list; the host reports it as Tag.obj
// and these three sentinels present it in Ring's shape. They are only ever
// read, never handed to the host, never written. Without them every object
// in a list was skipped on its way into the engine and every later position
// moved down one: Find(1:3) answered [3, 6] where Ring answers [4, 8]
// (string/from_list_everything_is_findable).
var obj_shape: u8 = 0;
var self_pair: u8 = 0;
var super_pair: u8 = 0;

inline fn is(p: ?*anyopaque, s: *u8) bool {
    return p == @as(?*anyopaque, @ptrCast(s));
}

inline fn isPair(p: ?*anyopaque) bool {
    return is(p, &self_pair) or is(p, &super_pair);
}

pub fn ring_list_getitem_gc(_: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) ?*anyopaque {
    return newItem(pList, nIndex);
}

pub fn ring_list_getlist_gc(_: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) ?*anyopaque {
    if (is(pList, &obj_shape)) return if (nIndex == 1) @ptrCast(&self_pair) else if (nIndex == 2) @ptrCast(&super_pair) else null;
    if (isPair(pList)) return null;
    if (host.list_tag(pList, nIndex) == @intFromEnum(Tag.obj)) return @ptrCast(&obj_shape);
    return host.list_list(pList, nIndex);
}

pub fn ring_list_gettype_gc(_: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) c_uint {
    if (is(pList, &obj_shape)) return if (nIndex == 1 or nIndex == 2) ITEMTYPE_LIST else 0;
    if (isPair(pList)) return if (nIndex == 1) ITEMTYPE_STRING else 0;
    return switch (@as(Tag, @enumFromInt(host.list_tag(pList, nIndex)))) {
        .str => ITEMTYPE_STRING,
        .int, .num => ITEMTYPE_NUMBER,
        .list, .obj => ITEMTYPE_LIST,
        else => 0,
    };
}

pub fn ring_list_isnumber_gc(s: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) c_uint {
    return if (ring_list_gettype_gc(s, pList, nIndex) == ITEMTYPE_NUMBER) 1 else 0;
}

pub fn ring_list_isstring_gc(s: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) c_uint {
    return if (ring_list_gettype_gc(s, pList, nIndex) == ITEMTYPE_STRING) 1 else 0;
}

pub fn ring_list_islist_gc(s: ?*anyopaque, pList: *anyopaque, nIndex: c_uint) c_uint {
    return if (ring_list_gettype_gc(s, pList, nIndex) == ITEMTYPE_LIST) 1 else 0;
}

pub fn ring_item_getnumber(pItem: *anyopaque) f64 {
    const it = itemOf(pItem);
    if (is(it.list, &obj_shape) or isPair(it.list)) return 0;
    return host.list_num(it.list, it.idx);
}

/// NEVER null for a string item, an EMPTY one included: Ring's own reads
/// `cStr` out of its String struct, which always points at a buffer, and
/// the bridges treat null as "not a string" -- `orelse continue` in the
/// list marshaller -- so every "" in a list was DROPPED on its way into the
/// engine: CountEmptyStrings answered 0 for [ "A", '', "B", '', '' ]
/// (list/05_containsemptystrings), and the reactor's packer refused the
/// list outright. A null stays null only for an item that is no string.
pub fn ringItemStringPtr(pItem: *anyopaque) ?[*]const u8 {
    const it = itemOf(pItem);
    if (is(it.list, &self_pair)) return if (it.idx == 1) "self" else null;
    if (is(it.list, &super_pair)) return if (it.idx == 1) "super" else null;
    if (is(it.list, &obj_shape)) return null;
    var len: u32 = 0;
    const s = host.list_str(it.list, it.idx, &len);
    if (len == 0) {
        if (host.list_tag(it.list, it.idx) != @intFromEnum(Tag.str)) return null;
        return "";
    }
    return s;
}

pub fn ringItemStringSize(pItem: *anyopaque) c_uint {
    const it = itemOf(pItem);
    if (is(it.list, &self_pair)) return if (it.idx == 1) 4 else 0;
    if (is(it.list, &super_pair)) return if (it.idx == 1) 5 else 0;
    if (is(it.list, &obj_shape)) return 0;
    var len: u32 = 0;
    _ = host.list_str(it.list, it.idx, &len);
    return len;
}

pub fn ringItemListPtr(pItem: *anyopaque) ?*anyopaque {
    const it = itemOf(pItem);
    const l: *anyopaque = it.list orelse return null;
    return ring_list_getlist_gc(null, l, it.idx);
}

pub fn ringListSize(pList: *anyopaque) c_uint {
    if (is(pList, &obj_shape)) return 2;
    if (isPair(pList)) return 1;
    return host.list_len(pList);
}

/// Ring reads a string's length out of its own struct. Here a string is
/// only ever reached through an item, so this takes the same shim.
pub fn ring_string_size(pString: *anyopaque) c_uint {
    return ringItemStringSize(pString);
}

pub const RingString = extern struct { cStr: [*]const u8, nSize: c_uint };
/// Ring's List layout is not shared -- a Ring++ list is opaque. The name
/// exists so a bridge that mentions the type still compiles; `ringListSize`
/// is what reads a size, and it asks the host.
pub const RingList = opaque {};

pub const gl = ring_vm_api_getlist;
pub const il = ring_vm_api_islist;

// ---- lists: writing ---------------------------------------------------

pub fn ring_vm_api_newlist(_: *anyopaque) ?*anyopaque {
    return host.list_new();
}

pub fn ring_vm_api_retlist(p: *anyopaque, pList: *anyopaque) void {
    ctxOf(p).out.* = .{ .bits = @intFromPtr(pList), .tag = @intFromEnum(Tag.list) };
}

pub fn ring_list_addint(pList: *anyopaque, x: c_int) void {
    host.list_push_num(pList, @floatFromInt(x));
}

pub fn ring_list_adddouble(pList: *anyopaque, x: f64) void {
    host.list_push_num(pList, x);
}

pub fn ring_list_addstring(pList: *anyopaque, cStr: [*:0]const u8) void {
    const s = std.mem.span(cStr);
    host.list_push_str(pList, s.ptr, @intCast(s.len));
}

pub fn ring_list_addstring2(pList: *anyopaque, cStr: [*]const u8, nSize: c_uint) void {
    host.list_push_str(pList, cStr, nSize);
}

/// Ring makes the sublist INSIDE its parent and hands it back. The host's
/// push transfers the new list's build reference to the parent, so the
/// pointer stays usable afterwards -- the parent holds it.
pub fn ring_list_newlist(pList: *anyopaque) ?*anyopaque {
    const inner = host.list_new();
    host.list_push_list(pList, inner);
    return inner;
}

// ---- registration -----------------------------------------------------

pub const Reg = struct { name: [*:0]const u8, func: *const fn (*anyopaque) callconv(.c) void };

/// The largest DLL registers 534 names (stz_string); the whole engine
/// registers 2,495 across 88 files, and each links its own copy of this.
const MAX_FUNCS = 1024;

var slots: [MAX_FUNCS]?*const fn (*anyopaque) callconv(.c) void = .{null} ** MAX_FUNCS;
var slot_count: usize = 0;

fn Adapter(comptime i: usize) type {
    return struct {
        fn call(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
            const f = slots[i] orelse return 1;
            var c = Ctx{ .args = args, .argc = argc, .out = out };
            f(@ptrCast(&c));
            if (!c.failed) return 0;
            // the message, in place of whatever the bridge answered before
            // it raised (src/native.zig, RppFn)
            out.* = .{
                .bits = @intFromPtr(&last_error),
                .tag = @intFromEnum(Tag.str),
                .len = @intCast(last_error_len),
            };
            return 1;
        }
    };
}

const adapters: [MAX_FUNCS]RppFn = blk: {
    @setEvalBranchQuota(MAX_FUNCS * 64);
    var t: [MAX_FUNCS]RppFn = undefined;
    for (0..MAX_FUNCS) |i| t[i] = &Adapter(i).call;
    break :blk t;
};

/// The engine's own entry point calls this with the same `regs` table it
/// gives `ringlib_init`. `state` is unused: Ring++ registers by name.
pub fn registerAll(state: *anyopaque, regs: []const Reg) void {
    _ = state;
    for (regs) |r| {
        if (slot_count == MAX_FUNCS) return;
        slots[slot_count] = r.func;
        host.register(r.name, adapters[slot_count]);
        slot_count += 1;
    }
}

/// Called by the DLL's `rpp_init` before anything else.
pub fn setHost(h: *const HostApi) void {
    host = h;
}
