//! Public interface of the `shell` module.
const std = @import("std");

pub const ShellCtx = @import("ShellCtx.zig");
pub const signals = @import("signals.zig");
pub const main = @import("repl.zig").run;

test {
    std.testing.refAllDecls(@This());
    _ = @import("ast.zig");
    _ = @import("Source.zig");
    _ = @import("diagnostics.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("prompt_words.zig");
    _ = @import("resolve.zig");
}
