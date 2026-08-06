const std = @import("std");
const diagnostic_log = @import("logging.zig");
const sdl = @import("sdl3");
const windows = std.os.windows;
const config_ui = @import("config_main.zig");
const app_module = @import("app");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = diagnostic_log.write,
};

const win = @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

extern "kernel32" fn SetUnhandledExceptionFilter(
    filter: ?*const fn (?*anyopaque) callconv(.winapi) win.LONG,
) callconv(.winapi) ?*anyopaque;

const tray_message = win.WM_APP + 1;
const refresh_timer_id: usize = 1;
const refresh_menu_id: usize = 1000;
const settings_menu_id: usize = 1003;
const quit_menu_id: usize = 1001;
const reload_settings_message = win.WM_APP + 2;
const debug_settings_message = win.WM_APP + 3;
const app_module_id = "com.bnorick.steam-controller-battery.tray";
const config_app_module_id = "com.bnorick.steam-controller-battery.config";
const config_interval_edit_id: usize = 2000;
const config_wait_edit_id: usize = 2008;
const config_autostart_check_id: usize = 2016;
const config_ok_button_id: usize = 2024;
const config_exit_button_id: usize = 2032;
const idc_arrow: usize = 32512;
const icon_size = 32;
const tooltip_capacity = 127;
const battery_probe_interval_ms = 25;
const steam_controller_vendor_id: u16 = 0x28de;
const steam_controller_product_id: u16 = 0x1304;
const default_interval_ms: u32 = 15_000;
const default_battery_wait_ms: u32 = 5_000;

const RuntimeOptions = struct {
    interval_ms: u32 = default_interval_ms,
    battery_wait_ms: u32 = default_battery_wait_ms,
};

const LaunchOptions = struct {
    autostart_action: enum {
        none,
        enable,
        disable,
    } = .none,
    background: bool = false,
    replace_existing: bool = false,
    debug_logging: bool = false,
    show_debug_ui: bool = false,
};

const StoredConfig = struct {
    interval_ms: u32 = default_interval_ms,
    battery_wait_ms: u32 = default_battery_wait_ms,
    autostart_enabled: bool = false,
};

const ConfigWindowState = struct {
    hwnd: win.HWND = null,
    interval_edit: win.HWND = null,
    wait_edit: win.HWND = null,
    autostart_check: win.HWND = null,
    ok_button: win.HWND = null,
    exit_button: win.HWND = null,
    chosen: ?StoredConfig = null,
};

const BatteryInfo = struct {
    power_state: sdl.SDL_PowerState,
    battery_percent: c_int,
    wait_ms: u32,
    timed_out: bool,
};

const Snapshot = struct {
    connected: bool = false,
    battery_percent: ?u8 = null,
    power_state: sdl.SDL_PowerState = sdl.SDL_POWERSTATE_UNKNOWN,
    wait_ms: u32 = 0,
    timed_out: bool = false,
};

const SharedState = struct {
    mutex: std.Thread.Mutex = .{},
    shutdown: bool = false,
    refresh_requested: bool = false,
    refresh_pending: bool = false,
    version: u64 = 0,
    snapshot: Snapshot = .{},
};

const App = struct {
    hwnd: win.HWND = null,
    nid: win.NOTIFYICONDATAA = std.mem.zeroes(win.NOTIFYICONDATAA),
    options: RuntimeOptions,
    options_mutex: std.Thread.Mutex = .{},
    worker: ?std.Thread = null,
    settings_open: bool = false,
    quitting: bool = false,
    shared: SharedState = .{},
    last_version: u64 = std.math.maxInt(u64),
    current_icon: ?win.HICON = null,

    fn requestShutdown(self: *App) void {
        self.shared.mutex.lock();
        self.shared.shutdown = true;
        self.shared.mutex.unlock();
    }

    fn isShutdown(self: *App) bool {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();
        return self.shared.shutdown;
    }

    fn requestRefresh(self: *App) void {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        self.shared.refresh_requested = true;
        self.shared.refresh_pending = true;
        self.shared.version += 1;
    }

    fn runtimeOptions(self: *App) RuntimeOptions {
        self.options_mutex.lock();
        defer self.options_mutex.unlock();
        return self.options;
    }

    fn setRuntimeOptions(self: *App, options: RuntimeOptions) void {
        self.options_mutex.lock();
        defer self.options_mutex.unlock();
        self.options = options;
    }

    fn takeRefreshRequest(self: *App) bool {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        const requested = self.shared.refresh_requested;
        self.shared.refresh_requested = false;
        return requested;
    }
};

var global_app: ?*App = null;
var global_config_window: ?*ConfigWindowState = null;

pub const panic = std.debug.FullPanic(trayPanic);

fn trayPanic(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    std.log.err("panic: {s}", .{message});

    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, "steam-controller-battery-tray panic:\n{s}", .{message}) catch "steam-controller-battery-tray panic";
    _ = win.MessageBoxA(null, text, "steam-controller-battery-tray panic", win.MB_OK | win.MB_ICONERROR);
    std.process.abort();
}

pub fn main() void {
    installCrashMarker();
    realMain() catch |err| {
        std.log.err("tray terminated with error: {t}", .{err});
        showLaunchError(err);
    };
}

fn installCrashMarker() void {
    _ = SetUnhandledExceptionFilter(unhandledException);
}

fn unhandledException(_: ?*anyopaque) callconv(.winapi) win.LONG {
    std.log.err("unhandled Windows exception; process is terminating", .{});
    return 1; // EXCEPTION_EXECUTE_HANDLER
}

fn realMain() !void {
    const launch_options = try parseArgs();

    switch (launch_options.autostart_action) {
        .enable => {
            try setAutostartEnabled(true);
            try setStoredAutostartEnabled(true);
            return;
        },
        .disable => {
            try setAutostartEnabled(false);
            try setStoredAutostartEnabled(false);
            return;
        },
        .none => {},
    }

    if (launch_options.debug_logging) diagnostic_log.setEnabled(true);

    if (!launch_options.background) {
        if (try requestDebugSettingsFromRunningTray()) return;
        return runInitialConfigSingleton(launch_options.show_debug_ui);
    }

    var singleton = try app_module.SingletonApp.init(.{
        .app_id = app_module_id,
        .allocator = std.heap.page_allocator,
        .on_second_instance = onSecondTrayInstance,
    });
    defer singleton.deinit();

    const forwarded_args = [_][]const u8{ "steam-controller-battery-tray", "--reload-settings" };
    const forwarded_len: usize = if (launch_options.replace_existing) 2 else 1;
    switch (try singleton.requestSingleInstanceLock(forwarded_args[0..forwarded_len])) {
        .acquired => {},
        .already_running => return,
    }
    std.log.info("tray singleton acquired; loading runtime settings", .{});

    const options = try resolveRuntimeOptions();

    var app = App{
        .options = options,
    };
    global_app = &app;
    defer global_app = null;

    std.log.info("starting tray: interval={d}ms battery_wait={d}ms", .{ options.interval_ms, options.battery_wait_ms });
    try runApp(&app);
}

/// The normal launch path shows configuration before it starts the tray app.
/// Keep that pre-tray phase single-instance too, using a separate name so the
/// configuration process can launch the tray process without blocking it.
fn runInitialConfigSingleton(show_debug_ui: bool) !void {
    var singleton = try app_module.SingletonApp.init(.{
        .app_id = config_app_module_id,
        .allocator = std.heap.page_allocator,
        .on_second_instance = onSecondConfigInstance,
    });
    defer singleton.deinit();

    switch (try singleton.requestSingleInstanceLock(&.{"steam-controller-battery-config"})) {
        .acquired => {},
        .already_running => return,
    }

    if (show_debug_ui) config_ui.requestDebugLoggingOption();
    if (try config_ui.runConfigUi()) |config| {
        std.log.info("initial configuration accepted; launching tray", .{});
        try config_ui.applyConfigAndLaunch(config);
    }
}

fn requestDebugSettingsFromRunningTray() !bool {
    var probe = try app_module.SingletonApp.init(.{ .app_id = app_module_id, .allocator = std.heap.page_allocator });
    defer probe.deinit();
    return switch (try probe.requestSingleInstanceLock(&.{ "steam-controller-battery-tray", "--show-debug-settings" })) {
        .acquired => false,
        .already_running => true,
    };
}

fn onSecondConfigInstance(_: []const []const u8, _: ?*anyopaque) void {
    config_ui.requestDebugLoggingOption();
}

/// The singleton listener runs off the UI thread.  Post a Win32 message
/// instead of reading or mutating `App` state here; the window procedure owns
/// config reloads and UI updates.
fn onSecondTrayInstance(argv: []const []const u8, _: ?*anyopaque) void {
    const app = global_app orelse return;
    const should_reload = for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--reload-settings")) break true;
    } else false;
    const show_debug_settings = for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--show-debug-settings")) break true;
    } else false;
    if (show_debug_settings) {
        _ = win.PostMessageA(app.hwnd, debug_settings_message, 0, 0);
        return;
    }
    std.log.info("received a secondary launch; reload_settings={}", .{should_reload});
    if (win.PostMessageA(app.hwnd, reload_settings_message, if (should_reload) 1 else 0, 0) == 0) {
        std.log.err("could not queue settings reload: Win32 error {d}", .{win.GetLastError()});
    } else {
        std.log.info("settings reload queued", .{});
    }
}

fn runApp(app: *App) !void {
    const instance = win.GetModuleHandleA(null);
    if (instance == null) return error.GetModuleHandleFailed;

    try registerWindowClass(instance);

    app.hwnd = win.CreateWindowExA(
        0,
        window_class_name,
        window_title,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        instance,
        null,
    );
    if (app.hwnd == null) return error.CreateWindowFailed;

    try initTrayIcon(app);
    defer {
        std.log.info("tray cleanup: removing tray icon", .{});
        removeTrayIcon(app);
    }
    std.log.info("tray icon installed", .{});

    try startBatteryWorker(app);
    defer {
        std.log.info("tray cleanup: stopping battery worker", .{});
        stopBatteryWorker(app);
    }

    _ = win.SetTimer(app.hwnd, refresh_timer_id, 250, null);
    defer _ = win.KillTimer(app.hwnd, refresh_timer_id);

    try refreshTrayIcon(app, true);

    var msg: win.MSG = std.mem.zeroes(win.MSG);
    while (!app.quitting) {
        const message_result = win.GetMessageA(&msg, null, 0, 0);
        std.log.debug("tray GetMessage returned {d} (message=0x{x})", .{ message_result, msg.message });
        if (message_result <= 0) break;
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageA(&msg);
    }
    std.log.info("tray message loop exited; quitting={} shutting down", .{app.quitting});
}

fn stopBatteryWorker(app: *App) void {
    app.requestShutdown();
    if (app.worker) |worker| {
        worker.join();
        app.worker = null;
        std.log.info("battery worker stopped", .{});
    }
}

fn startBatteryWorker(app: *App) !void {
    std.debug.assert(app.worker == null);
    app.shared.mutex.lock();
    app.shared.shutdown = false;
    app.shared.refresh_requested = true;
    app.shared.refresh_pending = true;
    app.shared.version += 1;
    app.shared.mutex.unlock();
    app.worker = try std.Thread.spawn(.{}, batteryWorkerMain, .{app});
}

fn runConfigWindowAndLaunch() !void {
    var config = try loadStoredConfig();
    const accepted = try runConfigWindow(&config);
    if (!accepted) return;

    try saveStoredConfig(config);
    try setAutostartEnabled(config.autostart_enabled);
    launchBackgroundInstance() catch |err| {
        showLaunchError(err);
        return err;
    };
}

fn runConfigWindow(config: *StoredConfig) !bool {
    const instance = win.GetModuleHandleA(null);
    if (instance == null) return error.GetModuleHandleFailed;

    try registerConfigWindowClass(instance);

    var state = ConfigWindowState{};
    global_config_window = &state;
    defer global_config_window = null;

    state.hwnd = win.CreateWindowExA(
        win.WS_EX_DLGMODALFRAME,
        config_window_class_name,
        config_window_title,
        win.WS_OVERLAPPED | win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        360,
        210,
        null,
        null,
        instance,
        config,
    );
    if (state.hwnd == null) return error.CreateWindowFailed;

    _ = win.ShowWindow(state.hwnd, win.SW_SHOW);
    _ = win.UpdateWindow(state.hwnd);

    var msg: win.MSG = std.mem.zeroes(win.MSG);
    while (win.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageA(&msg);
    }

    if (state.chosen) |chosen| {
        config.* = chosen;
        return true;
    }
    return false;
}

fn registerWindowClass(instance: win.HINSTANCE) !void {
    var wc: win.WNDCLASSEXA = std.mem.zeroes(win.WNDCLASSEXA);
    wc.cbSize = @sizeOf(win.WNDCLASSEXA);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = instance;
    wc.lpszClassName = window_class_name;

    if (win.RegisterClassExA(&wc) == 0) {
        return error.RegisterClassFailed;
    }
}

fn registerConfigWindowClass(instance: win.HINSTANCE) !void {
    var wc: win.WNDCLASSEXA = std.mem.zeroes(win.WNDCLASSEXA);
    wc.cbSize = @sizeOf(win.WNDCLASSEXA);
    wc.lpfnWndProc = configWindowProc;
    wc.hInstance = instance;
    wc.hCursor = win.LoadCursorW(null, @ptrFromInt(idc_arrow));
    wc.hbrBackground = win.GetSysColorBrush(win.COLOR_WINDOW);
    wc.lpszClassName = config_window_class_name;

    if (win.RegisterClassExA(&wc) == 0 and win.GetLastError() != win.ERROR_CLASS_ALREADY_EXISTS) {
        return error.RegisterClassFailed;
    }
}

fn initTrayIcon(app: *App) !void {
    app.current_icon = createTrayIcon(null, sdl.SDL_POWERSTATE_UNKNOWN, false) orelse return error.CreateIconFailed;

    app.nid.cbSize = @sizeOf(win.NOTIFYICONDATAA);
    app.nid.hWnd = app.hwnd;
    app.nid.uID = 1;
    app.nid.uFlags = win.NIF_MESSAGE | win.NIF_ICON | win.NIF_TIP;
    app.nid.uCallbackMessage = tray_message;
    app.nid.hIcon = app.current_icon.?;
    setTooltip(&app.nid, "Steam Controller Battery");

    if (win.Shell_NotifyIconA(win.NIM_ADD, &app.nid) == 0) {
        return error.ShellNotifyIconAddFailed;
    }
}

fn removeTrayIcon(app: *App) void {
    _ = win.Shell_NotifyIconA(win.NIM_DELETE, &app.nid);
    if (app.current_icon) |icon| {
        _ = win.DestroyIcon(icon);
        app.current_icon = null;
    }
}

fn refreshTrayIcon(app: *App, force: bool) !void {
    var snapshot: Snapshot = undefined;
    var refresh_pending = false;
    var version: u64 = 0;

    app.shared.mutex.lock();
    snapshot = app.shared.snapshot;
    refresh_pending = app.shared.refresh_pending;
    version = app.shared.version;
    app.shared.mutex.unlock();

    if (!force and version == app.last_version) return;

    const next_icon = createTrayIcon(snapshot.battery_percent, snapshot.power_state, refresh_pending) orelse return error.CreateIconFailed;
    const previous_icon = app.current_icon;

    app.current_icon = next_icon;
    app.nid.uFlags = win.NIF_ICON | win.NIF_TIP;
    app.nid.hIcon = next_icon;

    var tooltip_buffer: [128]u8 = undefined;
    const tooltip = buildTooltip(&tooltip_buffer, snapshot, refresh_pending);
    setTooltip(&app.nid, tooltip);

    if (win.Shell_NotifyIconA(win.NIM_MODIFY, &app.nid) == 0) {
        return error.ShellNotifyIconModifyFailed;
    }

    if (previous_icon) |icon| {
        _ = win.DestroyIcon(icon);
    }

    app.last_version = version;
}

fn buildTooltip(buffer: []u8, snapshot: Snapshot, refresh_pending: bool) [:0]const u8 {
    const suffix = if (refresh_pending) " (Refreshing...)" else "";

    if (!snapshot.connected) {
        return std.fmt.bufPrintZ(buffer, "Steam Controller Battery: disconnected{s}", .{suffix}) catch "Steam Controller Battery";
    }

    if (snapshot.battery_percent) |percent| {
        return std.fmt.bufPrintZ(
            buffer,
            "Steam Controller Battery: {d}%{s}",
            .{ percent, suffix },
        ) catch "Steam Controller Battery";
    }

    if (snapshot.timed_out) {
        return std.fmt.bufPrintZ(
            buffer,
            "Steam Controller Battery: unknown{s}",
            .{suffix},
        ) catch "Steam Controller Battery";
    }

    return std.fmt.bufPrintZ(
        buffer,
        "Steam Controller Battery: unknown{s}",
        .{suffix},
    ) catch "Steam Controller Battery";
}

fn setTooltip(nid: *win.NOTIFYICONDATAA, text: [:0]const u8) void {
    @memset(&nid.szTip, 0);
    const len = @min(text.len, tooltip_capacity);
    @memcpy(nid.szTip[0..len], text[0..len]);
    nid.szTip[len] = 0;
}

fn batteryWorkerMain(app: *App) void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_GAMEPAD)) {
        std.log.err("SDL gamepad initialization failed: {s}", .{sdl.SDL_GetError()});
        updateSnapshot(app, .{});
        return;
    }
    defer sdl.SDL_Quit();
    std.log.info("battery worker started", .{});

    while (!app.isShutdown()) {
        const snapshot = collectSnapshot(app, app.runtimeOptions());
        updateSnapshot(app, snapshot);

        var slept_ms: u32 = 0;
        const interval_ms = app.runtimeOptions().interval_ms;
        while (slept_ms < interval_ms and !app.isShutdown()) {
            if (app.takeRefreshRequest()) break;
            const chunk = @min(interval_ms - slept_ms, 250);
            sdl.SDL_Delay(chunk);
            slept_ms += chunk;
        }
    }
}

fn updateSnapshot(app: *App, snapshot: Snapshot) void {
    app.shared.mutex.lock();
    defer app.shared.mutex.unlock();

    app.shared.snapshot = snapshot;
    app.shared.refresh_pending = false;
    app.shared.version += 1;
}

fn collectSnapshot(app: *App, options: RuntimeOptions) Snapshot {
    sdl.SDL_PumpEvents();

    var count: c_int = 0;
    const ids = sdl.SDL_GetGamepads(&count);
    if (ids == null) {
        std.log.warn("SDL_GetGamepads failed: {s}", .{sdl.SDL_GetError()});
        return .{};
    }
    defer sdl.SDL_free(ids);

    if (count == 0) {
        std.log.debug("battery check: no Steam Controller detected (SDL reported no gamepads)", .{});
        return .{};
    }

    const id = findSteamControllerId(ids[0..@as(usize, @intCast(count))]) orelse {
        std.log.debug("battery check: no Steam Controller detected ({d} other gamepad(s))", .{count});
        return .{};
    };

    const gamepad = sdl.SDL_OpenGamepad(id) orelse {
        std.log.warn("SDL_OpenGamepad failed: {s}", .{sdl.SDL_GetError()});
        return .{ .connected = true };
    };
    defer sdl.SDL_CloseGamepad(gamepad);

    const battery = queryBatteryInfo(app, gamepad, options.battery_wait_ms);
    std.log.debug("controller battery: percent={d} state={any} wait={d}ms timed_out={}", .{ battery.battery_percent, battery.power_state, battery.wait_ms, battery.timed_out });

    return .{
        .connected = true,
        .battery_percent = if (battery.battery_percent >= 0) @as(u8, @intCast(battery.battery_percent)) else null,
        .power_state = battery.power_state,
        .wait_ms = battery.wait_ms,
        .timed_out = battery.timed_out,
    };
}

fn findSteamControllerId(ids: []const sdl.SDL_JoystickID) ?sdl.SDL_JoystickID {
    for (ids) |id| {
        const vendor = sdl.SDL_GetGamepadVendorForID(id);
        const product = sdl.SDL_GetGamepadProductForID(id);

        if (vendor == steam_controller_vendor_id and product == steam_controller_product_id) {
            return id;
        }
    }

    return null;
}

fn queryBatteryInfo(
    app: *App,
    gamepad: *sdl.SDL_Gamepad,
    battery_wait_ms: u32,
) BatteryInfo {
    var elapsed_ms: u32 = 0;

    while (true) {
        if (app.isShutdown()) {
            return .{
                .power_state = sdl.SDL_POWERSTATE_UNKNOWN,
                .battery_percent = -1,
                .wait_ms = elapsed_ms,
                .timed_out = true,
            };
        }
        var battery_percent: c_int = -1;
        const power_state = sdl.SDL_GetGamepadPowerInfo(gamepad, &battery_percent);

        if (power_state != sdl.SDL_POWERSTATE_UNKNOWN or battery_percent >= 0) {
            return .{
                .power_state = power_state,
                .battery_percent = battery_percent,
                .wait_ms = elapsed_ms,
                .timed_out = false,
            };
        }

        if (elapsed_ms >= battery_wait_ms) {
            return .{
                .power_state = power_state,
                .battery_percent = battery_percent,
                .wait_ms = elapsed_ms,
                .timed_out = true,
            };
        }

        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => {},
                else => {},
            }
        }

        sdl.SDL_Delay(battery_probe_interval_ms);
        elapsed_ms += battery_probe_interval_ms;
    }
}

fn createTrayIcon(percent: ?u8, power_state: sdl.SDL_PowerState, refresh_pending: bool) ?win.HICON {
    const screen_dc = win.GetDC(null);
    if (screen_dc == null) return null;
    defer _ = win.ReleaseDC(null, screen_dc);

    const mem_dc = win.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return null;
    defer _ = win.DeleteDC(mem_dc);

    const color_bmp = win.CreateCompatibleBitmap(screen_dc, icon_size, icon_size);
    if (color_bmp == null) return null;
    defer _ = win.DeleteObject(color_bmp);

    var mask_bits = [_]u8{0} ** ((icon_size * icon_size) / 8);
    const mask_bmp = win.CreateBitmap(icon_size, icon_size, 1, 1, &mask_bits);
    if (mask_bmp == null) return null;
    defer _ = win.DeleteObject(mask_bmp);

    const old_obj = win.SelectObject(mem_dc, color_bmp);
    defer _ = win.SelectObject(mem_dc, old_obj);

    var rect = win.RECT{
        .left = 0,
        .top = 0,
        .right = icon_size,
        .bottom = icon_size,
    };

    const background = chooseBackgroundColor(percent, power_state);
    const brush = win.CreateSolidBrush(background);
    if (brush == null) return null;
    defer _ = win.DeleteObject(brush);
    _ = win.FillRect(mem_dc, &rect, brush);

    if (refresh_pending) {
        const triangle_brush = win.CreateSolidBrush(win.RGB(0x00, 0x00, 0x00));
        if (triangle_brush == null) return null;
        defer _ = win.DeleteObject(triangle_brush);

        const old_brush = win.SelectObject(mem_dc, triangle_brush);
        defer _ = win.SelectObject(mem_dc, old_brush);

        const pen = win.CreatePen(win.PS_NULL, 0, 0);
        if (pen == null) return null;
        defer _ = win.DeleteObject(pen);

        const old_pen = win.SelectObject(mem_dc, pen);
        defer _ = win.SelectObject(mem_dc, old_pen);

        const badge_size = 10;
        var triangle = [_]win.POINT{
            .{ .x = icon_size - badge_size, .y = 0 },
            .{ .x = icon_size, .y = 0 },
            .{ .x = icon_size, .y = badge_size },
        };
        _ = win.Polygon(mem_dc, &triangle, triangle.len);
    }

    _ = win.SetBkMode(mem_dc, win.TRANSPARENT);
    _ = win.SetTextColor(mem_dc, chooseTextColor(percent, power_state));

    const font_height: c_int = if (percent != null and percent.? >= 100) -12 else -15;
    const font = win.CreateFontA(
        font_height,
        0,
        0,
        0,
        win.FW_BOLD,
        0,
        0,
        0,
        win.DEFAULT_CHARSET,
        win.OUT_DEFAULT_PRECIS,
        win.CLIP_DEFAULT_PRECIS,
        win.DEFAULT_QUALITY,
        win.DEFAULT_PITCH | win.FF_DONTCARE,
        "Segoe UI",
    );
    if (font != null) {
        const old_font = win.SelectObject(mem_dc, font);
        defer {
            _ = win.SelectObject(mem_dc, old_font);
            _ = win.DeleteObject(font);
        }
    }

    var text_buf: [8]u8 = undefined;
    const text = if (percent) |value|
        std.fmt.bufPrintZ(&text_buf, "{d}", .{value}) catch "?"
    else
        "?";

    _ = win.DrawTextA(
        mem_dc,
        text.ptr,
        -1,
        &rect,
        win.DT_CENTER | win.DT_VCENTER | win.DT_SINGLELINE | win.DT_NOPREFIX,
    );

    var icon_info: win.ICONINFO = std.mem.zeroes(win.ICONINFO);
    icon_info.fIcon = win.TRUE;
    icon_info.hbmMask = mask_bmp;
    icon_info.hbmColor = color_bmp;

    return win.CreateIconIndirect(&icon_info);
}

fn chooseBackgroundColor(percent: ?u8, power_state: sdl.SDL_PowerState) win.COLORREF {
    if (power_state == sdl.SDL_POWERSTATE_CHARGING or power_state == sdl.SDL_POWERSTATE_CHARGED) {
        return win.RGB(0x1F, 0x6F, 0xD2);
    }

    if (percent) |value| {
        if (value > 40) return win.RGB(0x00, 0xA8, 0x3A);
        if (value > 10) return win.RGB(0xD1, 0x8B, 0x00);
        return win.RGB(0xC8, 0x1D, 0x13);
    }

    return win.RGB(0x55, 0x55, 0x55);
}

fn chooseTextColor(percent: ?u8, power_state: sdl.SDL_PowerState) win.COLORREF {
    _ = percent;
    _ = power_state;
    return win.RGB(0xFF, 0xFF, 0xFF);
}

fn showContextMenu(app: *App) void {
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);

    _ = win.AppendMenuA(menu, win.MF_STRING, refresh_menu_id, "Refresh");
    _ = win.AppendMenuA(menu, win.MF_STRING, settings_menu_id, "Settings");
    _ = win.AppendMenuA(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuA(menu, win.MF_STRING, quit_menu_id, "Quit");

    var point: win.POINT = std.mem.zeroes(win.POINT);
    if (win.GetCursorPos(&point) == 0) return;

    _ = win.SetForegroundWindow(app.hwnd);
    const command = win.TrackPopupMenu(
        menu,
        win.TPM_RETURNCMD | win.TPM_NONOTIFY | win.TPM_RIGHTBUTTON,
        point.x,
        point.y,
        0,
        app.hwnd,
        null,
    );
    switch (command) {
        refresh_menu_id => app.requestRefresh(),
        settings_menu_id => {
            showSettings(app, false);
            std.log.info("context-menu Settings handler returned; quitting={}", .{app.quitting});
        },
        quit_menu_id => {
            std.log.info("Quit selected from tray context menu", .{});
            app.quitting = true;
            app.requestShutdown();
            _ = win.DestroyWindow(app.hwnd);
            std.log.info("context-menu Quit handler returned", .{});
        },
        else => {},
    }
    std.log.debug("context menu closed; command={d} quitting={}", .{ command, app.quitting });
}

/// The config window uses SDL on the tray's main thread. Pause the worker
/// first so no other thread owns or pumps SDL while that window is active.
fn showSettings(app: *App, show_debug_logging: bool) void {
    if (app.settings_open) {
        if (show_debug_logging) config_ui.requestDebugLoggingOption();
        return;
    }
    app.settings_open = true;
    defer {
        std.log.info("settings session ended; quitting={}", .{app.quitting});
        app.settings_open = false;
        // Tray callbacks can be delivered as synchronous sent messages, which
        // are dispatched inside GetMessage rather than returned from it. The
        // WM_QUIT posted while SDL owns the queue can be consumed by SDL, so
        // issue a fresh one only after the settings backend is fully torn
        // down. This wakes the outer tray loop after this callback unwinds.
        if (app.quitting) {
            std.log.info("settings session reposting WM_QUIT for tray loop", .{});
            win.PostQuitMessage(0);
        }
    }

    std.log.info("settings session starting; stopping battery worker", .{});
    stopBatteryWorker(app);
    defer if (!app.quitting) {
        std.log.info("settings session restarting battery worker", .{});
        startBatteryWorker(app) catch |err| {
            std.log.err("could not restart battery worker: {t}", .{err});
        };
    } else {
        std.log.info("settings session leaving battery worker stopped for app shutdown", .{});
    };

    if (show_debug_logging) config_ui.requestDebugLoggingOption();
    const config = config_ui.runConfigUiWithEventPump(pumpTrayMessagesDuringSettings, @ptrCast(app)) catch |err| {
        std.log.err("settings window failed: {t}", .{err});
        return;
    } orelse return;

    if (app.quitting) {
        std.log.info("settings session cancelled by app shutdown", .{});
        return;
    }

    config_ui.saveConfig(config) catch |err| {
        std.log.err("could not save settings: {t}", .{err});
        return;
    };
    setAutostartEnabled(config.autostart_enabled) catch |err| {
        std.log.err("could not update autostart: {t}", .{err});
    };
    app.setRuntimeOptions(.{
        .interval_ms = config.interval_ms,
        .battery_wait_ms = config.battery_wait_ms,
    });
    std.log.info("settings saved in-process; restarting controller worker", .{});
}

/// The settings dialog has its own SDL event loop. Continue to dispatch
/// messages for the hidden tray window so Quit closes both UI surfaces rather
/// than waiting for the dialog to be dismissed manually.
fn pumpTrayMessagesDuringSettings(context: ?*anyopaque) bool {
    const app: *App = @ptrCast(@alignCast(context orelse return false));
    var msg: win.MSG = std.mem.zeroes(win.MSG);
    while (win.PeekMessageA(&msg, app.hwnd, 0, 0, win.PM_REMOVE) != 0) {
        std.log.debug("settings pump dispatching tray message 0x{x}", .{msg.message});
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageA(&msg);
    }
    if (app.quitting) std.log.info("settings pump returning false because app is quitting", .{});
    return !app.quitting;
}

fn parseArgs() !LaunchOptions {
    var result = LaunchOptions{};

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--autostart")) {
            result.autostart_action = .enable;
        } else if (std.mem.eql(u8, arg, "--no-autostart")) {
            result.autostart_action = .disable;
        } else if (std.mem.eql(u8, arg, "--background")) {
            result.background = true;
        } else if (std.mem.eql(u8, arg, "--replace-existing")) {
            result.replace_existing = true;
        } else if (std.mem.eql(u8, arg, "--debug-logging")) {
            result.debug_logging = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            result.show_debug_ui = true;
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}

fn resolveRuntimeOptions() !RuntimeOptions {
    const stored = try loadStoredConfig();
    return .{
        .interval_ms = stored.interval_ms,
        .battery_wait_ms = stored.battery_wait_ms,
    };
}

fn loadStoredConfig() !StoredConfig {
    var config = StoredConfig{};
    var key: windows.HKEY = undefined;
    const open_result = windows.advapi32.RegOpenKeyExW(
        windows.HKEY_CURRENT_USER,
        config_key_w,
        0,
        windows.KEY_QUERY_VALUE,
        &key,
    );
    if (open_result == error_file_not_found) return config;
    if (open_result != 0) return error.RegOpenKeyFailed;
    defer _ = windows.advapi32.RegCloseKey(key);

    config.interval_ms = readDwordValue(key, config_interval_value_name_w) catch config.interval_ms;
    config.battery_wait_ms = readDwordValue(key, config_battery_wait_value_name_w) catch config.battery_wait_ms;
    config.autostart_enabled = (readDwordValue(key, config_autostart_value_name_w) catch 0) != 0;
    return config;
}

fn saveStoredConfig(config: StoredConfig) !void {
    var key: windows.HKEY = undefined;
    const create_result = RegCreateKeyExW(
        windows.HKEY_CURRENT_USER,
        config_key_w,
        0,
        null,
        0,
        windows.KEY_SET_VALUE,
        null,
        &key,
        null,
    );
    if (create_result != 0) return error.RegCreateKeyFailed;
    defer _ = windows.advapi32.RegCloseKey(key);

    try writeDwordValue(key, config_interval_value_name_w, config.interval_ms);
    try writeDwordValue(key, config_battery_wait_value_name_w, config.battery_wait_ms);
    try writeDwordValue(key, config_autostart_value_name_w, if (config.autostart_enabled) 1 else 0);
}

fn setStoredAutostartEnabled(enabled: bool) !void {
    var config = try loadStoredConfig();
    config.autostart_enabled = enabled;
    try saveStoredConfig(config);
}

fn readDwordValue(key: windows.HKEY, name: windows.LPCWSTR) !u32 {
    var value_type: windows.DWORD = 0;
    var data: windows.DWORD = 0;
    var data_len: windows.DWORD = @sizeOf(windows.DWORD);
    const query_result = windows.advapi32.RegQueryValueExW(
        key,
        name,
        null,
        &value_type,
        @ptrCast(&data),
        &data_len,
    );
    if (query_result != 0) return error.RegQueryValueFailed;
    if (value_type != reg_dword or data_len != @sizeOf(windows.DWORD)) {
        return error.InvalidRegistryValue;
    }
    return data;
}

fn writeDwordValue(key: windows.HKEY, name: windows.LPCWSTR, value: u32) !void {
    var data: windows.DWORD = value;
    const set_result = RegSetValueExW(
        key,
        name,
        0,
        reg_dword,
        @ptrCast(&data),
        @sizeOf(windows.DWORD),
    );
    if (set_result != 0) return error.RegSetValueFailed;
}

fn launchBackgroundInstance() !void {
    var path_buf: [win.MAX_PATH:0]u16 = std.mem.zeroes([win.MAX_PATH:0]u16);
    const path_len = win.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return error.GetModuleFileNameFailed;

    const result = win.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        &path_buf,
        background_args_w,
        null,
        win.SW_HIDE,
    );
    if (@intFromPtr(result) <= 32) {
        return error.ShellExecuteFailed;
    }
}

fn getBackgroundCommand(buffer: [:0]u16) ![:0]u16 {
    var path_buf: [win.MAX_PATH:0]u16 = std.mem.zeroes([win.MAX_PATH:0]u16);
    const path_len = win.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return error.GetModuleFileNameFailed;

    const suffix = std.unicode.utf8ToUtf16LeStringLiteral(" --background");
    const total_len = 2 + path_len + (suffix.len - 1);
    if (total_len >= buffer.len) return error.BufferTooSmall;

    buffer[0] = '"';
    @memcpy(buffer[1 .. 1 + path_len], path_buf[0..path_len]);
    buffer[1 + path_len] = '"';
    @memcpy(buffer[2 + path_len .. total_len], suffix[0 .. suffix.len - 1]);
    buffer[total_len] = 0;
    return buffer[0..total_len :0];
}

fn siblingExecutablePath(buffer: [:0]u16, exe_name: []const u16) ![:0]const u16 {
    var path_buf: [win.MAX_PATH:0]u16 = std.mem.zeroes([win.MAX_PATH:0]u16);
    const path_len = win.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return error.GetModuleFileNameFailed;

    var dir_end = path_len;
    while (dir_end > 0 and path_buf[dir_end - 1] != '\\' and path_buf[dir_end - 1] != '/') : (dir_end -= 1) {}
    if (dir_end == 0) return error.GetModuleFileNameFailed;

    if (dir_end + exe_name.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..dir_end], path_buf[0..dir_end]);
    @memcpy(buffer[dir_end .. dir_end + exe_name.len], exe_name);
    buffer[dir_end + exe_name.len] = 0;
    return buffer[0 .. dir_end + exe_name.len :0];
}

fn createConfigControls(state: *ConfigWindowState, initial: *const StoredConfig) !void {
    const gui_font = win.GetStockObject(win.DEFAULT_GUI_FONT);
    var interval_buf: [16]u8 = undefined;
    var wait_buf: [16]u8 = undefined;
    const interval_text = try std.fmt.bufPrintZ(&interval_buf, "{d}", .{initial.interval_ms / 1000});
    const wait_text = try std.fmt.bufPrintZ(&wait_buf, "{d}", .{initial.battery_wait_ms / 1000});

    _ = try createSimpleChildControl(
        "STATIC",
        "Refresh interval (seconds):",
        20,
        20,
        160,
        20,
        0,
        state.hwnd,
    );

    state.interval_edit = try createChildControlEx(
        "EDIT",
        interval_text.ptr,
        190,
        18,
        120,
        24,
        win.WS_EX_CLIENTEDGE,
        state.hwnd,
        @ptrFromInt(config_interval_edit_id),
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_AUTOHSCROLL,
    );

    _ = try createSimpleChildControl(
        "STATIC",
        "Battery wait (seconds):",
        20,
        60,
        160,
        20,
        0,
        state.hwnd,
    );

    state.wait_edit = try createChildControlEx(
        "EDIT",
        wait_text.ptr,
        190,
        58,
        120,
        24,
        win.WS_EX_CLIENTEDGE,
        state.hwnd,
        @ptrFromInt(config_wait_edit_id),
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_AUTOHSCROLL,
    );

    state.autostart_check = try createChildControlEx(
        "BUTTON",
        "Launch at startup",
        20,
        98,
        180,
        24,
        0,
        state.hwnd,
        @ptrFromInt(config_autostart_check_id),
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_AUTOCHECKBOX,
    );
    _ = win.SendMessageA(state.autostart_check, win.BM_SETCHECK, if (initial.autostart_enabled) win.BST_CHECKED else win.BST_UNCHECKED, 0);

    state.ok_button = try createChildControlEx(
        "BUTTON",
        "OK",
        150,
        132,
        75,
        28,
        0,
        state.hwnd,
        @ptrFromInt(config_ok_button_id),
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_DEFPUSHBUTTON,
    );

    state.exit_button = try createChildControlEx(
        "BUTTON",
        "Exit",
        235,
        132,
        75,
        28,
        0,
        state.hwnd,
        @ptrFromInt(config_exit_button_id),
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON,
    );

    const controls = [_]win.HWND{
        state.interval_edit,
        state.wait_edit,
        state.autostart_check,
        state.ok_button,
        state.exit_button,
    };
    for (controls) |control| {
        _ = win.SendMessageA(control, win.WM_SETFONT, @as(win.WPARAM, @intCast(@intFromPtr(gui_font))), 1);
    }
}

fn createChildControlEx(
    class_name: [*:0]const u8,
    text: [*:0]const u8,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    ex_style: win.DWORD,
    parent: win.HWND,
    menu: win.HMENU,
    style: win.DWORD,
) !win.HWND {
    const control = win.CreateWindowExA(
        ex_style,
        class_name,
        text,
        style,
        x,
        y,
        width,
        height,
        parent,
        menu,
        win.GetModuleHandleA(null),
        null,
    );
    if (control == null) return error.CreateWindowFailed;
    return control;
}

fn createSimpleChildControl(
    class_name: [*:0]const u8,
    text: [*:0]const u8,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    ex_style: win.DWORD,
    parent: win.HWND,
) !win.HWND {
    return createChildControlEx(
        class_name,
        text,
        x,
        y,
        width,
        height,
        ex_style,
        parent,
        null,
        win.WS_CHILD | win.WS_VISIBLE,
    );
}

fn readEditSeconds(hwnd: win.HWND, field_name: []const u8) !u32 {
    var buffer: [32]u8 = undefined;
    const len = win.GetWindowTextA(hwnd, &buffer, buffer.len);
    if (len <= 0) {
        showConfigError("Enter a whole number of seconds.");
        return error.InvalidText;
    }

    const text = std.mem.trim(u8, buffer[0..@as(usize, @intCast(len))], " \t\r\n");
    const seconds = std.fmt.parseInt(u32, text, 10) catch {
        showConfigError("Enter a whole number of seconds.");
        return error.InvalidText;
    };
    if (seconds == 0) {
        var message_buf: [96]u8 = undefined;
        const message = std.fmt.bufPrintZ(&message_buf, "{s} must be at least 1 second.", .{field_name}) catch "Value must be at least 1 second.";
        _ = win.MessageBoxA(null, message, config_window_title, win.MB_OK | win.MB_ICONERROR);
        return error.InvalidText;
    }
    return std.math.mul(u32, seconds, 1000) catch error.InvalidInterval;
}

fn showConfigError(message: [*:0]const u8) void {
    _ = win.MessageBoxA(null, message, config_window_title, win.MB_OK | win.MB_ICONERROR);
}

fn showLaunchError(err: anyerror) void {
    var message_buf: [160]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "Could not start the tray app in the background: {s}",
        .{@errorName(err)},
    ) catch "Could not start the tray app in the background.";
    _ = win.MessageBoxA(null, message, config_window_title, win.MB_OK | win.MB_ICONERROR);
}

fn acceptConfigWindow(state: *ConfigWindowState) !void {
    const interval_ms = readEditSeconds(state.interval_edit, "Refresh interval") catch return;
    const battery_wait_ms = readEditSeconds(state.wait_edit, "Battery wait") catch return;
    const autostart_checked = win.SendMessageA(state.autostart_check, win.BM_GETCHECK, 0, 0) == win.BST_CHECKED;

    state.chosen = .{
        .interval_ms = interval_ms,
        .battery_wait_ms = battery_wait_ms,
        .autostart_enabled = autostart_checked,
    };
    _ = win.DestroyWindow(state.hwnd);
}

fn configWindowProc(
    hwnd: win.HWND,
    msg: win.UINT,
    w_param: win.WPARAM,
    l_param: win.LPARAM,
) callconv(.winapi) win.LRESULT {
    const state = global_config_window orelse return win.DefWindowProcA(hwnd, msg, w_param, l_param);

    switch (msg) {
        win.WM_CREATE => {
            const create_struct: *const win.CREATESTRUCTA = @ptrFromInt(@as(usize, @bitCast(l_param)));
            const initial: *const StoredConfig = @ptrCast(@alignCast(create_struct.lpCreateParams));
            state.hwnd = hwnd;
            createConfigControls(state, initial) catch return -1;
            return 0;
        },
        win.WM_COMMAND => {
            const command = @as(u16, @truncate(w_param));
            switch (command) {
                config_ok_button_id => {
                    acceptConfigWindow(state) catch {};
                    return 0;
                },
                config_exit_button_id => {
                    _ = win.DestroyWindow(hwnd);
                    return 0;
                },
                else => {},
            }
        },
        win.WM_CLOSE => {
            _ = win.DestroyWindow(hwnd);
            return 0;
        },
        win.WM_DESTROY => {
            win.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }

    return win.DefWindowProcA(hwnd, msg, w_param, l_param);
}

fn setAutostartEnabled(enabled: bool) !void {
    var key: windows.HKEY = undefined;
    const create_result = RegCreateKeyExW(
        windows.HKEY_CURRENT_USER,
        autostart_run_key_w,
        0,
        null,
        0,
        windows.KEY_SET_VALUE,
        null,
        &key,
        null,
    );
    if (create_result != 0) return error.RegCreateKeyFailed;
    defer _ = windows.advapi32.RegCloseKey(key);

    if (enabled) {
        var command_buf: [win.MAX_PATH + 64:0]u16 = undefined;
        const command = try getAutostartCommand(&command_buf);
        const set_result = RegSetValueExW(
            key,
            autostart_value_name_w,
            0,
            reg_sz,
            @ptrCast(command.ptr),
            @as(windows.DWORD, @intCast((command.len + 1) * @sizeOf(u16))),
        );
        if (set_result != 0) return error.RegSetValueFailed;
    } else {
        const delete_result = RegDeleteValueW(key, autostart_value_name_w);
        if (delete_result != 0 and delete_result != error_file_not_found) {
            return error.RegDeleteValueFailed;
        }
    }
}

fn isAutostartEnabled() !bool {
    var key: windows.HKEY = undefined;
    const open_result = windows.advapi32.RegOpenKeyExW(
        windows.HKEY_CURRENT_USER,
        autostart_run_key_w,
        0,
        windows.KEY_QUERY_VALUE,
        &key,
    );
    if (open_result == error_file_not_found) return false;
    if (open_result != 0) return error.RegOpenKeyFailed;
    defer _ = windows.advapi32.RegCloseKey(key);

    var value_type: windows.DWORD = 0;
    var data: [win.MAX_PATH + 32:0]u16 = undefined;
    var data_len: windows.DWORD = @sizeOf(@TypeOf(data));
    const query_result = windows.advapi32.RegQueryValueExW(
        key,
        autostart_value_name_w,
        null,
        &value_type,
        @ptrCast(&data),
        &data_len,
    );
    if (query_result == error_file_not_found) return false;
    if (query_result != 0) return error.RegQueryValueFailed;
    return value_type == reg_sz and data_len > @sizeOf(u16);
}

fn getAutostartCommand(buffer: [:0]u16) ![:0]const u16 {
    return getBackgroundCommand(buffer);
}

fn windowProc(
    hwnd: win.HWND,
    msg: win.UINT,
    w_param: win.WPARAM,
    l_param: win.LPARAM,
) callconv(.winapi) win.LRESULT {
    const app = global_app orelse return win.DefWindowProcA(hwnd, msg, w_param, l_param);

    switch (msg) {
        win.WM_TIMER => {
            if (w_param == refresh_timer_id) {
                refreshTrayIcon(app, false) catch {};
                return 0;
            }
        },
        tray_message => {
            const event = @as(win.UINT, @intCast(l_param));
            if (event == win.WM_RBUTTONUP or event == win.WM_CONTEXTMENU) {
                showContextMenu(app);
                std.log.info("tray context-menu dispatch returned; quitting={}", .{app.quitting});
                return 0;
            }
            if (event == win.WM_LBUTTONUP) {
                app.requestRefresh();
                return 0;
            }
        },
        win.WM_DESTROY => {
            std.log.info("tray window destroyed; posting quit", .{});
            app.quitting = true;
            app.requestShutdown();
            win.PostQuitMessage(0);
            return 0;
        },
        reload_settings_message => {
            std.log.info("processing settings reload request", .{});
            if (w_param != 0) {
                const options = resolveRuntimeOptions() catch |err| {
                    std.log.err("could not reload settings: {t}", .{err});
                    return 0;
                };
                app.setRuntimeOptions(options);
                std.log.info("settings reloaded: interval={d}ms battery_wait={d}ms", .{ options.interval_ms, options.battery_wait_ms });
            }
            app.requestRefresh();
            _ = win.SetForegroundWindow(hwnd);
            return 0;
        },
        debug_settings_message => {
            showSettings(app, true);
            return 0;
        },
        else => {},
    }

    return win.DefWindowProcA(hwnd, msg, w_param, l_param);
}

const window_class_name: [*:0]const u8 = "SteamControllerBatteryTrayWindow";
const window_title: [*:0]const u8 = "Steam Controller Battery Tray";
const config_window_class_name: [*:0]const u8 = "SteamControllerBatteryConfigWindow";
const config_window_title: [*:0]const u8 = "Steam Controller Battery Settings";
const background_args_w = std.unicode.utf8ToUtf16LeStringLiteral("--background");
const autostart_run_key_w = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const autostart_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("SteamControllerBatteryTray");
const config_key_w = std.unicode.utf8ToUtf16LeStringLiteral("Software\\SteamControllerBatteryTray");
const config_interval_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("IntervalMs");
const config_battery_wait_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("BatteryWaitMs");
const config_autostart_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("AutostartEnabled");
const reg_sz: windows.DWORD = 1;
const reg_dword: windows.DWORD = 4;
const error_file_not_found: windows.LSTATUS = 2;

extern "advapi32" fn RegCreateKeyExW(
    hKey: windows.HKEY,
    lpSubKey: windows.LPCWSTR,
    Reserved: windows.DWORD,
    lpClass: ?windows.LPWSTR,
    dwOptions: windows.DWORD,
    samDesired: windows.REGSAM,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *windows.HKEY,
    lpdwDisposition: ?*windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegSetValueExW(
    hKey: windows.HKEY,
    lpValueName: windows.LPCWSTR,
    Reserved: windows.DWORD,
    dwType: windows.DWORD,
    lpData: ?[*]const u8,
    cbData: windows.DWORD,
) callconv(.winapi) windows.LSTATUS;

extern "advapi32" fn RegDeleteValueW(
    hKey: windows.HKEY,
    lpValueName: windows.LPCWSTR,
) callconv(.winapi) windows.LSTATUS;
