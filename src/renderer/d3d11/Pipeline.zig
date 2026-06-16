//! Wrapper for a render pipeline: a compiled vertex/pixel shader pair plus
//! the blend state. Cells and images are read from structured buffers in the
//! shaders (indexed by SV_InstanceID), so there is no input layout.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a render pipeline.
pub const Options = struct {
    /// HLSL source of the vertex function (entry point `main`).
    vertex_fn: [:0]const u8,
    /// HLSL source of the fragment (pixel) function (entry point `main`).
    fragment_fn: [:0]const u8,

    /// Vertex step function. Unused for Direct3D (instancing is driven by
    /// SV_InstanceID), kept for parity with the other backends.
    step_fn: StepFunction = .per_vertex,

    /// Whether to enable blending.
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

vertex_shader: *api.ID3D11VertexShader,
pixel_shader: *api.ID3D11PixelShader,
blend_state: ?*api.ID3D11BlendState,

pub fn init(
    device: *api.ID3D11Device,
    comptime VertexAttributes: ?type,
    opts: Options,
) !Self {
    // Cells/images are read as structured buffers, so we don't build an
    // input layout from the vertex attributes.
    _ = VertexAttributes;

    const vs_code = try compile(opts.vertex_fn, "vs_5_0");
    defer vs_code.release();
    const vertex_shader = try device.createVertexShader(vs_code.bytes());
    errdefer vertex_shader.release();

    const ps_code = try compile(opts.fragment_fn, "ps_5_0");
    defer ps_code.release();
    const pixel_shader = try device.createPixelShader(ps_code.bytes());
    errdefer pixel_shader.release();

    const blend_state: ?*api.ID3D11BlendState = if (opts.blending_enabled) bs: {
        // Premultiplied alpha (ONE, ONE_MINUS_SRC_ALPHA), matching the
        // OpenGL and Metal backends.
        var desc: api.BlendDesc = .{};
        desc.RenderTarget[0] = .{
            .BlendEnable = 1,
            .SrcBlend = .one,
            .DestBlend = .inv_src_alpha,
            .BlendOp = .add,
            .SrcBlendAlpha = .one,
            .DestBlendAlpha = .inv_src_alpha,
            .BlendOpAlpha = .add,
        };
        break :bs try device.createBlendState(&desc);
    } else null;

    return .{
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .blend_state = blend_state,
    };
}

pub fn deinit(self: *const Self) void {
    if (self.blend_state) |bs| bs.release();
    self.pixel_shader.release();
    self.vertex_shader.release();
}

/// Compile HLSL source to bytecode. The caller owns the returned blob.
fn compile(source: [:0]const u8, target: [*:0]const u8) !*api.ID3DBlob {
    var code: ?*api.ID3DBlob = null;
    var errors: ?*api.ID3DBlob = null;
    const hr = api.D3DCompile(
        source.ptr,
        source.len,
        null,
        null,
        null,
        "main",
        target,
        0,
        0,
        &code,
        &errors,
    );
    if (errors) |e| {
        log.warn("shader compile diagnostics: {s}", .{e.bytes()});
        e.release();
    }
    if (api.FAILED(hr)) return error.ShaderCompileFailed;
    return code orelse error.ShaderCompileFailed;
}
