comptime {
    _ = @import("janet");
}

pub const janet_options = .{
    .bootstrap = false,
};

// mainclient/shell.c
pub extern fn main(c_int, [*][*:0]const u8) callconv(.c) c_int;
