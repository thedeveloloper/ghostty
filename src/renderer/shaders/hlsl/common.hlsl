// Common definitions shared across the Direct3D shaders, mirroring
// shaders/glsl/common.glsl. Include with `#include "common.hlsl"`.
//
// Included here are the global uniform constant buffer, functions for
// unpacking packed values, and functions for working with colors.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
// The field offsets match the CPU-side Uniforms struct: HLSL's constant
// buffer packing rules place these at the same byte offsets as the std140
// layout used by the OpenGL backend (e.g. grid_padding lands at offset 96).
cbuffer Globals : register(b0) {
    float4x4 projection_matrix;
    float2 screen_size;
    float2 cell_size;
    uint grid_size_packed_2u16;
    float4 grid_padding;
    uint padding_extend;
    float min_contrast;
    uint cursor_pos_packed_2u16;
    uint cursor_color_packed_4u8;
    uint bg_color_packed_4u8;
    uint bools;
};

// Bools
static const uint CURSOR_WIDE = 1u;
static const uint USE_DISPLAY_P3 = 2u;
static const uint USE_LINEAR_BLENDING = 4u;
static const uint USE_LINEAR_CORRECTION = 8u;

// Padding extend enum
static const uint EXTEND_LEFT = 1u;
static const uint EXTEND_RIGHT = 2u;
static const uint EXTEND_UP = 4u;
static const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.

uint4 unpack4u8(uint packed_value) {
    return uint4(
        (packed_value >> 0) & 0xFFu,
        (packed_value >> 8) & 0xFFu,
        (packed_value >> 16) & 0xFFu,
        (packed_value >> 24) & 0xFFu);
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        (packed_value >> 0) & 0xFFFFu,
        (packed_value >> 16) & 0xFFFFu);
}

int2 unpack2i16(int packed_value) {
    return int2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16);
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of a color in linear RGB space.
float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// WCAG 2.0 contrast ratio. Colors must be in linear RGB space.
float contrast_ratio(float3 color1, float3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return fg if it meets the minimum contrast ratio against bg, otherwise
// return whichever of black/white has the higher contrast. Linear RGB.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return float4(1.0, 1.0, 1.0, 1.0);
        } else {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }
    return fg;
}

// Convert a color from sRGB gamma encoding to linear. `step` yields 1 where
// the channel is at or below the cutoff, selecting the linear branch.
float4 linearize(float4 srgb) {
    float3 cutoff = step(srgb.rgb, float3(0.04045, 0.04045, 0.04045));
    float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
    float3 lower = srgb.rgb / 12.92;
    return float4(lerp(higher, lower, cutoff), srgb.a);
}

float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Convert a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear_color) {
    float3 cutoff = step(linear_color.rgb, float3(0.0031308, 0.0031308, 0.0031308));
    float3 higher = pow(linear_color.rgb, 1.0 / 2.4) * 1.055 - 0.055;
    float3 lower = linear_color.rgb * 12.92;
    return float4(lerp(higher, lower, cutoff), linear_color.a);
}

float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color, linearizing if requested, and
// premultiply by alpha.
float4 load_color(uint4 in_color, bool is_linear) {
    // 0 .. 255 -> 0.0 .. 1.0
    float4 color = float4(in_color) / 255.0;

    if (is_linear) color = linearize(color);

    // Premultiply by alpha.
    color.rgb *= color.a;

    return color;
}
