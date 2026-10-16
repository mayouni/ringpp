//! `rnxc dump --json <file.ring>` -- the parse of a file, LOSSLESS.
//!
//! `rnxc dump` prints one node a line and loses four things (haro/CODEGRAPH.md 4.2): a leaf's text past 40 bytes, a newline
//! inside a leaf (shown as a backslash), every position, and the tokens the grammar hides -- the `(` that opens a parameter list,
//! the `[` that opens a subscript, the quotes and parts of a string -- which are not nodes. Everything that reads the dump has had
//! to recover those by walking the leaves against the source, and the recovery is a heuristic (haro/spike/v18/cst.py).
//!
//! This is the export the heuristic stands in for. One JSON object, ASCII only:
//!
//!   {"format":"rnxc-dump/1", "file":<path as given>, "bytes":N, "error":false,
//!    "head":<the bytes before the root>, "tail":<the bytes after it>, "nodes":[NODE, ...]}
//!
//!   NODE = {"k":kind, "n":1 (named), "s":start byte, "e":end byte, "p":index of the parent (absent for the root),
//!           "x":1 (an ERROR or MISSING node),
//!           "t":text            -- a leaf, a node with no child: its full text
//!           "g":{"i":text, ...} -- an interior node: its non-empty GAPS}
//!
//! THE NODES ARE FLAT, in pre-order: a node's index is its place in the array, its children are the nodes that name it as their
//! parent, in the order they come. Nested JSON would have been shorter to write and is not safe to read: a chain of a thousand `+`
//! is a thousand levels deep, and the standard JSON decoder of Python gives up long before that. EVERY child is a node, anonymous
//! tokens included.
//!
//! A gap is the source between a node's start and its first child (key 0), between child i-1 and child i (key i), and between the
//! last child and the node's end. It is where layout lives -- and, in exactly the places the grammar hides a token, that token. So
//! the source of any node is its gaps and its children read in order, and the file is `head` + the root + `tail`: nothing is lost,
//! and nothing has to be guessed. An absent field is empty or false.
//!
//! EVERY STRING IS BYTES, NOT TEXT. A file may hold bytes that are not UTF-8 (Softanza's do), so each byte is written as one code
//! point U+0000..U+00FF -- `\u00e9` for byte 0xE9 -- and a reader that decodes the JSON gets the file read as Latin-1: one
//! character a byte, so an offset in the JSON is an offset in the file.
const std = @import("std");
const ts = @import("ts.zig");

fn esc(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (b >= 0x20 and b < 0x7f) {
                try w.writeByte(b);
            } else {
                try w.print("\\u{x:0>4}", .{b});
            },
        }
    }
    try w.writeByte('"');
}

fn node(n: ts.Node, src: []const u8, parent: i64, next: *u32, w: *std.Io.Writer) !void {
    const me: i64 = next.*;
    next.* += 1;
    if (me > 0) try w.writeByte(',');
    const s = n.startByte();
    const e = n.endByte();
    try w.writeAll("{\"k\":");
    try esc(w, n.kind());
    if (n.isNamed()) try w.writeAll(",\"n\":1");
    try w.print(",\"s\":{d},\"e\":{d}", .{ s, e });
    if (parent >= 0) try w.print(",\"p\":{d}", .{parent});
    if (n.isError() or n.isMissing()) try w.writeAll(",\"x\":1");
    const cc = n.childCount();
    if (cc == 0) {
        try w.writeAll(",\"t\":");
        try esc(w, src[s..e]);
        try w.writeByte('}');
        return;
    }
    // the gaps, keyed by the position of the child they come before (the last one: after the last child)
    var first = true;
    var prev = s;
    var i: u32 = 0;
    while (i <= cc) : (i += 1) {
        const nxt = if (i < cc) n.child(i).startByte() else e;
        if (nxt > prev) {
            try w.writeAll(if (first) ",\"g\":{" else ",");
            first = false;
            try w.print("\"{d}\":", .{i});
            try esc(w, src[prev..nxt]);
        }
        if (i < cc) prev = @max(prev, n.child(i).endByte());
    }
    if (!first) try w.writeByte('}');
    try w.writeByte('}');
    i = 0;
    while (i < cc) : (i += 1) try node(n.child(i), src, me, next, w);
}

/// Parse `path` and write its export to `w`. Returns false when the file could not be read or parsed.
pub fn exportFile(alloc: std.mem.Allocator, parser: ts.Parser, path: []const u8, w: *std.Io.Writer) !bool {
    const src = std.fs.cwd().readFileAlloc(alloc, path, 256 << 20) catch |e| {
        std.debug.print("note: could not read {s} ({s})\n", .{ path, @errorName(e) });
        return false;
    };
    const tree = parser.parse(src) orelse {
        std.debug.print("note: could not parse {s}\n", .{path});
        return false;
    };
    defer tree.deinit();
    const root = tree.root();
    try w.writeAll("{\"format\":\"rnxc-dump/1\",\"file\":");
    try esc(w, path);
    try w.print(",\"bytes\":{d},\"error\":{s},\"head\":", .{ src.len, if (root.hasError()) "true" else "false" });
    try esc(w, src[0..root.startByte()]);
    try w.writeAll(",\"tail\":");
    try esc(w, src[root.endByte()..]);
    try w.writeAll(",\"nodes\":[");
    var next: u32 = 0;
    try node(root, src, -1, &next, w);
    try w.writeAll("]}\n");
    return true;
}
