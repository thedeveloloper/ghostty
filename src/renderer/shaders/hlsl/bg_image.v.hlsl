#include "common.hlsl"

// Single-instance background image parameters. Matches the 8-byte CPU
// BgImage (opacity + a packed info byte).
struct BgImage {
    float opacity;
    uint info;
};

StructuredBuffer<BgImage> bg_images : register(t0);
Texture2D<float4> image_tex : register(t8);

// 4 bits of position.
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// 2 bits of fit, shifted 4.
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// 1 bit of repeat, shifted 6.
static const uint BG_IMAGE_REPEAT = 1u << 6;

struct VSOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat : TEXCOORD3;
};

VSOut main(uint vid : SV_VertexID) {
    BgImage bi = bg_images[0];
    uint info = bi.info;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Full-screen triangle.
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;

    VSOut o;
    o.position = position;
    o.opacity = bi.opacity;
    o.repeat = info & BG_IMAGE_REPEAT;

    float2 ss = screen_size;
    uint tw, th;
    image_tex.GetDimensions(tw, th);
    float2 tex_size = float2(tw, th);

    // Fit the image to the screen.
    float2 dest_size = tex_size;
    uint fit = info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float s = min(ss.x / tex_size.x, ss.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        float s = max(ss.x / tex_size.x, ss.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = ss;
    } else {
        dest_size = tex_size;
    }

    // Position the fitted image.
    float2 start = float2(0.0, 0.0);
    float2 mid = (ss - dest_size) / 2.0;
    float2 end = ss - dest_size;
    float2 dest_offset = mid;
    uint pos = info & BG_IMAGE_POSITION;
    if (pos == BG_IMAGE_TL) dest_offset = float2(start.x, start.y);
    else if (pos == BG_IMAGE_TC) dest_offset = float2(mid.x, start.y);
    else if (pos == BG_IMAGE_TR) dest_offset = float2(end.x, start.y);
    else if (pos == BG_IMAGE_ML) dest_offset = float2(start.x, mid.y);
    else if (pos == BG_IMAGE_MC) dest_offset = float2(mid.x, mid.y);
    else if (pos == BG_IMAGE_MR) dest_offset = float2(end.x, mid.y);
    else if (pos == BG_IMAGE_BL) dest_offset = float2(start.x, end.y);
    else if (pos == BG_IMAGE_BC) dest_offset = float2(mid.x, end.y);
    else if (pos == BG_IMAGE_BR) dest_offset = float2(end.x, end.y);

    o.offset = dest_offset;
    o.scale = tex_size / dest_size;

    // Fully opaque bg color, with the alpha carried separately.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    o.bg_color = float4(
        load_color(uint4(u_bg_color.rgb, 255), use_linear_blending).rgb,
        float(u_bg_color.a) / 255.0);

    return o;
}
