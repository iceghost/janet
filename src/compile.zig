const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const janet = @import("janet");
const x = @import("x");
const ThinArrayList = x.array_list.Thin;

pub const SourceMapping = extern struct {
    line: i32,
    column: i32,
};

pub const CompileResult = extern struct {
    funcdef: ?*janet.c.JanetFuncDef,
    @"error": ?[*:0]const u8,
    macrofiber: ?*janet.c.JanetFiber,
    error_mapping: SourceMapping,
    status: Status,

    pub const Status = enum(i32) {
        ok,
        @"error",
    };
};

pub const Slot = extern struct {
    constant: janet.Value,
    index: i32,
    envindex: i32,
    flags: u32,
};

pub const SymPair = extern struct {
    slot: Slot,
    sym: ?[*:0]const u8,
    sym2: ?[*:0]const u8,
    keep: i32,
    referenced: i32,
    birth_pc: u32,
    death_pc: u32,
};

pub const EnvRef = extern struct {
    envindex: i32,
    scope: *Scope,
};

pub const Scope = extern struct {
    name: [*:0]const u8,
    parent: ?*Scope,
    child: ?*Scope,
    consts: ThinArrayList(janet.Value),
    syms: ThinArrayList(SymPair),
    defs: ThinArrayList(*janet.c.JanetFuncDef),
    ra: Register.Allocator,
    ua: Register.Allocator,
    envs: ThinArrayList(EnvRef),
    bytecode_start: i32,
    flags: Flags,

    pub const Flags = packed struct(i32) {
        function: bool,
        env: bool,
        top: bool,
        unused: bool,
        closure: bool,
        @"while": bool,
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

pub const State = extern struct {
    scope: *Scope,
    buffer: ThinArrayList(u32),
    mapbuffer: ThinArrayList(SourceMapping),
    env: ?*janet.c.JanetTable,
    source: ?[*:0]const u8,
    result: CompileResult,
    current_mapping: SourceMapping,
    recursion_guard: i32,
    lints: ?*janet.Array.Extern,
    is_redef: i32,

    const Extern = extern struct {
        scope: ?*Scope,
        buffer: ThinArrayList(u32),
        mapbuffer: ThinArrayList(SourceMapping),
        env: ?*janet.c.JanetTable,
        source: ?[*:0]const u8,
        result: CompileResult,
        current_mapping: SourceMapping,
        recursion_guard: i32,
        lints: ?*janet.Array.Extern,
        is_redef: i32,
    };

    /// Emit a raw instruction with source mapping
    fn emit(self: *State, instruction: janet.bytecode.Quadruple) void {
        self.buffer.append(instruction);
        self.mapbuffer.append(self.current_mapping);
    }

    /// Add a constant to the current scope, return the index of the constant
    fn constant(self: *State, v: janet.Value) u32 {
        const scope = self.scope.find_outermost_function().?;
        // Check if already added
        for (scope.consts.items(), 0..) |c, i| {
            if (janet.value.eql(v, c)) return i;
        }
        try scope.consts.ensure_bounded(1, 0xFFFF);
        scope.consts.append(v);
        return scope.consts.items().len;
    }
};

pub const Fopts = extern struct {
    compiler: *State,
    hint: Slot,
    flags: u32,
};

pub const FunOptimizer = extern struct {
    can_optimize: *const fn (Fopts, ?[*]Slot) callconv(.c) i32,
    optimize: *const fn (Fopts, ?[*]Slot) callconv(.c) Slot,
};

pub const Special = extern struct {
    name: [*:0]const u8,
    compile: *const fn (Fopts, i32, ?[*]const janet.Value) callconv(.c) Slot,
};

pub const Register = enum(u32) {
    temp_0 = 240,
    temp_1,
    temp_2,
    temp_3,
    temp_4,
    temp_5,
    temp_6,
    temp_7,
    _,

    fn temp_bit(self: Register) u3 {
        const bit_index = @intFromEnum(self);
        assert(bit_index >= @intFromEnum(Register.temp_0));
        assert(bit_index <= @intFromEnum(Register.temp_7));
        return @intCast(bit_index - @intFromEnum(Register.temp_0));
    }

    fn max(a: Register, b: Register) Register {
        const a_val = @intFromEnum(a);
        const b_val = @intFromEnum(b);
        return if (a_val > b_val) a else b;
    }

    // pub const Temp = enum(u3) {
    //     temp_0,
    //     temp_1,
    //     temp_2,
    //     temp_3,
    //     temp_4,
    //     temp_5,
    //     temp_6,
    //     temp_7,
    // };

    pub const Allocator = extern struct {
        bit_set: x.bit_set.Dynamic,
        /// The maximum allocated register so far.
        max: Register,
        /// Holds which temporary registers are allocated.
        temps: std.bit_set.IntegerBitSet(32),

        pub fn init() Register.Allocator {
            return .{
                .bit_set = .empty,
                .max = @enumFromInt(0),
                .temps = .empty,
            };
        }

        pub fn deinit(self: *Register.Allocator, gpa: mem.Allocator) void {
            self.bit_set.deinit(gpa);
        }

        pub fn clone(self: *const Register.Allocator, gpa: mem.Allocator) mem.Allocator.Error!Register.Allocator {
            var copy = init();
            copy.bit_set = try self.bit_set.clone(gpa);
            copy.max = self.max;
            return copy;
        }

        fn reserve_temps(self: *Register.Allocator, gpa: mem.Allocator) mem.Allocator.Error!void {
            // Registers 240-255 are reserved and therefore always allocated.
            try self.bit_set.reserve_total(gpa, 0x100);
            var reg = @intFromEnum(Register.temp_0);
            while (reg < 0x100) : (reg += 1) {
                self.bit_set.set(reg);
            }
        }

        /// Ensure registers below `total` can be accessed.
        pub fn reserve(self: *Register.Allocator, gpa: mem.Allocator, total: u32) mem.Allocator.Error!void {
            if (total > @intFromEnum(Register.temp_0)) try self.reserve_temps(gpa);
            try self.bit_set.reserve_total(gpa, total);
        }

        /// Mark a register as allocated.
        pub fn touch(self: *Register.Allocator, reg: Register) void {
            self.bit_set.set(@intFromEnum(reg));
        }

        /// Allocate the first available register.
        pub fn alloc(self: *Register.Allocator, gpa: mem.Allocator) mem.Allocator.Error!Register {
            var index = self.bit_set.find_first_unset();
            if (index == @intFromEnum(Register.temp_0)) {
                try self.reserve_temps(gpa);
                index = self.bit_set.find_first_unset();
            }

            try self.bit_set.reserve_total(gpa, index + 1);
            self.bit_set.set(index);

            const reg: Register = @enumFromInt(index);
            self.max = .max(self.max, reg);
            return reg;
        }

        /// Free a previously allocated register.
        pub fn free(self: *Register.Allocator, reg: Register) void {
            self.bit_set.unset(@intFromEnum(reg));
        }

        /// Return whether a register is allocated.
        pub fn check(self: Register.Allocator, reg: Register) bool {
            return self.bit_set.is_set(@intFromEnum(reg));
        }

        /// Allocate a temporary register that fits in eight bits.
        pub fn temp(self: *Register.Allocator, gpa: mem.Allocator, hint: Register) mem.Allocator.Error!Register {
            assert(!self.temps.isSet(hint.temp_bit()));
            self.temps.set(hint.temp_bit());
            errdefer self.temps.unset(hint.temp_bit());

            const reg = try self.alloc(gpa);
            if (@intFromEnum(reg) > 0xFF) {
                self.free(reg);
                self.max = .max(reg, self.max);
                return hint;
            } else {
                return reg;
            }
        }

        /// Free a register previously allocated with `temp`.
        pub fn temp_free(self: *Register.Allocator, reg: Register, hint: Register) void {
            assert(@intFromEnum(reg) <= 0xFF);
            self.temps.unset(hint.temp_bit());
            if (@intFromEnum(reg) < 0xF0) self.free(reg);
        }
    };
};

test "Register.Allocator" {
    const gpa = std.testing.allocator;
    var registers = Register.Allocator.init();
    defer registers.deinit(gpa);

    const reg_0: Register = @enumFromInt(0);
    const reg_1: Register = @enumFromInt(1);
    const reg_239: Register = @enumFromInt(239);

    try std.testing.expectEqual(reg_0, try registers.alloc(gpa));
    try std.testing.expectEqual(reg_1, try registers.alloc(gpa));
    registers.free(reg_0);
    try std.testing.expectEqual(reg_0, try registers.alloc(gpa));

    try registers.reserve(gpa, 0x100);
    registers.touch(reg_239);
    try std.testing.expect(registers.check(reg_239));
    try std.testing.expect(registers.check(.temp_0));
}

test "temporary register fallback does not leak" {
    const gpa = std.testing.allocator;
    var registers = Register.Allocator.init();
    defer registers.deinit(gpa);

    for (0..240) |_| _ = try registers.alloc(gpa);

    const reg = try registers.temp(gpa, .temp_0);
    try std.testing.expectEqual(Register.temp_0, reg);
    registers.temp_free(reg, .temp_0);

    const reg_256: Register = @enumFromInt(256);
    try std.testing.expectEqual(reg_256, try registers.alloc(gpa));
}
