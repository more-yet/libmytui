const std = @import("std");
// Unicode line-break rules adapted from tui.zig (LICENSES/tui.zig-MIT.txt).
const unicode = @import("unicode.zig");

const Class = unicode.LineBreak;

pub const Kind = enum {
    prohibited,
    allowed,
    mandatory,
};

pub const Boundary = struct {
    offset: usize,
    kind: Kind,
};

const Scalar = struct {
    codepoint: u21,
    end: usize,
    raw: Class,
    class: Class,
    attached: bool = false,
    initial_punctuation: bool = false,
    final_punctuation: bool = false,
    east_asian: bool = false,
    unassigned: bool = false,
    extended_pictographic: bool = false,
};

const State = struct {
    left: ?Scalar = null,
    previous: ?Scalar = null,
    last_non_space: ?Scalar = null,
    last_non_space_predecessor: ?Scalar = null,
    regional_indicator_odd: bool = false,
    numeric_run: bool = false,
    numeric_run_before_left: bool = false,

    fn consume(self: *State, scalar: Scalar) void {
        const old_left = self.left;
        if (scalar.attached) {
            self.left = scalar;
            self.last_non_space = scalar;
            return;
        }
        self.previous = old_left;
        self.left = scalar;

        if (scalar.class != .sp) {
            self.last_non_space = scalar;
            self.last_non_space_predecessor = old_left;
        }

        self.numeric_run_before_left = self.numeric_run;
        self.numeric_run = scalar.class == .nu or
            ((scalar.class == .sy or scalar.class == .is) and self.numeric_run);
        self.regional_indicator_odd = if (scalar.class == .ri) !self.regional_indicator_odd else false;
    }

    fn classify(self: *const State, right: Scalar, right2: ?Scalar, right3: ?Scalar) Kind {
        const left = self.left.?;

        if (left.class == .cr and right.class == .lf) return .prohibited;
        if (isHard(left.class)) return .mandatory;
        if (isHard(right.class)) return .prohibited;

        if (right.class == .sp or right.class == .zw) return .prohibited;
        if (self.last_non_space != null and self.last_non_space.?.class == .zw) return .allowed;
        if (left.raw == .zwj) return .prohibited;
        if (right.attached) return .prohibited;

        if (left.class == .wj or right.class == .wj) return .prohibited;
        if (left.class == .gl) return .prohibited;
        if (right.class == .gl and !in(left.class, &.{ .sp, .ba, .hy, .hh })) return .prohibited;

        if (in(right.class, &.{ .cl, .cp, .ex, .sy })) return .prohibited;
        if (self.last_non_space != null and self.last_non_space.?.class == .op) return .prohibited;
        if (self.last_non_space) |quote| {
            if (quote.class == .qu and quote.initial_punctuation and
                isInitialQuotePredecessor(self.last_non_space_predecessor)) return .prohibited;
        }
        if (right.class == .qu and right.final_punctuation and isFinalQuoteFollower(right2)) {
            return .prohibited;
        }
        if (left.class == .sp and right.class == .is and right2 != null and right2.?.class == .nu) {
            return .allowed;
        }
        if (right.class == .is) return .prohibited;
        if (self.last_non_space) |previous_non_space| {
            if (in(previous_non_space.class, &.{ .cl, .cp }) and right.class == .ns) return .prohibited;
            if (previous_non_space.class == .b2 and right.class == .b2) return .prohibited;
        }

        if (left.class == .sp) return .allowed;

        if (right.class == .qu and !right.initial_punctuation) return .prohibited;
        if (left.class == .qu and !left.final_punctuation) return .prohibited;
        if (!left.east_asian and right.class == .qu) return .prohibited;
        if (right.class == .qu and (right2 == null or !right2.?.east_asian)) return .prohibited;
        if (left.class == .qu and !right.east_asian) return .prohibited;
        if (left.class == .qu and (self.previous == null or !self.previous.?.east_asian)) return .prohibited;
        if (left.class == .cb or right.class == .cb) return .allowed;
        if (in(left.class, &.{ .hy, .hh }) and in(right.class, &.{ .al, .hl }) and
            isWordInitialPredecessor(self.previous)) return .prohibited;

        if (in(right.class, &.{ .ba, .hh, .hy, .ns }) or left.class == .bb) return .prohibited;
        if (in(left.class, &.{ .hy, .hh }) and right.class != .hl and
            self.previous != null and self.previous.?.class == .hl) return .prohibited;
        if (left.class == .sy and right.class == .hl) return .prohibited;
        if (right.class == .in) return .prohibited;

        if (in(left.class, &.{ .al, .hl }) and right.class == .nu) return .prohibited;
        if (left.class == .nu and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (left.class == .pr and in(right.class, &.{ .id, .eb, .em })) return .prohibited;
        if (in(left.class, &.{ .id, .eb, .em }) and right.class == .po) return .prohibited;
        if (in(left.class, &.{ .pr, .po }) and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (in(left.class, &.{ .al, .hl }) and in(right.class, &.{ .pr, .po })) return .prohibited;
        if (in(left.class, &.{ .cl, .cp }) and in(right.class, &.{ .po, .pr }) and
            self.numeric_run_before_left) return .prohibited;
        if (self.numeric_run and in(right.class, &.{ .po, .pr, .nu })) return .prohibited;
        if (in(left.class, &.{ .po, .pr })) {
            if (right.class == .nu) return .prohibited;
            if (right.class == .op and right2 != null) {
                if (right2.?.class == .nu) return .prohibited;
                if (right2.?.class == .is and right3 != null and right3.?.class == .nu) return .prohibited;
            }
        }
        if (in(left.class, &.{ .hy, .is }) and right.class == .nu) return .prohibited;

        if (left.class == .jl and in(right.class, &.{ .jl, .jv, .h2, .h3 })) return .prohibited;
        if (in(left.class, &.{ .jv, .h2 }) and in(right.class, &.{ .jv, .jt })) return .prohibited;
        if (in(left.class, &.{ .jt, .h3 }) and right.class == .jt) return .prohibited;
        if (isHangul(left.class) and right.class == .po) return .prohibited;
        if (left.class == .pr and isHangul(right.class)) return .prohibited;

        if (in(left.class, &.{ .al, .hl }) and in(right.class, &.{ .al, .hl })) return .prohibited;
        if (left.class == .ap and isAksaraBase(right)) return .prohibited;
        if (isAksaraBase(left) and in(right.class, &.{ .vf, .vi })) return .prohibited;
        if (left.class == .vi and isAksaraBaseWithoutStart(right) and
            self.previous != null and isAksaraBase(self.previous.?)) return .prohibited;
        if (isAksaraBase(left) and isAksaraBase(right) and right2 != null and right2.?.class == .vf) {
            return .prohibited;
        }
        if (left.class == .is and in(right.class, &.{ .al, .hl })) return .prohibited;

        if (in(left.class, &.{ .al, .hl, .nu }) and right.class == .op and !right.east_asian) {
            return .prohibited;
        }
        if (left.class == .cp and !left.east_asian and in(right.class, &.{ .al, .hl, .nu })) {
            return .prohibited;
        }
        if (left.class == .ri and right.class == .ri and self.regional_indicator_odd) {
            return .prohibited;
        }
        if ((left.class == .eb or left.extended_pictographic and left.unassigned) and right.class == .em) {
            return .prohibited;
        }

        return .allowed;
    }
};

pub const Iterator = struct {
    input: []const u8,
    offset: usize = 0,
    finished: bool = false,
    state: State = .{},
    ahead: [3]?Scalar = .{ null, null, null },

    pub fn next(self: *Iterator) ?Boundary {
        if (self.finished) return null;
        if (self.offset == self.input.len) {
            self.finished = true;
            return .{ .offset = self.offset, .kind = .mandatory };
        }

        var start = self.offset;
        var previous = self.state.left;
        for (&self.ahead) |*entry| {
            if (entry.* == null and start < self.input.len) {
                entry.* = decodeScalar(self.input, start, previous);
            }
            const scalar = entry.* orelse break;
            start = scalar.end;
            previous = scalar;
        }
        const right = self.ahead[0].?;
        const boundary: Boundary = .{
            .offset = self.offset,
            .kind = if (self.state.left == null) .prohibited else self.state.classify(right, self.ahead[1], self.ahead[2]),
        };
        self.state.consume(right);
        self.offset = right.end;
        self.ahead = .{ self.ahead[1], self.ahead[2], null };
        return boundary;
    }
};

fn decodeScalar(input: []const u8, start: usize, previous: ?Scalar) Scalar {
    const sequence_len = std.unicode.utf8ByteSequenceLength(input[start]) catch unreachable;
    const end = start + sequence_len;
    const codepoint = std.unicode.utf8Decode(input[start..end]) catch unreachable;
    const props = unicode.lookup(codepoint);
    const raw: Class = switch (props.line) {
        .ai, .sg, .xx => .al,
        .cj => .ns,
        .sa => if (props.combining) .cm else .al,
        else => props.line,
    };
    if (in(raw, &.{ .cm, .zwj })) {
        if (previous) |base| {
            if (!in(base.class, &.{ .bk, .cr, .lf, .nl, .sp, .zw })) {
                var mark = base;
                mark.raw = raw;
                mark.end = end;
                mark.attached = true;
                return mark;
            }
        }
        return .{ .codepoint = 'A', .raw = raw, .class = .al, .end = end };
    }
    return .{
        .codepoint = codepoint,
        .end = end,
        .raw = raw,
        .class = raw,
        .initial_punctuation = props.initial,
        .final_punctuation = props.final,
        .east_asian = props.wide or props.halfwidth,
        .unassigned = props.unassigned,
        .extended_pictographic = props.pictographic,
    };
}

fn isHard(class: Class) bool {
    return in(class, &.{ .bk, .cr, .lf, .nl });
}

fn isInitialQuotePredecessor(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw });
}

fn isFinalQuoteFollower(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw });
}

fn isWordInitialPredecessor(value: ?Scalar) bool {
    if (value == null) return true;
    return in(value.?.class, &.{ .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl });
}

fn isHangul(class: Class) bool {
    return in(class, &.{ .jl, .jv, .jt, .h2, .h3 });
}

fn isAksaraBase(value: Scalar) bool {
    return in(value.class, &.{ .ak, .as }) or value.codepoint == 0x25cc;
}

fn isAksaraBaseWithoutStart(value: Scalar) bool {
    return value.class == .ak or value.codepoint == 0x25cc;
}

fn in(value: Class, comptime values: []const Class) bool {
    inline for (values) |candidate| if (value == candidate) return true;
    return false;
}

test "Unicode 17 default line break conformance" {
    const corpus = @embedFile("line_cases");
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        var bytes: [2048]u8 = undefined;
        var expected: [512]bool = undefined;
        var n: usize = 0;
        var len: usize = 0;
        while (tokens.next()) |mark| {
            expected[n] = std.mem.eql(u8, mark, "÷");
            n += 1;
            const cp = tokens.next() orelse break;
            len += try std.unicode.utf8Encode(try std.fmt.parseInt(u21, cp, 16), bytes[len..][0..4]);
        }
        if (n == 0) continue;
        var it: Iterator = .{ .input = bytes[0..len] };
        for (expected[0..n]) |allow| {
            const actual = it.next().?.kind != .prohibited;
            if (allow != actual) std.debug.print("{s}\n", .{line});
            try std.testing.expectEqual(allow, actual);
        }
        try std.testing.expect(it.next() == null);
    }
}
