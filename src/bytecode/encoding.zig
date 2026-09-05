const janet = @import("janet");
const x = @import("x");

pub const Register = enum(u8) {
    _,

    pub const Far = enum(u16) {
        _,
    };
};

pub const LabelNear = enum(u16) {
    _,
};

pub const LabelFar = enum(u24) {
    _,
};

pub const FunctionDefinition = enum(u16) {
    _,
};

pub const FunctionEnvironment = enum(u8) {
    _,
};

pub const Upvalue = enum(u8) {
    _,
};

pub const Constant = enum(u8) {
    _,
};

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

pub const Instruction = packed struct(u32) {
    op: OpCode,
    /// Tag for various use (debug, or backpatch)
    tagged: bool = 0,
    payload: packed union(u24) {
        @"0": packed struct {
            unused: u24 = 0,
        },
        S: packed struct(u24) {
            slot: Register.Far,
            unused: u8 = 0,
        },
        L: packed struct(u24) {
            destination: LabelFar,
        },
        SS: packed struct(u24) {
            near: Register,
            far: Register.Far,
        },
        SL: packed struct(u24) {
            slot: Register,
            destination: LabelNear,
        },
        ST: packed struct(u24) {
            slot: Register,
            set: x.bit_set.Enum(janet.Value),
        },
        SI: packed struct(u24) {
            slot: Register,
            immediate: i16,
        },
        SD: packed struct(u24) {
            slot: Register,
            definition: FunctionDefinition,
        },
        SU: packed struct(u24) {
            slot: Register,
            immediate: u16,
        },
        SSS: packed struct(u24) {
            slot0: Register,
            slot1: Register,
            slot2: Register,
        },
        SSI: packed struct(u24) {
            slot0: Register,
            slot1: Register,
            immediate: i8,
        },
        SSU: packed struct(u24) {
            slot0: Register,
            slot1: Register,
            immediate: u8,
        },
        SES: packed struct(u24) {
            slot: Register,
            environment: FunctionEnvironment,
            upvalue: Upvalue,
        },
        SC: packed struct(u24) {
            slot: Register,
            constant: Constant,
        },
    },

    pub fn noop() Instruction {
        return .{ .op = .noop, .payload = .{ .@"0" = .{} } };
    }

    pub fn @"error"(slot: Register.Far) Instruction {
        return .{ .op = .@"error", .payload = .{ .S = .{ .slot = slot } } };
    }
};
