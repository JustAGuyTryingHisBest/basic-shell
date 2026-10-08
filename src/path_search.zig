//! Locating executables via `PATH`.
const std = @import("std");

/// Search path used when `PATH` is unset. POSIX leaves this
/// implementation-defined; this matches what most shells fall back to.
const default_search_path = "/usr/bin:/bin";

/// Resolves `command_name` to the path of an executable, following POSIX
/// "Command Search and Execution": a name containing '/' is used as-is;
/// otherwise each entry of `path_variable` is tried in order, with an empty
/// entry meaning the current directory. Pass `null` when `PATH` is unset.
/// The returned slice may point into `path_buffer`.
pub fn findExecutable(
    io: std.Io,
    path_variable: ?[]const u8,
    command_name: []const u8,
    path_buffer: []u8,
) ?[]const u8 {
    if (std.mem.findScalar(u8, command_name, '/') != null) return command_name;

    const search_path = path_variable orelse default_search_path;
    var search_directories = std.mem.splitScalar(u8, search_path, ':');
    while (search_directories.next()) |search_directory| {
        const directory = if (search_directory.len == 0) "." else search_directory;
        const candidate_path = std.fmt.bufPrint(path_buffer, "{s}/{s}", .{ directory, command_name }) catch continue;
        if (isExecutableFile(io, candidate_path)) return candidate_path;
    }
    return null;
}

fn isExecutableFile(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch return false;
    if (stat.kind != .file) return false;
    cwd.access(io, path, .{ .execute = true }) catch return false;
    return true;
}
