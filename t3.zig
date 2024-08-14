const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const posix = std.posix;
const os = std.os.linux;
const math = std.math;

var i: usize = 0;
var size: Size = undefined;
var cooked_termios: os.termios = undefined;
var raw: os.termios = undefined;
var tty: fs.File = undefined;

pub fn main() !void {
    tty = try fs.openFileAbsolute("/dev/tty", .{ .mode = fs.File.OpenMode.read_write });
    defer tty.close();

    try uncook();
    defer cook() catch {};

    size = try getSize();

    posix.sigaction(posix.SIG.WINCH, &posix.Sigaction{
        .handler = .{ .handler = handleSigWinch },
        .mask = posix.empty_sigset,
        .flags = 0,
    }, null);

    while (true) {
        try render();

        var buffer: [1]u8 = undefined;
        _ = try tty.read(&buffer);

        if (buffer[0] == 'q') {
            return;
        } else if (buffer[0] == '\x1B') {
            raw.cc[@intFromEnum(os.V.TIME)] = 1;
            raw.cc[@intFromEnum(os.V.MIN)] = 0;
            try posix.tcsetattr(tty.handle, .NOW, raw);

            var esc_buffer: [8]u8 = undefined;
            const esc_read = try tty.read(&esc_buffer);

            raw.cc[@intFromEnum(os.V.TIME)] = 0;
            raw.cc[@intFromEnum(os.V.MIN)] = 1;
            try posix.tcsetattr(tty.handle, .NOW, raw);

            if (mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
                i -|= 1;
            } else if (mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
                i = @min(i + 1, 3);
            }
        }
    }
}

fn handleSigWinch(_: c_int) callconv(.C) void {
    size = getSize() catch return;
    render() catch return;
}

fn render() !void {
    const writer = tty.writer();
    try writeLine(writer, "foo", 0, size.width, i == 0);
    try writeLine(writer, "bar", 1, size.width, i == 1);
    try writeLine(writer, "baz", 2, size.width, i == 2);
    try writeLine(writer, "xyzzy", 3, size.width, i == 3);
}

fn writeLine(writer: anytype, txt: []const u8, y: usize, width: usize, selected: bool) !void {
    if (selected) {
        try blueBackground(writer);
    } else {
        try attributeReset(writer);
    }
    try moveCursor(writer, y, 0);
    try writer.writeAll(txt);
    try writer.writeByteNTimes(' ', width - txt.len);
}

fn uncook() !void {
    const writer = tty.writer();
    cooked_termios = try posix.tcgetattr(tty.handle);
    errdefer cook() catch {};

    raw = cooked_termios;
    raw.lflag = os.tc_lflag_t{
        .ECHO = false,
        .ICANON = false,
        .ISIG = false,
        .IEXTEN = false,
    };
    raw.iflag = os.tc_iflag_t{
        .IXON = false,
        .ICRNL = false,
        .BRKINT = false,
        .INPCK = false,
        .ISTRIP = false,
    };
    raw.oflag = os.tc_oflag_t{
        .OPOST = false,
    };
    // raw.cflag |= posix.system.CS8;
    raw.cc[@intFromEnum(os.V.TIME)] = 0;
    raw.cc[@intFromEnum(os.V.MIN)] = 1;
    try posix.tcsetattr(tty.handle, .FLUSH, raw);

    try hideCursor(writer);
    try enterAlt(writer);
    try clear(writer);
}

fn cook() !void {
    const writer = tty.writer();
    try clear(writer);
    try leaveAlt(writer);
    try showCursor(writer);
    try attributeReset(writer);
    try posix.tcsetattr(tty.handle, .FLUSH, cooked_termios);
}

fn moveCursor(writer: anytype, row: usize, col: usize) !void {
    _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
}

fn enterAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[s"); // Save cursor pposix.tion.
    try writer.writeAll("\x1B[?47h"); // Save screen.
    try writer.writeAll("\x1B[?1049h"); // Enable alternative buffer.
}

fn leaveAlt(writer: anytype) !void {
    try writer.writeAll("\x1B[?1049l"); // Disable alternative buffer.
    try writer.writeAll("\x1B[?47l"); // Restore screen.
    try writer.writeAll("\x1B[u"); // Restore cursor pposix.tion.
}

fn hideCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25l");
}

fn showCursor(writer: anytype) !void {
    try writer.writeAll("\x1B[?25h");
}

fn attributeReset(writer: anytype) !void {
    try writer.writeAll("\x1B[0m");
}

fn blueBackground(writer: anytype) !void {
    try writer.writeAll("\x1B[44m");
}

fn clear(writer: anytype) !void {
    try writer.writeAll("\x1B[2J");
}

const Size = struct { width: usize, height: usize };

fn getSize() !Size {
    var win_size = mem.zeroes(posix.winsize);
    const err = posix.system.ioctl(tty.handle, posix.system.T.IOCGWINSZ, @intFromPtr(&win_size));
    if (posix.errno(err) != .SUCCESS) {
        const retErr: posix.system.E = @enumFromInt(err);
        return posix.unexpectedErrno(retErr);
    }
    return Size{
        .height = win_size.row,
        .width = win_size.col,
    };
}
