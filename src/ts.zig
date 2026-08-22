//! Minimal tree-sitter binding — only what `ringpp check` needs.
//!
//! tree-sitter is a LENS, not a judge (docs/DESIGN_TOOLCHAIN.md §5).
//! Nothing here decides whether a file is valid Ring; that is Ring's own
//! scanner's job. This module answers "where is it and what shape is it".

const std = @import("std");

pub const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_ring() *const c.TSLanguage;

pub const Point = struct { row: u32, col: u32 };

pub const Node = struct {
    raw: c.TSNode,
    src: []const u8,

    pub fn kind(self: Node) []const u8 {
        return std.mem.span(c.ts_node_type(self.raw));
    }

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.raw);
    }

    pub fn isError(self: Node) bool {
        return c.ts_node_is_error(self.raw) or c.ts_node_is_missing(self.raw);
    }

    pub fn isMissing(self: Node) bool {
        return c.ts_node_is_missing(self.raw);
    }

    pub fn start(self: Node) Point {
        const p = c.ts_node_start_point(self.raw);
        return .{ .row = p.row, .col = p.column };
    }

    pub fn text(self: Node) []const u8 {
        const a = c.ts_node_start_byte(self.raw);
        const b = c.ts_node_end_byte(self.raw);
        if (a > self.src.len or b > self.src.len or b < a) return "";
        return self.src[a..b];
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.raw);
    }

    pub fn child(self: Node, i: u32) Node {
        return .{ .raw = c.ts_node_child(self.raw, i), .src = self.src };
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.raw);
    }

    pub fn namedChild(self: Node, i: u32) Node {
        return .{ .raw = c.ts_node_named_child(self.raw, i), .src = self.src };
    }

    pub fn field(self: Node, name: []const u8) Node {
        return .{
            .raw = c.ts_node_child_by_field_name(self.raw, name.ptr, @intCast(name.len)),
            .src = self.src,
        };
    }

    pub fn parent(self: Node) Node {
        return .{ .raw = c.ts_node_parent(self.raw), .src = self.src };
    }

    /// O(1). Finding the same node by scanning the parent's named children is
    /// O(siblings), which turns a per-function lookup into O(n^2): on a 3 MB
    /// single-file library that cost 467 seconds against 1.5.
    pub fn prevNamedSibling(self: Node) Node {
        return .{ .raw = c.ts_node_prev_named_sibling(self.raw), .src = self.src };
    }
};

pub const Tree = struct {
    raw: *c.TSTree,
    src: []const u8,

    pub fn root(self: Tree) Node {
        return .{ .raw = c.ts_tree_root_node(self.raw), .src = self.src };
    }

    pub fn deinit(self: Tree) void {
        c.ts_tree_delete(self.raw);
    }
};

pub const Parser = struct {
    raw: *c.TSParser,

    pub fn init() Parser {
        const p = c.ts_parser_new().?;
        _ = c.ts_parser_set_language(p, tree_sitter_ring());
        return .{ .raw = p };
    }

    pub fn deinit(self: Parser) void {
        c.ts_parser_delete(self.raw);
    }

    pub fn parse(self: Parser, src: []const u8) ?Tree {
        const t = c.ts_parser_parse_string(self.raw, null, src.ptr, @intCast(src.len));
        if (t == null) return null;
        return Tree{ .raw = t.?, .src = src };
    }
};

test "parses Ring and finds a typed parameter" {
    const p = Parser.init();
    defer p.deinit();
    const src = "int func Sum(int x, int y)\n    return x + y\n";
    const tree = p.parse(src).?;
    defer tree.deinit();

    var found = false;
    var stack = std.ArrayList(Node){};
    defer stack.deinit(std.testing.allocator);
    try stack.append(std.testing.allocator, tree.root());
    while (stack.pop()) |n| {
        if (std.mem.eql(u8, n.kind(), "typed_parameter")) {
            found = true;
            try std.testing.expectEqualStrings("int", n.field("type").text());
        }
        var i: u32 = 0;
        while (i < n.childCount()) : (i += 1) try stack.append(std.testing.allocator, n.child(i));
    }
    try std.testing.expect(found);
}
