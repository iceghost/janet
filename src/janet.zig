const std = @import("std");
pub const options = @import("root").janet_options;
const is_bootstrap = options.bootstrap;

const x = @import("x");

pub const gc = @import("gc.zig");
pub const value = @import("value.zig");
pub const Array = value.Array;
pub const Value = value.Box;

pub const c = @cImport({
    @cInclude("janet.h");
});

comptime {
    _ = @import("core/array.zig");
    _ = @import("core/util.zig");

    if (!is_bootstrap) {
        @export(&core_image_ptr, .{ .name = "janet_core_image" });
        @export(&core_image_size, .{ .name = "janet_core_image_size" });
    }
}

const core_image = if (@import("root").janet_options.bootstrap) "" else @embedFile("core.jimage");
const core_image_ptr: [*]const u8 = core_image.ptr;
const core_image_size: usize = core_image.len;

test "all janet test suites" {
    var iterator = x.testing.dir_fixtures.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        if (entry.kind == .file and
            std.mem.startsWith(u8, entry.name, "suite-") and
            std.mem.endsWith(u8, entry.name, ".janet"))
        {
            const suite_path = try x.testing.dir_fixtures.realPathFileAlloc(
                std.testing.io,
                entry.name,
                std.testing.allocator,
            );
            defer std.testing.allocator.free(suite_path);

            var child = try std.process.spawn(std.testing.io, .{
                .argv = &.{ x.testing.exe_path, suite_path },
            });
            defer child.kill(std.testing.io);
            try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(std.testing.io));
        }
    }
}
