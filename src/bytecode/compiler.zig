const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const janet = @import("janet");
const Register = janet.compile.Register;
const x = @import("x");

const Compiler = @This();

c: C,
scope_root: C.Scope,
/// Allocate objects that last for one compilation
arena_per_compilation: std.heap.ArenaAllocator.State,

pub const Result = struct {
    def: *janet.value.FunctionDefinition,

    const Diagnostics = struct {
        @"error": []u8 = undefined,
        macrofiber: *janet.value.Fiber = undefined,
        mapping: C.SourceMapping = undefined,
        lints: ?*janet.Array = null,
    };
};

pub const C = extern struct {
    /// Pointer to current scope
    scope: ?*Scope,
    buffer: x.array_list.Thin(janet.bytecode.Quadruple) = .empty,
    mapbuffer: x.array_list.Thin(SourceMapping) = .empty,
    /// Hold the environment
    env: ?*janet.value.Table,
    /// Name of source to attach to generated functions
    source: ?[*:0]const u8,
    /// The result of compilation
    result: C.Result,
    /// Keep track of where we are in the source
    current_mapping: SourceMapping,
    /// Prevent unbounded recursion
    recursion_guard: i32,
    /// Collect linting result
    lints: ?*janet.Array,
    /// Cached version of (dyn *redef*)
    is_redef: i32,

    /// A lexical scope during compilation
    pub const Scope = extern struct {
        /// For debugging the compiler
        name: [*:0]const u8,
        /// Scopes are doubly linked list.
        parent: ?*Scope,
        /// Scopes are doubly linked list.
        child: ?*Scope,

        /// Constants for this funcdef
        consts: x.array_list.Thin(janet.Value),
        /// Map of symbols to slots. Use a simple linear scan for symbols
        syms: x.array_list.Thin(SymPair),
        /// FuncDefs
        defs: x.array_list.Thin(*janet.value.FunctionDefinition),
        /// Register allocator
        ra: Register.Allocator,
        /// Upvalue allocator
        ua: Register.Allocator,
        /// Referenced closure environments
        ///
        /// The values at each index correspond to which index to get the
        /// environment from in the parent. The environment that corresponds to the
        /// direct parent's stack will always have value 0
        envs: x.array_list.Thin(EnvRef),
        bytecode_start: i32,
        flags: Flags,

        pub const Flags = packed struct(i32) {
            function: bool = false,
            env: bool = false,
            top: bool = false,
            unused: bool = false,
            closure: bool = false,
            @"while": bool = false,
            reserved: u26 = 0,
        };

        pub fn find_outermost_function(self: *Scope) ?*Scope {
            var it: ?*Scope = self;
            while (it) |s| : (it = s.parent) {
                if (s.flags.function) return s;
            } else {
                return null;
            }
        }
    };

    /// Source mapping for a bytecode instruction.
    pub const SourceMapping = extern struct {
        line: i32,
        column: i32,
    };

    pub const Result = extern struct {
        funcdef: ?*janet.value.FunctionDefinition,
        @"error": ?[*:0]const u8,
        macrofiber: ?*janet.c.JanetFiber,
        error_mapping: SourceMapping,
        status: Status,

        pub const Status = enum(i32) {
            ok,
            @"error",
        };
    };

    pub const Fopts = extern struct {
        compiler: *C,
        hint: Slot,
        /// Accepted primitive types and form-compilation options.
        flags: Flags,

        pub const Flags = packed struct(u32) {
            type: x.bit_set.Enum(janet.Value.Tag) = .empty,
            tail: bool = false,
            hint: bool = false,
            drop: bool = false,
            accept_splice: bool = false,
            reserved: u12 = 0,
        };

        pub fn init(compiler: *Compiler) Fopts {
            return .{
                .compiler = &compiler.c,
                .flags = .{},
                .hint = .init_constant(.nil),
            };
        }
    };

    pub const Special = extern struct {
        name: [*:0]const u8,
        compile: *const fn (Fopts, i32, [*]const janet.Value) callconv(.c) Slot,
    };

    /// A symbol and slot pair.
    pub const SymPair = extern struct {
        slot: Slot,
        sym: ?[*:0]const u8,
        sym2: ?[*:0]const u8,
        keep: i32,
        /// Whether this value has been used.
        referenced: i32,
        birth_pc: u32,
        death_pc: u32,
    };

    pub const EnvRef = extern struct {
        envindex: i32,
        scope: *Scope,
    };

    /// A stack slot.
    pub const Slot = extern struct {
        /// The slot's constant value, when `flags.constant` is set.
        constant: janet.Value,
        index: i32,
        /// Zero for a local slot, or a positive number for an upvalue.
        envindex: i32,
        flags: Flags,

        pub const Flags = packed struct(u32) {
            type: x.bit_set.Enum(janet.Value.Tag) = .empty,
            constant: bool = false,
            named: bool = false,
            mutable: bool = false,
            ref: bool = false,
            returned: bool = false,
            dep_note: bool = false,
            dep_warn: bool = false,
            dep_error: bool = false,
            spliced: bool = false,
            reserved: u7 = 0,
        };

        pub fn init_constant(v: janet.Value) Slot {
            var slot: Slot = .{
                .flags = .{
                    .constant = true,
                },
                .index = -1,
                .constant = v,
                .envindex = -1,
            };

            slot.flags.type = slot.flags.type.set(v.repr.unwrap_tag());

            return slot;
        }

        pub fn init_far(c: *Compiler) mem.Allocator.Error!Slot {
            return .{
                .flags = .{
                    .type = .full,
                },
                .index = @bitCast(@intFromEnum(try c.allocfar())),
                .constant = .nil,
                .envindex = -1,
            };
        }

        pub fn free(slot: Slot, c: *Compiler) void {
            if (slot.flags.constant or slot.flags.ref or slot.flags.named) return;
            if (slot.envindex >= 0) return;
            c.c.scope.?.ra.free(@enumFromInt(@as(u32, @bitCast(slot.index))));
        }
    };
};

pub fn init(
    compiler: *Compiler,
    env: *janet.value.Table,
    source: ?[*:0]const u8,
    lints: ?*janet.Array,
) void {
    compiler.* = .{
        .arena_per_compilation = .init,
        .scope_root = undefined,
        .c = .{
            .scope = null,
            .buffer = .empty,
            .mapbuffer = .empty,
            .env = env,
            .source = source,
            .result = .{
                .funcdef = null,
                .@"error" = null,
                .macrofiber = null,
                .error_mapping = .{ .line = -1, .column = -1 },
                .status = .ok,
            },
            .current_mapping = .{ .line = -1, .column = -1 },
            .recursion_guard = 1024,
            .lints = lints,
            .is_redef = if (env.get_keyword("redef")) |v| @intFromBool(v.repr.truthy()) else 0,
        },
    };
}

pub fn deinit(compiler: *Compiler, rt: *janet.Runtime) void {
    var scratch = compiler.arena_per_compilation.promote(rt.gpa);
    scratch.deinit();
    compiler.* = undefined;
}

extern fn janet_sfree(memory: *anyopaque) callconv(.c) void;
extern fn janet_cstring(cstring: [*:0]const u8) callconv(.c) [*:0]const u8;
extern fn janet_tuple_n(values: ?[*]const janet.Value, count: i32) callconv(.c) [*]const janet.Value;
extern fn janet_def_addflags(def: *janet.value.FunctionDefinition) callconv(.c) void;
extern fn janetc_scope(scope: *C.Scope, compiler: *C, flags: C.Scope.Flags, name: [*:0]const u8) callconv(.c) void;
extern fn janetc_popscope(compiler: *C) callconv(.c) void;
extern fn janetc_pop_funcdef(compiler: *C) callconv(.c) *janet.value.FunctionDefinition;
extern fn janetc_array(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_tuple(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_bufferctor(options: C.Fopts, source: janet.Value) callconv(.c) C.Slot;
extern fn janetc_call(options: C.Fopts, slots: x.array_list.Thin(C.Slot), function: C.Slot, form: [*]const janet.Value) callconv(.c) C.Slot;
extern fn janetc_freeslot(compiler: *C, slot: C.Slot) callconv(.c) void;
extern fn janetc_resolve(compiler: *C, symbol: [*:0]const u8) callconv(.c) C.Slot;
extern fn janetc_return(compiler: *C, slot: C.Slot) callconv(.c) C.Slot;
extern fn janetc_copy(compiler: *C, destination: C.Slot, source: C.Slot) callconv(.c) void;
extern fn janetc_cerror(compiler: *C, message: [*:0]const u8) callconv(.c) void;
extern fn janetc_macroexpand1(compiler: *C, source: janet.Value, out: *janet.Value, special: *?*const C.Special) callconv(.c) c_int;
extern fn janetc_emit_s(compiler: *C, opcode: u8, slot: C.Slot, write: i32) callconv(.c) i32;
extern fn janetc_emit_ss(compiler: *C, opcode: u8, lhs: C.Slot, rhs: C.Slot, write: i32) callconv(.c) i32;
extern fn janetc_emit_sss(compiler: *C, opcode: u8, first: C.Slot, second: C.Slot, third: C.Slot, write: i32) callconv(.c) i32;

fn get_target(
    compiler: *Compiler,
    rt: *janet.Runtime,
    hint: C.Slot,
    flags: C.Fopts.Flags,
) mem.Allocator.Error!C.Slot {
    if (flags.hint and hint.envindex < 0 and hint.index >= 0 and hint.index <= 0xFF) return hint;
    return .{
        .constant = .nil,
        .index = @bitCast(@intFromEnum(try compiler.allocfar(rt))),
        .envindex = -1,
        .flags = .{},
    };
}

pub fn compile(
    compiler: *Compiler,
    rt: *janet.Runtime,
    arena: mem.Allocator,
    source: janet.Value,
) mem.Allocator.Error!C.Result {
    janetc_scope(&compiler.scope_root, &compiler.c, .{ .function = true, .top = true }, "root");

    _ = try compiler.compile_value(rt, arena, source, .{
        .flags = .{ .type = .full, .tail = true },
    });

    if (compiler.c.result.status == .ok) {
        const def = janetc_pop_funcdef(&compiler.c);
        def.name = janet_cstring("thunk");
        janet_def_addflags(def);
        compiler.c.result.funcdef = def;
    } else {
        compiler.c.result.error_mapping = compiler.c.current_mapping;
        janetc_popscope(&compiler.c);
    }

    return compiler.c.result;
}

pub fn compile_value(
    compiler: *Compiler,
    rt: *janet.Runtime,
    arena: mem.Allocator,
    v: janet.Value,
    options: struct {
        hint: C.Slot = .init_constant(.nil),
        flags: C.Fopts.Flags = .{},
    },
) mem.Allocator.Error!C.Slot {
    const last_mapping = compiler.c.current_mapping;
    compiler.c.recursion_guard -= 1;

    if (compiler.c.result.status == .@"error") return .init_constant(.nil);
    if (compiler.c.recursion_guard <= 0) {
        janetc_cerror(&compiler.c, "recursed too deeply");
        return .init_constant(.nil);
    }

    var source = v;
    var special: ?*const C.Special = null;
    var macro_expansions: usize = 200;
    while (macro_expansions > 0 and
        compiler.c.result.status != .@"error" and
        janetc_macroexpand1(&compiler.c, source, &source, &special) != 0) : (macro_expansions -= 1)
    {}
    if (macro_expansions == 0) {
        janetc_cerror(&compiler.c, "recursed too deeply in macro expansion");
        return .init_constant(.nil);
    }

    const fopts: C.Fopts = .{
        .compiler = &compiler.c,
        .hint = options.hint,
        .flags = options.flags,
    };
    var result: C.Slot = undefined;
    if (special) |s| {
        const tuple = source.unwrap().tuple;
        const values = tuple.slice();
        result = s.compile(fopts, @intCast(values.len - 1), values.ptr + 1);
    } else switch (source.repr.unwrap_tag()) {
        .tuple => {
            const tuple = source.unwrap().tuple;
            const values = tuple.slice();
            if (values.len == 0) {
                result = .init_constant(.tuple(try .from_slice(rt, &.{})));
            } else if ((@as(u32, @bitCast(tuple.gc.flags)) & 0x10000) != 0) {
                result = janetc_tuple(fopts, source);
            } else {
                const function = try compiler.compile_value(rt, arena, values[0], .{});
                defer janetc_freeslot(&compiler.c, function);

                const arguments = try compiler.compile_value_many(rt, arena, values[1..]);
                result = janetc_call(fopts, arguments, function, values.ptr);
            }
            result.flags.spliced = false;
        },
        .symbol => result = janetc_resolve(&compiler.c, source.unwrap().string.slice().ptr),

        inline .table, .@"struct" => |t| {
            const slots = try compiler.compile_value_many_kv(rt, arena, switch (t) {
                .@"struct" => .from_struct(source.unwrap().@"struct"),
                .table => .from_table(source.unwrap().table),
                else => comptime unreachable,
            });
            defer for (slots.items()) |s| s.free(compiler);

            const can_inline = switch (t) {
                .table => false,
                .@"struct" => for (slots.items()) |slot| {
                    if (!slot.flags.constant or slot.flags.spliced) break false;
                } else blk: {
                    break :blk true;
                },
                else => comptime unreachable,
            };

            if (can_inline) {
                assert(t == .@"struct");
                const ds: *janet.value.Struct = try .begin(rt, @intCast(slots.items().len / 2));
                var i: usize = 0;
                while (i < slots.items().len) : (i += 2) {
                    ds.put(slots.items()[i].constant, slots.items()[i + 1].constant, true);
                }
                result = .init_constant(.@"struct"(try ds.end(rt)));
            } else {
                _ = compiler.emit_arguments(rt, arena, slots.items());

                result = try get_target(compiler, rt, options.hint, options.flags);

                _ = janetc_emit_s(&compiler.c, @intFromEnum(switch (t) {
                    .table => janet.bytecode.OpCode.make_table,
                    .@"struct" => janet.bytecode.OpCode.make_struct,
                    else => comptime unreachable,
                }), result, 1);
            }
        },
        .array => result = janetc_array(fopts, source),
        .buffer => result = janetc_bufferctor(fopts, source),
        else => result = .init_constant(source),
    }

    if (compiler.c.result.status == .@"error") return .init_constant(.nil);
    if (options.flags.tail) result = janetc_return(&compiler.c, result);
    if (options.flags.hint) {
        janetc_copy(&compiler.c, options.hint, result);
        result = options.hint;
    }
    compiler.c.current_mapping = last_mapping;
    compiler.c.recursion_guard += 1;
    return result;
}

pub fn compile_value_many(
    compiler: *Compiler,
    rt: *janet.Runtime,
    arena: mem.Allocator,
    values: []const janet.Value,
) mem.Allocator.Error!x.array_list.Thin(C.Slot) {
    var slots: x.array_list.Thin(C.Slot) = .empty;
    try slots.reserve_total_precise(arena, @intCast(values.len));
    for (values) |v| {
        slots.append(try compiler.compile_value(rt, arena, v, .{
            .flags = .{ .accept_splice = true },
        }));
    }

    return slots;
}

fn sorted_keys(
    rt: *janet.Runtime,
    arena: mem.Allocator,
    view: janet.value.DictView,
) ![]u32 {
    var indices: std.ArrayList(u32) = try .initCapacity(arena, view.count);
    for (view.ptr[0..view.capacity], 0..) |v, i| {
        if (!v.key.checktype(.nil)) indices.appendAssumeCapacity(@intCast(i));
    }

    std.mem.sortUnstableContext(0, indices.items.len, struct {
        rt: *janet.Runtime,
        entries: []const janet.value.Pair,
        indices: []u32,

        pub fn lessThan(ctx: @This(), lhs: usize, rhs: usize) bool {
            return janet.value.order(ctx.rt, ctx.entries[ctx.indices[lhs]].key, ctx.entries[ctx.indices[rhs]].key) == .lt;
        }

        pub fn swap(ctx: @This(), lhs: usize, rhs: usize) void {
            std.mem.swap(u32, &ctx.indices[lhs], &ctx.indices[rhs]);
        }
    }{
        .rt = rt,
        .entries = view.ptr[0..view.capacity],
        .indices = indices.items,
    });

    return try indices.toOwnedSlice(arena);
}

pub fn compile_value_many_kv(
    compiler: *Compiler,
    rt: *janet.Runtime,
    arena: mem.Allocator,
    view: janet.value.DictView,
) !x.array_list.Thin(C.Slot) {
    const indices = try sorted_keys(rt, arena, view);
    var res: x.array_list.Thin(C.Slot) = .empty;
    try res.reserve_total_precise(arena, @intCast(2 * indices.len));
    for (indices) |i| {
        res.append(try compiler.compile_value(rt, arena, view.ptr[i].key, .{
            .flags = .{ .accept_splice = true },
        }));
        res.append(try compiler.compile_value(rt, arena, view.ptr[i].val, .{
            .flags = .{ .accept_splice = true },
        }));
    }
    return res;
}

pub fn emit_arguments(
    compiler: *Compiler,
    rt: *janet.Runtime,
    arena: mem.Allocator,
    slots: []C.Slot,
) struct {
    spliced: bool,
    min_arity: i32,
} {
    // TODO: break this function into a pure emitter, and one for calculating min_arity or spliced
    _ = rt;
    _ = arena;

    var index: usize = 0;
    var min_arity: i32 = 0;
    var has_splice = false;
    while (index < slots.len) {
        if (slots[index].flags.spliced) {
            _ = janetc_emit_s(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_array), slots[index], 0);
            index += 1;
            has_splice = true;
        } else if (index + 1 == slots.len) {
            _ = janetc_emit_s(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push), slots[index], 0);
            index += 1;
            min_arity += 1;
        } else if (slots[index + 1].flags.spliced) {
            _ = janetc_emit_s(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push), slots[index], 0);
            _ = janetc_emit_s(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_array), slots[index + 1], 0);
            index += 2;
            min_arity += 1;
            has_splice = true;
        } else if (index + 2 == slots.len) {
            _ = janetc_emit_ss(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_2), slots[index], slots[index + 1], 0);
            index += 2;
            min_arity += 2;
        } else if (slots[index + 2].flags.spliced) {
            _ = janetc_emit_ss(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_2), slots[index], slots[index + 1], 0);
            _ = janetc_emit_s(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_array), slots[index + 2], 0);
            index += 3;
            min_arity += 2;
            has_splice = true;
        } else {
            _ = janetc_emit_sss(&compiler.c, @intFromEnum(janet.bytecode.OpCode.push_3), slots[index], slots[index + 1], slots[index + 2], 0);
            index += 3;
            min_arity += 3;
        }
    }
    return .{
        .spliced = has_splice,
        .min_arity = min_arity,
    };
}

fn allocfar(compiler: *Compiler, rt: *janet.Runtime) mem.Allocator.Error!Register {
    // need to use gpa until C client is fully gone
    const reg = try compiler.c.scope.?.ra.alloc(rt.gpa);
    if (@intFromEnum(reg) > 0xFFFF) {
        janetc_cerror(&compiler.c, "ran out of internal registers");
    }
    return reg;
}
