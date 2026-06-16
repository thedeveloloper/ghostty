#include "common.hlsl"

Texture2D<float4> image_tex : register(t8);
// TODO(windows): the bg_image pipeline needs a linear sampler bound at s0.
SamplerState image_sampler : register(s0);

struct VSOut {
    float4 position : SV_Position;
    nointerpolation float4 bg_color : COLOR0;
    nointerpolation float2 offset : TEXCOORD0;
    nointerpolation float2 scale : TEXCOORD1;
    nointerpolation float opacity : TEXCOORD2;
    nointerpolation uint repeat : TEXCOORD3;
};

float4 main(VSOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // SV_Position carries upper-left pixel coordinates, matching the texture
    // directionality.
    float2 frag_coord = in_data.position.xy;
    float2 tex_coord = (frag_coord - in_data.offset) * in_data.scale;

    uint tw, th;
    image_tex.GetDimensions(tw, th);
    float2 tex_size = float2(tw, th);

    // Wrap the coordinates if we need to repeat.
    if (in_data.repeat != 0) {
        tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        rgba = image_tex.Sample(image_sampler, tex_coord / tex_size);
        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }
        rgba.rgb *= rgba.a;
    }

    // Apply opacity, capped so it doesn't exceed the bg color's alpha.
    rgba *= min(in_data.opacity, 1.0 / in_data.bg_color.a);

    // Blend onto a fully opaque version of the background color.
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(in_data.bg_color.rgb, 1.0) * (1.0 - rgba.a));

    // Multiply by the background color alpha.
    rgba *= in_data.bg_color.a;

    return rgba;
}
