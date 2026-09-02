const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const generated = @import("generated");
const janet = @import("janet");
const x = @import("x");

const Error = Allocator.Error || error{
    JanetPanic,
};

/// (array/new capacity)
///
/// Creates a new empty array with a pre-allocated capacity.
///
/// The same as `(array)` but can be more efficient if the maximum size of an
/// array is known.
pub fn @"array/new"(rt: *janet.Runtime, values: []const janet.Value) Error!janet.Value {
    if (values.len != 1) {
        return rt.panic("arity mismatch, expected {}, got {}", .{ 1, values.len });
    }
    if (values[0].checktype(.number)) {
        return rt.panic("bad slot #0, expected 32-bit signed integer, got {t}", .{values[0].repr.unwrap_tag()});
    }
    const arr: *janet.Array = try .create(rt);
    try arr.ensure(rt, @intCast(values.len), 1);
    return .array(arr);
}

test "[codegen] corelib" {
    if (comptime !janet.options.is_codegen) {
        try std.testing.expectEqual(0xDEADBEEF, generated.magic);
        return;
    }

    try x.testing.codegen_writer.print("pub const magic = 0x{x};", .{0xDEADBEEF});
}
