//! Graphics API wrapper for Direct3D 11.
//!
//! This is the native Windows rendering backend, analogous to the Metal
//! backend on macOS. It satisfies the graphics API interface consumed by
//! `generic.zig` and renders into a DXGI swap chain bound to the HWND that
//! the host application provides via the embedded apprt platform surface.
//!
//! NOTE: This is currently a scaffold. The interface is in place so the
//! backend compiles and is selectable, but the Direct3D 11 calls themselves
//! are not yet implemented (see the d3d11/ submodules).
pub const Direct3D11 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Direct3D11);

pub const GraphicsAPI = Direct3D11;
pub const Target = @import("d3d11/Target.zig");
pub const Frame = @import("d3d11/Frame.zig");
pub const RenderPass = @import("d3d11/RenderPass.zig");
pub const Pipeline = @import("d3d11/Pipeline.zig");
const bufferpkg = @import("d3d11/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("d3d11/Sampler.zig");
pub const Texture = @import("d3d11/Texture.zig");
pub const shaders = @import("d3d11/shaders.zig");
const api = @import("d3d11/api.zig");

// TODO(windows): custom shaders need an HLSL translation target added to
// shadertoy.Target (Phase 2f). Until then we report GLSL so the backend
// compiles; custom shaders are not yet functional on Direct3D.
pub const custom_shader_target: shadertoy.Target = .glsl;

// The fragCoord for Direct3D shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Number of frames to multi-buffer via the swap chain.
pub const swap_chain_count = 3;

const log = std.log.scoped(.directx);

alloc: std.mem.Allocator,

/// Alpha blending mode.
blending: configpkg.Config.AlphaBlending,

/// The Direct3D device and its immediate context.
device: *api.ID3D11Device,
context: *api.ID3D11DeviceContext,

/// The swap chain bound to the host's HWND, its back buffer (kept so present
/// can copy the final target into it), and the back buffer's render target
/// view.
swap_chain: *api.IDXGISwapChain,
back_buffer: *api.ID3D11Resource,
render_target: *api.ID3D11RenderTargetView,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Direct3D11 {
    // The host hands us an HWND via the embedded apprt platform surface.
    const hwnd = switch (opts.rt_surface.platform) {
        .windows => |v| v.hwnd,
        else => return error.UnsupportedPlatform,
    };

    // A width/height of zero tells DXGI to use the window's client size.
    var desc: api.SwapChainDesc = .{
        .BufferDesc = .{ .Format = .b8g8r8a8_unorm },
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = api.USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .OutputWindow = hwnd,
        .Windowed = 1,
        .SwapEffect = .discard,
    };

    var swap_chain: ?*api.IDXGISwapChain = null;
    var device: ?*api.ID3D11Device = null;
    var context: ?*api.ID3D11DeviceContext = null;
    const hr = api.D3D11CreateDeviceAndSwapChain(
        null,
        .hardware,
        null,
        api.CREATE_DEVICE_BGRA_SUPPORT,
        null,
        0,
        api.SDK_VERSION,
        &desc,
        &swap_chain,
        &device,
        null,
        &context,
    );
    if (api.FAILED(hr)) return error.D3D11CreateDeviceFailed;

    const dev = device orelse return error.D3D11CreateDeviceFailed;
    errdefer dev.release();
    const ctx = context orelse return error.D3D11CreateDeviceFailed;
    errdefer ctx.release();
    const sc = swap_chain orelse return error.D3D11CreateDeviceFailed;
    errdefer sc.release();

    // Create the render target view for the swap chain's back buffer. We keep
    // the back buffer handle so present can copy the final target into it.
    const back_buffer = try sc.getBuffer(0);
    errdefer back_buffer.release();
    const rtv = try dev.createRenderTargetView(back_buffer);

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = dev,
        .context = ctx,
        .swap_chain = sc,
        .back_buffer = back_buffer,
        .render_target = rtv,
    };
}

pub fn deinit(self: *Direct3D11) void {
    self.render_target.release();
    self.back_buffer.release();
    self.swap_chain.release();
    self.context.release();
    self.device.release();
    self.* = undefined;
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *Direct3D11) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
pub fn drawFrameEnd(self: *Direct3D11) void {
    _ = self;
}

pub fn initShaders(
    self: *const Direct3D11,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(self.device, self.alloc, custom_shaders);
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Direct3D11) !struct { width: u32, height: u32 } {
    const desc = try self.swap_chain.getDesc();
    return .{
        .width = @intCast(desc.BufferDesc.Width),
        .height = @intCast(desc.BufferDesc.Height),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Direct3D11, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        .width = width,
        .height = height,
        .format = .b8g8r8a8_unorm,
    });
}

/// Present the provided target.
pub fn present(self: *Direct3D11, target: Target) !void {
    self.last_target = target;

    // Keep the swap chain back buffer the same size as the target, resizing it
    // when the window (and thus the rendered target) has changed size. Without
    // this the back buffer and target dimensions diverge and CopyResource
    // fails after a resize.
    const desc = try self.swap_chain.getDesc();
    if (desc.BufferDesc.Width != target.width or desc.BufferDesc.Height != target.height) {
        try self.resizeSwapChain(@intCast(target.width), @intCast(target.height));
    }

    // Copy the rendered target into the swap chain back buffer, then present.
    self.context.copyResource(self.back_buffer, target.texture.resource());
    try self.swap_chain.present(1, 0);
}

/// Resize the swap chain back buffer and recreate its render target view.
fn resizeSwapChain(self: *Direct3D11, width: u32, height: u32) !void {
    // All references to the back buffer must be released before resizing.
    self.render_target.release();
    self.back_buffer.release();

    try self.swap_chain.resizeBuffers(width, height);

    const back_buffer = try self.swap_chain.getBuffer(0);
    errdefer back_buffer.release();
    const rtv = try self.device.createRenderTargetView(back_buffer);
    self.back_buffer = back_buffer;
    self.render_target = rtv;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *Direct3D11) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Returns the options to use when constructing vertex buffers.
pub inline fn bufferOptions(self: Direct3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind = api.BIND_VERTEX_BUFFER,
    };
}

/// Returns the options to use when constructing the uniform constant buffer.
pub inline fn uniformBufferOptions(self: Direct3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind = api.BIND_CONSTANT_BUFFER,
    };
}

/// Returns the options for per-instance cell/image data, read as structured
/// buffers (`StructuredBuffer<T>`) in the shaders.
pub inline fn structuredBufferOptions(self: Direct3D11) bufferpkg.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .bind = api.BIND_SHADER_RESOURCE,
        .structured = true,
    };
}

pub const instanceBufferOptions = structuredBufferOptions;
pub const fgBufferOptions = structuredBufferOptions;
pub const bgBufferOptions = structuredBufferOptions;
pub const imageBufferOptions = structuredBufferOptions;
pub const bgImageBufferOptions = structuredBufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Direct3D11) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = .b8g8r8a8_unorm,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: Direct3D11) Sampler.Options {
    return .{
        .device = self.device,
        .filter = .min_mag_mip_linear,
        .address_u = .clamp,
        .address_v = .clamp,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Direct3D11,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device,
        .context = self.context,
        .format = switch (format) {
            .gray => .r8_unorm,
            .rgba => if (srgb) .r8g8b8a8_unorm_srgb else .r8g8b8a8_unorm,
            .bgra => if (srgb) .b8g8r8a8_unorm_srgb else .b8g8r8a8_unorm,
        },
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Direct3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const format: api.Format = switch (atlas.format) {
        .grayscale => .r8_unorm,
        .bgra => .b8g8r8a8_unorm,
        else => @panic("unsupported atlas format for Direct3D texture"),
    };

    return try Texture.init(
        .{
            .device = self.device,
            .context = self.context,
            .format = format,
        },
        atlas.size,
        atlas.size,
        atlas.data,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const Direct3D11,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
