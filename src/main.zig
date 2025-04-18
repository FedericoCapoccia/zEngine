const std = @import("std");

const c = @import("c").c;

const Engine = @import("engine.zig").Engine;
const log_fn = @import("log.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_fn.myLogFn,
};

var resize_requested: bool = false;
fn onResize(window: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
    resize_requested = true;
    _ = window;
    _ = width;
    _ = height;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) std.log.err("Leaked memory", .{});

    var engine = Engine{ .allocator = allocator };
    try Engine.init(&engine);
    defer engine.shutdown();

    _ = c.glfwSetFramebufferSizeCallback(engine.window.handle, onResize);

    while (c.glfwWindowShouldClose(engine.window.handle) == 0) {
        if (resize_requested) {
            engine.renderer.resize() catch |err| {
                std.log.err("Failed to resize: {s}", .{@errorName(err)});
                return err;
            };
            resize_requested = false;
        }

        c.glfwPollEvents();

        engine.renderer.draw() catch |err| {
            std.log.err("Failed to draw: {s}", .{@errorName(err)});
        };
    }
}
