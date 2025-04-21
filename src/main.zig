const std = @import("std");

const c = @import("clibs.zig").c;

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

    while (!engine.window.shouldClose()) {
        @import("window.zig").Window.pollEvents();

        // var show_demo_window: bool = true;

        {
            var open = true;
            // Imgui frame
            c.cImGui_ImplVulkan_NewFrame();
            c.cImGui_ImplGlfw_NewFrame();
            c.ImGui_NewFrame();
            c.ImGui_ShowDemoWindow(&open);

            c.ImGui_Render();
        }

        engine.renderer.draw() catch |err| {
            std.log.err("Failed to draw: {s}", .{@errorName(err)});
        };
    }
}
