const std = @import("std");
const builtin = @import("builtin");

const x = @import("x");

pub const janet_options = .{
    .bootstrap = false,
    .is_codegen = true,
    .nanbox = true,
};

fn run_test(init: std.process.Init.Minimal, test_fn: std.builtin.TestFn) !void {
    std.testing.allocator_instance = .init;
    std.testing.io_instance = .init(std.testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    std.testing.environ = init.environ;
    defer std.testing.io_instance.deinit();
    defer if (std.testing.allocator_instance.deinit() == .leak) {
        @panic("test leaked memory");
    };
    try test_fn.func();
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);

    x.testing.is_codegen = true;
    x.testing.codegen_writer = &stdout_writer.interface;

    for (builtin.test_functions) |test_fn| {
        if (std.mem.indexOf(u8, test_fn.name, "[codegen]") != null) {
            try run_test(init.minimal, test_fn);
        }
    }

    try stdout_writer.interface.flush();
}
