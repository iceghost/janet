const janet = @import("janet");

comptime {
    @export(&init_zig, .{ .name = "janet_init_zig" });
    @export(&deinit_zig, .{ .name = "janet_deinit_zig" });
}

fn init_zig(c_state: *janet.State.C) callconv(.c) void {
    c_state.init_zig() catch janet.oom();
}

fn deinit_zig(c_state: *janet.State.C) callconv(.c) void {
    c_state.deinit_zig();
}
