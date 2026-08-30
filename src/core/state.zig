const janet = @import("janet");

comptime {
    @export(&init, .{ .name = "janet_init_zig" });
    @export(&deinit, .{ .name = "janet_deinit_zig" });
}

fn init(c_state: *janet.runtime.State.C) callconv(.c) void {
    c_state.init_zig(&janet.runtime.state_shared) catch janet.oom();
}

fn deinit(c_state: *janet.runtime.State.C) callconv(.c) void {
    c_state.deinit_zig();
}
