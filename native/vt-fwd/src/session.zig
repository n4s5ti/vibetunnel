const std = @import("std");

pub const SessionInfo = struct {
    id: []const u8,
    name: []const u8,
    command: []const []const u8,
    workingDir: []const u8,
    status: []const u8,
    exitCode: ?i32 = null,
    startedAt: []const u8,
    pid: ?i32 = null,
    initialCols: ?u16 = null,
    initialRows: ?u16 = null,
    lastClearOffset: ?u64 = null,
    version: ?[]const u8 = null,
    gitRepoPath: ?[]const u8 = null,
    gitBranch: ?[]const u8 = null,
    gitAheadCount: ?i32 = null,
    gitBehindCount: ?i32 = null,
    gitHasChanges: ?bool = null,
    gitIsWorktree: ?bool = null,
    gitMainRepoPath: ?[]const u8 = null,
    attachedViaVT: ?bool = null,
};

pub fn writeSessionInfo(io: std.Io, path: []const u8, info: SessionInfo) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    try writeJsonAtomic(
        io,
        path,
        info,
        .{ .emit_null_optional_fields = false, .whitespace = .indent_2 },
    );
}

pub fn readSessionInfo(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(SessionInfo) {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    errdefer allocator.free(data);
    return std.json.parseFromSlice(SessionInfo, allocator, data, .{});
}

pub fn readSessionName(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const name_value = parsed.value.object.get("name") orelse return null;
    if (name_value != .string) return null;
    const name_copy = allocator.dupe(u8, name_value.string) catch return null;
    return name_copy;
}

pub fn updateSessionName(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSessionJson;
    try parsed.value.object.put(allocator, "name", .{ .string = name });

    try writeJsonAtomic(io, path, parsed.value, .{ .whitespace = .indent_2 });
}

fn writeJsonAtomic(
    io: std.Io,
    path: []const u8,
    value: anytype,
    options: std.json.Stringify.Options,
) !void {
    const permissions: std.Io.File.Permissions = @enumFromInt(0o600);
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = permissions,
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try std.json.Stringify.value(value, options, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.end();
    try atomic_file.replace(io);
}

test "writeSessionInfo and updateSessionName" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const command = [_][]const u8{ "echo", "hi" };
    const info = SessionInfo{
        .id = "test-session",
        .name = "initial name",
        .command = &command,
        .workingDir = "/tmp",
        .status = "running",
        .startedAt = "2025-01-01T00:00:00Z",
    };

    try writeSessionInfo(std.testing.io, path, info);

    const name1 = try readSessionName(std.testing.io, allocator, path);
    defer if (name1) |value| allocator.free(value);
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("initial name", name1.?);

    try updateSessionName(std.testing.io, allocator, path, "updated name");
    const name2 = try readSessionName(std.testing.io, allocator, path);
    defer if (name2) |value| allocator.free(value);
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("updated name", name2.?);
}

test "updateSessionName preserves fields and tolerates missing keys" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const json =
        \\{
        \\  "id": "test-session",
        \\  "name": "old name",
        \\  "command": ["bash"],
        \\  "workingDir": "/tmp",
        \\  "status": "running",
        \\  "extraField": "keep-me",
        \\  "nestedObject": { "a": 1 }
        \\}
    ;

    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, json);

    try updateSessionName(std.testing.io, allocator, path, "new name");

    const updated = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, updated, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("new name", obj.get("name").?.string);
    try std.testing.expectEqualStrings("keep-me", obj.get("extraField").?.string);
    try std.testing.expect(obj.get("nestedObject").? == .object);
}

test "updateSessionName adds name when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const json =
        \\{
        \\  "id": "test-session",
        \\  "command": ["bash"],
        \\  "workingDir": "/tmp",
        \\  "status": "running"
        \\}
    ;

    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, json);

    try updateSessionName(std.testing.io, allocator, path, "inserted name");

    const updated = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, updated, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("inserted name", obj.get("name").?.string);
    try std.testing.expectEqualStrings("test-session", obj.get("id").?.string);
}

test "updateSessionName errors on non-object JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "[]\n");

    try std.testing.expectError(error.InvalidSessionJson, updateSessionName(std.testing.io, allocator, path, "new name"));
}
