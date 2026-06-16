//! Represents a render target: an off-screen `ID3D11Texture2D` with a render
//! target view (to draw into) and a shader resource view (so custom shader
//! passes can sample it). The final target is copied to the swap chain's back
//! buffer at present time.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a Target.
pub const Options = struct {
    device: *api.ID3D11Device,
    width: usize,
    height: usize,
    format: api.Format = .b8g8r8a8_unorm,
};

texture: *api.ID3D11Texture2D,
rtv: *api.ID3D11RenderTargetView,
srv: *api.ID3D11ShaderResourceView,

width: usize,
height: usize,

pub fn init(opts: Options) !Self {
    const desc: api.Texture2DDesc = .{
        .Width = @intCast(opts.width),
        .Height = @intCast(opts.height),
        .Format = opts.format,
        .Usage = .default,
        .BindFlags = api.BIND_RENDER_TARGET | api.BIND_SHADER_RESOURCE,
    };

    const texture = try opts.device.createTexture2D(&desc, null);
    errdefer texture.release();
    const rtv = try opts.device.createRenderTargetView(texture.resource());
    errdefer rtv.release();
    const srv = try opts.device.createShaderResourceView(texture.resource());

    return .{
        .texture = texture,
        .rtv = rtv,
        .srv = srv,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    self.srv.release();
    self.rtv.release();
    self.texture.release();
}
