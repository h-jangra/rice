const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const paths = @import("paths/mod.zig");

pub fn isTTY() bool {
    if (builtin.is_test) return false;
    return std.Io.File.stderr().isTty(paths.getProcessIo()) catch false;
}

pub fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        std.os.windows.kernel32.Sleep(ms);
    } else {
        const req = std.posix.timespec{
            .sec = @as(isize, @intCast(ms / 1000)),
            .nsec = @as(isize, @intCast((ms % 1000) * 1_000_000)),
        };
        _ = std.posix.system.nanosleep(&req, null);
    }
}

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const Spinner = struct {
    allocator: Allocator,
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,
    active: std.atomic.Value(bool),
    thread: ?std.Thread = null,
    is_tty: bool,
    lock: SpinLock = .{},

    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

    pub fn start(allocator: Allocator, message: []const u8) !*Spinner {
        const spinner = try allocator.create(Spinner);
        const tty = isTTY();

        spinner.* = .{
            .allocator = allocator,
            .active = std.atomic.Value(bool).init(true),
            .thread = null,
            .is_tty = tty,
            .lock = .{},
        };

        const copy_len = @min(message.len, spinner.msg_buf.len);
        @memcpy(spinner.msg_buf[0..copy_len], message[0..copy_len]);
        spinner.msg_len = copy_len;

        if (tty) {
            spinner.thread = std.Thread.spawn(.{}, run, .{spinner}) catch null;
        } else {
            std.debug.print("{s}...\n", .{spinner.msg_buf[0..spinner.msg_len]});
        }

        return spinner;
    }

    fn run(self: *Spinner) void {
        var frame_idx: usize = 0;
        var local_buf: [256]u8 = undefined;
        var local_len: usize = 0;

        while (self.active.load(.acquire)) {
            {
                self.lock.lock();
                local_len = self.msg_len;
                @memcpy(local_buf[0..local_len], self.msg_buf[0..local_len]);
                self.lock.unlock();
            }

            const frame = frames[frame_idx % frames.len];
            std.debug.print("\r\x1b[2K{s} {s}", .{ frame, local_buf[0..local_len] });

            frame_idx +%= 1;
            sleepMs(80);
        }
    }

    pub fn updateMessage(self: *Spinner, new_message: []const u8) void {
        self.lock.lock();
        const copy_len = @min(new_message.len, self.msg_buf.len);
        @memcpy(self.msg_buf[0..copy_len], new_message[0..copy_len]);
        self.msg_len = copy_len;
        self.lock.unlock();

        if (!self.is_tty) {
            std.debug.print("{s}...\n", .{self.msg_buf[0..self.msg_len]});
        }
    }

    fn finish(self: *Spinner, final_message: ?[]const u8) void {
        if (self.active.swap(false, .release)) {
            if (self.thread) |*t| {
                t.join();
                self.thread = null;
            }
            if (self.is_tty) {
                if (final_message) |msg| {
                    std.debug.print("\r\x1b[2K{s}\n", .{msg});
                } else {
                    std.debug.print("\r\x1b[2K", .{});
                }
            } else if (final_message) |msg| {
                std.debug.print("{s}\n", .{msg});
            }
        }
        self.allocator.destroy(self);
    }

    pub fn stop(self: *Spinner) void {
        self.finish(null);
    }

    pub fn stopWithMessage(self: *Spinner, final_message: []const u8) void {
        self.finish(final_message);
    }
};

