const std = @import("std");

pub const Timer = struct {
    const FPS_CAPTURE_FRAMES_COUNT: u32 = 30;
    const FPS_AVERAGE_TIME_SECONDS: f64 = 0.5;
    const FPS_STEP = FPS_AVERAGE_TIME_SECONDS / @as(f64, FPS_CAPTURE_FRAMES_COUNT);

    timer: std.time.Timer = undefined,
    current: f64 = 0,
    previous: f64 = 0,
    update: f64 = 0,
    draw: f64 = 0,
    target: f64 = 0,
    frame: f64 = 0,
    frame_counter: u32 = 0,

    //FPS stuff
    _fps_index: u32 = 0,
    _fps_history: [FPS_CAPTURE_FRAMES_COUNT]f64 = .{0} ** FPS_CAPTURE_FRAMES_COUNT,
    _fps_average: f64 = 0,
    _fps_last: f64 = 0,

    pub fn new() !Timer {
        const timer = try std.time.Timer.start();
        return Timer{
            .timer = timer,
        };
    }

    // return the current time in seconds
    pub fn getTime(self: *Timer) f64 {
        const now: f64 = @floatFromInt(self.timer.read());
        return now / std.time.ns_per_s;
    }

    // Calculate dt of the update step, update internal state and returns it
    pub fn trackUpdate(self: *Timer) f64 {
        self.current = self.getTime();
        self.update = self.current - self.previous;
        self.previous = self.current;
        return self.update;
    }

    // Calculate dt of the draw step, update internal state and returns it
    pub fn trackDraw(self: *Timer) f64 {
        self.current = self.getTime();
        self.draw = self.current - self.previous;
        self.previous = self.current;
        return self.draw;
    }

    pub fn computeFrametime(self: *Timer) void {
        self.frame = self.update + self.draw;
        self.frame_counter += 1;
    }

    pub fn getFrametimeInMs(self: *const Timer) f64 {
        return self.frame * std.time.ms_per_s;
    }

    pub fn getFrametimeInNs(self: *const Timer) f64 {
        return self.frame * std.time.ns_per_s;
    }

    pub fn getFPS(self: *Timer) u64 {
        const frametime = self.frame;

        if (self.frame_counter == 0) {
            self._fps_average = 0;
            self._fps_last = 0;
            self._fps_index = 0;
            for (0..FPS_CAPTURE_FRAMES_COUNT) |i| {
                self._fps_history[i] = 0;
            }
        }

        if (frametime == 0) return 0;

        if ((self.getTime() - self._fps_last) > FPS_STEP) {
            self._fps_last = self.getTime();
            self._fps_index = (self._fps_index + 1) % FPS_CAPTURE_FRAMES_COUNT;
            self._fps_average -= self._fps_history[self._fps_index];
            self._fps_history[self._fps_index] = frametime / FPS_CAPTURE_FRAMES_COUNT;
            self._fps_average += self._fps_history[self._fps_index];
        }

        const fps_float = std.math.round(1.0 / self._fps_average);
        return @intFromFloat(fps_float);
    }
};
