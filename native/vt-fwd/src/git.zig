const std = @import("std");

pub const GitInfo = struct {
    arena: std.heap.ArenaAllocator,
    gitRepoPath: ?[]const u8 = null,
    gitBranch: ?[]const u8 = null,
    gitAheadCount: ?i32 = null,
    gitBehindCount: ?i32 = null,
    gitHasChanges: ?bool = null,
    gitIsWorktree: ?bool = null,
    gitMainRepoPath: ?[]const u8 = null,

    pub fn deinit(self: *GitInfo) void {
        self.arena.deinit();
    }
};

pub fn detectGitInfo(
    io: std.Io,
    allocator: std.mem.Allocator,
    parent_env: *const std.process.Environ.Map,
    working_dir: []const u8,
) GitInfo {
    var info = GitInfo{ .arena = std.heap.ArenaAllocator.init(allocator) };
    const arena_alloc = info.arena.allocator();

    var env = parent_env.clone(arena_alloc) catch return info;
    env.put("GIT_TERMINAL_PROMPT", "0") catch {};

    const repo_path = runGit(io, arena_alloc, working_dir, &env, &.{ "git", "rev-parse", "--show-toplevel" }) orelse return info;
    info.gitRepoPath = repo_path;

    if (runGit(io, arena_alloc, working_dir, &env, &.{ "git", "branch", "--show-current" })) |branch| {
        info.gitBranch = branch;
    } else {
        info.gitBranch = "";
    }

    const git_file_path = std.fs.path.join(arena_alloc, &.{ working_dir, ".git" }) catch null;
    if (git_file_path) |path| {
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            if (stat.kind != .directory) {
                info.gitIsWorktree = true;
                if (getMainRepositoryPath(io, arena_alloc, path)) |main| {
                    info.gitMainRepoPath = main;
                }
            }
        } else |_| {}
    }

    if (runGit(io, arena_alloc, working_dir, &env, &.{ "git", "rev-list", "--left-right", "--count", "HEAD...@{upstream}" })) |counts| {
        var parts = std.mem.splitScalar(u8, counts, '\t');
        if (parts.next()) |ahead| {
            info.gitAheadCount = std.fmt.parseInt(i32, ahead, 10) catch null;
        }
        if (parts.next()) |behind| {
            info.gitBehindCount = std.fmt.parseInt(i32, behind, 10) catch null;
        }
    }

    if (runGitStatus(io, arena_alloc, working_dir, &env)) |has_changes| {
        info.gitHasChanges = has_changes;
    }

    if (info.gitIsWorktree == null) {
        info.gitIsWorktree = false;
    }

    if (info.gitMainRepoPath == null) {
        info.gitMainRepoPath = info.gitRepoPath;
    }

    return info;
}

fn runGit(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
    argv: []const []const u8,
) ?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
    }) catch return null;
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const output = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return output;
}

fn runGitStatus(
    io: std.Io,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
) ?bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "diff-index", "--quiet", "HEAD", "--" },
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code == 0) return false;
            return true;
        },
        else => return null,
    }
}

fn getMainRepositoryPath(io: std.Io, allocator: std.mem.Allocator, git_file_path: []const u8) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, git_file_path, allocator, .limited(1024)) catch return null;
    defer allocator.free(data);

    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    const path_part = std.mem.trim(u8, trimmed[prefix.len..], " \t");

    const marker = "/.git/worktrees/";
    if (std.mem.indexOf(u8, path_part, marker)) |idx| {
        return allocator.dupe(u8, path_part[0..idx]) catch null;
    }

    return null;
}

fn expectCommandSuccess(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.CommandFailed,
    }
}

test "detectGitInfo retains metadata without an upstream branch" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(repo_path);
    const absolute_repo_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, repo_path, allocator);
    defer allocator.free(absolute_repo_path);

    try expectCommandSuccess(std.testing.io, allocator, absolute_repo_path, &.{ "git", "init", "-q", "-b", "main" });
    try expectCommandSuccess(std.testing.io, allocator, absolute_repo_path, &.{
        "git",
        "-c",
        "user.name=VibeTunnel Test",
        "-c",
        "user.email=test@vibetunnel.local",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "initial",
    });

    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    var info = detectGitInfo(std.testing.io, allocator, &env, absolute_repo_path);
    defer info.deinit();

    try std.testing.expectEqualStrings(absolute_repo_path, info.gitRepoPath.?);
    try std.testing.expectEqualStrings("main", info.gitBranch.?);
    try std.testing.expectEqualStrings(absolute_repo_path, info.gitMainRepoPath.?);
    try std.testing.expect(info.gitAheadCount == null);
    try std.testing.expect(info.gitBehindCount == null);
}
