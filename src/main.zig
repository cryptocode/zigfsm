//! The zigfsm library offer two state machine type constructors, StateMachineFromTable and StateMachine.
//! The first type is defined using an array of events and state transitions.
//! The second type is defined by calling methods for adding events and transitions.
//! State machines can also be constructed by importing Graphviz or libfsm text.
//! SPDX-License-Identifier: MIT

const std = @import("std");
const EnumField = std.builtin.Type.EnumField;

/// State transition errors
pub const StateError = error{
    /// Invalid transition
    Invalid,
    /// A state transition was canceled
    Canceled,
    /// An event or state transition has already been defined
    AlreadyDefined,
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

/// A transition, with optional event
pub fn Transition(comptime StateType: type, comptime EventType: ?type) type {
    return struct {
        event: if (EventType) |T| ?T else ?void = null,
        from: StateType,
        to: StateType,
    };
}
const ImportLineState = enum { ready, source, target, event, await_start_state, startstate, await_end_states, endstates };
const ImportInput = enum { identifier, startcolon, endcolon, newline };
const import_transition_table = [_]Transition(ImportLineState, ImportInput){
    .{ .event = .identifier, .from = .ready, .to = .source },
    .{ .event = .identifier, .from = .target, .to = .event },
    .{ .event = .identifier, .from = .event, .to = .event },
    .{ .event = .identifier, .from = .await_start_state, .to = .startstate },
    .{ .event = .identifier, .from = .await_end_states, .to = .endstates },
    .{ .event = .identifier, .from = .endstates, .to = .endstates },
    .{ .event = .identifier, .from = .source, .to = .target },
    .{ .event = .startcolon, .from = .ready, .to = .await_start_state },
    .{ .event = .endcolon, .from = .ready, .to = .await_end_states },
    .{ .event = .newline, .from = .ready, .to = .ready },
    .{ .event = .newline, .from = .startstate, .to = .ready },
    .{ .event = .newline, .from = .endstates, .to = .ready },
    .{ .event = .newline, .from = .target, .to = .ready },
    .{ .event = .newline, .from = .event, .to = .ready },
};

const ImportFSM = StateMachineFromTable(ImportLineState, ImportInput, import_transition_table[0..], .ready, &.{});

/// Construct a state machine type given a state enum and an optional event enum.
/// Add states and events using the member functions.
pub fn StateMachine(
    comptime StateType: type,
    comptime EventType: ?type,
    comptime initial_state: StateType,
) type {
    return StateMachineFromTable(StateType, EventType, &[0]Transition(StateType, EventType){}, initial_state, &[0]StateType{});
}

/// Construct a state machine type given a state enum, an optional event enum, a transition table, initial state and end states (which can be empty)
/// If you want to add transitions and end states using the member methods, you can use `StateMachine(...)` as a shorthand.
pub fn StateMachineFromTable(
    comptime StateType: type,
    comptime EventType: ?type,
    comptime transitions: []const Transition(StateType, EventType),
    comptime initial_state_a: StateType,
    comptime final_states: []const StateType,
) type {
    const initial_state = initial_state_a;
    const StateEventSelector = enum { state, event };
    const EventTypeArg = if (EventType) |T| T else void;
    const StateEventUnion = union(StateEventSelector) {
        state: StateType,
        event: if (EventType) |T| T else void,
    };

    const state_type_count = comptime std.meta.fields(StateType).len;
    const event_type_count = comptime if (EventType) |T| std.meta.fields(T).len else 0;
    const TransitionBitSet = std.StaticBitSet(state_type_count * state_type_count);
    const FinalStatesType = std.StaticBitSet(state_type_count);

    const state_enum_bits = std.math.log2_int_ceil(usize, state_type_count);
    const event_enum_bits = if (event_type_count > 0) std.math.log2_int_ceil(usize, event_type_count) else 0;

    // Events are organized into a packed 2D array. Indexing by state and event yields the next state (where 0 means no transition)
    // Add 1 to bit_count because zero is used to indicates absence of transition (no target state defined for a source state/event combination)
    // Cell values must thus be adjusted accordingly when added or queried.
    const bits_per_cell = @as(u16, @max(state_enum_bits, event_enum_bits)) + 1;
    const total_bits = (bits_per_cell * state_type_count * @max(event_type_count, 1));
    const total_bytes = total_bits / 8 + 1;
    const CellType = std.meta.Int(.unsigned, bits_per_cell);
    const EventPackedIntArray = if (EventType != null)
        [total_bytes]u8
    else
        void;

    return struct {
        internal: struct {
            start_state: StateType,
            current_state: StateType,
            state_map: TransitionBitSet,
            final_states: FinalStatesType,
            transition_handlers: []const *Handler,
            events: EventPackedIntArray,
        } = undefined,

        const Self = @This();
        pub const StateEnum = StateType;
        pub const EventEnum = if (EventType) |T| T else void;

        /// Transition handler interface
        pub const Handler = struct {
            onTransition: *const fn (self: *Handler, event: ?EventTypeArg, from: StateType, to: StateType) HandlerResult,
        };

        /// Returns a new state machine instance
        pub fn init() Self {
            var instance: Self = .{};
            instance.internal.start_state = initial_state;
            instance.internal.current_state = initial_state;
            instance.internal.final_states = FinalStatesType.initEmpty();
            instance.internal.transition_handlers = &.{};
            instance.internal.state_map = TransitionBitSet.initEmpty();
            if (comptime EventType != null) {
                instance.internal.events = .{0} ** total_bytes;
            }

            for (transitions) |t| {
                const offset = (@intFromEnum(t.from) * state_type_count) + @intFromEnum(t.to);
                instance.internal.state_map.setValue(offset, true);

                if (comptime EventType != null) {
                    if (t.event) |event| {
                        const slot = computeEventSlot(event, t.from);
                        std.mem.writePackedIntNative(CellType, &instance.internal.events, slot * bits_per_cell, @intFromEnum(t.to) + @as(CellType, 1));
                    }
                }
            }

            for (final_states) |f| {
                instance.internal.final_states.setValue(@intFromEnum(f), true);
            }

            return instance;
        }

        /// Create a new state machine instance, with state transitions imported from the given Graphviz or libfsm text
        pub fn initFrom(input: []const u8) !Self {
            var instance = Self.init();
            try instance.importText(input);
            return instance;
        }

        /// Returns the current state
        pub fn currentState(self: *Self) StateType {
            return self.internal.current_state;
        }

        /// Sets the start state. This becomes the new `currentState()`.
        pub fn setStartState(self: *Self, start_state: StateType) void {
            self.internal.start_state = start_state;
            self.internal.current_state = start_state;
        }

        /// Unconditionally restart the state machine.
        /// This sets the current state back to the initial start state.
        pub fn restart(self: *Self) void {
            self.internal.current_state = self.internal.start_state;
        }

        /// Same as `restart` but fails if the state machine is currently neither in a final state,
        /// nor in the initial start state.
        pub fn safeRestart(self: *Self) StateError!void {
            if (!self.isInFinalState() and !self.isInStartState()) return StateError.Invalid;
            self.internal.current_state = self.internal.start_state;
        }

        /// Returns true if the current state is the start state
        pub fn isInStartState(self: *Self) bool {
            return self.internal.current_state == self.internal.start_state;
        }

        /// Final states are optional. Note that it's possible, and common, for transitions
        /// to exit final states during execution. It's up to the library user to check for
        /// any final state conditions, using `isInFinalState()` or comparing with `currentState()`
        /// Returns `StateError.Invalid` if the final state is already added.
        pub fn addFinalState(self: *Self, final_state: StateType) !void {
            if (self.isFinalState(final_state)) return StateError.Invalid;
            self.internal.final_states.setValue(@intFromEnum(final_state), true);
        }

        /// Returns true if the state machine is in a final state
        pub fn isInFinalState(self: *Self) bool {
            return self.internal.final_states.isSet(@intFromEnum(self.currentState()));
        }

        /// Returns true if the argument is a final state
        pub fn isFinalState(self: *Self, state: StateType) bool {
            return self.internal.final_states.isSet(@intFromEnum(state));
        }

        /// Invoke all `handlers` when a state transition happens
        pub fn setTransitionHandlers(self: *Self, handlers: []const *Handler) void {
            self.internal.transition_handlers = handlers;
        }

        /// Add the transition `from` -> `to` if missing, and define an event for the transition
        pub fn addEventAndTransition(self: *Self, event: EventTypeArg, from: StateType, to: StateType) !void {
            if (comptime EventType != null) {
                if (!self.canTransitionFromTo(from, to)) try self.addTransition(from, to);
                try self.addEvent(event, from, to);
            }
        }

        /// Check if the transition `from` -> `to` is valid and add the event for this transition
        pub fn addEvent(self: *Self, event: EventTypeArg, from: StateType, to: StateType) !void {
            if (comptime EventType != null) {
                if (self.canTransitionFromTo(from, to)) {
                    const slot = computeEventSlot(event, from);
                    const slot_val = std.mem.readPackedIntNative(CellType, &self.internal.events, slot * bits_per_cell);
                    if (slot_val != 0) return StateError.AlreadyDefined;
                    std.mem.writePackedIntNative(CellType, &self.internal.events, slot * bits_per_cell, @as(CellType, @intCast(@intFromEnum(to))) + 1);
                } else return StateError.Invalid;
            }
        }

        /// Trigger a transition using an event
        /// Returns `StateError.Invalid` if the event is not defined for the current state
        pub fn do(self: *Self, event: EventTypeArg) !Transition(StateType, EventType) {
            if (comptime EventType != null) {
                const from_state = self.internal.current_state;
                const slot = computeEventSlot(event, self.internal.current_state);
                const to_state = std.mem.readPackedIntNative(CellType, &self.internal.events, slot * bits_per_cell);
                if (to_state != 0) {
                    try self.transitionToInternal(event, @as(StateType, @enumFromInt(to_state - 1)));
                    return .{ .event = event, .from = from_state, .to = @as(StateType, @enumFromInt(to_state - 1)) };
                } else {
                    return StateError.Invalid;
                }
            }
        }

        /// Given an event and a from-state (usually the current state), return the slot index for the to-state
        fn computeEventSlot(event: EventTypeArg, from: StateType) usize {
            return @as(usize, @intCast(@intFromEnum(from))) * event_type_count + @intFromEnum(event);
        }

        /// Add a valid state transition
        /// Returns `StateError.AlreadyDefined` if the transition is already defined
        pub fn addTransition(self: *Self, from: StateType, to: StateType) !void {
            const offset: usize = (@as(usize, @intCast(@intFromEnum(from))) * state_type_count) + @intFromEnum(to);
            if (self.internal.state_map.isSet(offset)) return StateError.AlreadyDefined;
            self.internal.state_map.setValue(offset, true);
        }

        /// Returns true if the current state is equal to `requested_state`
        pub fn isCurrently(self: *Self, requested_state: StateType) bool {
            return self.internal.current_state == requested_state;
        }

        /// Returns true if the transition is possible
        pub fn canTransitionTo(self: *Self, new_state: StateType) bool {
            const offset: usize = (@as(usize, @intCast(@intFromEnum(self.currentState()))) * state_type_count) + @intFromEnum(new_state);
            return self.internal.state_map.isSet(offset);
        }

        /// Returns true if the transition `from` -> `to` is possible
        pub fn canTransitionFromTo(self: *Self, from: StateType, to: StateType) bool {
            const offset: usize = (@as(usize, @intCast(@intFromEnum(from))) * state_type_count) + @intFromEnum(to);
            return self.internal.state_map.isSet(offset);
        }

        /// If possible, transition from current state to `new_state`
        /// Returns `StateError.Invalid` if the transition is not allowed
        pub fn transitionTo(self: *Self, new_state: StateType) StateError!void {
            return self.transitionToInternal(null, new_state);
        }

        fn transitionToInternal(self: *Self, event: ?EventTypeArg, new_state: StateType) StateError!void {
            if (!self.canTransitionTo(new_state)) {
                return StateError.Invalid;
            }

            for (self.internal.transition_handlers) |handler| {
                switch (handler.onTransition(handler, event, self.currentState(), new_state)) {
                    .Cancel => return StateError.Canceled,
                    .CancelNoError => return,
                    else => {},
                }
            }

            self.internal.current_state = new_state;
        }

        /// Sets the new current state without firing any registered handlers
        /// Checking if the transition is valid is only done if `check_valid_transition` is true
        pub fn transitionToSilently(self: *Self, new_state: StateType, check_valid_transition: bool) StateError!void {
            if (check_valid_transition and !self.canTransitionTo(new_state)) {
                return StateError.Invalid;
            }
            self.internal.current_state = new_state;
        }

        /// Transition initiated by state or event
        /// Returns `StateError.Invalid` if the transition is not allowed
        pub fn apply(self: *Self, state_or_event: StateEventUnion) !void {
            if (state_or_event == StateEventSelector.state) {
                try self.transitionTo(state_or_event.state);
            } else if (EventType) |_| {
                _ = try self.do(state_or_event.event);
            }
        }

        /// An iterator that returns the next possible states
        pub const PossibleNextStateIterator = struct {
            fsm: *Self,
            index: usize = 0,

            /// Next valid state, or null if no more valid states are available
            pub fn next(self: *@This()) ?StateEnum {
                inline for (std.meta.fields(StateType), 0..) |field, i| {
                    if (i == self.index) {
                        self.index += 1;
                        if (self.fsm.canTransitionTo(@as(StateType, @enumFromInt(field.value)))) {
                            return @as(StateType, @enumFromInt(field.value));
                        }
                    }
                }

                return null;
            }

            /// Restarts the iterator
            pub fn reset(self: *@This()) void {
                self.index = 0;
            }
        };

        /// Returns an iterator for the next possible states from the current state
        pub fn validNextStatesIterator(self: *Self) PossibleNextStateIterator {
            return .{ .fsm = self };
        }

        /// Graphviz export options
        pub const ExportOptions = struct {
            rankdir: []const u8 = "LR",
            layout: ?[]const u8 = null,
            shape: []const u8 = "circle",
            shape_final_state: []const u8 = "doublecircle",
            fixed_shape_size: bool = false,
            show_events: bool = true,
            show_initial_state: bool = false,
        };

        /// Exports a Graphviz directed graph to the given writer
        pub fn exportGraphviz(self: *Self, title: []const u8, writer: anytype, options: ExportOptions) !void {
            try writer.print("digraph {s} {{\n", .{title});
            try writer.print("    rankdir=LR;\n", .{});
            if (options.layout) |layout| try writer.print("    layout={s};\n", .{layout});
            if (options.show_initial_state) try writer.print("    node [shape = point ]; \"start:\";\n", .{});

            // Style for final states
            if (self.internal.final_states.count() > 0) {
                try writer.print("    node [shape = {s} fixedsize = {}];", .{ options.shape_final_state, options.fixed_shape_size });
                var final_it = self.internal.final_states.iterator(.{ .kind = .set, .direction = .forward });
                while (final_it.next()) |index| {
                    try writer.print(" \"{s}\" ", .{@tagName(@as(StateType, @enumFromInt(index)))});
                }

                try writer.print(";\n", .{});
            }

            // Default style
            try writer.print("    node [shape = {s} fixedsize = {}];\n", .{ options.shape, options.fixed_shape_size });

            if (options.show_initial_state) {
                try writer.print("    \"start:\" -> \"{s}\";\n", .{@tagName(self.internal.start_state)});
            }

            var it = self.internal.state_map.iterator(.{ .kind = .set, .direction = .forward });
            while (it.next()) |index| {
                const from = @as(StateType, @enumFromInt(index / state_type_count));
                const to = @as(StateType, @enumFromInt(index % state_type_count));

                try writer.print("    \"{s}\" -> \"{s}\"", .{ @tagName(from), @tagName(to) });

                if (EventType) |T| {
                    if (options.show_events) {
                        const events_start_offset = @as(usize, @intCast(@intFromEnum(from))) * event_type_count;
                        var transition_name_buf: [4096]u8 = undefined;
                        var transition_name = std.io.fixedBufferStream(&transition_name_buf);
                        for (0..event_type_count) |event_index| {
                            const slot_val = std.mem.readPackedIntNative(CellType, &self.internal.events, (events_start_offset + event_index) * bits_per_cell);
                            if (slot_val > 0 and (slot_val - 1) == @intFromEnum(to)) {
                                if ((try transition_name.getPos()) == 0) {
                                    try writer.print(" [label = \"", .{});
                                }
                                if ((try transition_name.getPos()) > 0) {
                                    try transition_name.writer().print(" || ", .{});
                                }
                                try transition_name.writer().print("{s}", .{@tagName(@as(T, @enumFromInt(event_index)))});
                            }
                        }
                        if ((try transition_name.getPos()) > 0) {
                            try writer.print("{s}\"]", .{transition_name.getWritten()});
                        }
                    }
                }

                try writer.print(";\n", .{});
            }
            try writer.print("}}\n", .{});
        }

        const ImportParseHandler = struct {
            handler: ImportFSM.Handler,
            fsm: *Self,
            from: ?StateType = null,
            to: ?StateType = null,
            current_identifer: []const u8 = "",

            pub fn init(fsmptr: *Self) @This() {
                return .{
                    .handler = Interface.make(ImportFSM.Handler, @This()),
                    .fsm = fsmptr,
                };
            }

            pub fn onTransition(handler: *ImportFSM.Handler, event: ?ImportInput, from: ImportLineState, to: ImportLineState) HandlerResult {
                const parse_handler = Interface.downcast(@This(), handler);
                _ = from;
                _ = event;

                if (to == .startstate) {
                    const start_enum = std.meta.stringToEnum(StateType, parse_handler.current_identifer);
                    if (start_enum) |e| parse_handler.fsm.setStartState(e);
                } else if (to == .endstates) {
                    const end_enum = std.meta.stringToEnum(StateType, parse_handler.current_identifer);
                    if (end_enum) |e| parse_handler.fsm.addFinalState(e) catch return HandlerResult.Cancel;
                } else if (to == .source) {
                    const from_enum = std.meta.stringToEnum(StateType, parse_handler.current_identifer);
                    parse_handler.from = from_enum;
                } else if (to == .target) {
                    const to_enum = std.meta.stringToEnum(StateType, parse_handler.current_identifer);
                    parse_handler.to = to_enum;
                    if (parse_handler.from != null and parse_handler.to != null) {
                        parse_handler.fsm.addTransition(parse_handler.from.?, parse_handler.to.?) catch |e| {
                            if (e != StateError.AlreadyDefined) return HandlerResult.Cancel;
                        };
                    }
                } else if (to == .event) {
                    if (EventType != null) {
                        const event_enum = std.meta.stringToEnum(EventType.?, parse_handler.current_identifer);
                        if (event_enum) |te| {
                            parse_handler.fsm.addEvent(te, parse_handler.from.?, parse_handler.to.?) catch {
                                return HandlerResult.Cancel;
                            };
                        }
                    } else {
                        return HandlerResult.Cancel;
                    }
                }

                return HandlerResult.Continue;
            }
        };

        /// Reads a state machine from a buffer containing Graphviz or libfsm text.
        /// Any currently existing transitions are preserved.
        /// Parsing is supported at both comptime and runtime.
        ///
        /// Lines of the following forms are considered during parsing:
        ///
        ///    a -> b
        ///    "a" -> "b"
        ///    a -> b [label="someevent"]
        ///    a -> b [label="event1 || event2"]
        ///    a -> b "event1"
        ///    "a" -> "b" "event1";
        ///    a -> b 'event1'
        ///    'a' -> 'b' 'event1'
        ///    'a' -> 'b' 'event1 || event2'
        ///    start: a;
        ///    start: -> "a";
        ///    end: "abc" a2 a3 a4;
        ///    end: -> "X" Y 'ZZZ';
        ///    end: -> event1, e2, 'ZZZ';
        ///
        /// The purpose of this parser is to support a simple text format for defining state machines,
        /// not to be a full .gv parser.
        pub fn importText(self: *Self, input: []const u8) !void {

            // Might as well use a state machine to implement importing textual state machines.
            // After an input event, we'll end up in one of these states:
            var fsm = ImportFSM.init();

            var parse_handler = ImportParseHandler.init(self);
            var handlers: [1]*ImportFSM.Handler = .{&parse_handler.handler};
            fsm.setTransitionHandlers(&handlers);

            var line_no: usize = 1;
            var lines = std.mem.splitAny(u8, input, "\n");

            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "->") == null and std.mem.indexOf(u8, line, "start:") == null and std.mem.indexOf(u8, line, "end:") == null) continue;
                var parts = std.mem.tokenizeAny(u8, line, " \t='\";,");
                while (parts.next()) |part| {
                    if (anyStringsEqual(&.{ "->", "[label", "]", "||" }, part)) {
                        continue;
                    } else if (std.mem.eql(u8, part, "start:")) {
                        _ = try fsm.do(.startcolon);
                    } else if (std.mem.eql(u8, part, "end:")) {
                        _ = try fsm.do(.endcolon);
                    } else {
                        parse_handler.current_identifer = part;
                        _ = try fsm.do(.identifier);
                    }
                }
                _ = try fsm.do(.newline);
                line_no += 1;
            }
            _ = try fsm.do(.newline);
        }
    };
}

/// Generates a state machine from a file containing Graphviz or libfsm text
/// including the necessary state/event enum types. An instance is created and returned.
///
/// You can combine this with @embedFile to generate a state machine at
/// compile time from an external text file.
pub fn instanceFromText(comptime input: []const u8) !FsmFromText(input) {
    const FSM = FsmFromText(input);
    var fsm = FSM.init();
    try fsm.importText(input);
    return fsm;
}

/// Generates a state machine from a file containing Graphviz or libfsm text
/// including the necessary state/event enum types. The generated type is returned.
pub fn FsmFromText(comptime input: []const u8) type {
    comptime {
        @setEvalBranchQuota(100_000);

        // Might as well use a state machine to implement importing textual state machines.
        // After an input event, we'll end up in one of these states:
        var fsm = ImportFSM.init();

        var state_enum_fields: []const EnumField = &[_]EnumField{};
        var event_enum_fields: []const EnumField = &[_]EnumField{};

        var line_no: usize = 1;
        var lines = std.mem.splitAny(u8, input, "\n");
        var start_state_index: usize = 0;
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "->") == null and std.mem.indexOf(u8, line, "start:") == null and std.mem.indexOf(u8, line, "end:") == null) continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t='\";,");
            part_loop: while (parts.next()) |part| {
                if (anyStringsEqual(&.{ "->", "[label", "]", "||" }, part)) {
                    continue;
                } else if (std.mem.eql(u8, part, "start:")) {
                    _ = fsm.do(.startcolon) catch unreachable;
                } else if (std.mem.eql(u8, part, "end:")) {
                    _ = fsm.do(.endcolon) catch unreachable;
                } else {
                    const current_identifier = part;
                    _ = fsm.do(.identifier) catch unreachable;
                    const to = fsm.currentState();

                    if (to == .startstate or to == .endstates or to == .source or to == .target) {
                        for (state_enum_fields) |field| {
                            if (std.mem.eql(u8, field.name, current_identifier)) {
                                continue :part_loop;
                            }
                        }

                        if (to == .startstate) {
                            start_state_index = state_enum_fields.len;
                        }

                        state_enum_fields = state_enum_fields ++ &[_]EnumField{.{
                            .name = current_identifier ++ "",
                            .value = state_enum_fields.len,
                        }};
                    } else if (to == .event) {
                        for (event_enum_fields) |field| {
                            if (std.mem.eql(u8, field.name, current_identifier)) {
                                continue :part_loop;
                            }
                        }

                        event_enum_fields = event_enum_fields ++ &[_]EnumField{.{
                            .name = current_identifier ++ "",
                            .value = event_enum_fields.len,
                        }};
                    }
                }
            }
            _ = fsm.do(.newline) catch unreachable;
            line_no += 1;
        }
        _ = fsm.do(.newline) catch unreachable;

        const StateEnum = @Type(.{ .@"enum" = .{
            .fields = state_enum_fields,
            .tag_type = std.math.IntFittingRange(0, state_enum_fields.len),
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = false,
        } });

        const EventEnum = if (event_enum_fields.len > 0) @Type(.{ .@"enum" = .{
            .fields = event_enum_fields,
            .tag_type = std.math.IntFittingRange(0, event_enum_fields.len),
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = false,
        } }) else null;

        return StateMachine(StateEnum, EventEnum, @as(StateEnum, @enumFromInt(start_state_index)));
    }
}

/// Helper that returns true if any of the slices are equal to the item
fn anyStringsEqual(slices: []const []const u8, item: []const u8) bool {
    for (slices) |slice| {
        if (std.mem.eql(u8, slice, item)) return true;
    }
    return false;
}

/// Helper type to make it easier to deal with polymorphic types
pub const Interface = struct {
    /// We establish the convention that the implementation type has the interface as the
    /// first field, allowing a slightly less verbose interface idiom. This will not compile
    /// if there's a mismatch. When this convention doesn't work, use @fieldParentPtr directly.
    pub fn downcast(comptime Implementer: type, interface_ref: anytype) *Implementer {
        const field_name = comptime std.meta.fieldNames(Implementer).*[0];
        return @fieldParentPtr(field_name, interface_ref);
    }

    /// Instantiates an interface type and populates its function pointers to point to
    /// proper functions in the given implementer type.
    pub fn make(comptime InterfaceType: type, comptime Implementer: type) InterfaceType {
        var instance: InterfaceType = undefined;
        inline for (std.meta.fields(InterfaceType)) |f| {
            if (comptime std.meta.hasFn(Implementer, f.name)) {
                @field(instance, f.name) = @field(Implementer, f.name);
            }
        }
        return instance;
    }
};

/// An enum generator useful for testing, as well as state machines with sequenced states or events.
/// If `prefix` is an empty string, use @"0", @"1", etc to refer to the enum field.
pub fn GenerateConsecutiveEnum(comptime prefix: []const u8, comptime element_count: usize) type {
    @setEvalBranchQuota(100_000);
    var fields: []const EnumField = &[_]EnumField{};

    for (0..element_count) |i| {
        comptime var tmp_buf: [128]u8 = undefined;
        const field_name = comptime try std.fmt.bufPrint(&tmp_buf, "{s}{d}", .{ prefix, i });
        fields = fields ++ &[_]EnumField{.{
            .name = field_name ++ "",
            .value = i,
        }};
    }
    return @Type(.{ .@"enum" = .{
        .fields = fields,
        .tag_type = std.math.IntFittingRange(0, element_count),
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_exhaustive = false,
    } });
}
