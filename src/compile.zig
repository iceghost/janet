const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const x = @import("x");

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
