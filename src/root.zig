//! Public interface of the `shell` module.
const std = @import("std");

pub const ShellCtx = @import("ShellCtx.zig");
pub const signals = @import("signals.zig");
pub const main = @import("repl.zig").run;

test {
    std.testing.refAllDecls(@This());
}
