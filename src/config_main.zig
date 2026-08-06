const std = @import("std");
const diagnostic_log = @import("logging.zig");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const windows = std.os.windows;

const app_icon = @import("app_assets").icon;

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

const tray_exe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("steam-controller-battery-tray.exe");
const autostart_run_key_w = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const autostart_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("SteamControllerBatteryTray");
const config_key_w = std.unicode.utf8ToUtf16LeStringLiteral("Software\\SteamControllerBatteryTray");
const config_interval_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("IntervalMs");
const config_battery_wait_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("BatteryWaitMs");
const config_autostart_value_name_w = std.unicode.utf8ToUtf16LeStringLiteral("AutostartEnabled");
const background_args_w = std.unicode.utf8ToUtf16LeStringLiteral("--background --replace-existing");
const background_debug_args_w = std.unicode.utf8ToUtf16LeStringLiteral("--background --replace-existing --debug-logging");
const enable_autostart_args_w = std.unicode.utf8ToUtf16LeStringLiteral("--autostart");
const disable_autostart_args_w = std.unicode.utf8ToUtf16LeStringLiteral("--no-autostart");
const reg_dword: windows.DWORD = 4;
const error_file_not_found: windows.LSTATUS = 2;

pub const StoredConfig = struct {
    interval_ms: u32 = 15_000,
    battery_wait_ms: u32 = 5_000,
    autostart_enabled: bool = false,
};

/// Lets an in-process owner service its own native messages while this SDL
/// dialog is open. Returning false closes the dialog without saving.
pub const EventPump = *const fn (context: ?*anyopaque) bool;

const UiAction = enum {
    none,
    confirm,
    exit,
};

const UiState = struct {
    interval_seconds: f32,
    battery_wait_seconds: f32,
    autostart_enabled: bool,
    show_debug_logging: bool = false,
    debug_logging_enabled: bool = false,
    action: UiAction = .none,
};

var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
var frame_counter: u32 = 0;
var debug_option_requested = std.atomic.Value(bool).init(false);
var config_event_loop_active = std.atomic.Value(bool).init(false);

pub fn requestDebugLoggingOption() void {
    debug_option_requested.store(true, .release);
    if (config_event_loop_active.load(.acquire)) {
        var event = std.mem.zeroes(SDLBackend.c.SDL_Event);
        event.type = SDLBackend.c.SDL_EVENT_USER;
        _ = SDLBackend.c.SDL_PushEvent(&event);
    }
}

pub const panic = std.debug.FullPanic(configPanic);

pub fn main() void {
    installCrashMarker();
    mainInner() catch |err| {
        std.log.err("configuration process terminated with error: {t}", .{err});
        showStartupError(err);
    };
}

fn installCrashMarker() void {
    _ = SetUnhandledExceptionFilter(unhandledException);
}

fn unhandledException(_: ?*anyopaque) callconv(.winapi) win.LONG {
    std.log.err("unhandled Windows exception; process is terminating", .{});
    return 1; // EXCEPTION_EXECUTE_HANDLER
}

fn mainInner() !void {
    if (try runConfigUi()) |config| {
        try applyConfigAndLaunch(config);
    }
}

fn configPanic(message: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    std.log.err("panic: {s}", .{message});
    std.process.abort();
}

pub fn runConfigUi() !?StoredConfig {
    return runConfigUiWithEventPump(null, null);
}

pub fn runConfigUiWithEventPump(event_pump: ?EventPump, event_pump_context: ?*anyopaque) !?StoredConfig {
    std.log.info("opening configuration window", .{});
    return realMain(event_pump, event_pump_context) catch |err| {
        std.log.err("configuration window failed: {t}", .{err});
        showStartupError(err);
        return err;
    };
}

pub fn applyConfigAndLaunch(config: StoredConfig) !void {
    std.log.info("saving settings: interval={d}ms battery_wait={d}ms autostart={}", .{ config.interval_ms, config.battery_wait_ms, config.autostart_enabled });
    try saveConfig(config);
    try setTrayAutostart(config.autostart_enabled);
    try launchTray(if (diagnostic_log.isEnabled()) background_debug_args_w else background_args_w);
}

/// Persists the settings without starting or replacing the tray process.
/// The in-process settings dialog uses this so its current tray owner remains
/// alive while the controller worker is restarted.
pub fn saveConfig(config: StoredConfig) !void {
    try saveStoredConfig(config);
}

fn realMain(event_pump: ?EventPump, event_pump_context: ?*anyopaque) !?StoredConfig {
    gpa_instance = .{};
    const gpa = gpa_instance.allocator();
    SDLBackend.enableSDLLogging();
    defer if (gpa_instance.deinit() != .ok) @panic("config window leaked memory");
    frame_counter = 0;

    var config = try loadStoredConfig();
    var state = UiState{
        .interval_seconds = @floatFromInt(config.interval_ms / 1000),
        .battery_wait_seconds = @floatFromInt(config.battery_wait_ms / 1000),
        .autostart_enabled = config.autostart_enabled,
        .debug_logging_enabled = diagnostic_log.isEnabled(),
    };

    var backend = try SDLBackend.initWindow(.{
        .allocator = gpa,
        // This is only a hidden bootstrap size.  Once DVUI has measured the
        // dialog, we set the top-level SDL window to its content size.
        .size = .{ .w = 560.0, .h = 440.0 },
        .vsync = true,
        .hidden = true,
        .title = "Steam Controller Battery Settings",
        .icon = app_icon,
    });
    defer backend.deinit();
    config_event_loop_active.store(true, .release);
    defer config_event_loop_active.store(false, .release);
    _ = SDLBackend.c.SDL_SetWindowResizable(backend.window, false);

    const win_open = true;
    var window = try dvui.Window.init(@src(), gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer window.deinit();

    var interrupted = false;
    var window_shown = false;
    var window_fitted = false;
    var fit_not_before_frame: u32 = 0;
    while (win_open) {
        if (event_pump) |pump| {
            if (!pump(event_pump_context)) return null;
        }
        if (debug_option_requested.swap(false, .acq_rel)) {
            state.show_debug_logging = true;
            window_fitted = false;
            _ = SDLBackend.c.SDL_RaiseWindow(backend.window);
            // The minimum size returned this frame was measured before the
            // newly visible debug card existed. Wait one layout frame before
            // applying the outer SDL window size.
            fit_not_before_frame = frame_counter + 2;
        }
        frame_counter += 1;
        const nstime = window.beginWait(interrupted);
        try window.begin(nstime);
        try backend.addAllEvents(&window);

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 0xF5, 0xF5, 0xF5, 0xFF);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        const measured_content_size = drawUi(&state);

        for (dvui.events()) |*event| {
            if (event.evt == .window and event.evt.window.action == .close) {
                return null;
            }
            if (event.evt == .app and event.evt.app.action == .quit) {
                return null;
            }
        }

        const end_micros = try window.end(.{});
        try backend.setCursor(window.cursorRequested());
        try backend.textInputRect(window.textInputRequested());

        // `FloatingWindowWidget.autoSize()` in DVUI does this for an embedded
        // dialog.  This app owns the OS window, so apply the root widget's
        // measured minimum size to SDL once it is available (normally frame 2).
        if (!window_fitted and frame_counter >= fit_not_before_frame) {
            if (measured_content_size) |size| {
                _ = SDLBackend.c.SDL_SetWindowSize(
                    backend.window,
                    @intFromFloat(@ceil(size.w * backend.initial_scale)),
                    @intFromFloat(@ceil(size.h * backend.initial_scale)),
                );
                window_fitted = true;
            }
        }
        if (!window_shown and window_fitted) {
            _ = SDLBackend.c.SDL_ShowWindow(backend.window);
            window_shown = true;
        }
        // If content was added dynamically, keep the previously presented
        // frame on screen until the next frame has measured and resized the
        // outer window. This makes the new card and its larger window appear
        // together rather than in two visible steps.
        if (window_fitted) try backend.renderPresent();

        switch (state.action) {
            .confirm => {
                if (state.show_debug_logging) diagnostic_log.setEnabled(state.debug_logging_enabled);
                config.interval_ms = try secondsToMillis(state.interval_seconds);
                config.battery_wait_ms = try secondsToMillis(state.battery_wait_seconds);
                config.autostart_enabled = state.autostart_enabled;
                return config;
            },
            .exit => return null,
            .none => {},
        }

        var wait_event_micros = window.waitTime(end_micros);
        // SDL waits for events on its own window. Poll briefly when embedded
        // in the tray process so a Quit command for its hidden window is
        // handled promptly as well.
        if (event_pump != null) wait_event_micros = @min(wait_event_micros, 50_000);
        interrupted = try backend.waitEventTimeout(wait_event_micros);
    }

    return null;
}

fn drawUi(state: *UiState) ?dvui.Size {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .style = .window,
        .background = true,
        .expand = .both,
        .padding = .all(18),
        .name = "settings-root",
    });
    const measured_content_size = dvui.minSizeGet(outer.data().id);
    defer outer.deinit();

    {
        var hero = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .color_fill = dvui.themeGet().color(.content, .fill_hover),
            .corner_radius = .all(14),
            .padding = .all(16),
            .expand = .horizontal,
        });
        defer hero.deinit();

        dvui.labelNoFmt(@src(), "Steam Controller Battery", .{}, .{ .font = .theme(.title) });
        dvui.labelNoFmt(@src(), "These settings are saved and reused by the tray app.", .{}, .{});
    }

    if (state.show_debug_logging) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .height(10) });
        {
            var debug_card = dvui.box(@src(), .{ .dir = .vertical }, .{ .background = true, .corner_radius = .all(14), .padding = .all(12), .expand = .horizontal });
            defer debug_card.deinit();

            var debug_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer debug_row.deinit();

            _ = dvui.checkbox(@src(), &state.debug_logging_enabled, null, .{ .gravity_y = 0.0 });
            _ = dvui.spacer(@src(), .{ .min_size_content = .width(10) });

            var text_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer text_col.deinit();

            dvui.labelNoFmt(@src(), "Enable debug logging", .{}, .{ .font = .theme(.heading) });
            dvui.labelNoFmt(@src(), "Writes a session log beside the app\n(maximum 64 MiB).", .{}, .{});
        }
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .height(12) });

    stepperRow(
        0,
        "Refresh interval",
        "How often the tray refreshes battery telemetry.",
        &state.interval_seconds,
        5,
        300,
        5,
    );

    _ = dvui.spacer(@src(), .{ .min_size_content = .height(10) });

    stepperRow(
        1,
        "Battery wait",
        "How long to wait for telemetry before showing unknown.",
        &state.battery_wait_seconds,
        1,
        20,
        1,
    );

    _ = dvui.spacer(@src(), .{ .min_size_content = .height(10) });

    {
        var autostart_card = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .corner_radius = .all(14),
            .padding = .all(12),
            .expand = .horizontal,
        });
        defer autostart_card.deinit();

        var autostart_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer autostart_row.deinit();

        _ = dvui.checkbox(@src(), &state.autostart_enabled, null, .{ .gravity_y = 0.0 });
        _ = dvui.spacer(@src(), .{ .min_size_content = .width(10) });

        var text_col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
        defer text_col.deinit();

        dvui.labelNoFmt(@src(), "Launch at startup", .{}, .{ .font = .theme(.heading) });
        dvui.labelNoFmt(@src(), "Start in the tray when you sign in to Windows.", .{}, .{});
    }

    // Follow DVUI's dialogDirect footer pattern: this is the only vertical
    // expander, so the action row remains anchored at the bottom.
    _ = dvui.spacer(@src(), .{ .min_size_content = .height(8), .expand = .vertical });

    var actions_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1.0 });
    defer actions_row.deinit();

    if (dvui.button(@src(), "Exit", .{}, .{ .min_size_content = .{ .w = 84, .h = 36 } })) {
        state.action = .exit;
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .width(10) });
    if (dvui.button(@src(), "OK", .{}, .{ .min_size_content = .{ .w = 84, .h = 36 } })) {
        state.action = .confirm;
    }

    return measured_content_size;
}

fn stepperRow(id_extra: usize, label: []const u8, description: []const u8, value: *f32, min: u32, max: u32, step: u32) void {
    var card = dvui.box(@src(), .{ .dir = .vertical }, .{
        .background = true,
        .corner_radius = .all(14),
        .padding = .all(12),
        .expand = .horizontal,
        .id_extra = id_extra,
    });
    defer card.deinit();

    dvui.labelNoFmt(@src(), label, .{}, .{ .font = .theme(.heading) });
    var description_text = dvui.textLayout(@src(), .{ .break_lines = true }, .{ .expand = .horizontal });
    description_text.addText(description, .{});
    description_text.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .height(8) });
    var slider_data: dvui.WidgetData = undefined;
    _ = digitActivatingSliderEntry(@src(), "{d:0.0} s", .{
        .value = value,
        .min = @floatFromInt(min),
        .max = @floatFromInt(max),
        .interval = @floatFromInt(step),
    }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .min_size_content = .height(36),
        .data_out = &slider_data,
    });
    dvui.dataSet(null, slider_data.id, "_slider_hover_rect", slider_data.borderRectScale().r);
    dvui.tooltip(
        @src(),
        .{ .active_rect = slider_data.borderRectScale().r, .position = .vertical },
        "Drag to adjust. Press a number to type a value, then Enter to apply.",
        .{},
        .{ .max_size_content = .width(360), .margin = .{ .y = 8, .h = 8 }, .box_shadow = .{} },
    );
}

/// Makes DVUI's slider entry behave like a conventional numeric input.
fn digitActivatingSliderEntry(
    src: std.builtin.SourceLocation,
    comptime label_fmt: ?[]const u8,
    init_opts: dvui.SliderEntryInitOptions,
    opts: dvui.Options,
) bool {
    const id = dvui.parentGet().extendId(src, opts.idExtra());
    var digit_text_mode = dvui.dataGet(null, id, "_digit_text_mode", bool) orelse false;
    var started_by_digit = false;

    if (!digit_text_mode) {
        for (dvui.events()) |*event| {
            const hovered = if (dvui.dataGet(null, id, "_slider_hover_rect", dvui.Rect.Physical)) |rect|
                rect.contains(dvui.currentWindow().mouse_pt)
            else
                false;
            if (event.handled or (event.target_widgetId != id and !hovered) or event.evt != .key) continue;

            const key = event.evt.key;
            if (key.action != .down) continue;
            const digit = digitForKey(key.code) orelse continue;

            var buffer = [_]u8{0} ** 20;
            buffer[0] = digit;
            dvui.dataSetSlice(null, id, "_digit_text_buf", &buffer);
            digit_text_mode = true;
            started_by_digit = true;
            dvui.dataSet(null, id, "_digit_text_mode", true);
            dvui.focusWidget(id, null, event.num);
            dvui.refresh(null, @src(), id);
            break;
        }
    }

    if (digit_text_mode) return digitTextEntry(src, init_opts, opts, started_by_digit);
    return dvui.sliderEntry(src, label_fmt, init_opts, opts);
}

/// A local text mode for the digit shortcut. Unlike sliderEntry's built-in
/// edit mode, this keeps the seeded digit and places the caret after it.
fn digitTextEntry(src: std.builtin.SourceLocation, init_opts: dvui.SliderEntryInitOptions, opts: dvui.Options, started_by_digit: bool) bool {
    const options = dvui.slider_entry_defaults.themeOverride(opts.theme).min_sizeM(10, 1).override(opts);
    var box = dvui.box(src, .{ .dir = .horizontal }, options);
    defer box.deinit();

    dvui.tabIndexSet(box.data().id, options.tab_index, box.data().rectScale().r);
    const rect_scale = box.data().contentRectScale();
    const buffer = dvui.dataGetSlice(null, box.data().id, "_digit_text_buf", []u8).?;
    var entry: dvui.TextEntryWidget = undefined;
    entry.init(@src(), .{ .text = .{ .buffer = buffer } }, options.strip().override(.{
        .min_size_content = .{},
        .expand = .both,
        .tab_index = 0,
    }));
    defer entry.deinit();

    if (started_by_digit) {
        var selection = entry.textLayout.selection;
        selection.start = 1;
        selection.cursor = 1;
        selection.end = 1;
    }

    var commit = false;
    var cancel = false;
    var skip_generated_text = started_by_digit;
    for (dvui.events()) |*event| {
        const matches_box = dvui.eventMatch(event, .{ .id = box.data().id, .r = rect_scale.r });
        const matches_entry = entry.matchEvent(event);
        if (!matches_box and !matches_entry) continue;

        if (skip_generated_text and event.evt == .text) {
            event.handle(@src(), box.data());
            skip_generated_text = false;
            continue;
        }
        if (event.evt == .key and event.evt.key.action == .down) {
            switch (event.evt.key.code) {
                .enter => {
                    event.handle(@src(), box.data());
                    commit = true;
                    dvui.focusWidget(null, null, event.num);
                    break;
                },
                .escape => {
                    event.handle(@src(), box.data());
                    cancel = true;
                    break;
                },
                else => {},
            }
        }
        if (event.evt == .mouse and event.evt.mouse.action == .focus) {
            event.handle(@src(), box.data());
            dvui.focusWidget(box.data().id, null, event.num);
        }
        if (!event.handled) entry.processEvent(event);
    }

    if (box.data().id != dvui.focusedWidgetId()) commit = true;
    if (box.data().id == dvui.focusedWidgetId()) {
        dvui.wantTextInput(box.data().borderRectScale().r.toNatural());
    }

    if (commit and !cancel) {
        if (std.fmt.parseFloat(f32, buffer[0..entry.len])) |parsed| {
            init_opts.value.* = std.math.clamp(parsed, init_opts.min orelse -std.math.inf(f32), init_opts.max orelse std.math.inf(f32));
        } else |_| {}
    }
    if (commit or cancel) {
        dvui.dataSet(null, box.data().id, "_digit_text_mode", false);
        dvui.refresh(null, @src(), box.data().id);
    }
    entry.draw();
    entry.drawCursor();
    return commit and !cancel;
}

fn digitForKey(key: dvui.enums.Key) ?u8 {
    return switch (key) {
        .zero, .kp_0 => '0',
        .one, .kp_1 => '1',
        .two, .kp_2 => '2',
        .three, .kp_3 => '3',
        .four, .kp_4 => '4',
        .five, .kp_5 => '5',
        .six, .kp_6 => '6',
        .seven, .kp_7 => '7',
        .eight, .kp_8 => '8',
        .nine, .kp_9 => '9',
        else => null,
    };
}

fn secondsToMillis(seconds: f32) !u32 {
    const rounded = @as(u32, @intFromFloat(@round(seconds)));
    if (rounded == 0) return error.InvalidInterval;
    return std.math.mul(u32, rounded, 1000) catch error.InvalidInterval;
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

fn setTrayAutostart(enabled: bool) !void {
    if (enabled) {
        try launchTray(enable_autostart_args_w);
    } else {
        try launchTray(disable_autostart_args_w);
    }
}

fn launchTray(args: ?windows.LPCWSTR) !void {
    var path_buf: [win.MAX_PATH:0]u16 = std.mem.zeroes([win.MAX_PATH:0]u16);
    const tray_path = try siblingExecutablePath(&path_buf, tray_exe_name_w);

    const result = win.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        tray_path.ptr,
        args,
        null,
        win.SW_HIDE,
    );
    if (@intFromPtr(result) <= 32) return error.ShellExecuteFailed;
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

fn showStartupError(err: anyerror) void {
    var message_buf: [192]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "The settings window could not start: {s}",
        .{@errorName(err)},
    ) catch "The settings window could not start.";
    _ = win.MessageBoxA(null, message, "Steam Controller Battery Settings", win.MB_OK | win.MB_ICONERROR);
}

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
