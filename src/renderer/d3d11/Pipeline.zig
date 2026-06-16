//! Wrapper for a render pipeline.
//!
//! For Direct3D 11 this will own a compiled vertex/pixel shader pair, the
//! `ID3D11InputLayout` describing the vertex attributes, and the blend state.
const Self = @This();

const std = @import("std");

const log = std.log.scoped(.directx);

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// HLSL source of the vertex function.
    vertex_fn: [:0]const u8,
    /// HLSL source of the fragment (pixel) function.
    fragment_fn: [:0]const u8,

    /// Vertex step function.
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

/// The stride of the per-vertex/instance data, in bytes.
stride: usize,

/// Whether blending is enabled for this pipeline.
blending_enabled: bool,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = opts.vertex_fn;
    _ = opts.fragment_fn;
    _ = opts.step_fn;
    // TODO(windows): D3DCompile the shaders, build the input layout and
    // blend state from VertexAttributes and opts.
    return .{
        .stride = if (VertexAttributes) |VA| @sizeOf(VA) else 0,
        .blending_enabled = opts.blending_enabled,
    };
}

pub fn deinit(self: *const Self) void {
    _ = self;
}
