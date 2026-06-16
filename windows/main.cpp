// Minimal native Windows host for Ghostty.
//
// This embeds libghostty through its C API (include/ghostty.h), the same way
// the macOS app embeds it through Swift. The top-level window owns a tab strip
// and routes events; each terminal surface lives in its own child window (one
// surface <-> one HWND <-> one Direct3D swap chain). Keyboard, mouse, and
// clipboard input are translated to the core's input API.
//
// Out of scope for now: split panes within a tab, full IME composition, native
// settings UI, and desktop-notification toasts.

#include <windows.h>
#include <windowsx.h>

#include <cstring>
#include <string>
#include <vector>

#include "ghostty.h"

namespace {

// One terminal surface, hosted in a child window of the top-level window.
struct Surface {
    HWND hwnd = nullptr;
    ghostty_surface_t surface = nullptr;
    std::string title;

    // Current cursor and visibility, applied in WM_SETCURSOR.
    HCURSOR cursor = nullptr;
    bool cursor_visible = true;
};

// The application: one libghostty app, a top-level window, and a list of tabs
// (each tab is currently a single surface; split panes come later).
struct App {
    ghostty_app_t app = nullptr;
    HWND hwnd = nullptr;
    std::vector<Surface*> tabs;
    size_t active = 0;

    // Saved window state for toggling borderless fullscreen.
    bool fullscreen = false;
    WINDOWPLACEMENT prev_placement = {sizeof(WINDOWPLACEMENT)};
    LONG_PTR prev_style = 0;
};

App g_app;

constexpr UINT WM_GHOSTTY_WAKEUP = WM_USER + 1;
const wchar_t* kSurfaceClass = L"GhosttySurface";
const wchar_t* kWindowClass = L"GhosttyWindow";

double dpiScale(HWND hwnd) {
    const UINT dpi = GetDpiForWindow(hwnd);
    return (dpi == 0 ? 96.0 : static_cast<double>(dpi)) / 96.0;
}

int tabBarHeight(HWND hwnd) { return static_cast<int>(28.0 * dpiScale(hwnd)); }

//----------------------------------------------------------------------------//
// Input helpers
//----------------------------------------------------------------------------//

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

// The Windows scan code keys the core's keycode table (Chromium's "win"
// column); extended keys get the 0xE000 prefix.
uint32_t scancodeFromLParam(LPARAM lparam) {
    const uint32_t sc = static_cast<uint32_t>((lparam >> 16) & 0xFF);
    const bool extended = (lparam & (1 << 24)) != 0;
    return extended ? (0xE000u | sc) : sc;
}

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

//----------------------------------------------------------------------------//
// Tab management
//----------------------------------------------------------------------------//

Surface* activeSurface(App* app) { return app->tabs.empty() ? nullptr : app->tabs[app->active]; }

// Place the active surface's child window over the content area (below the tab
// strip) and hide the others.
void layoutTabs(App* app) {
    RECT client;
    GetClientRect(app->hwnd, &client);
    const int bar = tabBarHeight(app->hwnd);
    for (size_t i = 0; i < app->tabs.size(); i++) {
        HWND child = app->tabs[i]->hwnd;
        if (i == app->active) {
            SetWindowPos(child, nullptr, client.left, client.top + bar, client.right - client.left,
                         client.bottom - client.top - bar, SWP_NOZORDER | SWP_SHOWWINDOW);
        } else {
            ShowWindow(child, SW_HIDE);
        }
    }
    InvalidateRect(app->hwnd, nullptr, FALSE);
}

void setActiveTab(App* app, size_t index) {
    if (index >= app->tabs.size())
        return;
    app->active = index;
    layoutTabs(app);
    Surface* s = activeSurface(app);
    if (s != nullptr) {
        SetFocus(s->hwnd);
        SetWindowTextA(app->hwnd, s->title.empty() ? "Ghostty" : s->title.c_str());
    }
}

Surface* createSurface(App* app); // forward declaration

void addTab(App* app) {
    Surface* s = createSurface(app);
    if (s == nullptr)
        return;
    app->tabs.push_back(s);
    setActiveTab(app, app->tabs.size() - 1);
}

void closeTabAt(App* app, size_t index) {
    if (index >= app->tabs.size())
        return;
    Surface* s = app->tabs[index];
    ghostty_surface_free(s->surface);
    DestroyWindow(s->hwnd);
    delete s;
    app->tabs.erase(app->tabs.begin() + static_cast<long>(index));

    if (app->tabs.empty()) {
        PostQuitMessage(0);
        return;
    }
    setActiveTab(app, app->active >= app->tabs.size() ? app->tabs.size() - 1 : app->active);
}

// Find the tab index hosting the given libghostty surface, or -1.
ptrdiff_t indexOfSurface(App* app, ghostty_surface_t surface) {
    for (size_t i = 0; i < app->tabs.size(); i++) {
        if (app->tabs[i]->surface == surface)
            return static_cast<ptrdiff_t>(i);
    }
    return -1;
}

//----------------------------------------------------------------------------//
// Window-level actions
//----------------------------------------------------------------------------//

void toggleFullscreen(App* app) {
    HWND hwnd = app->hwnd;
    if (!app->fullscreen) {
        app->prev_style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        GetWindowPlacement(hwnd, &app->prev_placement);
        MONITORINFO mi = {sizeof(mi)};
        if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi)) {
            SetWindowLongPtrW(hwnd, GWL_STYLE,
                              app->prev_style & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
            SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                         mi.rcMonitor.right - mi.rcMonitor.left,
                         mi.rcMonitor.bottom - mi.rcMonitor.top,
                         SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            app->fullscreen = true;
        }
    } else {
        SetWindowLongPtrW(hwnd, GWL_STYLE, app->prev_style);
        SetWindowPlacement(hwnd, &app->prev_placement);
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        app->fullscreen = false;
    }
}

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

//----------------------------------------------------------------------------//
// libghostty runtime callbacks
//----------------------------------------------------------------------------//

void wakeupCb(void* userdata) {
    auto* app = static_cast<App*>(userdata);
    if (app != nullptr && app->hwnd != nullptr)
        PostMessageW(app->hwnd, WM_GHOSTTY_WAKEUP, 0, 0);
}

bool actionCb(ghostty_app_t app_handle, ghostty_target_s target, ghostty_action_s action) {
    (void)app_handle;
    App* app = &g_app;
    if (app->hwnd == nullptr)
        return false;

    // The surface this action targets, if any.
    Surface* surface = nullptr;
    if (target.tag == GHOSTTY_TARGET_SURFACE) {
        const ptrdiff_t i = indexOfSurface(app, target.target.surface);
        if (i >= 0)
            surface = app->tabs[static_cast<size_t>(i)];
    }
    if (surface == nullptr)
        surface = activeSurface(app);

    switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
        if (surface != nullptr)
            InvalidateRect(surface->hwnd, nullptr, FALSE);
        return true;

    case GHOSTTY_ACTION_SET_TITLE:
        if (surface != nullptr && action.action.set_title.title != nullptr) {
            surface->title = action.action.set_title.title;
            InvalidateRect(app->hwnd, nullptr, FALSE);
            if (surface == activeSurface(app)) {
                SetWindowTextA(app->hwnd, surface->title.c_str());
            }
        }
        return true;

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        if (surface != nullptr) {
            surface->cursor = LoadCursorW(nullptr, mouseShapeCursor(action.action.mouse_shape));
            SetCursor(surface->cursor);
        }
        return true;

    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        if (surface != nullptr) {
            surface->cursor_visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE;
            SetCursor(surface->cursor_visible ? surface->cursor : nullptr);
        }
        return true;

    case GHOSTTY_ACTION_NEW_TAB:
        addTab(app);
        return true;

    case GHOSTTY_ACTION_CLOSE_TAB:
        if (surface != nullptr) {
            const ptrdiff_t i = indexOfSurface(app, surface->surface);
            if (i >= 0)
                closeTabAt(app, static_cast<size_t>(i));
        }
        return true;

    case GHOSTTY_ACTION_GOTO_TAB: {
        const int n = static_cast<int>(app->tabs.size());
        if (n == 0)
            return true;
        const int v = static_cast<int>(action.action.goto_tab);
        size_t target_index = app->active;
        if (v == GHOSTTY_GOTO_TAB_PREVIOUS) {
            target_index = (app->active + static_cast<size_t>(n) - 1) % static_cast<size_t>(n);
        } else if (v == GHOSTTY_GOTO_TAB_NEXT) {
            target_index = (app->active + 1) % static_cast<size_t>(n);
        } else if (v == GHOSTTY_GOTO_TAB_LAST) {
            target_index = static_cast<size_t>(n - 1);
        } else if (v >= 0 && v < n) {
            target_index = static_cast<size_t>(v);
        }
        setActiveTab(app, target_index);
        return true;
    }

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
        toggleFullscreen(app);
        return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
        ShowWindow(app->hwnd, IsZoomed(app->hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        return true;

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS: {
        const LONG_PTR style = GetWindowLongPtrW(app->hwnd, GWL_STYLE);
        SetWindowLongPtrW(app->hwnd, GWL_STYLE, style ^ static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
        SetWindowPos(app->hwnd, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        return true;
    }

    case GHOSTTY_ACTION_INITIAL_SIZE: {
        RECT r = {0, 0, static_cast<LONG>(action.action.initial_size.width),
                  static_cast<LONG>(action.action.initial_size.height + tabBarHeight(app->hwnd))};
        const DWORD style = static_cast<DWORD>(GetWindowLongPtrW(app->hwnd, GWL_STYLE));
        AdjustWindowRectExForDpi(&r, style, FALSE, 0, GetDpiForWindow(app->hwnd));
        SetWindowPos(app->hwnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top,
                     SWP_NOMOVE | SWP_NOZORDER);
        return true;
    }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
        ShowWindow(app->hwnd, SW_RESTORE);
        SetForegroundWindow(app->hwnd);
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

    // TODO(windows): split panes (NEW_SPLIT/GOTO_SPLIT/...) and desktop
    // notification toasts are not implemented yet.
    default:
        return false;
    }
}

bool readClipboardCb(void* userdata, ghostty_clipboard_e location, void* state) {
    (void)location;
    auto* surface = static_cast<Surface*>(userdata);
    if (surface == nullptr || surface->surface == nullptr)
        return false;

    std::string utf8;
    if (OpenClipboard(surface->hwnd)) {
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

    ghostty_surface_complete_clipboard_request(surface->surface, utf8.c_str(), state, true);
    return true;
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
    (void)location;
    (void)confirm;
    auto* surface = static_cast<Surface*>(userdata);
    if (surface == nullptr || content == nullptr || len == 0)
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
    if (!OpenClipboard(surface->hwnd))
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
    (void)process_alive;
    auto* surface = static_cast<Surface*>(userdata);
    if (surface == nullptr)
        return;
    const ptrdiff_t i = indexOfSurface(&g_app, surface->surface);
    if (i >= 0)
        closeTabAt(&g_app, static_cast<size_t>(i));
}

//----------------------------------------------------------------------------//
// Per-surface child window
//----------------------------------------------------------------------------//

void handleKey(Surface* s, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (s->surface == nullptr)
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

    uint32_t cp = MapVirtualKeyW(static_cast<UINT>(wparam), MAPVK_VK_TO_CHAR) & 0x7FFFFFFFu;
    if (cp >= 'A' && cp <= 'Z')
        cp += 32;
    ev.unshifted_codepoint = cp;

    ghostty_surface_key(s->surface, ev);
}

void handleMouseButton(Surface* s, ghostty_input_mouse_state_e state,
                       ghostty_input_mouse_button_e button) {
    if (s->surface == nullptr)
        return;
    if (state == GHOSTTY_MOUSE_PRESS) {
        SetCapture(s->hwnd);
    } else {
        ReleaseCapture();
    }
    ghostty_surface_mouse_button(s->surface, state, button, currentMods());
}

LRESULT CALLBACK surfaceWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCTW*>(lparam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    auto* s = reinterpret_cast<Surface*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (s == nullptr)
        return DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps;
        BeginPaint(hwnd, &ps);
        if (s->surface != nullptr)
            ghostty_surface_draw(s->surface);
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_SIZE:
        if (s->surface != nullptr) {
            ghostty_surface_set_size(s->surface, LOWORD(lparam), HIWORD(lparam));
        }
        return 0;

    case WM_SETFOCUS:
        if (s->surface != nullptr)
            ghostty_surface_set_focus(s->surface, true);
        return 0;

    case WM_KILLFOCUS:
        if (s->surface != nullptr)
            ghostty_surface_set_focus(s->surface, false);
        return 0;

    case WM_SETCURSOR:
        if (LOWORD(lparam) == HTCLIENT) {
            SetCursor(s->cursor_visible ? s->cursor : nullptr);
            return TRUE;
        }
        break;

    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP:
        handleKey(s, msg, wparam, lparam);
        return 0;

    case WM_MOUSEMOVE:
        if (s->surface != nullptr) {
            ghostty_surface_mouse_pos(s->surface, static_cast<double>(GET_X_LPARAM(lparam)),
                                      static_cast<double>(GET_Y_LPARAM(lparam)), currentMods());
        }
        return 0;

    case WM_LBUTTONDOWN:
        handleMouseButton(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT);
        return 0;
    case WM_LBUTTONUP:
        handleMouseButton(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT);
        return 0;
    case WM_RBUTTONDOWN:
        handleMouseButton(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT);
        return 0;
    case WM_RBUTTONUP:
        handleMouseButton(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT);
        return 0;
    case WM_MBUTTONDOWN:
        handleMouseButton(s, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE);
        return 0;
    case WM_MBUTTONUP:
        handleMouseButton(s, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE);
        return 0;

    case WM_MOUSEWHEEL:
        if (s->surface != nullptr) {
            ghostty_surface_mouse_scroll(
                s->surface, 0.0, static_cast<double>(GET_WHEEL_DELTA_WPARAM(wparam)) / WHEEL_DELTA,
                0);
        }
        return 0;
    case WM_MOUSEHWHEEL:
        if (s->surface != nullptr) {
            ghostty_surface_mouse_scroll(
                s->surface, static_cast<double>(GET_WHEEL_DELTA_WPARAM(wparam)) / WHEEL_DELTA, 0.0,
                0);
        }
        return 0;

    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

Surface* createSurface(App* app) {
    auto* s = new Surface();
    s->cursor = LoadCursorW(nullptr, IDC_IBEAM);
    s->hwnd = CreateWindowExW(0, kSurfaceClass, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0,
                              app->hwnd, nullptr, GetModuleHandleW(nullptr), s);
    if (s->hwnd == nullptr) {
        delete s;
        return nullptr;
    }

    ghostty_surface_config_s config = ghostty_surface_config_new();
    config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    config.platform.windows.hwnd = s->hwnd;
    config.userdata = s;
    config.scale_factor = dpiScale(s->hwnd);
    s->surface = ghostty_surface_new(app->app, &config);
    if (s->surface == nullptr) {
        DestroyWindow(s->hwnd);
        delete s;
        return nullptr;
    }
    return s;
}

//----------------------------------------------------------------------------//
// Top-level window
//----------------------------------------------------------------------------//

// Draw the tab strip across the top of the window.
void paintTabBar(App* app, HDC dc) {
    RECT client;
    GetClientRect(app->hwnd, &client);
    const int bar = tabBarHeight(app->hwnd);
    const int n = static_cast<int>(app->tabs.size());
    if (n == 0)
        return;

    RECT strip = {client.left, client.top, client.right, client.top + bar};
    FillRect(dc, &strip, reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1));

    const int width = (client.right - client.left) / n;
    SetBkMode(dc, TRANSPARENT);
    for (int i = 0; i < n; i++) {
        RECT tab = {client.left + i * width, client.top,
                    (i == n - 1) ? client.right : client.left + (i + 1) * width, client.top + bar};
        FillRect(dc, &tab,
                 reinterpret_cast<HBRUSH>(
                     (static_cast<size_t>(i) == app->active ? COLOR_WINDOW : COLOR_BTNFACE) + 1));
        FrameRect(dc, &tab, reinterpret_cast<HBRUSH>(COLOR_BTNSHADOW + 1));
        const std::string& title = app->tabs[static_cast<size_t>(i)]->title;
        const std::string label = title.empty() ? "Ghostty" : title;
        RECT text = tab;
        text.left += 8;
        DrawTextA(dc, label.c_str(), -1, &text,
                  DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS | DT_NOPREFIX);
    }
}

LRESULT CALLBACK appWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    App* app = &g_app;
    switch (msg) {
    case WM_GHOSTTY_WAKEUP:
        if (app->app != nullptr)
            ghostty_app_tick(app->app);
        return 0;

    case WM_SIZE:
        layoutTabs(app);
        return 0;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        paintTabBar(app, dc);
        EndPaint(hwnd, &ps);
        return 0;
    }

    case WM_LBUTTONDOWN: {
        const int y = GET_Y_LPARAM(lparam);
        const int n = static_cast<int>(app->tabs.size());
        if (y < tabBarHeight(hwnd) && n > 0) {
            RECT client;
            GetClientRect(hwnd, &client);
            const int width = (client.right - client.left) / n;
            const int idx = (width > 0) ? GET_X_LPARAM(lparam) / width : 0;
            setActiveTab(app, static_cast<size_t>(idx < n ? idx : n - 1));
        }
        return 0;
    }

    case WM_SETFOCUS: {
        Surface* s = activeSurface(app);
        if (s != nullptr)
            SetFocus(s->hwnd);
        return 0;
    }

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

    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_default_files(config);
    ghostty_config_finalize(config);

    ghostty_runtime_config_s runtime = {};
    runtime.userdata = &g_app;
    runtime.supports_selection_clipboard = false;
    runtime.wakeup_cb = wakeupCb;
    runtime.action_cb = actionCb;
    runtime.read_clipboard_cb = readClipboardCb;
    runtime.confirm_read_clipboard_cb = confirmReadClipboardCb;
    runtime.write_clipboard_cb = writeClipboardCb;
    runtime.close_surface_cb = closeSurfaceCb;

    g_app.app = ghostty_app_new(&runtime, config);
    ghostty_config_free(config);
    if (g_app.app == nullptr) {
        MessageBoxW(nullptr, L"ghostty_app_new failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    WNDCLASSEXW surface_class = {};
    surface_class.cbSize = sizeof(surface_class);
    surface_class.style = CS_HREDRAW | CS_VREDRAW;
    surface_class.lpfnWndProc = surfaceWndProc;
    surface_class.hInstance = hInstance;
    surface_class.lpszClassName = kSurfaceClass;
    RegisterClassExW(&surface_class);

    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.lpfnWndProc = appWndProc;
    window_class.hInstance = hInstance;
    window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClass;
    RegisterClassExW(&window_class);

    g_app.hwnd = CreateWindowExW(0, kWindowClass, L"Ghostty", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                                 CW_USEDEFAULT, 800, 600, nullptr, nullptr, hInstance, nullptr);
    if (g_app.hwnd == nullptr) {
        MessageBoxW(nullptr, L"CreateWindow failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    addTab(&g_app);
    if (g_app.tabs.empty()) {
        MessageBoxW(nullptr, L"ghostty_surface_new failed", L"Ghostty", MB_ICONERROR);
        return 1;
    }

    ShowWindow(g_app.hwnd, nCmdShow);
    UpdateWindow(g_app.hwnd);
    ghostty_app_tick(g_app.app);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    for (Surface* s : g_app.tabs) {
        ghostty_surface_free(s->surface);
        delete s;
    }
    ghostty_app_free(g_app.app);
    return static_cast<int>(msg.wParam);
}
