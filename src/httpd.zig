//! A server's socket, for a program that holds its own request loop.
//!
//! HaroServer's host is ONE live program (the resident VM, `rnxc resident`)
//! that takes its apps and its requests itself: it waits for a request,
//! routes it to a function an app defined, admits or replaces an app's code
//! when the request is a deployment, and answers. This file is the socket
//! under that loop and nothing more -- no routing, no framework: the loop and
//! every decision in it are the program's, in Ring.
//!
//!     rpp_http_listen(nPort)        1 when 127.0.0.1:nPort is ours, 0 when not
//!     rpp_http_next()               waits for the next request; 1, or 0 when the
//!                                   listener is gone
//!     rpp_http_method()             "GET", "POST", ...
//!     rpp_http_path()               the path, without the query
//!     rpp_http_query()              what followed `?`, or ""
//!     rpp_http_header(cName)        a header's value, any case, or ""
//!     rpp_http_body()               the body, as sent
//!     rpp_http_reply(nStatus, cType, cBody)
//!                                   answers the request and closes it
//!
//! One request at a time, one connection per request (`Connection: close`):
//! the VM runs one program on one thread, and the loop is the program.
//! Published at start-up through the table `rpp_init` fills, as `src/zip.zig`
//! is -- no library, no DLL: commitment 5, one binary.
const std = @import("std");
const native = @import("native.zig");

const RppVal = native.RppVal;
const Tag = native.Tag;

var alloc: std.mem.Allocator = undefined;
var srv: ?std.net.Server = null;
/// The request being answered, and its parts as offsets into `req`.
var conn: ?std.net.Server.Connection = null;
var req: std.ArrayListUnmanaged(u8) = .{};
var head_end: usize = 0;
var method: []const u8 = "";
var path: []const u8 = "";
var query: []const u8 = "";
var body: []const u8 = "";
/// What a native hands back; the VM copies it before the call returns.
var out_buf: std.ArrayListUnmanaged(u8) = .{};
/// A request larger than this is answered 413 and not handed to the program.
const MAX_REQUEST: usize = 64 << 20;

fn retStr(out: *RppVal, s: []const u8) void {
    out_buf.clearRetainingCapacity();
    out_buf.appendSlice(alloc, s) catch {};
    out.* = RppVal.str(out_buf.items);
}

fn argNum(args: [*]const RppVal, i: u32) ?f64 {
    return switch (@as(Tag, @enumFromInt(args[i].tag))) {
        .int => @floatFromInt(args[i].asInt()),
        .num => args[i].asNum(),
        else => null,
    };
}

fn argStr(args: [*]const RppVal, i: u32) ?[]const u8 {
    if (args[i].tag != @intFromEnum(Tag.str)) return null;
    return args[i].asStr();
}

/// recv/send, not ReadFile/WriteFile: on Windows `Stream.read` on an accepted
/// socket fails with GetLastError(87) (web.zig measured it, 2026-09-04).
fn recvSome(stream: std.net.Stream, buf: []u8) !usize {
    return std.posix.recv(stream.handle, buf, 0);
}

fn sendAll(stream: std.net.Stream, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try std.posix.send(stream.handle, bytes[off..], 0);
        if (n == 0) return error.Closed;
        off += n;
    }
}

/// How long a request may take to arrive once its connection is accepted.
const RECV_TIMEOUT_MS: u32 = 10_000;

fn recvTimeout(stream: std.net.Stream) void {
    if (@import("builtin").os.tag == .windows) {
        const ms: u32 = RECV_TIMEOUT_MS;
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&ms)) catch {};
    } else {
        const tv = std.posix.timeval{ .sec = RECV_TIMEOUT_MS / 1000, .usec = 0 };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}

fn closeConn() void {
    if (conn) |cn| cn.stream.close();
    conn = null;
}

fn httpListen(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const port = argNum(args, 0) orelse return 1;
    if (port < 1 or port > 65535) return 1;
    if (srv == null) {
        const addr = std.net.Address.parseIp4("127.0.0.1", @intFromFloat(port)) catch {
            out.* = RppVal.int(0);
            return 0;
        };
        srv = addr.listen(.{ .reuse_address = true }) catch {
            out.* = RppVal.int(0);
            return 0;
        };
    }
    out.* = RppVal.int(1);
    return 0;
}

/// Read one request: its head to the blank line, then as many body bytes as
/// Content-Length says. false when the peer closed or sent no request.
fn readRequest(stream: std.net.Stream) !bool {
    req.clearRetainingCapacity();
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try recvSome(stream, &chunk);
        if (n == 0) return false;
        try req.appendSlice(alloc, chunk[0..n]);
        if (std.mem.indexOf(u8, req.items, "\r\n\r\n")) |sep| {
            head_end = sep;
            break;
        }
        if (req.items.len > MAX_REQUEST) return error.TooLarge;
    }
    const want = contentLength(req.items[0..head_end]);
    if (want > MAX_REQUEST) return error.TooLarge;
    while (req.items.len - (head_end + 4) < want) {
        const n = try recvSome(stream, &chunk);
        if (n == 0) break;
        try req.appendSlice(alloc, chunk[0..n]);
    }
    const line_end = std.mem.indexOf(u8, req.items, "\r\n") orelse head_end;
    var it = std.mem.splitScalar(u8, req.items[0..line_end], ' ');
    method = it.next() orelse "";
    const target = it.next() orelse "/";
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        path = target[0..q];
        query = target[q + 1 ..];
    } else {
        path = target;
        query = "";
    }
    const b0 = head_end + 4;
    body = req.items[b0..@min(req.items.len, b0 + want)];
    return method.len > 0;
}

fn contentLength(headers: []const u8) usize {
    const v = headerValue(headers, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, v, 10) catch 0;
}

fn headerValue(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next(); // the request line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name))
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn httpNext(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    _ = args;
    if (argc != 0) return 1;
    // a request the program never answered is answered for it
    if (conn != null) {
        if (conn) |cn| sendAll(cn.stream, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
        closeConn();
    }
    var s = &(srv orelse {
        out.* = RppVal.int(0);
        return 0;
    });
    while (true) {
        // one loop serves everything, so nothing a single client does may stop
        // it: a connection that fails as it is accepted is passed over, and
        // one that sends nothing is given up after RECV_TIMEOUT_MS
        const cn = s.accept() catch |e| switch (e) {
            error.ConnectionAborted, error.ConnectionResetByPeer, error.WouldBlock => continue,
            else => {
                out.* = RppVal.int(0);
                return 0;
            },
        };
        recvTimeout(cn.stream);
        const ok = readRequest(cn.stream) catch |e| blk: {
            if (e == error.TooLarge) sendAll(cn.stream, "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
            break :blk false;
        };
        if (!ok) {
            cn.stream.close();
            continue;
        }
        conn = cn;
        out.* = RppVal.int(1);
        return 0;
    }
}

fn httpMethod(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    _ = args;
    _ = argc;
    retStr(out, if (conn != null) method else "");
    return 0;
}

fn httpPath(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    _ = args;
    _ = argc;
    retStr(out, if (conn != null) path else "");
    return 0;
}

fn httpQuery(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    _ = args;
    _ = argc;
    retStr(out, if (conn != null) query else "");
    return 0;
}

fn httpBody(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    _ = args;
    _ = argc;
    retStr(out, if (conn != null) body else "");
    return 0;
}

fn httpHeader(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 1) return 1;
    const name = argStr(args, 0) orelse return 1;
    retStr(out, if (conn != null) (headerValue(req.items[0..head_end], name) orelse "") else "");
    return 0;
}

fn reason(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Content",
        500 => "Internal Server Error",
        else => "Status",
    };
}

fn httpReply(args: [*]const RppVal, argc: u32, out: *RppVal) callconv(.c) c_int {
    if (argc != 3) return 1;
    const st = argNum(args, 0) orelse return 1;
    const ctype = argStr(args, 1) orelse return 1;
    const text = argStr(args, 2) orelse return 1;
    const cn = conn orelse {
        out.* = RppVal.int(0);
        return 0;
    };
    const status: u16 = if (st >= 100 and st <= 999) @intFromFloat(st) else 500;
    var hdr: [512]u8 = undefined;
    const h = std.fmt.bufPrint(&hdr, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason(status), ctype[0..@min(ctype.len, 200)], text.len }) catch return 1;
    // ONE send, head and body together. Measured 2026-10-31: as two, every
    // request took a Windows timer tick (~15 ms) -- Nagle held the body until
    // the head was acknowledged, and the client delays its ACK
    out_buf.clearRetainingCapacity();
    out_buf.appendSlice(alloc, h) catch return 1;
    out_buf.appendSlice(alloc, text) catch return 1;
    var ok = true;
    sendAll(cn.stream, out_buf.items) catch {
        ok = false;
    };
    closeConn();
    out.* = RppVal.int(if (ok) 1 else 0);
    return 0;
}

const table = [_]struct { name: [*:0]const u8, f: native.RppFn }{
    .{ .name = "rpp_http_listen", .f = &httpListen },
    .{ .name = "rpp_http_next", .f = &httpNext },
    .{ .name = "rpp_http_method", .f = &httpMethod },
    .{ .name = "rpp_http_path", .f = &httpPath },
    .{ .name = "rpp_http_query", .f = &httpQuery },
    .{ .name = "rpp_http_header", .f = &httpHeader },
    .{ .name = "rpp_http_body", .f = &httpBody },
    .{ .name = "rpp_http_reply", .f = &httpReply },
};

/// Publish them through the same table `rpp_init` fills, at start-up.
pub fn registerAll(a: std.mem.Allocator) void {
    alloc = a;
    native.reg_alloc = a;
    for (table) |r| native.register(r.name, r.f);
}
