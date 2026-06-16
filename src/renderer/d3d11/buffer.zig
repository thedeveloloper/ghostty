const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");

const log = std.log.scoped(.directx);

/// Options for initializing a buffer.
pub const Options = struct {};

/// GPU data storage for a set of equal types, used for vertex/storage/uniform
/// buffers. Mirrors the OpenGL backend's `Buffer` wrapper.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Underlying native buffer handle.
        buffer: api.Buffer,

        /// Options this buffer was allocated with.
        opts: Options,

        /// Current allocated length of the data store, in number of `T`s.
        len: usize,

        /// Initialize a buffer with the given length pre-allocated.
        pub fn init(opts: Options, len: usize) !Self {
            _ = opts;
            _ = len;
            // TODO(windows): create an ID3D11Buffer (D3D11_USAGE_DYNAMIC).
            return error.Unimplemented;
        }

        /// Initialize a buffer filled with the given data.
        pub fn initFill(opts: Options, data: []const T) !Self {
            _ = opts;
            _ = data;
            // TODO(windows): create an ID3D11Buffer initialized with `data`.
            return error.Unimplemented;
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        /// Sync the complete contents of the buffer. Reallocates if the data
        /// is larger than the current allocation.
        pub fn sync(self: *Self, data: []const T) !void {
            _ = self;
            _ = data;
            // TODO(windows): Map/Unmap with D3D11_MAP_WRITE_DISCARD.
            return error.Unimplemented;
        }

        /// Like `sync` but draws data from an array of ArrayLists. Returns the
        /// number of items synced.
        pub fn syncFromArrayLists(
            self: *Self,
            lists: []const std.ArrayListUnmanaged(T),
        ) !usize {
            _ = self;
            _ = lists;
            return error.Unimplemented;
        }
    };
}
