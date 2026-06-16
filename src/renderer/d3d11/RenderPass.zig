//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.directx);

/// Options for beginning a render pass.
pub const Options = struct {
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
    uniforms: ?*api.ID3D11Buffer = null,
    buffers: []const ?*api.ID3D11Buffer = &.{},
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

attachments: []const Options.Attachment,

step_number: usize = 0,

/// Begin a render pass.
pub fn begin(opts: Options) Self {
    return .{
        .attachments = opts.attachments,
    };
}

/// Add a step to this render pass.
pub fn step(self: *Self, s: Step) void {
    _ = self;
    _ = s;
    // TODO(windows): set the RTV/viewport, bind the pipeline, uniforms,
    // buffers, textures and samplers, then issue the (instanced) draw.
}

/// Complete this render pass. This struct can no longer be used afterward.
pub fn complete(self: *const Self) void {
    _ = self;
}
