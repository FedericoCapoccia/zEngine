const std = @import("std");

const Window = @import("window.zig").Window;
const Renderer = @import("renderer.zig").Renderer;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    window: Window = undefined,
    renderer: Renderer = undefined,

    pub fn init(engine: *Engine) !void {
        std.log.info("Initializing engine", .{});

        engine.window = Window.init(800, 600, "zEngine") catch |err| {
            std.log.err("Failed to initialize window: {s}", .{@errorName(err)});
            return error.WindowCreationFailed;
        };
        errdefer engine.window.shutdown();
        engine.window.setTitle("Hello");

        engine.renderer = Renderer.new(engine.allocator, &engine.window) catch |err| {
            std.log.err("Failed to initialize renderer: {s}", .{@errorName(err)});
            return error.RendererCreationFailed;
        };
        errdefer engine.renderer.shutdown();

        engine.window.show();
    }

    pub fn shutdown(self: *Engine) void {
        std.log.info("Shutting down engine", .{});
        self.renderer.shutdown();
        self.window.shutdown();
    }
};
