//! The Ring++ native ABI, version 1.
//!
//! Softanza reaches its Zig engine through a handle protocol:
//!
//!     _pH_ = StzEngineString(_cStr_)        string  -> handle
//!     _pR_ = StzEngineStringToUpper(_pH_)   handle  -> handle
//!     _c_  = StzEngineStringData(_pR_)      handle  -> string
//!            StzEngineStringFree(_pR_)      handle  -> void
//!
//! so the ABI needs exactly four things to cross: an integer, a double, a
//! borrowed string, and an opaque handle. Nothing else.
//!
//! WHY NOT RING'S ABI. Ring's extensions are compiled against its C API
//! and speak in its List/Item structures. Loading them unchanged would
//! drag those structures back into a runtime built to leave them behind.
//! This ABI is deliberately smaller than Ring's, because a Ring++ value
//! is 16 bytes and needs no unpacking.
//!
//! OWNERSHIP, which is the only rule an engine author must remember:
//!
//!   * strings passed IN are BORROWED and valid only for the call;
//!   * a string returned OUT is COPIED by the VM before the call returns,
//!     so the engine may point at its own arena and reuse it immediately;
//!   * handles are opaque to the VM. It never frees one. The Ring code
//!     frees them, exactly as it does today.
//!
//! Nothing is shared between the two allocators, in either direction.

const std = @import("std");
const handles = @import("handles.zig");

pub const Tag = enum(u32) {
    nil = 0,
    int = 1,
    num = 2,
    str = 3,
    handle = 4,
    /// A Ring LIST. Unlike the four above, a list is not a value that can be
    /// flattened into these sixteen bytes: `bits` is an opaque handle to a
    /// vector the VM owns, and the engine reads or builds it through the
    /// host callbacks below. Added 2026-09-10 for Softanza's engine, where
    /// 833 of 1,775 boundary calls carry a list.
    list = 5,
    /// An OBJECT inside a list, answered by `list_tag` only, so the engine
    /// backend can present it in Ring's object layout and the marshallers
    /// keep its position (2026-10-02). It was `nil`, and every object was
    /// skipped on its way into the engine. Never an argument or a result.
    obj = 6,
};

/// One value crossing the boundary. Sixteen bytes, C layout, no pointers
/// into VM internals.
pub const RppVal = extern struct {
    /// i64, f64 bits, or a pointer -- read according to `tag`.
    bits: u64 = 0,
    tag: u32 = @intFromEnum(Tag.nil),
    /// The byte length, for `.str` only. Zero otherwise.
    len: u32 = 0,

    pub fn int(x: i64) RppVal {
        return .{ .bits = @bitCast(x), .tag = @intFromEnum(Tag.int) };
    }
    pub fn num(x: f64) RppVal {
        return .{ .bits = @bitCast(x), .tag = @intFromEnum(Tag.num) };
    }
    pub fn str(s: []const u8) RppVal {
        return .{
            .bits = @intFromPtr(s.ptr),
            .tag = @intFromEnum(Tag.str),
            .len = @intCast(s.len),
        };
    }
    pub fn handle(p: ?*anyopaque) RppVal {
        return .{ .bits = @intFromPtr(p), .tag = @intFromEnum(Tag.handle) };
    }
    pub fn list(p: RppList) RppVal {
        return .{ .bits = @intFromPtr(p), .tag = @intFromEnum(Tag.list) };
    }
    pub fn asList(self: RppVal) RppList {
        return @ptrFromInt(self.bits);
    }

    pub fn asInt(self: RppVal) i64 {
        return @bitCast(self.bits);
    }
    pub fn asNum(self: RppVal) f64 {
        return @bitCast(self.bits);
    }
    pub fn asStr(self: RppVal) []const u8 {
        const p: [*]const u8 = @ptrFromInt(self.bits);
        return p[0..self.len];
    }
};

/// A function an engine exports. Returns 0 on success; anything else is
/// an error, and then `out`, when it holds a string, is the error's message
/// -- borrowed, copied by the VM before the call returns -- which the VM
/// raises as Ring raises a bridge's error, catchable (F-103, 2026-10-09). An
/// engine that leaves `out` empty still raises, under a generic message.
pub const RppFn = *const fn (
    args: [*]const RppVal,
    argc: u32,
    out: *RppVal,
) callconv(.c) c_int;

/// Handed to the engine so it can publish its functions by name.
pub const RppRegister = *const fn (
    name: [*:0]const u8,
    f: RppFn,
) callconv(.c) void;

/// An opaque handle to a list the VM owns. Never dereferenced by the engine.
pub const RppList = ?*anyopaque;

/// What the VM offers the engine, handed to `rpp_init` once.
///
/// The four scalar types cross inside `RppVal` and need nothing here; an
/// engine that only moves numbers, strings and handles uses `register` and
/// ignores the rest. Lists need callbacks because a list is the VM's, not
/// the engine's: nothing is shared between the two allocators, in either
/// direction, and that rule is what these preserve.
///
/// OWNERSHIP, and there is exactly one rule to remember:
///
///   * `list_new` hands back a list holding ONE reference on the engine's
///     behalf, so a collection during the build cannot free it;
///   * `list_push_list` TRANSFERS that reference into the parent. The
///     engine must not touch the inner handle afterwards;
///   * the list finally placed in `out` transfers its reference to the VM.
///
/// Numbers and strings pushed are copied, exactly as a returned string is.
/// A list arrives as an argument BORROWED: it is valid for the call and
/// must not be kept.
pub const HostApi = extern struct {
    register: RppRegister,
    // ---- building a list to return ----
    list_new: *const fn () callconv(.c) RppList,
    list_push_num: *const fn (RppList, f64) callconv(.c) void,
    list_push_str: *const fn (RppList, [*]const u8, u32) callconv(.c) void,
    list_push_list: *const fn (RppList, RppList) callconv(.c) void,
    // ---- reading a list that arrived ----
    list_len: *const fn (RppList) callconv(.c) u32,
    /// The `Tag` of item `i`, 1-based as Ring counts. `nil` when out of range.
    list_tag: *const fn (RppList, u32) callconv(.c) u32,
    list_num: *const fn (RppList, u32) callconv(.c) f64,
    list_str: *const fn (RppList, u32, *u32) callconv(.c) [*]const u8,
    list_list: *const fn (RppList, u32) callconv(.c) RppList,
    // ---- ONE handle table, the host's (ABI 3, 2026-10-22) ----
    // RINGPP-HOST-HANDLES-01 and RINGPP-CPTR-RETIRE-01 (stzlib-security, SECURITY-R16): a Ring copy of an object a
    // native library destroyed read freed, reused memory with no error, and ids could not cross DLLs because every
    // library had a table of its own. The host keeps one (src/handles.zig). An id is `generation * 2^32 + slot + 1`,
    // exact in an f64; a release bumps the slot's generation, so every copy of the old id is STALE.
    //
    //   handle_store    the id of a pointer; a pointer that is already live gets the id it has (one object, one id);
    //                   0 for null, or when the table cannot grow
    //   handle_resolve  the pointer, or null: id 0, malformed, never issued, released or retired
    //   handle_state    0 unknown (not an id), 1 live, 2 stale (an id this table issued, no longer valid): a bridge
    //                   raises for 2 and stays quiet for NULL
    //   handle_release  retire the id (every copy goes stale), answer the pointer for the caller to free; a stale or
    //                   unknown id releases nothing
    //   handle_retire   the library freed a pointer WITHOUT holding its id: retire the id it has, if any (1) or none (0)
    //
    // An engine built for ABI 2 never reads these and keeps its own table; one built for 3 must run on a host that
    // speaks 3 (`rpp_abi_version`, checked at load).
    handle_store: *const fn (?*anyopaque) callconv(.c) f64,
    handle_resolve: *const fn (f64) callconv(.c) ?*anyopaque,
    handle_state: *const fn (f64) callconv(.c) c_int,
    handle_release: *const fn (f64) callconv(.c) ?*anyopaque,
    handle_retire: *const fn (?*anyopaque) callconv(.c) c_int,
};

/// THE table: one per process, whichever library asks.
pub var handle_table = handles.Table.init(std.heap.page_allocator);

pub fn hostHandleStore(p: ?*anyopaque) callconv(.c) f64 {
    return handle_table.store(p);
}
pub fn hostHandleResolve(id: f64) callconv(.c) ?*anyopaque {
    return handle_table.resolve(id);
}
pub fn hostHandleState(id: f64) callconv(.c) c_int {
    return @intFromEnum(handle_table.state(id));
}
pub fn hostHandleRelease(id: f64) callconv(.c) ?*anyopaque {
    return handle_table.release(id);
}
pub fn hostHandleRetire(p: ?*anyopaque) callconv(.c) c_int {
    return if (handle_table.retirePtr(p)) 1 else 0;
}

/// Filled by the VM at startup and handed to every engine that loads.
pub var host_api: HostApi = undefined;

/// The one symbol a Ring++ engine must export:
///
///     export fn rpp_init(host: *const HostApi) callconv(.c) c_int
///
/// It registers every function it offers and returns 0.
pub const INIT_SYMBOL = "rpp_init";

/// The ABI version this build speaks. An engine may export
/// `rpp_abi_version` returning this; absent, version 1 is assumed. An engine that
/// exports a number ABOVE this is refused at load (`too_new`): it would read the
/// vtable past its end.
///
/// **3** since 2026-10-22: the HostApi ends with the host's handle table (store,
/// resolve, state, release, retire). The table only grew at its end, so an engine
/// built for 2 loads and runs as before.
///
/// **2** since 2026-09-10: `rpp_init` receives a `*const HostApi` where it
/// received a bare `RppRegister`, and `Tag.list` exists. Version 1 engines
/// do not load -- the change is in the init signature, so a stale engine
/// would read a vtable pointer as a function pointer. There is one version 1
/// engine in the world (`bench/engine_shim.zig`) and it moved with the ABI.
pub const VERSION: u32 = 3;

// ---------------------------------------------------------------- registry

pub const Entry = struct { name: []const u8, f: RppFn };

/// Registered natives, by name. Small and linear on purpose: a lookup
/// happens once per call site at load time, not once per call.
pub var entries: std.ArrayListUnmanaged(Entry) = .{};
pub var reg_alloc: ?std.mem.Allocator = null;

/// The callback hand ed to `rpp_init`. Names are copied, because the
/// engine's own string table may be unloaded before we are.
pub fn register(name: [*:0]const u8, f: RppFn) callconv(.c) void {
    const a = reg_alloc orelse return;
    const src = std.mem.span(name);
    const owned = a.alloc(u8, src.len) catch return;
    @memcpy(owned, src);
    entries.append(a, .{ .name = owned, .f = f }) catch {};
}

pub fn find(name: []const u8) ?RppFn {
    // Ring resolves these names case-insensitively, so this does too.
    for (entries.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, name)) return e.f;
    }
    return null;
}

/// What `LoadLib(path)` found, told apart the way RING tells them apart --
/// `vendor/ring-vm/src/dll_e.c:51` and `:57`:
///
///     could not open it at all          -> R38
///     opened, but no init function      -> R46
///
/// Ring looks for `ringlib_init` and we look for `rpp_init`, which is the
/// whole of the difference. An earlier note here said Ring "has no case for
/// you could load this and I cannot" and used that to justify answering
/// NULL instead of raising. It was wrong: R46 IS that case.
pub const LoadResult = enum { ok, cannot_open, no_init, too_new };

pub fn loadLib(alloc: std.mem.Allocator, path: []const u8) LoadResult {
    reg_alloc = alloc;
    var lib = std.DynLib.open(path) catch return .cannot_open;
    const init = lib.lookup(*const fn (*const HostApi) callconv(.c) c_int, INIT_SYMBOL) orelse {
        lib.close();
        return .no_init;
    };
    // An engine built for a LATER host would read the vtable past its end: refuse it by name rather than let it find garbage.
    if (lib.lookup(*const fn () callconv(.c) u32, "rpp_abi_version")) |ver| {
        if (ver() > VERSION) {
            lib.close();
            return .too_new;
        }
    }
    host_api.register = &register;
    return if (init(&host_api) == 0) .ok else .no_init;
}
