const std = @import("std");

var log_mutex: std.Thread.Mutex = .{};
var log_file: ?std.fs.File = null;
var enabled = std.atomic.Value(bool).init(false);
var session_stopped = false;
var bytes_written: usize = 0;
const max_session_bytes = 64 * 1024 * 1024;

pub fn isEnabled() bool {
    return enabled.load(.acquire);
}

pub fn setEnabled(value: bool) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    if (value and session_stopped) return;
    if (value and !enabled.load(.acquire)) {
        if (log_file) |file| file.close();
        log_file = null;
        openFreshLog();
    }
    enabled.store(value and log_file != null and !session_stopped, .release);
}

pub fn write(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled.load(.acquire)) return;
    log_mutex.lock();
    defer log_mutex.unlock();

    if (session_stopped) return;
    const file = log_file orelse return;
    var message: [1536]u8 = undefined;
    const rendered = std.fmt.bufPrint(&message, format, args) catch "<log message too long>";
    var line: [1800]u8 = undefined;
    const output = std.fmt.bufPrint(&line, "[{d}] [{s}] {s}: {s}\r\n", .{ std.time.milliTimestamp(), @tagName(level), @tagName(scope), rendered }) catch return;
    if (bytes_written + output.len > max_session_bytes) {
        const limit_message = std.fmt.bufPrint(&line, "[{d}] [warn] logger: 64 MiB session limit reached; logging disabled\r\n", .{std.time.milliTimestamp()}) catch "";
        file.writeAll(limit_message) catch {};
        session_stopped = true;
        enabled.store(false, .release);
        return;
    }
    file.writeAll(output) catch {};
    bytes_written += output.len;
}

fn openFreshLog() void {
    var executable_path: [std.fs.max_path_bytes]u8 = undefined;
    const executable = std.fs.selfExePath(&executable_path) catch return;
    const directory = std.fs.path.dirname(executable) orelse return;
    var current: [std.fs.max_path_bytes]u8 = undefined;
    var previous: [std.fs.max_path_bytes]u8 = undefined;
    var oldest: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&current, "{s}{c}steam-controller-battery.log", .{ directory, std.fs.path.sep }) catch return;
    const path_1 = std.fmt.bufPrint(&previous, "{s}.1", .{path}) catch return;
    const path_2 = std.fmt.bufPrint(&oldest, "{s}.2", .{path}) catch return;

    std.fs.deleteFileAbsolute(path_2) catch {};
    std.fs.renameAbsolute(path_1, path_2) catch {};
    std.fs.renameAbsolute(path, path_1) catch {};
    const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
    log_file = file;
    session_stopped = false;
    bytes_written = 0;
}
