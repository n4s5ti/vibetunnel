const std = @import("std");
const posix = std.posix;

const asciinema_mod = @import("asciinema.zig");
const control_socket = @import("control_socket.zig");
const git_mod = @import("git.zig");
const logger_mod = @import("logger.zig");
const pty_mod = @import("pty.zig");
const session_mod = @import("session.zig");
const title_mod = @import("title.zig");
const title_filter_mod = @import("title_filter.zig");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

const TitleMode = enum {
    none,
    filter,
    static,
};

const Options = struct {
    session_id: ?[]const u8 = null,
    title_mode: TitleMode = .none,
    update_title: ?[]const u8 = null,
    verbosity: logger_mod.Level = logger_mod.Level.@"error",
    log_file: ?[]const u8 = null,
};

const ParsedArgs = struct {
    options: Options,
    command: []const []const u8,
};

const SessionContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: *logger_mod.Logger,
    running: *std.atomic.Value(bool),
    pty: *pty_mod.Pty,
    pty_mutex: std.Io.Mutex = .init,
    stdout_mutex: std.Io.Mutex = .init,
    session_mutex: std.Io.Mutex = .init,
    asciinema: *asciinema_mod.AsciinemaWriter,
    title_mode: TitleMode,
    title_filter: title_filter_mod.TitleFilter = .{},
    session_id: []const u8,
    session_dir: []const u8,
    session_json_path: []const u8,
    ipc_path: []const u8,
    cwd: []const u8,
    command: []const []const u8,
    home: []const u8,
    session_name: []const u8,
    last_cols: u16,
    last_rows: u16,
};

const RawMode = struct {
    fd: posix.fd_t,
    orig: c.termios,

    fn enable(fd: posix.fd_t) !RawMode {
        var term: c.termios = undefined;
        if (c.tcgetattr(fd, &term) != 0) return error.TermiosFailed;
        var raw = term;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(fd, c.TCSANOW, &raw) != 0) return error.TermiosFailed;
        return .{ .fd = fd, .orig = term };
    }

    fn restore(self: *RawMode) void {
        _ = c.tcsetattr(self.fd, c.TCSANOW, &self.orig);
    }
};

const EnvDefaults = struct {
    title_mode: ?TitleMode = null,
    verbosity: ?logger_mod.Level = null,

    fn load(self: *EnvDefaults) void {
        if (getenv("VIBETUNNEL_TITLE_MODE")) |val| {
            if (parseTitleMode(val)) |mode| {
                self.title_mode = mode;
            }
        }
        if (getenv("VIBETUNNEL_LOG_LEVEL")) |val| {
            if (logger_mod.parseLevel(val)) |level| {
                self.verbosity = level;
            }
        }
        if (getenv("VIBETUNNEL_DEBUG")) |val| {
            if (isTruthy(val)) {
                self.verbosity = .debug;
            }
        }
    }
};

const SizeInfo = struct {
    cols: u16,
    rows: u16,
    has_size: bool,
};

const ExecEnv = struct {
    arena: std.heap.ArenaAllocator,
    executable: [*:0]const u8,
    argv: [:null]?[*:0]const u8,
    envp: [:null]const ?[*:0]const u8,

    fn deinit(self: *ExecEnv) void {
        self.arena.deinit();
    }
};

const ExitInfo = struct {
    exit_code: i32,
    signal: ?u8,
};

var g_running = std.atomic.Value(bool).init(true);
var g_signal = std.atomic.Value(i32).init(0);
var g_child_pid = std.atomic.Value(i32).init(-1);

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    g_running.store(false, .release);
    g_signal.store(@intCast(@intFromEnum(sig)), .release);
}

pub fn main(init: std.process.Init) !void {
    markForwarderStarted(init.io);

    const allocator = init.gpa;
    const args = init.minimal.args.vector;
    var args_plain = try allocator.alloc([]const u8, args.len);
    defer allocator.free(args_plain);
    for (args, 0..) |arg, idx| {
        args_plain[idx] = std.mem.sliceTo(arg, 0);
    }

    var defaults = EnvDefaults{};
    defaults.load();

    const parsed = try parseArgs(init.io, args_plain[1..], defaults);
    const options = parsed.options;
    const command = parsed.command;

    if (args_plain.len <= 1 or (command.len == 0 and options.update_title == null)) {
        showUsage(init.io);
        return;
    }

    const home = getHome();
    const log_path = options.log_file orelse defaultLogPath(allocator, home) catch null;
    var logger = logger_mod.Logger.init(init.io, options.verbosity, log_path);
    defer logger.deinit();

    if (options.update_title) |title| {
        if (options.session_id == null) {
            logger.logError("--update-title requires --session-id", .{});
            return error.InvalidArguments;
        }
        const session_id = options.session_id.?;
        if (!isValidSessionId(session_id)) {
            logger.logError("invalid session id: {s}", .{session_id});
            return error.InvalidArguments;
        }
        const control_path = try controlPath(allocator, home);
        const session_json_path = try std.fs.path.join(allocator, &.{ control_path, session_id, "session.json" });
        defer allocator.free(control_path);
        defer allocator.free(session_json_path);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sanitized = try title_mod.sanitizeTitle(arena.allocator(), title);
        session_mod.updateSessionName(init.io, arena.allocator(), session_json_path, sanitized) catch |err| {
            logger.logError("failed to update session title: {s}", .{@errorName(err)});
            return err;
        };
        return;
    }

    if (command.len == 0) {
        logger.logError("no command specified", .{});
        showUsage(init.io);
        return error.InvalidArguments;
    }

    const title_mode = options.title_mode;

    const cwd = try std.process.currentPathAlloc(init.io, allocator);

    const control_path = try controlPath(allocator, home);
    const session_id = options.session_id orelse try generateSessionId(init.io, allocator);
    if (!isValidSessionId(session_id)) {
        logger.logError("invalid session id: {s}", .{session_id});
        return error.InvalidArguments;
    }

    const session_dir = try std.fs.path.join(allocator, &.{ control_path, session_id });
    try std.Io.Dir.cwd().createDirPath(init.io, session_dir);
    try std.Io.Dir.cwd().setFilePermissions(
        init.io,
        session_dir,
        @enumFromInt(0o700),
        .{},
    );

    const session_json_path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    const stdout_path = try std.fs.path.join(allocator, &.{ session_dir, "stdout" });
    const stdin_path = try std.fs.path.join(allocator, &.{ session_dir, "stdin" });
    const ipc_path = try std.fs.path.join(allocator, &.{ session_dir, "ipc.sock" });

    try ensureStdinPipe(init.io, stdin_path);

    const dims = try determineInitialSize(init.io);
    const initial_cols = dims.cols;
    const initial_rows = dims.rows;

    const session_name = try title_mod.generateSessionName(allocator, command, cwd, home);
    const started_at = try isoTimestamp(init.io, allocator);
    var git_info = git_mod.detectGitInfo(init.io, allocator, init.environ_map, cwd);
    defer git_info.deinit();

    var session_info = session_mod.SessionInfo{
        .id = session_id,
        .name = session_name,
        .command = command,
        .workingDir = cwd,
        .status = "starting",
        .startedAt = started_at,
        .pid = null,
        .initialCols = if (dims.has_size) initial_cols else null,
        .initialRows = if (dims.has_size) initial_rows else null,
        .lastClearOffset = 0,
        .version = build_options.version,
        .gitRepoPath = git_info.gitRepoPath,
        .gitBranch = git_info.gitBranch,
        .gitAheadCount = git_info.gitAheadCount,
        .gitBehindCount = git_info.gitBehindCount,
        .gitHasChanges = git_info.gitHasChanges,
        .gitIsWorktree = git_info.gitIsWorktree,
        .gitMainRepoPath = git_info.gitMainRepoPath,
        .attachedViaVT = if (getenv("VIBETUNNEL_SESSION_ID") != null) true else null,
    };

    try session_mod.writeSessionInfo(init.io, session_json_path, session_info);

    const command_string = try joinCommand(allocator, command);
    defer allocator.free(command_string);

    var asciinema_writer = try asciinema_mod.AsciinemaWriter.init(
        init.io,
        allocator,
        stdout_path,
        initial_cols,
        initial_rows,
        command_string,
        session_name,
    );
    errdefer asciinema_writer.deinit();

    const winsize = pty_mod.winsize{ .ws_col = initial_cols, .ws_row = initial_rows, .ws_xpixel = 0, .ws_ypixel = 0 };
    var pty = try pty_mod.Pty.open(winsize);
    errdefer pty.deinit();

    var exec_env = try buildExecEnv(allocator, init.environ_map, command, session_id);
    const cwd_z = try allocator.dupeZ(u8, cwd);
    defer allocator.free(cwd_z);
    const pid = c.fork();
    if (pid < 0) {
        logger.logError("failed to fork", .{});
        exec_env.deinit();
        return error.ForkFailed;
    }

    if (pid == 0) {
        if (c.close(pty.master) != 0 or
            c.setsid() < 0 or
            c.ioctl(pty.slave, pty_mod.TIOCSCTTY, @as(c_ulong, 0)) < 0 or
            c.dup2(pty.slave, 0) < 0 or
            c.dup2(pty.slave, 1) < 0 or
            c.dup2(pty.slave, 2) < 0 or
            c.close(pty.slave) != 0 or
            c.chdir(cwd_z.ptr) != 0)
        {
            c._exit(126);
        }

        _ = c.execve(
            exec_env.executable,
            @ptrCast(@constCast(exec_env.argv.ptr)),
            @ptrCast(@constCast(exec_env.envp.ptr)),
        );
        c._exit(127);
    }

    exec_env.deinit();

    _ = c.close(pty.slave);
    pty.slave = -1;
    var child_active = true;
    errdefer if (child_active) {
        terminateChild(pid);
        _ = waitForChild(pid) catch {};
    };

    g_running.store(true, .release);
    g_signal.store(0, .release);
    g_child_pid.store(@intCast(pid), .release);

    installSignalHandlers();

    session_info.pid = @intCast(pid);
    session_info.status = "running";
    try session_mod.writeSessionInfo(init.io, session_json_path, session_info);

    var ctx = SessionContext{
        .allocator = allocator,
        .io = init.io,
        .logger = &logger,
        .running = &g_running,
        .pty = &pty,
        .asciinema = &asciinema_writer,
        .title_mode = title_mode,
        .session_id = session_id,
        .session_dir = session_dir,
        .session_json_path = session_json_path,
        .ipc_path = ipc_path,
        .cwd = cwd,
        .command = command,
        .home = home,
        .session_name = session_name,
        .last_cols = initial_cols,
        .last_rows = initial_rows,
    };

    if (title_mode == .static) {
        updateLocalTitle(&ctx, session_name) catch {};
    }

    var control_server = try control_socket.Server.init(ctx.io, ctx.allocator, ctx.ipc_path, .{
        .context = &ctx,
        .logger = &logger,
        .on_stdin = handleSocketStdin,
        .on_resize = handleSocketResize,
        .on_reset_size = handleSocketResetSize,
        .on_kill = handleSocketKill,
        .on_update_title = handleSocketUpdateTitle,
    }, &g_running);
    const control_thread = std.Thread.spawn(.{}, control_socket.Server.run, .{&control_server}) catch |err| {
        g_running.store(false, .release);
        control_server.stop();
        return err;
    };
    const session_thread = std.Thread.spawn(.{}, sessionWatcherThread, .{&ctx}) catch |err| {
        g_running.store(false, .release);
        control_server.stop();
        control_thread.join();
        return err;
    };
    const resize_thread = std.Thread.spawn(.{}, resizeWatcherThread, .{&ctx}) catch |err| {
        g_running.store(false, .release);
        control_server.stop();
        control_thread.join();
        session_thread.join();
        return err;
    };

    var raw_mode: ?RawMode = null;
    const stdin_fd = std.Io.File.stdin().handle;
    if (c.isatty(stdin_fd) == 1) {
        raw_mode = RawMode.enable(stdin_fd) catch null;
    }

    var main_loop_failed = false;
    mainLoop(&ctx, stdin_fd) catch |err| {
        main_loop_failed = true;
        logger.logError("main loop error: {s}", .{@errorName(err)});
    };

    g_running.store(false, .release);
    if (raw_mode) |*mode| mode.restore();
    control_server.stop();
    control_thread.join();
    session_thread.join();
    resize_thread.join();

    const signaled = g_signal.load(.acquire);
    if (signaled != 0) {
        _ = c.kill(-pid, signaled);
    } else if (main_loop_failed) {
        terminateChild(pid);
    }

    const exit_info = waitForChild(pid) catch |err| blk: {
        logger.logError("waitpid failed: {s}", .{@errorName(err)});
        break :blk ExitInfo{ .exit_code = 1, .signal = null };
    };
    child_active = false;

    asciinema_writer.writeExit(exit_info.exit_code, session_id) catch {};

    session_info.name = ctx.session_name;
    session_info.status = "exited";
    session_info.exitCode = exit_info.exit_code;
    session_mod.writeSessionInfo(init.io, session_json_path, session_info) catch {};

    pty.deinit();
    asciinema_writer.deinit();
    allocator.free(ctx.session_name);

    std.process.exit(@intCast(exit_info.exit_code));
}

fn markForwarderStarted(io: std.Io) void {
    const marker_path = getenv("VIBETUNNEL_FWD_STARTED_FILE") orelse return;
    const permissions: std.Io.File.Permissions = @enumFromInt(0o600);
    const file = std.Io.Dir.cwd().createFile(io, marker_path, .{
        .exclusive = true,
        .permissions = permissions,
    }) catch return;
    file.close(io);
}

fn parseArgs(io: std.Io, args: []const []const u8, defaults: EnvDefaults) !ParsedArgs {
    var options = Options{};
    if (defaults.title_mode) |mode| options.title_mode = mode;
    if (defaults.verbosity) |level| options.verbosity = level;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            showUsage(io);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--session-id")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            options.session_id = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--title-mode")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            const mode = parseTitleMode(args[i + 1]) orelse return error.InvalidArguments;
            options.title_mode = mode;
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--update-title")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            options.update_title = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbosity")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            const level = logger_mod.parseLevel(args[i + 1]) orelse return error.InvalidArguments;
            options.verbosity = level;
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "--log-file")) {
            if (i + 1 >= args.len) return error.InvalidArguments;
            options.log_file = args[i + 1];
            i += 2;
            continue;
        }
        if (std.mem.eql(u8, arg, "-q")) {
            options.verbosity = .silent;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-v")) {
            options.verbosity = .info;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-vv")) {
            options.verbosity = .verbose;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "-vvv")) {
            options.verbosity = .debug;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidArguments;
        }
        break;
    }

    var command = args[i..];
    if (command.len > 0 and std.mem.eql(u8, command[0], "--")) {
        command = command[1..];
    }

    return .{ .options = options, .command = command };
}

fn showUsage(io: std.Io) void {
    const usage =
        \\VibeTunnel Forward (vibetunnel-fwd)
        \\
        \\Usage:
        \\  vibetunnel-fwd [--session-id <id>] [--title-mode <mode>] [--verbosity <level>] <command> [args...]
        \\
        \\Options:
        \\  --session-id <id>       Use a pre-generated session ID
        \\  --title-mode <mode>     none, filter, static
        \\  --update-title <title>  Update session title and exit (requires --session-id)
        \\  --verbosity <level>     silent, error, warn, info, verbose, debug
        \\  --log-file <path>       Override default log file path
        \\  -q/-v/-vv/-vvv          Quick verbosity
        \\
    ;
    std.Io.File.stdout().writeStreamingAll(io, usage) catch {};
}

fn parseTitleMode(value: []const u8) ?TitleMode {
    if (std.ascii.eqlIgnoreCase(value, "none")) return .none;
    if (std.ascii.eqlIgnoreCase(value, "filter")) return .filter;
    if (std.ascii.eqlIgnoreCase(value, "static")) return .static;
    return null;
}

fn isTruthy(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

fn getHome() []const u8 {
    if (getenv("HOME")) |val| return val;
    return "";
}

fn defaultLogPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    if (home.len == 0) return allocator.dupe(u8, "./.vibetunnel/log.txt");
    return std.fs.path.join(allocator, &.{ home, ".vibetunnel", "log.txt" });
}

fn controlPath(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    if (getenv("VIBETUNNEL_CONTROL_DIR")) |val| {
        return allocator.dupe(u8, val);
    }
    if (home.len == 0) return allocator.dupe(u8, "./.vibetunnel/control");
    return std.fs.path.join(allocator, &.{ home, ".vibetunnel", "control" });
}

fn generateSessionId(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.Io.Clock.real.now(io).toMilliseconds();
    return std.fmt.allocPrint(allocator, "fwd_{d}_{d}", .{ ts, c.getpid() });
}

fn isValidSessionId(session_id: []const u8) bool {
    if (session_id.len == 0 or session_id.len > 64) return false;
    for (session_id) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    }
    return true;
}

fn determineInitialSize(io: std.Io) !SizeInfo {
    const stdout_fd = std.Io.File.stdout().handle;
    const is_external = getenv("VIBETUNNEL_SESSION_ID") != null;

    if (is_external) {
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        if (c.isatty(stdout_fd) == 1) {
            const ws = pty_mod.getWinsizeFromFd(stdout_fd) catch return .{ .cols = 80, .rows = 24, .has_size = false };
            return .{ .cols = ws.ws_col, .rows = ws.ws_row, .has_size = true };
        }
        return .{ .cols = 80, .rows = 24, .has_size = false };
    }

    if (c.isatty(stdout_fd) == 1) {
        const ws = pty_mod.getWinsizeFromFd(stdout_fd) catch return .{ .cols = 120, .rows = 40, .has_size = true };
        return .{ .cols = ws.ws_col, .rows = ws.ws_row, .has_size = true };
    }

    return .{ .cols = 120, .rows = 40, .has_size = true };
}

fn ensureStdinPipe(io: std.Io, path: []const u8) !void {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind != .named_pipe) return error.InvalidStdinPipe;
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const path_z = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(path_z);
    if (c.mkfifo(path_z.ptr, 0o600) != 0) return error.MkfifoFailed;
}

fn isoTimestamp(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    const secs_signed = @divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s);
    if (secs_signed < 0) return allocator.dupe(u8, "1970-01-01T00:00:00Z");
    const secs: u64 = @intCast(secs_signed);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

fn joinCommand(allocator: std.mem.Allocator, command: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", command);
}

fn buildExecEnv(
    allocator: std.mem.Allocator,
    parent_env: *const std.process.Environ.Map,
    command: []const []const u8,
    session_id: []const u8,
) !ExecEnv {
    if (command.len == 0) return error.InvalidArguments;
    var env_map = try parent_env.clone(allocator);
    defer env_map.deinit();
    _ = env_map.swapRemove("VIBETUNNEL_FWD_STARTED_FILE");
    env_map.put("TERM", "xterm-256color") catch {};
    env_map.put("VIBETUNNEL_SESSION_ID", session_id) catch {};

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    const envp = (try env_map.createPosixBlock(arena_alloc, .{})).slice;
    const argv = try buildArgvZ(arena_alloc, command);
    const executable = try resolveExecutable(arena_alloc, &env_map, command[0]);

    return .{ .arena = arena, .executable = executable, .argv = argv, .envp = envp };
}

fn buildArgvZ(allocator: std.mem.Allocator, command: []const []const u8) ![:null]?[*:0]const u8 {
    var argv = try allocator.alloc(?[*:0]const u8, command.len + 1);
    for (command, 0..) |arg, idx| {
        argv[idx] = try allocator.dupeZ(u8, arg);
    }
    argv[command.len] = null;
    return argv[0..command.len :null];
}

fn resolveExecutable(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    executable: []const u8,
) ![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, executable, '/') != null) {
        return (try allocator.dupeZ(u8, executable)).ptr;
    }

    const path_value = env_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    var paths = std.mem.splitScalar(u8, path_value, ':');
    while (paths.next()) |path_entry| {
        const dir = if (path_entry.len == 0) "." else path_entry;
        const candidate = try std.fs.path.join(allocator, &.{ dir, executable });
        const candidate_z = try allocator.dupeZ(u8, candidate);
        if (c.access(candidate_z.ptr, c.X_OK) == 0) return candidate_z.ptr;
    }

    return (try allocator.dupeZ(u8, executable)).ptr;
}

fn installSignalHandlers() void {
    var sa = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
}

fn handleSocketStdin(context: *anyopaque, data: []const u8) void {
    const ctx: *SessionContext = @ptrCast(@alignCast(context));
    writeToPty(ctx, data, true);
}

fn handleSocketResize(context: *anyopaque, cols: u16, rows: u16) void {
    const ctx: *SessionContext = @ptrCast(@alignCast(context));
    resizePty(ctx, cols, rows);
}

fn handleSocketResetSize(context: *anyopaque) void {
    const ctx: *SessionContext = @ptrCast(@alignCast(context));
    const stdout_fd = std.Io.File.stdout().handle;
    if (c.isatty(stdout_fd) != 1) return;
    if (pty_mod.getWinsizeFromFd(stdout_fd)) |ws| {
        resizePty(ctx, ws.ws_col, ws.ws_row);
    } else |_| {}
}

fn handleSocketKill(context: *anyopaque, signal: ?i32) void {
    const ctx: *SessionContext = @ptrCast(@alignCast(context));
    const pid = g_child_pid.load(.acquire);
    if (pid <= 0) return;
    const sig = signal orelse @as(i32, @intCast(@intFromEnum(posix.SIG.TERM)));
    _ = c.kill(-pid, sig);
    ctx.running.store(false, .release);
}

fn handleSocketUpdateTitle(context: *anyopaque, title: []const u8) void {
    const ctx: *SessionContext = @ptrCast(@alignCast(context));
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const sanitized = title_mod.sanitizeTitle(arena.allocator(), title) catch return;
    const name_copy = ctx.allocator.dupe(u8, sanitized) catch return;

    session_mod.updateSessionName(ctx.io, arena.allocator(), ctx.session_json_path, sanitized) catch {};
    replaceSessionName(ctx, name_copy);
}

fn writeToPty(ctx: *SessionContext, data: []const u8, record_input: bool) void {
    ctx.pty_mutex.lockUncancelable(ctx.io);
    defer ctx.pty_mutex.unlock(ctx.io);

    var offset: usize = 0;
    while (offset < data.len) {
        const write_result = c.write(ctx.pty.master, data[offset..].ptr, data.len - offset);
        if (write_result < 0) {
            if (std.c.errno(write_result) == .INTR) continue;
            return;
        }
        const written: usize = @intCast(write_result);
        if (written == 0) break;
        offset += written;
    }

    if (record_input) {
        ctx.asciinema.writeInput(data) catch {};
    }
}

fn resizePty(ctx: *SessionContext, cols: u16, rows: u16) void {
    if (cols == 0 or rows == 0) return;
    const ws = pty_mod.winsize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 };
    ctx.pty.setSize(ws) catch {};
    ctx.asciinema.writeResize(cols, rows) catch {};
}

fn updateLocalTitle(ctx: *SessionContext, name: []const u8) !void {
    const safe_name = try title_mod.sanitizeTitle(ctx.allocator, name);
    defer ctx.allocator.free(safe_name);
    const seq = if (ctx.title_mode == .none or ctx.title_mode == .filter)
        try std.fmt.allocPrint(ctx.allocator, "\x1b]2;{s}\x07", .{safe_name})
    else
        try title_mod.generateTitleSequence(ctx.allocator, ctx.cwd, ctx.command, safe_name, ctx.home);
    defer ctx.allocator.free(seq);

    ctx.stdout_mutex.lockUncancelable(ctx.io);
    defer ctx.stdout_mutex.unlock(ctx.io);
    std.Io.File.stdout().writeStreamingAll(ctx.io, seq) catch {};
}

fn sessionWatcherThread(ctx: *SessionContext) void {
    var last_mtime = std.Io.Timestamp.zero;
    if (std.Io.Dir.cwd().statFile(ctx.io, ctx.session_json_path, .{})) |stat| {
        last_mtime = stat.mtime;
    } else |_| {}

    while (ctx.running.load(.acquire)) {
        std.Io.sleep(ctx.io, .fromMilliseconds(500), .awake) catch return;
        const stat = std.Io.Dir.cwd().statFile(ctx.io, ctx.session_json_path, .{}) catch continue;
        if (stat.mtime.nanoseconds == last_mtime.nanoseconds) continue;
        last_mtime = stat.mtime;

        var arena = std.heap.ArenaAllocator.init(ctx.allocator);
        defer arena.deinit();
        const name_tmp = session_mod.readSessionName(ctx.io, arena.allocator(), ctx.session_json_path) catch null;
        if (name_tmp == null) continue;
        const name_copy = ctx.allocator.dupe(u8, name_tmp.?) catch continue;
        replaceSessionName(ctx, name_copy);
    }
}

fn resizeWatcherThread(ctx: *SessionContext) void {
    const stdout_fd = std.Io.File.stdout().handle;
    if (c.isatty(stdout_fd) != 1) return;
    var last_cols = ctx.last_cols;
    var last_rows = ctx.last_rows;

    while (ctx.running.load(.acquire)) {
        std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake) catch return;
        const ws = pty_mod.getWinsizeFromFd(stdout_fd) catch continue;
        if (ws.ws_col == last_cols and ws.ws_row == last_rows) continue;
        last_cols = ws.ws_col;
        last_rows = ws.ws_row;
        resizePty(ctx, ws.ws_col, ws.ws_row);
    }
}

fn mainLoop(ctx: *SessionContext, stdin_fd: posix.fd_t) !void {
    var stdin_active = true;
    var poll_fds = [_]posix.pollfd{
        .{ .fd = ctx.pty.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
    };

    var buffer: [8192]u8 = undefined;
    var filtered = std.ArrayList(u8).empty;
    defer filtered.deinit(ctx.allocator);

    while (ctx.running.load(.acquire)) {
        if (!stdin_active) {
            poll_fds[1].fd = -1;
            poll_fds[1].events = 0;
        }

        const ready = try posix.poll(&poll_fds, 200);

        if (ready == 0) continue;

        if (poll_fds[0].revents & posix.POLL.IN != 0) {
            const read_result = c.read(ctx.pty.master, &buffer, buffer.len);
            if (read_result < 0) {
                switch (std.c.errno(read_result)) {
                    .INTR => continue,
                    .IO => break,
                    else => return error.PtyReadFailed,
                }
            }
            const read_len: usize = @intCast(read_result);
            if (read_len == 0) break;

            const chunk = buffer[0..read_len];
            var output_slice = chunk;
            if (ctx.title_mode != .none) {
                filtered.clearRetainingCapacity();
                ctx.title_filter.filter(ctx.allocator, chunk, &filtered) catch {};
                output_slice = filtered.items;
            }

            if (output_slice.len > 0) {
                ctx.asciinema.writeOutput(output_slice) catch {};
                ctx.stdout_mutex.lockUncancelable(ctx.io);
                std.Io.File.stdout().writeStreamingAll(ctx.io, output_slice) catch {};
                ctx.stdout_mutex.unlock(ctx.io);
            }
        }

        if (poll_fds[0].revents & posix.POLL.IN == 0 and
            poll_fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0)
        {
            break;
        }

        if (stdin_active and poll_fds[1].revents & (posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL) != 0) {
            stdin_active = false;
        } else if (stdin_active and poll_fds[1].revents & posix.POLL.IN != 0) {
            const read_result = c.read(stdin_fd, &buffer, buffer.len);
            if (read_result < 0) {
                if (std.c.errno(read_result) == .INTR) continue;
                return error.StdinReadFailed;
            }
            const read_len: usize = @intCast(read_result);
            if (read_len == 0) {
                stdin_active = false;
            } else {
                writeToPty(ctx, buffer[0..read_len], true);
            }
        }
    }
}

fn decodeExitStatus(status: u32) ExitInfo {
    if ((status & 0x7f) == 0) {
        return .{ .exit_code = @intCast((status >> 8) & 0xff), .signal = null };
    }
    const sig: u8 = @intCast(status & 0x7f);
    return .{ .exit_code = 128 + sig, .signal = sig };
}

fn replaceSessionName(ctx: *SessionContext, name: []u8) void {
    ctx.session_mutex.lockUncancelable(ctx.io);
    if (std.mem.eql(u8, ctx.session_name, name)) {
        ctx.session_mutex.unlock(ctx.io);
        ctx.allocator.free(name);
        return;
    }

    const old_name = ctx.session_name;
    ctx.session_name = name;
    updateLocalTitle(ctx, name) catch {};
    ctx.session_mutex.unlock(ctx.io);
    ctx.allocator.free(old_name);
}

fn terminateChild(pid: c.pid_t) void {
    if (pid > 0) _ = c.kill(-pid, @intFromEnum(posix.SIG.TERM));
}

fn waitForChild(pid: c.pid_t) !ExitInfo {
    while (true) {
        var wait_status: c_int = 0;
        const result = c.waitpid(pid, &wait_status, 0);
        if (result == pid) return decodeExitStatus(@bitCast(wait_status));
        if (std.c.errno(result) == .INTR) continue;
        return error.WaitFailed;
    }
}

test "parseArgs handles verbosity and command boundaries" {
    const parsed = try parseArgs(std.testing.io, &.{ "-q", "echo", "hello" }, .{});
    try std.testing.expect(parsed.options.verbosity == .silent);
    try std.testing.expectEqualStrings("echo", parsed.command[0]);
    try std.testing.expectEqualStrings("hello", parsed.command[1]);
}

test "parseArgs rejects missing values and unknown options" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(std.testing.io, &.{"--session-id"}, .{}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(std.testing.io, &.{"--unknown"}, .{}));
}

test "session ids are bounded and path-safe" {
    try std.testing.expect(isValidSessionId("fwd_123_456"));
    try std.testing.expect(!isValidSessionId("../escape"));
    try std.testing.expect(!isValidSessionId("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
}
