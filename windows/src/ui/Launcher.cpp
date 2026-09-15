#include "Launcher.h"
#include <shellapi.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <imm.h>
#include <uxtheme.h>
#include <cmath>
#include <algorithm>
#include <set>

namespace frog {
namespace {
constexpr UINT timerAnimation = 1, timerLongPress = 2, timerDrag = 3, timerStatus = 4, timerReload = 5, timerImageRetry = 6;
D2D1_RECT_F drect(Rect r) { return D2D1::RectF(r.x, r.y, r.x + r.width, r.y + r.height); }
D2D1_COLOR_F color(UINT32 rgb, float alpha = 1) { return D2D1::ColorF(rgb, alpha); }
D2D1_COLOR_F systemColor(int index) { COLORREF c = GetSysColor(index); return D2D1::ColorF(GetRValue(c) / 255.0f, GetGValue(c) / 255.0f, GetBValue(c) / 255.0f); }
bool sameProcess(HWND window) { DWORD pid{}; if (window) GetWindowThreadProcessId(window, &pid); return pid == GetCurrentProcessId(); }
}
Launcher::Launcher(Options options, Instance& instance)
    : options_(std::move(options)), instance_(instance), diagnostics_(options_.diagnostics), storageQueue_(std::make_unique<SerialQueue>()) {
    try { preferences_ = Preferences::load(options_); }
    catch (const std::exception& error) {
        // 偏好损坏时进入显式错误状态，避免保存覆盖它或误写默认数据。
        throw Error(std::string("无法读取偏好。请保留 preferences.json 并修复后重新启动。\n") + error.what());
    }
    view_.rootPage = preferences_.page; theme_.update(preferences_);
    WNDCLASSEXW cls{sizeof(cls)}; cls.hInstance = GetModuleHandleW(nullptr); cls.lpfnWndProc = controllerProc; cls.lpszClassName = L"FrogController";
    RegisterClassExW(&cls);
    controller_ = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, instance_.windowTitle().c_str(), WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, cls.hInstance, this);
    require(controller_ != nullptr, winError("无法创建应用控制器"));
    taskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated"); instance_.listen(controller_);
    try { hotkey_.set(controller_, preferences_.hotkey); } catch (const std::exception& error) { status_ = error.what(); statusPersistent_ = true; }
    corners_.configure(controller_, preferences_.cornersEnabled, preferences_.corners);
    cacheDirectory_ = options_.isolated ? fs::temp_directory_path() / wide("Frog-session-" + uuid()) : localDirectory() / L"IconCache";
    images_ = std::make_unique<Images>(cacheDirectory_, options_.offline, [this](Images::Result result) {
        dispatch([this, result = std::move(result)]() mutable {
            auto requested = requestedIcons_.find(result.url);
            if (images_ && result.generation == images_->generation() && requested != requestedIcons_.end() && requested->second == result.request)
                receivedImage(std::move(result));
        });
    });
    tray(true); diagnostics_.event("process_started", {{"isolated", options_.isolated}, {"offline", options_.offline}, {"background", options_.background}, {"iconCacheDirectory", utf8(cacheDirectory_.wstring())}});
    loadInitial();
}
Launcher::~Launcher() {
    watcher_.stop(); images_.reset(); storageQueue_.reset();
    MSG message{}; while (PeekMessageW(&message, controller_, wmDispatch, wmDispatch, PM_REMOVE)) delete reinterpret_cast<std::function<void()>*>(message.lParam);
    { std::lock_guard lock(accessibility_->mutex); accessibility_->window = nullptr; accessibility_->nodes.clear(); }
    if (provider_) UiaDisconnectProvider(provider_.Get()); provider_.Reset();
    tray(false); if (window_) DestroyWindow(window_); if (controller_) DestroyWindow(controller_);
    if (font_) DeleteObject(font_); if (editBrush_) DeleteObject(editBrush_);
    if (options_.isolated && !cacheDirectory_.empty()) { std::error_code ec; fs::remove_all(cacheDirectory_, ec); }
}
int Launcher::run() {
    if (!options_.background) show();
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
      try {
        if (msg.message == WM_KEYDOWN || msg.message == WM_SYSKEYDOWN) {
            if (visible_ && sameProcess(GetForegroundWindow()) && !inMenu_ && !systemPanel_) {
                if (keyboard(msg.wParam, (GetKeyState(VK_CONTROL) & 0x8000) != 0, (GetKeyState(VK_SHIFT) & 0x8000) != 0)) continue;
            }
        }
        if (panel_ != Panel::none && visible_ && !composing_ && IsDialogMessageW(window_, &msg)) continue;
        TranslateMessage(&msg); DispatchMessageW(&msg);
      } catch (const std::exception& error) { notify(error.what(), true); }
    }
    return static_cast<int>(msg.wParam);
}
void Launcher::dispatch(std::function<void()> action) {
    auto* task = new std::function<void()>(std::move(action)); if (!PostMessageW(controller_, wmDispatch, 0, reinterpret_cast<LPARAM>(task))) delete task;
}
LRESULT CALLBACK Launcher::controllerProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto* self = reinterpret_cast<Launcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) { self = static_cast<Launcher*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self)); self->controller_ = window; }
    if (self) try { return self->controllerMessage(message, w, l); } catch (const std::exception& error) { self->notify(error.what(), true); return 0; }
    return DefWindowProcW(window, message, w, l);
}
LRESULT Launcher::controllerMessage(UINT message, WPARAM w, LPARAM l) {
    if (taskbarCreated_ && message == taskbarCreated_) { tray(true); return 0; }
    switch (message) {
    case wmDispatch: { std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(l)); if (!quitting_) (*task)(); return 0; }
    case wmActivate: show(); return 0;
    case WM_HOTKEY: if (visible_) hide(); else show(); return 0;
    case wmCorner: if (!visible_ && !systemPanel_) show(); return 0;
    case wmDirectory: if (!quitting_) SetTimer(controller_, timerReload, 180, nullptr); return 0;
    case WM_TIMER:
        if (w == timerReload) { KillTimer(controller_, timerReload); reload(); }
        else if (w == timerImageRetry) { KillTimer(controller_, timerImageRetry); requestImages(); }
        return 0;
    case wmTray:
        if (LOWORD(l) == WM_CONTEXTMENU || LOWORD(l) == WM_RBUTTONUP) trayMenu();
        else if (LOWORD(l) == NIN_SELECT || LOWORD(l) == NIN_KEYSELECT) { if (visible_) hide(); else show(); } return 0;
    case WM_POWERBROADCAST: if (w == PBT_APMRESUMEAUTOMATIC || w == PBT_APMRESUMESUSPEND) { reload(); if (visible_) { place(false); requestImages(); } } return TRUE;
    case WM_QUERYENDSESSION: return TRUE;
    case WM_ENDSESSION: if (w) quit(); return 0;
    }
    return DefWindowProcW(controller_, message, w, l);
}
void Launcher::createWindow() {
    if (window_) return;
    WNDCLASSEXW cls{sizeof(cls)}; cls.hInstance = GetModuleHandleW(nullptr); cls.lpfnWndProc = windowProc; cls.lpszClassName = L"FrogLauncher"; cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hIcon = LoadIconW(cls.hInstance, MAKEINTRESOURCEW(101)); cls.hIconSm = cls.hIcon;
    RegisterClassExW(&cls);
    window_ = CreateWindowExW(WS_EX_APPWINDOW, cls.lpszClassName, L"青蛙导航", WS_POPUP | WS_MINIMIZEBOX | WS_CLIPCHILDREN, 0, 0, 1280, 720, nullptr, nullptr, cls.hInstance, this);
    require(window_ != nullptr, winError("无法创建启动台窗口"));
    search_ = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(10), cls.hInstance, nullptr);
    SendMessageW(search_, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(L"搜索书签或输入网址"));
    SendMessageW(search_, EM_SETLIMITTEXT, 2048, 0);
    accessibleName(search_, L"搜索书签或输入网址");
    SetWindowSubclass(search_, controlProc, 1, reinterpret_cast<DWORD_PTR>(this));
    settingsButton_ = CreateWindowExW(0, L"BUTTON", L"设置", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(11), cls.hInstance, nullptr);
    addButton_ = CreateWindowExW(0, L"BUTTON", L"添加书签", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(12), cls.hInstance, nullptr);
    provider_.Attach(createAccessibility(accessibility_)); accessibility_->window = window_;
    updateTheme();
}
void Launcher::show(bool showSettings) {
    if (quitting_) return;
    if (visible_) { if (showSettings) settings(); SetForegroundWindow(window_); return; }
    showStart_ = milliseconds(); paintPending_ = true; createWindow(); place(true); visible_ = true;
    images_->resume(); corners_.suppress(true); requestImages();
    ShowWindow(window_, SW_SHOWNORMAL); SetForegroundWindow(window_);
    if (showSettings) settings();
    if (panel_ == Panel::none) SetFocus(search_); else if (!controls_.empty()) SetFocus(controls_.begin()->second);
    animate(); reload(); requestWallpaper();
    diagnostics_.event("show_requested", {{"first", firstShow_}});
}
void Launcher::hide() {
    if (!visible_) return;
    if (panel_ == Panel::bookmark) readDraft();
    cancelDrag(); hotkeyCapture_ = false; visible_ = false; paintPending_ = false;
    KillTimer(window_, timerAnimation); KillTimer(window_, timerLongPress); KillTimer(window_, timerDrag); KillTimer(window_, timerStatus);
    KillTimer(controller_, timerImageRetry);
    animationStart_ = 0; view_.organizing = false; ShowWindow(window_, SW_HIDE); images_->pause(); requestedIcons_.clear();
    corners_.suppress(systemPanel_); savePage(); diagnostics_.event("hidden");
}
void Launcher::quit() {
    if (busy_) { notify("正在保存数据，请完成后再退出。"); return; }
    hide(); quitting_ = true; PostQuitMessage(0);
}
void Launcher::place(bool mouseMonitor) {
    if (!window_) return; POINT point{}; GetCursorPos(&point);
    auto monitor = mouseMonitor ? MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) : MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    auto rect = monitorWorkArea(monitor);
    SetWindowPos(window_, HWND_TOP, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, SWP_NOACTIVATE);
    dpiScale_ = GetDpiForWindow(window_) / 96.0f; updateLayout();
}
void Launcher::updateLayout() {
    if (!window_) return;
    RECT rect{}; GetClientRect(window_, &rect); dpiScale_ = GetDpiForWindow(window_) / 96.0f;
    view_.layout = {rect.right / dpiScale_, rect.bottom / dpiScale_};
    float x = (view_.layout.width - 380) / 2;
    auto placeControl = [&](HWND handle, float px, float py, float width, float height) { MoveWindow(handle, static_cast<int>(px * dpiScale_), static_cast<int>(py * dpiScale_), static_cast<int>(width * dpiScale_), static_cast<int>(height * dpiScale_), TRUE); };
    placeControl(search_, x + 34, 42, 304, 22); placeControl(settingsButton_, x + 396, 34, 36, 36); placeControl(addButton_, x + 438, 34, 36, 36);
    if (target_) {
        target_->SetDpi(96 * dpiScale_, 96 * dpiScale_); auto size = target_->GetPixelSize();
        if (size.width != static_cast<UINT>(rect.right) || size.height != static_cast<UINT>(rect.bottom)) {
            auto result = target_->Resize(D2D1::SizeU(rect.right, rect.bottom));
            if (result == D2DERR_RECREATE_TARGET) { releaseRenderer(); requestWallpaper(); } else check(result, "无法调整绘制表面。");
        }
    }
    view_.clamp(snapshot_.document); visibleItems_ = view_.visibleItems(snapshot_.document);
    layoutPanelControls(); syncAccessibility(); requestImages(); invalidate();
}
void Launcher::updateTheme() {
    theme_.update(preferences_); if (!window_) return;
    if (font_) DeleteObject(font_);
    font_ = CreateFontW(-static_cast<int>(14 * dpiScale_), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (editBrush_) DeleteObject(editBrush_);
    COLORREF background = theme_.highContrast ? GetSysColor(COLOR_WINDOW) : (theme_.dark ? RGB(45, 45, 48) : RGB(250, 250, 250));
    editBrush_ = CreateSolidBrush(background);
    BOOL dark = theme_.dark; DwmSetWindowAttribute(window_, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    SendMessageW(search_, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE);
    for (auto [id, handle] : controls_) { SendMessageW(handle, WM_SETFONT, reinterpret_cast<WPARAM>(font_), TRUE); SetWindowTheme(handle, theme_.dark ? L"DarkMode_Explorer" : L"Explorer", nullptr); }
    if (theme_.highContrast) wallpaper_.Reset(); invalidate();
}
void Launcher::invalidate() { if (window_ && visible_) InvalidateRect(window_, nullptr, FALSE); }
void Launcher::ensureRenderer() {
    if (!d2d_) check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf()), "无法初始化 Direct2D。");
    if (!dwrite_) check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite_.GetAddressOf())), "无法初始化 DirectWrite。");
    if (target_) return;
    RECT rect{}; GetClientRect(window_, &rect);
    auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_UNKNOWN, D2D1_ALPHA_MODE_IGNORE), 96 * dpiScale_, 96 * dpiScale_);
    check(d2d_->CreateHwndRenderTarget(props, D2D1::HwndRenderTargetProperties(window_, D2D1::SizeU(rect.right, rect.bottom)), &target_), "无法建立绘制表面。");
    ++rendererGeneration_;
    target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE); target_->CreateSolidColorBrush(color(0xffffff), &brush_);
}
void Launcher::releaseRenderer() { bitmaps_.clear(); wallpaper_.Reset(); requestedIcons_.clear(); brush_.Reset(); target_.Reset(); formats_.clear(); }
void Launcher::rectangle(Rect rect, D2D1_COLOR_F value, float radius, bool outline) {
    brush_->SetColor(value); auto r = drect(rect);
    if (radius > 0) { auto rounded = D2D1::RoundedRect(r, radius, radius); if (outline) target_->DrawRoundedRectangle(rounded, brush_.Get(), 1); else target_->FillRoundedRectangle(rounded, brush_.Get()); }
    else { if (outline) target_->DrawRectangle(r, brush_.Get(), 1); else target_->FillRectangle(r, brush_.Get()); }
}
void Launcher::text(const std::wstring& value, Rect rect, float size, D2D1_COLOR_F ink, bool center, bool bold, bool wrap) {
    auto key = std::make_pair(static_cast<int>(size * 10), bold); auto& format = formats_[key];
    if (!format) {
        dwrite_->CreateTextFormat(L"Segoe UI", nullptr, bold ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"zh-CN", &format);
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0}; ComPtr<IDWriteInlineObject> ellipsis; dwrite_->CreateEllipsisTrimmingSign(format.Get(), &ellipsis); format->SetTrimming(&trimming, ellipsis.Get());
    }
    format->SetTextAlignment(center ? DWRITE_TEXT_ALIGNMENT_CENTER : DWRITE_TEXT_ALIGNMENT_LEADING); format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    format->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
    brush_->SetColor(ink); target_->DrawText(value.c_str(), static_cast<UINT>(value.size()), format.Get(), drect(rect), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
}
void Launcher::drawIcon(const Bookmark& bookmark, Rect rect, float opacity) {
    auto found = bitmaps_.find(bookmark.url);
    ++paintedIcons_;
    float radius = rect.width * .22f;
    if (found != bitmaps_.end()) {
        ++paintedReadyIcons_; found->second.used = ++bitmapUse_;
        // 透明 favicon 使用与 macOS 相同的白色底板，图片铺满后统一裁圆角。
        rectangle(rect, color(0xffffff, .95f * opacity), radius);
        ComPtr<ID2D1RoundedRectangleGeometry> geometry; d2d_->CreateRoundedRectangleGeometry(D2D1::RoundedRect(drect(rect), radius, radius), &geometry);
        ComPtr<ID2D1Layer> layer; target_->CreateLayer(&layer); auto parameters = D2D1::LayerParameters(); parameters.geometricMask = geometry.Get();
        target_->PushLayer(parameters, layer.Get()); target_->DrawBitmap(found->second.bitmap.Get(), drect(rect), opacity); target_->PopLayer();
    } else {
        rectangle(rect, color(theme_.dark ? 0x41434c : 0xd7dce5, opacity), radius);
        auto title = wide(bookmark.title); if (!title.empty()) title.resize((title[0] >= 0xD800 && title[0] <= 0xDBFF && title.size() > 1) ? 2 : 1);
        text(title, rect, rect.width * .39f, color(theme_.dark ? 0xffffff : 0x354055, opacity), true, true);
    }
    rectangle(rect, color(theme_.dark ? 0xffffff : 0x000000, .12f * opacity), radius, true);
}
void Launcher::drawTile(const Item& item, Rect rect, int index, float opacity) {
    auto ink = theme_.highContrast ? systemColor(COLOR_WINDOWTEXT) : color(theme_.dark ? 0xffffff : 0x202020, .94f * opacity);
    bool selected = view_.selection == index, hovered = hover_ == index;
    if (selected || hovered) rectangle(rect, theme_.highContrast ? systemColor(COLOR_HIGHLIGHT) : color(theme_.dark ? 0xffffff : 0x000000, selected ? .12f : .065f), 8);
    if (selected) rectangle(rect, theme_.highContrast ? systemColor(COLOR_HIGHLIGHTTEXT) : color(theme_.dark ? 0x4cc2ff : 0x0067c0), 8, true);
    Rect icon{rect.x + 16, rect.y + 6, 72, 72};
    D2D1_MATRIX_3X2_F original; target_->GetTransform(&original);
    if (view_.organizing && item.id != "__add__" && !theme_.reducedMotion) {
        float rotation = static_cast<float>(std::sin(milliseconds() / 140 + index) * 1.5); target_->SetTransform(D2D1::Matrix3x2F::Rotation(rotation, D2D1::Point2F(icon.x + 36, icon.y + 36)) * original);
    }
    if (item.folder) {
        rectangle(icon, theme_.highContrast ? systemColor(COLOR_BTNFACE) : color(theme_.dark ? 0x626572 : 0xd8dce6, .55f), 12);
        auto children = snapshot_.document.items(item.id);
        for (size_t i = 0; i < std::min<size_t>(4, children.size()); ++i) if (auto b = snapshot_.document.bookmark(children[i].id)) drawIcon(*b, {icon.x + 14 + static_cast<float>(i % 2) * 25, icon.y + 14 + static_cast<float>(i / 2) * 25, 19, 19}, opacity);
        rectangle(icon, color(theme_.dark ? 0xffffff : 0x000000, .12f), 12, true);
    } else if (item.id == "__add__") {
        rectangle(icon, color(theme_.dark ? 0xffffff : 0x000000, .035f), 12); rectangle(icon, color(theme_.dark ? 0xffffff : 0x000000, .32f), 12, true); text(L"+", icon, 32, ink, true);
    } else if (auto b = snapshot_.document.bookmark(item.id)) drawIcon(*b, icon, opacity);
    target_->SetTransform(original);
    if (drag_.active && drag_.hover == item.id && item.id != drag_.source) {
        rectangle({icon.x - 4, icon.y - 4, 80, 80}, color(theme_.dark ? 0x4cc2ff : 0x0067c0), 15, true);
        if (!item.folder && !view_.folder && milliseconds() - drag_.hoverSince > 600) text(L"创建文件夹", {rect.x - 8, rect.y - 24, 120, 20}, 11, ink, true);
    }
    text(wide(item.title), {rect.x + 2, rect.y + 83, 100, 18}, 12, ink, true);
    if (view_.searching()) {
        auto b = snapshot_.document.bookmark(item.id); std::string name = "根目录";
        if (b && b->groupId) if (auto g = snapshot_.document.group(*b->groupId)) name = g->name;
        text(wide(name), {rect.x + 2, rect.y + 100, 100, 16}, 10.5f, color(theme_.dark ? 0xffffff : 0x000000, .6f), true);
    }
    if (view_.organizing && item.id != "__add__") {
        brush_->SetColor(theme_.highContrast ? systemColor(COLOR_BTNFACE) : color(0xe8e8ed));
        target_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(icon.x, icon.y), 11, 11), brush_.Get()); text(L"−", {icon.x - 11, icon.y - 12, 22, 22}, 18, color(0x36363b), true);
    }
}
void Launcher::paint() {
    PAINTSTRUCT paint{}; BeginPaint(window_, &paint); ScopeExit finish{[&] { EndPaint(window_, &paint); }};
    if (!visible_) return;
    ensureRenderer(); paintedIcons_ = paintedReadyIcons_ = 0; target_->BeginDraw(); target_->SetTransform(D2D1::Matrix3x2F::Identity());
    float w = view_.layout.width, h = view_.layout.height;
    auto ink = theme_.highContrast ? systemColor(COLOR_WINDOWTEXT) : color(theme_.dark ? 0xf2f2f2 : 0x202020);
    auto background = theme_.highContrast ? systemColor(COLOR_WINDOW) : color(theme_.dark ? 0x202024 : 0xf3f3f3);
    target_->Clear(background);
    if (wallpaper_ && !theme_.highContrast) {
        auto size = wallpaper_->GetSize(); float scale = std::max(w / size.width, h / size.height);
        target_->DrawBitmap(wallpaper_.Get(), D2D1::RectF((w - size.width * scale) / 2, (h - size.height * scale) / 2, (w + size.width * scale) / 2, (h + size.height * scale) / 2), 1, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
        rectangle({0, 0, w, h}, color(theme_.dark ? 0x1c1c20 : 0xf3f3f3, theme_.dark ? .64f : .76f));
    }
    float searchX = (w - 380) / 2;
    rectangle({searchX, 34, 380, 36}, theme_.highContrast ? systemColor(COLOR_WINDOW) : color(theme_.dark ? 0x2d2d30 : 0xfafafa), 4);
    rectangle({searchX, 34, 380, 36}, color(theme_.dark ? 0xffffff : 0x000000, .16f), 4, true);
    if (GetFocus() == search_) rectangle({searchX + 1, 68, 378, 2}, theme_.highContrast ? systemColor(COLOR_HIGHLIGHT) : color(theme_.dark ? 0x4cc2ff : 0x0067c0));
    brush_->SetColor(ink); target_->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(searchX + 17, 50), 5, 5), brush_.Get(), 1.4f); target_->DrawLine(D2D1::Point2F(searchX + 21, 54), D2D1::Point2F(searchX + 25, 58), brush_.Get(), 1.4f);
    if (!view_.query.empty()) text(L"×", {searchX + 343, 37, 30, 28}, 19, ink, true);
    if (view_.inFolder()) {
        rectangle({0, 82, w, h - 82}, theme_.highContrast ? background : color(theme_.dark ? 0x1c1c20 : 0xf3f3f3, .5f));
        auto bounds = view_.layout.folderBounds();
        if (auto group = snapshot_.document.group(*view_.folder)) text(wide(group->name), {bounds.x + 38, bounds.y + 10, bounds.width - 76, 36}, 24, ink, true, true);
        text(L"‹", {bounds.x, bounds.y + 11, 32, 32}, 30, ink, true);
    }
    float offset = 0, scale = 1;
    if (animationStart_ && !theme_.reducedMotion) {
        float t = std::clamp(static_cast<float>((milliseconds() - animationStart_) / 220), 0.0f, 1.0f), remaining = (1 - t) * (1 - t) * (1 - t);
        offset = animationDirection_ * 64 * remaining; if (!animationDirection_) scale = 1 - .08f * remaining;
    }
    target_->PushAxisAlignedClip(D2D1::RectF(0, 85, w, h - 24), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    target_->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale, D2D1::Point2F(w / 2, h / 2)) * D2D1::Matrix3x2F::Translation(offset, 0));
    for (size_t i = 0; i < visibleItems_.size(); ++i) drawTile(visibleItems_[i], view_.layout.tile(static_cast<int>(i), view_.inFolder()), static_cast<int>(i), drag_.active && drag_.source == visibleItems_[i].id ? .35f : 1);
    target_->SetTransform(D2D1::Matrix3x2F::Identity()); target_->PopAxisAlignedClip();
    if (visibleItems_.empty()) {
        std::wstring title = !loaded_ ? L"正在读取书签…" : (view_.searching() ? L"没有匹配的书签" : L"把常用网站放在这里");
        std::wstring hint = view_.searching() ? L"按 Enter 打开网址或使用 Google 搜索" : L"点击右上角 +，添加你的第一个书签";
        text(title, {40, h / 2 - 36, w - 80, 36}, 24, ink, true, true); text(hint, {40, h / 2 + 10, w - 80, 24}, 13, ink, true);
    }
    int count = view_.pageCount(snapshot_.document); float dotsY = view_.inFolder() ? view_.layout.folderBounds().y + view_.layout.folderBounds().height - 12 : h - 28;
    int firstDot = std::max(0, view_.page() - 12), lastDot = std::min(count, firstDot + 25);
    float start = w / 2 - (lastDot - firstDot - 1) * 9;
    for (int i = firstDot; i < lastDot; ++i) { brush_->SetColor(color(theme_.dark ? 0xffffff : 0x202020, i == view_.page() ? .95f : .3f)); target_->FillEllipse(D2D1::Ellipse(D2D1::Point2F(start + (i - firstDot) * 18, dotsY), i == view_.page() ? 4.0f : 3.0f, i == view_.page() ? 4.0f : 3.0f), brush_.Get()); }
    if (count > 1) { text(L"‹", {20, h / 2 - 24, 32, 48}, 32, ink, true); text(L"›", {w - 52, h / 2 - 24, 32, 48}, 32, ink, true); }
    if (view_.organizing) text(L"整理中 · 拖动调整位置 · 按 Esc 完成", {40, h - 63, w - 80, 24}, 12, ink, true);
    if (drag_.active) {
        Item item; if (auto b = snapshot_.document.bookmark(drag_.source)) item = {b->id, b->title}; else if (auto g = snapshot_.document.group(drag_.source)) item = {g->id, g->name, g->order, true};
        drawTile(item, {drag_.x - 52, drag_.y - 40, 104, 112}, -2, .92f);
    }
    if (panel_ != Panel::none) drawPanel();
    if (!status_.empty()) {
        float statusWidth = panel_ == Panel::none ? std::min(w - 40, 780.0f) : panelBounds().width - 56;
        float y = panel_ == Panel::none ? h - 108 : panelBounds().y + panelBounds().height - 111;
        rectangle({(w - statusWidth) / 2, y, statusWidth, 48}, theme_.highContrast ? systemColor(COLOR_INFOBK) : color(theme_.dark ? 0x35353b : 0xffffff, .98f), 8);
        text(wide(status_), {(w - statusWidth) / 2 + 8, y + 2, statusWidth - 16, 44}, 12, theme_.highContrast ? systemColor(COLOR_INFOTEXT) : ink, false, false, true);
    }
    auto result = target_->EndDraw();
    if (result == D2DERR_RECREATE_TARGET) { releaseRenderer(); requestImages(); requestWallpaper(); invalidate(); }
    else check(result, "界面绘制失败。");
    if (paintPending_ && loaded_ && SUCCEEDED(result)) {
        paintPending_ = false;
        diagnostics_.event(firstShow_ ? "first_interactive" : "reopened", {{"durationMs", milliseconds() - showStart_}, {"bookmarks", snapshot_.document.bookmarks.size()}, {"dpi", dpiScale_ * 96},
            {"rendererGeneration", rendererGeneration_}, {"iconsDrawn", paintedIcons_}, {"readyIconsDrawn", paintedReadyIcons_}, {"bitmapCount", bitmaps_.size()}}); firstShow_ = false;
    }
}
void Launcher::animate(int direction) {
    animationDirection_ = direction; animationStart_ = milliseconds();
    if (theme_.reducedMotion) { animationStart_ = 0; corners_.suppress(systemPanel_); invalidate(); return; }
    SetTimer(window_, timerAnimation, 16, nullptr); invalidate();
}
void Launcher::receivedImage(Images::Result result) {
    if (!visible_) return;
    diagnostics_.event("image_completed", {{"key", hash(result.url)}, {"request", result.request}, {"generation", result.generation},
        {"source", result.source == Images::Source::cache ? "cache" : (result.source == Images::Source::network ? "network" : "wallpaper")},
        {"loaded", result.pixels != nullptr}, {"deferred", result.deferred}, {"queueMs", result.queueMs}, {"loadMs", result.loadMs}, {"totalMs", result.totalMs}});
    if (result.deferred) { requestedIcons_.erase(result.url); SetTimer(controller_, timerImageRetry, 100, nullptr); return; }
    if (!result.pixels) return;
    auto& pixels = result.pixels; auto& url = result.url; ensureRenderer();
    ComPtr<ID2D1Bitmap> bitmap;
    if (FAILED(target_->CreateBitmap(D2D1::SizeU(pixels->width, pixels->height), pixels->bgra.data(), pixels->width * 4, D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)), &bitmap))) return;
    if (url == "__wallpaper__") { if (!theme_.highContrast) wallpaper_ = bitmap; }
    else {
        bitmaps_[url] = {bitmap, ++bitmapUse_};
        if (bitmaps_.size() > 128) {
            std::set<std::string> needed; for (auto b : visibleBookmarks()) needed.insert(b->url);
            auto oldest = std::min_element(bitmaps_.begin(), bitmaps_.end(), [&](const auto& a, const auto& b) {
                bool aNeeded = needed.contains(a.first), bNeeded = needed.contains(b.first);
                return aNeeded != bNeeded ? !aNeeded : a.second.used < b.second.used;
            });
            requestedIcons_.erase(oldest->first); bitmaps_.erase(oldest);
        }
    }
    invalidate();
}
std::vector<const Bookmark*> Launcher::visibleBookmarks() const {
    std::vector<const Bookmark*> bookmarks; std::set<std::string> seen;
    auto add = [&](const Bookmark* b) { if (b && seen.insert(b->url).second) bookmarks.push_back(b); };
    for (const auto& item : visibleItems_) {
        if (item.folder) { auto contents = snapshot_.document.items(item.id); for (size_t i = 0; i < std::min<size_t>(4, contents.size()); ++i) add(snapshot_.document.bookmark(contents[i].id)); }
        else add(snapshot_.document.bookmark(item.id));
    }
    return bookmarks;
}
void Launcher::requestImages() {
    if (!images_ || !visible_) return;
    UINT size = std::clamp(static_cast<UINT>(72 * dpiScale_), 32u, 192u);
    for (auto b : visibleBookmarks()) {
        auto bitmap = bitmaps_.find(b->url);
        if (bitmap != bitmaps_.end() && bitmap->second.bitmap->GetPixelSize().width >= size) continue;
        if (requestedIcons_.contains(b->url)) continue;
        if (auto request = images_->request(b->url, size)) requestedIcons_[b->url] = request;
        else SetTimer(controller_, timerImageRetry, 100, nullptr);
    }
}
void Launcher::requestWallpaper() {
    if (visible_ && !theme_.highContrast) if (auto request = images_->wallpaper(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST))) requestedIcons_["__wallpaper__"] = request;
}
void Launcher::loadInitial() {
    busy_ = true;
    auto directory = preferences_.dataDirectory; bool create = options_.isolated || sameFile(directory, localDirectory() / L"Data");
    bool initialize = options_.isolated || !fs::exists(localDirectory() / L"preferences.json");
    storageQueue_->post([this, directory, create, initialize] {
        try { auto snapshot = storage_.open(directory, create, {}, initialize); dispatch([this, snapshot = std::move(snapshot)]() mutable { busy_ = false; applySnapshot(std::move(snapshot)); diagnostics_.event("data_loaded", {{"bookmarks", snapshot_.document.bookmarks.size()}}); }); }
        catch (const std::exception& error) { dispatch([this, message = std::string(error.what())] { busy_ = false; notify(message + " 已保留原文件，请在设置中重试读取或选择目录。", true); diagnostics_.event("load_failed", {{"message", message}}); }); }
    });
}
void Launcher::reload() {
    if (busy_) { reloadPending_ = true; return; }
    if (!loaded_) { loadInitial(); return; }
    busy_ = true;
    storageQueue_->post([this] {
        try { auto snapshot = storage_.reload(); dispatch([this, snapshot = std::move(snapshot)]() mutable {
            busy_ = false;
            if (!watcher_.running()) watcher_.start(snapshot.directory, [this] { PostMessageW(controller_, wmDirectory, 0, 0); });
            if (snapshot.bytes != snapshot_.bytes) { cancelDrag(); applySnapshot(std::move(snapshot)); notify("已读取外部更新，未提交的输入已保留。", panel_ != Panel::none); diagnostics_.event("external_updated"); }
            else if (statusPersistent_ && status_.find("读取") != std::string::npos) { status_.clear(); statusPersistent_ = false; invalidate(); }
            if (reloadPending_) { reloadPending_ = false; reload(); }
        }); }
        catch (const std::exception& error) { dispatch([this, message = std::string(error.what())] { busy_ = false; reloadPending_ = false; notify(message + " 当前数据与草稿已保留，请恢复文件后重试读取。", true); }); }
    });
}
void Launcher::applySnapshot(Snapshot snapshot) {
    bool directoryChanged = snapshot_.directory != snapshot.directory;
    snapshot_ = std::move(snapshot); loaded_ = true;
    if (directoryChanged) watcher_.start(snapshot_.directory, [this] { PostMessageW(controller_, wmDirectory, 0, 0); });
    view_.clamp(snapshot_.document); updateLayout();
}
void Launcher::mutate(std::function<void(Document&)> mutation, std::function<void()> success, std::string expected, std::function<void()> failure) {
    require(loaded_, "数据尚未成功读取，请先到设置中恢复数据目录。"); require(!busy_, "正在处理数据，请稍后重试。");
    auto next = snapshot_.document; mutation(next); next.validate();
    if (expected.empty()) expected = snapshot_.bytes; busy_ = true; invalidate();
    storageQueue_->post([this, next = std::move(next), expected = std::move(expected), success = std::move(success), failure = std::move(failure)]() mutable {
        try { auto saved = storage_.save(next, expected); dispatch([this, saved = std::move(saved), success = std::move(success)]() mutable {
            busy_ = false; applySnapshot(std::move(saved)); status_.clear(); if (success) success(); diagnostics_.event("saved");
            if (reloadPending_) { reloadPending_ = false; reload(); }
        }); }
        catch (const Conflict& error) {
            std::optional<Snapshot> current; try { current = storage_.reload(); } catch (const std::exception&) {}
            dispatch([this, current = std::move(current), message = std::string(error.what()), failure]() mutable {
                busy_ = false; if (current) applySnapshot(std::move(*current)); draft_.expected = snapshot_.bytes; renameExpected_ = snapshot_.bytes;
                if (failure) failure();
                notify(message, true); diagnostics_.event("save_conflict");
            });
        } catch (const std::exception& error) { dispatch([this, message = std::string(error.what()), failure] { busy_ = false; if (failure) failure(); notify(message + " 当前内容与草稿已保留。", true); diagnostics_.event("save_failed", {{"message", message}}); }); }
    });
}
void Launcher::notify(const std::string& value, bool persistent) {
    status_ = value; statusPersistent_ = persistent;
    if (window_) { KillTimer(window_, timerStatus); if (!persistent && visible_) SetTimer(window_, timerStatus, 4200, nullptr); }
    invalidate();
}
void Launcher::tray(bool add) {
    if (!controller_) return;
    NOTIFYICONDATAW data{sizeof(data)}; data.hWnd = controller_; data.uID = 1; data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    data.uCallbackMessage = wmTray; data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101)); wcscpy_s(data.szTip, L"青蛙导航 · 书签启动台");
    Shell_NotifyIconW(add ? NIM_ADD : NIM_DELETE, &data);
    if (add) { data.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &data); }
}
void Launcher::trayMenu() {
    HMENU menu = CreatePopupMenu(); ScopeExit cleanup{[&] { DestroyMenu(menu); }};
    AppendMenuW(menu, MF_STRING, 1, visible_ ? L"收起" : L"展开"); AppendMenuW(menu, MF_STRING, 2, L"设置…"); AppendMenuW(menu, MF_SEPARATOR, 0, nullptr); AppendMenuW(menu, MF_STRING, 3, L"退出青蛙导航");
    POINT point{}; GetCursorPos(&point); inMenu_ = true; SetForegroundWindow(controller_);
    UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, controller_, nullptr); inMenu_ = false; PostMessageW(controller_, WM_NULL, 0, 0);
    if (command == 1) { if (visible_) hide(); else show(); } else if (command == 2) show(true); else if (command == 3) quit();
}
void Launcher::menu(const std::string& id, POINT point) {
    if (panel_ != Panel::none) return;
    auto b = snapshot_.document.bookmark(id); auto g = snapshot_.document.group(id); if (!b && !g) return;
    HMENU popup = CreatePopupMenu(); ScopeExit cleanup{[&] { DestroyMenu(popup); }}; std::map<UINT, Location> locations;
    AppendMenuW(popup, MF_STRING, 1, L"打开");
    if (b) {
        AppendMenuW(popup, MF_STRING, 2, L"复制网址"); AppendMenuW(popup, MF_STRING, 3, L"编辑…"); AppendMenuW(popup, MF_STRING, 4, L"刷新图标");
        HMENU move = CreatePopupMenu(); UINT command = 100;
        if (b->groupId) { locations[command] = {}; AppendMenuW(move, MF_STRING, command++, L"根目录"); }
        for (const auto& group : snapshot_.document.groups) if (b->groupId != Location(group.id)) { locations[command] = group.id; AppendMenuW(move, MF_STRING, command++, wide(group.name).c_str()); }
        if (locations.empty()) AppendMenuW(move, MF_GRAYED, 0, L"无其他文件夹");
        AppendMenuW(popup, MF_POPUP, reinterpret_cast<UINT_PTR>(move), L"移动位置");
    } else AppendMenuW(popup, MF_STRING, 3, L"重命名…");
    AppendMenuW(popup, MF_STRING, 5, L"整理位置"); AppendMenuW(popup, MF_SEPARATOR, 0, nullptr); AppendMenuW(popup, MF_STRING, 6, L"删除…");
    inMenu_ = true; corners_.suppress(true); UINT action = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window_, nullptr); inMenu_ = false; corners_.suppress(false);
    b = snapshot_.document.bookmark(id); g = snapshot_.document.group(id);
    if (action == 1) activate(id);
    else if (action == 2 && b) { copyText(window_, wide(b->url)); notify("网址已复制。"); }
    else if (action == 3) { if (b) edit(id); else if (g) rename(id); }
    else if (action == 4 && b) {
        if (auto request = images_->request(b->url, static_cast<UINT>(72 * dpiScale_), true)) {
            requestedIcons_[b->url] = request; notify(options_.offline ? "离线模式下保留当前图标。" : "正在后台刷新图标，失败时保留原图标。");
        } else notify("图标队列繁忙，请稍后刷新。");
    }
    else if (action == 5) { view_.organizing = true; animate(); }
    else if (action == 6) remove(id);
    else if (locations.contains(action)) mutate([=](Document& data) { data.move(id, locations.at(action)); });
}
void Launcher::activate(const std::string& id) {
    if (id == "__add__") edit();
    else if (snapshot_.document.group(id)) openFolder(id);
    else if (auto b = snapshot_.document.bookmark(id)) { if (view_.organizing) edit(id); else open(b->url); }
}
void Launcher::open(const std::string& url) { if (openUrl(url)) hide(); else notify("无法交给默认浏览器，请检查网址及默认浏览器设置。", true); }
void Launcher::remove(const std::string& id) {
    if (snapshot_.document.group(id) && !snapshot_.document.items(id).empty()) { notify("请先移出或删除文件夹内的书签，再删除文件夹。"); return; }
    auto expected = snapshot_.bytes; systemPanel_ = true; corners_.suppress(true);
    int result = MessageBoxW(window_, L"确认删除这个条目？此操作会写入当前书签文件。", L"删除确认", MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2);
    systemPanel_ = false; corners_.suppress(false); if (result == IDOK) mutate([id](Document& data) { data.remove(id); }, {}, expected);
}
void Launcher::turn(int delta) {
    if (panel_ != Panel::none) return; int old = view_.page(); view_.turn(snapshot_.document, delta);
    if (old != view_.page()) { hover_ = -1; updateLayout(); animate(delta); savePage(); }
}
void Launcher::openFolder(const std::string& id) { view_.folder = id; view_.folderPage = 0; view_.selection = -1; updateLayout(); animate(); }
void Launcher::focusSearch() { if (panel_ != Panel::none) return; SetFocus(search_); SendMessageW(search_, EM_SETSEL, 0, -1); }
void Launcher::escape() {
    if (drag_.active || !drag_.source.empty()) { cancelDrag(); return; }
    if (hotkeyCapture_) { hotkeyCapture_ = false; refreshSettings(); return; }
    if (panel_ != Panel::none) { if (!busy_) closePanel(); return; }
    if (view_.organizing) { view_.organizing = false; KillTimer(window_, timerAnimation); invalidate(); return; }
    if (view_.inFolder()) { view_.folder.reset(); updateLayout(); animate(); return; }
    if (!view_.query.empty()) { SetWindowTextW(search_, L""); return; }
    hide();
}
bool Launcher::keyboard(WPARAM key, bool control, bool shift) {
    if (composing_ || key == VK_PROCESSKEY || key == VK_PACKET) return false;
    if ((GetKeyState(VK_MENU) & 0x8000) && key == VK_F4) { hide(); return true; }
    if (hotkeyCapture_) {
        if (key == VK_ESCAPE) { hotkeyCapture_ = false; refreshSettings(); return true; }
        if (key == VK_CONTROL || key == VK_MENU || key == VK_SHIFT || key == VK_LWIN || key == VK_RWIN) return true;
        auto prefs = preferences_; prefs.hotkey = {true, static_cast<UINT>((control ? MOD_CONTROL : 0) | (shift ? MOD_SHIFT : 0) | ((GetKeyState(VK_MENU) & 0x8000) ? MOD_ALT : 0) | (((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) ? MOD_WIN : 0)), static_cast<UINT>(key)};
        try { updatePreferences(prefs); hotkeyCapture_ = false; } catch (const std::exception& error) { notify(error.what(), true); }
        refreshSettings(); return true;
    }
    if (key == VK_ESCAPE) { escape(); return true; }
    if (panel_ != Panel::none) {
        if (key == VK_RETURN && !busy_ && (panel_ == Panel::bookmark || panel_ == Panel::rename)) {
            wchar_t name[40]{}; GetClassNameW(GetFocus(), name, 40);
            if (_wcsicmp(name, L"EDIT") == 0) { saveDraft(); return true; }
        }
        return false;
    }
    if (control && key == 'N') { edit(); return true; }
    if (control && key == VK_OEM_COMMA) { settings(); return true; }
    if ((control && key == 'F') || (key == VK_OEM_2 && !shift && GetFocus() != search_)) { focusSearch(); return true; }
    if (key == VK_PRIOR || key == VK_NEXT) { turn(key == VK_PRIOR ? -1 : 1); return true; }
    if (key == VK_LEFT || key == VK_RIGHT || key == VK_UP || key == VK_DOWN) {
        if (GetFocus() == search_ && (key == VK_LEFT || key == VK_RIGHT)) return false;
        int columns = view_.inFolder() ? std::min(4, view_.layout.columns()) : view_.layout.columns();
        int delta = key == VK_LEFT ? -1 : (key == VK_RIGHT ? 1 : (key == VK_UP ? -columns : columns));
        view_.select(snapshot_.document, delta); SetFocus(window_); updateLayout(); return true;
    }
    if (key == VK_RETURN) {
        if (GetFocus() == settingsButton_ || GetFocus() == addButton_) return false;
        if (!visibleItems_.empty()) activate(visibleItems_[view_.selection < 0 ? 0 : view_.selection].id);
        else if (!trim(view_.query).empty()) open(searchUrl(view_.query)); return true;
    }
    if (key == VK_F2 && view_.selection >= 0) { auto item = visibleItems_[view_.selection]; if (item.folder) rename(item.id); else if (item.id != "__add__") edit(item.id); return true; }
    if (key == VK_DELETE && GetFocus() != search_ && view_.selection >= 0) { remove(visibleItems_[view_.selection].id); return true; }
    if (key == VK_APPS || (shift && key == VK_F10)) {
        if (view_.selection >= 0) { auto rect = view_.layout.tile(view_.selection, view_.inFolder()); POINT point{static_cast<LONG>((rect.x + 52) * dpiScale_), static_cast<LONG>((rect.y + 52) * dpiScale_)}; ClientToScreen(window_, &point); menu(visibleItems_[view_.selection].id, point); } return true;
    }
    return false;
}
int Launcher::hitTile(float x, float y) const { for (size_t i = 0; i < visibleItems_.size(); ++i) if (view_.layout.tile(static_cast<int>(i), view_.inFolder()).contains(x, y)) return static_cast<int>(i); return -1; }
void Launcher::pointerDown(float x, float y) {
    if (panel_ != Panel::none) return;
    int index = hitTile(x, y);
    if (index >= 0) {
        auto item = visibleItems_[index]; auto rect = view_.layout.tile(index, view_.inFolder()); view_.selection = index;
        if (view_.organizing && x < rect.x + 30 && y < rect.y + 20 && item.id != "__add__") { remove(item.id); return; }
        if (item.id != "__add__" && !view_.searching() && !busy_) {
            drag_ = {}; drag_.source = item.id; drag_.x = drag_.startX = x; drag_.y = drag_.startY = y; drag_.originalFolder = view_.folder; drag_.originalPage = view_.page(); dragExpected_ = snapshot_.bytes;
            SetCapture(window_); SetTimer(window_, timerLongPress, 520, nullptr);
        }
        SetFocus(window_); invalidate(); return;
    }
}
void Launcher::pointerMove(float x, float y) {
    if (panel_ != Panel::none) return;
    hover_ = hitTile(x, y);
    if (!drag_.source.empty()) {
        drag_.x = x; drag_.y = y;
        if (!drag_.active && std::hypot(x - drag_.startX, y - drag_.startY) > 7) {
            drag_.active = true; KillTimer(window_, timerLongPress); SetTimer(window_, timerDrag, 30, nullptr); corners_.suppress(true); diagnostics_.event("drag_started");
        }
        if (drag_.active) {
            std::string target = hover_ >= 0 ? visibleItems_[hover_].id : "";
            if (target != drag_.hover) { drag_.hover = target; drag_.hoverSince = milliseconds(); }
            if (view_.inFolder() && !view_.layout.folderBounds().contains(x, y)) {
                view_.folder.reset(); view_.selection = -1; drag_.hover.clear(); updateLayout(); animate();
            }
            float left = view_.inFolder() ? view_.layout.folderBounds().x : 0, right = view_.inFolder() ? left + view_.layout.folderBounds().width : view_.layout.width;
            int edge = x < left + 42 ? -1 : (x > right - 42 ? 1 : 0);
            if (edge != drag_.edge) { drag_.edge = edge; drag_.edgeSince = milliseconds(); }
        }
    }
    TRACKMOUSEEVENT tracking{sizeof(tracking), TME_LEAVE, window_, 0}; TrackMouseEvent(&tracking); invalidate();
}
void Launcher::dragTick() {
    if (!drag_.active) return;
    double now = milliseconds();
    if (drag_.edge && now - drag_.edgeSince >= 620) { turn(drag_.edge); drag_.edgeSince = now; drag_.hover.clear(); }
    if (!drag_.hover.empty() && drag_.hover != drag_.source && now - drag_.hoverSince >= 650 && snapshot_.document.bookmark(drag_.source) && snapshot_.document.group(drag_.hover)) {
        auto target = drag_.hover; drag_.hover.clear(); openFolder(target);
    }
    invalidate();
}
void Launcher::pointerUp(float x, float y) {
    if (panel_ != Panel::none) return;
    KillTimer(window_, timerLongPress); KillTimer(window_, timerDrag);
    auto drag = drag_; auto expected = dragExpected_; drag_ = {}; if (GetCapture() == window_) ReleaseCapture(); corners_.suppress(false);
    int index = hitTile(x, y);
    if (drag.active) {
        auto rollback = [this, drag] { view_.folder = drag.originalFolder; view_.page() = drag.originalPage; updateLayout(); };
        if (x < 0 || x > view_.layout.width || y < 85 || y > view_.layout.height) { rollback(); diagnostics_.event("drag_cancelled"); return; }
        auto target = index >= 0 ? visibleItems_[index].id : std::string{};
        if (target == "__add__") target.clear();
        auto location = view_.folder; bool merge = !location && !target.empty() && target == drag.hover && milliseconds() - drag.hoverSince >= 650 && snapshot_.document.bookmark(target) && snapshot_.document.bookmark(drag.source);
        try {
            if (merge) {
                auto group = std::make_shared<std::string>(); mutate([=](Document& data) { *group = data.merge(drag.source, target); }, [this, group] { openFolder(*group); }, expected, rollback);
            } else if (!target.empty() && snapshot_.document.group(target) && snapshot_.document.bookmark(drag.source)) mutate([=](Document& data) { data.move(drag.source, target); }, {}, expected, rollback);
            else mutate([=](Document& data) { data.move(drag.source, location, target); }, {}, expected, rollback);
            diagnostics_.event("drag_dropped");
        } catch (...) { view_.folder = drag.originalFolder; view_.page() = drag.originalPage; updateLayout(); throw; }
        invalidate(); return;
    }
    if (drag.held) { invalidate(); return; }
    if (index >= 0) { if (drag.source.empty() || visibleItems_[index].id == drag.source) activate(visibleItems_[index].id); return; }
    float w = view_.layout.width, h = view_.layout.height, sx = (w - 380) / 2;
    if (Rect{sx + 340, 34, 38, 36}.contains(x, y)) { SetWindowTextW(search_, L""); SetFocus(search_); return; }
    if (Rect{sx, 34, 380, 36}.contains(x, y)) { SetFocus(search_); return; }
    if (view_.pageCount(snapshot_.document) > 1) { if (x < 60 && y > 85) { turn(-1); return; } if (x > w - 60 && y > 85) { turn(1); return; } }
    int count = view_.pageCount(snapshot_.document); float dy = view_.inFolder() ? view_.layout.folderBounds().y + view_.layout.folderBounds().height - 12 : h - 28;
    if (std::abs(y - dy) < 14) {
        int first = std::max(0, view_.page() - 12), last = std::min(count, first + 25); float start = w / 2 - (last - first - 1) * 9;
        int page = first + static_cast<int>(std::round((x - start) / 18)); if (page >= first && page < last) { turn(page - view_.page()); return; }
    }
    if (view_.inFolder()) { auto r = view_.layout.folderBounds(); if (Rect{r.x + 38, r.y, r.width - 76, 58}.contains(x, y)) rename(*view_.folder); else if (!r.contains(x, y) || x < r.x + 36) { view_.folder.reset(); updateLayout(); animate(); } return; }
    if (y >= 85) { if (view_.organizing) { view_.organizing = false; invalidate(); } else hide(); }
}
void Launcher::cancelDrag() {
    KillTimer(window_, timerLongPress); KillTimer(window_, timerDrag); bool active = drag_.active;
    drag_.cancel(view_); if (GetCapture() == window_) ReleaseCapture(); corners_.suppress(systemPanel_);
    if (active) { updateLayout(); diagnostics_.event("drag_cancelled"); } invalidate();
}
void Launcher::savePage() { preferences_.page = view_.rootPage; try { preferences_.save(options_); } catch (const std::exception& error) { notify(error.what(), true); } }
LRESULT CALLBACK Launcher::controlProc(HWND window, UINT message, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR ref) {
    auto* self = reinterpret_cast<Launcher*>(ref);
    if (message == WM_IME_STARTCOMPOSITION) self->composing_ = true;
    if (message == WM_IME_ENDCOMPOSITION) self->composing_ = false;
    if (message == WM_NCDESTROY) RemoveWindowSubclass(window, controlProc, 1);
    return DefSubclassProc(window, message, w, l);
}
LRESULT CALLBACK Launcher::windowProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    auto* self = reinterpret_cast<Launcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) { self = static_cast<Launcher*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self)); self->window_ = window; }
    if (self) try { return self->message(message, w, l); } catch (const std::exception& error) { self->notify(error.what(), true); return 0; }
    return DefWindowProcW(window, message, w, l);
}
LRESULT Launcher::message(UINT message, WPARAM w, LPARAM l) {
    switch (message) {
    case WM_PAINT: paint(); return 0;
    case WM_ERASEBKGND: return 1;
    case WM_CLOSE: hide(); return 0;
    case WM_SYSCOMMAND: if ((w & 0xfff0) == SC_MINIMIZE || (w & 0xfff0) == SC_CLOSE) { hide(); return 0; } break;
    case WM_ACTIVATE: if (LOWORD(w) == WA_INACTIVE && visible_ && !systemPanel_ && !inMenu_ && !sameProcess(reinterpret_cast<HWND>(l))) hide(); return 0;
    case WM_SIZE: if (w == SIZE_MINIMIZED) hide(); else updateLayout(); return 0;
    case WM_DPICHANGED: dpiScale_ = HIWORD(w) / 96.0f; releaseRenderer(); updateTheme(); place(false); requestWallpaper(); return 0;
    case WM_DISPLAYCHANGE: if (visible_) { place(false); requestWallpaper(); } return 0;
    case WM_SETTINGCHANGE: case WM_THEMECHANGED: updateTheme(); if (visible_) { place(false); requestWallpaper(); } return 0;
    case WM_COMMAND:
        if (LOWORD(w) == 10 && HIWORD(w) == EN_CHANGE) { view_.query = utf8(windowText(search_)); view_.searchPage = 0; view_.selection = -1; view_.organizing = false; updateLayout(); }
        else if (LOWORD(w) == 11) settings(); else if (LOWORD(w) == 12) edit(); else panelCommand(LOWORD(w), HIWORD(w)); return 0;
    case WM_CTLCOLOREDIT: case WM_CTLCOLORSTATIC: case WM_CTLCOLORBTN: {
        auto dc = reinterpret_cast<HDC>(w); COLORREF ink = theme_.highContrast ? GetSysColor(COLOR_WINDOWTEXT) : (theme_.dark ? RGB(242, 242, 242) : RGB(32, 32, 32));
        SetTextColor(dc, ink); SetBkColor(dc, theme_.highContrast ? GetSysColor(COLOR_WINDOW) : (theme_.dark ? RGB(45, 45, 48) : RGB(250, 250, 250))); return reinterpret_cast<LRESULT>(editBrush_);
    }
    case WM_DRAWITEM: {
        auto* draw = reinterpret_cast<DRAWITEMSTRUCT*>(l); if (draw->CtlID != 11 && draw->CtlID != 12) break;
        FillRect(draw->hDC, &draw->rcItem, editBrush_); SetBkMode(draw->hDC, TRANSPARENT); SetTextColor(draw->hDC, theme_.highContrast ? GetSysColor(COLOR_WINDOWTEXT) : (theme_.dark ? RGB(220, 220, 225) : RGB(45, 45, 45)));
        HFONT symbol = CreateFontW(-static_cast<int>(19 * dpiScale_), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe MDL2 Assets"); auto old = SelectObject(draw->hDC, symbol);
        DrawTextW(draw->hDC, draw->CtlID == 11 ? L"\uE713" : L"\uE710", 1, &draw->rcItem, DT_CENTER | DT_VCENTER | DT_SINGLELINE); SelectObject(draw->hDC, old); DeleteObject(symbol);
        if (draw->itemState & ODS_FOCUS) DrawFocusRect(draw->hDC, &draw->rcItem); return TRUE;
    }
    case WM_LBUTTONDOWN: pointerDown(GET_X_LPARAM(l) / dpiScale_, GET_Y_LPARAM(l) / dpiScale_); return 0;
    case WM_MOUSEMOVE: pointerMove(GET_X_LPARAM(l) / dpiScale_, GET_Y_LPARAM(l) / dpiScale_); return 0;
    case WM_LBUTTONUP: pointerUp(GET_X_LPARAM(l) / dpiScale_, GET_Y_LPARAM(l) / dpiScale_); return 0;
    case WM_MOUSELEAVE: hover_ = -1; invalidate(); return 0;
    case WM_CAPTURECHANGED: if (!drag_.source.empty()) cancelDrag(); return 0;
    case WM_CONTEXTMENU: { POINT point{GET_X_LPARAM(l), GET_Y_LPARAM(l)}; if (point.x == -1) { keyboard(VK_APPS, false, false); return 0; } POINT client = point; ScreenToClient(window_, &client); int index = hitTile(client.x / dpiScale_, client.y / dpiScale_); if (index >= 0) menu(visibleItems_[index].id, point); return 0; }
    case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL:
        if (panel_ == Panel::none) { wheel_ += GET_WHEEL_DELTA_WPARAM(w) * (message == WM_MOUSEWHEEL ? -1 : 1); if (std::abs(wheel_) >= WHEEL_DELTA) { turn(wheel_ > 0 ? 1 : -1); wheel_ = 0; } } return 0;
    case WM_TIMER:
        if (w == timerAnimation) { if (milliseconds() - animationStart_ > 240) { animationStart_ = 0; corners_.suppress(systemPanel_ || drag_.active); if (!view_.organizing || theme_.reducedMotion) KillTimer(window_, timerAnimation); } invalidate(); }
        else if (w == timerLongPress) { KillTimer(window_, timerLongPress); if (!drag_.source.empty() && !drag_.active) { drag_.held = true; view_.organizing = true; animate(); } }
        else if (w == timerDrag) dragTick(); else if (w == timerStatus) { KillTimer(window_, timerStatus); if (!statusPersistent_) status_.clear(); invalidate(); } return 0;
    case WM_GETOBJECT: if (static_cast<LONG>(l) == UiaRootObjectId && provider_) return UiaReturnRawElementProvider(window_, w, l, provider_.Get()); break;
    case wmAccessibleInvoke: accessibleAction(static_cast<int>(w), l != 0); return 0;
    case WM_GETDLGCODE: return DLGC_WANTARROWS | DLGC_WANTCHARS;
    case WM_CHAR: if (panel_ == Panel::none && w >= 32 && w != 127 && GetFocus() == window_) { SetFocus(search_); SendMessageW(search_, WM_CHAR, w, l); } return 0;
    case WM_SETFOCUS: invalidate(); return 0;
    }
    return DefWindowProcW(window_, message, w, l);
}
}
