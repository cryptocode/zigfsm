const std = @import("std");
const zigfsm = @import("zigfsm");

// Run with `zig build benchmark`
pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const State = zigfsm.GenerateConsecutiveEnum("S", 20);
    const Event = zigfsm.GenerateConsecutiveEnum("T", 20);
    const defs = [_]zigfsm.Transition(State, Event){
        .{ .event = .T0, .from = .S0, .to = .S1 },
        .{ .event = .T0, .from = .S1, .to = .S0 },
        .{ .event = .T19, .from = .S0, .to = .S19 },
        .{ .event = .T19, .from = .S19, .to = .S0 },
    };

    const FSM = zigfsm.StateMachineFromTable(State, Event, &defs, .S0, &.{});
    var fsm = FSM.init();

    const start = std.Io.Timestamp.now(io, .awake);

    var iterations: usize = 0;
    const changes_per_iteration = 120;
    const max_iterations = 1_000_000;
    while (iterations < max_iterations) : (iterations += 1) {
        comptime var tc: usize = 0;
        // Test a mix of direct and event based transitions
        inline while (tc < changes_per_iteration / 8) : (tc += 1) {
            try fsm.transitionTo(.S1);
            try fsm.transitionTo(.S0);
            _ = try fsm.do(.T0);
            _ = try fsm.do(.T0);
            try fsm.transitionTo(.S1);
            try fsm.transitionTo(.S0);
            _ = try fsm.do(.T19);
            _ = try fsm.do(.T19);
        }
    }

    std.mem.doNotOptimizeAway(&iterations);
    const end = std.Io.Timestamp.now(io, .awake);

    const elapsed_microsec = @as(f64, @floatFromInt(start.durationTo(end).toNanoseconds())) / 1000;
    const rate = @as(f64, changes_per_iteration) * @as(f64, @floatFromInt(iterations)) / elapsed_microsec;

    std.debug.print("{d:.2} transitions per µs ({d:.2} nanoseconds on avg. per transition)\n", .{ rate, 1000 / rate });
}
