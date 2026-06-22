// Minimal native Windows host for Ghostty.
//
// This embeds libghostty through its C API (include/ghostty.h), the same way
// the macOS app embeds it through Swift. The top-level window owns a tab strip
// and routes events. Each terminal surface lives in its own child window (one
// surface <-> one HWND <-> one Direct3D swap chain). A tab is a binary split
// tree of panes, so a tab can be divided into multiple surfaces. Keyboard,
// mouse, and clipboard input are translated to the core's input API.
//
// Out of scope for now: full IME composition, native settings UI, and
// desktop-notification toasts.

#include <windows.h>
#include <windowsx.h>
// dbghelp.h must follow windows.h.
#include <dbghelp.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "ghostty.h"

namespace {

// One terminal surface, hosted in a child window.
struct Surface {
    HWND hwnd = nullptr;
    ghostty_surface_t surface = nullptr;
    std::string title;

    HCURSOR cursor = nullptr;
    bool cursor_visible = true;
};

// A node in a tab's split tree: a leaf (one surface) or a split of two panes.
struct Pane {
    Surface* surface = nullptr; // non-null for a leaf
    Pane* a = nullptr;          // children for a split (a is left/top)
    Pane* b = nullptr;
    Pane* parent = nullptr;
    bool vertical = false;    // true: a over b; false: a beside b
    double ratio = 0.5;       // fraction of the split given to `a`
    RECT rect = {0, 0, 0, 0}; // last laid-out rect, used for spatial nav

    bool leaf() const { return surface != nullptr; }
};

// A tab: a split tree plus the focused leaf and an optional zoom.
struct Tab {
    Pane* root = nullptr;
    Surface* focused = nullptr;
    bool zoomed = false;
};

// The application: one libghostty app, a top-level window, and a list of tabs.
struct App {
    ghostty_app_t app = nullptr;
    HWND hwnd = nullptr;
    std::vector<Tab*> tabs;
    size_t active = 0;

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

Surface* createSurface(App* app); // forward declaration

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
// Split tree helpers
//----------------------------------------------------------------------------//

void collectLeaves(Pane* pane, std::vector<Pane*>& out) {
    if (pane == nullptr)
        return;
    if (pane->leaf()) {
        out.push_back(pane);
    } else {
        collectLeaves(pane->a, out);
        collectLeaves(pane->b, out);
    }
}

Pane* firstLeaf(Pane* pane) {
    while (pane != nullptr && !pane->leaf())
        pane = pane->a;
    return pane;
}

Pane* paneForSurface(Pane* pane, Surface* s) {
    if (pane == nullptr)
        return nullptr;
    if (pane->leaf())
        return pane->surface == s ? pane : nullptr;
    Pane* found = paneForSurface(pane->a, s);
    return found != nullptr ? found : paneForSurface(pane->b, s);
}

Tab* tabForSurface(App* app, Surface* s) {
    for (Tab* tab : app->tabs) {
        if (paneForSurface(tab->root, s) != nullptr)
            return tab;
    }
    return nullptr;
}

// Lay out a pane subtree within `rect`, positioning leaf child windows.
void layoutPane(Pane* pane, RECT rect) {
    if (pane == nullptr)
        return;
    pane->rect = rect;
    if (pane->leaf()) {
        SetWindowPos(pane->surface->hwnd, nullptr, rect.left, rect.top, rect.right - rect.left,
                     rect.bottom - rect.top, SWP_NOZORDER | SWP_SHOWWINDOW);
        return;
    }
    if (pane->vertical) {
        const int split = rect.top + static_cast<int>((rect.bottom - rect.top) * pane->ratio);
        layoutPane(pane->a, {rect.left, rect.top, rect.right, split});
        layoutPane(pane->b, {rect.left, split, rect.right, rect.bottom});
    } else {
        const int split = rect.left + static_cast<int>((rect.right - rect.left) * pane->ratio);
        layoutPane(pane->a, {rect.left, rect.top, split, rect.bottom});
        layoutPane(pane->b, {split, rect.top, rect.right, rect.bottom});
    }
}

Surface* activeSurface(App* app) {
    if (app->tabs.empty())
        return nullptr;
    return app->tabs[app->active]->focused;
}

// Show/position the active tab's panes; hide every other tab's surfaces.
void layoutTabs(App* app) {
    RECT client;
    GetClientRect(app->hwnd, &client);
    const int bar = tabBarHeight(app->hwnd);
    const RECT content = {client.left, client.top + bar, client.right, client.bottom};

    for (size_t i = 0; i < app->tabs.size(); i++) {
        Tab* tab = app->tabs[i];
        std::vector<Pane*> leaves;
        collectLeaves(tab->root, leaves);
        if (i != app->active) {
            for (Pane* leaf : leaves)
                ShowWindow(leaf->surface->hwnd, SW_HIDE);
            continue;
        }
        if (tab->zoomed && tab->focused != nullptr) {
            for (Pane* leaf : leaves) {
                if (leaf->surface == tab->focused) {
                    SetWindowPos(leaf->surface->hwnd, nullptr, content.left, content.top,
                                 content.right - content.left, content.bottom - content.top,
                                 SWP_NOZORDER | SWP_SHOWWINDOW);
                } else {
                    ShowWindow(leaf->surface->hwnd, SW_HIDE);
                }
            }
        } else {
            layoutPane(tab->root, content);
        }
    }
    InvalidateRect(app->hwnd, nullptr, FALSE);
}

void focusSurface(App* app, Surface* s) {
    if (s == nullptr)
        return;
    Tab* tab = tabForSurface(app, s);
    if (tab != nullptr)
        tab->focused = s;
    SetFocus(s->hwnd);
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

void addTab(App* app) {
    Surface* s = createSurface(app);
    if (s == nullptr)
        return;
    auto* tab = new Tab();
    tab->root = new Pane();
    tab->root->surface = s;
    tab->focused = s;
    app->tabs.push_back(tab);
    setActiveTab(app, app->tabs.size() - 1);
}

// Split the focused pane, creating a new surface beside or below it.
void splitFocused(App* app, Tab* tab, ghostty_action_split_direction_e dir) {
    Pane* leaf = paneForSurface(tab->root, tab->focused);
    if (leaf == nullptr)
        return;
    Surface* ns = createSurface(app);
    if (ns == nullptr)
        return;

    auto* split = new Pane();
    split->vertical = (dir == GHOSTTY_SPLIT_DIRECTION_DOWN || dir == GHOSTTY_SPLIT_DIRECTION_UP);
    split->parent = leaf->parent;

    auto* new_leaf = new Pane();
    new_leaf->surface = ns;
    new_leaf->parent = split;

    const bool new_first =
        (dir == GHOSTTY_SPLIT_DIRECTION_LEFT || dir == GHOSTTY_SPLIT_DIRECTION_UP);
    split->a = new_first ? new_leaf : leaf;
    split->b = new_first ? leaf : new_leaf;

    Pane* parent = leaf->parent;
    leaf->parent = split;
    if (parent == nullptr) {
        tab->root = split;
    } else if (parent->a == leaf) {
        parent->a = split;
    } else {
        parent->b = split;
    }

    tab->focused = ns;
    tab->zoomed = false;
    layoutTabs(app);
}

void removeTab(App* app, Tab* tab) {
    for (size_t i = 0; i < app->tabs.size(); i++) {
        if (app->tabs[i] != tab)
            continue;
        app->tabs.erase(app->tabs.begin() + static_cast<long>(i));
        delete tab;
        if (app->tabs.empty()) {
            PostQuitMessage(0);
            return;
        }
        setActiveTab(app, app->active >= app->tabs.size() ? app->tabs.size() - 1 : app->active);
        return;
    }
}

void freeTree(Pane* pane) {
    if (pane == nullptr)
        return;
    freeTree(pane->a);
    freeTree(pane->b);
    delete pane;
}

// Close a single surface, collapsing its split (or closing the tab if it was
// the tab's only pane).
void closeSurface(App* app, Surface* s) {
    Tab* tab = tabForSurface(app, s);
    if (tab == nullptr)
        return;
    Pane* leaf = paneForSurface(tab->root, s);
    Pane* parent = leaf->parent;

    ghostty_surface_free(s->surface);
    DestroyWindow(s->hwnd);

    if (parent == nullptr) {
        // The tab's only pane: the whole tab goes away.
        delete leaf;
        tab->root = nullptr;
        delete s;
        removeTab(app, tab);
        return;
    }

    // Replace the parent split with the surviving sibling.
    Pane* sibling = (parent->a == leaf) ? parent->b : parent->a;
    Pane* grand = parent->parent;
    sibling->parent = grand;
    if (grand == nullptr) {
        tab->root = sibling;
    } else if (grand->a == parent) {
        grand->a = sibling;
    } else {
        grand->b = sibling;
    }
    delete leaf;
    delete parent;

    if (tab->focused == s) {
        Pane* nf = firstLeaf(sibling);
        tab->focused = nf != nullptr ? nf->surface : nullptr;
    }
    tab->zoomed = false;
    delete s;

    if (tab == app->tabs[app->active]) {
        layoutTabs(app);
        focusSurface(app, tab->focused);
    }
}

// Move focus to another pane in the tab, by order or by direction.
void gotoSplit(App* app, Tab* tab, ghostty_action_goto_split_e dir) {
    std::vector<Pane*> leaves;
    collectLeaves(tab->root, leaves);
    if (leaves.size() < 2)
        return;

    Pane* current = paneForSurface(tab->root, tab->focused);
    if (current == nullptr)
        return;

    if (dir == GHOSTTY_GOTO_SPLIT_PREVIOUS || dir == GHOSTTY_GOTO_SPLIT_NEXT) {
        size_t idx = 0;
        for (size_t i = 0; i < leaves.size(); i++) {
            if (leaves[i] == current)
                idx = i;
        }
        const size_t n = leaves.size();
        idx = (dir == GHOSTTY_GOTO_SPLIT_NEXT) ? (idx + 1) % n : (idx + n - 1) % n;
        focusSurface(app, leaves[idx]->surface);
        return;
    }

    // Directional: pick the nearest leaf whose center lies in that direction.
    const int cx = (current->rect.left + current->rect.right) / 2;
    const int cy = (current->rect.top + current->rect.bottom) / 2;
    Pane* best = nullptr;
    long best_dist = 0;
    for (Pane* leaf : leaves) {
        if (leaf == current)
            continue;
        const int lx = (leaf->rect.left + leaf->rect.right) / 2;
        const int ly = (leaf->rect.top + leaf->rect.bottom) / 2;
        bool ok = false;
        switch (dir) {
        case GHOSTTY_GOTO_SPLIT_LEFT:
            ok = lx < cx;
            break;
        case GHOSTTY_GOTO_SPLIT_RIGHT:
            ok = lx > cx;
            break;
        case GHOSTTY_GOTO_SPLIT_UP:
            ok = ly < cy;
            break;
        case GHOSTTY_GOTO_SPLIT_DOWN:
            ok = ly > cy;
            break;
        default:
            break;
        }
        if (!ok)
            continue;
        const long dist = (lx - cx) * (lx - cx) + (ly - cy) * (ly - cy);
        if (best == nullptr || dist < best_dist) {
            best = leaf;
            best_dist = dist;
        }
    }
    if (best != nullptr)
        focusSurface(app, best->surface);
}

// Resize the focused pane's enclosing split in the given direction.
void resizeSplit(App* app, Tab* tab, ghostty_action_resize_split_s rs) {
    Pane* leaf = paneForSurface(tab->root, tab->focused);
    if (leaf == nullptr)
        return;
    const bool want_vertical =
        (rs.direction == GHOSTTY_RESIZE_SPLIT_UP || rs.direction == GHOSTTY_RESIZE_SPLIT_DOWN);

    // Walk up to the nearest split with the matching orientation.
    Pane* node = leaf;
    while (node->parent != nullptr && node->parent->vertical != want_vertical)
        node = node->parent;
    Pane* split = node->parent;
    if (split == nullptr)
        return;

    const int extent = want_vertical ? (split->rect.bottom - split->rect.top)
                                     : (split->rect.right - split->rect.left);
    if (extent <= 0)
        return;
    double delta = static_cast<double>(rs.amount) / extent;
    // Growing the focused side means increasing `a` when focus is in `a`.
    const bool grow =
        (rs.direction == GHOSTTY_RESIZE_SPLIT_DOWN || rs.direction == GHOSTTY_RESIZE_SPLIT_RIGHT);
    if (split->b == node || !grow)
        delta = -delta;
    split->ratio += delta;
    if (split->ratio < 0.05)
        split->ratio = 0.05;
    if (split->ratio > 0.95)
        split->ratio = 0.95;
    layoutTabs(app);
}

void equalizeSplits(Pane* pane) {
    if (pane == nullptr || pane->leaf())
        return;
    pane->ratio = 0.5;
    equalizeSplits(pane->a);
    equalizeSplits(pane->b);
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

// Convert a UTF-8 string to a wide string. A negative len treats the input as
// null-terminated; otherwise it is the byte length.
std::wstring utf8ToWide(const char* s, int len) {
    if (s == nullptr)
        return {};
    const int wn = MultiByteToWideChar(CP_UTF8, 0, s, len, nullptr, 0);
    if (wn <= 0)
        return {};
    std::wstring wide(static_cast<size_t>(wn), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, len, wide.data(), wn);
    // A null-terminated input includes the terminator in the count; drop it.
    if (len < 0 && !wide.empty() && wide.back() == L'\0')
        wide.pop_back();
    return wide;
}

void openUrl(const char* url, uintptr_t len) {
    if (url == nullptr || len == 0)
        return;
    const std::wstring wide = utf8ToWide(url, static_cast<int>(len));
    if (wide.empty())
        return;
    ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

// Open the configuration file, creating it if needed. Triggered by the
// OPEN_CONFIG action. Opens it with the file's associated program, falling
// back to Notepad when the configuration file type has no association.
void openConfig() {
    const ghostty_string_s path = ghostty_config_open_path();
    if (path.ptr == nullptr || path.len == 0)
        return;
    const std::wstring wide = utf8ToWide(path.ptr, static_cast<int>(path.len));
    ghostty_string_free(path);
    if (wide.empty())
        return;

    const HINSTANCE rc =
        ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(rc) <= 32) {
        std::wstring cmd = L"notepad.exe \"" + wide + L"\"";
        STARTUPINFOW si = {sizeof(si)};
        PROCESS_INFORMATION pi = {};
        if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si,
                           &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }
}

// Reload configuration from disk and propagate it to the app and all surfaces.
// Mirrors the initial load in wWinMain. update_config does not take ownership,
// so we free our copy afterward.
void reloadConfig(App* app) {
    ghostty_config_t config = ghostty_config_new();
    ghostty_config_load_default_files(config);
    ghostty_config_finalize(config);
    ghostty_app_update_config(app->app, config);
    ghostty_config_free(config);
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

    // Resolve the targeted surface by its libghostty handle, if any.
    Surface* surface = nullptr;
    if (target.tag == GHOSTTY_TARGET_SURFACE) {
        for (Tab* tab : app->tabs) {
            std::vector<Pane*> leaves;
            collectLeaves(tab->root, leaves);
            for (Pane* leaf : leaves) {
                if (leaf->surface->surface == target.target.surface)
                    surface = leaf->surface;
            }
        }
    }
    if (surface == nullptr)
        surface = activeSurface(app);
    Tab* tab = surface != nullptr ? tabForSurface(app, surface) : nullptr;

    switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
        if (surface != nullptr)
            InvalidateRect(surface->hwnd, nullptr, FALSE);
        return true;

    case GHOSTTY_ACTION_SET_TITLE:
        if (surface != nullptr && action.action.set_title.title != nullptr) {
            surface->title = action.action.set_title.title;
            InvalidateRect(app->hwnd, nullptr, FALSE);
            if (surface == activeSurface(app))
                SetWindowTextA(app->hwnd, surface->title.c_str());
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
        if (tab != nullptr) {
            std::vector<Pane*> leaves;
            collectLeaves(tab->root, leaves);
            for (Pane* leaf : leaves)
                closeSurface(app, leaf->surface);
        }
        return true;

    case GHOSTTY_ACTION_GOTO_TAB: {
        const int n = static_cast<int>(app->tabs.size());
        if (n == 0)
            return true;
        const int v = static_cast<int>(action.action.goto_tab);
        size_t idx = app->active;
        if (v == GHOSTTY_GOTO_TAB_PREVIOUS) {
            idx = (app->active + static_cast<size_t>(n) - 1) % static_cast<size_t>(n);
        } else if (v == GHOSTTY_GOTO_TAB_NEXT) {
            idx = (app->active + 1) % static_cast<size_t>(n);
        } else if (v == GHOSTTY_GOTO_TAB_LAST) {
            idx = static_cast<size_t>(n - 1);
        } else if (v >= 0 && v < n) {
            idx = static_cast<size_t>(v);
        }
        setActiveTab(app, idx);
        return true;
    }

    case GHOSTTY_ACTION_NEW_SPLIT:
        if (tab != nullptr)
            splitFocused(app, tab, action.action.new_split);
        return true;

    case GHOSTTY_ACTION_GOTO_SPLIT:
        if (tab != nullptr)
            gotoSplit(app, tab, action.action.goto_split);
        return true;

    case GHOSTTY_ACTION_RESIZE_SPLIT:
        if (tab != nullptr)
            resizeSplit(app, tab, action.action.resize_split);
        return true;

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
        if (tab != nullptr) {
            equalizeSplits(tab->root);
            layoutTabs(app);
        }
        return true;

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
        if (tab != nullptr) {
            tab->zoomed = !tab->zoomed;
            layoutTabs(app);
        }
        return true;

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

    case GHOSTTY_ACTION_OPEN_CONFIG:
        openConfig();
        return true;

    case GHOSTTY_ACTION_RELOAD_CONFIG:
        reloadConfig(app);
        return true;

    case GHOSTTY_ACTION_CONFIG_CHANGE:
        // The configuration changed; repaint so any visual changes take
        // effect. The core propagates the new config to surfaces itself.
        InvalidateRect(app->hwnd, nullptr, FALSE);
        return true;

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_WINDOW:
        PostQuitMessage(0);
        return true;

    // TODO(windows): desktop-notification toasts are not implemented yet.
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
    if (surface != nullptr)
        closeSurface(&g_app, surface);
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
        SetFocus(s->hwnd);
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
        if (s->surface != nullptr)
            ghostty_surface_set_size(s->surface, LOWORD(lparam), HIWORD(lparam));
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
        Surface* focused = app->tabs[static_cast<size_t>(i)]->focused;
        const std::string label =
            (focused != nullptr && !focused->title.empty()) ? focused->title : "Ghostty";
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

// Unhandled-exception handler: write a symbolized backtrace of the crashing
// thread to ghostty-crash.txt next to the exe, so crashes can be diagnosed
// without a debugger. Symbols resolve from the .pdb the Debug build emits.
LONG WINAPI crashHandler(EXCEPTION_POINTERS* ep) {
    HANDLE process = GetCurrentProcess();
    HANDLE thread = GetCurrentThread();
    SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME);
    SymInitialize(process, nullptr, TRUE);

    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    std::wstring out(exe);
    out = out.substr(0, out.find_last_of(L"\\/") + 1) + L"ghostty-crash.txt";
    FILE* f = _wfopen(out.c_str(), L"w");
    if (f == nullptr)
        return EXCEPTION_EXECUTE_HANDLER;

    fprintf(f, "Unhandled exception 0x%08lX at %p\n\n", ep->ExceptionRecord->ExceptionCode,
            ep->ExceptionRecord->ExceptionAddress);

    CONTEXT context = *ep->ContextRecord;
    STACKFRAME64 frame = {};
    frame.AddrPC.Offset = context.Rip;
    frame.AddrPC.Mode = AddrModeFlat;
    frame.AddrFrame.Offset = context.Rbp;
    frame.AddrFrame.Mode = AddrModeFlat;
    frame.AddrStack.Offset = context.Rsp;
    frame.AddrStack.Mode = AddrModeFlat;

    char symbuf[sizeof(SYMBOL_INFO) + 512] = {};
    auto* sym = reinterpret_cast<SYMBOL_INFO*>(symbuf);

    for (int i = 0; i < 64; i++) {
        if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, process, thread, &frame, &context, nullptr,
                         SymFunctionTableAccess64, SymGetModuleBase64, nullptr))
            break;
        if (frame.AddrPC.Offset == 0)
            break;

        const DWORD64 base = SymGetModuleBase64(process, frame.AddrPC.Offset);
        char module[64] = "?";
        if (base != 0) {
            IMAGEHLP_MODULE64 mi = {};
            mi.SizeOfStruct = sizeof(mi);
            if (SymGetModuleInfo64(process, base, &mi)) {
                strncpy(module, mi.ModuleName, sizeof(module) - 1);
            }
        }

        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen = 511;
        DWORD64 disp = 0;
        if (SymFromAddr(process, frame.AddrPC.Offset, &disp, sym)) {
            IMAGEHLP_LINE64 line = {};
            line.SizeOfStruct = sizeof(line);
            DWORD line_disp = 0;
            if (SymGetLineFromAddr64(process, frame.AddrPC.Offset, &line_disp, &line)) {
                fprintf(f, "%2d  %s!%s + 0x%llx  (%s:%lu)\n", i, module, sym->Name, disp,
                        line.FileName, line.LineNumber);
            } else {
                fprintf(f, "%2d  %s!%s + 0x%llx\n", i, module, sym->Name, disp);
            }
        } else {
            fprintf(f, "%2d  %s + 0x%llx\n", i, module, frame.AddrPC.Offset - base);
        }
    }

    fclose(f);
    MessageBoxW(nullptr, L"Ghostty crashed. A backtrace was written to ghostty-crash.txt.",
                L"Ghostty crash", MB_ICONERROR);
    return EXCEPTION_EXECUTE_HANDLER;
}

} // namespace

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, PWSTR, int nCmdShow) {
    SetUnhandledExceptionFilter(crashHandler);
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

    for (Tab* tab : g_app.tabs) {
        std::vector<Pane*> leaves;
        collectLeaves(tab->root, leaves);
        for (Pane* leaf : leaves) {
            ghostty_surface_free(leaf->surface->surface);
            delete leaf->surface;
        }
        freeTree(tab->root);
        delete tab;
    }
    ghostty_app_free(g_app.app);
    return static_cast<int>(msg.wParam);
}
