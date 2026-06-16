//! Wrapper for handling render passes.
//!
//! Binding convention (must match the HLSL shaders): the uniform constant
//! buffer is at register b0; structured `buffers` are SRVs at t0+; `textures`
//! are SRVs at t8+; `samplers` are at s0+. Buffers and textures are bound to
//! both the vertex and pixel stages.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.directx);

/// Base SRV register for textures, leaving t0..t7 for structured buffers.
const texture_srv_base: u32 = 8;

/// Options for beginning a render pass.
pub const Options = struct {
    context: *api.ID3D11DeviceContext,

    /// Color attachments for this render pass.
    attachments: []const Attachment,

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

/// Describes a step in a render pass.
pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?api.BoundBuffer = null,
    buffers: []const ?api.BoundBuffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    /// Describes the draw call for this step.
    pub const Draw = struct {
        type: api.Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

context: *api.ID3D11DeviceContext,

/// Begin a render pass: bind the render target and viewport, and clear if
/// requested.
pub fn begin(opts: Options) Self {
    const ctx = opts.context;
    const at = opts.attachments[0];

    // Resolve the render target view and dimensions from the attachment.
    const rtv: ?*api.ID3D11RenderTargetView, const dims: [2]usize = switch (at.target) {
        .target => |t| .{ t.rtv, .{ t.width, t.height } },
        // TODO(windows): rendering into a plain texture (custom shader
        // intermediates) needs an RTV on the texture.
        .texture => |t| .{ null, .{ t.width, t.height } },
    };

    if (rtv) |target_view| {
        ctx.omSetRenderTarget(target_view);
        ctx.rsSetViewport(.{
            .Width = @floatFromInt(dims[0]),
            .Height = @floatFromInt(dims[1]),
        });
        if (at.clear_color) |c| ctx.clearRenderTargetView(target_view, c);
    }

    return .{ .context = ctx };
}

/// Add a step to this render pass.
pub fn step(self: *Self, s: Step) void {
    if (s.draw.instance_count == 0) return;

    const ctx = self.context;

    // Shaders and pipeline state.
    ctx.vsSetShader(s.pipeline.vertex_shader);
    ctx.psSetShader(s.pipeline.pixel_shader);
    ctx.omSetBlendState(s.pipeline.blend_state);
    ctx.iaSetPrimitiveTopology(switch (s.draw.type) {
        .triangle => .triangle_list,
        .triangle_strip => .triangle_strip,
    });

    // Uniform constant buffer at b0.
    if (s.uniforms) |u| {
        ctx.vsSetConstantBuffer(0, u.buffer);
        ctx.psSetConstantBuffer(0, u.buffer);
    }

    // Structured buffers as SRVs at t0+.
    for (s.buffers, 0..) |maybe, i| if (maybe) |b| if (b.srv) |srv| {
        ctx.vsSetShaderResource(@intCast(i), srv);
        ctx.psSetShaderResource(@intCast(i), srv);
    };

    // Textures as SRVs at t8+.
    for (s.textures, 0..) |maybe, j| if (maybe) |t| {
        ctx.vsSetShaderResource(texture_srv_base + @as(u32, @intCast(j)), t.srv);
        ctx.psSetShaderResource(texture_srv_base + @as(u32, @intCast(j)), t.srv);
    };

    // Samplers at s0+.
    for (s.samplers, 0..) |maybe, j| if (maybe) |sampler| {
        ctx.psSetSampler(@intCast(j), sampler.sampler);
    };

    ctx.drawInstanced(@intCast(s.draw.vertex_count), @intCast(s.draw.instance_count));
}

/// Complete this render pass. This struct can no longer be used afterward.
pub fn complete(self: *const Self) void {
    _ = self;
}
