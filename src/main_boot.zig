const std = @import("std");
const janet = @import("janet");
const c = janet.c;

pub const janet_options = .{
    .bootstrap = true,
};

extern fn array_test() callconv(.c) c_int;
extern fn buffer_test() callconv(.c) c_int;
extern fn number_test() callconv(.c) c_int;
extern fn system_test() callconv(.c) c_int;
extern fn table_test() callconv(.c) c_int;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    janet.Runtime.state_shared = .{
        .gpa = init.gpa,
    };
    _ = c.janet_init();
    defer c.janet_deinit();

    _ = array_test();
    _ = buffer_test();
    _ = number_test();
    _ = system_test();
    _ = table_test();

    const env = c.janet_core_env(null);

    const args = c.janet_array(@intCast(argv.len));
    for (argv) |arg| {
        c.janet_array_push(args, c.janet_cstringv(arg.ptr));
    }
    c.janet_def(env, "boot/args", c.janet_wrap_array(args), "Command line arguments.");

    const config = c.janet_table(0);
    c.janet_def(env, "boot/config", c.janet_wrap_table(config), "Boot options");

    var source_dir = try std.Io.Dir.cwd().openDir(io, argv[1], .{});
    defer source_dir.close(io);
    try std.process.setCurrentDir(io, source_dir);

    const boot_source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/boot/boot.janet",
        allocator,
        .limited(std.math.maxInt(i32)),
    );
    defer allocator.free(boot_source);

    const status = c.janet_dobytes(
        env,
        boot_source.ptr,
        @intCast(boot_source.len),
        "boot.janet",
        null,
    );
    return @intCast(status);
}
