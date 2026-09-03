const std = @import("std");

const janet = @import("janet");
const c = janet.c;
const Array = janet.Array;
const String = janet.value.String;
const Table = janet.value.Table;
const Value = janet.Value;

pub const janet_options = .{
    .bootstrap = false,
    .is_codegen = false,
    .nanbox = true,
};

const CFunction = *const fn (argc: i32, argv: [*c]Value) callconv(.c) Value;

extern fn janet_line_getter(argc: i32, argv: [*c]Value) callconv(.c) Value;
extern fn janet_line_init() callconv(.c) void;
extern fn janet_line_save_history() callconv(.c) void;
extern fn janet_line_deinit() callconv(.c) void;
extern fn janet_wrap_cfunction(cfun: CFunction) callconv(.c) Value;
extern fn janet_core_env(replacements: *Table) callconv(.c) *Table;
extern fn janet_unwrap_function(value: Value) callconv(.c) *janet.value.Function;
extern fn janet_fiber(callee: *janet.value.Function, capacity: i32, argc: i32, argv: [*]const Value) callconv(.c) *c.JanetFiber;
extern fn janet_wrap_fiber(fiber: *c.JanetFiber) callconv(.c) Value;
extern fn janet_gcroot(root: Value) callconv(.c) void;

pub fn main(init: std.process.Init) !u8 {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    janet.Runtime.state_shared = .{
        .gpa = init.gpa,
    };
    _ = c.janet_init();

    const rt = janet.Runtime.default();

    const replacements: *janet.value.Table = try .create(rt);

    try replacements.put(
        rt,
        try .symbol(rt, "getline"),
        janet_wrap_cfunction(&janet_line_getter),
    );

    janet_line_init();

    const env = janet_core_env(replacements);
    const args: *janet.Array = try .create(rt);
    try args.reserve(rt, argv.len);
    for (argv[1..]) |arg| {
        try args.push(rt, try .string(rt, arg));
    }

    try env.put(
        rt,
        try .keyword(rt, "executable"),
        try .string(rt, argv[0]),
    );

    const main_function = env.resolve(try .intern(rt, "cli-main")).value;
    const main_args: [1]Value = .{.array(args)};
    const fiber = janet_fiber(janet_unwrap_function(main_function), 64, 1, &main_args);
    janet_gcroot(janet_wrap_fiber(fiber));
    fiber.*.env = @ptrCast(env);

    const status = c.janet_loop_fiber(fiber);

    janet_line_save_history();
    c.janet_deinit();
    janet_line_deinit();

    return @intCast(status);
}
