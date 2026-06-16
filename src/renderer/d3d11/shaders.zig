const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");

const api = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.directx);

/// This contains the state for the shaders used by the Direct3D renderer.
pub const Shaders = struct {
    /// Collection of available render pipelines.
    pipelines: Pipelines,

    /// Custom shaders to run against the final drawable texture. Each shader
    /// is run in sequence against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Set to true when deinited, to prevent double-free.
    defunct: bool = false,

    /// The named render pipelines, matching the other backends.
    pub const Pipelines = struct {
        bg_color: Pipeline,
        cell_bg: Pipeline,
        cell_text: Pipeline,
        image: Pipeline,
        bg_image: Pipeline,
    };

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    pub fn init(
        device: *api.ID3D11Device,
        alloc: Allocator,
        post_shaders: []const [:0]const u8,
    ) !Shaders {
        _ = alloc;
        _ = post_shaders;

        // TODO(windows): port the remaining shaders to HLSL (Phase 2f);
        // cell_text/image/bg_image still use placeholder source.
        const placeholder: Pipeline.Options = .{ .vertex_fn = "", .fragment_fn = "" };
        return .{
            .pipelines = .{
                .bg_color = try Pipeline.init(device, null, .{
                    .vertex_fn = loadShaderCode("../shaders/hlsl/full_screen.v.hlsl"),
                    .fragment_fn = loadShaderCode("../shaders/hlsl/bg_color.f.hlsl"),
                    .blending_enabled = false,
                }),
                .cell_bg = try Pipeline.init(device, null, .{
                    .vertex_fn = loadShaderCode("../shaders/hlsl/full_screen.v.hlsl"),
                    .fragment_fn = loadShaderCode("../shaders/hlsl/cell_bg.f.hlsl"),
                    .blending_enabled = true,
                }),
                .cell_text = try Pipeline.init(device, CellText, placeholder),
                .image = try Pipeline.init(device, Image, placeholder),
                .bg_image = try Pipeline.init(device, BgImage, placeholder),
            },
            .post_pipelines = &.{},
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        inline for (@typeInfo(Pipelines).@"struct".fields) |field| {
            @field(self.pipelines, field.name).deinit();
        }

        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(self.post_pipelines);
        }
    }
};

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(4),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans, in a packed struct for space efficiency.
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool,

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool,

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// re-encoded for storage.
        use_linear_blending: bool,

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool = false,

        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Load shader code from the target path, processing `#include` directives.
///
/// Comptime only. Mirrors the OpenGL backend's loader so the HLSL shaders can
/// share `common.hlsl` without a runtime include handler.
fn loadShaderCode(comptime path: []const u8) [:0]const u8 {
    return comptime processIncludes(@embedFile(path), std.fs.path.dirname(path).?);
}

/// Used by loadShaderCode.
fn processIncludes(contents: [:0]const u8, basedir: []const u8) [:0]const u8 {
    @setEvalBranchQuota(100_000);
    var i: usize = 0;
    while (i < contents.len) {
        if (std.mem.startsWith(u8, contents[i..], "#include")) {
            std.debug.assert(std.mem.startsWith(u8, contents[i..], "#include \""));
            const start = i + "#include \"".len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"').?;
            return std.fmt.comptimePrint(
                "{s}{s}{s}",
                .{
                    contents[0..i],
                    @embedFile(basedir ++ "/" ++ contents[start..end]),
                    processIncludes(contents[end + 1 ..], basedir),
                },
            );
        }
        if (std.mem.indexOfPos(u8, contents, i, "\n#")) |j| {
            i = (j + 1);
        } else {
            break;
        }
    }
    return contents;
}
