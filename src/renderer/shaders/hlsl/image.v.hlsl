#include "common.hlsl"

// Per-instance image placement, read from a structured buffer. Padded to the
// 48-byte CPU Image layout (source_rect is 16-byte aligned there).
struct Image {
    float2 grid_pos;
    float2 cell_offset;
    float4 source_rect;
    float2 dest_size;
    float2 _pad;
};

StructuredBuffer<Image> images : register(t0);
Texture2D<float4> image_tex : register(t8);

struct VSOut {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

VSOut main(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    Image img = images[iid];

    // Quad corner from the vertex id (triangle strip).
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    uint tw, th;
    image_tex.GetDimensions(tw, th);
    float2 tex_size = float2(tw, th);

    VSOut o;

    // Texture coordinates from the source rect, normalized.
    o.tex_coord = img.source_rect.xy + img.source_rect.zw * corner;
    o.tex_coord /= tex_size;

    // Image position: top-left of the cell plus the dest rect.
    float2 image_pos = (cell_size * img.grid_pos) + img.cell_offset;
    image_pos += img.dest_size * corner;
    o.position = mul(projection_matrix, float4(image_pos.xy, 1.0, 1.0));

    return o;
}
