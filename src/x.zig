const std = @import("std");
const Io = std.Io;

pub const testing = struct {
    pub var exe_path: [:0]const u8 = undefined;
    pub var dir_fixtures: Io.Dir = undefined;
};
