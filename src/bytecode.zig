const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const janet = @import("janet");
const x = @import("x");

pub const Compiler = @import("bytecode/compiler.zig");

comptime {
    _ = Compiler;
}

pub const OpCode = enum(u7) {
    noop,
    @"error",
    typecheck,
    @"return",
    return_nil,
    add_immediate,
    add,
    subtract_immediate,
    subtract,
    multiply_immediate,
    multiply,
    divide_immediate,
    divide,
    divide_floor,
    modulo,
    remainder,
    band,
    bor,
    bxor,
    bnot,
    shift_left,
    shift_left_immediate,
    shift_right,
    shift_right_immediate,
    shift_right_unsigned,
    shift_right_unsigned_immediate,
    move_far,
    move_near,
    jump,
    jump_if,
    jump_if_not,
    jump_if_nil,
    jump_if_not_nil,
    greater_than,
    greater_than_immediate,
    less_than,
    less_than_immediate,
    equals,
    equals_immediate,
    compare,
    load_nil,
    load_true,
    load_false,
    load_integer,
    load_constant,
    load_upvalue,
    load_self,
    set_upvalue,
    closure,
    push,
    push_2,
    push_3,
    push_array,
    call,
    tailcall,
    @"resume",
    signal,
    propagate,
    in,
    get,
    put,
    get_index,
    put_index,
    length,
    make_array,
    make_buffer,
    make_string,
    make_struct,
    make_table,
    make_tuple,
    make_bracket_tuple,
    greater_than_equal,
    less_than_equal,
    next,
    not_equals,
    not_equals_immediate,
    cancel,
    instruction_count,
};

pub const Quadruple = packed struct(u32) {
    op: OpCode,
    breakpoint: bool,
    payload: u24,
};

const Sourcemap = struct {
    line: i32,
    column: i32,
};

pub const Wip = struct {
    instructions: std.ArrayList(Quadruple),
    sourcemaps: std.ArrayList(Sourcemap),
    scopes: std.DoublyLinkedList,

    const Scope = struct {
        slots: janet.compile.Register.Allocator,

        const Function = struct {
            scope: Scope,
            constants: std.ArrayList(janet.Value),
            upvalues: janet.compile.Register.Allocator,

            fn append_constant(func: *Function, v: janet.Value) u32 {
                _ = func; // autofix
                _ = v; // autofix
                //
            }
        };
    };

    fn emit(self: *Wip, ins: Quadruple) void {
        _ = self; // autofix
        _ = ins; // autofix
        //
    }

    fn load_const(self: *Wip, v: janet.Value, reg: janet.compile.Register) void {
        specialized_opcode: switch (v.unwrap()) {
            .number => |f| {
                if (self.cannot_cast(f)) break :specialized_opcode;
            },
        }

        // no specialized opcode
        const cindex = self.add_constant();
        const payload: packed struct(u24) {
            reg: u8,
            cindex: u16,
        } = .{ .reg = reg, .cindex = cindex };

        self.emit(.{ .op = .load_constant, .payload = @bitCast(payload) });
    }
};

pub fn compile(
    rt: *janet.Runtime,
    source: janet.Value,
    env: *janet.value.Table,
    where: ?[*:0]const u8,
    lints: ?*janet.Array,
) Compiler.C.Result {
    var compiler: Compiler = undefined;
    compiler.init(env, where, lints);
    defer compiler.deinit(rt);

    return compiler.compile(rt, source);
}
