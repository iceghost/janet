const std = @import("std");
const assert = std.debug.assert;

comptime {
    @export(&string_calchash, .{ .name = "janet_string_calchash" });
}

fn string_calchash(str: [*:0]const u8, len: i32) callconv(.c) i32 {
    const ulen: u32 = @intCast(len);
    const res: u32 = @truncate(std.hash_map.hashString(str[0..ulen]));
    return @bitCast(res);
}
