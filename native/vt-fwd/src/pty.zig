const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("vibetunnel-fwd does not support Windows.");
    }
}

pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

const c = switch (builtin.os.tag) {
    .macos => @cImport({
        @cInclude("fcntl.h");
        @cInclude("sys/ioctl.h");
        @cInclude("util.h");
        @cInclude("termios.h");
        @cInclude("unistd.h");
    }),
    .linux => @cImport({
        @cInclude("fcntl.h");
        @cInclude("sys/ioctl.h");
        @cInclude("pty.h");
        @cInclude("termios.h");
        @cInclude("unistd.h");
    }),
    else => @compileError("Unsupported OS for PTY support."),
};

pub const TIOCSCTTY = if (builtin.os.tag == .macos) 536900705 else c.TIOCSCTTY;
const TIOCSWINSZ = if (builtin.os.tag == .macos) 2148037735 else c.TIOCSWINSZ;
const TIOCGWINSZ = if (builtin.os.tag == .macos) 1074295912 else c.TIOCGWINSZ;

pub const Pty = struct {
    pub const Fd = posix.fd_t;
    pub const OpenError = error{OpenptyFailed};
    pub const SetSizeError = error{IoctlFailed};
    pub const GetSizeError = error{IoctlFailed};

    master: Fd,
    slave: Fd,

    pub fn open(size: winsize) OpenError!Pty {
        var size_copy = size;
        var master_fd: Fd = undefined;
        var slave_fd: Fd = undefined;
        if (c.openpty(&master_fd, &slave_fd, null, null, @ptrCast(&size_copy)) < 0) {
            return error.OpenptyFailed;
        }
        errdefer {
            _ = c.close(master_fd);
            _ = c.close(slave_fd);
        }

        // Set CLOEXEC on the master fd, only slave should be inherited.
        const fd_flags = c.fcntl(master_fd, c.F_GETFD);
        if (fd_flags >= 0) {
            _ = c.fcntl(master_fd, c.F_SETFD, fd_flags | c.FD_CLOEXEC);
        }

        // Ensure UTF-8 mode is enabled.
        var attrs: c.termios = undefined;
        if (c.tcgetattr(master_fd, &attrs) != 0) return error.OpenptyFailed;
        attrs.c_iflag |= c.IUTF8;
        if (c.tcsetattr(master_fd, c.TCSANOW, &attrs) != 0) return error.OpenptyFailed;

        return .{
            .master = master_fd,
            .slave = slave_fd,
        };
    }

    pub fn deinit(self: *Pty) void {
        if (self.master >= 0) {
            _ = c.close(self.master);
            self.master = -1;
        }
        if (self.slave >= 0) {
            _ = c.close(self.slave);
            self.slave = -1;
        }
        self.* = undefined;
    }

    pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
        if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0) {
            return error.IoctlFailed;
        }
    }

    pub fn getSize(self: Pty) GetSizeError!winsize {
        var ws: winsize = undefined;
        if (c.ioctl(self.master, TIOCGWINSZ, @intFromPtr(&ws)) < 0) {
            return error.IoctlFailed;
        }
        return ws;
    }
};

pub fn getWinsizeFromFd(fd: posix.fd_t) Pty.GetSizeError!winsize {
    var ws: winsize = undefined;
    if (c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws)) < 0) {
        return error.IoctlFailed;
    }
    return ws;
}
