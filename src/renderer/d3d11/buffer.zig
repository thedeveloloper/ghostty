const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a buffer.
pub const Options = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,

    /// The D3D11 bind flag for the buffer (vertex, constant, shader resource).
    bind: u32 = api.BIND_VERTEX_BUFFER,

    /// Whether this is a structured buffer (read as a `StructuredBuffer<T>`
    /// SRV in the shaders, mirroring the OpenGL storage-buffer approach).
    structured: bool = false,
};

/// GPU data storage for a set of equal types, used for vertex/constant/
/// structured buffers. Mirrors the OpenGL/Metal `Buffer` wrappers: a dynamic
/// buffer that grows on demand and is updated by mapping with WRITE_DISCARD.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying `ID3D11Buffer`.
        buffer: *api.ID3D11Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store, in number of `T`s.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            const buffer = try opts.device.createBuffer(&bufferDesc(opts, len), null);
            return .{ .buffer = buffer, .opts = opts, .len = len };
        }

        /// Initialize a buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            var self = try init(opts, data.len);
            errdefer self.deinit();
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: Self) void {
            self.buffer.release();
        }

        /// Sync the complete contents of the buffer, reallocating (to double
        /// the required size) if the data no longer fits.
        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len > self.len) try self.grow(data.len * 2);
            const bytes = data.len * @sizeOf(T);
            if (bytes == 0) return;

            const mapped = try self.opts.context.map(self.buffer.resource(), 0, .write_discard);
            const dst: [*]u8 = @ptrCast(mapped.pData orelse return error.MapFailed);
            const src: [*]const u8 = @ptrCast(data.ptr);
            @memcpy(dst[0..bytes], src[0..bytes]);
            self.opts.context.unmap(self.buffer.resource(), 0);
        }

        /// Like `sync` but draws data from an array of ArrayLists. Returns the
        /// number of items synced.
        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) !usize {
            var total: usize = 0;
            for (lists) |list| total += list.items.len;
            if (total > self.len) try self.grow(total * 2);
            if (total == 0) return 0;

            const mapped = try self.opts.context.map(self.buffer.resource(), 0, .write_discard);
            const dst: [*]u8 = @ptrCast(mapped.pData orelse return error.MapFailed);
            var i: usize = 0;
            for (lists) |list| {
                const n = list.items.len * @sizeOf(T);
                const src: [*]const u8 = @ptrCast(list.items.ptr);
                @memcpy(dst[i .. i + n], src[0..n]);
                i += n;
            }
            self.opts.context.unmap(self.buffer.resource(), 0);
            return total;
        }

        /// Reallocate the underlying buffer to hold at least `len` elements.
        fn grow(self: *Self, len: usize) !void {
            const buffer = try self.opts.device.createBuffer(&bufferDesc(self.opts, len), null);
            self.buffer.release();
            self.buffer = buffer;
            self.len = len;
        }

        fn bufferDesc(opts: Options, len: usize) api.BufferDesc {
            var byte_width: u32 = @intCast(len * @sizeOf(T));
            // Constant buffers must be a non-zero multiple of 16 bytes.
            if (opts.bind & api.BIND_CONSTANT_BUFFER != 0) {
                byte_width = std.mem.alignForward(u32, @max(byte_width, 16), 16);
            }
            return .{
                .ByteWidth = byte_width,
                .Usage = .dynamic,
                .BindFlags = opts.bind,
                .CPUAccessFlags = api.CPU_ACCESS_WRITE,
                // D3D11_RESOURCE_MISC_BUFFER_STRUCTURED
                .MiscFlags = if (opts.structured) 0x40 else 0,
                .StructureByteStride = if (opts.structured) @sizeOf(T) else 0,
            };
        }
    };
}
