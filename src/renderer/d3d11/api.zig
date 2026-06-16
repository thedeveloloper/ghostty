//! Minimal hand-rolled Direct3D 11 / DXGI bindings.
//!
//! Only the COM interfaces, methods, structs and enums the renderer actually
//! uses are bound here, in the spirit of the project's other hand-maintained
//! graphics bindings (e.g. pkg/opengl). The COM ABI is identical across the
//! GNU and MSVC targets, so these work for both.
//!
//! COM vtables are laid out in a fixed order (base interface methods first),
//! so unused leading slots are kept as `*const anyopaque` placeholders to
//! preserve the layout of the methods we do call.

const std = @import("std");
const windows = std.os.windows;

const HRESULT = windows.HRESULT;
const ULONG = windows.ULONG;
const UINT = windows.UINT;
const BOOL = windows.BOOL;
const GUID = windows.GUID;
const HWND = windows.HWND;
const HMODULE = windows.HMODULE;

/// True if an HRESULT indicates failure.
pub inline fn FAILED(hr: HRESULT) bool {
    return hr < 0;
}

/// `D3D11_SDK_VERSION`.
pub const SDK_VERSION: UINT = 7;

/// Primitive topology for a draw call.
pub const Primitive = enum {
    triangle,
    triangle_strip,
};

// -- Placeholder native handles ------------------------------------------
//
// TODO(windows): these stand in for GPU resources until the corresponding
// wrapper types (buffer.zig, Texture.zig, Sampler.zig) are implemented
// against real COM interfaces.
pub const Buffer = struct {};
pub const Texture = struct {};
pub const Sampler = struct {};

// -- Enums ---------------------------------------------------------------

pub const DriverType = enum(c_int) {
    unknown = 0,
    hardware = 1,
    reference = 2,
    null = 3,
    software = 4,
    warp = 5,
};

pub const FeatureLevel = enum(c_uint) {
    @"11_0" = 0xb000,
    @"11_1" = 0xb100,
};

pub const Format = enum(c_uint) {
    unknown = 0,
    r8g8b8a8_unorm = 28,
    r8g8b8a8_unorm_srgb = 29,
    b8g8r8a8_unorm = 87,
    b8g8r8a8_unorm_srgb = 91,
};

pub const SwapEffect = enum(c_uint) {
    discard = 0,
    sequential = 1,
    flip_sequential = 3,
    flip_discard = 4,
};

/// `DXGI_USAGE_RENDER_TARGET_OUTPUT`.
pub const USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;

/// `D3D11_CREATE_DEVICE_BGRA_SUPPORT`.
pub const CREATE_DEVICE_BGRA_SUPPORT: UINT = 0x20;

// -- Structs -------------------------------------------------------------

pub const Rational = extern struct {
    Numerator: UINT = 0,
    Denominator: UINT = 1,
};

pub const ModeDesc = extern struct {
    Width: UINT = 0,
    Height: UINT = 0,
    RefreshRate: Rational = .{},
    Format: Format = .unknown,
    ScanlineOrdering: c_uint = 0,
    Scaling: c_uint = 0,
};

pub const SampleDesc = extern struct {
    Count: UINT = 1,
    Quality: UINT = 0,
};

pub const SwapChainDesc = extern struct {
    BufferDesc: ModeDesc = .{},
    SampleDesc: SampleDesc = .{},
    BufferUsage: UINT = 0,
    BufferCount: UINT = 0,
    OutputWindow: ?HWND = null,
    Windowed: BOOL = 0,
    SwapEffect: SwapEffect = .discard,
    Flags: UINT = 0,
};

// -- COM interfaces ------------------------------------------------------

/// Subset of `ID3D11Device` (vtable through `CreateRenderTargetView`).
pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Device) callconv(.winapi) ULONG,
        CreateBuffer: *const anyopaque,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const anyopaque,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (
            *ID3D11Device,
            *ID3D11Resource,
            ?*const anyopaque,
            *?*ID3D11RenderTargetView,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn release(self: *ID3D11Device) void {
        _ = self.vtable.Release(self);
    }

    pub inline fn createRenderTargetView(
        self: *ID3D11Device,
        resource: *ID3D11Resource,
    ) !*ID3D11RenderTargetView {
        var rtv: ?*ID3D11RenderTargetView = null;
        const hr = self.vtable.CreateRenderTargetView(self, resource, null, &rtv);
        if (FAILED(hr)) return error.CreateRenderTargetViewFailed;
        return rtv orelse error.CreateRenderTargetViewFailed;
    }
};

/// `ID3D11DeviceContext`. We only need to release it for now.
pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) ULONG,
    };

    pub inline fn release(self: *ID3D11DeviceContext) void {
        _ = self.vtable.Release(self);
    }
};

/// Base resource interface; used to pass textures to view-creation methods.
pub const ID3D11Resource = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Resource) callconv(.winapi) ULONG,
    };

    pub inline fn release(self: *ID3D11Resource) void {
        _ = self.vtable.Release(self);
    }
};

/// `ID3D11RenderTargetView`. We only need to release it for now.
pub const ID3D11RenderTargetView = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11RenderTargetView) callconv(.winapi) ULONG,
    };

    pub inline fn release(self: *ID3D11RenderTargetView) void {
        _ = self.vtable.Release(self);
    }
};

/// `IID_ID3D11Texture2D` = {6f15aaf2-d208-4e89-9ab4-489535d34f9c}
pub const IID_ID3D11Texture2D: GUID = .{
    .Data1 = 0x6f15aaf2,
    .Data2 = 0xd208,
    .Data3 = 0x4e89,
    .Data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

/// Subset of `IDXGISwapChain` (vtable through `GetDesc`).
pub const IDXGISwapChain = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IDXGISwapChain) callconv(.winapi) ULONG,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject
        GetDevice: *const anyopaque,
        // IDXGISwapChain
        Present: *const fn (*IDXGISwapChain, UINT, UINT) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (
            *IDXGISwapChain,
            UINT,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const fn (*IDXGISwapChain, *SwapChainDesc) callconv(.winapi) HRESULT,
    };

    pub inline fn release(self: *IDXGISwapChain) void {
        _ = self.vtable.Release(self);
    }

    pub inline fn present(self: *IDXGISwapChain, sync_interval: UINT, flags: UINT) !void {
        const hr = self.vtable.Present(self, sync_interval, flags);
        if (FAILED(hr)) return error.PresentFailed;
    }

    /// Get the back buffer at the given index as an `ID3D11Texture2D`.
    pub inline fn getBuffer(self: *IDXGISwapChain, index: UINT) !*ID3D11Resource {
        var ptr: ?*anyopaque = null;
        const hr = self.vtable.GetBuffer(self, index, &IID_ID3D11Texture2D, &ptr);
        if (FAILED(hr)) return error.GetBufferFailed;
        return @ptrCast(@alignCast(ptr orelse return error.GetBufferFailed));
    }

    pub inline fn getDesc(self: *IDXGISwapChain) !SwapChainDesc {
        var desc: SwapChainDesc = .{};
        const hr = self.vtable.GetDesc(self, &desc);
        if (FAILED(hr)) return error.GetDescFailed;
        return desc;
    }
};

// -- Entry points --------------------------------------------------------

pub extern "d3d11" fn D3D11CreateDeviceAndSwapChain(
    pAdapter: ?*anyopaque,
    DriverType: DriverType,
    Software: ?HMODULE,
    Flags: UINT,
    pFeatureLevels: ?[*]const FeatureLevel,
    FeatureLevels: UINT,
    SDKVersion: UINT,
    pSwapChainDesc: *const SwapChainDesc,
    ppSwapChain: *?*IDXGISwapChain,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*FeatureLevel,
    ppImmediateContext: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;
