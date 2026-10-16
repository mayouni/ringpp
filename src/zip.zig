//! ZIP for Ring++: the twelve names Ring's `ringzip` extension registers,
//! in Zig, with no C and no DLL.
//!
//! WHY NOT THE VENDORED C. `vendor/ring-ext/ringzip` carries Ring's binding
//! (322 lines) around kuba--/zip and miniz -- about ten thousand lines of C
//! that exist because Ring's extension had to be C. Zig's own standard
//! library reads a zip outright (`std.zip`: the header structs, `Iterator`,
//! `extract`) and carries the two pieces a writer needs, `flate.Compress`
//! and `Crc32`. So the C stays vendored for the ORACLE, which is Ring's own
//! build and must behave like Ring, and nothing in `rnxc` depends on it.
//!
//! WHY NOT A DLL. `ring_libzip.dll` is a DLL because RING loads extensions
//! that way. Commitment 5 says rnxc is one binary, so these are registered
//! at start-up through the same table `rpp_init` fills, and the shim that
//! Ring++ installs beside itself does not call `LoadLib` at all. Until this
//! existed, that call found `D:\Ring127\bin\ring_libzip.dll` on the PATH --
//! a reach outside the repository that commitment 1 forbids, and which
//! nobody had noticed because it FAILED quietly.
//!
//! WHAT IS THE SAME AS RING, deliberately: the twelve names, their argument
//! counts, `zip_getfilenamebyindex` being 1-BASED, and `zip_openfile`
//! taking only the FIRST character of the mode ('r', 'w', 'a'), because
//! Ring's binding passes `cMode[0]` to kuba--/zip.
//!
//! WHAT IS NOT: `zip_entry_read`, which takes raw C pointers on Ring and
//! therefore cannot be called from Ring source at all -- there is no way to
//! make a `void**` there. It is registered so the name resolves, and it
//! answers the same refusal Ring's own parameter check would.

const std = @import("std");
const native = @import("native.zig");

const RppVal = native.RppVal;
const Tag = native.Tag;

/// The allocator every archive and every returned string comes from. Set
/// once by `registerAll`.
var alloc: std.mem.Allocator = undefined;

/// A string handed back to the VM. The ABI says the VM COPIES a returned
/// string before the call returns, so one buffer is enough and it may be
/// reused on the next call.
var out_buf: std.ArrayListUnmanaged(u8) = .{};

const Entry = struct {
    name: []u8,
    /// The bytes exactly as they sit in the file.
    stored: []u8,
    method: std.zip.CompressionMethod,
    crc: u32,
    raw_len: u32,
};

/// An open archive. A WRITE archive is built in memory and written whole by
/// `zip_close`, which is what lets `'a'` work without rewriting the format:
/// the existing entries are read in, the new ones appended, and the file
/// laid out once.
const Archive = struct {
    path: []u8,
    mode: u8,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// The entry `zip_entry_open` opened and `zip_entry_close` will commit.
    open_name: ?[]u8 = null,
    open_data: std.ArrayListUnmanaged(u8) = .{},

    fn deinit(self: *Archive) void {
        for (self.entries.items) |e| {
            alloc.free(e.name);
            alloc.free(e.stored);
        }
        self.entries.deinit(alloc);
        self.open_data.deinit(alloc);
        if (self.open_name) |n| alloc.free(n);
        alloc.free(self.path);
        alloc.destroy(self);
    }
};

// ------------------------------------------------------------ reading

/// Every entry name in an archive, in central-directory order.
fn readNames(path: []const u8, names: *std.ArrayListUnmanaged([]u8)) !void {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(&rbuf);
    var it = try std.zip.Iterator.init(&fr);
    while (try it.next()) |e| {
        const name = try alloc.alloc(u8, e.filename_len);
        errdefer alloc.free(name);
        try fr.seekTo(e.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        try names.append(alloc, name);
    }
}

/// One entry's bytes, uncompressed. Null when the archive has no such name.
fn readEntry(path: []const u8, want: []const u8) !?[]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(&rbuf);
    var it = try std.zip.Iterator.init(&fr);
    var namebuf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |e| {
        if (e.filename_len > namebuf.len) continue;
        const name = namebuf[0..e.filename_len];
        try fr.seekTo(e.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(name);
        if (!std.mem.eql(u8, name, want)) continue;

        // The local header's own filename and extra fields sit between it
        // and the data, and their lengths need not match the central
        // directory's -- so they are read from the LOCAL header.
        try fr.seekTo(e.file_offset);
        const lh = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &lh.signature, &std.zip.local_file_header_sig)) return error.ZipBadLocalHeader;
        try fr.seekTo(e.file_offset + @sizeOf(std.zip.LocalFileHeader) + lh.filename_len + lh.extra_len);

        const packed_bytes = try alloc.alloc(u8, @intCast(e.compressed_size));
        defer alloc.free(packed_bytes);
        try fr.interface.readSliceAll(packed_bytes);

        switch (e.compression_method) {
            .store => return try alloc.dupe(u8, packed_bytes),
            .deflate => {
                var aw: std.Io.Writer.Allocating = .init(alloc);
                errdefer aw.deinit();
                var in: std.Io.Reader = .fixed(packed_bytes);
                var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&in, .raw, &dbuf);
                _ = try d.reader.streamRemaining(&aw.writer);
                return try aw.toOwnedSlice();
            },
            else => return error.UnsupportedCompressionMethod,
        }
    }
    return null;
}

// ------------------------------------------------------------ writing

/// ENTRIES ARE STORED, NOT DEFLATED, and that is Zig 0.15.2's doing rather
/// than a choice about zip.
///
/// `std.compress.flate.Compress` is a stub here: its `drain` ends in
/// `@panic("TODO")` and returns 0 before reaching it, so `end()` spins in
/// `while (c.writer.end != 0)` for ever -- found by hanging, not by
/// reading. The `Compress.Simple` path beside it does not even COMPILE:
/// `BlockWriter` names `bit_writer` and `LiteralEncoder`, and `Container`
/// names `writeFooter`, none of which exist in this version. Only
/// DECOMPRESSION is finished, which is why reading a deflated archive works
/// on the other side of this file.
///
/// Method 0 is ordinary zip -- every reader accepts it, and
/// `bench/exec/zip.ring` proves RING reads what we write.
///
/// WHAT IT COSTS: an archive as large as its contents, where miniz would
/// have shrunk it. When a compressor lands in std, `addEntry` is the one
/// place that changes.

/// Lay the whole archive out: local header + data per entry, then the
/// central directory, then the end record. Zip64 is not written -- an
/// archive that needs it would be 4 GB, and Ring's own binding cannot make
/// one either.
fn writeArchive(a: *Archive) !void {
    var f = try std.fs.cwd().createFile(a.path, .{ .truncate = true });
    defer f.close();
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = f.writer(&wbuf);
    const w = &fw.interface;

    var offsets = try alloc.alloc(u32, a.entries.items.len);
    defer alloc.free(offsets);

    var at: u32 = 0;
    for (a.entries.items, 0..) |e, i| {
        offsets[i] = at;
        const lh: std.zip.LocalFileHeader = .{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = e.method,
            .last_modification_time = 0,
            .last_modification_date = 0x21, // 1980-01-01, the epoch of the format
            .crc32 = e.crc,
            .compressed_size = @intCast(e.stored.len),
            .uncompressed_size = e.raw_len,
            .filename_len = @intCast(e.name.len),
            .extra_len = 0,
        };
        try w.writeStruct(lh, .little);
        try w.writeAll(e.name);
        try w.writeAll(e.stored);
        at += @intCast(@sizeOf(std.zip.LocalFileHeader) + e.name.len + e.stored.len);
    }

    const cd_at = at;
    for (a.entries.items, 0..) |e, i| {
        const ch: std.zip.CentralDirectoryFileHeader = .{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = e.method,
            .last_modification_time = 0,
            .last_modification_date = 0x21,
            .crc32 = e.crc,
            .compressed_size = @intCast(e.stored.len),
            .uncompressed_size = e.raw_len,
            .filename_len = @intCast(e.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = offsets[i],
        };
        try w.writeStruct(ch, .little);
        try w.writeAll(e.name);
        at += @intCast(@sizeOf(std.zip.CentralDirectoryFileHeader) + e.name.len);
    }

    const end: std.zip.EndRecord = .{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(a.entries.items.len),
        .record_count_total = @intCast(a.entries.items.len),
        .central_directory_size = at - cd_at,
        .central_directory_offset = cd_at,
        .comment_len = 0,
    };
    try w.writeStruct(end, .little);
    try w.flush();
}

/// Take what is already in the file into the archive, so `'a'` appends
/// rather than replaces.
fn loadExisting(a: *Archive) !void {
    var names: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    readNames(a.path, &names) catch return; // no file yet, or not an archive
    for (names.items) |n| {
        const raw = (readEntry(a.path, n) catch continue) orelse continue;
        defer alloc.free(raw);
        try addEntry(a, n, raw);
    }
}

fn addEntry(a: *Archive, name: []const u8, raw: []const u8) !void {
    try a.entries.append(alloc, .{
        .name = try alloc.dupe(u8, name),
        .stored = try alloc.dupe(u8, raw),
        .method = .store,
        .crc = std.hash.Crc32.hash(raw),
        .raw_len = @intCast(raw.len),
    });
}

// ------------------------------------------------------- the twelve

fn argStr(args: [*]const RppVal, i: u32) ?[]const u8 {
    if (args[i].tag != @intFromEnum(Tag.str)) return null;
    return args[i].asStr();
}

/// A handle arrives back as an INTEGER, not as `Tag.handle`: the VM turns a
/// returned handle into `Value.int` (main.zig, the native bridge) because a
/// Ring++ value has no pointer type and the engine protocol never needed
/// one. So this accepts every shape a handle can wear on the way in.
fn argArchive(args: [*]const RppVal, i: u32) ?*Archive {
    const v = args[i];
    const bits: u64 = switch (@as(Tag, @enumFromInt(v.tag))) {
        .handle => v.bits,
        .int => @bitCast(v.asInt()),
        .num => blk: {
            const f = v.asNum();
            if (f <= 0) return null;
            break :blk @intFromFloat(f);
        },
        else => return null,
    };
    if (bits == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(bits)));
}

fn argNum(args: [*]const RppVal, i: u32) ?f64 {
    return switch (@as(Tag, @enumFromInt(args[i].tag))) {
        .int => @floatFromInt(args[i].asInt()),
        .num => args[i].asNum(),
        else => null,
    };
}

fn retStr(out: *RppVal, s: []const u8) void {
    out_buf.clearRetainingCapacity();
    out_buf.appendSlice(alloc, s) catch {};
    out.* = RppVal.str(out_buf.items);
}

fn zipOpenFile(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const path = argStr(args, 0) orelse return 1;
    const mode_s = argStr(args, 1) orelse return 1;
    // Ring passes cMode[0] to kuba--/zip, so only the first character counts.
    const mode: u8 = if (mode_s.len > 0) std.ascii.toLower(mode_s[0]) else 'r';

    const a = alloc.create(Archive) catch return 1;
    a.* = .{ .path = alloc.dupe(u8, path) catch {
        alloc.destroy(a);
        return 1;
    }, .mode = mode };

    switch (mode) {
        'r' => {
            // Reading opens lazily, but a missing archive must not answer a
            // handle: Ring's zip_open returns NULL and the Ring code tests it.
            var probe = std.fs.cwd().openFile(path, .{}) catch {
                a.deinit();
                out.* = RppVal.handle(null);
                return 0;
            };
            probe.close();
        },
        'a' => loadExisting(a) catch {},
        else => {}, // 'w' starts empty and replaces the file at close
    }
    out.* = RppVal.handle(a);
    return 0;
}

fn zipEntryOpen(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const a = argArchive(args, 0) orelse return 1;
    const name = argStr(args, 1) orelse return 1;
    if (a.open_name) |n| alloc.free(n);
    a.open_name = alloc.dupe(u8, name) catch return 1;
    a.open_data.clearRetainingCapacity();
    out.* = RppVal.int(0);
    return 0;
}

fn zipEntryWrite(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    // Ring's binding takes THREE parameters and refuses two, so this does
    // too -- `ZipEntry.WriteString` in Ring's own shim passes two and fails
    // on Ring for the same reason. Matching it keeps the two comparable.
    if (argc != 3) return 1;
    const a = argArchive(args, 0) orelse return 1;
    const data = argStr(args, 1) orelse return 1;
    const n = argNum(args, 2) orelse return 1;
    const want: usize = if (n <= 0) 0 else @intFromFloat(@min(n, @as(f64, @floatFromInt(data.len))));
    a.open_data.appendSlice(alloc, data[0..want]) catch return 1;
    out.* = RppVal.int(0);
    return 0;
}

fn zipEntryFwrite(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const a = argArchive(args, 0) orelse return 1;
    const path = argStr(args, 1) orelse return 1;
    const f = std.fs.cwd().openFile(path, .{}) catch {
        out.* = RppVal.int(-1);
        return 0;
    };
    defer f.close();
    const bytes = f.readToEndAlloc(alloc, std.math.maxInt(u32)) catch {
        out.* = RppVal.int(-1);
        return 0;
    };
    defer alloc.free(bytes);
    a.open_data.clearRetainingCapacity();
    a.open_data.appendSlice(alloc, bytes) catch return 1;
    out.* = RppVal.int(0);
    return 0;
}

fn zipEntryRead(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    // Ring's version takes two RAW C POINTERS out of the caller, which Ring
    // source cannot produce -- there is no way to make a `void**` there. It
    // is registered so the name resolves and refuses, as Ring's parameter
    // check does.
    _ = args;
    _ = argc;
    _ = out;
    return 1;
}

fn zipEntryFread(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const a = argArchive(args, 0) orelse return 1;
    const dest = argStr(args, 1) orelse return 1;
    const name = a.open_name orelse return 1;
    const raw = (readEntry(a.path, name) catch {
        out.* = RppVal.int(-1);
        return 0;
    }) orelse {
        out.* = RppVal.int(-1);
        return 0;
    };
    defer alloc.free(raw);
    const f = std.fs.cwd().createFile(dest, .{ .truncate = true }) catch {
        out.* = RppVal.int(-1);
        return 0;
    };
    defer f.close();
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(&wbuf);
    fw.interface.writeAll(raw) catch {
        out.* = RppVal.int(-1);
        return 0;
    };
    fw.interface.flush() catch {};
    out.* = RppVal.int(0);
    return 0;
}

fn zipEntryClose(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const a = argArchive(args, 0) orelse return 1;
    if (a.open_name) |name| {
        addEntry(a, name, a.open_data.items) catch return 1;
        alloc.free(name);
        a.open_name = null;
        a.open_data.clearRetainingCapacity();
    }
    out.* = RppVal.int(0);
    return 0;
}

fn zipExtractAllFiles(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const path = argStr(args, 0) orelse return 1;
    const folder = argStr(args, 1) orelse return 1;
    out.* = RppVal.int(0);

    std.fs.cwd().makePath(folder) catch {};
    var dir = std.fs.cwd().openDir(folder, .{}) catch return 0;
    defer dir.close();
    var f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(&rbuf);
    std.zip.extract(dir, &fr, .{}) catch {};
    return 0;
}

fn zipClose(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const a = argArchive(args, 0) orelse return 1;
    if (a.mode != 'r') writeArchive(a) catch {};
    a.deinit();
    out.* = RppVal.int(0);
    return 0;
}

fn zipFilesCount(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const a = argArchive(args, 0) orelse return 1;
    if (a.mode != 'r') {
        out.* = RppVal.int(@intCast(a.entries.items.len));
        return 0;
    }
    var names: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    readNames(a.path, &names) catch {
        out.* = RppVal.int(0);
        return 0;
    };
    out.* = RppVal.int(@intCast(names.items.len));
    return 0;
}

fn zipGetFileNameByIndex(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const a = argArchive(args, 0) orelse return 1;
    const n = argNum(args, 1) orelse return 1;
    // 1-BASED, as Ring's binding is: it passes index-1 to miniz.
    if (n < 1) return 1;
    const want: usize = @intFromFloat(n);

    if (a.mode != 'r') {
        if (want > a.entries.items.len) return 1;
        retStr(out, a.entries.items[want - 1].name);
        return 0;
    }
    var names: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (names.items) |nm| alloc.free(nm);
        names.deinit(alloc);
    }
    readNames(a.path, &names) catch return 1;
    if (want > names.items.len) return 1;
    retStr(out, names.items[want - 1]);
    return 0;
}

fn zipExtractFile(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 2) return 1;
    const path = argStr(args, 0) orelse return 1;
    const name = argStr(args, 1) orelse return 1;
    const raw = (readEntry(path, name) catch {
        retStr(out, "");
        return 0;
    }) orelse {
        retStr(out, "");
        return 0;
    };
    defer alloc.free(raw);
    retStr(out, raw);
    return 0;
}

// ------------------------------------------------------------ wiring

const Reg = struct { name: [*:0]const u8, f: native.RppFn };

const table = [_]Reg{
    .{ .name = "zip_openfile", .f = &zipOpenFile },
    .{ .name = "zip_entry_open", .f = &zipEntryOpen },
    .{ .name = "zip_entry_write", .f = &zipEntryWrite },
    .{ .name = "zip_entry_fwrite", .f = &zipEntryFwrite },
    .{ .name = "zip_entry_read", .f = &zipEntryRead },
    .{ .name = "zip_entry_fread", .f = &zipEntryFread },
    .{ .name = "zip_entry_close", .f = &zipEntryClose },
    .{ .name = "zip_extract_allfiles", .f = &zipExtractAllFiles },
    .{ .name = "zip_close", .f = &zipClose },
    .{ .name = "zip_filescount", .f = &zipFilesCount },
    .{ .name = "zip_getfilenamebyindex", .f = &zipGetFileNameByIndex },
    .{ .name = "zip_extract_file", .f = &zipExtractFile },
};

/// Publish the twelve through the same table `rpp_init` fills. Called once,
/// at start-up, so no library has to be loaded for them to resolve.
pub fn registerAll(a: std.mem.Allocator) void {
    alloc = a;
    native.reg_alloc = a;
    for (table) |r| native.register(r.name, r.f);
}
