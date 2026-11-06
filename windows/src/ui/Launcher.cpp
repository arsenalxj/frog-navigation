#include "Launcher.h"
#include "core/Calculator.h"
#include <shellapi.h>
#include <windowsx.h>
#include <commctrl.h>
#include <imm.h>
#include <algorithm>
#include <cmath>
#include <cwctype>

namespace frog {
namespace {
constexpr UINT timerReload = 5, timerCalcFeedback = 6;
constexpr UINT32 paper = 0xfffef8, surface = 0xf8f4ed, line = 0xe4dfd7, ink = 0x0f1a20,
    muted = 0x695e45, green = 0x0d5e3a, purple = 0x7e1671, teal = 0x126e82,
    red = 0x7c1823, yellow = 0xe6c24d, mint = 0xadd5a2, forest = 0x1a3b2e;
D2D1_RECT_F drect(Rect r) { return D2D1::RectF(r.x, r.y, r.x + r.width, r.y + r.height); }
bool sameProcess(HWND window) { DWORD pid{}; if (window) GetWindowThreadProcessId(window, &pid); return pid == GetCurrentProcessId(); }
std::string host(const std::string& url) {
    auto start = url.find("://"); start = start == std::string::npos ? 0 : start + 3;
    auto result = url.substr(start, url.find_first_of("/?#", start) - start);
    if (result.starts_with("www.")) result.erase(0, 4);
    return result;
}
std::string clockText() { SYSTEMTIME t{}; GetLocalTime(&t); char value[16]{}; sprintf_s(value, "%02u:%02u:%02u", t.wHour, t.wMinute, t.wSecond); return value; }
const char* bufferName(TerminalBuffer buffer) {
    switch (buffer) {
    case TerminalBuffer::settings: return "settings"; case TerminalBuffer::help: return "help";
    case TerminalBuffer::log: return "log"; case TerminalBuffer::job: return "job";
    case TerminalBuffer::calc: return "calc"; default: return "";
    }
}
}
Launcher::Launcher(Options options, Instance& instance)
    : options_(std::move(options)), instance_(instance), diagnostics_(options_.diagnostics), storageQueue_(std::make_unique<SerialQueue>()) {
    preferences_ = Preferences::load(options_);
    expanded_.insert(preferences_.expandedGroupIDs.begin(), preferences_.expandedGroupIDs.end());
    WNDCLASSEXW cls{sizeof(cls)}; cls.hInstance = GetModuleHandleW(nullptr); cls.lpfnWndProc = controllerProc; cls.lpszClassName = L"FrogController";
    RegisterClassExW(&cls);
    controller_ = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, instance_.windowTitle().c_str(), WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, cls.hInstance, this);
    require(controller_ != nullptr, winError("无法创建应用控制器"));
    taskbarCreated_ = RegisterWindowMessageW(L"TaskbarCreated"); instance_.listen(controller_);
    try { hotkey_.set(controller_, preferences_.hotkey); } catch (const std::exception& e) { hotkeyError_ = e.what(); appendLog(hotkeyError_, red); }
    try { corners_.configure(controller_, preferences_.cornersEnabled, preferences_.corners); } catch (const std::exception& e) { settingErrors_["corner"] = e.what(); appendLog(e.what(), red); }
    tray(true); diagnostics_.event("process_started", {{"isolated", options_.isolated}, {"background", options_.background}, {"interface", "terminal"}});
    loadInitial();
}
Launcher::~Launcher() {
    watcher_.stop(); storageQueue_.reset();
    MSG msg{}; while (PeekMessageW(&msg, controller_, wmDispatch, wmDispatch, PM_REMOVE)) delete reinterpret_cast<std::function<void()>*>(msg.lParam);
    { std::lock_guard lock(accessibility_->mutex); accessibility_->window = nullptr; accessibility_->nodes.clear(); }
    if (provider_) UiaDisconnectProvider(provider_.Get()); provider_.Reset();
    corners_.configure(controller_, false, 0);
    tray(false); if (window_) DestroyWindow(window_); if (controller_) DestroyWindow(controller_);
    if (font_) DeleteObject(font_); if (editBrush_) DeleteObject(editBrush_);
}
int Launcher::run() {
    if (!options_.background) show();
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    return static_cast<int>(msg.wParam);
}
void Launcher::dispatch(std::function<void()> action) {
    auto* task = new std::function<void()>(std::move(action));
    if (!PostMessageW(controller_, wmDispatch, 0, reinterpret_cast<LPARAM>(task))) delete task;
}
LRESULT CALLBACK Launcher::controllerProc(HWND window, UINT msg, WPARAM w, LPARAM l) {
    auto* self = reinterpret_cast<Launcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (msg == WM_NCCREATE) { self = static_cast<Launcher*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self)); self->controller_ = window; }
    if (self) try { return self->controllerMessage(msg, w, l); } catch (const std::exception& e) { self->notify(e.what(), true); return 0; }
    return DefWindowProcW(window, msg, w, l);
}
LRESULT Launcher::controllerMessage(UINT msg, WPARAM w, LPARAM l) {
    if (taskbarCreated_ && msg == taskbarCreated_) { tray(true); return 0; }
    switch (msg) {
    case wmDispatch: { std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(l)); if (!quitting_) (*task)(); return 0; }
    case wmActivate: show(); return 0;
    case WM_HOTKEY: if (visible_) hide(); else show(); return 0;
    case wmCorner: if (!visible_) show(); return 0;
    case wmDirectory: if (!quitting_) SetTimer(controller_, timerReload, 180, nullptr); return 0;
    case WM_TIMER: if (w == timerReload) { KillTimer(controller_, timerReload); reload(); } return 0;
    case wmTray:
        if (LOWORD(l) == WM_CONTEXTMENU || LOWORD(l) == WM_RBUTTONUP) trayMenu();
        else if (LOWORD(l) == NIN_SELECT || LOWORD(l) == NIN_KEYSELECT) { if (visible_) hide(); else show(); } return 0;
    case WM_POWERBROADCAST: if (w == PBT_APMRESUMEAUTOMATIC || w == PBT_APMRESUMESUSPEND) { reload(); if (visible_) place(false); } return TRUE;
    case WM_QUERYENDSESSION: return TRUE;
    case WM_ENDSESSION: if (w) quit(); return 0;
    }
    return DefWindowProcW(controller_, msg, w, l);
}
void Launcher::createWindow() {
    if (window_) return;
    WNDCLASSEXW cls{sizeof(cls)}; cls.hInstance = GetModuleHandleW(nullptr); cls.lpfnWndProc = windowProc; cls.lpszClassName = L"FrogLauncher"; cls.hCursor = LoadCursorW(nullptr, IDC_ARROW); cls.style = CS_DBLCLKS;
    cls.hIcon = LoadIconW(cls.hInstance, MAKEINTRESOURCEW(101)); cls.hIconSm = cls.hIcon; RegisterClassExW(&cls);
    window_ = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"青蛙导航 · 回声终端", WS_POPUP | WS_CLIPCHILDREN, 0, 0, 1440, 900, controller_, nullptr, cls.hInstance, this);
    require(window_ != nullptr, winError("无法创建终端窗口"));
    search_ = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, window_, reinterpret_cast<HMENU>(10), cls.hInstance, nullptr);
    require(search_ != nullptr, winError("无法创建命令行输入"));
    SendMessageW(search_, EM_SETLIMITTEXT, 32767, 0); accessibleName(search_, L"命令行输入");
    SetWindowSubclass(search_, controlProc, 1, reinterpret_cast<DWORD_PTR>(this));
    editBrush_ = CreateSolidBrush(RGB(255, 254, 248));
    tooltip_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, window_, nullptr, cls.hInstance, nullptr);
    if (tooltip_) {
        TOOLINFOW tool{sizeof(tool)}; tool.uFlags = TTF_TRACK | TTF_ABSOLUTE; tool.hwnd = window_; tool.uId = 1; tool.lpszText = const_cast<wchar_t*>(L"");
        SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool)); SendMessageW(tooltip_, TTM_SETMAXTIPWIDTH, 0, 1100);
    }
    provider_.Attach(createAccessibility(accessibility_)); accessibility_->window = window_;
}
void Launcher::show(bool settings) {
    if (quitting_) return;
    createWindow(); place(true);
    if (!visible_) { visible_ = true; paintPending_ = true; showStart_ = milliseconds(); corners_.suppress(true); ShowWindow(window_, SW_SHOWNORMAL); }
    SetForegroundWindow(window_);
    if (settings && !prompt_ && !busy_) openBuffer(TerminalBuffer::settings);
    layoutInput();
    if (textInputActive()) { SetFocus(search_); SendMessageW(search_, EM_SETSEL, savedSelectionStart_, savedSelectionEnd_); }
    else SetFocus(window_);
    reload(); invalidate(); diagnostics_.event("show_requested", {{"first", firstShow_}});
}
void Launcher::hide() {
    if (!visible_) return;
    if (textInputActive()) SendMessageW(search_, EM_GETSEL, reinterpret_cast<WPARAM>(&savedSelectionStart_), reinterpret_cast<LPARAM>(&savedSelectionEnd_));
    cancelDrag(); updateHover(-1, -1);
    if (input_ == TerminalInput::search || !query_.empty()) {
        query_.clear(); selection_ = scroll_ = 0;
        if (input_ == TerminalInput::search) setInput(TerminalInput::none);
        rebuildItems();
    }
    visible_ = false; paintPending_ = false; ShowWindow(window_, SW_HIDE); corners_.suppress(false); diagnostics_.event("hidden");
}
void Launcher::quit() { if (busy_) { notify("正在处理数据，请完成后再退出。", true); return; } hide(); quitting_ = true; PostQuitMessage(0); }
void Launcher::place(bool mouseMonitor) {
    if (!window_) return; POINT point{}; GetCursorPos(&point);
    auto monitor = mouseMonitor ? MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST) : MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(info)}; require(GetMonitorInfoW(monitor, &info) != FALSE, winError("无法读取显示器范围"));
    auto rect = info.rcMonitor; SetWindowPos(window_, HWND_TOP, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, SWP_NOACTIVATE); updateLayout();
}
void Launcher::updateLayout() {
    if (!window_) return; RECT rect{}; GetClientRect(window_, &rect);
    scale_ = std::max(.01f, std::min(rect.right / 1440.0f, rect.bottom / 900.0f));
    originX_ = (rect.right - 1440 * scale_) / 2; originY_ = (rect.bottom - 900 * scale_) / 2;
    int height = std::max(1, static_cast<int>(15.5f * scale_));
    if (fontHeight_ != height) {
        auto next = CreateFontW(-height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH, L"Consolas");
        SendMessageW(search_, WM_SETFONT, reinterpret_cast<WPARAM>(next), TRUE); if (font_) DeleteObject(font_); font_ = next; fontHeight_ = height;
    }
    if (target_) { auto result = target_->Resize(D2D1::SizeU(rect.right, rect.bottom)); if (result == D2DERR_RECREATE_TARGET) releaseRenderer(); else check(result, "无法调整绘制表面。"); }
    layoutInput(); syncAccessibility(); invalidate();
}
void Launcher::layoutInput() {
    if (!search_) return;
    inputX_ = prompt_ ? std::min(480.0f, 70 + static_cast<float>(wide(promptLabel()).size()) * 8.0f) : input_ == TerminalInput::calc ? 180.0f : 58.0f;
    float hintWidth = std::min(510.0f, static_cast<float>(wide(inputHint()).size()) * 10.0f);
    MoveWindow(search_, static_cast<int>(originX_ + inputX_ * scale_), static_cast<int>(originY_ + 763 * scale_),
        static_cast<int>(std::max(160.0f, 1400 - hintWidth - 24 - inputX_) * scale_), static_cast<int>(28 * scale_), TRUE);
    ShowWindow(search_, textInputActive() ? SW_SHOW : SW_HIDE);
    SendMessageW(search_, EM_SETREADONLY, busy_, 0);
}
void Launcher::invalidate() {
    if (window_ && visible_) InvalidateRect(window_, nullptr, FALSE);
}
void Launcher::ensureRenderer() {
    if (!d2d_) check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf()), "无法初始化 Direct2D。");
    if (!dwrite_) check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(dwrite_.GetAddressOf())), "无法初始化 DirectWrite。");
    if (target_) return;
    RECT rect{}; GetClientRect(window_, &rect);
    check(d2d_->CreateHwndRenderTarget(D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_UNKNOWN, D2D1_ALPHA_MODE_IGNORE), 96, 96), D2D1::HwndRenderTargetProperties(window_, D2D1::SizeU(rect.right, rect.bottom)), &target_), "无法建立绘制表面。");
    target_->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE); check(target_->CreateSolidColorBrush(D2D1::ColorF(ink), &brush_), "无法建立画笔。");
}
void Launcher::releaseRenderer() { brush_.Reset(); target_.Reset(); }
void Launcher::rectangle(Rect rect, UINT32 color, float radius, bool outline) {
    brush_->SetColor(D2D1::ColorF(color));
    if (radius > 0) { auto shape = D2D1::RoundedRect(drect(rect), radius, radius); if (outline) target_->DrawRoundedRectangle(shape, brush_.Get()); else target_->FillRoundedRectangle(shape, brush_.Get()); }
    else if (outline) target_->DrawRectangle(drect(rect), brush_.Get()); else target_->FillRectangle(drect(rect), brush_.Get());
}
void Launcher::text(const std::wstring& value, Rect rect, float size, UINT32 color, bool center, bool bold) {
    auto& format = formats_[{static_cast<int>(size * 10), bold}];
    if (!format) {
        check(dwrite_->CreateTextFormat(L"Consolas", nullptr, bold ? DWRITE_FONT_WEIGHT_SEMI_BOLD : DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, L"zh-CN", &format), "无法建立字体。");
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP); format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER, 0, 0}; ComPtr<IDWriteInlineObject> ellipsis; dwrite_->CreateEllipsisTrimmingSign(format.Get(), &ellipsis); format->SetTrimming(&trimming, ellipsis.Get());
    }
    format->SetTextAlignment(center ? DWRITE_TEXT_ALIGNMENT_CENTER : DWRITE_TEXT_ALIGNMENT_LEADING); brush_->SetColor(D2D1::ColorF(color));
    target_->DrawText(value.c_str(), static_cast<UINT>(value.size()), format.Get(), drect(rect), brush_.Get(), D2D1_DRAW_TEXT_OPTIONS_CLIP);
}
void Launcher::paint() {
    PAINTSTRUCT ps{}; BeginPaint(window_, &ps); ScopeExit finish{[&] { EndPaint(window_, &ps); }};
    if (!visible_) return; ensureRenderer(); target_->BeginDraw(); target_->SetTransform(D2D1::Matrix3x2F::Identity()); target_->Clear(D2D1::ColorF(paper));
    target_->SetTransform(D2D1::Matrix3x2F::Scale(scale_, scale_) * D2D1::Matrix3x2F::Translation(originX_, originY_));
    bool output = buffer_ == TerminalBuffer::none || prompt_ || input_ == TerminalInput::command;
    if (buffer_ == TerminalBuffer::none) drawRows();
    else { if (output) target_->PushAxisAlignedClip(D2D1::RectF(40, 24, 1400, 648), D2D1_ANTIALIAS_MODE_PER_PRIMITIVE); drawBuffer(); if (output) target_->PopAxisAlignedClip(); }
    if (output) drawOutput();
    drawChrome();
    auto result = target_->EndDraw(); if (result == D2DERR_RECREATE_TARGET) { releaseRenderer(); invalidate(); } else check(result, "界面绘制失败。");
    if (paintPending_ && loaded_ && SUCCEEDED(result)) {
        paintPending_ = false; diagnostics_.event(firstShow_ ? "first_interactive" : "reopened", {{"durationMs", milliseconds() - showStart_}, {"bookmarks", snapshot_.document.bookmarks.size()}, {"rows", rows_.size()}, {"scale", scale_}}); firstShow_ = false;
    }
}
void Launcher::drawRows() {
    if (rows_.empty()) {
        text(!loaded_ ? busy_ ? L"正在读取书签…" : L"无法载入数据，原文件已保留" : query_.empty() ? L"把常用网站放在这里" : L"没有匹配的书签", {40, 280, 1360, 36}, 20, !loaded_ && !busy_ ? red : ink, true);
        text(!loaded_ && !busy_ ? L":retry 重试读取 · :cd 更换数据目录" : query_.empty() ? L"a 添加书签 · n 新建文件夹 · :help 查看帮助" : L"Enter 打开网址或 Google 搜索 · Esc 清空", {40, 322, 1360, 28}, 13, muted, true);
    }
    int end = std::min(static_cast<int>(rows_.size()), scroll_ + 19);
    for (int i = scroll_; i < end; ++i) {
        const auto& row = rows_[i]; float y = 24.0f + (i - scroll_) * 32, indent = row.depth * 32.0f; bool selected = i == selection_;
        if (selected) { rectangle({40, y, 1360, 32}, ink); rectangle({40, y, 3, 32}, yellow); }
        if (organizing_ && !row.folder) text(L"[×]", {50, y, 38, 32}, 12, selected ? yellow : red, false, true);
        if (row.folder) {
            brush_->SetColor(D2D1::ColorF(selected ? yellow : muted));
            const auto start = D2D1::Point2F(row.expanded ? 82.0f : 84.0f, y + (row.expanded ? 14.0f : 12.0f));
            const auto middle = D2D1::Point2F(row.expanded ? 86.0f : 88.0f, y + (row.expanded ? 18.0f : 16.0f));
            const auto finish = D2D1::Point2F(row.expanded ? 90.0f : 84.0f, y + (row.expanded ? 14.0f : 20.0f));
            target_->DrawLine(start, middle, brush_.Get(), 1.5f);
            target_->DrawLine(middle, finish, brush_.Get(), 1.5f);
            rectangle({100, y + 9, 19, 14}, selected ? mint : purple, 2); rectangle({100, y + 6, 9, 5}, selected ? mint : purple, 1);
            text(wide(row.title), {134, y, 1030, 32}, 14, selected ? paper : purple, false, true);
            text(wide(row.detail + (row.expanded ? " · 已展开" : "") + (organizing_ ? " · 固定" : "")), {1180, y, 210, 32}, 11.5f, selected ? mint : muted);
        } else {
            if (row.depth) { rectangle({106, y, 1, 32}, line); rectangle({106, y + 16, 18, 1}, line); }
            rectangle({98 + indent, y + 6, 20, 20}, row.iconColor, 3);
            text(row.initial, {98 + indent, y + 6, 20, 20}, 11, paper, true, true);
            text(wide(row.title), {134 + indent, y, query_.empty() ? 800.0f : 590.0f, 32}, 14, selected ? paper : ink);
            if (!query_.empty()) { rectangle({750, y + 7, 180, 18}, line); text(wide(row.groupName), {755, y + 7, 170, 18}, 10, purple); }
            text(wide(row.detail), {970, y, 420, 32}, 12, selected ? mint : muted);
        }
        if (dragging_ && i == dragTarget_) {
            rectangle({46, y + 1, 1348, 30}, green, 0, true); rectangle({46, dragBefore_ ? y : y + 31, 1348, 2}, green);
            std::string label = row.folder ? "移入「" + row.title + "」" : dragMerge_ ? mergeReady_ ? "＋ 创建文件夹" : "停留以创建文件夹" : "插入到此";
            rectangle({1110, y - 20, 284, 18}, mint); text(wide(label), {1118, y - 20, 268, 18}, 11, forest, false, true);
        }
    }
    if (static_cast<int>(rows_.size()) > 19) {
        float height = 608.0f * 19 / static_cast<float>(rows_.size());
        rectangle({1412, 24, 2, 608}, line); rectangle({1412, 24 + (608 - height) * scroll_ / static_cast<float>(rows_.size() - 19), 2, height}, muted);
    }
}
void Launcher::drawBuffer() {
    text(L"BUFFER", {40, 24, 60, 24}, 10, muted); text(wide(std::string("[") + bufferName(buffer_) + "]"), {102, 24, 350, 24}, 13, ink, false, true); rectangle({40, 50, 1360, 1}, line);
    if (buffer_ == TerminalBuffer::help) {
        text(L"NAME", {64, 72, 260, 24}, 12, green, false, true); text(L"青蛙导航 — 本地书签启动台。所有操作在命令行完成。", {340, 72, 1060, 24}, 12, ink);
        text(L"SYNOPSIS", {64, 102, 260, 24}, 12, green, false, true); text(L"frog [command] · j/k 选择 · : 命令 · / 搜索", {340, 102, 1060, 24}, 12, ink);
        text(L"COMMANDS", {64, 136, 260, 24}, 12, green, false, true);
        for (int i = bufferOffset_; i < std::min(static_cast<int>(helpCommands_.size()), bufferOffset_ + 21); ++i) {
            const auto& command = helpCommands_[i]; float y = 162.0f + (i - bufferOffset_) * 20;
            auto separator = command.label.find(" · ");
            text(wide(":" + command.id), {64, y, 260, 20}, 12, teal, false, true); text(wide(command.label.substr(0, separator)), {340, y, 400, 20}, 11.5f, ink);
            text(wide(command.detail + (separator == std::string::npos ? "" : " · " + command.label.substr(separator + std::string_view(" · ").size()))), {760, y, 250, 20}, 10.5f, muted);
        }
        rectangle({1030, 142, 1, 442}, line); text(L"KEYS · 列表模式", {1080, 136, 314, 24}, 12, green, false, true);
        static const std::pair<const wchar_t*, const wchar_t*> keys[]{
            {L"j/k · ↑/↓", L"移动"}, {L"g/G", L"首项 / 末项"}, {L"PageUp/Down", L"滚动"}, {L"Enter", L"打开 / 确认"},
            {L"/", L"搜索"}, {L":", L"命令"}, {L"a · Ctrl+N", L"添加书签"}, {L"n", L"新建文件夹"}, {L"e", L"编辑书签"},
            {L"r", L"重命名文件夹"}, {L"m", L"移动书签"}, {L"D", L"删除确认"}, {L"c / C", L"复制链接"}, {L"o", L"整理"},
            {L"Shift+↑/↓", L"书签排序"}, {L"Tab", L"展开 / 折叠"}, {L"z", L"全部展开"}, {L"Ctrl+,", L"设置"}, {L"?", L"帮助"}, {L"Esc", L"取消 / 返回"}};
        for (size_t i = 0; i < std::size(keys); ++i) { float y = 162.0f + static_cast<float>(i) * 20; text(keys[i].first, {1080, y, 125, 20}, 11, teal, false, true); text(keys[i].second, {1210, y, 184, 20}, 11.5f, ink); }
        rectangle({64, 584, 936, 1}, line); text(L"EXAMPLES", {64, 592, 260, 24}, 12, green, false, true);
        static const std::pair<const wchar_t*, const wchar_t*> examples[]{
            {L":add", L"逐项输入网址 / 标题 / 位置"}, {L":edit url", L"修改当前书签网址"}, {L":delete", L"命令行 y/N 确认删除"},
            {L":set corner right-up", L"修改屏幕触角"}, {L":backup", L"输入备份文件路径，导出 JSON"}, {L":calc", L"打开计算器；c 复制结果"}};
        for (size_t i = 0; i < std::size(examples); ++i) { float y = 618.0f + static_cast<float>(i) * 17; text(examples[i].first, {64, y, 370, 17}, 11.5f, ink); text(examples[i].second, {460, y, 540, 17}, 11.5f, ink); }
        text(wide("FILES: " + utf8((preferences_.dataDirectory / L"bookmarks.json").wstring())), {64, 716, 1336, 20}, 10, muted);
        return;
    }
    if (buffer_ == TerminalBuffer::calc) {
        text(wide(calcError_.empty() ? calcExpression_.empty() ? "输入算式后按 Enter 计算" : calcPreview_.empty() ? "…" : calcPreview_ : calcError_), {72, 84, 1296, 64}, calcError_.empty() && !calcPreview_.empty() ? 40.0f : 15.0f, calcError_.empty() ? green : red, false, true);
        rectangle({72, 168, 1296, 1}, line); text(wide("HISTORY · " + std::to_string(calcHistory_.size()) + " 条"), {72, 180, 600, 24}, 10.5f, muted);
        text(L"↑↓ 选择 · 点击载入 · c 复制结果", {1000, 180, 368, 24}, 10.5f, muted);
        for (int i = bufferOffset_; i < std::min(static_cast<int>(calcHistory_.size()), bufferOffset_ + 16); ++i) {
            float y = 205.0f + (i - bufferOffset_) * 26; bool selected = i == calcHistoryIndex_;
            if (selected) { rectangle({64, y, 1312, 22}, ink); rectangle({64, y, 3, 22}, yellow); }
            const auto& entry = calcHistory_[i]; text(wide(entry.time), {100, y, 80, 22}, 11, selected ? mint : muted);
            text(wide(entry.expression), {190, y, 900, 22}, 12.5f, selected ? paper : ink); text(wide(entry.value), {1100, y, 268, 22}, 13, selected ? mint : green, false, true);
        }
        return;
    }
    if (buffer_ == TerminalBuffer::job) { text(wide(jobTitle_ + " · " + jobStatus_), {72, 66, 1296, 28}, 18, jobStatus_ == "ERROR" ? red : green, false, true); }
    if (buffer_ == TerminalBuffer::settings) { text(L"设置项", {130, 72, 150, 24}, 10.5f, muted); text(L"当前值", {304, 72, 496, 24}, 10.5f, muted); text(L"命令", {840, 72, 550, 24}, 10.5f, muted); }
    const auto& lines = buffer_ == TerminalBuffer::log ? logs_ : buffer_ == TerminalBuffer::job ? jobLines_ : bufferLines_;
    int capacity = buffer_ == TerminalBuffer::settings ? 31 : buffer_ == TerminalBuffer::job ? 25 : 32;
    float top = buffer_ == TerminalBuffer::settings ? 106.0f : buffer_ == TerminalBuffer::job ? 110.0f : 74.0f;
    for (int i = bufferOffset_; i < std::min(static_cast<int>(lines.size()), bufferOffset_ + capacity); ++i) {
        const auto& entry = lines[i]; float y = top + (i - bufferOffset_) * 20;
        text(wide(std::to_string(i + 1)), {72, y, 48, 20}, 10, muted);
        auto tab = entry.text.find('\t');
        if (buffer_ == TerminalBuffer::settings && tab != std::string::npos) {
            auto next = entry.text.find('\t', tab + 1); text(wide(entry.text.substr(0, tab)), {130, y, 146, 20}, 12, teal);
            bool flash = entry.text.starts_with("corner\t") && milliseconds() < cornerFlashUntil_;
            text(L"=", {286, y, 14, 20}, 12, muted); text(wide(entry.text.substr(tab + 1, next - tab - 1) + (flash ? " ←" : "")), {304, y, 496, 20}, 12, flash ? 0x862617 : entry.color, false, true);
            if (next != std::string::npos) text(wide(entry.text.substr(next + 1)), {840, y, 550, 20}, 10.5f, muted);
        } else {
            if (!entry.time.empty()) text(wide(entry.time), {116, y, 70, 20}, 11, muted);
            float x = entry.time.empty() ? 130.0f : 190.0f; text(wide(entry.text), {x, y, 1400 - x, 20}, 12, entry.color);
        }
    }
    text(wide(std::to_string(std::min(static_cast<int>(lines.size()), bufferOffset_ + capacity)) + " / " + std::to_string(lines.size())), {1260, 716, 140, 20}, 10, muted);
}
void Launcher::drawOutput() {
    rectangle({40, 664, 1360, 72}, paper); rectangle({40, 664, 1360, 1}, line);
    if (prompt_) {
        rectangle({40, 665, 1360, 71}, surface); rectangle({40, 664, 3, 72}, yellow);
        text(wide("PROMPT · " + prompt_->command + (prompt_->total ? " · " + std::to_string(prompt_->step + 1) + "/" + std::to_string(prompt_->total) : "")), {54, 668, 1300, 20}, 10.5f, muted);
        if (!prompt_->choices.empty() && prompt_->error.empty()) {
            int start = std::max(0, prompt_->selected - 2);
            for (int i = start; i < std::min(static_cast<int>(prompt_->choices.size()), start + 3); ++i) {
                float y = 690.0f + (i - start) * 14; bool selected = i == prompt_->selected; if (selected) rectangle({40, y, 1360, 16}, ink);
                const auto& choice = prompt_->choices[i]; text(wide(std::to_string(i + 1)), {50, y, 28, 16}, 11, selected ? yellow : muted);
                text(wide(choice.label), {78, y, 840, 16}, 12, selected ? paper : ink); text(wide(choice.detail), {940, y, 450, 16}, 11, selected ? mint : muted);
            }
        } else {
            text(wide(prompt_->error.empty() ? prompt_->hint : prompt_->error), {54, 690, 1332, 20}, 12.5f, prompt_->error.empty() ? ink : red);
            auto context = prompt_->command == "edit" ? (prompt_->field == "title" ? "网址：" + draft_.url : "标题：" + draft_.title) : "Enter 确认 · Esc 取消；未提交的输入会保留。";
            text(wide(context), {54, 709, 1332, 20}, 11.5f, muted);
        }
        return;
    }
    if (!issue_.empty() && input_ == TerminalInput::none) {
        text(L"DATA ERROR · 已保留现有数据", {40, 667, 1360, 20}, 10.5f, red);
        text(wide(issue_), {40, 690, 1360, 20}, 12.5f, red); text(L":retry 重试载入 · :cd 更换数据目录 · :log 查看日志", {40, 710, 1360, 20}, 11.5f, muted); return;
    }
    if (organizing_ && input_ == TerminalInput::none) {
        text(L"整理 / ORGANIZE", {40, 667, 1360, 20}, 11, green, false, true);
        text(L"j/k 选择 · Shift+↑/↓ 或 J/K 同组排序 · m 移到文件夹 · D 删除确认", {40, 689, 1360, 20}, 13, ink);
        text(L"文件夹置顶且固定；拖动书签排序、移入文件夹，或在根书签中央停留创建文件夹。o / Esc 完成。", {40, 709, 1360, 20}, 12, muted); return;
    }
    if (input_ == TerminalInput::command && !commandHints_.empty()) {
        text(L"COMMANDS · Tab 补全 · ↑↓ 历史", {40, 667, 800, 20}, 10.5f, muted);
        for (size_t i = 0; i < commandHints_.size(); ++i) { float y = 690.0f + static_cast<float>(i) * 16;
            text(wide(std::to_string(i + 1)), {48, y, 26, 16}, 11, muted); text(wide(":" + commandHints_[i].id), {74, y, 350, 16}, 12.5f, ink);
            text(wide(commandHints_[i].label), {440, y, 952, 16}, 11, muted);
        }
        return;
    }
    text(L"OUTPUT", {40, 667, 100, 20}, 10.5f, muted); text(L":log 查看全部", {1270, 667, 130, 20}, 10.5f, muted);
    int start = std::max(0, static_cast<int>(logs_.size()) - 3);
    for (int i = start; i < static_cast<int>(logs_.size()); ++i) { float y = 690.0f + (i - start) * 16; text(wide(logs_[i].time), {40, y, 64, 16}, 11.5f, muted); text(wide(logs_[i].text), {106, y, 1294, 16}, 12.5f, logs_[i].color); }
}
void Launcher::drawChrome() {
    rectangle({0, 752, 1440, 1}, line);
    text(input_ == TerminalInput::calc ? L"=" : input_ == TerminalInput::search ? L"/" : input_ != TerminalInput::none || prompt_ ? L":" : L"›", {40, 757, 18, 32}, 17, input_ == TerminalInput::search ? teal : green, false, true);
    if (prompt_) text(wide(promptLabel()), {58, 757, inputX_ - 70, 32}, 13, muted);
    else if (input_ == TerminalInput::calc) text(L"calc › 算式", {58, 757, 120, 32}, 13, muted);
    if (!textInputActive()) text(wide(prompt_ ? inputText_ : buffer_ == TerminalBuffer::settings ? ": 输入命令 · :help 查看帮助" : ": 打开命令 · / 搜索 · ? 帮助"), {inputX_, 757, 820, 32}, 14, muted);
    const auto hint = wide(inputHint()); const float hintWidth = std::min(510.0f, static_cast<float>(hint.size()) * 10.0f);
    text(hint, {1400 - hintWidth, 757, hintWidth, 32}, 12, prompt_ && !prompt_->error.empty() ? red : muted);
    rectangle({0, 796, 1440, 36}, forest); auto mode = modeLabel();
    if (buffer_ == TerminalBuffer::none && !prompt_ && input_ != TerminalInput::command) {
        if (!query_.empty()) mode += " · “" + query_ + "” · " + std::to_string(rows_.size()) + " 条结果";
        else if (!expanded_.empty()) mode += " · 已展开 " + std::to_string(expanded_.size()) + " 个文件夹";
    }
    text(wide(mode), {40, 797, 860, 36}, 12.5f, yellow, false, true);
    if (!prompt_ && input_ == TerminalInput::none && !busy_) text(buffer_ == TerminalBuffer::settings ? L":set <key> <value> · :help 帮助 · Esc 返回" : L": 命令 · ? 帮助", {920, 797, 480, 36}, 12, mint);
    if (busy_) text(L"正在处理，请稍候…", {40, 842, 1360, 28}, 11.5f, muted);
    else {
        auto hints = wide(shortcuts()); float x = 40; size_t start = 0;
        while (start < hints.size() && x < 1380) {
            auto end = hints.find(L"    ", start); auto segment = hints.substr(start, end == std::wstring::npos ? end : end - start); auto split = segment.find(L' ');
            auto key = segment.substr(0, split), label = split == std::wstring::npos ? L"" : segment.substr(split + 1);
            auto width = [](std::wstring_view value) { float result = 0; for (auto unit : value) result += unit < 128 ? 6.9f : 11.5f; return result; };
            float keyWidth = std::max(24.0f, width(key) + 12); rectangle({x, 845, keyWidth, 22}, surface, 2); rectangle({x, 845, keyWidth, 22}, line, 2, true);
            text(key, {x, 845, keyWidth, 22}, 11.5f, ink, true); float labelWidth = width(label); text(label, {x + keyWidth + 6, 845, std::max(0.0f, std::min(labelWidth + 2, 1400 - x - keyWidth - 6)), 22}, 11.5f, muted);
            x += keyWidth + 24 + labelWidth; if (end == std::wstring::npos) break; start = end + 4;
        }
    }
}
void Launcher::loadInitial() {
    busy_ = true; layoutInput(); syncAccessibility();
    auto directory = preferences_.dataDirectory; bool create = options_.isolated || sameFile(directory, localDirectory() / L"Data");
    bool initialize = options_.isolated || !fs::exists(localDirectory() / L"preferences.json");
    storageQueue_->post([this, directory, create, initialize] {
        try { auto snapshot = storage_.open(directory, create, {}, initialize); dispatch([this, snapshot = std::move(snapshot)]() mutable {
            busy_ = false; issue_.clear(); applySnapshot(std::move(snapshot));
            appendLog("青蛙导航 · " + std::to_string(snapshot_.document.bookmarks.size()) + " bookmarks · " + std::to_string(snapshot_.document.groups.size()) + " groups · UTF-8", green);
            appendLog("输入 : 打开命令 · / 搜索 · ? 帮助"); diagnostics_.event("data_loaded", {{"bookmarks", snapshot_.document.bookmarks.size()}});
        }); } catch (const std::exception& e) { dispatch([this, value = std::string(e.what())] { busy_ = false; issue_ = value; notify(value + " 原文件已保留；:retry 重试或 :cd 更换目录。", true); layoutInput(); diagnostics_.event("load_failed", {{"message", value}}); }); }
    });
}
void Launcher::reload() {
    if (busy_ || reloading_) { reloadPending_ = true; return; }
    if (!loaded_) { loadInitial(); return; }
    reloading_ = true;
    storageQueue_->post([this] {
        try { auto next = storage_.reload(); dispatch([this, next = std::move(next)]() mutable {
            reloading_ = false; issue_.clear(); if (next.bytes != snapshot_.bytes) { cancelDrag(); applySnapshot(std::move(next)); appendLog("已读取外部更新，未提交的输入已保留。"); diagnostics_.event("external_updated"); }
            if (!watcher_.running()) watcher_.start(snapshot_.directory, [this] { PostMessageW(controller_, wmDirectory, 0, 0); });
            layoutInput(); refreshBuffer(); syncAccessibility(); invalidate(); if (reloadPending_) { reloadPending_ = false; reload(); }
        }); } catch (const std::exception& e) { dispatch([this, value = std::string(e.what())] { reloading_ = false; reloadPending_ = false; issue_ = value; notify(value + " 当前数据与草稿已保留；:retry 重试。", true); layoutInput(); }); }
    });
}
void Launcher::applySnapshot(Snapshot snapshot) {
    bool changed = snapshot_.directory != snapshot.directory; snapshot_ = std::move(snapshot); loaded_ = true;
    if (changed) watcher_.start(snapshot_.directory, [this] { PostMessageW(controller_, wmDirectory, 0, 0); });
    auto expandedCount = expanded_.size(); std::erase_if(expanded_, [this](const auto& id) { return !snapshot_.document.group(id); });
    if (expandedCount != expanded_.size()) persistExpanded();
    rebuildItems(); layoutInput(); refreshBuffer();
}
void Launcher::mutate(std::function<void(Document&)> mutation, std::function<void()> success, std::string expected) {
    require(loaded_, "数据尚未成功读取；:retry 重试或 :cd 更换目录。"); require(!busy_, "正在处理数据，请稍后重试。");
    auto next = snapshot_.document; mutation(next); next.validate(); if (expected.empty()) expected = snapshot_.bytes;
    busy_ = true; layoutInput(); syncAccessibility(); invalidate();
    storageQueue_->post([this, next = std::move(next), expected = std::move(expected), success = std::move(success)]() mutable {
        try { auto saved = storage_.save(next, expected); dispatch([this, saved = std::move(saved), success = std::move(success)]() mutable {
            busy_ = false; issue_.clear(); applySnapshot(std::move(saved)); if (success) success(); diagnostics_.event("saved");
            if (reloadPending_) { reloadPending_ = false; reload(); }
        }); } catch (const Conflict& e) {
            std::optional<Snapshot> current; try { current = storage_.reload(); } catch (const std::exception&) {}
            dispatch([this, current = std::move(current), value = std::string(e.what())]() mutable {
                busy_ = false; if (current) applySnapshot(std::move(*current)); draft_.expected = snapshot_.bytes;
                notify(value + " 输入已保留，核对后 Enter 重试。", true); layoutInput(); diagnostics_.event("save_conflict");
            });
        } catch (const std::exception& e) { dispatch([this, value = std::string(e.what())] { busy_ = false; notify(value + " 当前数据与草稿已保留。", true); layoutInput(); diagnostics_.event("save_failed", {{"message", value}}); }); }
    });
}
void Launcher::notify(const std::string& value, bool error) {
    if (error && prompt_) prompt_->error = value;
    if (error && buffer_ == TerminalBuffer::calc && !prompt_) calcFeedback_ = value;
    appendLog(value, error ? red : teal); layoutInput();
}
void Launcher::appendLog(const std::string& value, UINT32 color) {
    if (logs_.size() == 200) logs_.erase(logs_.begin()); logs_.push_back({clockText(), value, color});
    if (buffer_ == TerminalBuffer::settings) refreshBuffer(); syncAccessibility(); invalidate();
}
void Launcher::tray(bool add) {
    if (!controller_) return; NOTIFYICONDATAW data{sizeof(data)}; data.hWnd = controller_; data.uID = 1; data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    data.uCallbackMessage = wmTray; data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(102)); wcscpy_s(data.szTip, L"青蛙导航 · 回声终端"); Shell_NotifyIconW(add ? NIM_ADD : NIM_DELETE, &data);
    if (add) { data.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &data); }
}
void Launcher::trayMenu() {
    HMENU popup = CreatePopupMenu(); ScopeExit cleanup{[&] { DestroyMenu(popup); }};
    AppendMenuW(popup, MF_STRING, 1, visible_ ? L"收起" : L"展开"); AppendMenuW(popup, MF_STRING, 2, L"设置"); AppendMenuW(popup, MF_SEPARATOR, 0, nullptr); AppendMenuW(popup, MF_STRING, 3, L"退出青蛙导航");
    POINT point{}; GetCursorPos(&point); inMenu_ = true; SetForegroundWindow(controller_); auto command = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, controller_, nullptr); inMenu_ = false; PostMessageW(controller_, WM_NULL, 0, 0);
    if (command == 1) { if (visible_) hide(); else show(); } else if (command == 2) show(true); else if (command == 3) quit();
}
void Launcher::menu(POINT point) {
    if (busy_ || prompt_ || buffer_ != TerminalBuffer::none || !selectedRow()) return;
    bool folder = selectedRow()->folder; HMENU popup = CreatePopupMenu(); ScopeExit cleanup{[&] { DestroyMenu(popup); }};
    AppendMenuW(popup, MF_STRING, 1, folder ? L"展开 / 折叠" : L"打开");
    AppendMenuW(popup, MF_STRING, 2, folder ? L"重命名" : L"编辑标题与网址");
    if (!folder) { AppendMenuW(popup, MF_STRING, 3, L"复制网址"); AppendMenuW(popup, MF_STRING, 4, L"移动"); }
    AppendMenuW(popup, MF_STRING, 5, L"删除（需确认）"); inMenu_ = true;
    int command = TrackPopupMenu(popup, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, window_, nullptr); inMenu_ = false;
    if (command == 1) activate(); else if (command == 2) beginAction(folder ? "rename" : "edit"); else if (command == 3) copySelection(); else if (command == 4) beginAction("move"); else if (command == 5) beginAction("delete");
}
const TerminalRow* Launcher::selectedRow() const { return selection_ >= 0 && selection_ < static_cast<int>(rows_.size()) ? &rows_[selection_] : nullptr; }
void Launcher::rebuildItems(const std::string& selected) {
    auto keep = selected.empty() && selectedRow() ? selectedRow()->id : selected;
    rows_.clear(); const auto& data = snapshot_.document;
    auto bookmarkRow = [&](const Item& item, int depth) {
        if (auto b = data.bookmark(item.id)) { std::string group = "根目录"; if (b->groupId) if (auto g = data.group(*b->groupId)) group = g->name;
            rows_.push_back({b->id, b->title, host(b->url), group, b->groupId, false, false, depth});
            auto& row = rows_.back(); constexpr UINT32 tiles[]{green, purple, 0x1661ab, red, 0x862617, teal, 0x2e4b26, forest};
            uint32_t hash = 0; for (auto unit : wide(row.id)) hash = hash * 31 + unit; row.iconColor = tiles[hash % 8];
            row.initial = wide(row.title); if (!row.initial.empty()) {
                row.initial.resize(row.initial[0] >= 0xd800 && row.initial[0] <= 0xdbff && row.initial.size() > 1 ? 2 : 1);
                wchar_t upper[8]{}; int length = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_UPPERCASE, row.initial.data(), static_cast<int>(row.initial.size()), upper, static_cast<int>(std::size(upper)), nullptr, nullptr, 0);
                if (length > 0) row.initial.assign(upper, length);
            }
        }
    };
    if (!trim(query_).empty()) { for (const auto& item : data.search(query_)) bookmarkRow(item, 0); }
    else {
        std::vector<const Group*> groups; groups.reserve(data.groups.size()); for (const auto& group : data.groups) groups.push_back(&group);
        std::sort(groups.begin(), groups.end(), [](auto a, auto b) { return a->order == b->order ? a->id < b->id : a->order < b->order; });
        for (auto group : groups) {
            auto children = data.items(group->id); bool expanded = expanded_.contains(group->id);
            rows_.push_back({group->id, group->name, std::to_string(children.size()) + " 项", {}, {}, true, expanded, 0});
            if (expanded) for (const auto& item : children) bookmarkRow(item, 1);
        }
        for (const auto& item : data.items()) if (!item.folder) bookmarkRow(item, 0);
    }
    for (size_t i = 0; i < rows_.size(); ++i) if (rows_[i].id == keep) { selection_ = static_cast<int>(i); break; }
    clampSelection(); syncAccessibility(); invalidate();
}
void Launcher::clampSelection() { selection_ = std::clamp(selection_, 0, std::max(0, static_cast<int>(rows_.size()) - 1)); scroll_ = std::clamp(scroll_, 0, std::max(0, static_cast<int>(rows_.size()) - 19)); if (selection_ < scroll_) scroll_ = selection_; if (selection_ >= scroll_ + 19) scroll_ = selection_ - 18; }
void Launcher::moveCursor(int delta) { selection_ = std::clamp(selection_ + delta, 0, std::max(0, static_cast<int>(rows_.size()) - 1)); clampSelection(); syncAccessibility(); invalidate(); }
void Launcher::scroll(int delta) {
    if (prompt_) return;
    if (buffer_ != TerminalBuffer::none) {
        int capacity = buffer_ == TerminalBuffer::calc ? 16 : buffer_ == TerminalBuffer::settings ? 31 : buffer_ == TerminalBuffer::job ? 25 : buffer_ == TerminalBuffer::help ? 21 : 32;
        size_t count = buffer_ == TerminalBuffer::calc ? calcHistory_.size() : buffer_ == TerminalBuffer::log ? logs_.size() : buffer_ == TerminalBuffer::job ? jobLines_.size() : buffer_ == TerminalBuffer::help ? helpCommands_.size() : bufferLines_.size();
        bufferOffset_ = std::clamp(bufferOffset_ + delta, 0, std::max(0, static_cast<int>(count) - capacity));
    } else { scroll_ = std::clamp(scroll_ + delta, 0, std::max(0, static_cast<int>(rows_.size()) - 19)); selection_ = std::clamp(selection_, scroll_, std::min(std::max(0, static_cast<int>(rows_.size()) - 1), scroll_ + 18)); }
    syncAccessibility(); invalidate();
}
void Launcher::persistExpanded() { preferences_.expandedGroupIDs.assign(expanded_.begin(), expanded_.end()); try { preferences_.save(options_); } catch (const std::exception& e) { notify(e.what(), true); } }
void Launcher::toggleFolder(const std::string& id) {
    if (prompt_ || busy_) return; auto group = snapshot_.document.group(id); if (!group) return;
    std::string name = group->name; bool expanding = !expanded_.contains(id); if (expanding) expanded_.insert(id); else expanded_.erase(id);
    persistExpanded(); rebuildItems(id); appendLog(std::string(expanding ? "展开文件夹 " : "折叠文件夹 ") + name);
}
void Launcher::toggleAll() {
    if (prompt_ || busy_ || buffer_ != TerminalBuffer::none || !trim(query_).empty()) return;
    auto row = selectedRow(); auto keep = row ? row->folder ? row->id : row->group.value_or("") : "";
    if (expanded_.size() == snapshot_.document.groups.size()) expanded_.clear(); else for (const auto& group : snapshot_.document.groups) expanded_.insert(group.id);
    persistExpanded(); rebuildItems(keep); appendLog(expanded_.empty() ? "折叠全部文件夹" : "展开全部文件夹");
}
void Launcher::activate() {
    if (prompt_ || busy_ || buffer_ != TerminalBuffer::none) return;
    if (auto row = selectedRow()) { if (row->folder) { auto id = row->id; toggleFolder(id); } else if (auto b = snapshot_.document.bookmark(row->id)) open(b->url); }
    else if (!trim(query_).empty()) open(searchUrl(query_));
}
void Launcher::open(const std::string& url) { if (openUrl(url)) { appendLog("已打开 " + url, green); hide(); } else notify("系统未能打开 " + url, true); }
void Launcher::copySelection() { auto row = selectedRow(); require(row && !row->folder, "请选择书签。"); auto b = snapshot_.document.bookmark(row->id); require(b != nullptr, "书签已不存在。"); copyText(window_, wide(b->url)); appendLog("已复制链接 " + b->url, green); }
void Launcher::reorder(int delta) {
    auto row = selectedRow(); if (!organizing_ || !query_.empty() || busy_ || !row || row->folder) return;
    auto id = row->id; auto group = row->group; auto peers = snapshot_.document.items(group); std::vector<std::string> ids;
    for (const auto& item : peers) if (!item.folder) ids.push_back(item.id);
    auto it = std::find(ids.begin(), ids.end(), id); int from = static_cast<int>(it - ids.begin()), to = from + delta;
    if (it == ids.end() || to < 0 || to >= static_cast<int>(ids.size())) return;
    auto before = delta < 0 ? ids[to] : to + 1 < static_cast<int>(ids.size()) ? ids[to + 1] : std::string{};
    mutate([group, id, before](Document& data) { data.move(id, group, before); }, [this, id] { rebuildItems(id); appendLog("已调整书签顺序", green); });
}
void Launcher::escape() {
    if (busy_) return; cancelDrag();
    if (prompt_) { finishPrompt(); return; }
    if (buffer_ == TerminalBuffer::calc && input_ == TerminalInput::command) { setInput(TerminalInput::calc, calcExpression_); return; }
    if (input_ == TerminalInput::calc) { buffer_ = TerminalBuffer::none; bufferOffset_ = 0; setInput(TerminalInput::none); return; }
    if (input_ != TerminalInput::none) { if (input_ == TerminalInput::search) { query_.clear(); selection_ = scroll_ = 0; rebuildItems("__reset__"); } setInput(TerminalInput::none); return; }
    if (buffer_ != TerminalBuffer::none) { buffer_ = TerminalBuffer::none; bufferOffset_ = 0; syncAccessibility(); invalidate(); return; }
    if (organizing_) { organizing_ = false; invalidate(); return; }
    if (!query_.empty()) { query_.clear(); selection_ = scroll_ = 0; rebuildItems("__reset__"); return; }
    auto row = selectedRow(); auto group = row ? row->folder ? Location(row->id) : row->group : Location{};
    if (group && expanded_.contains(*group)) { auto id = *group; toggleFolder(id); return; }
    if (!expanded_.empty()) { expanded_.clear(); persistExpanded(); rebuildItems(group.value_or("")); appendLog("折叠全部文件夹"); return; }
    hide();
}
bool Launcher::keyboard(WPARAM key, bool control, bool shift) {
    if (composing_) return false;
    if (busy_) return key == VK_RETURN || key == VK_ESCAPE || key == VK_TAB;
    if (prompt_ && prompt_->command == "hotkey") {
        if (key == VK_ESCAPE) { finishPrompt(); return true; }
        if (key == VK_CONTROL || key == VK_SHIFT || key == VK_MENU || key == VK_LWIN || key == VK_RWIN) return true;
        UINT modifiers = (control ? MOD_CONTROL : 0) | (shift ? MOD_SHIFT : 0) | ((GetKeyState(VK_MENU) & 0x8000) ? MOD_ALT : 0) | (((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) ? MOD_WIN : 0);
        require(modifiers != 0, "请使用 Ctrl、Alt、Shift 或 Win 组合键。"); auto prefs = preferences_; prefs.hotkey = {true, modifiers, static_cast<UINT>(key)}; updatePreferences(prefs); finishPrompt(); appendLog("已保存全局快捷键", green); return true;
    }
    if (control) {
        if (key == 'Q') { quit(); return true; }
        if (key == 'H') { hide(); return true; }
        if (key == 'N' && !prompt_) { beginAction("add"); return true; }
        if (key == VK_OEM_COMMA && !prompt_) { openBuffer(TerminalBuffer::settings); return true; }
        if (key == 'F' && !prompt_) { startSearch(); return true; }
        if (key == 'A' && textInputActive()) { SendMessageW(search_, EM_SETSEL, 0, -1); return true; }
        if (key == 'C' && !textInputActive() && !prompt_) { copySelection(); return true; }
        return false;
    }
    if (GetKeyState(VK_MENU) & 0x8000) return false;
    if (key == VK_ESCAPE) { escape(); return true; }
    if (prompt_) {
        if (!prompt_->acceptsText) { if (key == VK_PACKET) return false; if (key == 'Y' && prompt_->command == "delete") confirmDelete(); else if (key == 'N' || key == VK_RETURN) finishPrompt(); return true; }
        if (key == VK_RETURN) { submitInput(); return true; }
        if (key == VK_TAB) { if (prompt_->command == "edit") switchEditField(); else if (shift) previousPrompt(); else cycleChoice(1); return true; }
        if ((key == VK_UP || key == VK_DOWN) && !prompt_->choices.empty()) { cycleChoice(key == VK_DOWN ? 1 : -1); return true; }
        return false;
    }
    if (input_ == TerminalInput::calc) {
        if (key == VK_RETURN) { submitCalc(); return true; }
        if (key == VK_UP || key == VK_DOWN) { browseCalc(key == VK_DOWN ? 1 : -1); return true; }
        if (key == VK_TAB) return true;
        return false;
    }
    if (input_ == TerminalInput::command) {
        if (key == VK_RETURN) { submitInput(); return true; }
        if (key == VK_TAB) { completeCommand(shift); return true; }
        if (key == VK_UP || key == VK_DOWN) { recallHistory(key == VK_UP ? -1 : 1); return true; }
        return false;
    }
    if (input_ == TerminalInput::search) {
        if (key == VK_RETURN) { submitInput(); return true; }
        if (key == VK_UP || key == VK_DOWN) { moveCursor(key == VK_DOWN ? 1 : -1); return true; }
        return false;
    }
    if (key == VK_APPS || (shift && key == VK_F10)) { POINT point{}; GetCursorPos(&point); menu(point); return true; }
    if (key == VK_TAB) { if (buffer_ == TerminalBuffer::none) if (auto row = selectedRow(); row && row->folder) { auto id = row->id; toggleFolder(id); } return true; }
    if (buffer_ != TerminalBuffer::none) {
        if (buffer_ == TerminalBuffer::settings) return key == VK_RETURN;
        if (key == VK_UP || key == VK_DOWN || key == VK_PRIOR || key == VK_NEXT) { scroll(key == VK_UP ? -1 : key == VK_DOWN ? 1 : key == VK_PRIOR ? -18 : 18); return true; }
        return key == VK_RETURN;
    }
    if (organizing_ && shift && (key == VK_UP || key == VK_DOWN)) { reorder(key == VK_DOWN ? 1 : -1); return true; }
    if (key == VK_UP || key == VK_DOWN || key == VK_PRIOR || key == VK_NEXT || key == VK_HOME || key == VK_END) { moveCursor(key == VK_UP ? -1 : key == VK_DOWN ? 1 : key == VK_PRIOR ? -19 : key == VK_NEXT ? 19 : key == VK_HOME ? -1000000 : 1000000); return true; }
    if (key == VK_RETURN) { activate(); return true; }
    return false;
}
bool Launcher::character(wchar_t value) {
    if (busy_) return true;
    if (input_ == TerminalInput::calc && !prompt_) {
        if (value == L'=') { submitCalc(); return true; }
        if (value == L':') { setInput(TerminalInput::command); return true; }
        if (value == L'c' || value == L'C') { copyCalc(); return true; }
        if (value < 32) return false;
        return std::wstring_view(L"0123456789+-*/().eE （）").find(value) == std::wstring_view::npos;
    }
    if (textInputActive()) return false;
    if (prompt_) { if (prompt_->command == "delete") { if (value == L'y' || value == L'Y') confirmDelete(); else if (value == L'n' || value == L'N') finishPrompt(); } return true; }
    if (value == L':') { historyIndex_ = -1; historyDraft_.clear(); completionPrefix_.clear(); lastCompletion_.clear(); setInput(TerminalInput::command); return true; }
    if (buffer_ == TerminalBuffer::settings) return true;
    if (value == L'/') { startSearch(); return true; }
    if (value == L'?') { openBuffer(TerminalBuffer::help); return true; }
    if (buffer_ != TerminalBuffer::none) {
        if (value == L'j') scroll(1); else if (value == L'k') scroll(-1); else if (value == L'g') scroll(-1000000); else if (value == L'G') scroll(1000000);
        return true;
    }
    switch (value) {
    case L'j': moveCursor(1); break; case L'k': moveCursor(-1); break; case L'g': moveCursor(-1000000); break; case L'G': moveCursor(1000000); break;
    case L'J': if (organizing_) reorder(1); break; case L'K': if (organizing_) reorder(-1); break;
    case L'a': beginAction("add"); break; case L'n': beginAction("mkdir"); break; case L'e': beginAction("edit"); break; case L'r': beginAction("rename"); break;
    case L'm': beginAction("move"); break; case L'D': beginAction("delete"); break; case L'c': case L'C': copySelection(); break;
    case L'o': if (!trim(query_).empty()) notify("搜索结果不能排序；先按 Esc 清空搜索。", true); else { organizing_ = !organizing_; invalidate(); } break;
    case L'z': toggleAll(); break; case L',': openBuffer(TerminalBuffer::settings); break;
    default: return false;
    }
    return true;
}
int Launcher::hitRow(float x, float y) const { if (buffer_ != TerminalBuffer::none || x < 40 || x >= 1400 || y < 24 || y >= 632) return -1; int row = scroll_ + static_cast<int>((y - 24) / 32); return row < static_cast<int>(rows_.size()) ? row : -1; }
void Launcher::click(float x, float y, bool activateRow) {
    if (busy_) return;
    if (y >= 752 && y < 792) { if (textInputActive()) SetFocus(search_); else if (!prompt_) setInput(buffer_ == TerminalBuffer::calc ? TerminalInput::calc : TerminalInput::command, buffer_ == TerminalBuffer::calc ? calcExpression_ : ""); return; }
    if (prompt_) {
        if (y >= 690 && y < 732 && !prompt_->choices.empty()) chooseOption(std::max(0, prompt_->selected - 2) + static_cast<int>((y - 690) / 14));
        return;
    }
    if (input_ == TerminalInput::command && y >= 690 && y < 738 && !commandHints_.empty()) { int index = static_cast<int>((y - 690) / 16); if (index < static_cast<int>(commandHints_.size())) { auto value = commandHints_[index].id; setInput(TerminalInput::command, value); } return; }
    if (buffer_ == TerminalBuffer::help && x >= 64 && x < 1010) {
        if (y >= 162 && y < 582) { int index = bufferOffset_ + static_cast<int>((y - 162) / 20); if (index < static_cast<int>(helpCommands_.size())) setInput(TerminalInput::command, helpCommands_[index].id); return; }
        if (y >= 618 && y < 720 && input_ != TerminalInput::command) { static const char* examples[]{"add", "edit url", "delete", "set corner right-up", "backup", "calc"}; int index = static_cast<int>((y - 618) / 17); if (index < 6) setInput(TerminalInput::command, examples[index]); return; }
    }
    if (buffer_ == TerminalBuffer::calc && y >= 205 && y < 621) { selectCalc(bufferOffset_ + static_cast<int>((y - 205) / 26)); return; }
    if (y >= 666 && y < 688 && x >= 1270) { openBuffer(TerminalBuffer::log); return; }
    int row = hitRow(x, y); if (row < 0) return;
    selection_ = row; setInput(TerminalInput::none); clampSelection();
    if (organizing_ && !rows_[row].folder && x >= 46 && x < 88) { beginAction("delete"); return; }
    if (activateRow || (rows_[row].folder && x >= 70 && x < 96)) { activate(); return; }
    if (organizing_ && !rows_[row].folder && query_.empty()) { dragSource_ = rows_[row].id; dragExpected_ = snapshot_.bytes; dragX_ = x; dragY_ = y; SetCapture(window_); }
    syncAccessibility(); invalidate();
}
void Launcher::dragMove(float x, float y) {
    if (dragSource_.empty() || busy_ || prompt_) return;
    if (std::hypot(x - dragX_, y - dragY_) > 5) dragging_ = true;
    if (!dragging_) return;
    dragCurrentX_ = x; dragCurrentY_ = y;
    if (y < 30) scroll(-1); else if (y > 626) scroll(1);
    int next = hitRow(x, y); if (next >= 0 && rows_[next].id == dragSource_) next = -1;
    float dy = next < 0 ? 0 : y - 24 - (next - scroll_) * 32;
    auto source = snapshot_.document.bookmark(dragSource_);
    bool merge = next >= 0 && source && !source->groupId && !rows_[next].folder && !rows_[next].group && dy >= 9 && dy <= 23;
    bool before = dy < 16;
    if (next != dragTarget_ || merge != dragMerge_ || before != dragBefore_) {
        dragTarget_ = next; dragMerge_ = merge; dragBefore_ = before; mergeReady_ = false; dragHoverSince_ = milliseconds();
    }
    SetTimer(window_, 7, 80, nullptr); invalidate();
}
void Launcher::dragEnd(float x, float y) {
    auto source = dragSource_, expected = dragExpected_; bool active = dragging_, merge = dragMerge_ && mergeReady_, before = dragBefore_;
    int target = hitRow(x, y); cancelDrag();
    if (!active || target < 0 || busy_ || prompt_) return;
    auto from = snapshot_.document.bookmark(source); const auto row = rows_[target];
    if (!from || source == row.id) return;
    auto selection = std::make_shared<std::string>(source); auto destination = std::make_shared<Location>();
    mutate([source, row, merge, before, selection, destination](Document& data) {
        auto bookmark = data.bookmark(source); require(bookmark != nullptr, "书签已不存在。");
        if (merge) {
            auto targetBookmark = data.bookmark(row.id); require(!bookmark->groupId && targetBookmark && !targetBookmark->groupId, "仅可将两条根目录书签合并。");
            std::string name = "新建文件夹"; int suffix = 2;
            while (std::any_of(data.groups.begin(), data.groups.end(), [&](const auto& group) { return group.name == name; })) name = "新建文件夹 " + std::to_string(suffix++);
            auto group = data.addGroup(name); data.move(row.id, group); data.move(source, group); *selection = group; *destination = group; return;
        }
        if (row.folder) { require(data.group(row.id) != nullptr, "目标文件夹已不存在。"); *destination = row.id; data.move(source, row.id); return; }
        auto targetBookmark = data.bookmark(row.id); require(targetBookmark != nullptr, "拖拽目标已改变，请重试。"); *destination = targetBookmark->groupId;
        auto peers = data.items(*destination); std::vector<std::string> ids;
        for (const auto& item : peers) if (!item.folder && item.id != source) ids.push_back(item.id);
        auto at = std::find(ids.begin(), ids.end(), row.id); require(at != ids.end(), "拖拽目标已改变。");
        if (!before) ++at; data.move(source, *destination, at == ids.end() ? "" : *at);
    }, [this, selection, destination] { if (*destination) expanded_.insert(**destination); persistExpanded(); rebuildItems(*selection); appendLog("已移动书签", green); }, expected);
}
void Launcher::cancelDrag() { KillTimer(window_, 7); dragSource_.clear(); dragExpected_.clear(); dragging_ = false; dragTarget_ = -1; dragMerge_ = mergeReady_ = false; if (GetCapture() == window_) ReleaseCapture(); invalidate(); }
void Launcher::updateHover(float x, float y) {
    if (!tooltip_) return;
    int index = buffer_ == TerminalBuffer::settings && x >= 130 && x < 1390 && y >= 106 && y < 726 ? bufferOffset_ + static_cast<int>((y - 106) / 20) : -1;
    if (index >= static_cast<int>(bufferLines_.size())) index = -1;
    if (index == hoverBuffer_) return; hoverBuffer_ = index;
    TOOLINFOW tool{sizeof(tool)}; tool.hwnd = window_; tool.uId = 1;
    SendMessageW(tooltip_, TTM_TRACKACTIVATE, FALSE, reinterpret_cast<LPARAM>(&tool));
    if (index >= 0) {
        tooltipText_ = wide(bufferLines_[index].text); std::replace(tooltipText_.begin(), tooltipText_.end(), L'\t', L' '); tool.lpszText = tooltipText_.data();
        SendMessageW(tooltip_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool)); POINT point{}; GetCursorPos(&point);
        SendMessageW(tooltip_, TTM_TRACKPOSITION, 0, MAKELPARAM(point.x + 12, point.y + 22)); SendMessageW(tooltip_, TTM_TRACKACTIVATE, TRUE, reinterpret_cast<LPARAM>(&tool));
        TRACKMOUSEEVENT tracking{sizeof(tracking), TME_LEAVE, window_, 0}; TrackMouseEvent(&tracking);
    }
}
void Launcher::syncAccessibility() {
    if (!window_) return;
    std::vector<AccessibleNode> nodes; accessibleActions_.clear(); POINT origin{}; ClientToScreen(window_, &origin);
    auto add = [&](const std::string& key, const std::string& name, const std::string& help, Rect rect, bool selected, bool folder, bool enabled) {
        auto [it, inserted] = accessibleTokens_.try_emplace(key, nextToken_); if (inserted) ++nextToken_;
        int token = it->second; accessibleActions_[token] = key;
        RECT bounds{origin.x + static_cast<LONG>(originX_ + rect.x * scale_), origin.y + static_cast<LONG>(originY_ + rect.y * scale_), origin.x + static_cast<LONG>(originX_ + (rect.x + rect.width) * scale_), origin.y + static_cast<LONG>(originY_ + (rect.y + rect.height) * scale_)};
        nodes.push_back({token, wide(name), wide(help), bounds, selected, enabled, folder});
    };
    if (buffer_ == TerminalBuffer::none) for (int i = scroll_; i < std::min(static_cast<int>(rows_.size()), scroll_ + 19); ++i) {
        const auto& row = rows_[i]; auto b = snapshot_.document.bookmark(row.id);
        add(row.id, row.title, row.folder ? row.detail + (row.expanded ? " 已展开" : " 已折叠") : b ? b->url : row.detail, {40, 24.0f + (i - scroll_) * 32, 1360, 32}, i == selection_, row.folder, !busy_ && !prompt_);
    }
    if (prompt_) {
        add("prompt", promptLabel(), prompt_->error.empty() ? prompt_->hint : prompt_->error, {40, 664, 1360, 24}, false, false, false);
        int start = std::max(0, prompt_->selected - 2);
        for (int i = start; i < std::min(static_cast<int>(prompt_->choices.size()), start + 3); ++i) add("choice:" + std::to_string(i), prompt_->choices[i].label, prompt_->choices[i].detail, {40, 690.0f + (i - start) * 14, 1360, 14}, i == prompt_->selected, false, !busy_);
    }
    if (!prompt_ && input_ == TerminalInput::command) for (size_t i = 0; i < commandHints_.size(); ++i) add("suggest:" + commandHints_[i].id, ":" + commandHints_[i].id, commandHints_[i].label, {40, 690.0f + static_cast<float>(i) * 16, 1360, 16}, false, false, !busy_);
    if (buffer_ == TerminalBuffer::calc) {
        add("calc-result", calcError_.empty() ? "结果 " + calcPreview_ : calcError_, "计算器", {72, 84, 1296, 64}, false, false, false);
        if (!calcFeedback_.empty()) add("calc-feedback", calcFeedback_, "计算器操作反馈", {890, 757, 510, 32}, false, false, false);
        for (int i = bufferOffset_; i < std::min(static_cast<int>(calcHistory_.size()), bufferOffset_ + 16); ++i) add("calc:" + std::to_string(i), calcHistory_[i].expression + " = " + calcHistory_[i].value, "点击载入算式", {64, 205.0f + (i - bufferOffset_) * 26, 1312, 22}, i == calcHistoryIndex_, false, !busy_ && !prompt_);
    } else if (buffer_ == TerminalBuffer::help) {
        add("help-name", "NAME 青蛙导航 — 本地书签启动台", "SYNOPSIS frog [command]", {64, 72, 1336, 54}, false, false, false);
        for (int i = bufferOffset_; i < std::min(static_cast<int>(helpCommands_.size()), bufferOffset_ + 21); ++i) add("complete:" + helpCommands_[i].id, helpCommands_[i].detail, helpCommands_[i].label, {64, 162.0f + (i - bufferOffset_) * 20, 946, 20}, false, false, !busy_ && !prompt_);
        add("help-files", "FILES: " + utf8((preferences_.dataDirectory / L"bookmarks.json").wstring()), "当前JSON文件", {64, 716, 1336, 20}, false, false, false);
    } else if (buffer_ != TerminalBuffer::none) {
        const auto& lines = buffer_ == TerminalBuffer::log ? logs_ : buffer_ == TerminalBuffer::job ? jobLines_ : bufferLines_;
        int capacity = buffer_ == TerminalBuffer::settings ? 31 : buffer_ == TerminalBuffer::job ? 25 : 32;
        float top = buffer_ == TerminalBuffer::settings ? 106.0f : buffer_ == TerminalBuffer::job ? 110.0f : 74.0f;
        for (int i = bufferOffset_; i < std::min(static_cast<int>(lines.size()), bufferOffset_ + capacity); ++i) add("buffer:" + std::to_string(i), lines[i].text, lines[i].time, {72, top + (i - bufferOffset_) * 20, 1328, 20}, false, false, false);
    }
    add("status", modeLabel(), shortcuts(), {0, 796, 1440, 36}, false, false, false);
    if (!logs_.empty() && !prompt_ && (buffer_ == TerminalBuffer::none || input_ == TerminalInput::command)) add("output", logs_.back().text, "最近操作日志", {40, 664, 1360, 72}, false, false, false);
    int focus = 0; for (const auto& node : nodes) if (node.selected) { focus = node.token; break; }
    { std::lock_guard lock(accessibility_->mutex); accessibility_->nodes = std::move(nodes); accessibility_->focus = focus; }
    diagnostics_.event("terminal_state", {{"mode", modeLabel()}, {"input", inputText_}, {"prompt", prompt_ ? prompt_->command : ""}, {"field", prompt_ ? prompt_->field : ""}, {"step", prompt_ ? prompt_->step : 0}, {"selection", selection_}, {"rows", rows_.size()}, {"buffer", bufferName(buffer_)}, {"busy", busy_}, {"issue", issue_}, {"error", prompt_ ? prompt_->error : calcError_}});
}
void Launcher::accessibleAction(int token, bool focusOnly) {
    auto it = accessibleActions_.find(token); if (it == accessibleActions_.end() || busy_) return; auto id = it->second;
    if (id.starts_with("suggest:")) { if (!prompt_) setInput(TerminalInput::command, id.substr(8)); return; }
    if (id.starts_with("complete:")) { if (!prompt_) setInput(TerminalInput::command, id.substr(9)); return; }
    if (id.starts_with("choice:")) { if (prompt_) chooseOption(std::stoi(id.substr(7))); return; }
    if (id.starts_with("calc:")) { if (!prompt_) selectCalc(std::stoi(id.substr(5))); return; }
    if (prompt_ || buffer_ != TerminalBuffer::none) return;
    for (size_t i = 0; i < rows_.size(); ++i) if (rows_[i].id == id) { selection_ = static_cast<int>(i); setInput(TerminalInput::none); clampSelection(); if (!focusOnly) activate(); syncAccessibility(); invalidate(); break; }
}
LRESULT CALLBACK Launcher::controlProc(HWND window, UINT msg, WPARAM w, LPARAM l, UINT_PTR, DWORD_PTR ref) {
    auto* self = reinterpret_cast<Launcher*>(ref);
    try {
        // UIA/COM 可运行嵌套消息泵；按键必须在控件过程处理，不能只依赖主循环。
        if ((msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) && self->keyboard(w, (GetKeyState(VK_CONTROL) & 0x8000) != 0, (GetKeyState(VK_SHIFT) & 0x8000) != 0)) return 0;
        if (msg == WM_CHAR && !self->composing_ && (w == VK_RETURN || w == VK_TAB || w == VK_ESCAPE)) return 0;
        if (msg == WM_IME_STARTCOMPOSITION) self->composing_ = true;
        if (msg == WM_IME_ENDCOMPOSITION) { self->composing_ = false; auto result = DefSubclassProc(window, msg, w, l); self->inputChanged(); return result; }
        if (msg == WM_CHAR && !self->composing_ && self->character(static_cast<wchar_t>(w))) return 0;
        if (msg == WM_NCDESTROY) RemoveWindowSubclass(window, controlProc, 1);
    } catch (const std::exception& e) { self->notify(e.what(), true); return 0; }
    return DefSubclassProc(window, msg, w, l);
}
LRESULT CALLBACK Launcher::windowProc(HWND window, UINT msg, WPARAM w, LPARAM l) {
    auto* self = reinterpret_cast<Launcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (msg == WM_NCCREATE) { self = static_cast<Launcher*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self)); self->window_ = window; }
    if (self) try { return self->message(msg, w, l); } catch (const std::exception& e) { self->notify(e.what(), true); return 0; }
    return DefWindowProcW(window, msg, w, l);
}
LRESULT Launcher::message(UINT msg, WPARAM w, LPARAM l) {
    auto x = [&] { return (GET_X_LPARAM(l) - originX_) / scale_; }; auto y = [&] { return (GET_Y_LPARAM(l) - originY_) / scale_; };
    switch (msg) {
    case WM_PAINT: paint(); return 0; case WM_ERASEBKGND: return 1;
    case WM_CLOSE: hide(); return 0;
    case WM_SYSCOMMAND: if ((w & 0xfff0) == SC_MINIMIZE || (w & 0xfff0) == SC_CLOSE) { hide(); return 0; } break;
    case WM_ACTIVATE: if (LOWORD(w) == WA_INACTIVE && visible_ && !inMenu_ && !sameProcess(reinterpret_cast<HWND>(l))) hide(); return 0;
    case WM_SIZE: if (w == SIZE_MINIMIZED) hide(); else updateLayout(); return 0;
    case WM_DPICHANGED: releaseRenderer(); place(false); return 0;
    case WM_DISPLAYCHANGE: case WM_SETTINGCHANGE: if (visible_) place(false); return 0;
    case WM_COMMAND: if (LOWORD(w) == 10 && HIWORD(w) == EN_CHANGE) inputChanged(); return 0;
    case WM_CTLCOLOREDIT: case WM_CTLCOLORSTATIC: { auto dc = reinterpret_cast<HDC>(w); SetTextColor(dc, RGB(15, 26, 32)); SetBkColor(dc, RGB(255, 254, 248)); return reinterpret_cast<LRESULT>(editBrush_); }
    case WM_LBUTTONDOWN: click(x(), y(), false); return 0; case WM_LBUTTONDBLCLK: click(x(), y(), true); return 0;
    case WM_MOUSEMOVE: updateHover(x(), y()); dragMove(x(), y()); return 0; case WM_LBUTTONUP: dragEnd(x(), y()); return 0;
    case WM_MOUSELEAVE: updateHover(-1, -1); return 0;
    case WM_CAPTURECHANGED: if (!dragSource_.empty()) cancelDrag(); return 0;
    case WM_CONTEXTMENU: { POINT point{GET_X_LPARAM(l), GET_Y_LPARAM(l)}; if (point.x == -1) GetCursorPos(&point); else { POINT client = point; ScreenToClient(window_, &client); int row = hitRow((client.x - originX_) / scale_, (client.y - originY_) / scale_); if (row >= 0 && !prompt_) { selection_ = row; setInput(TerminalInput::none); } } menu(point); return 0; }
    case WM_MOUSEWHEEL: wheel_ -= GET_WHEEL_DELTA_WPARAM(w); while (std::abs(wheel_) >= WHEEL_DELTA) { int direction = wheel_ > 0 ? 1 : -1; scroll(direction * 3); wheel_ -= direction * WHEEL_DELTA; } return 0;
    case WM_TIMER:
        if (w == timerCalcFeedback) { KillTimer(window_, timerCalcFeedback); calcFeedback_.clear(); layoutInput(); invalidate(); }
        else if (w == 7 && dragging_) { if (dragCurrentY_ < 30 || dragCurrentY_ > 626) dragMove(dragCurrentX_, dragCurrentY_); if (dragMerge_ && milliseconds() - dragHoverSince_ >= 550) mergeReady_ = true; invalidate(); }
        else if (w == 8) { KillTimer(window_, 8); cornerFlashUntil_ = 0; invalidate(); }
        return 0;
    case WM_GETOBJECT: if (static_cast<LONG>(l) == UiaRootObjectId && provider_) return UiaReturnRawElementProvider(window_, w, l, provider_.Get()); break;
    case wmAccessibleInvoke: accessibleAction(static_cast<int>(w), l != 0); return 0;
    case WM_GETDLGCODE: return DLGC_WANTARROWS | DLGC_WANTCHARS;
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
        if (keyboard(w, (GetKeyState(VK_CONTROL) & 0x8000) != 0, (GetKeyState(VK_SHIFT) & 0x8000) != 0)) return 0;
        break;
    case WM_CHAR: character(static_cast<wchar_t>(w)); return 0;
    }
    return DefWindowProcW(window_, msg, w, l);
}
}
