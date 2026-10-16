//! COMPILATION AS A STEP THAT ENDS.
//!
//! `rnxc` reads 613 files, parses them and compiles them before a Softanza
//! program executes its first statement: 7.28 s measured 2026-09-14, against
//! Ring's 3.06 s, of which 3.38 s is tree-sitter and the rest is the
//! compiler. Every run pays it again, and nothing in those 613 files changed
//! between one run and the next.
//!
//! `src/rnxc.zig` already draws the line this needs. At the end of
//! compilation everything the VM will ever read is copied into the VM's own
//! heap and the compiler's arena is thrown away whole -- code, the row/file
//! tables, the dispatch and method tables, the constants, and every string,
//! because names and constants point into the SOURCE TEXT. That copy is a
//! self-contained runtime image. This module writes it to a file and reads it
//! back, so the second run of a program starts at the first statement.
//!
//! WHAT MAKES IT SOUND. An image is used only when the exact binary that
//! wrote it is asking, and only when every source file that went into it is
//! byte-for-byte what it was:
//!
//!   * the executable's own size and mtime are in the header, so any rebuild
//!     of rnxc invalidates every image without anyone remembering to bump a
//!     version. This also means the file is only ever read back by the build
//!     that wrote it, which is why the tables can be written as raw bytes
//!     without pinning down a single field's layout;
//!   * a MANIFEST of every file in the load unit -- path, length and a hash
//!     of its contents -- is checked before anything else is read. Re-reading
//!     and hashing the 613 files costs 0.07 s, measured: it is the same read
//!     the compiler does, without the parse;
//!   * VERSION is bumped by hand when this format changes, for the case the
//!     mtime check cannot see.
//!
//! ANY doubt is a MISS, never a failure: a short file, a bad magic, an I/O
//! error, a file that moved. A cache that cannot be read means the compiler
//! runs, which is exactly what happened before this existed.
//!
//! WHAT IT DOES NOT DO. The unit is keyed as a whole, so a DIFFERENT root
//! file is a different image even though 613 of its 614 files are the same.
//! Repeat runs of one program get this; a sweep over thousands of distinct
//! test files does not. That needs the library's compiled form to be
//! extensible -- a second piece of work, and a larger one.

const std = @import("std");
const vm = @import("main.zig");

/// Bumped by hand when the layout below changes in a way the executable's
/// own fingerprint would not catch (it nearly always would).
pub const VERSION: u32 = 4; // 2: class_parent and fn_owner (2026-09-23); 3: the locals tables and class_attrs_fn, for eval (2026-09-25); 4: the accessor tables, for getters and setters (2026-09-26)
const MAGIC: [8]u8 = "RNXIMG\x00\x00".*;

/// One source file as it was when the image was written.
pub const Stamp = struct { path: []const u8, len: u64, hash: u64 };

/// Everything the VM reads that compilation produced. The field list is the
/// freeze in rnxc.zig, and the two must be changed together: a table missing
/// here is a table the warm path leaves empty, which is a silent wrong
/// answer rather than a crash.
pub const Parts = struct {
    code: []vm.Instr,
    rows: []u32,
    files: []u16,
    fn_of: []u32,
    fn_entry: []u32,
    fn_frame: []u8,
    fn_method: []bool,
    names: []const []const u8,
    fn_names: []const []const u8,
    file_names: []const []const u8,
    dispatch: []u32,
    method_tab: []vm.MethodEnt,
    class_slots: []u32,
    attr_from: []u32,
    attr_ent: []vm.AttrEnt,
    global_names: []const []const u8,
    class_konst: []u32,
    class_parent: []u16,
    fn_owner: []u16,
    /// eval's view of every function (F-72): its locals, and each class's
    /// attribute prologue.
    fn_local_from: []u32,
    local_names: []const []const u8,
    local_regs: []u8,
    local_boxed: []bool,
    class_attrs_fn: []u32,
    /// Ring's automatic getters and setters (F-73): per attribute name,
    /// the name index of get<name> and set<name>, or vm.ACC_NONE.
    acc_get: []u32,
    acc_set: []u32,
    konst: []vm.Value,
    fn_masks: [64]u64,
    main_tramp: u32,
    nglobals: u32,
    main_fn: u32,
    n_names: u32,
    /// The two notes rnxc prints when the top level did not fully compile.
    /// Carried so a warm run says exactly what a cold run says.
    poisoned_own: bool,
    poisoned: bool,
};

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    _pad: u32 = 0,
    exe_size: u64,
    exe_mtime: i64,
    main_tramp: u32,
    nglobals: u32,
    main_fn: u32,
    n_names: u32,
    nstamps: u32,
    poisoned_own: u32,
    poisoned: u32,
    _pad2: u32 = 0,
};

/// Size and mtime of the running executable. Any rebuild changes one of
/// them, and an image written by another build is then a miss.
pub const ExeStamp = struct {
    size: u64 = 0,
    mtime: i64 = 0,

    pub fn ofSelf(alloc: std.mem.Allocator) ExeStamp {
        const p = std.fs.selfExePathAlloc(alloc) catch return .{};
        const f = std.fs.cwd().openFile(p, .{}) catch return .{};
        defer f.close();
        const st = f.stat() catch return .{};
        return .{ .size = st.size, .mtime = @truncate(st.mtime) };
    }
};

pub fn hashOf(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x726e7869, bytes);
}

/// Read a file into a buffer that is REUSED across the whole manifest.
///
/// Verifying 613 sources with one allocation each, freed as it goes, leaves
/// the allocator holding a free pool the size of the corpus -- and
/// perf/engine_senses measures exactly that, asserting that a 40 MB
/// allocation is visible in rss. It is not, if 20 MB of it can be served
/// from what the manifest check just handed back. One buffer, grown to the
/// largest file and reused, leaves that much and no more.
pub fn readReusing(
    alloc: std.mem.Allocator,
    path: []const u8,
    buf: *[]u8,
) ?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const st = f.stat() catch return null;
    const n: usize = @intCast(st.size);
    if (buf.*.len < n) {
        const bigger = alloc.alloc(u8, n) catch return null;
        if (buf.*.len > 0) alloc.free(buf.*);
        buf.* = bigger;
    }
    const got = f.readAll(buf.*[0..n]) catch return null;
    if (got != n) return null;
    return buf.*[0..n];
}

/// `RNXC_IMAGE=1` makes every hit and miss say why. A cache that silently
/// never engages looks exactly like one that is working, which is how the
/// first version of this was measured as "11x faster" while three quarters
/// of its runs were quietly recompiling.
pub var explain: bool = false;

/// RNXC_IMAGE_SEPKONST=1: give every restored constant its own allocation
/// instead of one packed blob. A diagnostic, not a fix -- if a bug goes away
/// under it, something is reading past the end of a string and the packed
/// blob is only what made that visible.
pub var separate_konst: bool = false;

pub fn say(comptime fmt: []const u8, args: anytype) void {
    if (explain) std.debug.print("image: " ++ fmt ++ "\n", args);
}

// ------------------------------------------------------------- writing

pub const Buf = std.ArrayListUnmanaged(u8);

pub const W = struct {
    b: Buf = .{},
    a: std.mem.Allocator,

    pub fn pad(self: *W) !void {
        while (self.b.items.len % 16 != 0) try self.b.append(self.a, 0);
    }
    pub fn u32v(self: *W, x: u32) !void {
        try self.b.appendSlice(self.a, std.mem.asBytes(&x));
    }
    pub fn u64v(self: *W, x: u64) !void {
        try self.b.appendSlice(self.a, std.mem.asBytes(&x));
    }
    pub fn bytes(self: *W, s: []const u8) !void {
        try self.u64v(s.len);
        try self.b.appendSlice(self.a, s);
        try self.pad();
    }
    pub fn slice(self: *W, comptime T: type, s: []const T) !void {
        try self.u64v(s.len);
        try self.b.appendSlice(self.a, std.mem.sliceAsBytes(s));
        try self.pad();
    }
    pub fn strings(self: *W, s: []const []const u8) !void {
        try self.u64v(s.len);
        var total: u64 = 0;
        for (s) |e| total += e.len;
        for (s) |e| try self.u64v(e.len);
        try self.u64v(total);
        for (s) |e| try self.b.appendSlice(self.a, e);
        try self.pad();
    }
};

/// The dispatch table is `nclasses * nnames` u32s and is nearly all zeros --
/// a class answers a few dozen of the 38,428 names in the estate. Written as
/// its length plus the entries that are not zero, which is the difference
/// between a file that is mostly holes and one that is not.
fn writeDispatch(w: *W, d: []const u32) !void {
    var n: u64 = 0;
    for (d) |x| {
        if (x != 0) n += 1;
    }
    try w.u64v(d.len);
    try w.u64v(n);
    for (d, 0..) |x, i| {
        if (x == 0) continue;
        try w.u32v(@intCast(i));
        try w.u32v(x);
    }
    try w.pad();
}

/// A constant is a number or a string -- the compiler puts nothing else in
/// the table. Strings are written as tag + length here and their bytes into
/// one blob, so reading back is one allocation and a walk.
pub fn writeKonst(w: *W, k: []const vm.Value) !void {
    try w.u64v(k.len);
    var total: u64 = 0;
    for (k) |v| {
        if (v.tag == .str) total += v.p.s.len;
    }
    for (k) |v| {
        try w.u32v(@intFromEnum(v.tag));
        const n: u32 = if (v.tag == .str) v.p.s.len else 0;
        try w.u32v(n);
        const payload: u64 = if (v.tag == .str) 0 else @bitCast(v.p.i);
        try w.u64v(payload);
    }
    try w.u64v(total);
    for (k) |v| {
        if (v.tag == .str) try w.b.appendSlice(w.a, v.p.s.ptr[0..v.p.s.len]);
    }
    try w.pad();
}

/// Written to a temporary name and renamed over, because perf/driven_load
/// starts eight children of the same script at once and every one of them
/// misses on the first run.
pub fn save(
    alloc: std.mem.Allocator,
    path: []const u8,
    exe: ExeStamp,
    stamps: []const Stamp,
    p: Parts,
) !void {
    var w = W{ .a = alloc };
    defer w.b.deinit(alloc);

    const h = Header{
        .magic = MAGIC,
        .version = VERSION,
        .exe_size = exe.size,
        .exe_mtime = exe.mtime,
        .main_tramp = p.main_tramp,
        .nglobals = p.nglobals,
        .main_fn = p.main_fn,
        .n_names = p.n_names,
        .nstamps = @intCast(stamps.len),
        .poisoned_own = @intFromBool(p.poisoned_own),
        .poisoned = @intFromBool(p.poisoned),
    };
    try w.b.appendSlice(alloc, std.mem.asBytes(&h));
    try w.pad();

    for (stamps) |s| {
        try w.u64v(s.len);
        try w.u64v(s.hash);
        try w.bytes(s.path);
    }

    try w.slice(vm.Instr, p.code);
    try w.slice(u32, p.rows);
    try w.slice(u16, p.files);
    try w.slice(u32, p.fn_of);
    try w.slice(u32, p.fn_entry);
    try w.slice(u8, p.fn_frame);
    try w.slice(u8, @ptrCast(p.fn_method));
    try w.strings(p.names);
    try w.strings(p.fn_names);
    try w.strings(p.file_names);
    try writeDispatch(&w, p.dispatch);
    try w.slice(vm.MethodEnt, p.method_tab);
    try w.slice(u32, p.class_slots);
    try w.slice(u32, p.attr_from);
    try w.slice(vm.AttrEnt, p.attr_ent);
    try w.strings(p.global_names);
    try w.slice(u32, p.class_konst);
    try w.slice(u16, p.class_parent);
    try w.slice(u16, p.fn_owner);
    try w.slice(u32, p.fn_local_from);
    try w.strings(p.local_names);
    try w.slice(u8, p.local_regs);
    try w.slice(bool, p.local_boxed);
    try w.slice(u32, p.class_attrs_fn);
    try w.slice(u32, p.acc_get);
    try w.slice(u32, p.acc_set);
    try writeKonst(&w, p.konst);
    try w.slice(u64, &p.fn_masks);

    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    var tmp_buf: [512]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, std.Thread.getCurrentId() }) catch return error.NameTooLong;
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(w.b.items);
    }
    std.fs.cwd().rename(tmp, path) catch {
        std.fs.cwd().deleteFile(tmp) catch {};
    };
}

// ------------------------------------------------------------- reading

/// EACH SECTION IS READ STRAIGHT INTO THE PLACE IT WILL LIVE. The first
/// version of this slurped the whole 40 MB file and then copied every table
/// out of it, which left the process holding both -- and it showed, in the
/// two places in the estate that measure memory rather than answers:
/// metrics_monitor read 232 MB where a compiling run read 152, and
/// engine_senses' "a 40 MB allocation is visible in rss" FAILED, because a
/// 40 MB buffer had just been freed and the allocator answered out of it
/// without asking the OS for anything. A cache that changes what a program
/// observes about itself is not transparent, whatever its output says.
pub const R = struct {
    f: std.fs.File,
    off: usize = 0,

    pub fn readInto(self: *R, dst: []u8) !void {
        const n = try self.f.readAll(dst);
        if (n != dst.len) {
            say("short read at {d}: wanted {d}, got {d}", .{ self.off, dst.len, n });
            return error.Corrupt;
        }
        self.off += n;
    }
    /// Sections start on 16-byte boundaries so nothing has to care about
    /// where the section before it ended.
    pub fn pad(self: *R) !void {
        var skip: [16]u8 = undefined;
        const n = (16 - (self.off % 16)) % 16;
        if (n != 0) try self.readInto(skip[0..n]);
    }
    pub fn u32v(self: *R) !u32 {
        var b: [4]u8 = undefined;
        try self.readInto(&b);
        return std.mem.bytesToValue(u32, &b);
    }
    pub fn u64v(self: *R) !u64 {
        var b: [8]u8 = undefined;
        try self.readInto(&b);
        return std.mem.bytesToValue(u64, &b);
    }
    pub fn bytes(self: *R, a: std.mem.Allocator) ![]u8 {
        const n: usize = @intCast(try self.u64v());
        const out = try a.alloc(u8, n);
        try self.readInto(out);
        try self.pad();
        return out;
    }
    pub fn slice(self: *R, comptime T: type, a: std.mem.Allocator) ![]T {
        const n: usize = @intCast(try self.u64v());
        const out = try a.alloc(T, n);
        try self.readInto(std.mem.sliceAsBytes(out));
        try self.pad();
        return out;
    }
    pub fn strings(self: *R, a: std.mem.Allocator) ![]const []const u8 {
        const n: usize = @intCast(try self.u64v());
        const lens = try a.alloc(u64, n);
        defer a.free(lens);
        try self.readInto(std.mem.sliceAsBytes(lens));
        const total: usize = @intCast(try self.u64v());
        const blob = try a.alloc(u8, if (total == 0) 1 else total);
        if (total > 0) try self.readInto(blob[0..total]) else blob[0] = 0;
        try self.pad();
        const out = try a.alloc([]const u8, n);
        var off: usize = 0;
        for (out, 0..) |*e, ix| {
            const l: usize = @intCast(lens[ix]);
            if (off + l > blob.len) {
                say("strings blob overrun", .{});
                return error.Corrupt;
            }
            e.* = blob[off .. off + l];
            off += l;
        }
        return out;
    }
};

/// The dispatch table is the largest thing here -- 24 million u32s on the
/// Softanza unit, 96 MB, of which about 1.9 million are not zero. It is read
/// back in CHUNKS and scattered as they arrive, so the holes never exist on
/// disk and the pairs never exist in memory.
///
/// THE CHUNK IS ON THE HEAP, AND THAT IS NOT A STYLE CHOICE. With a 16 KB
/// STACK array here instead, `readAll` returned the full count and the array
/// came back UNWRITTEN under ReleaseFast -- the first pair read 959,590,912
/// where the file holds 9, checked byte by byte from outside. The same source
/// built ReleaseSafe read it correctly, and a standalone program doing the
/// same read is correct in both. Reproduced deliberately after the fact, both
/// ways, on 2026-09-14. The cause is NOT established; what is established is
/// that this is where it happened and that the heap buffer does not do it.
fn readDispatch(r: *R, a: std.mem.Allocator) ![]u32 {
    const n: usize = @intCast(try r.u64v());
    var pairs: usize = @intCast(try r.u64v());
    const out = try a.alloc(u32, n);
    @memset(out, 0);
    const chunk = try a.alloc(u32, 8192);
    defer a.free(chunk);
    while (pairs > 0) {
        const take = @min(pairs, chunk.len / 2);
        try r.readInto(std.mem.sliceAsBytes(chunk[0 .. take * 2]));
        var i: usize = 0;
        while (i < take) : (i += 1) {
            const ix: usize = chunk[i * 2];
            if (ix >= n) {
                say("dispatch index {d} of {d} at byte {d}", .{ ix, n, r.off });
                return error.Corrupt;
            }
            out[ix] = chunk[i * 2 + 1];
        }
        pairs -= take;
    }
    try r.pad();
    return out;
}

const KEnt = extern struct { tag: u32, len: u32, payload: u64 };

pub fn readKonst(r: *R, a: std.mem.Allocator) ![]vm.Value {
    const n: usize = @intCast(try r.u64v());
    const ents = try a.alloc(KEnt, n);
    defer a.free(ents);
    try r.readInto(std.mem.sliceAsBytes(ents));
    const total: usize = @intCast(try r.u64v());
    // At least one byte, always. A zero-length allocation hands back Zig's
    // alignment sentinel rather than an address, and `""` is a constant the
    // estate uses everywhere (the same trap dupKonst records).
    const blob = try a.alloc(u8, if (total == 0) 1 else total);
    if (total > 0) try r.readInto(blob[0..total]) else blob[0] = 0;
    try r.pad();

    const out = try a.alloc(vm.Value, n);
    var off: usize = 0;
    for (out, 0..) |*v, i| {
        const tag: vm.Tag = @enumFromInt(ents[i].tag);
        if (tag != .str) {
            v.* = .{ .p = .{ .i = @bitCast(ents[i].payload) }, .tag = tag };
            continue;
        }
        const l: usize = ents[i].len;
        if (off + l > blob.len) {
            say("konst blob overrun", .{});
            return error.Corrupt;
        }
        if (separate_konst) {
            const own = try a.alloc(u8, if (l == 0) 1 else l);
            if (l > 0) @memcpy(own[0..l], blob[off .. off + l]) else own[0] = 0;
            const sp2 = try a.create(vm.Str);
            sp2.* = .{ .ptr = own.ptr, .len = @intCast(l), .rc = vm.konst_rc, .cap = 0 };
            off += l;
            v.* = vm.Value.str(sp2);
            continue;
        }
        const sp = try a.create(vm.Str);
        // PINNED (vm.konst_rc), and cap 0 so the in-place append path can
        // never write through a constant -- the same contract dupKonst keeps.
        // The pin matters MOST here: these bytes are an interior pointer into
        // the shared blob above, so a release that reached zero would hand
        // the allocator an address it never gave out. That is the hang the
        // pin closes -- correct output, then a spin inside exit.
        sp.* = .{ .ptr = blob[off..].ptr, .len = @intCast(l), .rc = vm.konst_rc, .cap = 0 };
        off += l;
        v.* = vm.Value.str(sp);
    }
    return out;
}

/// Every file the image was built from, still byte-for-byte what it was.
/// The read is the same one the compiler would do; the parse is what is
/// saved. Returns false on the first file that moved, shrank or changed.
fn verify(alloc: std.mem.Allocator, r: *R, n: usize) bool {
    var buf: []u8 = &.{};
    defer if (buf.len > 0) alloc.free(buf);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const len = r.u64v() catch return false;
        const hash = r.u64v() catch return false;
        const path = r.bytes(alloc) catch return false;
        defer alloc.free(path);
        const src = readReusing(alloc, path, &buf) orelse return false;
        if (src.len != len) return false;
        if (hashOf(src) != hash) return false;
    }
    return true;
}

/// The image at `path`, or null -- which means "compile", and is the answer
/// for a missing file, another build's file, a changed source, a truncated
/// write and anything else that does not add up.
pub fn load(alloc: std.mem.Allocator, path: []const u8, exe: ExeStamp) ?Parts {
    const f = std.fs.cwd().openFile(path, .{}) catch {
        say("no image at {s}", .{path});
        return null;
    };
    defer f.close();
    var r = R{ .f = f };

    var hb: [@sizeOf(Header)]u8 = undefined;
    r.readInto(&hb) catch return null;
    const h = std.mem.bytesToValue(Header, &hb);
    if (!std.mem.eql(u8, &h.magic, &MAGIC)) return null;
    if (h.version != VERSION) return null;
    if (h.exe_size != exe.size or h.exe_mtime != exe.mtime) {
        say("written by another build ({d}/{d} against {d}/{d})", .{ h.exe_size, h.exe_mtime, exe.size, exe.mtime });
        return null;
    }

    r.pad() catch return null;
    if (!verify(alloc, &r, h.nstamps)) {
        say("a source file changed", .{});
        return null;
    }

    const p = loadBody(alloc, &r, h) catch |e| {
        say("unreadable at byte {d}: {s}", .{ r.off, @errorName(e) });
        return null;
    };
    say("used, {d} file(s)", .{h.nstamps});
    return p;
}

fn loadBody(alloc: std.mem.Allocator, r: *R, h: Header) !Parts {
    var p: Parts = undefined;
    p.code = try r.slice(vm.Instr, alloc);
    p.rows = try r.slice(u32, alloc);
    p.files = try r.slice(u16, alloc);
    p.fn_of = try r.slice(u32, alloc);
    p.fn_entry = try r.slice(u32, alloc);
    p.fn_frame = try r.slice(u8, alloc);
    p.fn_method = @ptrCast(try r.slice(u8, alloc));
    p.names = try r.strings(alloc);
    p.fn_names = try r.strings(alloc);
    p.file_names = try r.strings(alloc);
    p.dispatch = try readDispatch(r, alloc);
    p.method_tab = try r.slice(vm.MethodEnt, alloc);
    p.class_slots = try r.slice(u32, alloc);
    p.attr_from = try r.slice(u32, alloc);
    p.attr_ent = try r.slice(vm.AttrEnt, alloc);
    p.global_names = try r.strings(alloc);
    p.class_konst = try r.slice(u32, alloc);
    p.class_parent = try r.slice(u16, alloc);
    p.fn_owner = try r.slice(u16, alloc);
    p.fn_local_from = try r.slice(u32, alloc);
    p.local_names = try r.strings(alloc);
    p.local_regs = try r.slice(u8, alloc);
    p.local_boxed = try r.slice(bool, alloc);
    p.class_attrs_fn = try r.slice(u32, alloc);
    p.acc_get = try r.slice(u32, alloc);
    p.acc_set = try r.slice(u32, alloc);
    p.konst = try readKonst(r, alloc);
    const masks = try r.slice(u64, alloc);
    defer alloc.free(masks);
    if (masks.len != p.fn_masks.len) {
        say("masks {d}", .{masks.len});
        return error.Corrupt;
    }
    @memcpy(&p.fn_masks, masks);
    p.main_tramp = h.main_tramp;
    p.nglobals = h.nglobals;
    p.main_fn = h.main_fn;
    p.n_names = h.n_names;
    p.poisoned_own = h.poisoned_own != 0;
    p.poisoned = h.poisoned != 0;
    return p;
}

// --------------------------------------------------------- where it lives

/// `RNXC_CACHE` names it; otherwise the platform's own cache directory. Not
/// the source tree: an image is this machine's, it is derived, and Softanza's
/// tree belongs to someone else.
pub fn dir(alloc: std.mem.Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(alloc, "RNXC_CACHE")) |v| {
        if (v.len > 0) return v;
    } else |_| {}
    const home_var = if (@import("builtin").os.tag == .windows) "LOCALAPPDATA" else "XDG_CACHE_HOME";
    if (std.process.getEnvVarOwned(alloc, home_var)) |v| {
        if (v.len > 0) return std.fs.path.join(alloc, &.{ v, "rnxc", "images" }) catch null;
    } else |_| {}
    if (std.process.getEnvVarOwned(alloc, "HOME")) |v| {
        if (v.len > 0) return std.fs.path.join(alloc, &.{ v, ".cache", "rnxc", "images" }) catch null;
    } else |_| {}
    return null;
}

/// One image per root file, named by the hash of its absolute path. The
/// header and the manifest decide whether it may be used; this only has to
/// find it.
pub fn pathFor(alloc: std.mem.Allocator, root_abs: []const u8) ?[]const u8 {
    const d = dir(alloc) orelse return null;
    var key: [512]u8 = undefined;
    const n = @min(root_abs.len, key.len);
    for (root_abs[0..n], 0..) |c, i| key[i] = std.ascii.toLower(if (c == '\\') '/' else c);
    var name: [32]u8 = undefined;
    const fname = std.fmt.bufPrint(&name, "{x:0>16}.rnxi", .{hashOf(key[0..n])}) catch return null;
    return std.fs.path.join(alloc, &.{ d, fname }) catch null;
}

pub fn enabled(alloc: std.mem.Allocator) bool {
    if (std.process.getEnvVarOwned(alloc, "RNXC_NOCACHE")) |v| {
        defer alloc.free(v);
        return v.len == 0 or std.mem.eql(u8, v, "0");
    } else |_| {}
    return true;
}
