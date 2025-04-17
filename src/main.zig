const std = @import("std");

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

    // const window = Window.initialize(800, 600, "SimpleEngine") catch |err| {
    //     log.err("Failed to create window: {s}", .{@errorName(err)});
    //     return;
    // };
    // defer window.shutdown();
    //
    //
    // var renderer = Renderer.initialize(allocator, &window) catch |err| {
    //     log.err("Failed to create renderer: {s}", .{@errorName(err)});
    //     return;
    // };
    // defer renderer.shutdown();
    //
    // var running = true;
    // var event: sdl.Event = undefined;
    // while (running) {
    //     while (sdl.pollEvent(&event)) {
    //         switch (event.type) {
    //             .quit => running = false,
    //             else => {},
    //         }
    //     }
    // }

    //while (!window.should_close()) {
    //    if (window.should_resize()) {
    //        const new_dim = window.try_resize() catch |err| {
    //            log.err("Failed to resize window: {s}", .{@errorName(err)});
    //            return;
    //        };
    //        _ = new_dim;
    // TODO: renderer.resize()
    //    }
    //    break; // FIXME:

    // TODO: draw

    // TODO: pollEvents and handle them such as input, audio etc...
    //}

}
