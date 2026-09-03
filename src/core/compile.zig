const janet = @import("janet");
const Compiler = janet.bytecode.Compiler;

comptime {
    @export(&default, .{ .name = "janet_compile" });
    @export(&lint, .{ .name = "janet_compile_lint" });
    @export(&fopts_default, .{ .name = "janetc_fopts_default" });
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

fn fopts_default(c: *Compiler.C) callconv(.c) Compiler.C.Fopts {
    return .init(@fieldParentPtr("c", c));
}
