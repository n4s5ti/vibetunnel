const std = @import("std");

pub const AsciinemaWriter = struct {
    io: std.Io,
    file: std.Io.File,
    writer: std.Io.File.Writer,
    writer_buf: [4096]u8 = undefined,
    started_at: std.Io.Timestamp,
    mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    utf8_buffer: std.ArrayList(u8),

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        width: u16,
        height: u16,
        command: []const u8,
        title: []const u8,
    ) !AsciinemaWriter {
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }

        const permissions: std.Io.File.Permissions = @enumFromInt(0o600);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = true,
            .permissions = permissions,
        });
        var writer = AsciinemaWriter{
            .io = io,
            .file = file,
            .writer = undefined,
            .started_at = std.Io.Clock.awake.now(io),
            .allocator = allocator,
            .utf8_buffer = std.ArrayList(u8).empty,
        };
        writer.writer = file.writer(io, &writer.writer_buf);
        try writer.writeHeader(width, height, command, title);
        return writer;
    }

    pub fn deinit(self: *AsciinemaWriter) void {
        self.utf8_buffer.deinit(self.allocator);
        _ = self.writer.end() catch {};
        self.file.close(self.io);
    }

    pub fn writeOutput(self: *AsciinemaWriter, data: []const u8) !void {
        var combined = std.ArrayList(u8).empty;
        defer combined.deinit(self.allocator);
        try combined.appendSlice(self.allocator, self.utf8_buffer.items);
        try combined.appendSlice(self.allocator, data);

        var sanitized = std.ArrayList(u8).empty;
        defer sanitized.deinit(self.allocator);
        self.utf8_buffer.clearRetainingCapacity();
        try sanitizeUtf8(
            self.allocator,
            combined.items,
            true,
            &sanitized,
            &self.utf8_buffer,
        );

        if (sanitized.items.len == 0) return;
        try self.writeEvent('o', sanitized.items);
    }

    pub fn writeInput(self: *AsciinemaWriter, data: []const u8) !void {
        var sanitized = std.ArrayList(u8).empty;
        defer sanitized.deinit(self.allocator);
        var unused_remainder = std.ArrayList(u8).empty;
        defer unused_remainder.deinit(self.allocator);
        try sanitizeUtf8(self.allocator, data, false, &sanitized, &unused_remainder);
        if (sanitized.items.len > 0) try self.writeEvent('i', sanitized.items);
    }

    pub fn writeResize(self: *AsciinemaWriter, cols: u16, rows: u16) !void {
        var buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&buf, "{d}x{d}", .{ cols, rows });
        try self.writeEvent('r', size);
    }

    pub fn writeExit(self: *AsciinemaWriter, exit_code: i32, session_id: []const u8) !void {
        if (self.utf8_buffer.items.len > 0) {
            var sanitized = std.ArrayList(u8).empty;
            defer sanitized.deinit(self.allocator);
            var unused_remainder = std.ArrayList(u8).empty;
            defer unused_remainder.deinit(self.allocator);
            try sanitizeUtf8(
                self.allocator,
                self.utf8_buffer.items,
                false,
                &sanitized,
                &unused_remainder,
            );
            self.utf8_buffer.clearRetainingCapacity();
            if (sanitized.items.len > 0) try self.writeEvent('o', sanitized.items);
        }

        var file_writer = &self.writer;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try file_writer.interface.writeAll("[\"exit\",");
        try file_writer.interface.print("{}", .{exit_code});
        try file_writer.interface.writeAll(",");
        try std.json.Stringify.value(session_id, .{}, &file_writer.interface);
        try file_writer.interface.writeAll("]\n");
        try file_writer.interface.flush();
    }

    fn writeHeader(self: *AsciinemaWriter, width: u16, height: u16, command: []const u8, title: []const u8) !void {
        const header = Header{
            .version = 2,
            .width = width,
            .height = height,
            .timestamp = @intCast(@divTrunc(std.Io.Clock.real.now(self.io).nanoseconds, std.time.ns_per_s)),
            .command = if (command.len > 0) command else null,
            .title = if (title.len > 0) title else null,
        };
        var file_writer = &self.writer;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try std.json.Stringify.value(header, .{ .emit_null_optional_fields = false }, &file_writer.interface);
        try file_writer.interface.writeAll("\n");
        try file_writer.interface.flush();
    }

    fn writeEvent(self: *AsciinemaWriter, event_type: u8, data: []const u8) !void {
        var file_writer = &self.writer;
        const elapsed_ns = self.started_at.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds;
        const elapsed = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        try file_writer.interface.writeAll("[");
        try file_writer.interface.print("{d:.6}", .{elapsed});
        try file_writer.interface.writeAll(",\"");
        try file_writer.interface.writeByte(event_type);
        try file_writer.interface.writeAll("\",");
        try std.json.Stringify.value(data, .{}, &file_writer.interface);
        try file_writer.interface.writeAll("]\n");
        try file_writer.interface.flush();
    }
};

const Header = struct {
    version: u8,
    width: u16,
    height: u16,
    timestamp: i64,
    command: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

fn sanitizeUtf8(
    allocator: std.mem.Allocator,
    data: []const u8,
    preserve_incomplete_tail: bool,
    output: *std.ArrayList(u8),
    remainder: *std.ArrayList(u8),
) !void {
    var index: usize = 0;
    while (index < data.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(data[index]) catch {
            try output.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        const end = index + sequence_len;
        if (end > data.len) {
            if (preserve_incomplete_tail) {
                try remainder.appendSlice(allocator, data[index..]);
                return;
            }
            try output.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(data[index..end]) catch {
            try output.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        try output.appendSlice(allocator, data[index..end]);
        index = end;
    }
}

test "sanitizeUtf8 preserves incomplete tails and replaces malformed bytes" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var remainder = std.ArrayList(u8).empty;
    defer remainder.deinit(allocator);

    try sanitizeUtf8(allocator, &.{ 'A', 0xff, 'B', 0xE2, 0x82 }, true, &output, &remainder);
    try std.testing.expectEqualStrings("A\xEF\xBF\xBDB", output.items);
    try std.testing.expectEqualSlices(u8, &.{ 0xE2, 0x82 }, remainder.items);
}

test "sanitizeUtf8 completes split codepoints" {
    const allocator = std.testing.allocator;
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var remainder = std.ArrayList(u8).empty;
    defer remainder.deinit(allocator);

    try sanitizeUtf8(allocator, &.{ 0xE2, 0x82, 0xAC }, true, &output, &remainder);
    try std.testing.expectEqualStrings("\xE2\x82\xAC", output.items);
    try std.testing.expectEqual(@as(usize, 0), remainder.items.len);
}
