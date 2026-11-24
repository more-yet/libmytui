// Adapted from tui.zig (LICENSES/tui.zig-MIT.txt).
const std = @import("std");
const kitty = @import("kitty.zig");

pub const Limits = struct {
    max_payload_bytes: usize = 64 * 1024 * 1024,
    max_pixels: u64 = 100_000_000,
    /// Capped at `Sender.max_local_name_bytes`.
    max_local_name_bytes: usize = Sender.max_local_name_bytes,
};

pub const Sender = struct {
    pub const max_source_chunk_bytes = 3_072;
    pub const max_base64_chunk_bytes = std.base64.standard.Encoder.calcSize(max_source_chunk_bytes);
    pub const max_local_name_bytes = 2_048;
    pub const output_capacity = 4_608;

    comptime {
        const encoded_capacity = std.base64.standard.Encoder.calcSize(@max(max_source_chunk_bytes, max_local_name_bytes));
        std.debug.assert(output_capacity >= kitty.max_control_bytes + encoded_capacity + 6);
    }

    limits: Limits,
    kind: enum { command, transfer, animation } = .command,
    remaining: []const u8 = "",
    response: kitty.ResponseMode = .all,
    header: [kitty.max_control_bytes]u8 = undefined,
    header_len: usize = 0,
    pending_len: u16 = 0,
    pending_accepted: u16 = 0,
    output: [output_capacity]u8 = undefined,

    pub fn init(limits: Limits) Sender {
        return .{ .limits = limits };
    }

    pub fn isActive(self: *const Sender) bool {
        return self.header_len != 0 or self.remaining.len != 0 or self.pending_len != 0;
    }

    /// Release local state after draining output or closing the transport.
    pub fn deinit(self: *Sender) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    /// Keep `data` alive and unchanged until completion, including cancellation output.
    pub fn begin(self: *Sender, command: kitty.Command, data: []const u8, response: kitty.ResponseMode) !void {
        if (self.isActive()) return error.TransferActive;
        const tx = command.transmission();
        if (tx) |t| try self.validatePayload(t, data) else if (data.len != 0) return error.UnexpectedPayload;
        self.header_len = (try kitty.encodeControl(&self.header, command, .{ .response = response, .more_chunks = data.len > max_source_chunk_bytes })).len;
        self.kind = if (command == .animation_frame) .animation else if (tx != null) .transfer else .command;
        self.remaining = data;
        self.response = response;
    }

    /// Continue driving output after cancellation to drain the command and send its delete.
    pub fn cancel(self: *Sender, selector: kitty.DeleteSelector) !void {
        if (!self.isActive() or self.kind == .command) return error.NoActiveTransfer;
        self.header_len = (try kitty.encodeControl(&self.header, .{ .delete = selector }, .{ .response = self.response })).len;
        self.remaining = "";
        self.kind = .command;
    }

    pub fn outputStep(self: *Sender) ?[]const u8 {
        if (self.pending_len != 0) return self.output[self.pending_accepted..self.pending_len];
        if (!self.isActive()) return null;
        const n = @min(max_source_chunk_bytes, self.remaining.len);
        var w = std.Io.Writer.fixed(&self.output);
        w.writeAll("\x1b_G") catch unreachable;
        if (self.header_len != 0) {
            w.writeAll(self.header[0..self.header_len]) catch unreachable;
            self.header_len = 0;
        } else {
            if (self.kind == .animation) w.writeAll("a=f,") catch unreachable;
            w.writeAll(if (n < self.remaining.len) "m=1" else "m=0") catch unreachable;
            if (self.response != .all) w.writeAll(if (self.response == .none) ",q=2" else ",q=1") catch unreachable;
        }
        w.writeByte(';') catch unreachable;
        const encoder = std.base64.standard.Encoder;
        const dest = w.writableSlice(encoder.calcSize(n)) catch unreachable;
        _ = encoder.encode(dest, self.remaining[0..n]);
        self.remaining = self.remaining[n..];
        w.writeAll("\x1b\\") catch unreachable;
        self.pending_len = @intCast(w.end);
        return w.buffered();
    }

    pub fn consumeOutput(self: *Sender, count: usize) void {
        std.debug.assert(self.pending_len != 0 and count <= self.pending_len - self.pending_accepted);
        self.pending_accepted += @intCast(count);
        if (self.pending_accepted != self.pending_len) return;

        self.pending_len = 0;
        self.pending_accepted = 0;
    }

    fn validatePayload(self: *const Sender, tx: kitty.Transmission, bytes: []const u8) !void {
        if (tx.data_size_bytes > self.limits.max_payload_bytes) return error.PayloadLimitExceeded;
        const pixels = @as(u64, tx.width_pixels) * tx.height_pixels;
        if (pixels > self.limits.max_pixels) return error.PixelLimitExceeded;
        if (tx.format == .rgb or tx.format == .rgba) {
            if (tx.width_pixels == 0 or tx.height_pixels == 0) return error.InvalidDimensions;
        }
        if (tx.format == .png and tx.compression == .zlib and tx.data_size_bytes == 0) {
            return error.MissingDataSize;
        }
        if (tx.medium != .direct) {
            const name_limit = @min(self.limits.max_local_name_bytes, max_local_name_bytes);
            if (bytes.len == 0 or bytes.len > name_limit) return error.InvalidLocalName;
            if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidLocalName;
            if (tx.medium == .shared_memory and
                (bytes.len == 1 or bytes[0] != '/' or std.mem.indexOfScalar(u8, bytes[1..], '/') != null))
            {
                return error.InvalidLocalName;
            }
            if (tx.data_offset_bytes != 0 and tx.data_size_bytes == 0) return error.InvalidDataRange;
            _ = std.math.add(u32, tx.data_offset_bytes, tx.data_size_bytes) catch return error.DataRangeOverflow;
            return;
        }
        if (bytes.len > self.limits.max_payload_bytes) return error.PayloadLimitExceeded;
        if (bytes.len == 0) return error.InvalidDataLength;
        if (tx.data_offset_bytes != 0) return error.InvalidDataRange;
        if (tx.format == .png and tx.compression == .none) {
            try self.validatePng(bytes, tx);
        }
        if ((tx.format == .rgb or tx.format == .rgba) and tx.compression == .none) {
            const channels: u64 = if (tx.format == .rgb) 3 else 4;
            const expected = std.math.mul(u64, pixels, channels) catch return error.DimensionOverflow;
            if (expected != bytes.len) return error.InvalidDataLength;
        }
    }

    fn validatePng(self: *const Sender, bytes: []const u8, tx: kitty.Transmission) !void {
        const signature = "\x89PNG\r\n\x1a\n";
        if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..signature.len], signature) or
            !std.mem.eql(u8, bytes[8..12], "\x00\x00\x00\x0d") or
            !std.mem.eql(u8, bytes[12..16], "IHDR"))
        {
            return error.InvalidPng;
        }
        const width = std.mem.readInt(u32, bytes[16..20], .big);
        const height = std.mem.readInt(u32, bytes[20..24], .big);
        if (width == 0 or height == 0) return error.InvalidPng;
        if (tx.width_pixels != 0 and tx.width_pixels != width) return error.InvalidDimensions;
        if (tx.height_pixels != 0 and tx.height_pixels != height) return error.InvalidDimensions;
        const pixels = @as(u64, width) * height;
        if (pixels > self.limits.max_pixels) return error.PixelLimitExceeded;
    }
};
