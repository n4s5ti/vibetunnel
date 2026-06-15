const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
});

pub const Level = enum(u8) {
    silent = 0,
    @"error" = 1,
    warn = 2,
    info = 3,
    verbose = 4,
    debug = 5,
};

pub fn parseLevel(value: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(value, "silent")) return .silent;
    if (std.ascii.eqlIgnoreCase(value, "error")) return .@"error";
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "verbose")) return .verbose;
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    return null;
}

pub const Logger = struct {
    io: std.Io,
    level: Level,
    file: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, level: Level, log_path: ?[]const u8) Logger {
        var logger = Logger{ .io = io, .level = level };
        if (log_path) |path| {
            if (std.fs.path.dirname(path)) |dir| {
                std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            }
            const permissions: std.Io.File.Permissions = @enumFromInt(0o600);
            logger.file = std.Io.Dir.cwd().createFile(io, path, .{
                .truncate = false,
                .permissions = permissions,
            }) catch null;
            if (logger.file) |file| {
                file.setPermissions(io, permissions) catch {};
                const flags = c.fcntl(file.handle, c.F_GETFL);
                if (flags >= 0) _ = c.fcntl(file.handle, c.F_SETFL, flags | c.O_APPEND);
            }
        }
        return logger;
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |*file| {
            file.close(self.io);
            self.file = null;
        }
    }

    pub fn logError(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.@"error", "ERROR", fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, "WARN", fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, "INFO", fmt, args);
    }

    pub fn verbose(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.verbose, "VERBOSE", fmt, args);
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, "DEBUG", fmt, args);
    }

    fn log(self: *Logger, level: Level, comptime label: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(self.level) < @intFromEnum(level)) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        var stderr_buffer: [640]u8 = undefined;
        const stderr_msg = std.fmt.bufPrint(&stderr_buffer, "[{s}] {s}\n", .{ label, msg }) catch return;
        std.Io.File.stderr().writeStreamingAll(self.io, stderr_msg) catch {};

        if (self.file) |*file| {
            file.writeStreamingAll(self.io, msg) catch {};
            file.writeStreamingAll(self.io, "\n") catch {};
        }
    }
};

test "parseLevel is case-insensitive" {
    try std.testing.expect(parseLevel("INFO") == .info);
    try std.testing.expect(parseLevel("warn") == .warn);
    try std.testing.expect(parseLevel("DEBUG") == .debug);
    try std.testing.expect(parseLevel("nope") == null);
}

test "logger appends and keeps private permissions" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "log.txt" });
    defer allocator.free(path);

    var first = Logger.init(std.testing.io, .debug, path);
    first.info("first", .{});
    first.deinit();
    var second = Logger.init(std.testing.io, .debug, path);
    second.info("second", .{});
    second.deinit();

    const contents = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(1024),
    );
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("first\nsecond\n", contents);
    const file_stat = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        @intFromEnum(file_stat.permissions) & 0o777,
    );
}
