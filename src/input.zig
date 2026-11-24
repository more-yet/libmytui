const std = @import("std");
const Size = @import("geometry.zig").Size;

pub const Mouse = struct {
    x: u16,
    y: u16,
    action: enum { press, release, move, drag, wheel },
    button: enum(u8) { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right, extra1, extra2, extra3, extra4 },
    shift: bool,
    alt: bool,
    control: bool,
};

pub const Reply = union(enum) {
    raw: []const u8,
    cursor: struct { x: u16, y: u16 },
    keyboard_flags: u32,
    mode: struct { number: u16, state: u3 },
    graphics: GraphicsReply,
};
pub const GraphicsReply = struct {
    id: u32,
    placement: ?u32 = null,
    number: ?u32 = null,
    frame: ?u32 = null,
    ok: bool,
    message: []const u8,
    pub fn matches(self: GraphicsReply, ids: @import("graphics/kitty.zig").Identifiers) bool {
        if (ids.image_id == 0 and ids.image_number == 0) return false;
        return (ids.image_id == 0 or ids.image_id == self.id) and (ids.image_number == 0 or ids.image_number == self.number) and (ids.placement_id == 0 or ids.placement_id == self.placement);
    }
    pub fn remoteError(self: GraphicsReply) ?struct { code: []const u8, detail: []const u8 } {
        if (self.ok) return null;
        const i = std.mem.indexOfScalar(u8, self.message, ':') orelse self.message.len;
        return .{ .code = self.message[0..i], .detail = self.message[if (i == self.message.len) i else i + 1..] };
    }
};

pub const Key = struct {
    code: union(enum) {
        character: u21,
        enter,
        tab,
        backspace,
        escape,
        up,
        down,
        left,
        right,
        home,
        end,
        delete,
        page_up,
        page_down,
        insert,
        function: u8,
        functional: u21,
    },
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    action: enum { press, repeat, release } = .press,
    shifted: ?u21 = null,
    base: ?u21 = null,
    text: []const u8 = "",

    pub fn is(self: Key, character: u21) bool {
        return self.action != .release and self.code == .character and self.code.character == character and
            !self.control and !self.alt and !self.super and !self.hyper and !self.meta;
    }
};

pub const Event = union(enum) {
    key: Key,
    mouse: Mouse,
    focus: bool,
    reply: Reply,
    paste: []const u8,
    paste_start,
    paste_chunk: []const u8,
    paste_end: struct { status: enum { complete, cancelled, invalid, truncated }, tail: []const u8 = "" },
    malformed: enum { utf8, paste, incomplete },
    resize: Size,
    timer: @import("schedule.zig").Timer,
    ready: @import("schedule.zig").Ready,
    input_overflow,
    screen_clear,
    graphics_sent,

    pub fn owned(self: Event, allocator: std.mem.Allocator) !OwnedEvent {
        const copy = try allocator.alloc(u8, self.payloadBytes());
        var result = self.ownedStorage(copy) catch unreachable;
        result.allocator = allocator;
        return result;
    }
    fn payload(self: *Event) ?*[]const u8 {
        return switch (self.*) {
            .paste => &self.paste,
            .paste_chunk => &self.paste_chunk,
            .paste_end => &self.paste_end.tail,
            .key => &self.key.text,
            .reply => switch (self.reply) {
                .raw => &self.reply.raw,
                .graphics => &self.reply.graphics.message,
                else => null,
            },
            else => null,
        };
    }
    pub fn payloadBytes(self: Event) usize {
        var event = self;
        return if (event.payload()) |s| s.len else 0;
    }
    pub fn ownedStorage(self: Event, storage: []u8) !OwnedEvent {
        var event = self;
        const s = event.payload() orelse return .{ .event = event, .payload = storage[0..0] };
        if (storage.len < s.len) return error.EventCapacity;
        const copy = storage[0..s.len];
        @memcpy(copy, s.*);
        s.* = copy;
        return .{ .event = event, .payload = copy };
    }
};

pub const OwnedEvent = struct {
    event: Event,
    allocator: ?std.mem.Allocator = null,
    payload: []u8,
    pub fn deinit(self: *OwnedEvent) void {
        std.crypto.secureZero(u8, self.payload);
        if (self.allocator) |a| a.free(self.payload);
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

pub const Parser = struct {
    pub const State = enum { ground, escape, escape_intermediate, utf8, csi, discard_csi, ss3, string, string_escape, discard_mouse, paste };
    const paste_end = "\x1b[201~";

    state: State = .ground,
    sequence: [256]u8 = undefined,
    associated: [256]u8 = undefined,
    len: usize = 0,
    utf8_expected: u3 = 0,
    alt: bool = false,
    osc: bool = false,
    apc: bool = false,
    paste: []u8,
    paste_len: usize = 0,
    paste_match: usize = 0,
    paste_overflow: bool = false,
    streamed: bool = false,
    paste_status: @FieldType(@FieldType(Event, "paste_end"), "status") = .complete,
    raw_replies: bool = false,
    raw: [260]u8 = undefined,
    raw_len: usize = 0,

    pub fn init(paste_storage: []u8) Parser {
        return .{ .paste = paste_storage };
    }
    pub fn initStreamed(chunk: []u8) !Parser {
        if (chunk.len < 16) return error.PasteChunkCapacity;
        return .{ .paste = chunk, .streamed = true };
    }
    pub fn cancelPaste(self: *Parser) void {
        if (self.state == .paste and self.streamed) {
            self.paste_status = .cancelled;
            self.paste_len = 0;
        }
    }

    pub fn finish(self: *Parser) ?Event {
        const state = self.state;
        self.state = .ground;
        return switch (state) {
            .ground => null,
            .escape => .{ .key = .{ .code = .escape } },
            .paste => if (self.streamed) .{ .paste_end = .{ .status = .truncated } } else .{ .malformed = .incomplete },
            else => .{ .malformed = .incomplete },
        };
    }
    pub fn timeoutKind(self: *const Parser) ?enum { escape, sequence } {
        return switch (self.state) {
            .escape => .escape,
            .utf8, .csi, .ss3 => .sequence,
            else => null,
        };
    }

    pub fn expire(self: *Parser) ?Event {
        switch (self.state) {
            .escape => {
                self.state = .ground;
                return .{ .key = .{ .code = .escape } };
            },
            .csi, .ss3 => self.state = .discard_csi,
            .utf8 => {
                self.state = .ground;
                return .{ .malformed = .utf8 };
            },
            else => {},
        }
        return null;
    }

    pub fn feed(self: *Parser, byte: u8) ?Event {
        if (!self.raw_replies) return self.decode(byte);
        const before = self.state;
        if (before == .ground or (byte == 27 and before != .string and before != .string_escape)) self.raw_len = 0;
        if (self.raw_len < self.raw.len) self.raw[self.raw_len] = byte;
        self.raw_len +|= 1;
        const event = self.decode(byte);
        if (event != null or self.state != .ground or byte == 0x18 or byte == 0x1a) return event;
        switch (before) {
            .csi, .string, .string_escape => return if (self.raw_len <= self.raw.len) .{ .reply = .{ .raw = self.raw[0..self.raw_len] } } else .input_overflow,
            .discard_csi => return if (self.len == self.sequence.len or self.raw_len > self.raw.len) .input_overflow else null,
            else => return null,
        }
    }
    fn decode(self: *Parser, byte: u8) ?Event {
        if (self.state != .ground and self.state != .paste and (byte == 0x18 or byte == 0x1a)) {
            self.state = .ground;
            return null;
        }
        if (byte == 0x1b) switch (self.state) {
            .paste, .string, .string_escape, .discard_mouse => {},
            else => {
                self.state = .escape;
                return null;
            },
        };
        switch (self.state) {
            .paste => {
                if (byte == paste_end[self.paste_match]) {
                    self.paste_match += 1;
                    if (self.paste_match != paste_end.len) return null;
                    self.state = .ground;
                    self.paste_match = 0;
                    if (self.streamed) {
                        if (self.paste_status == .complete and self.len != 0) self.paste_status = .invalid;
                        return .{ .paste_end = .{ .status = self.paste_status, .tail = if (self.paste_status == .complete) self.paste[0..self.paste_len] else "" } };
                    }
                    if (self.paste_overflow) return .input_overflow;
                    const bytes = self.paste[0..self.paste_len];
                    return if (std.unicode.utf8ValidateSlice(bytes)) .{ .paste = bytes } else .{ .malformed = .paste };
                }
                for (paste_end[0..self.paste_match]) |pending| self.appendPaste(pending);
                self.paste_match = 0;
                if (byte == paste_end[0]) self.paste_match = 1 else self.appendPaste(byte);
                if (self.streamed and self.paste_status == .complete and self.len == 0 and self.paste_len >= self.paste.len - 9) {
                    const chunk = self.paste[0..self.paste_len];
                    self.paste_len = 0;
                    return .{ .paste_chunk = chunk };
                }
                return null;
            },
            .string, .string_escape => {
                if (self.apc and byte != 0x1b and byte != 0x9c and !(self.state == .string_escape and byte == '\\')) {
                    if (self.len == self.sequence.len or byte < 0x20 or byte > 0x7e or self.state == .string_escape) {
                        self.apc = false;
                    } else {
                        self.sequence[self.len] = byte;
                        self.len += 1;
                    }
                }
                if (self.utf8_expected != 0 and byte & 0xc0 == 0x80) {
                    self.utf8_expected -= 1;
                    return null;
                }
                self.utf8_expected = 0;
                if ((self.state == .string_escape and byte == '\\') or byte == 0x9c or (self.osc and byte == 7)) {
                    self.state = .ground;
                    if (self.apc) return graphicsReply(self.sequence[0..self.len]);
                } else {
                    self.state = if (byte == 0x1b) .string_escape else .string;
                    if (byte >= 0xc2 and byte <= 0xf4)
                        self.utf8_expected = (std.unicode.utf8ByteSequenceLength(byte) catch unreachable) - 1;
                }
                return null;
            },
            .discard_mouse => {
                self.len += 1;
                if (self.len == 3) self.state = .ground;
                return null;
            },
            .discard_csi => {
                if (byte >= 0x40 and byte <= 0x7e) self.state = .ground;
                return null;
            },
            .escape_intermediate => {
                if (byte >= 0x30 and byte <= 0x7e) self.state = .ground;
                return null;
            },
            .csi, .ss3 => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    const ss3 = self.state == .ss3;
                    self.state = .ground;
                    if (!ss3 and self.len == 0 and byte == 'M') {
                        self.state = .discard_mouse;
                        return null;
                    }
                    if (!ss3 and byte == '~' and std.mem.eql(u8, self.sequence[0..self.len], "200")) {
                        self.state = .paste;
                        self.paste_len = 0;
                        self.paste_match = 0;
                        self.paste_overflow = false;
                        self.paste_status = .complete;
                        self.len = 0;
                        return if (self.streamed) .paste_start else null;
                    }
                    return self.keySequence(byte, ss3);
                }
                if (byte < 0x20 or byte > 0x3f or self.len == self.sequence.len) {
                    self.state = .discard_csi;
                } else {
                    self.sequence[self.len] = byte;
                    self.len += 1;
                }
                return null;
            },
            .utf8 => {
                if (byte & 0xc0 == 0x80) {
                    self.sequence[self.len] = byte;
                    self.len += 1;
                    if (self.len < self.utf8_expected) return null;
                    self.state = .ground;
                    const cp = std.unicode.utf8Decode(self.sequence[0..self.len]) catch return .{ .malformed = .utf8 };
                    return .{ .key = .{ .code = .{ .character = cp }, .alt = self.alt } };
                }
                self.state = .ground;
                self.alt = false;
            },
            .escape => {
                self.state = .ground;
                switch (byte) {
                    0x20...0x2f => {
                        self.state = .escape_intermediate;
                        return null;
                    },
                    '[' => {
                        self.state = .csi;
                        self.len = 0;
                        return null;
                    },
                    'O' => {
                        self.state = .ss3;
                        self.len = 0;
                        return null;
                    },
                    ']', 'P', '_', '^', 'X' => {
                        self.state = .string;
                        self.osc = byte == ']';
                        self.apc = byte == '_';
                        self.len = 0;
                        self.utf8_expected = 0;
                        return null;
                    },
                    else => {},
                }
                self.alt = true;
            },
            .ground => self.alt = false,
        }
        if (byte == 0x9b or byte == 0x8f) {
            self.state = if (byte == 0x9b) .csi else .ss3;
            self.len = 0;
            return null;
        }
        if (byte == 0x90 or byte == 0x98 or byte == 0x9d or byte == 0x9e or byte == 0x9f) {
            self.state = .string;
            self.osc = byte == 0x9d;
            self.apc = byte == 0x9f;
            self.len = 0;
            self.utf8_expected = 0;
            return null;
        }
        const key: Key = switch (byte) {
            9 => .{ .code = .tab, .alt = self.alt },
            10, 13 => .{ .code = .enter, .alt = self.alt },
            8, 127 => .{ .code = .backspace, .alt = self.alt },
            1...7, 11, 12, 14...26 => .{ .code = .{ .character = byte + 'a' - 1 }, .control = true, .alt = self.alt },
            0x20...0x7e => .{ .code = .{ .character = byte }, .alt = self.alt },
            0xc2...0xf4 => {
                self.utf8_expected = std.unicode.utf8ByteSequenceLength(byte) catch unreachable;
                self.sequence[0] = byte;
                self.len = 1;
                self.state = .utf8;
                return null;
            },
            else => return if (byte >= 0xa0) .{ .malformed = .utf8 } else null,
        };
        return .{ .key = key };
    }

    fn appendPaste(self: *Parser, byte: u8) void {
        if (self.paste_status != .complete) return;
        if (self.paste_len == self.paste.len) {
            self.paste_overflow = true;
            return;
        }
        self.paste[self.paste_len] = byte;
        self.paste_len += 1;
        if (!self.streamed) return;
        if (self.len == 0) self.utf8_expected = std.unicode.utf8ByteSequenceLength(byte) catch {
            self.paste_status = .invalid;
            return;
        };
        self.len += 1;
        if (self.len == self.utf8_expected) {
            _ = std.unicode.utf8Decode(self.paste[self.paste_len - self.len .. self.paste_len]) catch {
                self.paste_status = .invalid;
                return;
            };
            self.len = 0;
        }
    }

    fn keySequence(self: *Parser, final: u8, ss3: bool) ?Event {
        const parameters = self.sequence[0..self.len];
        var parts = std.mem.splitScalar(u8, parameters, ';');
        const first = parts.next().?;
        if (!ss3) {
            if ((final == 'I' or final == 'O') and parameters.len == 0) return .{ .focus = final == 'I' };
            if (first.len != 0 and first[0] == '?') {
                if (final == 'u' and parts.next() == null) return .{ .reply = .{ .keyboard_flags = number(u32, first[1..]) orelse return null } };
                if (final != 'y') return null;
                const state = parts.next() orelse return null;
                if (parts.next() != null or state.len != 2 or state[1] != '$' or state[0] < '0' or state[0] > '4') return null;
                return .{ .reply = .{ .mode = .{ .number = number(u16, first[1..]) orelse return null, .state = @intCast(state[0] - '0') } } };
            }
            if ((final == 'M' or final == 'm') and first.len != 0 and first[0] == '<') {
                const bits = number(u8, first[1..]) orelse return null;
                const x = number(u16, parts.next() orelse return null) orelse return null;
                const y = number(u16, parts.next() orelse return null) orelse return null;
                if (parts.next() != null) return null;
                return mouseReport(bits, x, y, final == 'm');
            }
            // A numeric CPR overlaps modified F3. Keep replies out of key bindings.
            if (final == 'R' and parameters.len != 0 and std.mem.indexOfScalar(u8, parameters, ':') == null) {
                const row = number(u16, first) orelse return null;
                const col = number(u16, parts.next() orelse return null) orelse return null;
                if (row == 0 or col == 0 or parts.next() != null) return null;
                return .{ .reply = .{ .cursor = .{ .x = col - 1, .y = row - 1 } } };
            }
            if (final == 'u') {
                var ids = std.mem.splitScalar(u8, first, ':');
                const cp = codepoint(ids.next().?) orelse return null;
                var key: Key = .{ .code = switch (cp) {
                    27, 57344 => .escape,
                    13, 57345 => .enter,
                    9, 57346 => .tab,
                    127, 57347 => .backspace,
                    57348 => .insert,
                    57349 => .delete,
                    57350 => .left,
                    57351 => .right,
                    57352 => .up,
                    57353 => .down,
                    57354 => .page_up,
                    57355 => .page_down,
                    57356 => .home,
                    57357 => .end,
                    57364...57398 => .{ .function = @intCast(cp - 57363) },
                    57358...57363, 57399...63743 => .{ .functional = cp },
                    else => .{ .character = cp },
                } };
                if (ids.next()) |id| {
                    if (id.len != 0) key.shifted = codepoint(id) orelse return null;
                    if (ids.next()) |base| key.base = codepoint(base) orelse return null;
                    if (ids.next() != null) return null;
                }
                if (parts.next()) |mods| if (!modifiers(&key, mods)) return null;
                if (parts.next()) |chars| {
                    var codes = std.mem.splitScalar(u8, chars, ':');
                    var len: usize = 0;
                    while (codes.next()) |id| {
                        var utf8: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(codepoint(id) orelse return null, &utf8) catch unreachable;
                        if (n > self.associated.len - len) return null;
                        @memcpy(self.associated[len..][0..n], utf8[0..n]);
                        len += n;
                    }
                    key.text = self.associated[0..len];
                }
                if (parts.next() != null) return null;
                return .{ .key = key };
            }
        }
        var key: Key = .{ .code = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            'Z' => .tab,
            'P'...'S' => .{ .function = final - 'P' + 1 },
            '~' => switch (number(u8, first) orelse return null) {
                1, 7 => .home,
                2 => .insert,
                4, 8 => .end,
                3 => .delete,
                5 => .page_up,
                6 => .page_down,
                11...15 => |n| .{ .function = n - 10 },
                17...21 => |n| .{ .function = n - 11 },
                23, 24 => |n| .{ .function = n - 12 },
                else => return null,
            },
            else => return null,
        } };
        if (final != '~' and first.len != 0 and !std.mem.eql(u8, first, "1")) return null;
        if (ss3 and parameters.len != 0) return null;
        if (parts.next()) |mods| if (!modifiers(&key, mods) or parts.next() != null) return null;
        if (final == 'Z') key.shift = true;
        return .{ .key = key };
    }
};

fn number(comptime T: type, bytes: []const u8) ?T {
    if (bytes.len == 0) return null;
    var value: T = 0;
    for (bytes) |b| {
        if (!std.ascii.isDigit(b)) return null;
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, b - '0') catch return null;
    }
    return value;
}

fn codepoint(s: []const u8) ?u21 {
    const cp = number(u21, s) orelse return null;
    return if (std.unicode.utf8ValidCodepoint(cp)) cp else null;
}

fn modifiers(key: *Key, bytes: []const u8) bool {
    var fields = std.mem.splitScalar(u8, bytes, ':');
    const mods = fields.next().?;
    const n = if (mods.len == 0) 1 else number(u16, mods) orelse return false;
    if (n == 0 or n > 256) return false;
    const bits = n - 1;
    key.shift = bits & 1 != 0;
    key.alt = bits & 2 != 0;
    key.control = bits & 4 != 0;
    key.super = bits & 8 != 0;
    key.hyper = bits & 16 != 0;
    key.meta = bits & 32 != 0;
    key.caps_lock = bits & 64 != 0;
    key.num_lock = bits & 128 != 0;
    if (fields.next()) |kind| key.action = switch (number(u8, kind) orelse return false) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => return false,
    };
    return fields.next() == null;
}

fn mouseReport(bits: u8, x: u16, y: u16, release: bool) ?Event {
    if (x == 0 or y == 0 or bits & 192 == 192) return null;
    const button = (bits & 3) + (if (bits & 128 != 0) @as(u8, 8) else if (bits & 64 != 0) @as(u8, 4) else 0);
    return .{ .mouse = .{
        .x = x - 1,
        .y = y - 1,
        .button = @fromBackingInt(button),
        .action = if (release) .release else if (bits & 64 != 0) .wheel else if (bits & 32 != 0) (if (button == 3) .move else .drag) else if (button == 3) .release else .press,
        .shift = bits & 4 != 0,
        .alt = bits & 8 != 0,
        .control = bits & 16 != 0,
    } };
}

fn graphicsReply(bytes: []const u8) ?Event {
    if (bytes.len < 2 or bytes[0] != 'G') return null;
    const split = std.mem.indexOfScalar(u8, bytes, ';') orelse return null;
    var fields = std.mem.splitScalar(u8, bytes[1..split], ',');
    var g: @FieldType(Reply, "graphics") = .{ .id = 0, .message = bytes[split + 1 ..], .ok = std.mem.eql(u8, bytes[split + 1 ..], "OK") };
    var seen: u4 = 0;
    if (g.message.len == 0) return null;
    while (fields.next()) |f| {
        if (f.len < 3 or f[1] != '=') return null;
        const bit: u4 = switch (f[0]) {
            'i' => 1,
            'I' => 2,
            'p' => 4,
            'r' => 8,
            else => 0,
        };
        if (seen & bit != 0) return null;
        seen |= bit;
        switch (f[0]) {
            'i' => g.id = number(u32, f[2..]) orelse return null,
            'I' => g.number = number(u32, f[2..]) orelse return null,
            'p' => g.placement = number(u32, f[2..]) orelse return null,
            'r' => g.frame = number(u32, f[2..]) orelse return null,
            else => {},
        }
    }
    return if (g.id != 0 or g.number != null) .{ .reply = .{ .graphics = g } } else null;
}

test "overflowed paste and ignored control strings preserve command framing" {
    var storage: [4]u8 = undefined;
    var parser = Parser.init(&storage);
    var overflows: usize = 0;
    var keys: usize = 0;
    for ("\x1b]Üq\x1b\\\x90\x07q\x9c\x9dq\x9c\x1b[1;\x1b[?9q\x1b#8\x1b[M\x00qq\x8fV\x1b[200~qqqqqq\x1b[201~q") |byte| {
        if (parser.feed(byte)) |event| switch (event) {
            .input_overflow => overflows += 1,
            .key => |key| {
                try std.testing.expect(key.is('q'));
                keys += 1;
            },
            else => return error.UnexpectedEvent,
        };
    }
    try std.testing.expectEqual(@as(usize, 1), overflows);
    try std.testing.expectEqual(@as(usize, 1), keys);
}

test "expired key reports retain framing through the final byte" {
    for ([_][]const u8{ "\x1b[1;", "\x1bO" }) |prefix| {
        var storage: [4]u8 = undefined;
        var parser = Parser.init(&storage);
        for (prefix) |byte| try std.testing.expect(parser.feed(byte) == null);
        try std.testing.expect(parser.timeoutKind() == .sequence);
        try std.testing.expect(parser.expire() == null);
        try std.testing.expect(parser.timeoutKind() == null);
        try std.testing.expect(parser.feed('q') == null);
        const event = parser.feed('x').?;
        try std.testing.expect(event == .key and event.key.is('x'));
    }
}

test "bounded raw reply framing and owned event erasure" {
    var p = Parser.init(&.{});
    p.raw_replies = true;
    const raw = "\x1b]999;payload\x1b\\";
    for (raw[0 .. raw.len - 1]) |b| try std.testing.expect(p.feed(b) == null);
    const reply = p.feed('\\').?;
    var storage: [raw.len]u8 = undefined;
    try std.testing.expectError(error.EventCapacity, reply.ownedStorage(storage[1..]));
    var owned = try reply.ownedStorage(&storage);
    var event: ?Event = null;
    for ("\x1b_Gi=4,p=2,r=3;EINVAL:bad frame\x1b\\") |b| event = p.feed(b);
    const g = event.?.reply.graphics;
    try std.testing.expect(g.matches(.{ .image_id = 4, .placement_id = 2 }) and g.frame == 3);
    try std.testing.expectEqualStrings("EINVAL", g.remoteError().?.code);
    try std.testing.expectEqualStrings(raw, owned.event.reply.raw);
    owned.deinit();
    try std.testing.expect(std.mem.allEqual(u8, &storage, 0));
}

test "owned key text survives reuse of parser storage" {
    var p = Parser.init(&.{});
    const report = "\x1b[97:65:113;256:2;101:769u";
    var key: Key = undefined;
    for (report) |b| if (p.feed(b)) |event| {
        key = event.key;
    };
    var saved = try (Event{ .key = key }).owned(std.testing.allocator);
    defer saved.deinit();
    for ("\x1b[98;;98u") |b| _ = p.feed(b);
    try std.testing.expectEqualStrings("e\u{301}", saved.event.key.text);
}

test "streamed paste stages complete UTF-8 and cancellation drains through the closing marker" {
    var buf: [16]u8 = undefined;
    var p = try Parser.initStreamed(&buf);
    var output: [64]u8 = undefined;
    var used: usize = 0;
    var ends: usize = 0;
    var keys: usize = 0;
    for ("\x1b[200~123456界\x1b[20xy\x1b[201~\x1b[200~abcdefgq\x1b[201~q") |b| {
        const ev = p.feed(b) orelse continue;
        switch (ev) {
            .paste_start => if (ends == 1) p.cancelPaste(),
            .paste_chunk => |chunk| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
                @memcpy(output[used..][0..chunk.len], chunk);
                used += chunk.len;
            },
            .paste_end => |end| {
                try std.testing.expectEqual(@as(@TypeOf(end.status), if (ends == 0) .complete else .cancelled), end.status);
                @memcpy(output[used..][0..end.tail.len], end.tail);
                used += end.tail.len;
                ends += 1;
            },
            .key => |k| {
                try std.testing.expect(k.is('q'));
                keys += 1;
            },
            else => return error.UnexpectedEvent,
        }
    }
    try std.testing.expectEqualStrings("123456界\x1b[20xy", output[0..used]);
    try std.testing.expect(ends == 2 and keys == 1);
    for ("\x1b[200~unclosed\x1b[20") |b| _ = p.feed(b);
    try std.testing.expect(p.finish().?.paste_end.status == .truncated and p.finish() == null);
}
