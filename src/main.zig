const std = @import("std");
const shell = @import("shell");

pub fn main(init: std.process.Init) !u8 {
    return shell.main(init);
}
