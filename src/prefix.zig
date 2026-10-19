//! THE LIBRARY AS A FILE.
//!
//! `src/image.zig` writes one compiled PROGRAM, keyed whole: change the root
//! file and it is a different image, even though 613 of its 614 files are
//! the same. That answers the developer running one test again. It does not
//! answer a SWEEP -- 5,143 files in `base/test`, each a different root, each
//! paying 7.28 s of read, parse and compile for the same library.
//!
//! This is the other half. It writes the COMPILER's state once the library
//! has been compiled -- its functions, classes, names, globals, constants,
//! and the code already emitted for them -- so a later run restores it and
//! compiles ONE file on top. The compiler side is `compilePrefix` and
//! `compileOnto`, and the three cases where that is NOT allowed are in
//! `prefixApplies`.
//!
//! WHAT IS DELIBERATELY NOT WRITTEN is everything only a function's own
//! emission needs: its statements, its locals, its parse tree. They are the
//! bulk of the compiler and nothing compiled later can reach them. A
//! function that comes back from here can be CALLED -- its entry, frame,
//! parameters, declared types and poison are all here -- and cannot be
//! re-emitted, which is exactly the deal.
//!
//! Soundness is the same as image.zig's and for the same reasons: the
//! executable's own size and mtime in the header, so a rebuild invalidates
//! everything; a manifest of every library file, verified by re-reading and
//! hashing before anything else is read; and any doubt is a MISS.

const std = @import("std");
const vm = @import("main.zig");
const co = @import("compile.zig");
const image = @import("image.zig");

/// 2: every function's locals (name, register, boxed) travel with it, so
/// an `eval` inside a library function can bind its string to the
/// caller's frame on the prefix path as it does on the image path (F-72).
/// Without them evalAssign fell through to the plain assignment and
/// twelve wide-clock rows crashed in the eval compiler (2026-09-25).
/// 3: each library file's NAME as Ring reports it beside its path -- the
/// folder it was loaded from, the platform separator, the load as written
/// (F-111); the path alone cannot say where the folder ends.
pub const VERSION: u32 = 3;
const MAGIC: [8]u8 = "RNXPFX\x00\x00".*;

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    _pad: u32 = 0,
    exe_size: u64,
    exe_mtime: i64,
    nstamps: u32,
    main_fn: u32,
    has_main: u32,
    stmts_ok: u32,
    stmts_bad: u32,
    stmts_native: u32,
    spread_direct: u64,
    spread_dyn: u64,
};

/// Everything a LATER file can ask about a function: how to call it, what it
/// answers, and whether it is fit to call. Its body is not here.
const PFunc = extern struct {
    entry: u32,
    id: u32,
    mask: u64,
    tramp: u32,
    body_from: u32,
    nparams: u32,
    nhints: u32,
    owner: u16,
    name_idx: u16,
    frame: u8,
    ret: u8,
    ret_elem: u8,
    /// 1 poisoned, 2 poisoned_own, 4 is_main, 8 called, 16 emitted, 32 owned
    flags: u8,
};

const PClass = extern struct {
    attrs_fn: u32,
    nattrs: u32,
    nmethods: u32,
    /// How many of the class's attributes came from its parent. The
    /// layout is rebuilt from the class's OWN declarations, so this is the
    /// line between the two and it has to survive the prefix.
    inherited: u32,
    parent: u16,
    id: u16,
    /// 1 has parent, 2 attrs_done, 4 has attrs_fn
    flags: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

// ------------------------------------------------------------- writing

pub fn save(
    alloc: std.mem.Allocator,
    path: []const u8,
    exe: image.ExeStamp,
    stamps: []const image.Stamp,
    /// parallel to stamps: each file as Ring names it in a report
    file_names: []const []const u8,
    c: *co.Compiler,
) !void {
    var w = image.W{ .a = alloc };
    defer w.b.deinit(alloc);

    const h = Header{
        .magic = MAGIC,
        .version = VERSION,
        .exe_size = exe.size,
        .exe_mtime = exe.mtime,
        .nstamps = @intCast(stamps.len),
        .main_fn = c.prefix_main orelse 0,
        .has_main = @intFromBool(c.prefix_main != null),
        .stmts_ok = c.stmts_ok,
        .stmts_bad = c.stmts_bad,
        .stmts_native = @intCast(c.stmts_native),
        .spread_direct = c.spread_direct,
        .spread_dyn = c.spread_dyn,
    };
    try w.b.appendSlice(alloc, std.mem.asBytes(&h));
    try w.pad();
    for (stamps, 0..) |s, k| {
        try w.u64v(s.len);
        try w.u64v(s.hash);
        try w.bytes(s.path);
        try w.bytes(if (k < file_names.len) file_names[k] else s.path);
    }

    try w.slice(vm.Instr, c.code.items);
    try w.slice(u32, c.rows.items);
    try w.slice(u16, c.files.items);
    try w.slice(co.Fixup, c.fixups.items);
    try w.strings(c.names.items);
    try w.strings(c.globals.items);
    try w.slice(u16, c.natives.items);
    try image.writeKonst(&w, c.konst.items);
    {
        // Which of those konstIndex actually has in its map. See
        // Compiler.konstIndexed: restoring a map the compiler never had is
        // not a smaller mistake than restoring none.
        const flags = try c.konstIndexed(alloc);
        defer alloc.free(flags);
        try w.slice(u8, flags);
    }
    try w.slice(u64, &vm.fn_masks);

    // The functions: the fixed part as one array, then their names, then
    // every parameter name, then every hint -- four flat runs rather than a
    // record-at-a-time walk with a length before each string.
    {
        const fx = try alloc.alloc(PFunc, c.funcs.items.len);
        defer alloc.free(fx);
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(alloc);
        var params = std.ArrayListUnmanaged([]const u8){};
        defer params.deinit(alloc);
        var hints = std.ArrayListUnmanaged(u8){};
        defer hints.deinit(alloc);
        for (c.funcs.items, 0..) |*f, i| {
            var fl: u8 = 0;
            if (f.poisoned) fl |= 1;
            if (f.poisoned_own) fl |= 2;
            if (f.is_main) fl |= 4;
            if (f.called) fl |= 8;
            if (f.emitted) fl |= 16;
            if (f.owner != null) fl |= 32;
            fx[i] = .{
                .entry = f.entry,
                .id = f.id,
                .mask = f.mask,
                .tramp = f.tramp,
                .body_from = f.body_from,
                .nparams = @intCast(f.params.len),
                .nhints = @intCast(f.hints.len),
                .owner = f.owner orelse 0,
                .name_idx = f.name_idx,
                .frame = f.frame,
                .ret = @intFromEnum(f.ret),
                .ret_elem = @intFromEnum(f.ret_elem),
                .flags = fl,
            };
            try names.append(alloc, f.name);
            for (f.params) |p| try params.append(alloc, p);
            for (f.hints) |x| try hints.append(alloc, @intFromEnum(x));
        }
        try w.slice(PFunc, fx);
        try w.strings(names.items);
        try w.strings(params.items);
        try w.slice(u8, hints.items);
    }

    // THE LOCALS, for eval only: a count per function, then names,
    // registers and boxed flags as three flat runs. A restored function is
    // still never emitted again; these say what its frame HOLDS, which is
    // what a string compiled at run time in that frame needs to know.
    {
        var counts = std.ArrayListUnmanaged(u32){};
        defer counts.deinit(alloc);
        var lnames = std.ArrayListUnmanaged([]const u8){};
        defer lnames.deinit(alloc);
        var lregs = std.ArrayListUnmanaged(u8){};
        defer lregs.deinit(alloc);
        var lboxed = std.ArrayListUnmanaged(u8){};
        defer lboxed.deinit(alloc);
        for (c.funcs.items) |*f| {
            try counts.append(alloc, @intCast(f.locals.items.len));
            for (f.locals.items) |l| {
                try lnames.append(alloc, l.name);
                try lregs.append(alloc, l.reg);
                try lboxed.append(alloc, @intFromBool(l.class.boxed()));
            }
        }
        try w.slice(u32, counts.items);
        try w.strings(lnames.items);
        try w.slice(u8, lregs.items);
        try w.slice(u8, lboxed.items);
    }

    {
        const cx = try alloc.alloc(PClass, c.classes.items.len);
        defer alloc.free(cx);
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(alloc);
        var pnames = std.ArrayListUnmanaged([]const u8){};
        defer pnames.deinit(alloc);
        var anames = std.ArrayListUnmanaged([]const u8){};
        defer anames.deinit(alloc);
        var aslots = std.ArrayListUnmanaged(u32){};
        defer aslots.deinit(alloc);
        var methods = std.ArrayListUnmanaged(u32){};
        defer methods.deinit(alloc);
        for (c.classes.items, 0..) |*ci, i| {
            var fl: u8 = 0;
            if (ci.parent != null) fl |= 1;
            if (ci.attrs_done) fl |= 2;
            if (ci.attrs_fn != null) fl |= 4;
            cx[i] = .{
                .attrs_fn = ci.attrs_fn orelse 0,
                .nattrs = @intCast(ci.attrs.items.len),
                .nmethods = @intCast(ci.methods.items.len),
                .inherited = ci.inherited,
                .parent = ci.parent orelse 0,
                .id = ci.id,
                .flags = fl,
            };
            try names.append(alloc, ci.name);
            try pnames.append(alloc, ci.parent_name);
            for (ci.attrs.items) |a| {
                try anames.append(alloc, a.name);
                try aslots.append(alloc, a.slot);
            }
            for (ci.methods.items) |m| try methods.append(alloc, m);
        }
        try w.slice(PClass, cx);
        try w.strings(names.items);
        try w.strings(pnames.items);
        try w.strings(anames.items);
        try w.slice(u32, aslots.items);
        try w.slice(u32, methods.items);
    }

    // The class a top-level name was proved to hold. Dropping it would not
    // be wrong, only dumber: the file compiled on top would lose inference
    // the whole-unit compile has, and could refuse a line over it.
    {
        var keys = std.ArrayListUnmanaged([]const u8){};
        defer keys.deinit(alloc);
        var vals = std.ArrayListUnmanaged(i32){};
        defer vals.deinit(alloc);
        var it = c.global_cls.iterator();
        while (it.next()) |e| {
            try keys.append(alloc, e.key_ptr.*);
            try vals.append(alloc, if (e.value_ptr.*) |v| @intCast(v) else -1);
        }
        try w.strings(keys.items);
        try w.slice(i32, vals.items);
    }

    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
    var tmp_buf: [512]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, std.Thread.getCurrentId() }) catch
        return error.NameTooLong;
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(w.b.items);
    }
    std.fs.cwd().rename(tmp, path) catch {
        std.fs.cwd().deleteFile(tmp) catch {};
    };
    image.say("prefix written: {d} file(s), {d} function(s), {d} bytes", .{ stamps.len, c.funcs.items.len, w.b.items.len });
}

// ------------------------------------------------------------- reading

/// Restore a compiled library into `c`, or answer false -- which means
/// "compile the unit whole", the thing that happened before this existed.
pub fn load(
    alloc: std.mem.Allocator,
    path: []const u8,
    exe: image.ExeStamp,
    c: *co.Compiler,
    out: *std.ArrayListUnmanaged(image.Stamp),
    file_names: *std.ArrayListUnmanaged([]const u8),
) bool {
    return loadInner(alloc, path, exe, c, out, file_names) catch |e| {
        image.say("prefix unusable: {s}", .{@errorName(e)});
        return false;
    };
}

fn loadInner(
    alloc: std.mem.Allocator,
    path: []const u8,
    exe: image.ExeStamp,
    c: *co.Compiler,
    out: *std.ArrayListUnmanaged(image.Stamp),
    file_names: *std.ArrayListUnmanaged([]const u8),
) !bool {
    const f = std.fs.cwd().openFile(path, .{}) catch {
        image.say("no prefix at {s}", .{path});
        return false;
    };
    defer f.close();
    var r = image.R{ .f = f };

    var hb: [@sizeOf(Header)]u8 = undefined;
    try r.readInto(&hb);
    const h = std.mem.bytesToValue(Header, &hb);
    if (!std.mem.eql(u8, &h.magic, &MAGIC)) return false;
    if (h.version != VERSION) return false;
    if (h.exe_size != exe.size or h.exe_mtime != exe.mtime) {
        image.say("prefix was written by another build", .{});
        return false;
    }
    try r.pad();

    // The library, still byte for byte what it was. One buffer for all of
    // it: see image.readReusing for what 613 separate reads cost.
    var srcbuf: []u8 = &.{};
    defer if (srcbuf.len > 0) alloc.free(srcbuf);
    var i: usize = 0;
    while (i < h.nstamps) : (i += 1) {
        const len = try r.u64v();
        const hash = try r.u64v();
        const p = try r.bytes(alloc);
        try file_names.append(alloc, try r.bytes(alloc));
        const src = image.readReusing(alloc, p, &srcbuf) orelse {
            image.say("prefix: {s} is gone", .{p});
            return false;
        };
        if (src.len != len or image.hashOf(src) != hash) {
            image.say("prefix: {s} changed", .{p});
            return false;
        }
        // The manifest this just verified IS the library's file list, and
        // the caller needs both halves of it: the paths, to name a file in
        // an error report, and the hashes, to write a whole-program image
        // that notices the same changes this check just made.
        try out.append(alloc, .{ .path = p, .len = len, .hash = hash });
    }

    c.code.items = try r.slice(vm.Instr, alloc);
    c.code.capacity = c.code.items.len;
    c.rows.items = try r.slice(u32, alloc);
    c.rows.capacity = c.rows.items.len;
    c.files.items = try r.slice(u16, alloc);
    c.files.capacity = c.files.items.len;
    c.fixups.items = try r.slice(co.Fixup, alloc);
    c.fixups.capacity = c.fixups.items.len;
    {
        const ns = try r.strings(alloc);
        c.names.items = @constCast(ns);
        c.names.capacity = ns.len;
    }
    {
        const gs = try r.strings(alloc);
        c.globals.items = @constCast(gs);
        c.globals.capacity = gs.len;
    }
    c.natives.items = try r.slice(u16, alloc);
    c.natives.capacity = c.natives.items.len;
    {
        const k = try image.readKonst(&r, alloc);
        c.konst.items = k;
        c.konst.capacity = k.len;
    }
    const konst_flags = try r.slice(u8, alloc);
    {
        const masks = try r.slice(u64, alloc);
        defer alloc.free(masks);
        if (masks.len != vm.fn_masks.len) return false;
        @memcpy(&vm.fn_masks, masks);
    }

    {
        const fx = try r.slice(PFunc, alloc);
        defer alloc.free(fx);
        const names = try r.strings(alloc);
        const params = try r.strings(alloc);
        const hints = try r.slice(u8, alloc);
        defer alloc.free(hints);
        if (names.len != fx.len) return false;
        var pi: usize = 0;
        var hi: usize = 0;
        try c.funcs.ensureTotalCapacity(alloc, fx.len + 64);
        for (fx, 0..) |x, ix| {
            if (pi + x.nparams > params.len or hi + x.nhints > hints.len) return false;
            const hs = try alloc.alloc(co.Class, x.nhints);
            for (hs, 0..) |*hh, k| hh.* = @enumFromInt(hints[hi + k]);
            c.funcs.appendAssumeCapacity(.{
                .name = names[ix],
                // A restored function is never emitted again, and nothing
                // that comes after it may look at its tree.
                .node = .{ .raw = std.mem.zeroes(@TypeOf(c.funcs.items[0].node.raw)), .src = "" },
                .params = @constCast(params[pi .. pi + x.nparams]),
                .entry = x.entry,
                .id = x.id,
                .frame = x.frame,
                .mask = x.mask,
                .ret = @enumFromInt(x.ret),
                .hints = hs,
                .ret_elem = @enumFromInt(x.ret_elem),
                .called = (x.flags & 8) != 0,
                .tramp = x.tramp,
                .body_from = x.body_from,
                .owner = if ((x.flags & 32) != 0) x.owner else null,
                .name_idx = x.name_idx,
                .poisoned = (x.flags & 1) != 0,
                .poisoned_own = (x.flags & 2) != 0,
                .emitted = (x.flags & 16) != 0,
                .is_main = (x.flags & 4) != 0,
            });
            pi += x.nparams;
            hi += x.nhints;
        }
    }

    {
        // the locals, restored as DECLARED so no pass widens or re-types
        // them: what they say is what the emitted code already does
        const counts = try r.slice(u32, alloc);
        defer alloc.free(counts);
        const lnames = try r.strings(alloc);
        const lregs = try r.slice(u8, alloc);
        defer alloc.free(lregs);
        const lboxed = try r.slice(u8, alloc);
        defer alloc.free(lboxed);
        if (counts.len != c.funcs.items.len or lnames.len != lregs.len or lregs.len != lboxed.len) return false;
        var li: usize = 0;
        for (c.funcs.items, 0..) |*fnc, ix| {
            const n = counts[ix];
            if (li + n > lnames.len) return false;
            try fnc.locals.ensureTotalCapacity(alloc, n);
            for (0..n) |k| fnc.locals.appendAssumeCapacity(.{
                .name = lnames[li + k],
                .reg = lregs[li + k],
                .class = if (lboxed[li + k] != 0) .ref else .int,
                .declared = true,
                .elem = .ref,
            });
            // the registers above its locals (they may share: shareFunction)
            var top: u16 = 0;
            for (fnc.locals.items) |l| top = @max(top, @as(u16, l.reg) + 1);
            fnc.reg_top = top;
            li += n;
        }
    }

    {
        const cx = try r.slice(PClass, alloc);
        defer alloc.free(cx);
        const names = try r.strings(alloc);
        const pnames = try r.strings(alloc);
        const anames = try r.strings(alloc);
        const aslots = try r.slice(u32, alloc);
        defer alloc.free(aslots);
        const methods = try r.slice(u32, alloc);
        defer alloc.free(methods);
        if (names.len != cx.len or pnames.len != cx.len) return false;
        var ai: usize = 0;
        var mi: usize = 0;
        try c.classes.ensureTotalCapacity(alloc, cx.len + 16);
        for (cx, 0..) |x, ix| {
            if (ai + x.nattrs > anames.len or mi + x.nmethods > methods.len) return false;
            var ci = co.ClassInfo{
                .name = names[ix],
                .node = .{ .raw = std.mem.zeroes(@TypeOf(c.funcs.items[0].node.raw)), .src = "" },
                .parent_name = pnames[ix],
                .parent = if ((x.flags & 1) != 0) x.parent else null,
                .attrs_fn = if ((x.flags & 4) != 0) x.attrs_fn else null,
                .attrs_done = (x.flags & 2) != 0,
                .id = x.id,
                .inherited = x.inherited,
            };
            try ci.attrs.ensureTotalCapacity(alloc, x.nattrs);
            for (0..x.nattrs) |k| ci.attrs.appendAssumeCapacity(.{ .name = anames[ai + k], .slot = aslots[ai + k] });
            try ci.methods.ensureTotalCapacity(alloc, x.nmethods);
            for (0..x.nmethods) |k| ci.methods.appendAssumeCapacity(methods[mi + k]);
            c.classes.appendAssumeCapacity(ci);
            ai += x.nattrs;
            mi += x.nmethods;
        }
    }

    {
        const keys = try r.strings(alloc);
        const vals = try r.slice(i32, alloc);
        defer alloc.free(vals);
        if (keys.len != vals.len) return false;
        for (keys, 0..) |k, ix| {
            try c.global_cls.put(alloc, k, if (vals[ix] < 0) null else @intCast(vals[ix]));
        }
    }

    // The two map-backed lookups, rebuilt from the tables just restored.
    // `fn_index` catches itself up on the next lookup and `method_maps` are
    // built per class on demand, so only these two need saying.
    try c.reindex(konst_flags);

    c.stmts_ok = h.stmts_ok;
    c.stmts_bad = h.stmts_bad;
    c.stmts_native = h.stmts_native;
    c.spread_direct = h.spread_direct;
    c.spread_dyn = h.spread_dyn;
    c.prefix_main = if (h.has_main != 0) h.main_fn else null;
    c.main_fn = null;
    c.prefix_funcs = c.funcs.items.len;
    c.prefix_classes = c.classes.items.len;
    c.prefix_code = c.code.items.len;
    c.prefix_fixups = c.fixups.items.len;
    vm.n_names = @intCast(c.names.items.len);
    image.say("prefix used: {d} file(s), {d} function(s), {d} class(es)", .{ h.nstamps, c.funcs.items.len, c.classes.items.len });
    return true;
}

/// One prefix per library root, named by the hash of its absolute path.
pub fn pathFor(alloc: std.mem.Allocator, lib_abs: []const u8) ?[]const u8 {
    const d = image.dir(alloc) orelse return null;
    var key: [512]u8 = undefined;
    const n = @min(lib_abs.len, key.len);
    for (lib_abs[0..n], 0..) |ch, i| key[i] = std.ascii.toLower(if (ch == '\\') '/' else ch);
    var name: [40]u8 = undefined;
    const fname = std.fmt.bufPrint(&name, "lib{x:0>16}.rnxp", .{image.hashOf(key[0..n])}) catch return null;
    return std.fs.path.join(alloc, &.{ d, fname }) catch null;
}
