const std = @import("std");
const unicode = @import("unicode.zig");
const W = unicode.Word;

fn scalar(bytes: []const u8, offset: *usize) unicode.Properties {
    const n = std.unicode.utf8ByteSequenceLength(bytes[offset.*]) catch unreachable;
    const cp = std.unicode.utf8Decode(bytes[offset.*..][0..n]) catch unreachable;
    offset.* += n;
    return unicode.lookup(cp);
}

fn ignored(w: W) bool {
    return w == .extend or w == .format or w == .zwj;
}
fn letter(w: W) bool {
    return w == .aletter or w == .hebrew_letter;
}
fn newline(w: W) bool {
    return w == .lf or w == .cr or w == .newline;
}
fn midLetter(w: W) bool {
    return w == .midletter or w == .midnumlet or w == .single_quote;
}
fn midNumber(w: W) bool {
    return w == .midnum or w == .midnumlet or w == .single_quote;
}
fn extendable(w: W) bool {
    return letter(w) or w == .numeric or w == .katakana or w == .extendnumlet;
}

/// UAX #29 default word segments over validated UTF-8, including separators.
pub const Words = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        const start = self.offset;
        if (start == self.bytes.len) return null;
        var raw = scalar(self.bytes, &self.offset).word;
        var prev = raw;
        var before: W = .other;
        var odd = raw == .regional_indicator;
        while (self.offset < self.bytes.len) {
            var end = self.offset;
            const props = scalar(self.bytes, &end);
            const w = props.word;
            const join = rules: {
                if (raw == .cr and w == .lf) break :rules true;
                if (newline(raw) or newline(w)) break :rules false;
                if ((raw == .zwj and props.pictographic) or (raw == .wsegspace and w == .wsegspace) or ignored(w)) break :rules true;
                if ((letter(prev) and (letter(w) or w == .numeric)) or
                    (prev == .numeric and (w == .numeric or letter(w))) or
                    (prev == .katakana and w == .katakana) or
                    (prev == .extendnumlet and extendable(w)) or (extendable(prev) and w == .extendnumlet) or
                    (prev == .hebrew_letter and w == .single_quote) or
                    (letter(before) and midLetter(prev) and letter(w)) or
                    (before == .hebrew_letter and prev == .double_quote and w == .hebrew_letter) or
                    (before == .numeric and midNumber(prev) and w == .numeric) or
                    (w == .regional_indicator and odd)) break :rules true;
                if ((letter(prev) and midLetter(w)) or (prev == .hebrew_letter and w == .double_quote) or
                    (prev == .numeric and midNumber(w)))
                {
                    var look = end;
                    while (look < self.bytes.len) {
                        const after = scalar(self.bytes, &look).word;
                        if (ignored(after)) continue;
                        break :rules if (w == .double_quote) after == .hebrew_letter else if (prev == .numeric) after == .numeric else letter(after);
                    }
                }
                break :rules false;
            };
            if (!join) break;
            self.offset = end;
            raw = w;
            if (!ignored(w)) {
                before = prev;
                prev = w;
                odd = w == .regional_indicator and !odd;
            }
        }
        return self.bytes[start..self.offset];
    }
};

test "Unicode 17 default word boundaries match every official case" {
    const corpus = @embedFile("word_cases");
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len], " \t\r");
        var bytes: [1024]u8 = undefined;
        var ends: [128]usize = undefined;
        var count: usize = 0;
        var len: usize = 0;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                if (len != 0) {
                    ends[count] = len;
                    count += 1;
                }
            } else if (!std.mem.eql(u8, token, "×"))
                len += try std.unicode.utf8Encode(try std.fmt.parseInt(u21, token, 16), bytes[len..][0..4]);
        }
        var it: Words = .{ .bytes = bytes[0..len] };
        for (ends[0..count]) |end| {
            _ = it.next() orelse return error.MissingSegment;
            if (end != it.offset) std.debug.print("{s}\n", .{line});
            try std.testing.expectEqual(end, it.offset);
        }
        try std.testing.expect(it.next() == null);
    }
}
