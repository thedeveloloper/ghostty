#include "common.hlsl"

// Per-instance cell glyph data, read from a structured buffer indexed by the
// instance id (mirrors the OpenGL vertex attributes). The HLSL struct is laid
// out to match the 32-byte CPU CellText: SM5 has no 16/8-bit scalars, so the
// i16/u16/u8 fields are packed into uints and unpacked below.
struct CellText {
    uint2 glyph_pos;
    uint2 glyph_size;
    uint bearings_packed; // 2x i16
    uint grid_pos_packed; // 2x u16
    uint color_packed; // 4x u8
    uint atlas_bools_packed; // atlas:u8, bools:u8, padding:u16
};

StructuredBuffer<CellText> cells : register(t0);
StructuredBuffer<uint> bg_colors : register(t1);

// Masks for the packed bools byte.
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

struct VSOut {
    float4 position : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 bg_color : COLOR1;
    float2 tex_coord : TEXCOORD0;
};

VSOut main(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    CellText cell = cells[iid];
    uint2 glyph_pos = cell.glyph_pos;
    uint2 glyph_size = cell.glyph_size;
    int2 bearings = unpack2i16(int(cell.bearings_packed));
    uint2 grid_pos = unpack2u16(cell.grid_pos_packed);
    uint4 color = unpack4u8(cell.color_packed);
    uint atlas = cell.atlas_bools_packed & 0xFFu;
    uint glyph_bools = (cell.atlas_bools_packed >> 8) & 0xFFu;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Grid position into world space.
    float2 cell_pos = cell_size * float2(grid_pos);

    // Quad corner from the vertex id (triangle strip):
    //   0 = top-left, 1 = top-right, 2 = bot-left, 3 = bot-right
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    VSOut o;
    o.atlas = atlas;

    // Offset the glyph within the cell using its bearings.
    float2 size = float2(glyph_size);
    float2 offset = float2(bearings);
    offset.y = cell_size.y - offset.y;

    cell_pos = cell_pos + size * corner + offset;
    o.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0, 1.0));

    // Texture coordinate in (non-normalized) atlas pixels.
    o.tex_coord = float2(glyph_pos) + float2(glyph_size) * corner;

    // Always fetch a linearized color to ease contrast calculations.
    o.color = load_color(color, true);
    o.bg_color = load_color(
        unpack4u8(bg_colors[grid_pos.y * grid_size.x + grid_pos.x]),
        true);
    float4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    o.bg_color += global_bg * (1.0 - o.bg_color.a);

    if (min_contrast > 1.0 && (glyph_bools & NO_MIN_CONTRAST) == 0) {
        o.color = contrasted_color(min_contrast, o.color, o.bg_color);
    }

    // Recolor for the cursor cell (unless this is the cursor glyph itself).
    bool is_cursor_pos =
        ((grid_pos.x == cursor_pos.x) ||
            (cursor_wide && (grid_pos.x == (cursor_pos.x + 1)))) &&
        (grid_pos.y == cursor_pos.y);
    if ((glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        o.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return o;
}
