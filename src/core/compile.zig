const janet = @import("janet");

comptime {
    @export(&default, .{ .name = "janet_compile" });
    @export(&lint, .{ .name = "janet_compile_lint" });
}

fn default(
    source: janet.Value,
    env: *janet.value.Table,
    where: ?[*:0]const u8,
) callconv(.c) janet.bytecode.Compiler.C.Result {
    return janet.bytecode.compile(janet.Runtime.default(), source, env, where, null);
}

fn lint(
    source: janet.Value,
    env: *janet.value.Table,
    where: ?[*:0]const u8,
    lints: ?*janet.Array,
) callconv(.c) janet.bytecode.Compiler.C.Result {
    return janet.bytecode.compile(janet.Runtime.default(), source, env, where, lints);
}
