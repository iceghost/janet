const std = @import("std");
const janet = @import("janet");
const c = janet.c;

pub const janet_options = .{
    .bootstrap = true,
    .is_codegen = false,
    .nanbox = true,
};

extern fn janet_core_env(?*janet.value.Table) callconv(.c) *janet.value.Table;
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
        // bootstrap runs only once anyway, use an arena
        .gpa = init.arena.allocator(),
    };
    _ = c.janet_init();
    defer c.janet_deinit();

    const rt = janet.Runtime.default();

    _ = array_test();
    _ = buffer_test();
    _ = number_test();
    _ = system_test();
    _ = table_test();

    const env = janet_core_env(null);

    const args: *janet.Array = try .create(rt);
    try args.reserve(rt, argv.len);
    for (argv) |arg| {
        try args.push(rt, try .string(rt, arg));
    }
    try env.bind(rt, "boot/args", .array(args), .{ .doc = "Command line arguments." });

    const config: *janet.value.Table = try .create(rt);
    try env.bind(rt, "boot/config", .table(config), .{ .doc = "Boot options." });

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
        @ptrCast(env),
        boot_source.ptr,
        @intCast(boot_source.len),
        "boot.janet",
        null,
    );
    return @intCast(status);
}
