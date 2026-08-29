const std = @import("std");
const allocator = std.heap.smp_allocator;

const janet = @import("janet");
const Register = janet.compile.Register;
const RegisterAllocator = janet.compile.Register.Allocator;

comptime {
    @export(&init, .{ .name = "janetc_regalloc_init" });
    @export(&deinit, .{ .name = "janetc_regalloc_deinit" });
    @export(&alloc, .{ .name = "janetc_regalloc_1" });
    @export(&free, .{ .name = "janetc_regalloc_free" });
    @export(&temp, .{ .name = "janetc_regalloc_temp" });
    @export(&free_temp, .{ .name = "janetc_regalloc_freetemp" });
    @export(&clone, .{ .name = "janetc_regalloc_clone" });
    @export(&reserve, .{ .name = "janetc_regalloc_reserve" });
    @export(&touch, .{ .name = "janetc_regalloc_touch" });
    @export(&check, .{ .name = "janetc_regalloc_check" });
}

fn init(registers: *RegisterAllocator) callconv(.c) void {
    registers.* = RegisterAllocator.init();
}

fn deinit(registers: *RegisterAllocator) callconv(.c) void {
    registers.deinit(allocator);
}

fn alloc(registers: *RegisterAllocator) callconv(.c) i32 {
    const reg = registers.alloc(allocator) catch janet.oom();
    return @bitCast(@intFromEnum(reg));
}

fn free(registers: *RegisterAllocator, reg: i32) callconv(.c) void {
    registers.free(@enumFromInt(@as(u32, @bitCast(reg))));
}

fn temp(registers: *RegisterAllocator, nth: c_int) callconv(.c) i32 {
    const reg = registers.temp(allocator, @enumFromInt(nth)) catch janet.oom();
    return @bitCast(@intFromEnum(reg));
}

fn free_temp(registers: *RegisterAllocator, reg: i32, nth: c_int) callconv(.c) void {
    const register: Register = @enumFromInt(@as(u32, @bitCast(reg)));
    registers.temp_free(register, @enumFromInt(nth));
}

fn clone(dest: *RegisterAllocator, src: *RegisterAllocator) callconv(.c) void {
    dest.* = src.clone(allocator) catch janet.oom();
}

fn reserve(registers: *RegisterAllocator, count: u32) callconv(.c) void {
    registers.reserve(allocator, count) catch janet.oom();
}

fn touch(registers: *RegisterAllocator, reg: i32) callconv(.c) void {
    registers.touch(@enumFromInt(@as(u32, @bitCast(reg))));
}

fn check(registers: *RegisterAllocator, reg: i32) callconv(.c) c_int {
    const register: Register = @enumFromInt(@as(u32, @bitCast(reg)));
    return @intFromBool(registers.check(register));
}
