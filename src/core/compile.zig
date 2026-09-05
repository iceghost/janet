const std = @import("std");

const janet = @import("janet");
const Compiler = janet.bytecode.Compiler;
const x = @import("x");

comptime {
    @export(&default, .{ .name = "janet_compile" });
    @export(&lint, .{ .name = "janet_compile_lint" });
    @export(&fopts_default, .{ .name = "janetc_fopts_default" });
    @export(&value, .{ .name = "janetc_value" });
    @export(&toslots, .{ .name = "janetc_toslots" });
    @export(&toslotskv, .{ .name = "janetc_toslotskv" });
    @export(&pushslots, .{ .name = "janetc_pushslots" });
    @export(&scope, .{ .name = "janetc_scope" });
    @export(&popscope, .{ .name = "janetc_popscope" });
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
    var scratch = compiler.arena_per_compilation.promote(rt.gpa);
    defer compiler.arena_per_compilation = scratch.state;
    return compiler.compile_value(rt, scratch.allocator(), v, .{
        .flags = opts.flags,
        .hint = opts.unwrap_hint(),
    }) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
        error.CompileFailed => .constant(.nil),
    };
}

fn toslots(
    c: *Compiler.C,
    values: ?[*]const janet.Value,
    len: i32,
) callconv(.c) x.array_list.Thin(Compiler.C.Slot) {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", c);
    var scratch = compiler.arena_per_compilation.promote(rt.gpa);
    defer compiler.arena_per_compilation = scratch.state;
    return compiler.compile_value_many(rt, scratch.allocator(), x.c_slice(values, len)) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
        error.CompileFailed => .empty,
    };
}

fn toslotskv(c: *Compiler.C, ds: janet.Value) callconv(.c) x.array_list.Thin(Compiler.C.Slot) {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", c);

    var scratch = compiler.arena_per_compilation.promote(rt.gpa);
    defer compiler.arena_per_compilation = scratch.state;
    return compiler.compile_value_many_kv(
        rt,
        scratch.allocator(),
        switch (ds.repr.unwrap_tag()) {
            .@"struct" => .from_struct(ds.unwrap().@"struct"),
            .table => .from_table(ds.unwrap().table),
            else => unreachable,
        },
    ) catch |err| switch (err) {
        error.OutOfMemory => rt.oom(),
        error.CompileFailed => .empty,
    };
}

fn pushslots(c: *Compiler.C, slots: x.array_list.Thin(Compiler.C.Slot)) callconv(.c) i32 {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", c);

    var scratch = compiler.arena_per_compilation.promote(rt.gpa);
    defer compiler.arena_per_compilation = scratch.state;

    var arguments = slots;
    const res = compiler.emit_arguments(rt, scratch.allocator(), arguments.items());
    return if (res.spliced) -1 - res.min_arity else res.min_arity;
}

fn scope(s: *Compiler.C.Scope, c: *Compiler.C, flags: Compiler.C.Scope.Flags, name: [*:0]const u8) callconv(.c) void {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", c);
    compiler.push_scope(rt, s, std.mem.span(name), flags) catch rt.oom();
}

fn popscope(c: *Compiler.C) callconv(.c) void {
    const rt: *janet.Runtime = .default();
    const compiler: *Compiler = @fieldParentPtr("c", c);
    compiler.pop_scope(rt) catch rt.oom();
}
