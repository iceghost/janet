const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const generated = @import("generated");
const janet = @import("janet");
const x = @import("x");

const Error = Allocator.Error || error{
    JanetPanic,
};

comptime {
    if (!janet.options.is_codegen) _ = generated;
}

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
    if (!values[0].checktype(.number)) {
        return rt.panic("bad slot #0, expected 32-bit signed integer, got {t}", .{values[0].repr.unwrap_tag()});
    }
    const capacity_number = values[0].unwrap().number;
    if (capacity_number < std.math.minInt(i32) or
        capacity_number > std.math.maxInt(i32) or
        capacity_number != @trunc(capacity_number))
    {
        return rt.panic("bad slot #0, expected 32-bit signed integer, got {t}", .{values[0].repr.unwrap_tag()});
    }
    const capacity: i32 = @intFromFloat(capacity_number);
    const arr: *janet.Array = try .create(rt);
    try arr.ensure(rt, @intCast(capacity), 1);
    return .array(arr);
}

test "[codegen] corelib" {
    if (comptime !janet.options.is_codegen) {
        try std.testing.expectEqual(0xDEADBEEF, generated.magic);
        return;
    }

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const documentations = try x.meta.collect_documentations(gpa, @src().file, @embedFile("core.zig"));
    const array_new_documentation = documentations.get("array/new").?;

    try x.testing.codegen_writer.print(
        \\const janet = @import("janet");
        \\
        \\const RegExt = extern struct {{
        \\    name: ?[*:0]const u8,
        \\    cfun: ?janet.value.CFunction,
        \\    documentation: ?[*:0]const u8,
        \\    source_file: ?[*:0]const u8,
        \\    source_line: i32,
        \\}};
        \\
        \\extern fn janet_cfuns_ext(*janet.value.Table, ?[*]const u8, [*]const RegExt) void;
        \\extern fn janet_core_cfuns_ext(*janet.value.Table, ?[*]const u8, [*]const RegExt) void;
        \\
        \\export fn @"array/new"(argc: i32, argv: [*]janet.Value) callconv(.c) janet.Value {{
        \\    const rt: *janet.Runtime = .default();
        \\    return janet.core.@"array/new"(rt, argv[0..@intCast(argc)]) catch |err| switch (err) {{
        \\        error.OutOfMemory => janet.oom(),
        \\        error.JanetPanic => rt.signal(.@"error", rt.panic_msg),
        \\    }};
        \\}}
        \\
        \\pub export fn janet_lib_zig(env: *janet.value.Table) void {{
        \\    const registrations: [2]RegExt = .{{
        \\        .{{
        \\            .name = "array/new",
        \\            .cfun = &@"array/new",
        \\            .documentation = "{[doc]f}",
        \\            .source_file = "{[source_file]f}",
        \\            .source_line = {[source_line]d},
        \\        }},
        \\        .{{
        \\            .name = null,
        \\            .cfun = null,
        \\            .documentation = null,
        \\            .source_file = null,
        \\            .source_line = 0,
        \\        }},
        \\    }};
        \\    if (comptime janet.options.bootstrap) {{
        \\        janet_cfuns_ext(env, null, &registrations);
        \\    }} else {{
        \\        janet_core_cfuns_ext(env, null, &registrations);
        \\    }}
        \\}}
        \\
    , .{
        .doc = std.zig.fmtString(array_new_documentation.text),
        .source_file = std.zig.fmtString(array_new_documentation.loc.file),
        .source_line = array_new_documentation.loc.line,
    });

    try x.testing.codegen_writer.print(
        \\pub const magic = 0x{x};
        \\
    , .{0xDEADBEEF});
}
