//! Public interface of the `shell` module.
const std = @import("std");

pub const ShellCtx = @import("ShellCtx.zig");
pub const signals = @import("signals.zig");
pub const main = @import("run.zig").main;

test {
    std.testing.refAllDecls(@This());
    _ = @import("ast.zig");
    _ = @import("builtins.zig");
    _ = @import("Source.zig");
    _ = @import("diagnostics.zig");
    _ = @import("eval.zig");
    _ = @import("exec.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("prompt_words.zig");
    _ = @import("resolve.zig");
    _ = @import("run.zig");
    _ = @import("value.zig");
}
