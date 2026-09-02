const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Documentation = struct {
    text: []u8,
    loc: std.builtin.SourceLocation,
};

/// Collect all documentation of top-level declarations
pub fn collect_documentations(
    arena: Allocator,
    comptime file: [:0]const u8,
    source: []const u8,
) !std.StringHashMapUnmanaged(Documentation) {
    const source_z = try arena.dupeZ(u8, source);
    defer arena.free(source_z);

    var tree = try std.zig.Ast.parse(arena, source_z, .zig);

    var result: std.StringHashMapUnmanaged(Documentation) = .empty;

    for (tree.rootDecls()) |decl| {
        const name, const name_token = try get_decl_name(arena, tree, decl) orelse continue;
        const doc = try get_decl_documentation(arena, tree, decl) orelse continue;

        try result.put(arena, name, .{
            .text = doc,
            .loc = .{
                .module = "",
                .file = file,
                .line = @intCast(tree.tokenLocation(0, name_token).line + 1),
                .column = 0,
                .fn_name = name,
            },
        });
    }

    return result;
}

fn get_decl_documentation(
    arena: Allocator,
    tree: std.zig.Ast,
    decl: std.zig.Ast.Node.Index,
) !?[]u8 {
    const declaration_start = tree.firstToken(decl);
    var doc_start = declaration_start;
    while (doc_start > 0 and tree.tokenTag(doc_start - 1) == .doc_comment) {
        doc_start -= 1;
    }
    if (doc_start == declaration_start) return null;

    var doc_writer: std.Io.Writer.Allocating = .init(arena);
    for (doc_start..declaration_start) |doc_token_usize| {
        if (doc_token_usize != doc_start) try doc_writer.writer.writeByte('\n');
        const token = tree.tokenSlice(@intCast(doc_token_usize));
        var line = token[3..];
        if (mem.startsWith(u8, line, " ")) line = line[1..];
        try doc_writer.writer.writeAll(line);
    }

    return try doc_writer.toOwnedSlice();
}

fn get_decl_name(
    arena: Allocator,
    tree: std.zig.Ast,
    decl: std.zig.Ast.Node.Index,
) !?struct { [:0]u8, std.zig.Ast.TokenIndex } {
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const name_token = if (tree.fullFnProto(&fn_buffer, decl)) |fn_proto|
        fn_proto.name_token orelse return null
    else
        return null;

    var name_writer: std.Io.Writer.Allocating = .init(arena);
    defer name_writer.deinit();
    const raw_name = tree.tokenSlice(name_token);
    if (mem.startsWith(u8, raw_name, "@")) {
        switch (try std.zig.string_literal.parseWrite(&name_writer.writer, raw_name[1..])) {
            .success => {},
            .failure => return error.InvalidZigSource,
        }
    } else {
        try name_writer.writer.writeAll(raw_name);
    }
    return .{ try name_writer.toOwnedSliceSentinel(0), name_token };
}
