const std = @import("std");
const logger_mod = @import("logger.zig");

const posix = std.posix;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

const max_payload_len: usize = 1024 * 1024;

pub const MessageType = enum(u8) {
    stdin_data = 0x01,
    control_cmd = 0x02,
    status_update = 0x03,
    heartbeat = 0x04,
    @"error" = 0x05,
};

pub const Handler = struct {
    context: *anyopaque,
    logger: *logger_mod.Logger,
    on_stdin: *const fn (context: *anyopaque, data: []const u8) void,
    on_resize: *const fn (context: *anyopaque, cols: u16, rows: u16) void,
    on_reset_size: *const fn (context: *anyopaque) void,
    on_kill: *const fn (context: *anyopaque, signal: ?i32) void,
    on_update_title: *const fn (context: *anyopaque, title: []const u8) void,
};

pub const Server = struct {
    io: std.Io,
    fd: posix.fd_t,
    socket_path: []const u8,
    allocator: std.mem.Allocator,
    handler: Handler,
    running: *std.atomic.Value(bool),
    active_client: std.atomic.Value(i32) = .init(-1),

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        handler: Handler,
        running: *std.atomic.Value(bool),
    ) !Server {
        _ = std.Io.Dir.cwd().deleteFile(io, socket_path) catch {};

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        if (@hasField(c.sockaddr_un, "sun_len")) {
            addr.sun_len = @intCast(@sizeOf(c.sockaddr_un));
        }

        if (socket_path.len >= addr.sun_path.len) {
            return error.PathTooLong;
        }

        std.mem.copyForwards(u8, addr.sun_path[0..socket_path.len], socket_path);
        addr.sun_path[socket_path.len] = 0;

        if (c.bind(fd, @ptrCast(&addr), @intCast(@sizeOf(c.sockaddr_un))) != 0) {
            return error.BindFailed;
        }
        const socket_path_z = try allocator.dupeZ(u8, socket_path);
        defer allocator.free(socket_path_z);
        if (c.chmod(socket_path_z.ptr, 0o600) != 0) {
            return error.ChmodFailed;
        }

        if (c.listen(fd, 8) != 0) {
            return error.ListenFailed;
        }

        return .{
            .io = io,
            .fd = fd,
            .socket_path = socket_path,
            .allocator = allocator,
            .handler = handler,
            .running = running,
        };
    }

    pub fn run(self: *Server) void {
        while (self.running.load(.acquire)) {
            const client_fd = c.accept(self.fd, null, null);
            if (client_fd < 0) {
                if (!self.running.load(.acquire)) return;
                continue;
            }
            self.active_client.store(client_fd, .release);
            self.handleClient(client_fd);
            self.active_client.store(-1, .release);
            _ = c.close(client_fd);
        }
    }

    pub fn stop(self: *Server) void {
        const client_fd = self.active_client.load(.acquire);
        if (client_fd >= 0) {
            _ = c.shutdown(client_fd, c.SHUT_RDWR);
        }
        _ = c.shutdown(self.fd, c.SHUT_RDWR);
        _ = c.close(self.fd);
        _ = std.Io.Dir.cwd().deleteFile(self.io, self.socket_path) catch {};
    }

    fn handleClient(self: *Server, fd: posix.fd_t) void {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.allocator);
        var temp: [4096]u8 = undefined;

        while (self.running.load(.acquire)) {
            const read_result = c.read(fd, &temp, temp.len);
            if (read_result < 0) {
                if (std.c.errno(read_result) == .INTR) continue;
                break;
            }
            const read_len: usize = @intCast(read_result);
            if (read_len == 0) break;
            if (buffer.items.len > max_payload_len + 5 -| read_len) break;
            _ = buffer.appendSlice(self.allocator, temp[0..read_len]) catch break;

            while (buffer.items.len >= 5) {
                const payload_len: usize = std.mem.readInt(u32, buffer.items[1..5], .big);
                if (payload_len > max_payload_len) return;
                const frame_len = 5 + payload_len;
                if (buffer.items.len < frame_len) break;
                const payload = buffer.items[5..frame_len];
                if (messageType(buffer.items[0])) |msg_type| {
                    self.dispatchMessage(fd, msg_type, payload);
                }
                buffer.replaceRange(self.allocator, 0, frame_len, &[_]u8{}) catch return;
            }
        }
    }

    fn dispatchMessage(self: *Server, fd: posix.fd_t, msg_type: MessageType, payload: []const u8) void {
        switch (msg_type) {
            .stdin_data => self.handler.on_stdin(self.handler.context, payload),
            .control_cmd => self.handleControl(payload),
            .heartbeat => self.sendHeartbeat(fd),
            else => {},
        }
    }

    fn handleControl(self: *Server, payload: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return;
        defer parsed.deinit();

        if (parsed.value != .object) return;
        const cmd_value = parsed.value.object.get("cmd") orelse return;
        if (cmd_value != .string) return;
        const cmd = cmd_value.string;

        if (std.mem.eql(u8, cmd, "resize")) {
            const cols = parseDimension(parsed.value.object.get("cols")) orelse return;
            const rows = parseDimension(parsed.value.object.get("rows")) orelse return;
            self.handler.on_resize(self.handler.context, cols, rows);
            return;
        }

        if (std.mem.eql(u8, cmd, "reset-size")) {
            self.handler.on_reset_size(self.handler.context);
            return;
        }

        if (std.mem.eql(u8, cmd, "kill")) {
            const signal = if (parsed.value.object.get("signal")) |value|
                parseSignal(value) orelse return
            else
                null;
            self.handler.on_kill(self.handler.context, signal);
            return;
        }

        if (std.mem.eql(u8, cmd, "update-title")) {
            const title_value = parsed.value.object.get("title") orelse return;
            if (title_value != .string) return;
            self.handler.on_update_title(self.handler.context, title_value.string);
            return;
        }
    }

    fn parseDimension(value_opt: ?std.json.Value) ?u16 {
        const value = value_opt orelse return null;
        if (value != .integer) return null;
        const dimension = value.integer;
        if (dimension <= 0 or dimension > std.math.maxInt(u16)) return null;
        return @intCast(dimension);
    }

    fn parseSignal(value_opt: ?std.json.Value) ?i32 {
        const value = value_opt orelse return null;
        switch (value) {
            .integer => |v| {
                if (v <= 0 or v > 64) return null;
                return @intCast(v);
            },
            .string => |s| return signalFromName(s),
            else => return null,
        }
    }

    fn signalFromName(name: []const u8) ?i32 {
        if (std.ascii.eqlIgnoreCase(name, "SIGTERM")) return @intCast(@intFromEnum(posix.SIG.TERM));
        if (std.ascii.eqlIgnoreCase(name, "SIGKILL")) return @intCast(@intFromEnum(posix.SIG.KILL));
        if (std.ascii.eqlIgnoreCase(name, "SIGINT")) return @intCast(@intFromEnum(posix.SIG.INT));
        if (std.ascii.eqlIgnoreCase(name, "SIGHUP")) return @intCast(@intFromEnum(posix.SIG.HUP));
        return null;
    }

    fn sendHeartbeat(self: *Server, fd: posix.fd_t) void {
        _ = self;
        var frame: [5]u8 = undefined;
        frame[0] = @intFromEnum(MessageType.heartbeat);
        std.mem.writeInt(u32, frame[1..5], 0, .big);
        _ = writeAll(fd, &frame);
    }
};

fn messageType(value: u8) ?MessageType {
    return switch (value) {
        @intFromEnum(MessageType.stdin_data) => .stdin_data,
        @intFromEnum(MessageType.control_cmd) => .control_cmd,
        @intFromEnum(MessageType.status_update) => .status_update,
        @intFromEnum(MessageType.heartbeat) => .heartbeat,
        @intFromEnum(MessageType.@"error") => .@"error",
        else => null,
    };
}

fn writeAll(fd: posix.fd_t, data: []const u8) void {
    var offset: usize = 0;
    while (offset < data.len) {
        const write_result = c.write(fd, data[offset..].ptr, data.len - offset);
        if (write_result < 0) {
            if (std.c.errno(write_result) == .INTR) continue;
            return;
        }
        const written: usize = @intCast(write_result);
        if (written == 0) return;
        offset += written;
    }
}

test "message type rejects unknown values" {
    try std.testing.expect(messageType(0xff) == null);
    try std.testing.expect(messageType(0x01) == .stdin_data);
}

test "resize dimensions require positive u16 integers" {
    try std.testing.expectEqual(@as(?u16, 80), Server.parseDimension(.{ .integer = 80 }));
    try std.testing.expect(Server.parseDimension(.{ .integer = 0 }) == null);
    try std.testing.expect(Server.parseDimension(.{ .integer = -1 }) == null);
    try std.testing.expect(Server.parseDimension(.{ .integer = 65536 }) == null);
    try std.testing.expect(Server.parseDimension(.{ .float = 80.5 }) == null);
}

test "signals reject malformed and out-of-range values" {
    try std.testing.expectEqual(
        @as(?i32, @intCast(@intFromEnum(posix.SIG.TERM))),
        Server.parseSignal(.{ .string = "SIGTERM" }),
    );
    try std.testing.expect(Server.parseSignal(.{ .string = "NOPE" }) == null);
    try std.testing.expect(Server.parseSignal(.{ .integer = 0 }) == null);
    try std.testing.expect(Server.parseSignal(.{ .integer = 65 }) == null);
}
