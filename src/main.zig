const std = @import("std");
const builtin = @import("builtin");
const sdl = @import("sdl3");

const Options = struct {
    watch: bool = false,
    interval_ms: u32 = 5000,
    battery_wait_ms: u32 = 3000,
    diagnostics: bool = false,
    force_hidapi_steam: bool = false,
    disable_rawinput: bool = false,
};

const BatteryInfo = struct {
    power_state: sdl.SDL_PowerState,
    battery_percent: c_int,
    wait_ms: u32,
    timed_out: bool,
};

const battery_probe_interval_ms = 25;

pub fn main() !void {
    const options = try parseArgs();

    applyHints(options);

    if (!sdl.SDL_Init(sdl.SDL_INIT_GAMEPAD)) {
        std.log.err("SDL_Init failed: {s}", .{sdl.SDL_GetError()});
        return error.SdlInitializationFailed;
    }
    defer sdl.SDL_Quit();

    if (options.diagnostics) {
        try printSdlDiagnostics();
    }

    if (options.watch) {
        try watchControllers(options);
    } else {
        // Let SDL process pending device discovery before enumerating.
        sdl.SDL_PumpEvents();
        try printControllers(options);
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

fn watchControllers(options: Options) !void {
    while (true) {
        var event: sdl.SDL_Event = undefined;

        // Pumping events allows SDL to process connection, removal, and
        // controller state updates.
        while (sdl.SDL_PollEvent(&event)) {
            switch (event.type) {
                sdl.SDL_EVENT_QUIT => return,
                else => {},
            }
        }

        const stdout = std.fs.File.stdout().deprecatedWriter();

        try stdout.writeAll("\x1b[2J\x1b[H");
        try printControllers(options);
        try stdout.print(
            "\nRefreshing every {} ms; press Ctrl-C to stop.\n",
            .{options.interval_ms},
        );

        sdl.SDL_Delay(options.interval_ms);
    }
}

fn printSdlDiagnostics() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("SDL diagnostics\n", .{});
    try stdout.print("  target os:       {s}\n", .{@tagName(builtin.os.tag)});
    try stdout.print("  SDL revision:    {s}\n", .{optionalCString(sdl.SDL_GetRevision())});
    try printHint(stdout, "hidapi", sdl.SDL_HINT_JOYSTICK_HIDAPI);
    try printHint(stdout, "hidapi steam", sdl.SDL_HINT_JOYSTICK_HIDAPI_STEAM);
    try printHint(stdout, "rawinput", sdl.SDL_HINT_JOYSTICK_RAWINPUT);
    try stdout.writeByte('\n');
}

fn printHint(writer: anytype, label: []const u8, name: [*:0]const u8) !void {
    const value = if (sdl.SDL_GetHint(name)) |hint| std.mem.span(hint) else "(unset)";
    try writer.print("  hint {s}:  {s}\n", .{ label, value });
}

fn printControllers(options: Options) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    var count: c_int = 0;
    const ids = sdl.SDL_GetGamepads(&count);

    if (ids == null) {
        std.log.err("SDL_GetGamepads failed: {s}", .{sdl.SDL_GetError()});
        return error.GamepadEnumerationFailed;
    }
    defer sdl.SDL_free(ids);

    if (count == 0) {
        try stdout.writeAll("No SDL gamepads detected.\n");
        return;
    }

    try stdout.print("SDL gamepads detected: {}\n\n", .{count});

    var index: usize = 0;
    while (index < @as(usize, @intCast(count))) : (index += 1) {
        const id = ids[index];

        const gamepad = sdl.SDL_OpenGamepad(id) orelse {
            try stdout.print(
                "[{}] Could not open gamepad ID {}: {s}\n",
                .{ index, id, sdl.SDL_GetError() },
            );
            continue;
        };
        defer sdl.SDL_CloseGamepad(gamepad);

        try printGamepad(stdout, options, index, id, gamepad);
    }
}

fn printGamepad(
    writer: anytype,
    options: Options,
    index: usize,
    id: sdl.SDL_JoystickID,
    gamepad: *sdl.SDL_Gamepad,
) !void {
    const name = optionalCString(sdl.SDL_GetGamepadName(gamepad));
    const path = optionalCString(sdl.SDL_GetGamepadPath(gamepad));

    const vendor = sdl.SDL_GetGamepadVendor(gamepad);
    const product = sdl.SDL_GetGamepadProduct(gamepad);
    const firmware = sdl.SDL_GetGamepadFirmwareVersion(gamepad);
    const steam_handle = sdl.SDL_GetGamepadSteamHandle(gamepad);
    const connection = sdl.SDL_GetGamepadConnectionState(gamepad);

    const battery = queryBatteryInfo(gamepad, options.battery_wait_ms);

    const virtual_steam_gamepad =
        vendor == 0x28de and product == 0x11ff;
    const physical_steam_controller =
        vendor == 0x28de and product == 0x1304;

    try writer.print("[{}] {s}\n", .{ index, name });
    try writer.print("  SDL instance ID: {}\n", .{id});
    try writer.print("  path:            {s}\n", .{path});
    try writer.print(
        "  USB ID:          {x:0>4}:{x:0>4}\n",
        .{ vendor, product },
    );
    try writer.print("  firmware:        {}\n", .{firmware});
    try writer.print("  connection:      {s}\n", .{
        connectionStateName(connection),
    });
    try writer.print("  power state:     {s}\n", .{
        powerStateName(battery.power_state),
    });

    if (battery.battery_percent >= 0) {
        try writer.print("  battery:         {}%\n", .{battery.battery_percent});
    } else {
        try writer.writeAll("  battery:         unknown\n");
    }
    try writer.print("  battery wait:    {} ms\n", .{battery.wait_ms});

    if (steam_handle != 0) {
        try writer.print(
            "  Steam handle:    0x{x}\n",
            .{steam_handle},
        );
    } else {
        try writer.writeAll("  Steam handle:    unavailable\n");
    }

    try writer.print(
        "  touchpads:       {}\n",
        .{sdl.SDL_GetNumGamepadTouchpads(gamepad)},
    );

    if (options.diagnostics) {
        try writer.writeAll("  diagnostics:     ");

        if (options.force_hidapi_steam) {
            try writer.writeAll("force-hidapi-steam ");
        }

        if (options.disable_rawinput) {
            try writer.writeAll("disable-rawinput ");
        }

        if (!options.force_hidapi_steam and !options.disable_rawinput) {
            try writer.writeAll("default-backend-selection");
        }

        try writer.writeByte('\n');
    }

    if (virtual_steam_gamepad) {
        try writer.writeAll(
            "  note:            Steam Virtual Gamepad; physical battery " ++
                "telemetry may not be exposed\n",
        );
    }

    if (physical_steam_controller and
        battery.power_state == sdl.SDL_POWERSTATE_UNKNOWN and
        battery.battery_percent < 0)
    {
        try writer.writeAll(
            "  note:            SDL opened this Steam Controller through HIDAPI " ++
                "Steam, but no battery telemetry arrived before the probe timeout\n",
        );
    }

    try writer.writeByte('\n');
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

fn optionalCString(value: ?[*:0] const u8) []const u8 {
    return if (value) |ptr| std.mem.span(ptr) else "(unavailable)";
}

fn powerStateName(state: sdl.SDL_PowerState) []const u8 {
    return switch (state) {
        sdl.SDL_POWERSTATE_ERROR => "error",
        sdl.SDL_POWERSTATE_UNKNOWN => "unknown",
        sdl.SDL_POWERSTATE_ON_BATTERY => "on battery",
        sdl.SDL_POWERSTATE_NO_BATTERY => "no battery",
        sdl.SDL_POWERSTATE_CHARGING => "charging",
        sdl.SDL_POWERSTATE_CHARGED => "charged",
        else => "unrecognized",
    };
}

fn connectionStateName(
    state: sdl.SDL_JoystickConnectionState,
) []const u8 {
    return switch (state) {
        sdl.SDL_JOYSTICK_CONNECTION_INVALID => "invalid",
        sdl.SDL_JOYSTICK_CONNECTION_UNKNOWN => "unknown",
        sdl.SDL_JOYSTICK_CONNECTION_WIRED => "wired",
        sdl.SDL_JOYSTICK_CONNECTION_WIRELESS => "wireless",
        else => "unrecognized",
    };
}

fn parseArgs() !Options {
    var result = Options{};

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--watch")) {
            result.watch = true;
        } else if (std.mem.eql(u8, arg, "--diagnostics")) {
            result.diagnostics = true;
        } else if (std.mem.eql(u8, arg, "--force-hidapi-steam")) {
            result.force_hidapi_steam = true;
        } else if (std.mem.eql(u8, arg, "--disable-rawinput")) {
            result.disable_rawinput = true;
        } else if (std.mem.eql(u8, arg, "--battery-wait-ms")) {
            const value = args.next() orelse {
                printUsage();
                return error.MissingBatteryWait;
            };

            result.battery_wait_ms = std.fmt.parseInt(u32, value, 10) catch {
                printUsage();
                return error.InvalidBatteryWait;
            };
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const value = args.next() orelse {
                printUsage();
                return error.MissingInterval;
            };

            result.interval_ms = std.fmt.parseInt(u32, value, 10) catch {
                printUsage();
                return error.InvalidInterval;
            };

            if (result.interval_ms == 0) {
                return error.InvalidInterval;
            }
        } else if (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h"))
        {
            printUsage();
            std.process.exit(0);
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    return result;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  steam-controller-battery
        \\  steam-controller-battery --diagnostics
        \\  steam-controller-battery --diagnostics --force-hidapi-steam
        \\  steam-controller-battery --diagnostics --force-hidapi-steam --disable-rawinput
        \\  steam-controller-battery --diagnostics --battery-wait-ms 5000
        \\  steam-controller-battery --watch
        \\  steam-controller-battery --watch --interval MILLISECONDS
        \\
        \\Options:
        \\  --diagnostics         Print SDL revision and relevant backend hints
        \\  --force-hidapi-steam  Set SDL_JOYSTICK_HIDAPI=1 and SDL_JOYSTICK_HIDAPI_STEAM=1 before SDL_Init
        \\  --disable-rawinput    Set SDL_JOYSTICK_RAWINPUT=0 before SDL_Init
        \\  --battery-wait-ms     Wait this long for battery telemetry before printing, default 3000
        \\
    , .{});
}
