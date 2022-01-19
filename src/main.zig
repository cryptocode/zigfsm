const std = @import("std");

/// State transition errors
pub const StateError = error{
    /// Invalid transition
    Invalid,
    /// A state transition was canceled
    Canceled,
    /// A trigger or state transition has already been defined
    AlreadyDefined,
    /// Invalid input encountered while importing a state machine
    ImportError,
};

/// Transition handlers must return whether the transition should complete or be canceled.
/// This can be used for state transition guards, as well as logging and debugging.
pub const HandlerResult = enum {
    /// Continue with the transition
    Continue,
    /// Cancel the transition by returning StateError.Canceled
    Cancel,
    /// Cancel the transition without error
    CancelNoError,
};

/// Construct a state machine type given a state enum and an optional trigger enum
pub fn StateMachine(comptime StateType: type, comptime TriggerType: ?type) type {
    const StateTriggerSelector = enum { state, trigger };
    const TriggerTypeArg = if (TriggerType) |T| T else void;
    const StateTriggerUnion = union(StateTriggerSelector) {
        state: StateType,
        trigger: if (TriggerType) |T| T else void,
    };

    return struct {
        internal: struct {
            arena: std.heap.ArenaAllocator,
            start_state: StateType,
            current_state: StateType,
            state_map: std.AutoArrayHashMap(StateType, std.AutoArrayHashMap(StateType, void)),
            transition_handlers: std.ArrayList(*Handler),
            final_states: std.AutoArrayHashMap(StateType, void),
            triggers: if (TriggerType) |T| std.AutoArrayHashMap(StateType, std.AutoArrayHashMap(T, StateType)) else void,
        } = undefined,

        const Self = @This();

        /// Transition handler interface
        pub const Handler = struct {
            onTransition: fn (self: *Handler, trigger: ?TriggerTypeArg, from: StateType, to: StateType) HandlerResult,
        };

        /// Initialize a new state machine with the given initial state
        pub fn init(allocator: std.mem.Allocator, initial_state: StateType) !*Self {
            var instance = try allocator.create(Self);
            instance.internal.arena = std.heap.ArenaAllocator.init(allocator);
            instance.internal.start_state = initial_state;
            instance.internal.final_states = @TypeOf(instance.internal.final_states).init(instance.internal.arena.allocator());
            instance.internal.current_state = initial_state;
            instance.internal.state_map = @TypeOf(instance.internal.state_map).init(instance.internal.arena.allocator());
            instance.internal.transition_handlers = @TypeOf(instance.internal.transition_handlers).init(instance.internal.arena.allocator());
            if (TriggerType != null) instance.internal.triggers = @TypeOf(instance.internal.triggers).init(instance.internal.arena.allocator());
            return instance;
        }

        /// Cleans up all state machine resources
        pub fn deinit(self: *Self) void {
            var map_itr = self.internal.state_map.iterator();
            while (map_itr.next()) |kv| {
                kv.value_ptr.deinit();
            }
            self.internal.state_map.deinit();
            self.internal.transition_handlers.deinit();
            self.internal.arena.deinit();
            self.internal.arena.child_allocator.destroy(self);
        }

        /// Returns the current state
        pub fn currentState(self: *Self) StateType {
            return self.internal.current_state;
        }

        /// Final states are optional. Note that it's possible, and common, for transitions
        /// to exit final states during execution. It's up to the library user to check for
        /// any final state condition, using `isInFinalState()` or `currentState()`
        /// Returns `StateError.Invalid` if there exists transitions from the `final_state`
        pub fn addFinalState(self: *Self, final_state: StateType) !void {
            try self.internal.final_states.put(final_state, {});
        }

        /// Returns true if the state machine is in a final state
        pub fn isInFinalState(self: *Self) bool {
            return self.internal.final_states.contains(self.currentState());
        }

        /// Returns true if the argument is a final state. Note that FSMs allow transitions from
        /// final states as long as they eventuelly ends up in a final state. Hence, any final
        /// state logic must be implemented by the library user.
        pub fn isFinalState(self: *Self, state: StateType) bool {
            return self.internal.final_states.contains(state);
        }

        // Returns true if the current state is the start state
        pub fn isInStartState(self: *Self) bool {
            return self.internal.current_state == self.internal.start_state;
        }

        /// Invoke `handler` when a state transition happens
        pub fn addTransitionHandler(self: *Self, handler: *Handler) !void {
            try self.internal.transition_handlers.append(handler);
        }

        /// Add the transition `from` -> `to` if missing, and define a trigger for the transition
        pub fn addTriggerAndTransition(self: *Self, trigger: TriggerTypeArg, from: StateType, to: StateType) !void {
            if (comptime TriggerType != null) {
                if (!self.canTransitionFromTo(from, to)) try self.addTransition(from, to);
                try self.addTrigger(trigger, from, to);
            }
        }

        /// Check if the transition `from` -> `to` is valid and add the trigger for this transition
        pub fn addTrigger(self: *Self, trigger: TriggerTypeArg, from: StateType, to: StateType) !void {
            if (comptime TriggerType != null) {
                if (self.canTransitionFromTo(from, to)) {
                    if (!self.internal.triggers.contains(from)) {
                        try self.internal.triggers.put(from, std.AutoArrayHashMap(TriggerTypeArg, StateType).init(self.internal.arena.allocator()));
                    }
                    if (self.internal.triggers.getPtr(from).?.contains(trigger)) return StateError.AlreadyDefined;
                    try self.internal.triggers.getPtr(from).?.put(trigger, to);
                } else return StateError.Invalid;
            }
        }

        /// Trigger a transition
        /// Returns `StateError.Invalid` if the trigger is not defined for the current state
        pub fn activateTrigger(self: *Self, trigger: TriggerTypeArg) !void {
            if (comptime TriggerType != null) {
                const entry = self.internal.triggers.getPtr(self.internal.current_state);
                if (entry) |e| {
                    const trigger_entry = e.get(trigger);
                    if (trigger_entry) |to_state| {
                        try self.transitionToInternal(trigger, to_state);
                    } else return StateError.Invalid;
                } else return StateError.Invalid;
            }
        }

        /// Add a valid state transition
        /// Returns `StateError.AlreadyDefined` if the transition is already defined
        pub fn addTransition(self: *Self, from: StateType, to: StateType) !void {
            if (!self.internal.state_map.contains(from)) {
                try self.internal.state_map.put(from, std.AutoArrayHashMap(StateType, void).init(self.internal.arena.allocator()));
            }
            if (self.internal.state_map.getPtr(from).?.contains(to)) return StateError.AlreadyDefined;
            try self.internal.state_map.getPtr(from).?.put(to, .{});
        }

        /// Returns true if the current state is equal to `requested_state`
        pub fn isCurrently(self: *Self, requested_state: StateType) bool {
            return self.internal.current_state == requested_state;
        }

        /// Returns true if the transition is possible
        pub fn canTransitionTo(self: *Self, new_state: StateType) bool {
            var from = self.internal.state_map.get(self.currentState());
            return from.?.contains(new_state);
        }

        /// Returns true if the transition `from` -> `to` is possible
        pub fn canTransitionFromTo(self: *Self, from: StateType, to: StateType) bool {
            var from_state = self.internal.state_map.get(from);
            return from_state != null and from_state.?.contains(to);
        }

        /// If possible, transition from current state to `new_state`
        /// Returns `StateError.Invalid` if the transition is not allowed
        pub fn transitionTo(self: *Self, new_state: StateType) StateError!void {
            return self.transitionToInternal(null, new_state);
        }

        fn transitionToInternal(self: *Self, trigger: ?TriggerTypeArg, new_state: StateType) StateError!void {
            if (!self.canTransitionTo(new_state)) {
                return StateError.Invalid;
            }

            for (self.internal.transition_handlers.items) |handler| {
                switch (handler.onTransition(handler, trigger, self.currentState(), new_state)) {
                    .Cancel => return StateError.Canceled,
                    .CancelNoError => return,
                    else => {},
                }
            }

            self.internal.current_state = new_state;
        }

        /// Transition initiated by state or trigger
        /// Returns `StateError.Invalid` if the transition is not allowed
        pub fn apply(self: *Self, state_or_trigger: StateTriggerUnion) !void {
            if (state_or_trigger == StateTriggerSelector.state) {
                try self.transitionTo(state_or_trigger.state);
            } else if (TriggerType) |_| {
                try self.activateTrigger(state_or_trigger.trigger);
            }
        }

        /// Graphviz export options
        pub const ExportOptions = struct {
            rankdir: []const u8 = "LR",
            layout: ?[]const u8 = null,
            shape: []const u8 = "circle",
            shape_final_state: []const u8 = "doublecircle",
            fixed_shape_size: bool = false,
            show_triggers: bool = true,
            show_initial_state: bool = false,
        };

        /// Exports a Graphviz directed graph to the given writer
        pub fn exportGraphviz(self: *Self, title: []const u8, writer: anytype, options: ExportOptions) !void {
            try writer.print("digraph {s} {{\n", .{title});
            try writer.print("    rankdir=LR;\n", .{});
            if (options.layout) |layout| try writer.print("    layout={s};\n", .{layout});
            if (options.show_initial_state) try writer.print("    node [shape = point ]; __INITIAL;\n", .{});

            // Style for final states
            if (self.internal.final_states.count() > 0) {
                try writer.print("    node [shape = {s} fixedsize = {}];", .{ options.shape_final_state, options.fixed_shape_size });
                var final_it = self.internal.final_states.iterator();
                while (final_it.next()) |kv| {
                    try writer.print(" \"{s}\" ", .{@tagName(kv.key_ptr.*)});
                }

                try writer.print(";\n", .{});
            }

            // Default style
            try writer.print("    node [shape = {s} fixedsize = {}];\n", .{ options.shape, options.fixed_shape_size });

            if (options.show_initial_state) {
                try writer.print("    __INITIAL -> \"{s}\";\n", .{@tagName(self.internal.start_state)});
            }

            var it = self.internal.state_map.iterator();
            while (it.next()) |kv| {
                const from = kv.key_ptr.*;
                const targets = kv.value_ptr.*;
                var target_it = targets.iterator();
                while (target_it.next()) |tkv| {
                    const to = tkv.key_ptr.*;
                    try writer.print("    \"{s}\" -> \"{s}\"", .{ @tagName(from), @tagName(to) });

                    if (options.show_triggers and self.internal.triggers.contains(from)) {
                        var trigger_map = self.internal.triggers.getPtr(from).?;
                        var trigger_it = trigger_map.iterator();
                        var transition_name = std.ArrayList(u8).init(self.internal.arena.allocator());
                        while (trigger_it.next()) |trigger_kv| {
                            if (trigger_kv.value_ptr.* == to) {
                                if (transition_name.items.len == 0) {
                                    try writer.print(" [label = \"", .{});
                                }
                                if (transition_name.items.len > 0) {
                                    try transition_name.writer().print(" || ", .{});
                                }
                                try transition_name.writer().print("{s}", .{@tagName(trigger_kv.key_ptr.*)});
                            }
                        }
                        if (transition_name.items.len > 0) {
                            try writer.print("{s}\"]", .{transition_name.items[0..]});
                        }
                    }
                    try writer.print(";\n", .{});
                }
            }
            try writer.print("}}\n", .{});
        }

        /// Reads a state machine from a Graphviz file. Any existing states and triggers are preserved.
        /// Only simple `a -> b` and `a -> b [label="abc || xyz"]` lines are considered, where label
        /// names are considered a list of triggers separated by ||. The purpose of this is mainly to
        /// support a simple text format for defining state machines, not to be a full gv parser.
        /// Fails with `StateError.ImportError` and print to stderr if the input cannot be parsed.
        pub fn importGraphviz(self: *Self, reader: anytype) !void {
            var line_no: usize = 1;
            var line_buf: [1024]u8 = undefined;
            while (reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| switch (err) {
                error.StreamTooLong => blk: {
                    try reader.skipUntilDelimiterOrEof('\n');
                    break :blk &line_buf;
                },
                else => |e| return e,
            }) |line| {
                var parts = std.mem.split(u8, line, "->");
                var lhs = parts.next();
                var rest = parts.next();
                if (lhs != null and rest != null) {
                    var lhs_trimmed = std.mem.trim(u8, lhs.?, " \t\"");
                    if (std.mem.eql(u8, lhs_trimmed, "__INITIAL")) continue;
                    var rhs_parts = std.mem.split(u8, rest.?, "[");
                    var rhs = rhs_parts.next();
                    if (rhs == null) {
                        rhs_parts = std.mem.split(u8, rest.?, ";");
                        rhs = rhs_parts.next();
                    }

                    var rhs_trimmed = std.mem.trim(u8, rhs.?, " \t\";");
                    rhs_trimmed = std.mem.trim(u8, rhs_trimmed, " \t\";");
                    var label = rhs_parts.next();
                    var triggers = std.ArrayList([]const u8).init(self.internal.arena.allocator());
                    if (label) |lbl| {
                        var label_parts = std.mem.split(u8, lbl, "=");
                        _ = label_parts.next();
                        var trigger_part = label_parts.next();
                        trigger_part = std.mem.trim(u8, trigger_part.?, " \t\"];");
                        var trigger_itr = std.mem.split(u8, trigger_part.?, "||");
                        while (trigger_itr.next()) |trigger_name| {
                            var trigger_name_trimmed = std.mem.trim(u8, trigger_name, " ");
                            try triggers.append(trigger_name_trimmed);
                        }
                    }

                    var from_state = std.meta.stringToEnum(StateType, lhs_trimmed);
                    var to_state = std.meta.stringToEnum(StateType, rhs_trimmed);
                    if (from_state == null or to_state == null) {
                        try std.io.getStdErr().writer().print("Error while importing graphviz file: Invalid state enums '{s}' and '{s}' encountered at line {d}: {s}\n", .{ lhs_trimmed, rhs_trimmed, line_no, line });
                        return StateError.ImportError;
                    } else {
                        try self.addTransition(from_state.?, to_state.?);
                        if (TriggerType) |T| {
                            for (triggers.items) |tr| {
                                var trigger_enum = std.meta.stringToEnum(T, tr);
                                if (trigger_enum == null) {
                                    try std.io.getStdErr().writer().print("Error while importing graphviz file: Invalid trigger '{s}' at line {d}: {s}\n", .{ tr, line_no, line });
                                    return StateError.ImportError;
                                } else try self.addTrigger(trigger_enum.?, from_state.?, to_state.?);
                            }
                        }
                    }
                }
                line_no += 1;
            }
        }
    };
}

/// Helper type to make it easier to deal with polymorphic types
pub const Interface = struct {
    /// We establish the convention that the implementation type has the interface as the 
    /// first field, allowing a slightly less verbose interface idiom. This will not compile
    /// if there's a mismatch. When this convention doesn't work, use @fieldParentPtr directly.
    pub fn downcast(comptime Implementer: type, interface_ref: anytype) *Implementer {
        const field_name = comptime std.meta.fieldNames(Implementer).*[0];
        return @fieldParentPtr(Implementer, field_name, interface_ref);
    }

    /// Instantiates an interface type and populates its function pointers to point to 
    /// proper functions in the given implementer type.
    pub fn make(comptime InterfaceType: type, comptime Implementer: type) InterfaceType {
        var instance: InterfaceType = undefined;
        inline for (std.meta.fields(InterfaceType)) |f| {
            if (comptime std.meta.trait.hasFn(f.name[0..f.name.len])(Implementer)) {
                @field(instance, f.name) = @field(Implementer, f.name[0..f.name.len]);
            }
        }
        return instance;
    }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

test "minimal without trigger" {
    const State = enum { on, off };
    const FSM = StateMachine(State, null);

    var sm = try FSM.init(std.testing.allocator, .off);
    defer sm.deinit();
    try sm.addTransition(.on, .off);
    try sm.addTransition(.off, .on);

    try sm.transitionTo(.on);
    try expectEqual(sm.currentState(), .on);
}

test "minimal with trigger" {
    const State = enum { on, off };
    const Trigger = enum { click };
    const FSM = StateMachine(State, Trigger);

    var sm = try FSM.init(std.testing.allocator, .off);
    defer sm.deinit();
    try sm.addTransition(.on, .off);
    try sm.addTransition(.off, .on);
    try sm.addTrigger(.click, .on, .off);
    try sm.addTrigger(.click, .off, .on);

    // Transition manually
    try sm.transitionTo(.on);
    try expectEqual(sm.currentState(), .on);

    // Transition through a trigger (event)
    try sm.activateTrigger(.click);
    try expectEqual(sm.currentState(), .off);
}

test "check state" {
    const State = enum { start, stop };
    const FSM = StateMachine(State, null);

    var sm = try FSM.init(std.testing.allocator, .start);
    defer sm.deinit();
    try sm.addTransition(.start, .stop);
    try sm.addFinalState(.stop);

    try expect(sm.isFinalState(.stop));
    try expect(sm.isInStartState());
    try expect(sm.isCurrently(.start));
    try expect(!sm.isInFinalState());

    try sm.transitionTo(.stop);
    try expect(sm.isCurrently(.stop));
    try expectEqual(sm.currentState(), .stop);
    try expect(sm.isInFinalState());
}

// Simple CSV parser based on the state model in https://ppolv.wordpress.com/2008/02/25/parsing-csv-in-erlang
// The main idea is that we classify characters from the input into InputEvent. When a character arrives, we
// simply trigger the event. If the input is well-formed, we move to the appropriate state. To actually extract
// CSV fields, we use a transition handler to keep track of where field slices starts and ends. If the input is
// incorrect, we have detailed information about where it happens and why based on states and triggers.
test "csv parser" {
    const State = enum { field_start, unquoted, quoted, post_quoted, done };
    const InputEvent = enum { char, quote, whitespace, comma, newline, anything_not_quote, eof };

    // Intentionally badly formatted csv to exercise corner cases
    const csv_input =
        \\"first",second,"third",4 
        \\  "more", right, here, 5
        \\  1,,b,c
    ;

    const FSM = StateMachine(State, InputEvent);

    const Parser = struct {
        handler: FSM.Handler,
        fsm: *FSM,
        csv: []const u8,
        cur_field_start: usize,
        cur_index: usize,
        line: usize = 0,
        col: usize = 0,

        // : [3][4]u8 =
        const parse_result: [3][4][]const u8 = .{
            .{ "\"first\"", "second", "\"third\"", "4" },
            .{ "\"more\"", "right", "here", "5" },
            .{ "1", "", "b", "c" },
        };

        pub fn parse(fsm: *FSM, csv: []const u8) !void {
            var instance: @This() = .{
                .handler = Interface.make(FSM.Handler, @This()),
                .fsm = fsm,
                .csv = csv,
                .cur_field_start = 0,
                .cur_index = 0,
                .line = 0,
                .col = 0,
            };
            try instance.fsm.addTransitionHandler(&instance.handler);
            try instance.read();
        }

        /// Feeds the input stream through the state machine
        fn read(self: *@This()) !void {
            var reader = std.io.fixedBufferStream(self.csv).reader();
            while (true) : (self.cur_index += 1) {
                var input = reader.readByte() catch {
                    // An example of how to handle parsing errors
                    self.fsm.activateTrigger(.eof) catch {
                        try std.io.getStdErr().writer().print("Unexpected end of stream\n", .{});
                    };
                    return;
                };

                // The order is important to honor subsets. In this case, it's mainly
                // important to handle \n before whitespaces in general, as some state
                // transitions depend on it.
                if (self.fsm.isCurrently(.quoted) and input != '"') {
                    try self.fsm.activateTrigger(.anything_not_quote);
                } else if (input == '\n') {
                    try self.fsm.activateTrigger(.newline);
                } else if (std.ascii.isSpace(input)) {
                    try self.fsm.activateTrigger(.whitespace);
                } else if (input == ',') {
                    try self.fsm.activateTrigger(.comma);
                } else if (input == '"') {
                    try self.fsm.activateTrigger(.quote);
                } else if (std.ascii.isPrint(input)) {
                    try self.fsm.activateTrigger(.char);
                }
            }
        }

        /// We use state transitions to extract CSV field slices, so we're not using any extra memory.
        /// Note that the transition handler must be public.
        pub fn onTransition(handler: *FSM.Handler, trigger: ?InputEvent, from: State, to: State) HandlerResult {
            const self = Interface.downcast(@This(), handler);

            const fields_per_row = 4;

            // Start of a field
            if (from == .field_start) {
                self.cur_field_start = self.cur_index;
            }

            // End of a field
            if (to != from and (from == .unquoted or from == .post_quoted)) {
                const found_field = std.mem.trim(u8, self.csv[self.cur_field_start..self.cur_index], " ");

                std.testing.expectEqualSlices(u8, found_field, parse_result[self.line][self.col]) catch unreachable;
                self.col = (self.col + 1) % fields_per_row;
            }

            // Empty field
            if (trigger.? == .comma and self.cur_field_start == self.cur_index) {
                self.col = (self.col + 1) % fields_per_row;
            }

            if (trigger.? == .newline) {
                self.line += 1;
            }

            return HandlerResult.Continue;
        }
    };

    var sm = try FSM.init(std.testing.allocator, .field_start);
    defer sm.deinit();

    // This implements the following fsm:
    try sm.addTriggerAndTransition(.whitespace, .field_start, .field_start);
    try sm.addTriggerAndTransition(.whitespace, .unquoted, .unquoted);
    try sm.addTriggerAndTransition(.whitespace, .post_quoted, .post_quoted);
    try sm.addTriggerAndTransition(.char, .field_start, .unquoted);
    try sm.addTriggerAndTransition(.char, .unquoted, .unquoted);
    try sm.addTriggerAndTransition(.quote, .field_start, .quoted);
    try sm.addTriggerAndTransition(.quote, .quoted, .post_quoted);
    try sm.addTriggerAndTransition(.anything_not_quote, .quoted, .quoted);
    try sm.addTriggerAndTransition(.comma, .post_quoted, .field_start);
    try sm.addTriggerAndTransition(.comma, .unquoted, .field_start);
    try sm.addTriggerAndTransition(.comma, .field_start, .field_start);
    try sm.addTriggerAndTransition(.newline, .post_quoted, .field_start);
    try sm.addTriggerAndTransition(.newline, .unquoted, .field_start);
    try sm.addTriggerAndTransition(.eof, .unquoted, .done);
    try sm.addTriggerAndTransition(.eof, .quoted, .done);
    try sm.addFinalState(.done);

    try Parser.parse(sm, csv_input);

    // Uncomment to generate a Graphviz diagram
    // try sm.exportGraphviz("csv", std.io.getStdOut().writer(), .{.shape = "box", .shape_final_state = "doublecircle", .show_initial_state=true});
}

// Demonstrates that triggering a single "click" event can perpetually cycle through intensity states.
test "moore machine: three-level intensity light" {
    const State = enum { off, dim, medium, bright };
    const Trigger = enum { click };
    const FSM = StateMachine(State, Trigger);

    var sm = try FSM.init(std.testing.allocator, .off);
    defer sm.deinit();

    try sm.addTriggerAndTransition(.click, .off, .dim);
    try sm.addTriggerAndTransition(.click, .dim, .medium);
    try sm.addTriggerAndTransition(.click, .medium, .bright);
    try sm.addTriggerAndTransition(.click, .bright, .off);

    // Trigger a full cycle of off -> dim -> medium -> bright -> off

    try expect(sm.isCurrently(.off));

    try sm.activateTrigger(.click);
    try expect(sm.isCurrently(.dim));

    try sm.activateTrigger(.click);
    try expect(sm.isCurrently(.medium));

    try sm.activateTrigger(.click);
    try expect(sm.isCurrently(.bright));

    try sm.activateTrigger(.click);
    try expect(sm.isCurrently(.off));

    try expect(sm.canTransitionTo(.dim));
    try expect(!sm.canTransitionTo(.medium));
    try expect(!sm.canTransitionTo(.bright));
    try expect(!sm.canTransitionTo(.off));

    // Uncomment to generate a Graphviz diagram
    // try sm.exportGraphviz("lights", std.io.getStdOut().writer(), .{.layout = "circo", .shape = "box"});
}

test "handler that cancels" {
    const State = enum { on, off };
    const Trigger = enum { click };
    const FSM = StateMachine(State, Trigger);

    var sm = try FSM.init(std.testing.allocator, .off);
    defer sm.deinit();

    // Demonstrates how to manage extra state (in this case a simple counter) while reacting
    // to transitions. Once the counter reaches 3, it cancels any further transitions. Real-world
    // handlers typically check from/to states and perhaps even which trigger (if any) caused the
    // transition.
    const CountingHandler = struct {
        handler: FSM.Handler,
        counter: usize,

        pub fn init() @This() {
            return .{
                .handler = Interface.make(FSM.Handler, @This()),
                .counter = 0,
            };
        }

        pub fn onTransition(handler: *FSM.Handler, trigger: ?Trigger, from: State, to: State) HandlerResult {
            _ = &.{ from, to, trigger };
            const self = Interface.downcast(@This(), handler);
            self.counter += 1;
            return if (self.counter < 3) HandlerResult.Continue else HandlerResult.Cancel;
        }
    };

    var countingHandler = CountingHandler.init();
    try sm.addTransitionHandler(&countingHandler.handler);
    try sm.addTriggerAndTransition(.click, .on, .off);
    try sm.addTriggerAndTransition(.click, .off, .on);

    try sm.activateTrigger(.click);
    try sm.activateTrigger(.click);

    // Third time will fail
    try std.testing.expectError(StateError.Canceled, sm.activateTrigger(.click));
}

// Implements the Deterministic Finite Automaton in https://en.wikipedia.org/wiki/Deterministic_finite_automaton#Example
test "dfa: binary alphabet, require even number of zeros in input" {
    const input =
        \\ S1 -> S2 [label = "0"];
        \\ S2 -> S1 [label = "0"];
        \\ S1 -> S1 [label = "1"];
        \\ S2 -> S2 [label = "1"];
    ;

    const State = enum { S1, S2 };
    const Bit = enum { @"0", @"1" };
    var sm = try StateMachine(State, Bit).init(std.testing.allocator, .S1);
    defer sm.deinit();
    try sm.importGraphviz(std.io.fixedBufferStream(input).reader());

    // If the final state is S1, there input has an even number of 0's
    try sm.addFinalState(.S1);

    // With valid input, we wil end up in the final state
    const valid_input: []const Bit = &.{ .@"0", .@"0", .@"1", .@"1" };
    for (valid_input) |bit| try sm.activateTrigger(bit);
    try expect(sm.isInFinalState());

    // With invalid input, we will not end up in the final state
    const invalid_input: []const Bit = &.{ .@"0", .@"0", .@"0", .@"1" };
    for (invalid_input) |bit| try sm.activateTrigger(bit);
    try expect(!sm.isInFinalState());
}

test "graphviz: import" {
    // Note that we also test skipping __INITIAL in case the DOT file was generated by zigfsm
    // with the `show_initial_state` flag set.
    const input =
        \\digraph parser_example {
        \\    rankdir=LR;
        \\    node [shape = doublecircle fixedsize = false]; "3"  "4"  "8" ;
        \\    node [shape = circle fixedsize = false];
        \\    __INITIAL -> "0";
        \\    "0" -> "2" [label = "SS(B)"];
        \\    "0" -> "1" [label = "SS(S)"];
        \\    "1" -> "3" [label = "S($end)"];
        \\    "2" -> "6" [label = "SS(b)"];
        \\    "2" -> "5" [label = "SS(a)"];
        \\    "2" -> "4" [label = "S(A)"];
        \\    "5" -> "7" [label = "S(b)"];
        \\    "5" -> "5" [label = "S(a)"];
        \\    "6" -> "6" [label = "S(b)"];
        \\    "6" -> "5" [label = "S(a)"];
        \\    "7" -> "8" [label = "S(b)"];
        \\    "7" -> "5" [label = "S(a)"];
        \\    "8" -> "6" [label = "S(b)"];
        \\    "8" -> "5" [label = "S(a) || extra"];
        \\}
    ;

    var outbuf = std.ArrayList(u8).init(std.testing.allocator);
    defer outbuf.deinit();

    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Trigger = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var sm = try StateMachine(State, Trigger).init(std.testing.allocator, .@"0");
    defer sm.deinit();

    try sm.importGraphviz(std.io.fixedBufferStream(input).reader());

    try sm.apply(.{ .trigger = .@"SS(B)" });
    try expectEqual(sm.currentState(), .@"2");
    try sm.transitionTo(.@"6");
    try expectEqual(sm.currentState(), .@"6");
    // Self-transition
    try sm.activateTrigger(.@"S(b)");
    try expectEqual(sm.currentState(), .@"6");
}

// Implements the state diagram example from the Graphviz docs
test "graphviz: export of finite automaton sample" {
    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Trigger = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var sm = try StateMachine(State, Trigger).init(std.testing.allocator, .@"0");
    defer sm.deinit();

    try sm.addTransition(State.@"0", State.@"2");
    try sm.addTransition(State.@"0", State.@"1");
    try sm.addTransition(State.@"1", State.@"3");
    try sm.addTransition(State.@"2", State.@"6");
    try sm.addTransition(State.@"2", State.@"5");
    try sm.addTransition(State.@"2", State.@"4");
    try sm.addTransition(State.@"5", State.@"7");
    try sm.addTransition(State.@"5", State.@"5");
    try sm.addTransition(State.@"6", State.@"6");
    try sm.addTransition(State.@"6", State.@"5");
    try sm.addTransition(State.@"7", State.@"8");
    try sm.addTransition(State.@"7", State.@"5");
    try sm.addTransition(State.@"8", State.@"6");
    try sm.addTransition(State.@"8", State.@"5");

    try sm.addFinalState(State.@"3");
    try sm.addFinalState(State.@"4");
    try sm.addFinalState(State.@"8");

    try sm.addTrigger(.@"SS(B)", .@"0", .@"2");
    try sm.addTrigger(.@"SS(S)", .@"0", .@"1");
    try sm.addTrigger(.@"S($end)", .@"1", .@"3");
    try sm.addTrigger(.@"SS(b)", .@"2", .@"6");
    try sm.addTrigger(.@"SS(a)", .@"2", .@"5");
    try sm.addTrigger(.@"S(A)", .@"2", .@"4");
    try sm.addTrigger(.@"S(b)", .@"5", .@"7");
    try sm.addTrigger(.@"S(a)", .@"5", .@"5");
    try sm.addTrigger(.@"S(b)", .@"6", .@"6");
    try sm.addTrigger(.@"S(a)", .@"6", .@"5");
    try sm.addTrigger(.@"S(b)", .@"7", .@"8");
    try sm.addTrigger(.@"S(a)", .@"7", .@"5");
    try sm.addTrigger(.@"S(b)", .@"8", .@"6");
    try sm.addTrigger(.@"S(a)", .@"8", .@"5");
    // This demonstrates that multiple triggers on the same transition are concatenated with ||
    try sm.addTrigger(.extra, .@"8", .@"5");

    var outbuf = std.ArrayList(u8).init(std.testing.allocator);
    defer outbuf.deinit();
    try sm.exportGraphviz("parser_example", outbuf.writer(), .{});

    const target =
        \\digraph parser_example {
        \\    rankdir=LR;
        \\    node [shape = doublecircle fixedsize = false]; "3"  "4"  "8" ;
        \\    node [shape = circle fixedsize = false];
        \\    "0" -> "2" [label = "SS(B)"];
        \\    "0" -> "1" [label = "SS(S)"];
        \\    "1" -> "3" [label = "S($end)"];
        \\    "2" -> "6" [label = "SS(b)"];
        \\    "2" -> "5" [label = "SS(a)"];
        \\    "2" -> "4" [label = "S(A)"];
        \\    "5" -> "7" [label = "S(b)"];
        \\    "5" -> "5" [label = "S(a)"];
        \\    "6" -> "6" [label = "S(b)"];
        \\    "6" -> "5" [label = "S(a)"];
        \\    "7" -> "8" [label = "S(b)"];
        \\    "7" -> "5" [label = "S(a)"];
        \\    "8" -> "6" [label = "S(b)"];
        \\    "8" -> "5" [label = "S(a) || extra"];
        \\}
        \\
    ;

    try expectEqualSlices(u8, target[0..], outbuf.items[0..]);
}

/// An elevator state machine
const ElevatorTest = struct {
    const Elevator = enum { doors_opened, doors_closed, moving, exit_light_blinking };
    const ElevatorActions = enum { open, close, alarm };

    pub fn init() !*StateMachine(Elevator, ElevatorActions) {
        var sm = try StateMachine(Elevator, ElevatorActions).init(std.testing.allocator, .doors_opened);
        try sm.addTransition(.doors_opened, .doors_closed);
        try sm.addTransition(.doors_closed, .moving);
        try sm.addTransition(.moving, .moving);
        try sm.addTransition(.doors_opened, .exit_light_blinking);
        try sm.addTransition(.doors_closed, .doors_opened);
        try sm.addTransition(.exit_light_blinking, .doors_opened);
        return sm;
    }
};

test "elevator: redefine transition should fail" {
    var sm = try ElevatorTest.init();
    defer sm.deinit();
    try std.testing.expectError(StateError.AlreadyDefined, sm.addTransition(.doors_opened, .doors_closed));
}

test "elevator: apply" {
    var sm = try ElevatorTest.init();
    defer sm.deinit();
    try sm.addTrigger(.alarm, .doors_opened, .exit_light_blinking);
    try sm.apply(.{ .state = ElevatorTest.Elevator.doors_closed });
    try sm.apply(.{ .state = ElevatorTest.Elevator.doors_opened });
    try sm.apply(.{ .trigger = ElevatorTest.ElevatorActions.alarm });
    try expect(sm.isCurrently(.exit_light_blinking));
}

test "elevator: transition success" {
    var sm = try ElevatorTest.init();
    defer sm.deinit();
    try sm.transitionTo(.doors_closed);
    try expectEqual(sm.currentState(), .doors_closed);
}

test "elevator: add a trigger and active it" {
    var sm = try ElevatorTest.init();
    defer sm.deinit();

    // The same trigger can be invoked for multiple state transitions
    try sm.addTrigger(.alarm, .doors_opened, .exit_light_blinking);
    try expectEqual(sm.currentState(), .doors_opened);

    try sm.activateTrigger(.alarm);
    try expectEqual(sm.currentState(), .exit_light_blinking);
}
