//! Wrapper for an `ID3D11SamplerState`.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

/// Options for initializing a sampler.
pub const Options = struct {
    device: *api.ID3D11Device,
    filter: api.Filter,
    address_u: api.TextureAddressMode,
    address_v: api.TextureAddressMode,
    address_w: api.TextureAddressMode = .clamp,
};

pub const Error = error{
    CreateSamplerStateFailed,
};

/// Underlying sampler state.
sampler: *api.ID3D11SamplerState,

pub fn init(opts: Options) Error!Self {
    const desc: api.SamplerDesc = .{
        .Filter = opts.filter,
        .AddressU = opts.address_u,
        .AddressV = opts.address_v,
        .AddressW = opts.address_w,
    };
    const sampler = try opts.device.createSamplerState(&desc);
    return .{ .sampler = sampler };
}

pub fn deinit(self: Self) void {
    self.sampler.release();
}
