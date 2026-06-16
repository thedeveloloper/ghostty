#include "common.hlsl"

// Glyph atlases, bound at t8/t9 (textures start at t8 by convention). The
// grayscale atlas holds alpha masks; the color atlas holds premultiplied
// linear color glyphs. Sampled with Load (nearest, non-normalized pixels) to
// match the OpenGL rectangle-texture sampling, so no sampler is needed.
Texture2D<float4> atlas_grayscale : register(t8);
Texture2D<float4> atlas_color : register(t9);

static const uint ATLAS_COLOR = 1u;

struct VSOut {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD0;
};

float4 main(VSOut in_data) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    int3 texel = int3(int2(in_data.tex_coord), 0);

    if (in_data.atlas == ATLAS_COLOR) {
        // Color glyphs are already premultiplied linear colors.
        float4 color = atlas_color.Load(texel);
        if (use_linear_blending) return color;
        // Unlinearize, dividing out and re-multiplying the premultiplied alpha.
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
        return color;
    }

    // Grayscale: our input color is always linear.
    float4 color = in_data.color;
    if (!use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
    }

    // Alpha mask for this pixel.
    float a = atlas_grayscale.Load(texel).r;

    // Linear blending weight correction to match gamma-incorrect blending.
    if (use_linear_correction) {
        float4 bg = in_data.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
    }

    // Apply the mask (premultiplied, so multiply the whole color).
    color *= a;
    return color;
}
