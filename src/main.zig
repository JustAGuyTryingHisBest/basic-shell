const std = @import("std");
const shell = @import("shell");

pub fn main(init: std.process.Init) !void {
    try shell.main(init);
}
