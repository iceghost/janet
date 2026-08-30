const std = @import("std");

const janet = @import("janet");
const c = janet.c;

pub const janet_options = .{
    .bootstrap = false,
};

extern fn janet_line_getter(argc: i32, argv: [*c]c.Janet) callconv(.c) c.Janet;
extern fn janet_line_init() callconv(.c) void;
extern fn janet_line_save_history() callconv(.c) void;
extern fn janet_line_deinit() callconv(.c) void;

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    _ = c.janet_init();

    const replacements = c.janet_table(0);
    c.janet_table_put(
        replacements,
        c.janet_csymbolv("getline"),
        c.janet_wrap_cfunction(&janet_line_getter),
    );
    janet_line_init();

    const env = c.janet_core_env(replacements);
    const args = c.janet_array(@intCast(argv.len));
    for (argv[1..]) |arg| {
        c.janet_array_push(args, c.janet_cstringv(arg.ptr));
    }

    c.janet_table_put(env, c.janet_ckeywordv("executable"), c.janet_cstringv(argv[0].ptr));

    var main_function: c.Janet = undefined;
    _ = c.janet_resolve(env, c.janet_csymbol("cli-main"), &main_function);
    const main_args = [1]c.Janet{c.janet_wrap_array(args)};
    const fiber = c.janet_fiber(c.janet_unwrap_function(main_function), 64, 1, &main_args);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    fiber.*.env = env;

    const status = c.janet_loop_fiber(fiber);

    janet_line_save_history();
    c.janet_deinit();
    janet_line_deinit();

    return @intCast(status);
}
