//! The zigfsm library implements two state machine types, StateMachineFromTable and StateMachine.
//! The first type is defined using an array of triggers and state transitions.
//! The second type is defined using methods for adding triggers and transitions.
//! Licence: MIT

const std = @import("std");

/// State transition errors
pub const StateError = error{
    /// Invalid transition
    Invalid,
    /// A state transition was canceled
    Canceled,
    /// A trigger or state transition has already been defined
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

/// A transition, and optional trigger
pub fn Transition(comptime StateType: type, comptime TriggerType: ?type) type {
    return struct {
        trigger: if (TriggerType) |T| ?T else ?void = null,
        from: StateType,
        to: StateType,
    };
}

/// Construct a state machine type given a state enum and an optional trigger enum.
/// Add states and triggers using the member functions.
pub fn StateMachine(comptime StateType: type, comptime TriggerType: ?type, comptime initial_state: StateType) type {
    return StateMachineFromTable(StateType, TriggerType, &[0]Transition(StateType, TriggerType){}, initial_state, &[0]StateType{});
}

/// Construct a state machine type given a state enum, an optional trigger enum, a transition table, initial state and end states (which can be empty)
/// If you want to add transitions and end states using the member methods, you can use `StateMachine(...)` as a shorthand.
pub fn StateMachineFromTable(comptime StateType: type, comptime TriggerType: ?type, comptime transitions: []const Transition(StateType, TriggerType), comptime initial_state_a: StateType, comptime final_states: []const StateType) type {
    const initial_state = initial_state_a;
    const StateTriggerSelector = enum { state, trigger };
    const TriggerTypeArg = if (TriggerType) |T| T else void;
    const StateTriggerUnion = union(StateTriggerSelector) {
        state: StateType,
        trigger: if (TriggerType) |T| T else void,
    };

    const state_type_count = comptime std.meta.fields(StateType).len;
    const trigger_type_count = comptime if (TriggerType) |T| std.meta.fields(T).len else 0;
    const TransitionBitSet = std.StaticBitSet(state_type_count * state_type_count);

    const state_enum_bits = std.math.log2_int_ceil(usize, state_type_count);
    const trigger_enum_bits = if (trigger_type_count > 0) std.math.log2_int_ceil(usize, trigger_type_count) else 0;

    // Add 1 to bit_count because zero is used to indicates absence of transition (no target state defined for a source state/trigger combination)
    // Cell values must thus be adjusted accordingly when added or queried.
    const CellType = std.meta.Int(.unsigned, std.math.max(state_enum_bits, trigger_enum_bits) + 1);
    const TriggerPackedIntArray = if (TriggerType != null) std.PackedIntArray(CellType, state_type_count * std.math.max(trigger_type_count, 1)) else void;
    const FinalStatesType = std.StaticBitSet(state_type_count);

    return struct {
        internal: struct {
            start_state: StateType,
            current_state: StateType,
            state_map: TransitionBitSet,
            final_states: FinalStatesType,
            transition_handlers: []*Handler,
            triggers: TriggerPackedIntArray,
        } = undefined,

        const Self = @This();
        pub const StateEnum = StateType;
        pub const TriggerEnum = if (TriggerType) |T| T else void;

        /// Transition handler interface
        /// You only need to implement the functions you need
        pub const Handler = struct {
            onTransition: *const fn (self: *Handler, trigger: ?TriggerTypeArg, from: StateType, to: StateType) HandlerResult,
        };

        /// Returns a new state machine instance
        pub fn init() Self {
            var instance: Self = .{};
            instance.internal.start_state = initial_state;
            instance.internal.current_state = initial_state;
            instance.internal.final_states = FinalStatesType.initEmpty();
            instance.internal.transition_handlers = &.{};
            instance.internal.state_map = TransitionBitSet.initEmpty();
            if (comptime TriggerType != null) instance.internal.triggers = TriggerPackedIntArray.initAllTo(0);

            for (transitions) |t| {
                var offset = (@enumToInt(t.from) * state_type_count) + @enumToInt(t.to);
                instance.internal.state_map.setValue(offset, true);

                if (comptime TriggerType != null) {
                    if (t.trigger) |trigger| {
                        const slot = computeTriggerSlot(trigger, t.from);
                        instance.internal.triggers.set(slot, @enumToInt(t.to) + @as(CellType, 1));
                    }
                }
            }

            for (final_states) |f| {
                instance.internal.final_states.setValue(@enumToInt(f), true);
            }

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
            self.internal.final_states.setValue(@enumToInt(final_state), true);
        }

        /// Returns true if the state machine is in a final state
        pub fn isInFinalState(self: *Self) bool {
            return self.internal.final_states.isSet(@enumToInt(self.currentState()));
        }

        /// Returns true if the argument is a final state
        pub fn isFinalState(self: *Self, state: StateType) bool {
            return self.internal.final_states.isSet(@enumToInt(state));
        }

        /// Invoke all `handlers` when a state transition happens
        pub fn setTransitionHandlers(self: *Self, handlers: []*Handler) void {
            self.internal.transition_handlers = handlers;
        }

        /// Add the transition `from` -> `to` if missing, and define a trigger for the transition
        pub fn addTriggerAndTransition(self: *Self, trigger: TriggerTypeArg, from: StateType, to: StateType) !void {
            if (comptime TriggerType != null) {
                if (!self.canTransitionFromTo(from, to)) try self.addTransition(from, to);
                try self.addTrigger(trigger, from, to);
            }
        }

        fn computeTriggerSlot(trigger: TriggerTypeArg, from: StateType) usize {
            return @intCast(usize, @enumToInt(from)) * trigger_type_count + @enumToInt(trigger);
        }

        /// Check if the transition `from` -> `to` is valid and add the trigger for this transition
        pub fn addTrigger(self: *Self, trigger: TriggerTypeArg, from: StateType, to: StateType) !void {
            if (comptime TriggerType != null) {
                if (self.canTransitionFromTo(from, to)) {
                    var slot = computeTriggerSlot(trigger, from);
                    if (self.internal.triggers.get(slot) != 0) return StateError.AlreadyDefined;
                    self.internal.triggers.set(slot, @intCast(CellType, @enumToInt(to)) + 1);
                } else return StateError.Invalid;
            }
        }

        /// Trigger a transition
        /// Returns `StateError.Invalid` if the trigger is not defined for the current state
        pub fn activateTrigger(self: *Self, trigger: TriggerTypeArg) !void {
            if (comptime TriggerType != null) {
                var slot = computeTriggerSlot(trigger, self.internal.current_state);
                var to_state = self.internal.triggers.get(slot);
                if (to_state != 0) {
                    try self.transitionToInternal(trigger, @intToEnum(StateType, to_state - 1));
                } else {
                    return StateError.Invalid;
                }
            }
        }

        /// Add a valid state transition
        /// Returns `StateError.AlreadyDefined` if the transition is already defined
        pub fn addTransition(self: *Self, from: StateType, to: StateType) !void {
            const offset: usize = (@intCast(usize, @enumToInt(from)) * state_type_count) + @enumToInt(to);
            if (self.internal.state_map.isSet(offset)) return StateError.AlreadyDefined;
            self.internal.state_map.setValue(offset, true);
        }

        /// Returns true if the current state is equal to `requested_state`
        pub fn isCurrently(self: *Self, requested_state: StateType) bool {
            return self.internal.current_state == requested_state;
        }

        /// Returns true if the transition is possible
        pub fn canTransitionTo(self: *Self, new_state: StateType) bool {
            const offset: usize = (@intCast(usize, @enumToInt(self.currentState())) * state_type_count) + @enumToInt(new_state);
            return self.internal.state_map.isSet(offset);
        }

        /// Returns true if the transition `from` -> `to` is possible
        pub fn canTransitionFromTo(self: *Self, from: StateType, to: StateType) bool {
            const offset: usize = (@intCast(usize, @enumToInt(from)) * state_type_count) + @enumToInt(to);
            return self.internal.state_map.isSet(offset);
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

            for (self.internal.transition_handlers) |handler| {
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

        /// An iterator that returns the next possible states
        pub const PossibleNextStateIterator = struct {
            fsm: *Self,
            index: usize = 0,

            /// Next valid state, or null if no more valid states are available
            pub fn next(self: *@This()) ?StateEnum {
                inline for (std.meta.fields(StateType)) |field, i| {
                    if (i == self.index) {
                        self.index += 1;
                        if (self.fsm.canTransitionTo(@intToEnum(StateType, field.value))) {
                            return @intToEnum(StateType, field.value);
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
            show_triggers: bool = true,
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
                    try writer.print(" \"{s}\" ", .{@tagName(@intToEnum(StateType, index))});
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
                const from = @intToEnum(StateType, index / state_type_count);
                const to = @intToEnum(StateType, index % state_type_count);

                try writer.print("    \"{s}\" -> \"{s}\"", .{ @tagName(from), @tagName(to) });

                if (TriggerType) |T| {
                    if (options.show_triggers) {
                        var triggers_start_offset = @intCast(usize, @enumToInt(from)) * trigger_type_count;
                        var transition_name_buf: [4096]u8 = undefined;
                        var transition_name = std.io.fixedBufferStream(&transition_name_buf);
                        var trigger_index: usize = 0;
                        while (trigger_index < trigger_type_count) : (trigger_index += 1) {
                            const slot_val = self.internal.triggers.get(triggers_start_offset + trigger_index);
                            if (slot_val > 0 and (slot_val - 1) == @enumToInt(to)) {
                                if ((try transition_name.getPos()) == 0) {
                                    try writer.print(" [label = \"", .{});
                                }
                                if ((try transition_name.getPos()) > 0) {
                                    try transition_name.writer().print(" || ", .{});
                                }
                                try transition_name.writer().print("{s}", .{@tagName(@intToEnum(T, trigger_index))});
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
            const LineState = enum { ready, source, target, trigger, await_start_state, startstate, await_end_states, endstates };
            const Input = enum { identifier, startcolon, endcolon, newline };
            const transition_table = [_]Transition(LineState, Input){
                .{ .trigger = .identifier, .from = .ready, .to = .source },
                .{ .trigger = .identifier, .from = .target, .to = .trigger },
                .{ .trigger = .identifier, .from = .trigger, .to = .trigger },
                .{ .trigger = .identifier, .from = .await_start_state, .to = .startstate },
                .{ .trigger = .identifier, .from = .await_end_states, .to = .endstates },
                .{ .trigger = .identifier, .from = .endstates, .to = .endstates },
                .{ .trigger = .identifier, .from = .source, .to = .target },
                .{ .trigger = .startcolon, .from = .ready, .to = .await_start_state },
                .{ .trigger = .endcolon, .from = .ready, .to = .await_end_states },
                .{ .trigger = .newline, .from = .ready, .to = .ready },
                .{ .trigger = .newline, .from = .startstate, .to = .ready },
                .{ .trigger = .newline, .from = .endstates, .to = .ready },
                .{ .trigger = .newline, .from = .target, .to = .ready },
                .{ .trigger = .newline, .from = .trigger, .to = .ready },
            };

            const FSM = StateMachineFromTable(LineState, Input, transition_table[0..], .ready, &.{});
            var fsm = FSM.init();

            const ParseHandler = struct {
                handler: FSM.Handler,
                fsm: *Self,
                from: ?StateType = null,
                to: ?StateType = null,
                current_identifer: []const u8 = "",

                pub fn init(fsmptr: *Self) @This() {
                    return .{
                        .handler = Interface.make(FSM.Handler, @This()),
                        .fsm = fsmptr,
                    };
                }

                pub fn onTransition(handler: *FSM.Handler, trigger: ?Input, from: LineState, to: LineState) HandlerResult {
                    const parse_handler = Interface.downcast(@This(), handler);
                    _ = from;
                    _ = trigger;

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
                    } else if (to == .trigger) {
                        if (TriggerType != null) {
                            const trigger_enum = std.meta.stringToEnum(TriggerType.?, parse_handler.current_identifer);
                            if (trigger_enum) |te| {
                                parse_handler.fsm.addTrigger(te, parse_handler.from.?, parse_handler.to.?) catch {
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

            var parse_handler = ParseHandler.init(self);
            var handlers: [1]*FSM.Handler = .{&parse_handler.handler};
            fsm.setTransitionHandlers(&handlers);

            var line_no: usize = 1;
            var lines = std.mem.split(u8, input, "\n");

            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "->") == null and std.mem.indexOf(u8, line, "start:") == null and std.mem.indexOf(u8, line, "end:") == null) continue;
                var parts = std.mem.tokenize(u8, line, " \t='\";,");
                while (parts.next()) |part| {
                    if (anyStringsEqual(&.{ "->", "[label", "]", "||" }, part)) {
                        continue;
                    } else if (std.mem.eql(u8, part, "start:")) {
                        try fsm.activateTrigger(.startcolon);
                    } else if (std.mem.eql(u8, part, "end:")) {
                        try fsm.activateTrigger(.endcolon);
                    } else {
                        parse_handler.current_identifer = part;
                        try fsm.activateTrigger(.identifier);
                    }
                }
                try fsm.activateTrigger(.newline);
                line_no += 1;
            }
            try fsm.activateTrigger(.newline);
        }
    };
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

/// An enum generator useful for testing, as well as state machines with sequenced states or triggers.
/// If `prefix` is an empty string, use @"0", @"1", etc to refer to the enum field.
pub fn GenerateConsecutiveEnum(comptime prefix: []const u8, comptime element_count: usize) type {
    const EnumField = std.builtin.Type.EnumField;
    var fields: []const EnumField = &[_]EnumField{};

    var i: usize = 0;
    while (i < element_count) : (i += 1) {
        comptime var tmp_buf: [128]u8 = undefined;
        const field_name = comptime try std.fmt.bufPrint(&tmp_buf, "{s}{d}", .{ prefix, i });
        fields = fields ++ &[_]EnumField{.{
            .name = field_name,
            .value = i,
        }};
    }
    return @Type(.{ .Enum = .{
        .layout = .Auto,
        .fields = fields,
        .tag_type = std.math.IntFittingRange(0, element_count),
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_exhaustive = false,
    } });
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;

test "generate state enums" {
    const State = GenerateConsecutiveEnum("S", 100);
    var fsm = StateMachine(State, null, .S0).init();
    try fsm.addTransition(.S0, .S1);
    try fsm.transitionTo(.S1);
    try expectEqual(fsm.currentState(), .S1);
}

test "minimal without trigger" {
    const State = enum { on, off };
    var fsm = StateMachine(State, null, .off).init();
    try fsm.addTransition(.on, .off);
    try fsm.addTransition(.off, .on);

    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);
}

test "comptime minimal without trigger" {
    comptime {
        const State = enum { on, off };
        var fsm = StateMachine(State, null, .off).init();
        try fsm.addTransition(.on, .off);
        try fsm.addTransition(.off, .on);

        try fsm.transitionTo(.on);
        try expectEqual(fsm.currentState(), .on);
    }
}

test "minimal with trigger" {
    const State = enum { on, off };
    const Trigger = enum { click };
    var fsm = StateMachine(State, Trigger, .off).init();
    try fsm.addTransition(.on, .off);
    try fsm.addTransition(.off, .on);
    try fsm.addTrigger(.click, .on, .off);
    try fsm.addTrigger(.click, .off, .on);

    // Transition manually
    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);

    // Transition through a trigger (event)
    try fsm.activateTrigger(.click);
    try expectEqual(fsm.currentState(), .off);
}

test "minimal with trigger defined using a table" {
    const State = enum { on, off };
    const Trigger = enum { click };
    const definition = [_]Transition(State, Trigger){
        .{ .trigger = .click, .from = .on, .to = .off },
        .{ .trigger = .click, .from = .off, .to = .on },
    };
    var fsm = StateMachineFromTable(State, Trigger, &definition, .off, &.{}).init();

    // Transition manually
    try fsm.transitionTo(.on);
    try expectEqual(fsm.currentState(), .on);

    // Transition through a trigger (event)
    try fsm.activateTrigger(.click);
    try expectEqual(fsm.currentState(), .off);
}

test "check state" {
    const State = enum { start, stop };
    const FSM = StateMachine(State, null, .start);

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

// Simple CSV parser based on the state model in https://ppolv.wordpress.com/2008/02/25/parsing-csv-in-erlang
// The main idea is that we classify incoming characters as InputEvent's. When a character arrives, we
// simply trigger the event. If the input is well-formed, we automatically move to the appropriate state.
// To actually extract CSV fields, we use a transition handler to keep track of where field slices starts and ends.
// If the input is incorrect we have detailed information about where it happens, and why based on states and triggers.
test "csv parser" {
    const State = enum { field_start, unquoted, quoted, post_quoted, done };
    const InputEvent = enum { char, quote, whitespace, comma, newline, anything_not_quote, eof };

    // Intentionally badly formatted csv to exercise corner cases
    const csv_input =
        \\"first",second,"third",4 
        \\  "more", right, here, 5
        \\  1,,b,c
    ;

    const FSM = StateMachine(State, InputEvent, .field_start);

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
                .handler = Interface.make(FSM.Handler, @This()),
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
                var input = reader.readByte() catch {
                    // An example of how to handle parsing errors
                    self.fsm.activateTrigger(.eof) catch {
                        try std.io.getStdErr().writer().print("Unexpected end of stream\n", .{});
                    };
                    return;
                };

                // The order of checks is important to classify input correctly
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

        /// We use state transitions to extract CSV field slices, and we're not using any extra memory.
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

                std.testing.expectEqualSlices(u8, found_field, expected_parse_result[self.line][self.col]) catch unreachable;
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

    var fsm = FSM.init();
    try fsm.addTriggerAndTransition(.whitespace, .field_start, .field_start);
    try fsm.addTriggerAndTransition(.whitespace, .unquoted, .unquoted);
    try fsm.addTriggerAndTransition(.whitespace, .post_quoted, .post_quoted);
    try fsm.addTriggerAndTransition(.char, .field_start, .unquoted);
    try fsm.addTriggerAndTransition(.char, .unquoted, .unquoted);
    try fsm.addTriggerAndTransition(.quote, .field_start, .quoted);
    try fsm.addTriggerAndTransition(.quote, .quoted, .post_quoted);
    try fsm.addTriggerAndTransition(.anything_not_quote, .quoted, .quoted);
    try fsm.addTriggerAndTransition(.comma, .post_quoted, .field_start);
    try fsm.addTriggerAndTransition(.comma, .unquoted, .field_start);
    try fsm.addTriggerAndTransition(.comma, .field_start, .field_start);
    try fsm.addTriggerAndTransition(.newline, .post_quoted, .field_start);
    try fsm.addTriggerAndTransition(.newline, .unquoted, .field_start);
    try fsm.addTriggerAndTransition(.eof, .unquoted, .done);
    try fsm.addTriggerAndTransition(.eof, .quoted, .done);
    try fsm.addFinalState(.done);

    try Parser.parse(&fsm, csv_input);
    try expect(fsm.isInFinalState());

    // Uncomment to generate a Graphviz diagram
    // try fsm.exportGraphviz("csv", std.io.getStdOut().writer(), .{.shape = "box", .shape_final_state = "doublecircle", .show_initial_state=true});
}

// Demonstrates that triggering a single "click" event can perpetually cycle through intensity states.
test "moore machine: three-level intensity light" {
    // Here we use anonymous state/trigger enums, Zig will still allow us to reference these
    var fsm = StateMachine(enum { off, dim, medium, bright }, enum { click }, .off).init();

    try fsm.addTriggerAndTransition(.click, .off, .dim);
    try fsm.addTriggerAndTransition(.click, .dim, .medium);
    try fsm.addTriggerAndTransition(.click, .medium, .bright);
    try fsm.addTriggerAndTransition(.click, .bright, .off);

    // Trigger a full cycle of off -> dim -> medium -> bright -> off

    try expect(fsm.isCurrently(.off));

    try fsm.activateTrigger(.click);
    try expect(fsm.isCurrently(.dim));

    try fsm.activateTrigger(.click);
    try expect(fsm.isCurrently(.medium));

    try fsm.activateTrigger(.click);
    try expect(fsm.isCurrently(.bright));

    try fsm.activateTrigger(.click);
    try expect(fsm.isCurrently(.off));

    try expect(fsm.canTransitionTo(.dim));
    try expect(!fsm.canTransitionTo(.medium));
    try expect(!fsm.canTransitionTo(.bright));
    try expect(!fsm.canTransitionTo(.off));

    // Uncomment to generate a Graphviz diagram
    // try fsm.exportGraphviz("lights", std.io.getStdOut().writer(), .{.layout = "circo", .shape = "box"});
}

test "handler that cancels" {
    const State = enum { on, off };
    const Trigger = enum { click };
    const FSM = StateMachine(State, Trigger, .off);
    var fsm = FSM.init();

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
    fsm.setTransitionHandlers(&.{&countingHandler.handler});
    try fsm.addTriggerAndTransition(.click, .on, .off);
    try fsm.addTriggerAndTransition(.click, .off, .on);

    try fsm.activateTrigger(.click);
    try fsm.activateTrigger(.click);

    // Third time will fail
    try expectError(StateError.Canceled, fsm.activateTrigger(.click));
}

// Implements https://en.wikipedia.org/wiki/Deterministic_finite_automaton#Example
test "comptime dfa: binary alphabet, require even number of zeros in input" {

    // Comptime use of triggers is commented out until this is fixed: https://github.com/ziglang/zig/issues/10694
    //comptime
    {
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
        var fsm = StateMachine(State, Bit, .S1).init();
        try fsm.importText(input);

        // With valid input, we wil end up in the final state
        const valid_input: []const Bit = &.{ .@"0", .@"0", .@"1", .@"1" };
        for (valid_input) |bit| try fsm.activateTrigger(bit);
        try expect(fsm.isInFinalState());

        // With invalid input, we will not end up in the final state
        const invalid_input: []const Bit = &.{ .@"0", .@"0", .@"0", .@"1" };
        for (invalid_input) |bit| try fsm.activateTrigger(bit);
        try expect(!fsm.isInFinalState());
    }
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

    var outbuf = std.ArrayList(u8).init(std.testing.allocator);
    defer outbuf.deinit();

    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Trigger = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var fsm = StateMachine(State, Trigger, .@"0").init();
    try fsm.importText(input);

    try fsm.apply(.{ .trigger = .@"SS(B)" });
    try expectEqual(fsm.currentState(), .@"2");
    try fsm.transitionTo(.@"6");
    try expectEqual(fsm.currentState(), .@"6");
    // Self-transition
    try fsm.activateTrigger(.@"S(b)");
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

    var outbuf = std.ArrayList(u8).init(std.testing.allocator);
    defer outbuf.deinit();

    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5" };
    const Trigger = enum { a, b, c };

    var fsm = StateMachine(State, Trigger, .@"0").init();
    try fsm.importText(input);

    try expectEqual(fsm.currentState(), .@"1");
    try fsm.transitionTo(.@"2");
    try expectEqual(fsm.currentState(), .@"2");
    try fsm.activateTrigger(.a);
    try expectEqual(fsm.currentState(), .@"3");
    try expect(fsm.isInFinalState());
}

// Implements the state diagram example from the Graphviz docs
test "export: graphviz export of finite automaton sample" {
    const State = enum { @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8" };
    const Trigger = enum { @"SS(B)", @"SS(S)", @"S($end)", @"SS(b)", @"SS(a)", @"S(A)", @"S(b)", @"S(a)", extra };

    var fsm = StateMachine(State, Trigger, .@"0").init();
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

    try fsm.addTrigger(.@"SS(B)", .@"0", .@"2");
    try fsm.addTrigger(.@"SS(S)", .@"0", .@"1");
    try fsm.addTrigger(.@"S($end)", .@"1", .@"3");
    try fsm.addTrigger(.@"SS(b)", .@"2", .@"6");
    try fsm.addTrigger(.@"SS(a)", .@"2", .@"5");
    try fsm.addTrigger(.@"S(A)", .@"2", .@"4");
    try fsm.addTrigger(.@"S(b)", .@"5", .@"7");
    try fsm.addTrigger(.@"S(a)", .@"5", .@"5");
    try fsm.addTrigger(.@"S(b)", .@"6", .@"6");
    try fsm.addTrigger(.@"S(a)", .@"6", .@"5");
    try fsm.addTrigger(.@"S(b)", .@"7", .@"8");
    try fsm.addTrigger(.@"S(a)", .@"7", .@"5");
    try fsm.addTrigger(.@"S(b)", .@"8", .@"6");
    try fsm.addTrigger(.@"S(a)", .@"8", .@"5");
    // This demonstrates that multiple triggers on the same transition are concatenated with ||
    try fsm.addTrigger(.extra, .@"8", .@"5");

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
    var fsm = StateMachine(Sum, Coin, .sum0).init();
    try fsm.importText(state_machine);

    // Add 5p, 10p and 10p coins
    try fsm.activateTrigger(.p5);
    try fsm.activateTrigger(.p10);
    try fsm.activateTrigger(.p10);

    // Car park charge reached
    try expect(fsm.isInFinalState());

    // Verify that we're unable to accept more coins
    try expectError(StateError.Invalid, fsm.activateTrigger(.p10));

    // Restart the state machine and try a different combination to reach 25p
    fsm.restart();
    try fsm.activateTrigger(.p20);
    try fsm.activateTrigger(.p5);
    try expect(fsm.isInFinalState());

    // Same as restart(), but makes sure we're currently in the start state or a final state
    try fsm.safeRestart();
    try fsm.activateTrigger(.p10);
    try expectError(StateError.Invalid, fsm.safeRestart());
    try fsm.activateTrigger(.p5);
    try fsm.activateTrigger(.p5);
    try fsm.activateTrigger(.p5);
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
    var fsm = StateMachine(Sum, Coin, .sum0).init();
    try fsm.importText(state_machine);

    var next_valid_iterator = fsm.validNextStatesIterator();
    try expectEqual(Sum.sum5, next_valid_iterator.next().?);
    try expectEqual(Sum.sum10, next_valid_iterator.next().?);
    try expectEqual(Sum.sum20, next_valid_iterator.next().?);
    try expectEqual(next_valid_iterator.next(), null);
}

/// An elevator state machine
const ElevatorTest = struct {
    const Elevator = enum { doors_opened, doors_closed, moving, exit_light_blinking };
    const ElevatorActions = enum { open, close, alarm };

    pub fn init() !StateMachine(Elevator, ElevatorActions, .doors_opened) {
        var fsm = StateMachine(Elevator, ElevatorActions, .doors_opened).init();
        try fsm.addTransition(.doors_opened, .doors_closed);
        try fsm.addTransition(.doors_closed, .moving);
        try fsm.addTransition(.moving, .moving);
        try fsm.addTransition(.doors_opened, .exit_light_blinking);
        try fsm.addTransition(.doors_closed, .doors_opened);
        try fsm.addTransition(.exit_light_blinking, .doors_opened);
        return fsm;
    }
};

test "elevator: redefine transition should fail" {
    var fsm = try ElevatorTest.init();
    try expectError(StateError.AlreadyDefined, fsm.addTransition(.doors_opened, .doors_closed));
}

test "elevator: apply" {
    var fsm = try ElevatorTest.init();
    try fsm.addTrigger(.alarm, .doors_opened, .exit_light_blinking);
    try fsm.apply(.{ .state = ElevatorTest.Elevator.doors_closed });
    try fsm.apply(.{ .state = ElevatorTest.Elevator.doors_opened });
    try fsm.apply(.{ .trigger = ElevatorTest.ElevatorActions.alarm });
    try expect(fsm.isCurrently(.exit_light_blinking));
}

test "elevator: transition success" {
    var fsm = try ElevatorTest.init();
    try fsm.transitionTo(.doors_closed);
    try expectEqual(fsm.currentState(), .doors_closed);
}

test "elevator: add a trigger and active it" {
    var fsm = try ElevatorTest.init();

    // The same trigger can be invoked for multiple state transitions
    try fsm.addTrigger(.alarm, .doors_opened, .exit_light_blinking);
    try expectEqual(fsm.currentState(), .doors_opened);

    try fsm.activateTrigger(.alarm);
    try expectEqual(fsm.currentState(), .exit_light_blinking);
}

test "statemachine from transition array" {
    const Elevator = enum { doors_opened, doors_closed, exit_light_blinking, moving };
    const Events = enum { open, close, alarm, notused1, notused2 };

    const defs = [_]Transition(Elevator, Events){
        .{ .trigger = .open, .from = .doors_closed, .to = .doors_opened },
        .{ .trigger = .open, .from = .doors_opened, .to = .doors_opened },
        .{ .trigger = .close, .from = .doors_opened, .to = .doors_closed },
        .{ .trigger = .close, .from = .doors_closed, .to = .doors_closed },
        .{ .trigger = .alarm, .from = .doors_closed, .to = .doors_opened },
        .{ .trigger = .alarm, .from = .doors_opened, .to = .exit_light_blinking },
        .{ .from = .doors_closed, .to = .moving },
        .{ .from = .moving, .to = .moving },
        .{ .from = .moving, .to = .doors_closed },
    };

    const final_states = [_]Elevator{};
    const FSM = StateMachineFromTable(Elevator, Events, defs[0..], .doors_closed, final_states[0..]);

    var fsm = FSM.init();

    try fsm.transitionTo(.doors_opened);
    try fsm.transitionTo(.doors_opened);
    if (!fsm.canTransitionTo(.moving)) {
        fsm.transitionTo(.moving) catch {};
        try fsm.transitionTo(.doors_closed);
        if (fsm.canTransitionTo(.moving)) try fsm.transitionTo(.moving);
        try fsm.transitionTo(.doors_closed);
    }
}
