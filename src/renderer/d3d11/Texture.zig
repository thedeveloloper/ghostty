//! Wrapper for an `ID3D11Texture2D` and its shader resource view.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a texture.
pub const Options = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,
    format: api.Format,
};

pub const Error = error{
    CreateTexture2DFailed,
    CreateShaderResourceViewFailed,
};

/// Underlying texture and its shader resource view.
texture: *api.ID3D11Texture2D,
srv: *api.ID3D11ShaderResourceView,

/// Options this texture was created with.
opts: Options,

/// Current dimensions of this texture.
width: usize,
height: usize,

pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const desc: api.Texture2DDesc = .{
        .Width = @intCast(width),
        .Height = @intCast(height),
        .Format = opts.format,
        .Usage = .default,
        .BindFlags = api.BIND_SHADER_RESOURCE,
    };

    var initial: api.SubresourceData = undefined;
    const initial_ptr: ?*const api.SubresourceData = if (data) |d| ptr: {
        initial = .{
            .pSysMem = d.ptr,
            .SysMemPitch = @intCast(rowPitch(opts.format, width)),
        };
        break :ptr &initial;
    } else null;

    const texture = try opts.device.createTexture2D(&desc, initial_ptr);
    errdefer texture.release();
    const srv = try opts.device.createShaderResourceView(texture.resource());

    return .{
        .texture = texture,
        .srv = srv,
        .opts = opts,
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: Self) void {
    self.srv.release();
    self.texture.release();
}

pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    // The renderer only ever replaces the full texture, so we update the
    // whole resource. A partial region would require a D3D11_BOX.
    _ = x;
    _ = y;
    _ = height;
    self.opts.context.updateSubresource(
        self.texture.resource(),
        0,
        data.ptr,
        @intCast(rowPitch(self.opts.format, width)),
        0,
    );
}

/// Bytes per row for a tightly packed image of the given format and width.
fn rowPitch(format: api.Format, width: usize) usize {
    return width * bytesPerPixel(format);
}

fn bytesPerPixel(format: api.Format) usize {
    return switch (format) {
        .r8_unorm => 1,
        .r8g8b8a8_unorm,
        .r8g8b8a8_unorm_srgb,
        .b8g8r8a8_unorm,
        .b8g8r8a8_unorm_srgb,
        => 4,
        .unknown => 0,
    };
}
