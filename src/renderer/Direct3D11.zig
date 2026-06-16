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

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// NOTE: This is `error{}!Direct3D11` for parity with the other backends'
///       fallible init signatures, even though it can't currently fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!Direct3D11 {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *Direct3D11) void {
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
    return try shaders.Shaders.init(self.alloc, custom_shaders);
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Direct3D11) !struct { width: u32, height: u32 } {
    _ = self;
    // TODO(windows): query the swap chain / HWND client size.
    return error.Unimplemented;
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Direct3D11, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{ .width = width, .height = height });
}

/// Present the provided target.
pub fn present(self: *Direct3D11, target: Target) !void {
    self.last_target = target;
    // TODO(windows): IDXGISwapChain::Present.
    return error.Unimplemented;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *Direct3D11) !void {
    if (self.last_target) |target| try self.present(target);
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Direct3D11) bufferpkg.Options {
    _ = self;
    return .{};
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Direct3D11) Texture.Options {
    _ = self;
    return .{};
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: Direct3D11) Sampler.Options {
    _ = self;
    return .{};
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
    _ = self;
    _ = format;
    _ = srgb;
    return .{};
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Direct3D11,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    _ = atlas;
    // TODO(windows): create an ID3D11Texture2D + SRV from the atlas data.
    return error.Unimplemented;
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
