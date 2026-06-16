//! Wrapper for an `ID3D11Texture2D` and its shader resource view.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a texture.
pub const Options = struct {};

pub const Error = error{
    Unimplemented,
};

/// Underlying native texture handle.
texture: api.Texture,

/// Current width of this texture.
width: usize,
/// Current height of this texture.
height: usize,

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    _ = opts;
    _ = width;
    _ = height;
    _ = data;
    // TODO(windows): ID3D11Device::CreateTexture2D + CreateShaderResourceView.
    return error.Unimplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}

pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    _ = self;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = data;
    // TODO(windows): UpdateSubresource for the given region.
    return error.Unimplemented;
}
