//! Windows single-instance handoff using a local named-pipe endpoint.
//!
//! The first process owns a named pipe; later processes forward a compact
//! argv payload to it and return `.already_running`.  The handoff handler runs on a
//! listener thread, so it must hand GUI work back to the UI thread.
const std = @import("std");
const w = std.os.windows;

pub const SecondInstanceFn = *const fn (argv: []const []const u8, user_data: ?*anyopaque) void;
pub const LockResult = enum { acquired, already_running };

pub const Options = struct {
    app_id: []const u8,
    allocator: std.mem.Allocator,
    on_second_instance: ?SecondInstanceFn = null,
    user_data: ?*anyopaque = null,
};

const file_flag_first_pipe_instance: w.DWORD = 0x0008_0000;
const pipe_access_duplex: w.DWORD = 0x0000_0003;
const pipe_type_byte: w.DWORD = 0;
const pipe_readmode_byte: w.DWORD = 0;
const pipe_wait: w.DWORD = 0;
const pipe_reject_remote_clients: w.DWORD = 0x0000_0008;
const pipe_unlimited_instances: w.DWORD = 255;
const generic_read: w.DWORD = 0x8000_0000;
const generic_write: w.DWORD = 0x4000_0000;
const open_existing: w.DWORD = 3;
const error_access_denied = @as(w.Win32Error, @enumFromInt(5));
const error_pipe_connected = @as(w.Win32Error, @enumFromInt(535));
const thread_terminate: w.DWORD = 0x0001;

extern "kernel32" fn CreateFileW(?w.LPCWSTR, w.DWORD, w.DWORD, ?*w.SECURITY_ATTRIBUTES, w.DWORD, w.DWORD, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn CreateNamedPipeW(w.LPCWSTR, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD, ?*w.SECURITY_ATTRIBUTES) callconv(.winapi) w.HANDLE;
extern "kernel32" fn ConnectNamedPipe(w.HANDLE, ?*anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn DisconnectNamedPipe(w.HANDLE) callconv(.winapi) w.BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) w.DWORD;
extern "kernel32" fn OpenThread(w.DWORD, w.BOOL, w.DWORD) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn CancelSynchronousIo(w.HANDLE) callconv(.winapi) w.BOOL;

pub const SingletonApp = struct {
    allocator: std.mem.Allocator,
    endpoint: [:0]u16,
    handoff: ?SecondInstanceFn,
    handoff_context: ?*anyopaque,
    host: ?*PipeHost = null,

    pub fn init(options: Options) !SingletonApp {
        if (options.app_id.len == 0) return error.InvalidAppId;
        const endpoint_utf8 = try std.fmt.allocPrint(options.allocator, "\\\\.\\pipe\\{s}", .{options.app_id});
        defer options.allocator.free(endpoint_utf8);
        const endpoint = std.unicode.utf8ToUtf16LeAllocZ(options.allocator, endpoint_utf8) catch return error.InvalidAppId;
        return .{
            .allocator = options.allocator,
            .endpoint = endpoint,
            .handoff = options.on_second_instance,
            .handoff_context = options.user_data,
        };
    }

    pub fn deinit(self: *SingletonApp) void {
        if (self.host) |host| {
            std.log.info("singleton cleanup: stopping handoff listener", .{});
            host.stop();
            std.log.info("singleton cleanup: handoff listener stopped", .{});
            self.allocator.destroy(host);
        }
        self.allocator.free(self.endpoint);
    }

    pub fn requestSingleInstanceLock(self: *SingletonApp, argv: []const []const u8) !LockResult {
        if (self.host != null) return error.AlreadyCalled;
        const listener = createListener(self.endpoint, true);
        if (listener == w.INVALID_HANDLE_VALUE) {
            if (w.GetLastError() != error_access_denied) return error.LockUnavailable;
            try relayInvocation(self.endpoint, argv);
            return .already_running;
        }

        const host = try self.allocator.create(PipeHost);
        errdefer self.allocator.destroy(host);
        host.* = .{
            .endpoint = self.endpoint,
            .handoff = self.handoff,
            .handoff_context = self.handoff_context,
            .thread = undefined,
            .accepting = std.atomic.Value(u8).init(1),
            .thread_id = std.atomic.Value(w.DWORD).init(0),
        };
        host.thread = try std.Thread.spawn(.{}, PipeHost.serve, .{ host, listener });
        self.host = host;
        return .acquired;
    }
};

const PipeHost = struct {
    endpoint: [:0]const u16,
    handoff: ?SecondInstanceFn,
    handoff_context: ?*anyopaque,
    thread: std.Thread,
    accepting: std.atomic.Value(u8),
    thread_id: std.atomic.Value(w.DWORD),

    fn stop(self: *PipeHost) void {
        std.log.debug("singleton listener stop requested", .{});
        self.accepting.store(0, .release);
        // A handoff can be waiting in synchronous ConnectNamedPipe or
        // ReadFile.  Cancelling that operation lets shutdown complete even
        // when a second launch dies part-way through its handoff.
        const id = self.thread_id.load(.acquire);
        if (id != 0) {
            if (OpenThread(thread_terminate, w.FALSE, id)) |thread_handle| {
                defer w.CloseHandle(thread_handle);
                _ = CancelSynchronousIo(thread_handle);
            }
        }
        // Wake a pending ConnectNamedPipe. The empty connection makes the
        // listener re-check `accepting` and close its server handle.
        const client = CreateFileW(self.endpoint.ptr, generic_read | generic_write, 0, null, open_existing, 0, null);
        if (client != w.INVALID_HANDLE_VALUE) w.CloseHandle(client);
        self.thread.join();
        std.log.debug("singleton listener thread joined", .{});
    }

    fn serve(self: *PipeHost, initial_listener: w.HANDLE) void {
        self.thread_id.store(GetCurrentThreadId(), .release);
        var listener = initial_listener;
        while (self.accepting.load(.acquire) != 0) {
            const connected = ConnectNamedPipe(listener, null);
            if (connected == w.FALSE and w.GetLastError() != error_pipe_connected) {
                w.CloseHandle(listener);
                return;
            }
            if (self.accepting.load(.acquire) == 0) {
                _ = DisconnectNamedPipe(listener);
                w.CloseHandle(listener);
                return;
            }
            const argv = decodeArguments(std.heap.page_allocator, listener) catch null;
            if (argv) |args| {
                defer freeArguments(std.heap.page_allocator, args);
                if (self.handoff) |handoff| handoff(args, self.handoff_context);
            }
            if (self.accepting.load(.acquire) == 0) {
                _ = DisconnectNamedPipe(listener);
                w.CloseHandle(listener);
                return;
            }

            // Keep at least one instance of the named pipe alive while a
            // client is being retired. Otherwise another process can win the
            // small close-then-create gap and start a parallel host.
            const replacement = createListener(self.endpoint, false);
            _ = DisconnectNamedPipe(listener);
            w.CloseHandle(listener);
            if (replacement == w.INVALID_HANDLE_VALUE) return;
            listener = replacement;
        }
        w.CloseHandle(listener);
    }
};

fn createListener(endpoint: [:0]const u16, first_instance: bool) w.HANDLE {
    return CreateNamedPipeW(endpoint.ptr, pipe_access_duplex | if (first_instance) file_flag_first_pipe_instance else 0, pipe_type_byte | pipe_readmode_byte | pipe_wait | pipe_reject_remote_clients, pipe_unlimited_instances, 64 * 1024, 64 * 1024, 0, null);
}

fn relayInvocation(endpoint: [:0]const u16, argv: []const []const u8) !void {
    const connection = CreateFileW(endpoint.ptr, generic_read | generic_write, 0, null, open_existing, 0, null);
    if (connection == w.INVALID_HANDLE_VALUE) return error.SecondaryConnectFailed;
    defer w.CloseHandle(connection);
    try encodeArguments(connection, argv);
}

fn encodeArguments(connection: w.HANDLE, argv: []const []const u8) !void {
    if (argv.len > 64) return error.TooManyArgs;
    try writeInt(connection, @intCast(argv.len));
    for (argv) |arg| {
        if (arg.len > 4096) return error.ArgumentTooLong;
        try writeInt(connection, @intCast(arg.len));
        try writeAll(connection, arg);
    }
}

fn decodeArguments(allocator: std.mem.Allocator, connection: w.HANDLE) ![]const []const u8 {
    const count = try readInt(connection);
    if (count > 64) return error.TooManyArgs;
    const argv = try allocator.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    while (filled < argv.len) : (filled += 1) {
        const len = try readInt(connection);
        if (len > 4096) return error.ArgumentTooLong;
        const arg = try allocator.alloc(u8, len);
        errdefer allocator.free(arg);
        try readAll(connection, arg);
        argv[filled] = arg;
    }
    return argv;
}

fn freeArguments(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn writeInt(pipe: w.HANDLE, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writeAll(pipe, &bytes);
}

fn readInt(pipe: w.HANDLE) !u32 {
    var bytes: [4]u8 = undefined;
    try readAll(pipe, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

fn writeAll(pipe: w.HANDLE, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) written += try w.WriteFile(pipe, bytes[written..], null);
}

fn readAll(pipe: w.HANDLE, bytes: []u8) !void {
    var read: usize = 0;
    while (read < bytes.len) {
        const n = try w.ReadFile(pipe, bytes[read..], null);
        if (n == 0) return error.UnexpectedEof;
        read += n;
    }
}
