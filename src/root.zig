//! Public interface of the `shell` module.
const std = @import("std");

pub const ShellCtx = @import("ShellCtx.zig");

test {
    std.testing.refAllDecls(@This());
}
