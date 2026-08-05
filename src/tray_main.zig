const std = @import("std");
const sdl = @import("sdl3");
const windows = std.os.windows;

const win = @cImport({
    @cInclude("windows.h");
    @cInclude("shellapi.h");
});

const tray_message = win.WM_APP + 1;
const refresh_timer_id: usize = 1;
const refresh_menu_id: usize = 1000;
const autostart_menu_id: usize = 1002;
const quit_menu_id: usize = 1001;
const icon_size = 32;
const tooltip_capacity = 127;
const battery_probe_interval_ms = 25;
const steam_controller_vendor_id: u16 = 0x28de;
const steam_controller_product_id: u16 = 0x1304;

const Options = struct {
    interval_ms: u32 = 60_000,
    battery_wait_ms: u32 = 10_000,
    force_hidapi_steam: bool = false,
    disable_rawinput: bool = false,
    autostart_action: enum {
        none,
        enable,
        disable,
    } = .none,
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
    options: Options,
    worker: ?std.Thread = null,
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

    fn takeRefreshRequest(self: *App) bool {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        const requested = self.shared.refresh_requested;
        self.shared.refresh_requested = false;
        return requested;
    }
};

var global_app: ?*App = null;

pub fn main() !void {
    const options = try parseArgs();

    switch (options.autostart_action) {
        .enable => {
            try setAutostartEnabled(true);
            return;
        },
        .disable => {
            try setAutostartEnabled(false);
            return;
        },
        .none => {},
    }

    var app = App{
        .options = options,
    };
    global_app = &app;
    defer global_app = null;

    try runApp(&app);
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
    defer removeTrayIcon(app);

    app.worker = try std.Thread.spawn(.{}, batteryWorkerMain, .{app});
    defer if (app.worker) |worker| worker.join();

    _ = win.SetTimer(app.hwnd, refresh_timer_id, 250, null);
    defer _ = win.KillTimer(app.hwnd, refresh_timer_id);

    try refreshTrayIcon(app, true);

    var msg: win.MSG = std.mem.zeroes(win.MSG);
    while (win.GetMessageA(&msg, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&msg);
        _ = win.DispatchMessageA(&msg);
    }
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
    applyHints(app.options);

    if (!sdl.SDL_Init(sdl.SDL_INIT_GAMEPAD)) {
        updateSnapshot(app, .{});
        return;
    }
    defer sdl.SDL_Quit();

    while (!app.isShutdown()) {
        const snapshot = collectSnapshot(app.options);
        updateSnapshot(app, snapshot);

        var slept_ms: u32 = 0;
        while (slept_ms < app.options.interval_ms and !app.isShutdown()) {
            if (app.takeRefreshRequest()) break;
            const chunk = @min(app.options.interval_ms - slept_ms, 250);
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

fn collectSnapshot(options: Options) Snapshot {
    sdl.SDL_PumpEvents();

    var count: c_int = 0;
    const ids = sdl.SDL_GetGamepads(&count);
    if (ids == null) {
        return .{};
    }
    defer sdl.SDL_free(ids);

    if (count == 0) {
        return .{};
    }

    const id = findSteamControllerId(ids[0..@as(usize, @intCast(count))]) orelse return .{};

    const gamepad = sdl.SDL_OpenGamepad(id) orelse return .{
        .connected = true,
    };
    defer sdl.SDL_CloseGamepad(gamepad);

    const battery = queryBatteryInfo(gamepad, options.battery_wait_ms);

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
    gamepad: *sdl.SDL_Gamepad,
    battery_wait_ms: u32,
) BatteryInfo {
    var elapsed_ms: u32 = 0;

    while (true) {
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

fn applyHints(options: Options) void {
    if (options.force_hidapi_steam) {
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_JOYSTICK_HIDAPI, "1");
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_JOYSTICK_HIDAPI_STEAM, "1");
    }

    if (options.disable_rawinput) {
        _ = sdl.SDL_SetHint(sdl.SDL_HINT_JOYSTICK_RAWINPUT, "0");
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

    const autostart_enabled = isAutostartEnabled() catch false;
    _ = win.AppendMenuA(menu, win.MF_STRING, refresh_menu_id, "Refresh");
    _ = win.AppendMenuA(
        menu,
        @as(win.UINT, @intCast(win.MF_STRING | (if (autostart_enabled) win.MF_CHECKED else 0))),
        autostart_menu_id,
        "Launch at startup",
    );
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
        autostart_menu_id => {
            setAutostartEnabled(!autostart_enabled) catch {};
        },
        quit_menu_id => {
            app.requestShutdown();
            _ = win.DestroyWindow(app.hwnd);
        },
        else => {},
    }
}

fn parseArgs() !Options {
    var result = Options{};

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force-hidapi-steam")) {
            result.force_hidapi_steam = true;
        } else if (std.mem.eql(u8, arg, "--disable-rawinput")) {
            result.disable_rawinput = true;
        } else if (std.mem.eql(u8, arg, "--enable-autostart")) {
            result.autostart_action = .enable;
        } else if (std.mem.eql(u8, arg, "--disable-autostart")) {
            result.autostart_action = .disable;
        } else if (std.mem.eql(u8, arg, "--battery-wait-ms")) {
            const value = args.next() orelse return error.MissingBatteryWait;
            result.battery_wait_ms = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const value = args.next() orelse return error.MissingInterval;
            result.interval_ms = try std.fmt.parseInt(u32, value, 10);
            if (result.interval_ms == 0) return error.InvalidInterval;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  steam-controller-battery-tray
        \\  steam-controller-battery-tray --interval MILLISECONDS
        \\  steam-controller-battery-tray --battery-wait-ms MILLISECONDS
        \\  steam-controller-battery-tray --force-hidapi-steam
        \\  steam-controller-battery-tray --disable-rawinput
        \\  steam-controller-battery-tray --enable-autostart
        \\  steam-controller-battery-tray --disable-autostart
        \\
    , .{});
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
        var command_buf: [win.MAX_PATH + 32:0]u16 = undefined;
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
    var path_buf: [win.MAX_PATH:0]u16 = std.mem.zeroes([win.MAX_PATH:0]u16);
    const path_len = win.GetModuleFileNameW(null, &path_buf, path_buf.len);
    if (path_len == 0 or path_len >= path_buf.len) return error.GetModuleFileNameFailed;

    if (path_len + 3 > buffer.len) return error.BufferTooSmall;
    buffer[0] = '"';
    @memcpy(buffer[1 .. 1 + path_len], path_buf[0..path_len]);
    buffer[1 + path_len] = '"';
    buffer[2 + path_len] = 0;
    return buffer[0 .. 2 + path_len :0];
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
                return 0;
            }
            if (event == win.WM_LBUTTONUP) {
                app.requestRefresh();
                return 0;
            }
        },
        win.WM_DESTROY => {
            app.requestShutdown();
            win.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }

    return win.DefWindowProcA(hwnd, msg, w_param, l_param);
}

const window_class_name: [*:0]const u8 = "SteamControllerBatteryTrayWindow";
const window_title: [*:0]const u8 = "Steam Controller Battery Tray";
const autostart_run_key_w = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const autostart_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("SteamControllerBatteryTray");
const reg_sz: windows.DWORD = 1;
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
