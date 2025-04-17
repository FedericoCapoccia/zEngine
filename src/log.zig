const std = @import("std");

const ctime = @cImport({
    @cInclude("time.h");
});

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const writer = switch (level) {
        .err, .warn => std.io.getStdErr().writer(),
        .info, .debug => std.io.getStdOut().writer(),
    };

    const color = switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };

    const now: ctime.time_t = ctime.time(null);
    const timeinfo = ctime.localtime(&now);
    var buff: [9]u8 = undefined;
    _ = ctime.strftime(&buff, buff.len, "%H:%M:%S", timeinfo);

    writer.print("[{s}] {s}[{s}]\t", .{ buff, color, @tagName(level) }) catch return;
    writer.print(format ++ "\x1b[0m\n", args) catch return;
}
