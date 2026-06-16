//! Represents a render target.
//!
//! For Direct3D 11 this will wrap an `ID3D11Texture2D` and its
//! `ID3D11RenderTargetView` (either the swap chain back buffer or an
//! off-screen texture for custom shader passes).
const Self = @This();

const std = @import("std");

const log = std.log.scoped(.directx);

/// Options for initializing a Target.
pub const Options = struct {
    /// Desired width.
    width: usize,
    /// Desired height.
    height: usize,
};

/// Current width of this target.
width: usize,
/// Current height of this target.
height: usize,

pub fn init(opts: Options) !Self {
    // TODO(windows): allocate the backing ID3D11Texture2D + RTV.
    return .{
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}
