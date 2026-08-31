const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

const x = @import("x");

pub const janet_options = .{
    .bootstrap = false,
    .nanbox = true,
};

const Runner = struct {
    io: Io,
    gpa: Allocator,
    init: std.process.Init.Minimal,
    arena: Allocator,
    stdout: *Io.Writer,
    stdin: *Io.Reader,

    fn run(runner: *Runner) !void {
        for (builtin.test_functions) |test_fn| {
            try runner.run_one(test_fn);
        }
    }

    fn run_one(runner: *Runner, test_fn: std.builtin.TestFn) !void {
        std.testing.allocator_instance = .init;
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(runner.init.args),
            .environ = runner.init.environ,
        });
        std.testing.environ = runner.init.environ;
        defer std.testing.io_instance.deinit();
        defer if (std.testing.allocator_instance.deinit() == .leak) {
            @panic("test leaked memory");
        };
        try test_fn.func();
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    x.testing.exe_path = args[1];
    x.testing.dir_fixtures = try Io.Dir.cwd().openDir(io, args[2], .{ .iterate = true });

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    var stdin_buffer: [128]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);

    var runner: Runner = .{
        .arena = init.arena.allocator(),
        .gpa = init.gpa,
        .init = init.minimal,
        .io = init.io,
        .stdin = &stdin_reader.interface,
        .stdout = &stdout_writer.interface,
    };

    try runner.run();
}
