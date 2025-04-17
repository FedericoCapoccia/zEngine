const std = @import("std");

const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;

pub const Engine = struct {
    allocator: *const std.mem.Allocator,
    window: Window = undefined,
    renderer: Renderer = undefined,

    pub fn init(engine: *Engine) !void {
        std.log.info("Initializing engine", .{});
        Window.init(&engine.window, 800, 600, "zEngine") catch |err| {
            std.log.err("Failed to initialize window: {s}", .{@errorName(err)});
            return error.WindowCreationFailed;
        };
    }

    pub fn shutdown(self: *const Engine) void {
        std.log.info("Shutting down engine", .{});
        self.window.shutdown();
    }
};
