const janet = @import("janet");
const Compiler = janet.bytecode.Compiler;

comptime {
    @export(&default, .{ .name = "janet_compile" });
    @export(&lint, .{ .name = "janet_compile_lint" });
    @export(&fopts_default, .{ .name = "janetc_fopts_default" });
    @export(&value, .{ .name = "janetc_value" });
}

fn default(
    source: janet.Value,
    env: *janet.value.Table,
    where: ?[*:0]const u8,
) callconv(.c) Compiler.C.Result {
    const rt: *janet.Runtime = .default();
    return janet.bytecode.compile(rt, source, env, where, null) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
    };
}

fn lint(
    source: janet.Value,
    env: *janet.value.Table,
    where: ?[*:0]const u8,
    lints: ?*janet.Array,
) callconv(.c) Compiler.C.Result {
    const rt: *janet.Runtime = .default();
    return janet.bytecode.compile(rt, source, env, where, lints) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
    };
}

fn fopts_default(c: *Compiler.C) callconv(.c) Compiler.C.Fopts {
    return .init(@fieldParentPtr("c", c));
}

fn value(opts: Compiler.C.Fopts, v: janet.Value) callconv(.c) Compiler.C.Slot {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", opts.compiler);
    return compiler.compile_value(rt, opts.hint, opts.flags, v) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
    };
}
