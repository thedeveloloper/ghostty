// Minimal native Windows host for Ghostty.
//
// This embeds libghostty through its C API (include/ghostty.h), the same way
// the macOS app embeds it through Swift. It opens a single window, creates a
// terminal surface bound to the window's HWND, drives the libghostty event
// loop, and translates Win32 keyboard/mouse/clipboard events into the core's
// input API. The Direct3D 11 renderer inside libghostty draws into the HWND.
//
// Out of scope for now: tabs/splits, native chrome, settings, and full IME
// composition (basic typing works via ToUnicode; IME preedit is a follow-up).

#include <windows.h>
#include <windowsx.h>

#include <cstring>
#include <string>

#include "ghostty.h"

namespace {

// State for our single window. libghostty calls back into us with the
// `userdata` pointer we register, which points at this.
struct Host {
    ghostty_app_t app = nullptr;
    ghostty_surface_t surface = nullptr;
    HWND hwnd = nullptr;

    // Current mouse cursor and whether it should be shown, applied in
    // WM_SETCURSOR (Windows resets the cursor on each one).
    HCURSOR cursor = nullptr;
    bool cursor_visible = true;

    // Saved window state for toggling borderless fullscreen.
    bool fullscreen = false;
    WINDOWPLACEMENT prev_placement = {sizeof(WINDOWPLACEMENT)};
    LONG_PTR prev_style = 0;
};

Host g_host;

// Posted to the window to ask the main thread to tick the libghostty loop.
constexpr UINT WM_GHOSTTY_WAKEUP = WM_USER + 1;

double dpiScale(HWND hwnd) {
    const UINT dpi = GetDpiForWindow(hwnd);
    return (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
}

// Current keyboard modifier state as a ghostty mods mask.
ghostty_input_mods_e currentMods() {
    int mods = GHOSTTY_MODS_NONE;
    if (GetKeyState(VK_SHIFT) & 0x8000)
        mods |= GHOSTTY_MODS_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000)
        mods |= GHOSTTY_MODS_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000)
        mods |= GHOSTTY_MODS_ALT;
    if ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000)
        mods |= GHOSTTY_MODS_SUPER;
    if (GetKeyState(VK_CAPITAL) & 0x0001)
        mods |= GHOSTTY_MODS_CAPS;
    if (GetKeyState(VK_NUMLOCK) & 0x0001)
        mods |= GHOSTTY_MODS_NUM;
    if (GetKeyState(VK_RSHIFT) & 0x8000)
        mods |= GHOSTTY_MODS_SHIFT_RIGHT;
    if (GetKeyState(VK_RCONTROL) & 0x8000)
        mods |= GHOSTTY_MODS_CTRL_RIGHT;
    if (GetKeyState(VK_RMENU) & 0x8000)
        mods |= GHOSTTY_MODS_ALT_RIGHT;
    return static_cast<ghostty_input_mods_e>(mods);
}

// The Windows scan code, which is what the core's keycode table is keyed on
// (Chromium's "win" column). Extended keys get the 0xE000 prefix.
uint32_t scancodeFromLParam(LPARAM lparam) {
    const uint32_t sc = static_cast<uint32_t>((lparam >> 16) & 0xFF);
    const bool extended = (lparam & (1 << 24)) != 0;
    return extended ? (0xE000u | sc) : sc;
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

// Map a ghostty mouse shape to a standard Win32 cursor.
LPCWSTR mouseShapeCursor(ghostty_action_mouse_shape_e shape) {
    switch (shape) {
    case GHOSTTY_MOUSE_SHAPE_TEXT:
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
    case GHOSTTY_MOUSE_SHAPE_CELL:
        return IDC_IBEAM;
    case GHOSTTY_MOUSE_SHAPE_POINTER:
    case GHOSTTY_MOUSE_SHAPE_ALIAS:
        return IDC_HAND;
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
        return IDC_CROSS;
    case GHOSTTY_MOUSE_SHAPE_WAIT:
        return IDC_WAIT;
    case GHOSTTY_MOUSE_SHAPE_PROGRESS:
        return IDC_APPSTARTING;
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
    case GHOSTTY_MOUSE_SHAPE_NO_DROP:
        return IDC_NO;
    case GHOSTTY_MOUSE_SHAPE_MOVE:
    case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL:
        return IDC_SIZEALL;
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
        return IDC_SIZEWE;
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
        return IDC_SIZENS;
    case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE:
        return IDC_SIZENESW;
    case GHOSTTY_MOUSE_SHAPE_NW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE:
        return IDC_SIZENWSE;
    default:
        return IDC_ARROW;
    }
}

// Toggle borderless fullscreen, saving and restoring the window style and
// placement.
void toggleFullscreen(Host* host) {
    HWND hwnd = host->hwnd;
    if (!host->fullscreen) {
        host->prev_style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        GetWindowPlacement(hwnd, &host->prev_placement);
        MONITORINFO mi = {sizeof(mi)};
        if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi)) {
            SetWindowLongPtrW(hwnd, GWL_STYLE,
                              host->prev_style & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
            SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                         mi.rcMonitor.right - mi.rcMonitor.left,
                         mi.rcMonitor.bottom - mi.rcMonitor.top,
                         SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            host->fullscreen = true;
        }
    } else {
        SetWindowLongPtrW(hwnd, GWL_STYLE, host->prev_style);
        SetWindowPlacement(hwnd, &host->prev_placement);
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        host->fullscreen = false;
    }
}

// Open a (url, len) pair with the system default handler.
void openUrl(const char* url, uintptr_t len) {
    if (url == nullptr || len == 0)
        return;
    const int wn = MultiByteToWideChar(CP_UTF8, 0, url, static_cast<int>(len), nullptr, 0);
    if (wn <= 0)
        return;
    std::wstring wide(static_cast<size_t>(wn), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, url, static_cast<int>(len), wide.data(), wn);
    ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

bool actionCb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)app;
    (void)target;
    Host* host = &g_host;
    if (host->hwnd == nullptr)
        return false;

    switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
        InvalidateRect(host->hwnd, nullptr, FALSE);
        return true;

    case GHOSTTY_ACTION_SET_TITLE:
        if (action.action.set_title.title != nullptr) {
            SetWindowTextA(host->hwnd, action.action.set_title.title);
        }
        return true;

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        host->cursor = LoadCursorW(nullptr, mouseShapeCursor(action.action.mouse_shape));
        SetCursor(host->cursor);
        return true;

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        host->cursor_visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE;
        SetCursor(host->cursor_visible ? host->cursor : nullptr);
        return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
        toggleFullscreen(host);
        return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
        ShowWindow(host->hwnd, IsZoomed(host->hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        return true;

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS: {
        const LONG_PTR style = GetWindowLongPtrW(host->hwnd, GWL_STYLE);
        SetWindowLongPtrW(host->hwnd, GWL_STYLE,
                          style ^ static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
        SetWindowPos(host->hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        return true;
    }

    case GHOSTTY_ACTION_INITIAL_SIZE: {
        RECT r = {0, 0, static_cast<LONG>(action.action.initial_size.width),
                  static_cast<LONG>(action.action.initial_size.height)};
        const DWORD style = static_cast<DWORD>(GetWindowLongPtrW(host->hwnd, GWL_STYLE));
        AdjustWindowRectExForDpi(&r, style, FALSE, 0, GetDpiForWindow(host->hwnd));
        SetWindowPos(host->hwnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top,
                     SWP_NOMOVE | SWP_NOZORDER);
        return true;
    }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
        ShowWindow(host->hwnd, SW_RESTORE);
        SetForegroundWindow(host->hwnd);
        return true;

    case GHOSTTY_ACTION_RING_BELL:
        MessageBeep(MB_OK);
        return true;

    case GHOSTTY_ACTION_OPEN_URL:
        openUrl(action.action.open_url.url, action.action.open_url.len);
        return true;

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_WINDOW:
        PostQuitMessage(0);
        return true;

    // TODO(windows): NEW_WINDOW/NEW_TAB/CLOSE_TAB/NEW_SPLIT require managing
    // multiple surfaces and a tab/split UI, which this single-window host does
    // not do yet. Desktop notifications also need a toast implementation.
    default:
        return false;
    }
}

// Read the standard clipboard as UTF-8 and hand it back to the core.
bool readClipboardCb(void* userdata, ghostty_clipboard_e location, void* state) {
    (void)location;
    auto* host = static_cast<Host*>(userdata);
    if (host == nullptr || host->surface == nullptr)
        return false;

    std::string utf8;
    if (OpenClipboard(host->hwnd)) {
        HANDLE handle = GetClipboardData(CF_UNICODETEXT);
        if (handle != nullptr) {
            const wchar_t* wide = static_cast<const wchar_t*>(GlobalLock(handle));
            if (wide != nullptr) {
                const int n =
                    WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
                if (n > 0) {
                    utf8.resize(static_cast<size_t>(n));
                    WideCharToMultiByte(CP_UTF8, 0, wide, -1, utf8.data(), n, nullptr, nullptr);
                }
                GlobalUnlock(handle);
            }
        }
        CloseClipboard();
    }

    ghostty_surface_complete_clipboard_request(host->surface, utf8.c_str(), state, true);
    return true;
}

void confirmReadClipboardCb(void* userdata, const char* str, void* state,
                            ghostty_clipboard_request_e request) {
    (void)userdata;
    (void)str;
    (void)state;
    (void)request;
}

// Write the first text content to the standard clipboard as UTF-16.
void writeClipboardCb(void* userdata, ghostty_clipboard_e location,
                      const ghostty_clipboard_content_s* content, size_t len, bool confirm) {
    (void)location;
    (void)confirm;
    auto* host = static_cast<Host*>(userdata);
    if (host == nullptr || content == nullptr || len == 0)
        return;

    const char* text = nullptr;
    for (size_t i = 0; i < len; i++) {
        if (content[i].mime != nullptr && std::strcmp(content[i].mime, "text/plain") == 0) {
            text = content[i].data;
            break;
        }
    }
    if (text == nullptr)
        text = content[0].data;
    if (text == nullptr)
        return;

    const int wn = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (wn <= 0)
        return;
    if (!OpenClipboard(host->hwnd))
        return;
    EmptyClipboard();
    HGLOBAL global = GlobalAlloc(GMEM_MOVEABLE, static_cast<size_t>(wn) * sizeof(wchar_t));
    if (global != nullptr) {
        auto* wide = static_cast<wchar_t*>(GlobalLock(global));
        MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, wn);
        GlobalUnlock(global);
        SetClipboardData(CF_UNICODETEXT, global);
    }
    CloseClipboard();
}

void closeSurfaceCb(void* userdata, bool process_alive) {
    (void)userdata;
    (void)process_alive;
    PostQuitMessage(0);
}

//----------------------------------------------------------------------------//
// Input
//----------------------------------------------------------------------------//

void handleKey(Host* host, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (host->surface == nullptr)
        return;

    const bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
    const bool repeat = down && (lparam & (1 << 30)) != 0;

    ghostty_input_key_s ev = {};
    ev.action =
        down ? (repeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) : GHOSTTY_ACTION_RELEASE;
    ev.mods = currentMods();
    ev.consumed_mods = GHOSTTY_MODS_NONE;
    ev.keycode = scancodeFromLParam(lparam);
    ev.composing = false;

    // Translate the key to its produced text (Enter -> \r, etc.). Only on key
    // down; ToUnicode also advances dead-key state.
    char utf8[16] = {0};
    if (down) {
        BYTE kb[256];
        if (GetKeyboardState(kb)) {
            WCHAR wide[8];
            const int n = ToUnicode(static_cast<UINT>(wparam),
                                    static_cast<UINT>((lparam >> 16) & 0xFF), kb, wide, 8, 0);
            if (n > 0) {
                WideCharToMultiByte(CP_UTF8, 0, wide, n, utf8, sizeof(utf8) - 1, nullptr, nullptr);
            }
        }
    }
    ev.text = utf8;

    // Unshifted codepoint, used for keybinding matching.
    uint32_t cp = MapVirtualKeyW(static_cast<UINT>(wparam), MAPVK_VK_TO_CHAR) & 0x7FFFFFFFu;
    if (cp >= 'A' && cp <= 'Z')
        cp += 32;
    ev.unshifted_codepoint = cp;

    ghostty_surface_key(host->surface, ev);
}

void handleMouseButton(Host* host, ghostty_input_mouse_state_e state,
                       ghostty_input_mouse_button_e button) {
    if (host->surface == nullptr)
        return;
    if (state == GHOSTTY_MOUSE_PRESS) {
        SetCapture(host->hwnd);
    } else {
        ReleaseCapture();
    }
    ghostty_surface_mouse_button(host->surface, state, button, currentMods());
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

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP:
        handleKey(host, msg, wparam, lparam);
        return 0;

    case WM_SETCURSOR:
        // Apply our tracked cursor over the client area; let the system
        // handle borders/resize edges.
        if (LOWORD(lparam) == HTCLIENT) {
            SetCursor(host->cursor_visible ? host->cursor : nullptr);
            return TRUE;
        }
        break;

    case WM_MOUSEMOVE:
        if (host->surface != nullptr) {
            ghostty_surface_mouse_pos(host->surface, static_cast<double>(GET_X_LPARAM(lparam)),
                                      static_cast<double>(GET_Y_LPARAM(lparam)), currentMods());
        }
        return 0;

    case WM_LBUTTONDOWN:
        handleMouseButton(host, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT);
        return 0;
    case WM_LBUTTONUP:
        handleMouseButton(host, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT);
        return 0;
    case WM_RBUTTONDOWN:
        handleMouseButton(host, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT);
        return 0;
    case WM_RBUTTONUP:
        handleMouseButton(host, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT);
        return 0;
    case WM_MBUTTONDOWN:
        handleMouseButton(host, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE);
        return 0;
    case WM_MBUTTONUP:
        handleMouseButton(host, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE);
        return 0;

    case WM_MOUSEWHEEL:
        if (host->surface != nullptr) {
            const double delta = static_cast<double>(GET_WHEEL_DELTA_WPARAM(wparam)) / WHEEL_DELTA;
            ghostty_surface_mouse_scroll(host->surface, 0.0, delta, 0);
        }
        return 0;

    case WM_MOUSEHWHEEL:
        if (host->surface != nullptr) {
            const double delta = static_cast<double>(GET_WHEEL_DELTA_WPARAM(wparam)) / WHEEL_DELTA;
            ghostty_surface_mouse_scroll(host->surface, delta, 0.0, 0);
        }
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

    g_host.cursor = LoadCursorW(nullptr, IDC_IBEAM);

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
