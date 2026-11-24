pub const kitty = @import("graphics/kitty.zig");
pub const Sender = @import("graphics/sender.zig").Sender;
pub const Limits = @import("graphics/sender.zig").Limits;
pub const placeholder = @import("graphics/placeholder.zig");

test "local media admission and cancellation preserve pending bytes" {
    const std = @import("std");
    var s = Sender.init(.{});
    defer s.deinit();
    const ids: kitty.Identifiers = .{ .image_id = 42 };
    inline for (.{ .file, .temporary_file, .shared_memory }) |medium| {
        const command: kitty.Command = .{ .animation_frame = .{ .transmission = .{ .medium = medium, .identifiers = ids, .width_pixels = 1, .height_pixels = 1, .data_size_bytes = 4 } } };
        try std.testing.expectError(error.InvalidLocalName, s.begin(command, "/a\x00b", .all));
        try s.begin(command, "/image", .errors_only);
        const bytes = s.outputStep().?;
        s.consumeOutput(1);
        try s.cancel(.{ .all = true });
        try std.testing.expectEqualStrings(bytes[1..], s.outputStep().?);
        s.consumeOutput(bytes.len - 1);
        const cleanup = s.outputStep().?;
        try std.testing.expectEqualStrings("\x1b_Ga=d,d=A,q=1;\x1b\\", cleanup);
        s.consumeOutput(cleanup.len);
    }
}
