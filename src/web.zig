//! The browser renderer's socket half.
//!
//! Contract 5.1: "the binary serves the HTML and takes events over a local
//! socket". This is that socket, and nothing more -- no framework, no
//! template engine, no JavaScript. One listener, one page at a time, one
//! form POST back.
//!
//! THE SPLIT IS DELIBERATE. This file decodes an HTTP request into the
//! form fields a browser sent, in document order, and hands them to Ring
//! as a list of [name, value] pairs. It does NOT know what a widget is,
//! which field changed, or what an event means. Ring holds the semantics,
//! exactly as it does for the console builtins, so the browser renderer's
//! rules live in one place (rpp/tui.ring) rather than two.
//!
//! WHY THE WHOLE FORM AND NOT ONE EVENT: a browser posts every control on
//! the page, not the one that changed. Only the model knows which values
//! are new, and the model is Ring's. Handing over the raw form is the
//! honest interface; deciding what changed is the renderer's job.

const std = @import("std");

var srv: ?std.net.Server = null;

/// Request scratch. A page of HTML is written from the caller's slice and
/// never copied here; only the request comes into these.
var req_buf: [256 * 1024]u8 = undefined;
var form_buf: [256 * 1024]u8 = undefined;
var form_len: usize = 0;

/// The decoded pairs, as offsets into `form_buf`.
pub const Pair = struct { k0: usize, k1: usize, v0: usize, v1: usize };
var pairs: [512]Pair = undefined;
var pair_n: usize = 0;

pub fn count() usize {
    return pair_n;
}

pub fn key(i: usize) []const u8 {
    return form_buf[pairs[i].k0..pairs[i].k1];
}

pub fn value(i: usize) []const u8 {
    return form_buf[pairs[i].v0..pairs[i].v1];
}

/// Listen on 127.0.0.1:port. 1 when the port is ours, 0 when it is not --
/// a port already in use is an ordinary thing and must not be a panic.
pub fn serve(port: u16) i64 {
    if (srv != null) return 1;
    const addr = std.net.Address.parseIp4("127.0.0.1", port) catch return 0;
    srv = addr.listen(.{ .reuse_address = true }) catch return 0;
    return 1;
}

pub fn done() void {
    if (srv) |*s| {
        s.deinit();
        srv = null;
    }
}

/// Serve `html` until a POST arrives, then decode its form and return true.
/// GETs are answered with the page and do not return: a browser asks for
/// the page, its icon and whatever else it fancies, and none of that is an
/// event. false means the listener is gone.
pub fn wait(html: []const u8) bool {
    var s = &(srv orelse return false);
    while (true) {
        const conn = s.accept() catch return false;
        defer conn.stream.close();

        const n = recvSome(conn.stream, &req_buf) catch continue;
        if (n == 0) continue;
        var head = req_buf[0..n];

        const is_post = std.mem.startsWith(u8, head, "POST");
        if (!is_post) {
            respond(conn.stream, html);
            continue;
        }

        // the body follows the blank line; read the rest if the socket
        // handed us a short first chunk
        var total = n;
        const sep = std.mem.indexOf(u8, head, "\r\n\r\n") orelse {
            respond(conn.stream, html);
            continue;
        };
        const want = contentLength(head[0..sep]);
        while (total - (sep + 4) < want and total < req_buf.len) {
            const more = recvSome(conn.stream, req_buf[total..]) catch break;
            if (more == 0) break;
            total += more;
        }
        head = req_buf[0..total];
        decode(head[sep + 4 ..]);
        // POST / redirect / GET. Answering the POST with the page we are
        // holding would show the screen the form just LEFT: Ring has not
        // acted on the form yet, so the next screen does not exist. A 303
        // sends the browser straight back for it, and by the time that GET
        // is accepted Ring has drawn it. Without this every action showed
        // the previous screen until the reader pressed reload.
        redirectHome(conn.stream);
        return true;
    }
}

/// One last page, then close. After the final screen a browser is still
/// following the redirect, and a listener that has already gone answers
/// it with a reset -- which is what the reader sees instead of an ending.
/// This serves one request and shuts the socket.
pub fn bye(html: []const u8) void {
    if (srv) |*sv| {
        if (sv.accept()) |conn| {
            defer conn.stream.close();
            var scratch: [8192]u8 = undefined;
            _ = recvSome(conn.stream, &scratch) catch {};
            respond(conn.stream, html);
        } else |_| {}
    }
    done();
}

fn contentLength(headers: []const u8) usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (line.len > 15 and std.ascii.eqlIgnoreCase(line[0..15], "content-length:")) {
            const v = std.mem.trim(u8, line[15..], " ");
            return std.fmt.parseInt(usize, v, 10) catch 0;
        }
    }
    return 0;
}

fn redirectHome(stream: std.net.Stream) void {
    sendAll(stream, "HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch return;
}

fn respond(stream: std.net.Stream, html: []const u8) void {
    var hdr: [128]u8 = undefined;
    const h = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{html.len},
    ) catch return;
    sendAll(stream, h) catch return;
    sendAll(stream, html) catch return;
}

/// recv/send, not ReadFile/WriteFile. Measured 2026-09-04: reading an
/// accepted socket through `Stream.read` on Windows fails with
/// GetLastError(87), "invalid parameter" -- the handle is a socket and
/// wants the winsock calls, which `std.posix` maps to on every platform.
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

/// `a=1&b=hello+there&c=%41` -> pairs, in the order the browser sent them,
/// which is document order and therefore tree order.
fn decode(body: []const u8) void {
    form_len = 0;
    pair_n = 0;
    var it = std.mem.splitScalar(u8, body, '&');
    while (it.next()) |field| {
        if (field.len == 0) continue;
        if (pair_n == pairs.len) return;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const k0 = form_len;
        unescape(field[0..eq]);
        const k1 = form_len;
        const v0 = form_len;
        if (eq < field.len) unescape(field[eq + 1 ..]);
        const v1 = form_len;
        pairs[pair_n] = .{ .k0 = k0, .k1 = k1, .v0 = v0, .v1 = v1 };
        pair_n += 1;
    }
}

fn unescape(src: []const u8) void {
    var i: usize = 0;
    while (i < src.len and form_len < form_buf.len) : (i += 1) {
        const c = src[i];
        if (c == '+') {
            form_buf[form_len] = ' ';
            form_len += 1;
        } else if (c == '%' and i + 2 < src.len) {
            const hi = hex(src[i + 1]);
            const lo = hex(src[i + 2]);
            if (hi != 255 and lo != 255) {
                form_buf[form_len] = hi * 16 + lo;
                form_len += 1;
                i += 2;
            } else {
                form_buf[form_len] = c;
                form_len += 1;
            }
        } else {
            form_buf[form_len] = c;
            form_len += 1;
        }
    }
}

fn hex(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 255;
}
