//! Minimal hand-rolled Direct3D 11 / DXGI bindings.
//!
//! Only the COM interfaces, methods, structs and enums the renderer actually
//! uses are bound here, in the spirit of the project's other hand-maintained
//! graphics bindings (e.g. pkg/opengl). The COM ABI is identical across the
//! GNU and MSVC targets, so these work for both.
//!
//! COM vtables are laid out in a fixed order (base interface methods first).
//! Every slot up to the last method we call is listed so the layout matches
//! the real interface; slots we don't call yet are `*const anyopaque`
//! placeholders, named after their method for clarity.

const std = @import("std");
const windows = std.os.windows;

const HRESULT = windows.HRESULT;
const ULONG = windows.ULONG;
const UINT = windows.UINT;
const FLOAT = f32;
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
    r8_unorm = 61,
    b8g8r8a8_unorm = 87,
    b8g8r8a8_unorm_srgb = 91,
};

pub const SwapEffect = enum(c_uint) {
    discard = 0,
    sequential = 1,
    flip_sequential = 3,
    flip_discard = 4,
};

pub const Usage = enum(c_uint) {
    default = 0,
    immutable = 1,
    dynamic = 2,
    staging = 3,
};

pub const Map = enum(c_uint) {
    read = 1,
    write = 2,
    read_write = 3,
    write_discard = 4,
    write_no_overwrite = 5,
};

pub const Filter = enum(c_uint) {
    min_mag_mip_point = 0x0,
    min_mag_mip_linear = 0x15,
};

pub const TextureAddressMode = enum(c_uint) {
    wrap = 1,
    mirror = 2,
    clamp = 3,
    border = 4,
};

pub const ComparisonFunc = enum(c_uint) {
    never = 1,
};

/// `DXGI_USAGE_RENDER_TARGET_OUTPUT`.
pub const USAGE_RENDER_TARGET_OUTPUT: UINT = 0x20;

/// `D3D11_CREATE_DEVICE_BGRA_SUPPORT`.
pub const CREATE_DEVICE_BGRA_SUPPORT: UINT = 0x20;

// `D3D11_BIND_FLAG` values.
pub const BIND_VERTEX_BUFFER: UINT = 0x1;
pub const BIND_CONSTANT_BUFFER: UINT = 0x4;
pub const BIND_SHADER_RESOURCE: UINT = 0x8;
pub const BIND_RENDER_TARGET: UINT = 0x20;

/// `D3D11_CPU_ACCESS_WRITE`.
pub const CPU_ACCESS_WRITE: UINT = 0x10000;

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

pub const BufferDesc = extern struct {
    ByteWidth: UINT,
    Usage: Usage,
    BindFlags: UINT,
    CPUAccessFlags: UINT = 0,
    MiscFlags: UINT = 0,
    StructureByteStride: UINT = 0,
};

pub const Texture2DDesc = extern struct {
    Width: UINT,
    Height: UINT,
    MipLevels: UINT = 1,
    ArraySize: UINT = 1,
    Format: Format,
    SampleDesc: SampleDesc = .{},
    Usage: Usage = .default,
    BindFlags: UINT,
    CPUAccessFlags: UINT = 0,
    MiscFlags: UINT = 0,
};

pub const SamplerDesc = extern struct {
    Filter: Filter,
    AddressU: TextureAddressMode,
    AddressV: TextureAddressMode,
    AddressW: TextureAddressMode,
    MipLODBias: FLOAT = 0,
    MaxAnisotropy: UINT = 1,
    ComparisonFunc: ComparisonFunc = .never,
    BorderColor: [4]FLOAT = .{ 0, 0, 0, 0 },
    MinLOD: FLOAT = 0,
    MaxLOD: FLOAT = 0,
};

pub const SubresourceData = extern struct {
    pSysMem: ?*const anyopaque,
    SysMemPitch: UINT = 0,
    SysMemSlicePitch: UINT = 0,
};

pub const MappedSubresource = extern struct {
    pData: ?*anyopaque = null,
    RowPitch: UINT = 0,
    DepthPitch: UINT = 0,
};

// -- COM interfaces ------------------------------------------------------

/// Base resource interface; textures and buffers can be cast to this to be
/// passed to view-creation, map and update methods.
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

/// `ID3D11Buffer`.
pub const ID3D11Buffer = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Buffer) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11Buffer) void {
        _ = self.vtable.Release(self);
    }
    pub inline fn resource(self: *ID3D11Buffer) *ID3D11Resource {
        return @ptrCast(self);
    }
};

/// `ID3D11Texture2D`.
pub const ID3D11Texture2D = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Texture2D) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11Texture2D) void {
        _ = self.vtable.Release(self);
    }
    pub inline fn resource(self: *ID3D11Texture2D) *ID3D11Resource {
        return @ptrCast(self);
    }
};

/// `ID3D11ShaderResourceView`.
pub const ID3D11ShaderResourceView = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11ShaderResourceView) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11ShaderResourceView) void {
        _ = self.vtable.Release(self);
    }
};

/// `ID3D11SamplerState`.
pub const ID3D11SamplerState = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11SamplerState) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11SamplerState) void {
        _ = self.vtable.Release(self);
    }
};

/// `ID3D11RenderTargetView`.
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

/// Subset of `ID3D11Device` (vtable through `CreateSamplerState`, slot 23).
pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11Device) callconv(.winapi) ULONG,
        CreateBuffer: *const fn (
            *ID3D11Device,
            *const BufferDesc,
            ?*const SubresourceData,
            *?*ID3D11Buffer,
        ) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (
            *ID3D11Device,
            *const Texture2DDesc,
            ?*const SubresourceData,
            *?*ID3D11Texture2D,
        ) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const fn (
            *ID3D11Device,
            *ID3D11Resource,
            ?*const anyopaque,
            *?*ID3D11ShaderResourceView,
        ) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (
            *ID3D11Device,
            *ID3D11Resource,
            ?*const anyopaque,
            *?*ID3D11RenderTargetView,
        ) callconv(.winapi) HRESULT,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const anyopaque,
        CreateVertexShader: *const anyopaque,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const anyopaque,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const anyopaque,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const fn (
            *ID3D11Device,
            *const SamplerDesc,
            *?*ID3D11SamplerState,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn release(self: *ID3D11Device) void {
        _ = self.vtable.Release(self);
    }

    pub inline fn createBuffer(
        self: *ID3D11Device,
        desc: *const BufferDesc,
        initial: ?*const SubresourceData,
    ) !*ID3D11Buffer {
        var out: ?*ID3D11Buffer = null;
        const hr = self.vtable.CreateBuffer(self, desc, initial, &out);
        if (FAILED(hr)) return error.CreateBufferFailed;
        return out orelse error.CreateBufferFailed;
    }

    pub inline fn createTexture2D(
        self: *ID3D11Device,
        desc: *const Texture2DDesc,
        initial: ?*const SubresourceData,
    ) !*ID3D11Texture2D {
        var out: ?*ID3D11Texture2D = null;
        const hr = self.vtable.CreateTexture2D(self, desc, initial, &out);
        if (FAILED(hr)) return error.CreateTexture2DFailed;
        return out orelse error.CreateTexture2DFailed;
    }

    pub inline fn createShaderResourceView(
        self: *ID3D11Device,
        res: *ID3D11Resource,
    ) !*ID3D11ShaderResourceView {
        var out: ?*ID3D11ShaderResourceView = null;
        const hr = self.vtable.CreateShaderResourceView(self, res, null, &out);
        if (FAILED(hr)) return error.CreateShaderResourceViewFailed;
        return out orelse error.CreateShaderResourceViewFailed;
    }

    pub inline fn createRenderTargetView(
        self: *ID3D11Device,
        res: *ID3D11Resource,
    ) !*ID3D11RenderTargetView {
        var out: ?*ID3D11RenderTargetView = null;
        const hr = self.vtable.CreateRenderTargetView(self, res, null, &out);
        if (FAILED(hr)) return error.CreateRenderTargetViewFailed;
        return out orelse error.CreateRenderTargetViewFailed;
    }

    pub inline fn createSamplerState(
        self: *ID3D11Device,
        desc: *const SamplerDesc,
    ) !*ID3D11SamplerState {
        var out: ?*ID3D11SamplerState = null;
        const hr = self.vtable.CreateSamplerState(self, desc, &out);
        if (FAILED(hr)) return error.CreateSamplerStateFailed;
        return out orelse error.CreateSamplerStateFailed;
    }
};

/// Subset of `ID3D11DeviceContext` (vtable through `UpdateSubresource`,
/// slot 48). Intermediate slots are placeholders, named for clarity, and
/// will be typed as the drawing code needs them.
pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11DeviceContext) callconv(.winapi) ULONG,
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const fn (
            *ID3D11DeviceContext,
            *ID3D11Resource,
            UINT,
            Map,
            UINT,
            *MappedSubresource,
        ) callconv(.winapi) HRESULT,
        Unmap: *const fn (*ID3D11DeviceContext, *ID3D11Resource, UINT) callconv(.winapi) void,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const anyopaque,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const anyopaque,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const fn (
            *ID3D11DeviceContext,
            *ID3D11Resource,
            UINT,
            ?*const anyopaque,
            *const anyopaque,
            UINT,
            UINT,
        ) callconv(.winapi) void,
    };

    pub inline fn release(self: *ID3D11DeviceContext) void {
        _ = self.vtable.Release(self);
    }

    pub inline fn map(
        self: *ID3D11DeviceContext,
        res: *ID3D11Resource,
        subresource: UINT,
        map_type: Map,
    ) !MappedSubresource {
        var mapped: MappedSubresource = .{};
        const hr = self.vtable.Map(self, res, subresource, map_type, 0, &mapped);
        if (FAILED(hr)) return error.MapFailed;
        return mapped;
    }

    pub inline fn unmap(self: *ID3D11DeviceContext, res: *ID3D11Resource, subresource: UINT) void {
        self.vtable.Unmap(self, res, subresource);
    }

    pub inline fn updateSubresource(
        self: *ID3D11DeviceContext,
        res: *ID3D11Resource,
        subresource: UINT,
        data: *const anyopaque,
        row_pitch: UINT,
        depth_pitch: UINT,
    ) void {
        // A null box updates the entire resource.
        self.vtable.UpdateSubresource(self, res, subresource, null, data, row_pitch, depth_pitch);
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
