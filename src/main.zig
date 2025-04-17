const std = @import("std");

const sdl = @import("zsdl3");

const Engine = @import("engine.zig").Engine;
const log_fn = @import("log.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_fn.myLogFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) std.log.err("Leaked memory", .{});

    var engine = Engine{ .allocator = allocator };
    try Engine.init(&engine);
    defer engine.shutdown();

    // TODO: move into engine loop and leave main as the entrypoint
    var running = true;
    var event: sdl.Event = undefined;
    while (running) {
        while (sdl.pollEvent(&event)) {
            switch (event.type) {
                .quit => running = false,
                .window_resized => {
                    std.log.debug("Window resized", .{});
                },
                else => {},
            }
        }
    }
}
