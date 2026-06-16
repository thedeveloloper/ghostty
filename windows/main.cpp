// Minimal native Windows host for Ghostty.
//
// This embeds libghostty through its C API (include/ghostty.h), the same way
// the macOS app embeds it through Swift. It is a proof of concept: it opens a
// single window, creates a terminal surface bound to the window's HWND, drives
// the libghostty event loop, and feeds basic keyboard input. The Direct3D 11
// renderer inside libghostty draws into the HWND.
//
// Richer input, tabs/splits, native chrome, and settings are intentionally out
// of scope here; this exists to prove the embedding + render path end to end.

#include <windows.h>

#include "ghostty.h"

namespace {

// State for our single window. libghostty calls back into us with the
// `userdata` pointer we register, which points at this.
struct Host {
    ghostty_app_t app = nullptr;
    ghostty_surface_t surface = nullptr;
    HWND hwnd = nullptr;
};

Host g_host;

// Posted to the window to ask the main thread to tick the libghostty loop.
constexpr UINT WM_GHOSTTY_WAKEUP = WM_USER + 1;

double dpiScale(HWND hwnd) {
    const UINT dpi = GetDpiForWindow(hwnd);
    return (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
}

//----------------------------------------------------------------------------//
// libghostty runtime callbacks
//----------------------------------------------------------------------------//

// Called (possibly from the renderer thread) when the core needs the host to
// advance its event loop. We post a message so the tick happens on the main
// thread that owns the window.
void wakeupCb(void* userdata) {
    auto* host = static_cast<Host*>(userdata);
    if (host != nullptr && host->hwnd != nullptr) {
        PostMessageW(host->hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
    }
}

bool actionCb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)app;
    (void)target;
    switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
        if (g_host.hwnd != nullptr)
            InvalidateRect(g_host.hwnd, nullptr, FALSE);
        return true;

    case GHOSTTY_ACTION_SET_TITLE:
        if (g_host.hwnd != nullptr && action.action.set_title.title != nullptr) {
            SetWindowTextA(g_host.hwnd, action.action.set_title.title);
        }
        return true;

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_WINDOW:
        PostQuitMessage(0);
        return true;

    default:
        // Unhandled actions are fine to ignore for the proof of concept.
        return false;
    }
}

// Clipboard is not yet implemented (Phase 4). Reads fail gracefully and writes
// are dropped.
bool readClipboardCb(void* userdata, ghostty_clipboard_e location, void* state) {
    (void)userdata;
    (void)location;
    (void)state;
    return false;
}

void confirmReadClipboardCb(void* userdata, const char* str, void* state,
                            ghostty_clipboard_request_e request) {
    (void)userdata;
    (void)str;
    (void)state;
    (void)request;
}

void writeClipboardCb(void* userdata, ghostty_clipboard_e location,
                      const ghostty_clipboard_content_s* content, size_t len, bool confirm) {
    (void)userdata;
    (void)location;
    (void)content;
    (void)len;
    (void)confirm;
}

void closeSurfaceCb(void* userdata, bool process_alive) {
    (void)userdata;
    (void)process_alive;
    PostQuitMessage(0);
}

//----------------------------------------------------------------------------//
// Input
//----------------------------------------------------------------------------//

// Feed typed UTF-16 text (from WM_CHAR, including Enter as \r) to the surface
// as terminal input. This is the minimal path; proper key-event translation
// (modifiers, key bindings, IME) is Phase 4.
void feedText(Host* host, wchar_t ch) {
    if (host->surface == nullptr)
        return;
    char utf8[8];
    const int n = WideCharToMultiByte(CP_UTF8, 0, &ch, 1, utf8, sizeof(utf8), nullptr, nullptr);
    if (n > 0)
        ghostty_surface_text(host->surface, utf8, static_cast<uintptr_t>(n));
}

LRESULT CALLBACK wndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    Host* host = &g_host;
    switch (msg) {
    case WM_GHOSTTY_WAKEUP:
        if (host->app != nullptr)
            ghostty_app_tick(host->app);
        return 0;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        if (host->surface != nullptr)
            ghostty_surface_draw(host->surface);
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_SIZE:
        if (host->surface != nullptr) {
            ghostty_surface_set_size(host->surface, LOWORD(lparam), HIWORD(lparam));
        }
        return 0;

    case WM_DPICHANGED: {
        if (host->surface != nullptr) {
            const double scale = dpiScale(hwnd);
            ghostty_surface_set_content_scale(host->surface, scale, scale);
        }
        const RECT* r = reinterpret_cast<const RECT*>(lparam);
        SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }

    case WM_SETFOCUS:
        if (host->surface != nullptr)
            ghostty_surface_set_focus(host->surface, true);
        return 0;

    case WM_KILLFOCUS:
        if (host->surface != nullptr)
            ghostty_surface_set_focus(host->surface, false);
        return 0;

    case WM_CHAR:
        feedText(host, static_cast<wchar_t>(wparam));
        return 0;

    case WM_CLOSE:
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, PWSTR, int nCmdShow) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    if (ghostty_init(0, nullptr) != 0) {
        MessageBoxW(nullptr, L"ghostty_init failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    // Build the configuration from the user's default config files.
    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_default_files(config);
    ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime = {};
    runtime.userdata = &g_host;
    runtime.supports_selection_clipboard = false;
    runtime.wakeup_cb = wakeupCb;
    runtime.action_cb = actionCb;
    runtime.read_clipboard_cb = readClipboardCb;
    runtime.confirm_read_clipboard_cb = confirmReadClipboardCb;
    runtime.write_clipboard_cb = writeClipboardCb;
    runtime.close_surface_cb = closeSurfaceCb;

    g_host.app = ghostty_app_new(&runtime, config);
    ghostty_config_free(config);
    if (g_host.app == nullptr) {
        MessageBoxW(nullptr, L"ghostty_app_new failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    const wchar_t* class_name = L"GhosttyWindow";
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hInstance;
    wc.hCursor = LoadCursor(nullptr, IDC_IBEAM);
    wc.lpszClassName = class_name;
    RegisterClassExW(&wc);

    g_host.hwnd = CreateWindowExW(0, class_name, L"Ghostty", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                                  CW_USEDEFAULT, 800, 600, nullptr, nullptr, hInstance, nullptr);
    if (g_host.hwnd == nullptr) {
        MessageBoxW(nullptr, L"CreateWindow failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    // Create the terminal surface bound to our window.
    ghostty_surface_config_s surface_config = ghostty_surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_config.platform.windows.hwnd = g_host.hwnd;
    surface_config.userdata = &g_host;
    surface_config.scale_factor = dpiScale(g_host.hwnd);
    g_host.surface = ghostty_surface_new(g_host.app, &surface_config);
    if (g_host.surface == nullptr) {
        MessageBoxW(nullptr, L"ghostty_surface_new failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    // Push the initial size and focus, then show the window.
    RECT client;
    GetClientRect(g_host.hwnd, &client);
    ghostty_surface_set_size(g_host.surface, client.right - client.left,
                             client.bottom - client.top);
    ghostty_surface_set_focus(g_host.surface, true);

    ShowWindow(g_host.hwnd, nCmdShow);
    UpdateWindow(g_host.hwnd);

    // Process any events queued during startup.
    ghostty_app_tick(g_host.app);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    ghostty_surface_free(g_host.surface);
    ghostty_app_free(g_host.app);
    return static_cast<int>(msg.wParam);
}
