const std = @import("std");

const c = @import("c").c;

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

    while (c.glfwWindowShouldClose(engine.window.handle) == 0) {
        engine.renderer.draw() catch |err| {
            std.log.err("Failed to draw: {s}", .{@errorName(err)});
        };

        c.glfwPollEvents();
    }

    // TODO: move into engine loop and leave main as the entrypoint
    // var running = true;
    // var event: sdl.Event = undefined;
    // var resize_requested = false;
    // while (running) {
    //     if (resize_requested) {
    //         engine.renderer.resize() catch |err| {
    //             std.log.err("Failed to resize: {s}", .{@errorName(err)});
    //             return err;
    //         };
    //         resize_requested = false;
    //     }
    //
    //         //
    //     while (sdl.pollEvent(&event)) {
    //         switch (event.type) {
    //             .quit => running = false,
    //             .window_resized => resize_requested = true,
    //             else => {},
    //         }
    //     }
    // }
}
