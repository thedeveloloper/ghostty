//! Wrapper for an `ID3D11SamplerState`.
const Self = @This();

const std = @import("std");
const api = @import("api.zig");

/// Options for initializing a sampler.
pub const Options = struct {};

pub const Error = error{
    Unimplemented,
};

/// Underlying native sampler handle.
sampler: api.Sampler,

pub fn init(opts: Options) Error!Self {
    _ = opts;
    // TODO(windows): ID3D11Device::CreateSamplerState.
    return error.Unimplemented;
}

pub fn deinit(self: Self) void {
    _ = self;
}
