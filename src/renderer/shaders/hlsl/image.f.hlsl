#include "common.hlsl"

Texture2D<float4> image_tex : register(t8);
// TODO(windows): the image pipelines need a linear sampler bound at s0
// (the render pass does not currently bind one for image steps).
SamplerState image_sampler : register(s0);

struct VSOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

float4 main(VSOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image_tex.Sample(image_sampler, in_data.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= rgba.a;
    return rgba;
}
