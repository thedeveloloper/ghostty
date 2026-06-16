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

pub const Viewport = extern struct {
    TopLeftX: FLOAT = 0,
    TopLeftY: FLOAT = 0,
    Width: FLOAT,
    Height: FLOAT,
    MinDepth: FLOAT = 0,
    MaxDepth: FLOAT = 1,
};

pub const PrimitiveTopology = enum(c_uint) {
    triangle_list = 4,
    triangle_strip = 5,
};

/// `D3D11_SRV_DIMENSION_BUFFER`.
pub const SRV_DIMENSION_BUFFER: c_uint = 1;

/// A shader resource view descriptor. The trailing fields are a union in
/// the C API, sized for its largest member (4 UINTs); for a structured
/// buffer we only use the first two (FirstElement, NumElements).
pub const ShaderResourceViewDesc = extern struct {
    Format: Format,
    ViewDimension: c_uint,
    u0: u32 = 0,
    u1: u32 = 0,
    u2: u32 = 0,
    u3: u32 = 0,
};

/// A GPU buffer together with an optional shader resource view, present for
/// structured buffers that are read in the shaders. This is the handle the
/// render pass binds.
pub const BoundBuffer = struct {
    buffer: *ID3D11Buffer,
    srv: ?*ID3D11ShaderResourceView = null,
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
        CreateVertexShader: *const fn (
            *ID3D11Device,
            *const anyopaque,
            usize,
            ?*anyopaque,
            *?*ID3D11VertexShader,
        ) callconv(.winapi) HRESULT,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const fn (
            *ID3D11Device,
            *const anyopaque,
            usize,
            ?*anyopaque,
            *?*ID3D11PixelShader,
        ) callconv(.winapi) HRESULT,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const fn (
            *ID3D11Device,
            *const BlendDesc,
            *?*ID3D11BlendState,
        ) callconv(.winapi) HRESULT,
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

    /// Create a shader resource view over a structured buffer so it can be
    /// read as a `StructuredBuffer<T>` in the shaders.
    pub inline fn createBufferSRV(
        self: *ID3D11Device,
        buffer: *ID3D11Buffer,
        num_elements: u32,
    ) !*ID3D11ShaderResourceView {
        var desc: ShaderResourceViewDesc = .{
            .Format = .unknown,
            .ViewDimension = SRV_DIMENSION_BUFFER,
            .u0 = 0, // FirstElement
            .u1 = num_elements, // NumElements
        };
        var out: ?*ID3D11ShaderResourceView = null;
        const hr = self.vtable.CreateShaderResourceView(self, buffer.resource(), &desc, &out);
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

    pub inline fn createVertexShader(self: *ID3D11Device, bytecode: []const u8) !*ID3D11VertexShader {
        var out: ?*ID3D11VertexShader = null;
        const hr = self.vtable.CreateVertexShader(self, bytecode.ptr, bytecode.len, null, &out);
        if (FAILED(hr)) return error.CreateVertexShaderFailed;
        return out orelse error.CreateVertexShaderFailed;
    }

    pub inline fn createPixelShader(self: *ID3D11Device, bytecode: []const u8) !*ID3D11PixelShader {
        var out: ?*ID3D11PixelShader = null;
        const hr = self.vtable.CreatePixelShader(self, bytecode.ptr, bytecode.len, null, &out);
        if (FAILED(hr)) return error.CreatePixelShaderFailed;
        return out orelse error.CreatePixelShaderFailed;
    }

    pub inline fn createBlendState(self: *ID3D11Device, desc: *const BlendDesc) !*ID3D11BlendState {
        var out: ?*ID3D11BlendState = null;
        const hr = self.vtable.CreateBlendState(self, desc, &out);
        if (FAILED(hr)) return error.CreateBlendStateFailed;
        return out orelse error.CreateBlendStateFailed;
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
        VSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, ?[*]const ?*ID3D11Buffer) callconv(.winapi) void,
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, ?[*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void,
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?*const anyopaque, UINT) callconv(.winapi) void,
        PSSetSamplers: *const fn (*ID3D11DeviceContext, UINT, UINT, ?[*]const ?*ID3D11SamplerState) callconv(.winapi) void,
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?*const anyopaque, UINT) callconv(.winapi) void,
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
        PSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, ?[*]const ?*ID3D11Buffer) callconv(.winapi) void,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const fn (*ID3D11DeviceContext, UINT, UINT, UINT, UINT) callconv(.winapi) void,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, c_uint) callconv(.winapi) void,
        VSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, ?[*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, UINT, ?[*]const ?*ID3D11RenderTargetView, ?*anyopaque) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, ?*const [4]f32, UINT) callconv(.winapi) void,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const fn (*ID3D11DeviceContext, UINT, ?[*]const Viewport) callconv(.winapi) void,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const fn (*ID3D11DeviceContext, *ID3D11Resource, *ID3D11Resource) callconv(.winapi) void,
        UpdateSubresource: *const fn (
            *ID3D11DeviceContext,
            *ID3D11Resource,
            UINT,
            ?*const anyopaque,
            *const anyopaque,
            UINT,
            UINT,
        ) callconv(.winapi) void,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (
            *ID3D11DeviceContext,
            *ID3D11RenderTargetView,
            *const [4]f32,
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

    pub inline fn vsSetShader(self: *ID3D11DeviceContext, shader: *ID3D11VertexShader) void {
        self.vtable.VSSetShader(self, shader, null, 0);
    }

    pub inline fn psSetShader(self: *ID3D11DeviceContext, shader: *ID3D11PixelShader) void {
        self.vtable.PSSetShader(self, shader, null, 0);
    }

    pub inline fn vsSetConstantBuffer(self: *ID3D11DeviceContext, slot: UINT, buffer: *ID3D11Buffer) void {
        self.vtable.VSSetConstantBuffers(self, slot, 1, &[_]?*ID3D11Buffer{buffer});
    }

    pub inline fn psSetConstantBuffer(self: *ID3D11DeviceContext, slot: UINT, buffer: *ID3D11Buffer) void {
        self.vtable.PSSetConstantBuffers(self, slot, 1, &[_]?*ID3D11Buffer{buffer});
    }

    pub inline fn vsSetShaderResource(self: *ID3D11DeviceContext, slot: UINT, srv: *ID3D11ShaderResourceView) void {
        self.vtable.VSSetShaderResources(self, slot, 1, &[_]?*ID3D11ShaderResourceView{srv});
    }

    pub inline fn psSetShaderResource(self: *ID3D11DeviceContext, slot: UINT, srv: *ID3D11ShaderResourceView) void {
        self.vtable.PSSetShaderResources(self, slot, 1, &[_]?*ID3D11ShaderResourceView{srv});
    }

    pub inline fn psSetSampler(self: *ID3D11DeviceContext, slot: UINT, sampler: *ID3D11SamplerState) void {
        self.vtable.PSSetSamplers(self, slot, 1, &[_]?*ID3D11SamplerState{sampler});
    }

    pub inline fn iaSetPrimitiveTopology(self: *ID3D11DeviceContext, topology: PrimitiveTopology) void {
        self.vtable.IASetPrimitiveTopology(self, @intFromEnum(topology));
    }

    pub inline fn rsSetViewport(self: *ID3D11DeviceContext, viewport: Viewport) void {
        self.vtable.RSSetViewports(self, 1, &[_]Viewport{viewport});
    }

    pub inline fn omSetRenderTarget(self: *ID3D11DeviceContext, rtv: *ID3D11RenderTargetView) void {
        self.vtable.OMSetRenderTargets(self, 1, &[_]?*ID3D11RenderTargetView{rtv}, null);
    }

    pub inline fn omSetBlendState(self: *ID3D11DeviceContext, blend: ?*ID3D11BlendState) void {
        self.vtable.OMSetBlendState(self, blend, null, 0xffffffff);
    }

    pub inline fn clearRenderTargetView(self: *ID3D11DeviceContext, rtv: *ID3D11RenderTargetView, color: [4]f32) void {
        self.vtable.ClearRenderTargetView(self, rtv, &color);
    }

    pub inline fn drawInstanced(self: *ID3D11DeviceContext, vertex_count: UINT, instance_count: UINT) void {
        self.vtable.DrawInstanced(self, vertex_count, instance_count, 0, 0);
    }

    pub inline fn copyResource(self: *ID3D11DeviceContext, dst: *ID3D11Resource, src: *ID3D11Resource) void {
        self.vtable.CopyResource(self, dst, src);
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

// -- Pipeline state ------------------------------------------------------

pub const Blend = enum(c_uint) {
    zero = 1,
    one = 2,
    src_alpha = 5,
    inv_src_alpha = 6,
};

pub const BlendOp = enum(c_uint) {
    add = 1,
};

/// `D3D11_COLOR_WRITE_ENABLE_ALL`.
pub const COLOR_WRITE_ENABLE_ALL: u8 = 0x0f;

pub const RenderTargetBlendDesc = extern struct {
    BlendEnable: BOOL = 0,
    SrcBlend: Blend = .one,
    DestBlend: Blend = .zero,
    BlendOp: BlendOp = .add,
    SrcBlendAlpha: Blend = .one,
    DestBlendAlpha: Blend = .zero,
    BlendOpAlpha: BlendOp = .add,
    RenderTargetWriteMask: u8 = COLOR_WRITE_ENABLE_ALL,
};

pub const BlendDesc = extern struct {
    AlphaToCoverageEnable: BOOL = 0,
    IndependentBlendEnable: BOOL = 0,
    RenderTarget: [8]RenderTargetBlendDesc = [_]RenderTargetBlendDesc{.{}} ** 8,
};

/// `ID3DBlob` (a.k.a. ID3D10Blob): a chunk of compiled shader bytecode or
/// compiler error text.
pub const ID3DBlob = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.winapi) ULONG,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) ?*anyopaque,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };
    pub inline fn release(self: *ID3DBlob) void {
        _ = self.vtable.Release(self);
    }
    pub inline fn bytes(self: *ID3DBlob) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.vtable.GetBufferPointer(self).?);
        return ptr[0..self.vtable.GetBufferSize(self)];
    }
};

pub const ID3D11VertexShader = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11VertexShader) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11VertexShader) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3D11PixelShader = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11PixelShader) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11PixelShader) void {
        _ = self.vtable.Release(self);
    }
};

pub const ID3D11BlendState = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3D11BlendState) callconv(.winapi) ULONG,
    };
    pub inline fn release(self: *ID3D11BlendState) void {
        _ = self.vtable.Release(self);
    }
};

// -- Entry points --------------------------------------------------------

pub extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: *const anyopaque,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: ?[*:0]const u8,
    pTarget: ?[*:0]const u8,
    Flags1: UINT,
    Flags2: UINT,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.winapi) HRESULT;

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
