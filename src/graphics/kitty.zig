// Adapted from tui.zig (LICENSES/tui.zig-MIT.txt).
const std = @import("std");

pub const specification_revision = "2026-09-16";
pub const specification_source =
    "https://github.com/kovidgoyal/kitty/blob/87ab3e98f4d399337777e4329960d7cd09101e99/docs/graphics-protocol.rst";
pub const max_control_bytes = 480;

pub const ResponseMode = enum(u2) {
    all = 0,
    /// Reports errors but suppresses successful `OK` replies.
    errors_only = 1,
    none = 2,
};

pub const Format = enum(u8) {
    rgb = 24,
    rgba = 32,
    png = 100,
};

pub const Medium = enum(u8) {
    direct = 'd',
    file = 'f',
    temporary_file = 't',
    shared_memory = 's',
};

pub const Compression = enum(u8) {
    none,
    zlib,
};

pub const Identifiers = struct {
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
};

pub const Transmission = struct {
    format: Format = .rgba,
    medium: Medium = .direct,
    width_pixels: u32 = 0,
    height_pixels: u32 = 0,
    data_size_bytes: u32 = 0,
    data_offset_bytes: u32 = 0,
    identifiers: Identifiers = .{},
    compression: Compression = .none,
    transient: bool = false,
};

pub const CursorPolicy = enum(u1) {
    move = 0,
    preserve = 1,
};

pub const Placement = struct {
    source_x_pixels: u32 = 0,
    source_y_pixels: u32 = 0,
    source_width_pixels: u32 = 0,
    source_height_pixels: u32 = 0,
    cell_x_offset_pixels: u32 = 0,
    cell_y_offset_pixels: u32 = 0,
    columns: u32 = 0,
    rows: u32 = 0,
    z_order: i32 = 0,
    cursor: CursorPolicy = .move,
    virtual: bool = false,
    parent_image_id: u32 = 0,
    parent_placement_id: u32 = 0,
    parent_x_cells: i32 = 0,
    parent_y_cells: i32 = 0,
};

pub const TransmitAndDisplay = struct {
    transmission: Transmission,
    placement: Placement,
};

pub const Display = struct {
    identifiers: Identifiers,
    placement: Placement,
};

pub const DeleteSelector = union(enum) {
    all: bool,
    image_id: struct { free_data: bool = false, image_id: u32, placement_id: u32 = 0 },
    image_number: struct { free_data: bool = false, image_number: u32, placement_id: u32 = 0 },
    cursor: bool,
    animation_frames: struct {
        free_data: bool = false,
        image_id: u32 = 0,
        image_number: u32 = 0,
        frame: u32 = 0,
    },
    cell: struct { free_data: bool = false, x: u32, y: u32 },
    cell_z: struct { free_data: bool = false, x: u32, y: u32, z_order: i32 },
    id_range: struct { free_data: bool = false, first: u32, last: u32 },
    column: struct { free_data: bool = false, x: u32 },
    row: struct { free_data: bool = false, y: u32 },
    z_order: struct { free_data: bool = false, z_order: i32 },
};

pub const CompositionMode = enum(u1) {
    alpha_blend = 0,
    overwrite = 1,
};

pub const AnimationFrame = struct {
    transmission: Transmission,
    destination_x_pixels: u32 = 0,
    destination_y_pixels: u32 = 0,
    base_frame: u32 = 0,
    edit_frame: u32 = 0,
    gap_ms: i32 = 0,
    composition: CompositionMode = .alpha_blend,
    background_rgba: u32 = 0,
};

pub const AnimationState = enum(u2) {
    stop = 1,
    run_wait = 2,
    run = 3,
};

pub const AnimationControl = struct {
    identifiers: Identifiers,
    state: ?AnimationState = null,
    frame: u32 = 0,
    gap_ms: i32 = 0,
    current_frame: u32 = 0,
    /// 0: unchanged; 1: forever; n > 1: n - 1 loops.
    loops: u32 = 0,
};

pub const ComposeFrames = struct {
    identifiers: Identifiers,
    destination_frame: u32,
    source_frame: u32,
    destination_x_pixels: u32 = 0,
    destination_y_pixels: u32 = 0,
    width_pixels: u32 = 0,
    height_pixels: u32 = 0,
    source_x_pixels: u32 = 0,
    source_y_pixels: u32 = 0,
    composition: CompositionMode = .alpha_blend,
};

pub const Command = union(enum) {
    transmit: Transmission,
    transmit_and_display: TransmitAndDisplay,
    display: Display,
    query: Transmission,
    delete: DeleteSelector,
    animation_frame: AnimationFrame,
    animation_control: AnimationControl,
    compose_frames: ComposeFrames,

    pub fn transmission(self: Command) ?Transmission {
        return switch (self) {
            .transmit, .query => |tx| tx,
            inline .transmit_and_display, .animation_frame => |value| value.transmission,
            else => null,
        };
    }
};

pub const EncodeContext = struct {
    more_chunks: bool = false,
    response: ResponseMode = .all,
};

pub const EncodeError = error{ BufferTooSmall, InvalidCommand };

fn validate(command: Command) error{InvalidCommand}!void {
    switch (command) {
        .transmit, .query => |tx| try validateIdentifiers(tx.identifiers, false),
        .transmit_and_display => |value| {
            try validateIdentifiers(value.transmission.identifiers, false);
            try validatePlacement(value.placement);
        },
        .display => |value| {
            try validateIdentifiers(value.identifiers, true);
            try validatePlacement(value.placement);
        },
        .delete => |selector| try validateDelete(selector),
        .animation_frame => |value| try validateIdentifiers(value.transmission.identifiers, true),
        .animation_control => |value| try validateIdentifiers(value.identifiers, true),
        .compose_frames => |value| {
            try validateIdentifiers(value.identifiers, true);
            if (value.destination_frame == 0 or value.source_frame == 0) return error.InvalidCommand;
        },
    }
}

fn validateIdentifiers(value: Identifiers, required: bool) error{InvalidCommand}!void {
    if (value.image_id != 0 and value.image_number != 0) return error.InvalidCommand;
    if (required and value.image_id == 0 and value.image_number == 0) return error.InvalidCommand;
}

fn validatePlacement(value: Placement) error{InvalidCommand}!void {
    const has_parent = value.parent_image_id != 0 or value.parent_placement_id != 0;
    if (value.virtual and has_parent) return error.InvalidCommand;
    if ((value.parent_image_id == 0) != (value.parent_placement_id == 0)) return error.InvalidCommand;
    if (!has_parent and (value.parent_x_cells != 0 or value.parent_y_cells != 0)) return error.InvalidCommand;
}

fn validateDelete(selector: DeleteSelector) error{InvalidCommand}!void {
    switch (selector) {
        .all, .cursor, .z_order => {},
        .image_id => |value| if (value.image_id == 0) return error.InvalidCommand,
        .image_number => |value| if (value.image_number == 0) return error.InvalidCommand,
        .animation_frames => |value| {
            try validateIdentifiers(.{ .image_id = value.image_id, .image_number = value.image_number }, true);
        },
        .cell => |value| if (value.x == 0 or value.y == 0) return error.InvalidCommand,
        .cell_z => |value| if (value.x == 0 or value.y == 0) return error.InvalidCommand,
        .id_range => |value| if (value.first == 0 or value.first > value.last) return error.InvalidCommand,
        .column => |value| if (value.x == 0) return error.InvalidCommand,
        .row => |value| if (value.y == 0) return error.InvalidCommand,
    }
}

/// Encodes control fields only. Use `Sender` for complete framed commands.
pub fn encodeControl(output: []u8, command: Command, context: EncodeContext) EncodeError![]const u8 {
    try validate(command);
    if (context.more_chunks) {
        const tx = command.transmission() orelse return error.InvalidCommand;
        if (tx.medium != .direct) return error.InvalidCommand;
    }
    var builder = Builder{ .buffer = output };
    switch (command) {
        .transmit, .query => |tx| {
            try builder.field('a', "{c}", if (command == .query) @as(u8, 'q') else 't');
            try builder.transmission(tx, context.more_chunks);
        },
        .transmit_and_display => |value| {
            try builder.field('a', "{c}", 'T');
            try builder.transmission(value.transmission, context.more_chunks);
            try builder.placement(value.placement);
        },
        .display => |value| {
            try builder.field('a', "{c}", 'p');
            try builder.identifiers(value.identifiers);
            try builder.placement(value.placement);
        },
        .delete => |value| {
            try builder.field('a', "{c}", 'd');
            try builder.delete(value);
        },
        .animation_frame => |value| {
            try builder.field('a', "{c}", 'f');
            try builder.transmission(value.transmission, context.more_chunks);
            try builder.optional('x', value.destination_x_pixels);
            try builder.optional('y', value.destination_y_pixels);
            try builder.optional('c', value.base_frame);
            try builder.optional('r', value.edit_frame);
            try builder.optional('z', value.gap_ms);
            try builder.field('X', "{d}", @backingInt(value.composition));
            try builder.optional('Y', value.background_rgba);
        },
        .animation_control => |value| {
            try builder.field('a', "{c}", 'a');
            try builder.identifiers(value.identifiers);
            if (value.state) |state| try builder.field('s', "{d}", @backingInt(state));
            try builder.optional('r', value.frame);
            try builder.optional('z', value.gap_ms);
            try builder.optional('c', value.current_frame);
            try builder.optional('v', value.loops);
        },
        .compose_frames => |value| {
            try builder.field('a', "{c}", 'c');
            try builder.identifiers(value.identifiers);
            try builder.field('c', "{d}", value.destination_frame);
            try builder.field('r', "{d}", value.source_frame);
            try builder.optional('x', value.destination_x_pixels);
            try builder.optional('y', value.destination_y_pixels);
            try builder.optional('w', value.width_pixels);
            try builder.optional('h', value.height_pixels);
            try builder.optional('X', value.source_x_pixels);
            try builder.optional('Y', value.source_y_pixels);
            try builder.field('C', "{d}", @backingInt(value.composition));
        },
    }
    if (context.response != .all) try builder.field('q', "{d}", @backingInt(context.response));
    return output[0..builder.len];
}

const Builder = struct {
    buffer: []u8,
    len: usize = 0,
    fn field(self: *Builder, key: u8, comptime format: []const u8, value: anytype) EncodeError!void {
        const sep: []const u8 = if (self.len == 0) "" else ",";
        const out = std.fmt.bufPrint(self.buffer[self.len..], "{s}{c}=" ++ format, .{ sep, key, value }) catch return error.BufferTooSmall;
        self.len += out.len;
    }
    fn optional(self: *Builder, key: u8, value: anytype) EncodeError!void {
        if (value != 0) try self.field(key, "{d}", value);
    }
    fn identifiers(self: *Builder, value: Identifiers) EncodeError!void {
        try self.optional('i', value.image_id);
        try self.optional('I', value.image_number);
        try self.optional('p', value.placement_id);
    }

    fn transmission(self: *Builder, value: Transmission, more_chunks: bool) EncodeError!void {
        try self.field('f', "{d}", @backingInt(value.format));
        try self.field('t', "{c}", @backingInt(value.medium));
        try self.optional('s', value.width_pixels);
        try self.optional('v', value.height_pixels);
        try self.optional('S', value.data_size_bytes);
        try self.optional('O', value.data_offset_bytes);
        try self.identifiers(value.identifiers);
        if (value.compression == .zlib) try self.field('o', "{c}", 'z');
        if (more_chunks) try self.field('m', "{d}", 1);
        if (value.transient) try self.field('N', "{d}", 1);
    }

    fn placement(self: *Builder, value: Placement) EncodeError!void {
        try self.optional('x', value.source_x_pixels);
        try self.optional('y', value.source_y_pixels);
        try self.optional('w', value.source_width_pixels);
        try self.optional('h', value.source_height_pixels);
        try self.optional('X', value.cell_x_offset_pixels);
        try self.optional('Y', value.cell_y_offset_pixels);
        try self.optional('c', value.columns);
        try self.optional('r', value.rows);
        try self.optional('z', value.z_order);
        if (value.cursor == .preserve) try self.field('C', "{d}", 1);
        if (value.virtual) try self.field('U', "{d}", 1);
        try self.optional('P', value.parent_image_id);
        try self.optional('Q', value.parent_placement_id);
        try self.optional('H', value.parent_x_cells);
        try self.optional('V', value.parent_y_cells);
    }

    fn delete(self: *Builder, selector: DeleteSelector) EncodeError!void {
        switch (selector) {
            .all => |free| try self.field('d', "{c}", if (free) @as(u8, 'A') else 'a'),
            .image_id => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'I') else 'i');
                try self.field('i', "{d}", value.image_id);
                try self.optional('p', value.placement_id);
            },
            .image_number => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'N') else 'n');
                try self.field('I', "{d}", value.image_number);
                try self.optional('p', value.placement_id);
            },
            .cursor => |free| try self.field('d', "{c}", if (free) @as(u8, 'C') else 'c'),
            .animation_frames => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'F') else 'f');
                try self.optional('i', value.image_id);
                try self.optional('I', value.image_number);
                try self.optional('r', value.frame);
            },
            .cell => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'P') else 'p');
                try self.field('x', "{d}", value.x);
                try self.field('y', "{d}", value.y);
            },
            .cell_z => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'Q') else 'q');
                try self.field('x', "{d}", value.x);
                try self.field('y', "{d}", value.y);
                try self.field('z', "{d}", value.z_order);
            },
            .id_range => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'R') else 'r');
                try self.field('x', "{d}", value.first);
                try self.field('y', "{d}", value.last);
            },
            .column => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'X') else 'x');
                try self.field('x', "{d}", value.x);
            },
            .row => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'Y') else 'y');
                try self.field('y', "{d}", value.y);
            },
            .z_order => |value| {
                try self.field('d', "{c}", if (value.free_data) @as(u8, 'Z') else 'z');
                try self.field('z', "{d}", value.z_order);
            },
        }
    }
};
