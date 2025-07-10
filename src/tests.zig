//! Run tests with zig build test
//! SPDX-License-Identifier: MIT

const std = @import("std");
const zigfsm = @import("zigfsm");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

// Demonstrates that triggering a single "click" event can perpetually cycle through intensity states.
test "moore machine: three-level intensity light" {
    // A state machine type is defined using state enums and, optionally, event enums.
    // An event takes the state machine from one state to another, but you can also switch to
    // other states without using events.
    //
    // State and event enums can be explicit enum types, comptime generated enums, or
    // anonymous enums like in this example.
    //
    // If you don't want to use events, simply pass null to the second argument.
    // We also define what state is the initial one, in this case .off
    var fsm = zigfsm.StateMachine(enum { off, dim, medium, bright }, enum { click }, .off).init();

    try fsm.addEventAndTransition(.click, .off, .dim);
    try fsm.addEventAndTransition(.click, .dim, .medium);
    try fsm.addEventAndTransition(.click, .medium, .bright);
    try fsm.addEventAndTransition(.click, .bright, .off);

    // Do a full cycle of off -> dim -> medium -> bright -> off

    try expect(fsm.isCurrently(.off));

    _ = try fsm.do(.click);
    try expect(fsm.isCurrently(.dim));

    _ = try fsm.do(.click);
    try expect(fsm.isCurrently(.medium));

    _ = try fsm.do(.click);
    try expect(fsm.isCurrently(.bright));

    _ = try fsm.do(.click);
    try expect(fsm.isCurrently(.off));

    // Make sure we're in a good state
    try expect(fsm.canTransitionTo(.dim));
    try expect(!fsm.canTransitionTo(.medium));
    try expect(!fsm.canTransitionTo(.bright));
    try expect(!fsm.canTransitionTo(.off));

    // Uncomment to generate a Graphviz diagram
    // try fsm.exportGraphviz("lights", std.io.getStdOut().writer(), .{.layout = "circo", .shape = "box"});
}

test "minimal without event" {
    const State = enum { on, off };
    var fsm = zigfsm.StateMachine(State, null, .off).init();
    try fsm.addTransition(.on, .off);
    try fsm.addTransition(.off, .on);

    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);
}

test "comptime minimal without event" {
    comptime {
        const State = enum { on, off };
        var fsm = zigfsm.StateMachine(State, null, .off).init();
        try fsm.addTransition(.on, .off);
        try fsm.addTransition(.off, .on);

        try fsm.transitionTo(.on);
        try expectEqual(fsm.currentState(), .on);
    }
}

test "minimal with event" {
    const State = enum { on, off };
    const Event = enum { click };
    var fsm = zigfsm.StateMachine(State, Event, .off).init();
    try fsm.addTransition(.on, .off);
    try fsm.addTransition(.off, .on);
    try fsm.addEvent(.click, .on, .off);
    try fsm.addEvent(.click, .off, .on);

    // Transition manually
    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);

    // Transition through an event
    _ = try fsm.do(.click);
    try expectEqual(fsm.currentState(), .off);
}

test "minimal with event defined using a table" {
    const State = enum { on, off };
    const Event = enum { click };
    const definition = [_]zigfsm.Transition(State, Event){
        .{ .event = .click, .from = .on, .to = .off },
        .{ .event = .click, .from = .off, .to = .on },
    };
    var fsm = zigfsm.StateMachineFromTable(State, Event, &definition, .off, &.{}).init();

    // Transition manually
    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);

    // Transition through an event
    _ = try fsm.do(.click);
    try expectEqual(fsm.currentState(), .off);
}

test "generate state enum" {
    // When you have a simple sequence of states, such as S0, S1, ... then you
    // can have zigfsm generate these for you, rather than manually creating
    // the enum. The same applies to events; see next test.
    // You can use any prefix; here we use S
    const State = zigfsm.GenerateConsecutiveEnum("S", 100);
    var fsm = zigfsm.StateMachine(State, null, .S0).init();
    try fsm.addTransition(.S0, .S1);
    try fsm.transitionTo(.S1);
    try expectEqual(fsm.currentState(), .S1);
}

test "generate state enum and event enum" {
    // Generate state enums, S0, S1, ...
    const State = zigfsm.GenerateConsecutiveEnum("S", 100);

    // We also generate event enums, E0, E1, ...
    const Event = zigfsm.GenerateConsecutiveEnum("E", 100);

    // Initialize the state machine in state S0
    var fsm = zigfsm.StateMachine(State, Event, .S0).init();

    // When event E0 happens when in state S0, go to state S1
    try fsm.addEventAndTransition(.E0, .S0, .S1);
    _ = try fsm.do(.E0);

    // Make sure we're in the correct state after the event fired
    try expectEqual(fsm.currentState(), .S1);
}

test "check state" {
    const State = enum { start, stop };
    const FSM = zigfsm.StateMachine(State, null, .start);

    var fsm = FSM.init();
    try fsm.addTransition(.start, .stop);
    try fsm.addFinalState(.stop);

    try expect(fsm.isFinalState(.stop));
    try expect(fsm.isInStartState());
    try expect(fsm.isCurrently(.start));
    try expect(!fsm.isInFinalState());

    try fsm.transitionTo(.stop);
    try expect(fsm.isCurrently(.stop));
    try expectEqual(fsm.currentState(), .stop);
    try expect(fsm.isInFinalState());
}

// Implements https://en.wikipedia.org/wiki/Deterministic_finite_automaton#Example
// Comptime state machines finally works in stage2, see https://github.com/ziglang/zig/issues/10694
test "comptime dfa: binary alphabet, require even number of zeros in input" {
    comptime {
        @setEvalBranchQuota(10_000);

        // Note that both "start: S1;" and "start: -> S1;" syntaxes work, same with end:
        const input =
            \\ S1 -> S2 [label = "0"];
            \\ S2 -> S1 [label = "0"];
            \\ S1 -> S1 [label = "1"];
            \\ S2 -> S2 [label = "1"];
            \\ start: S1;
            \\ end: S1;
        ;

        const State = enum { S1, S2 };
        const Bit = enum { @"0", @"1" };
        var fsm = zigfsm.StateMachine(State, Bit, .S1).init();
        try fsm.importText(input);

        // With valid input, we wil end up in the final state
        const valid_input: []const Bit = &.{ .@"0", .@"0", .@"1", .@"1" };
        for (valid_input) |bit| _ = try fsm.do(bit);
        try expect(fsm.isInFinalState());

        // With invalid input, we will not end up in the final state
        const invalid_input: []const Bit = &.{ .@"0", .@"0", .@"0", .@"1" };
        for (invalid_input) |bit| _ = try fsm.do(bit);
        try expect(!fsm.isInFinalState());
    }
}

// Simple CSV parser based on the state model in https://ppolv.wordpress.com/2008/02/25/parsing-csv-in-erlang
// The main idea is that we classify incoming characters as InputEvent's. When a character arrives, we
// simply trigger the event. If the input is well-formed, we automatically move to the appropriate state.
// To actually extract CSV fields, we use a transition handler to keep track of where field slices starts and ends.
// If the input is incorrect we have detailed information about where it happens, and why based on states and events.
test "csv parser" {
    const State = enum { field_start, unquoted, quoted, post_quoted, done };
    const InputEvent = enum { char, quote, whitespace, comma, newline, anything_not_quote, eof };

    // Intentionally badly formatted csv to exercise corner cases
    const csv_input =
        \\"first",second,"third",4
        \\  "more", right, here, 5
        \\  1,,b,c
    ;

    const FSM = zigfsm.StateMachine(State, InputEvent, .field_start);

    const Parser = struct {
        handler: FSM.Handler,
        fsm: *FSM,
        csv: []const u8,
        cur_field_start: usize,
        cur_index: usize,
        line: usize = 0,
        col: usize = 0,

        const expected_parse_result: [3][4][]const u8 = .{
            .{ "\"first\"", "second", "\"third\"", "4" },
            .{ "\"more\"", "right", "here", "5" },
            .{ "1", "", "b", "c" },
        };

        pub fn parse(fsm: *FSM, csv: []const u8) !void {
            var instance: @This() = .{
                .handler = zigfsm.Interface.make(FSM.Handler, @This()),
                .fsm = fsm,
                .csv = csv,
                .cur_field_start = 0,
                .cur_index = 0,
                .line = 0,
                .col = 0,
            };
            instance.fsm.setTransitionHandlers(&.{&instance.handler});
            try instance.read();
        }

        /// Feeds the input stream through the state machine
        fn read(self: *@This()) !void {
            var stream = std.io.fixedBufferStream(self.csv);
            const reader = stream.reader();
            while (true) : (self.cur_index += 1) {
                const input = reader.readByte() catch {
                    // An example of how to handle parsing errors
                    _ = self.fsm.do(.eof) catch {
                        std.debug.print("Unexpected end of stream\n", .{});
                    };
                    return;
                };

                // The order of checks is important to classify input correctly
                if (self.fsm.isCurrently(.quoted) and input != '"') {
                    _ = try self.fsm.do(.anything_not_quote);
                } else if (input == '\n') {
                    _ = try self.fsm.do(.newline);
                } else if (std.ascii.isWhitespace(input)) {
                    _ = try self.fsm.do(.whitespace);
                } else if (input == ',') {
                    _ = try self.fsm.do(.comma);
                } else if (input == '"') {
                    _ = try self.fsm.do(.quote);
                } else if (std.ascii.isPrint(input)) {
                    _ = try self.fsm.do(.char);
                }
            }
        }

        /// We use state transitions to extract CSV field slices, and we're not using any extra memory.
        /// Note that the transition handler must be public.
        pub fn onTransition(handler: *FSM.Handler, event: ?InputEvent, from: State, to: State) zigfsm.HandlerResult {
            const self = zigfsm.Interface.downcast(@This(), handler);

            const fields_per_row = 4;

            // Start of a field
            if (from == .field_start) {
                self.cur_field_start = self.cur_index;
            }

            // End of a field
            if (to != from and (from == .unquoted or from == .post_quoted)) {
                const found_field = std.mem.trim(u8, self.csv[self.cur_field_start..self.cur_index], " ");

                std.testing.expectEqualSlices(u8, found_field, expected_parse_result[self.line][self.col]) catch unreachable;
                self.col = (self.col + 1) % fields_per_row;
            }

            // Empty field
            if (event.? == .comma and self.cur_field_start == self.cur_index) {
                self.col = (self.col + 1) % fields_per_row;
            }

            if (event.? == .newline) {
                self.line += 1;
            }

            return zigfsm.HandlerResult.Continue;
        }
    };

    var fsm = FSM.init();
    try fsm.addEventAndTransition(.whitespace, .field_start, .field_start);
    try fsm.addEventAndTransition(.whitespace, .unquoted, .unquoted);
    try fsm.addEventAndTransition(.whitespace, .post_quoted, .post_quoted);
    try fsm.addEventAndTransition(.char, .field_start, .unquoted);
    try fsm.addEventAndTransition(.char, .unquoted, .unquoted);
    try fsm.addEventAndTransition(.quote, .field_start, .quoted);
    try fsm.addEventAndTransition(.quote, .quoted, .post_quoted);
    try fsm.addEventAndTransition(.anything_not_quote, .quoted, .quoted);
    try fsm.addEventAndTransition(.comma, .post_quoted, .field_start);
    try fsm.addEventAndTransition(.comma, .unquoted, .field_start);
    try fsm.addEventAndTransition(.comma, .field_start, .field_start);
    try fsm.addEventAndTransition(.newline, .post_quoted, .field_start);
    try fsm.addEventAndTransition(.newline, .unquoted, .field_start);
    try fsm.addEventAndTransition(.eof, .unquoted, .done);
    try fsm.addEventAndTransition(.eof, .quoted, .done);
    try fsm.addFinalState(.done);

    try Parser.parse(&fsm, csv_input);
    try expect(fsm.isInFinalState());

    // Uncomment to generate a Graphviz diagram
    // try fsm.exportGraphviz("csv", std.io.getStdOut().writer(), .{.shape = "box", .shape_final_state = "doublecircle", .show_initial_state=true});
}

// An alternative to the "csv parser" test using do(...) return values rather than transition callbacks
test "csv parser, without handler callback" {
    const State = enum { field_start, unquoted, quoted, post_quoted, done };
    const InputEvent = enum { char, quote, whitespace, comma, newline, anything_not_quote, eof };

    // Intentionally badly formatted csv to exercise corner cases
    const csv_input =
        \\"first",second,"third",4
        \\  "more", right, here, 5
        \\  1,,b,c
    ;

    const FSM = zigfsm.StateMachine(State, InputEvent, .field_start);

    const Parser = struct {
        fsm: *FSM,
        csv: []const u8,
        cur_field_start: usize,
        cur_index: usize,
        line: usize = 0,
        col: usize = 0,

        const expected_parse_result: [3][4][]const u8 = .{
            .{ "\"first\"", "second", "\"third\"", "4" },
            .{ "\"more\"", "right", "here", "5" },
            .{ "1", "", "b", "c" },
        };

        pub fn parse(fsm: *FSM, csv: []const u8) !void {
            var instance: @This() = .{
                .fsm = fsm,
                .csv = csv,
                .cur_field_start = 0,
                .cur_index = 0,
                .line = 0,
                .col = 0,
            };
            try instance.read();
        }

        /// Feeds the input stream through the state machine
        fn read(self: *@This()) !void {
            var stream = std.io.fixedBufferStream(self.csv);
            const reader = stream.reader();
            while (true) : (self.cur_index += 1) {
                const input = reader.readByte() catch {
                    // An example of how to handle parsing errors
                    _ = self.fsm.do(.eof) catch {
                        std.debug.print("Unexpected end of stream\n", .{});
                    };
                    return;
                };

                // Holds from/to/event if a transition is triggered
                var maybe_transition: ?zigfsm.Transition(State, InputEvent) = null;

                // The order of checks is important to classify input correctly
                if (self.fsm.isCurrently(.quoted) and input != '"') {
                    maybe_transition = try self.fsm.do(.anything_not_quote);
                } else if (input == '\n') {
                    maybe_transition = try self.fsm.do(.newline);
                } else if (std.ascii.isWhitespace(input)) {
                    maybe_transition = try self.fsm.do(.whitespace);
                } else if (input == ',') {
                    maybe_transition = try self.fsm.do(.comma);
                } else if (input == '"') {
                    maybe_transition = try self.fsm.do(.quote);
                } else if (std.ascii.isPrint(input)) {
                    maybe_transition = try self.fsm.do(.char);
                }

                if (maybe_transition) |transition| {
                    const fields_per_row = 4;

                    // Start of a field
                    if (transition.from == .field_start) {
                        self.cur_field_start = self.cur_index;
                    }

                    // End of a field
                    if (transition.to != transition.from and (transition.from == .unquoted or transition.from == .post_quoted)) {
                        const found_field = std.mem.trim(u8, self.csv[self.cur_field_start..self.cur_index], " ");

                        std.testing.expectEqualSlices(u8, found_field, expected_parse_result[self.line][self.col]) catch unreachable;
                        self.col = (self.col + 1) % fields_per_row;
                    }

                    // Empty field
                    if (transition.event.? == .comma and self.cur_field_start == self.cur_index) {
                        self.col = (self.col + 1) % fields_per_row;
                    }

                    if (transition.event.? == .newline) {
                        self.line += 1;
                    }
                }
            }
        }
    };

    var fsm = FSM.init();
    try fsm.addEventAndTransition(.whitespace, .field_start, .field_start);
    try fsm.addEventAndTransition(.whitespace, .unquoted, .unquoted);
    try fsm.addEventAndTransition(.whitespace, .post_quoted, .post_quoted);
    try fsm.addEventAndTransition(.char, .field_start, .unquoted);
    try fsm.addEventAndTransition(.char, .unquoted, .unquoted);
    try fsm.addEventAndTransition(.quote, .field_start, .quoted);
    try fsm.addEventAndTransition(.quote, .quoted, .post_quoted);
    try fsm.addEventAndTransition(.anything_not_quote, .quoted, .quoted);
    try fsm.addEventAndTransition(.comma, .post_quoted, .field_start);
    try fsm.addEventAndTransition(.comma, .unquoted, .field_start);
    try fsm.addEventAndTransition(.comma, .field_start, .field_start);
    try fsm.addEventAndTransition(.newline, .post_quoted, .field_start);
    try fsm.addEventAndTransition(.newline, .unquoted, .field_start);
    try fsm.addEventAndTransition(.eof, .unquoted, .done);
    try fsm.addEventAndTransition(.eof, .quoted, .done);
    try fsm.addFinalState(.done);

    try Parser.parse(&fsm, csv_input);
    try expect(fsm.isInFinalState());

    // Uncomment to generate a Graphviz diagram
    // try fsm.exportGraphviz("csv", std.io.getStdOut().writer(), .{.shape = "box", .shape_final_state = "doublecircle", .show_initial_state=true});
}

test "handler that cancels" {
    const State = enum { on, off };
    const Event = enum { click };
    const FSM = zigfsm.StateMachine(State, Event, .off);
    var fsm = FSM.init();

    // Demonstrates how to manage extra state (in this case a simple counter) while reacting
    // to transitions. Once the counter reaches 3, it cancels any further transitions. Real-world
    // handlers typically check from/to states and perhaps even which event (if any) caused the
    // transition.
    const CountingHandler = struct {
        // The handler must be the first field
        handler: FSM.Handler,
        counter: usize,

        pub fn init() @This() {
            return .{
                .handler = zigfsm.Interface.make(FSM.Handler, @This()),
                .counter = 0,
            };
        }

        pub fn onTransition(handler: *FSM.Handler, event: ?Event, from: State, to: State) zigfsm.HandlerResult {
            _ = &.{ from, to, event };
            const self = zigfsm.Interface.downcast(@This(), handler);
            self.counter += 1;
            return if (self.counter < 3) zigfsm.HandlerResult.Continue else zigfsm.HandlerResult.Cancel;
        }
    };

    var countingHandler = CountingHandler.init();
    fsm.setTransitionHandlers(&.{&countingHandler.handler});
    try fsm.addEventAndTransition(.click, .on, .off);
    try fsm.addEventAndTransition(.click, .off, .on);

    _ = try fsm.do(.click);
    _ = try fsm.do(.click);

    // Third time will fail
    try expectError(zigfsm.StateError.Canceled, fsm.do(.click));
}

test "import: graphviz" {
    const input =
        \\digraph parser_example {
        \\    rankdir=LR;
        \\    node [shape = doublecircle fixedsize = false]; 3  4  8 ;
        \\    node [shape = circle fixedsize = false];
        \\    start: -> 0;
        \\    0 -> 2 [label = "SS(B)"];
        \\    0 -> 1 [label = "SS(S)"];
        \\    1 -> 3 [label = "S($end)"];
        \\    2 -> 6 [label = "SS(b)"];
        \\    2 -> 5 [label = "SS(a)"];
        \\    2 -> 4 [label = "S(A)"];
        \\    5 -> 7 [label = "S(b)"];
        \\    5 -> 5 [label = "S(a)"];
        \\    6 -> 6 [label = "S(b)"];
        \\    6 -> 5 [label = "S(a)"];
        \\    7 -> 8 [label = "S(b)"];
        \\    7 -> 5 [label = "S(a)"];
        \\    8 -> 6 [label = "S(b)"];
        \\    8 -> 5 [label = "S(a) || extra"];
        \\}
    ;

    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Event = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var fsm = zigfsm.StateMachine(State, Event, .@"0").init();
    try fsm.importText(input);

    try fsm.apply(.{ .event = .@"SS(B)" });
    try expectEqual(fsm.currentState(), .@"2");
    try fsm.transitionTo(.@"6");
    try expectEqual(fsm.currentState(), .@"6");
    // Self-transition
    _ = try fsm.do(.@"S(b)");
    try expectEqual(fsm.currentState(), .@"6");
}

test "import: libfsm text" {
    const input =
        \\ 1 -> 2 "a";
        \\ 2 -> 3 "a";
        \\ 3 -> 4 "b";
        \\ 4 -> 5 "b";
        \\ 5 -> 1 'c';
        \\ "1" -> "3" 'c';
        \\ 3 -> 5 'c';
        \\ start: 1;
        \\ end: 3, 4, 5;
    ;

    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5" };
    const Event = enum { a, b, c };

    var fsm = zigfsm.StateMachine(State, Event, .@"0").init();
    try fsm.importText(input);

    try expectEqual(fsm.currentState(), .@"1");
    try fsm.transitionTo(.@"2");
    try expectEqual(fsm.currentState(), .@"2");
    _ = try fsm.do(.a);
    try expectEqual(fsm.currentState(), .@"3");
    try expect(fsm.isInFinalState());
}

// Implements the state diagram example from the Graphviz docs
test "export: graphviz export of finite automaton sample" {
    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Event = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var fsm = zigfsm.StateMachine(State, Event, .@"0").init();
    try fsm.addTransition(State.@"0", State.@"2");
    try fsm.addTransition(State.@"0", State.@"1");
    try fsm.addTransition(State.@"1", State.@"3");
    try fsm.addTransition(State.@"2", State.@"6");
    try fsm.addTransition(State.@"2", State.@"5");
    try fsm.addTransition(State.@"2", State.@"4");
    try fsm.addTransition(State.@"5", State.@"7");
    try fsm.addTransition(State.@"5", State.@"5");
    try fsm.addTransition(State.@"6", State.@"6");
    try fsm.addTransition(State.@"6", State.@"5");
    try fsm.addTransition(State.@"7", State.@"8");
    try fsm.addTransition(State.@"7", State.@"5");
    try fsm.addTransition(State.@"8", State.@"6");
    try fsm.addTransition(State.@"8", State.@"5");

    try fsm.addFinalState(State.@"3");
    try fsm.addFinalState(State.@"4");
    try fsm.addFinalState(State.@"8");

    try fsm.addEvent(.@"SS(B)", .@"0", .@"2");
    try fsm.addEvent(.@"SS(S)", .@"0", .@"1");
    try fsm.addEvent(.@"S($end)", .@"1", .@"3");
    try fsm.addEvent(.@"SS(b)", .@"2", .@"6");
    try fsm.addEvent(.@"SS(a)", .@"2", .@"5");
    try fsm.addEvent(.@"S(A)", .@"2", .@"4");
    try fsm.addEvent(.@"S(b)", .@"5", .@"7");
    try fsm.addEvent(.@"S(a)", .@"5", .@"5");
    try fsm.addEvent(.@"S(b)", .@"6", .@"6");
    try fsm.addEvent(.@"S(a)", .@"6", .@"5");
    try fsm.addEvent(.@"S(b)", .@"7", .@"8");
    try fsm.addEvent(.@"S(a)", .@"7", .@"5");
    try fsm.addEvent(.@"S(b)", .@"8", .@"6");
    try fsm.addEvent(.@"S(a)", .@"8", .@"5");
    // This demonstrates that multiple events on the same transition are concatenated with ||
    try fsm.addEvent(.extra, .@"8", .@"5");

    var outbuf = std.ArrayList(u8).init(std.testing.allocator);
    defer outbuf.deinit();
    try fsm.exportGraphviz("parser_example", outbuf.writer(), .{});

    const target =
        \\digraph parser_example {
        \\    rankdir=LR;
        \\    node [shape = doublecircle fixedsize = false]; "3"  "4"  "8" ;
        \\    node [shape = circle fixedsize = false];
        \\    "0" -> "1" [label = "SS(S)"];
        \\    "0" -> "2" [label = "SS(B)"];
        \\    "1" -> "3" [label = "S($end)"];
        \\    "2" -> "4" [label = "S(A)"];
        \\    "2" -> "5" [label = "SS(a)"];
        \\    "2" -> "6" [label = "SS(b)"];
        \\    "5" -> "5" [label = "S(a)"];
        \\    "5" -> "7" [label = "S(b)"];
        \\    "6" -> "5" [label = "S(a)"];
        \\    "6" -> "6" [label = "S(b)"];
        \\    "7" -> "5" [label = "S(a)"];
        \\    "7" -> "8" [label = "S(b)"];
        \\    "8" -> "5" [label = "S(a) || extra"];
        \\    "8" -> "6" [label = "S(b)"];
        \\}
        \\
    ;

    try expectEqualSlices(u8, target[0..], outbuf.items[0..]);
}

test "finite state automaton for accepting a 25p car park charge (from Computers Without Memory - Computerphile)" {
    const state_machine =
        \\ sum0  ->  sum5   p5
        \\ sum0  ->  sum10  p10
        \\ sum0  ->  sum20  p20
        \\ sum5  ->  sum10  p5
        \\ sum5  ->  sum15  p10
        \\ sum5  ->  sum25  p20
        \\ sum10 ->  sum15  p5
        \\ sum10 ->  sum20  p10
        \\ sum15 ->  sum20  p5
        \\ sum15 ->  sum25  p10
        \\ sum20 ->  sum25  p5
        \\ start: sum0
        \\ end: sum25
    ;

    const Sum = enum { sum0, sum5, sum10, sum15, sum20, sum25 };
    const Coin = enum { p5, p10, p20 };
    var fsm = zigfsm.StateMachine(Sum, Coin, .sum0).init();
    try fsm.importText(state_machine);

    // Add 5p, 10p and 10p coins
    _ = try fsm.do(.p5);
    _ = try fsm.do(.p10);
    _ = try fsm.do(.p10);

    // Car park charge reached
    try expect(fsm.isInFinalState());

    // Verify that we're unable to accept more coins
    try expectError(zigfsm.StateError.Invalid, fsm.do(.p10));

    // Restart the state machine and try a different combination to reach 25p
    fsm.restart();
    _ = try fsm.do(.p20);
    _ = try fsm.do(.p5);
    try expect(fsm.isInFinalState());

    // Same as restart(), but makes sure we're currently in the start state or a final state
    try fsm.safeRestart();
    _ = try fsm.do(.p10);
    try expectError(zigfsm.StateError.Invalid, fsm.safeRestart());
    _ = try fsm.do(.p5);
    _ = try fsm.do(.p5);
    _ = try fsm.do(.p5);
    try expect(fsm.isInFinalState());
}

test "iterate next valid states" {
    const state_machine =
        \\ sum0  ->  sum5   p5
        \\ sum0  ->  sum10  p10
        \\ sum0  ->  sum20  p20
        \\ sum5  ->  sum10  p5
        \\ sum5  ->  sum15  p10
        \\ sum5  ->  sum25  p20
        \\ sum10 ->  sum15  p5
        \\ sum10 ->  sum20  p10
        \\ sum15 ->  sum20  p5
        \\ sum15 ->  sum25  p10
        \\ sum20 ->  sum25  p5
        \\ start: sum0
        \\ end: sum25
    ;

    const Sum = enum { sum0, sum5, sum10, sum15, sum20, sum25 };
    const Coin = enum { p5, p10, p20 };
    var fsm = zigfsm.StateMachine(Sum, Coin, .sum0).init();
    try fsm.importText(state_machine);

    var next_valid_iterator = fsm.validNextStatesIterator();
    try expectEqual(Sum.sum5, next_valid_iterator.next().?);
    try expectEqual(Sum.sum10, next_valid_iterator.next().?);
    try expectEqual(Sum.sum20, next_valid_iterator.next().?);
    try expectEqual(next_valid_iterator.next(), null);
}

// You don't actually need to define the state and event enums manually, but
// rather generate them at compile-time from a string or embedded text file.
//
// A downside is that editors are unlikely to autocomplete generated types
test "iterate next valid states, using state machine with generated enums" {
    const state_machine =
        \\ sum0  ->  sum5   p5
        \\ sum0  ->  sum10  p10
        \\ sum0  ->  sum20  p20
        \\ sum5  ->  sum10  p5
        \\ sum5  ->  sum15  p10
        \\ sum5  ->  sum25  p20
        \\ sum10 ->  sum15  p5
        \\ sum10 ->  sum20  p10
        \\ sum15 ->  sum20  p5
        \\ sum15 ->  sum25  p10
        \\ sum20 ->  sum25  p5
        \\ start: sum0
        \\ end: sum25
    ;

    var fsm = try zigfsm.instanceFromText(state_machine);
    const State = @TypeOf(fsm).StateEnum;
    _ = @TypeOf(fsm).EventEnum;

    var next_valid_iterator = fsm.validNextStatesIterator();
    try expectEqual(State.sum5, next_valid_iterator.next().?);
    try expectEqual(State.sum10, next_valid_iterator.next().?);
    try expectEqual(State.sum20, next_valid_iterator.next().?);
    try expectEqual(next_valid_iterator.next(), null);
}

// A simple push-down automaton to reliably return from jumping
// to the original standing or crouching state. Double-jumps
// leads to flying.
///
// In this example, we have a simple do/undo API. In a real-world app,
// a pushdown-automaton can obviously have any API suitable for
// the situation.
const GameState = struct {
    fsm: FSM,
    stack: std.ArrayList(FSM.StateEnum),

    const FSM = zigfsm.StateMachine(
        enum { standing, crouching, jumping, flying },
        enum { walk, jump },
        .standing,
    );

    pub fn init() !GameState {
        var state = GameState{
            .fsm = FSM.init(),
            .stack = std.ArrayList(FSM.StateEnum).init(std.testing.allocator),
        };

        // Event-triggered transitions
        try state.fsm.addEventAndTransition(.jump, .standing, .jumping);
        try state.fsm.addEventAndTransition(.jump, .crouching, .jumping);
        try state.fsm.addEventAndTransition(.jump, .jumping, .flying);

        // The valid undo-transitions for the push-down automaton
        try state.fsm.addTransition(.flying, .jumping);
        try state.fsm.addTransition(.jumping, .standing);
        try state.fsm.addTransition(.jumping, .crouching);
        return state;
    }

    pub fn deinit(self: *GameState) void {
        self.stack.deinit();
    }

    // Trigger an undoable event
    pub fn do(self: *GameState, event: FSM.EventEnum) !zigfsm.Transition(FSM.StateEnum, FSM.EventEnum) {
        try self.stack.append(self.fsm.currentState());
        return try self.fsm.do(event);
    }

    // Pops from the state stack and transitions to it. Returns true if stack had at least one state.
    pub fn undo(self: *GameState) !bool {
        if (self.stack.pop()) |state| {
            try self.fsm.transitionTo(state);
            return true;
        } else return false;
    }
};

test "push-down automaton game: standing -> jumping -> standing" {
    var state = try GameState.init();
    defer state.deinit();

    // We can jump whether we're standing or crouching
    _ = try state.do(.jump);
    std.debug.assert(state.fsm.isCurrently(.jumping));

    // Go back to previous state from jumping
    _ = try state.undo();
    std.debug.assert(state.fsm.isCurrently(.standing));
}

test "push-down automaton game: crouching -> jumping -> flying -> jumping -> croaching" {
    var state = try GameState.init();
    defer state.deinit();

    // Next sequence is: crouching -> jumping -> flying -> jumping -> croaching
    state.fsm.setStartState(.crouching);

    // Double jump to start flying
    _ = try state.do(.jump);
    _ = try state.do(.jump);
    std.debug.assert(state.fsm.isCurrently(.flying));

    // Go back to previous state from jumping
    _ = try state.undo();
    std.debug.assert(state.fsm.isCurrently(.jumping));
    _ = try state.undo();
    std.debug.assert(state.fsm.isCurrently(.crouching));
}

test {
    std.testing.refAllDecls(@This());
}
