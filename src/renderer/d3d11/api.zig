//! Placeholder Direct3D 11 native handle types.
//!
//! These stand in for the COM interfaces the real backend will use
//! (`ID3D11Buffer`, `ID3D11Texture2D` + SRV, `ID3D11SamplerState`, etc.).
//! They exist so the rest of the backend can be written against stable
//! types while the actual Direct3D 11 bindings are filled in.
//!
//! TODO(windows): replace these with real COM interface bindings (Phase 2b+).

/// Native GPU buffer handle (`ID3D11Buffer`).
pub const Buffer = struct {};

/// Native GPU texture handle (`ID3D11Texture2D` + `ID3D11ShaderResourceView`).
pub const Texture = struct {};

/// Native sampler state handle (`ID3D11SamplerState`).
pub const Sampler = struct {};

/// Primitive topology for a draw call.
pub const Primitive = enum {
    triangle,
    triangle_strip,
};
