#include "platform/Integration.h"
#include <UIAutomation.h>
#include <wincodec.h>
#include <dwmapi.h>
#include <algorithm>
#include <iostream>
#include <iterator>
#include <utility>
#include <string_view>
#include <wrl/implements.h>
#include <atomic>
#include <mutex>

using namespace frog;
namespace {
void expect(bool value, const char* message) { require(value, message); }

bool waitFor(const std::function<bool()>& condition, int timeout = 7000) {
    const auto started = milliseconds();
    do {
        if (condition()) return true;
        Sleep(25);
    } while (milliseconds() - started < timeout);
    return false;
}

std::vector<Json> events(const fs::path& path, const char* name) {
    std::vector<Json> result;
    std::ifstream input(path);
    for (std::string line; std::getline(input, line);) {
        auto event = Json::parse(line, nullptr, false);
        if (!event.is_discarded() && event.value("event", "") == name) result.push_back(std::move(event));
    }
    return result;
}

HWND findWindow(DWORD process, const wchar_t* className) {
    struct Context { DWORD process; const wchar_t* className; HWND found{}; } context{process, className};
    EnumWindows([](HWND window, LPARAM value) -> BOOL {
        auto& context = *reinterpret_cast<Context*>(value);
        DWORD process{};
        GetWindowThreadProcessId(window, &process);
        wchar_t name[128]{};
        GetClassNameW(window, name, static_cast<int>(std::size(name)));
        if (process == context.process && _wcsicmp(name, context.className) == 0) {
            context.found = window;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&context));
    return context.found;
}

PROCESS_INFORMATION launch(const std::wstring& command) {
    auto writable = command;
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    expect(CreateProcessW(nullptr, writable.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process), "无法启动真实测试进程");
    CloseHandle(process.hThread);
    return process;
}

void foreground(HWND window) {
    if (IsWindowVisible(window) && GetForegroundWindow() == window) return;
    // 测试由后台 CTest 启动；真实 Alt 按键解除 Windows 前台锁后再切换。
    INPUT unlock[2]{}; unlock[0].type = unlock[1].type = INPUT_KEYBOARD;
    unlock[0].ki.wVk = unlock[1].ki.wVk = VK_LMENU;
    unlock[0].ki.wScan = unlock[1].ki.wScan = static_cast<WORD>(MapVirtualKeyW(VK_LMENU, MAPVK_VK_TO_VSC));
    unlock[1].ki.dwFlags = KEYEVENTF_KEYUP;
    expect(SendInput(2, unlock, sizeof(INPUT)) == 2, "无法为交互验收取得前台输入权限");
    SetForegroundWindow(window);
    expect(waitFor([&] { return IsWindowVisible(window) && GetForegroundWindow() == window; }), "测试需要可交互桌面，终端未取得前台焦点");
}

std::wstring remoteText(HWND window) {
    DWORD_PTR length{};
    expect(SendMessageTimeoutW(window, WM_GETTEXTLENGTH, 0, 0, SMTO_ABORTIFHUNG, 3000, &length) != 0, "输入框无响应");
    std::wstring result(static_cast<size_t>(length) + 1, L'\0');
    DWORD_PTR actual{};
    expect(SendMessageTimeoutW(window, WM_GETTEXT, result.size(), reinterpret_cast<LPARAM>(result.data()), SMTO_ABORTIFHUNG, 3000, &actual) != 0, "无法读取输入框");
    result.resize(static_cast<size_t>(actual));
    return result;
}

void send(std::vector<INPUT>& input) {
    expect(SendInput(static_cast<UINT>(input.size()), input.data(), sizeof(INPUT)) == input.size(), "真实键盘或鼠标输入失败");
}

void key(WORD code, WORD modifier = 0, WORD secondModifier = 0) {
    std::vector<INPUT> input;
    auto append = [&](WORD value, bool up) {
        if (value == VK_SHIFT) value = VK_LSHIFT;
        else if (value == VK_CONTROL) value = VK_LCONTROL;
        else if (value == VK_MENU) value = VK_LMENU;
        INPUT event{};
        event.type = INPUT_KEYBOARD;
        event.ki.wVk = value;
        event.ki.wScan = static_cast<WORD>(MapVirtualKeyW(value, MAPVK_VK_TO_VSC));
        event.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
        if ((value >= VK_PRIOR && value <= VK_DOWN) || value == VK_INSERT || value == VK_DELETE) event.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
        input.push_back(event);
    };
    if (modifier) append(modifier, false);
    if (secondModifier) append(secondModifier, false);
    append(code, false);
    append(code, true);
    if (secondModifier) append(secondModifier, true);
    if (modifier) append(modifier, true);
    send(input);
}

void type(const std::wstring& value) {
    std::vector<INPUT> input;
    input.reserve(value.size() * 2);
    for (const auto character : value) {
        INPUT event{};
        event.type = INPUT_KEYBOARD;
        event.ki.wScan = character;
        event.ki.dwFlags = KEYEVENTF_UNICODE;
        input.push_back(event);
        event.ki.dwFlags |= KEYEVENTF_KEYUP;
        input.push_back(event);
    }
    if (!input.empty()) send(input);
}

void click(POINT point) {
    // 连续搜索结果位于同一屏幕位置；按系统阈值分隔单击，避免误触双击打开网址。
    static ULONGLONG previousTime = 0; static POINT previousPoint{};
    auto elapsed = GetTickCount64() - previousTime;
    const auto interval = static_cast<ULONGLONG>(GetDoubleClickTime()) + 50;
    if (previousTime && std::abs(point.x - previousPoint.x) <= GetSystemMetrics(SM_CXDOUBLECLK) &&
        std::abs(point.y - previousPoint.y) <= GetSystemMetrics(SM_CYDOUBLECLK) && elapsed < interval)
        Sleep(static_cast<DWORD>(interval - elapsed));
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    expect(width > 1 && height > 1, "无法获取交互桌面尺寸");
    std::vector<INPUT> input(3);
    for (auto& event : input) event.type = INPUT_MOUSE;
    input[0].mi.dx = static_cast<LONG>((static_cast<int64_t>(point.x - left) * 65535) / (width - 1));
    input[0].mi.dy = static_cast<LONG>((static_cast<int64_t>(point.y - top) * 65535) / (height - 1));
    input[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    input[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    input[2].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    send(input);
    previousTime = GetTickCount64(); previousPoint = point;
}

ComPtr<IUIAutomationElement> named(IUIAutomation* automation, IUIAutomationElement* root, const wchar_t* name) {
    VARIANT value{};
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(name);
    expect(value.bstrVal != nullptr, "无法分配 UIA 名称");
    ScopeExit release{[&] { VariantClear(&value); }};
    ComPtr<IUIAutomationCondition> condition;
    check(automation->CreatePropertyCondition(UIA_NamePropertyId, value, &condition), "无法创建 UIA 查询");
    ComPtr<IUIAutomationElement> result;
    check(root->FindFirst(TreeScope_Descendants, condition.Get(), &result), "UIA 查询失败");
    return result;
}

void clickElement(IUIAutomationElement* element) {
    expect(element != nullptr, "UIA 未找到目标条目");
    RECT rectangle{};
    check(element->get_CurrentBoundingRectangle(&rectangle), "UIA 没有条目坐标");
    expect(rectangle.right > rectangle.left && rectangle.bottom > rectangle.top, "UIA 条目不可见");
    click({rectangle.left + (rectangle.right - rectangle.left) / 2, rectangle.top + (rectangle.bottom - rectangle.top) / 2});
}
void dragElement(IUIAutomationElement* source, IUIAutomationElement* target, bool hoverWithMotion = false) {
    expect(source && target, "拖动源或目标不可见"); RECT from{}, to{};
    check(source->get_CurrentBoundingRectangle(&from), "无法读取拖动源");
    check(target->get_CurrentBoundingRectangle(&to), "无法读取拖动目标");
    const int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    const int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    std::vector<INPUT> input(4); for (auto& event : input) event.type = INPUT_MOUSE;
    auto point = [&](INPUT& event, const RECT& bounds) {
        event.mi.dx = static_cast<LONG>((static_cast<int64_t>((bounds.left + bounds.right) / 2 - left) * 65535) / (width - 1));
        event.mi.dy = static_cast<LONG>((static_cast<int64_t>((bounds.top + bounds.bottom) / 2 - top) * 65535) / (height - 1));
        event.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    };
    point(input[0], from); input[1].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    point(input[2], to); input[3].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    if (!hoverWithMotion) { send(input); return; }
    INPUT release = input.back(); input.pop_back(); send(input);
    ScopeExit releaseMouse{[&] { SendInput(1, &release, sizeof(INPUT)); }};
    // 始终在合并热区内微动，间隔小于拖动定时器；不能因重设计时器或跨中线而失去悬停。
    for (int i = 0; i < 50; ++i) {
        RECT jitter = to; const int offset = (i % 2) ? 1 : -1;
        jitter.top += offset; jitter.bottom += offset;
        INPUT move{}; move.type = INPUT_MOUSE; point(move, jitter);
        expect(SendInput(1, &move, sizeof(INPUT)) == 1, "无法发送拖动悬停微动"); Sleep(20);
    }
}

void invoke(IUIAutomationElement* element) {
    expect(element != nullptr, "UIA 未找到可调用条目");
    ComPtr<IUIAutomationInvokePattern> pattern;
    check(element->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&pattern)), "条目没有 UIA Invoke 接口");
    check(pattern->Invoke(), "UIA Invoke 失败");
}

std::wstring clipboardText() {
    if (!OpenClipboard(nullptr)) return {};
    ScopeExit close{[] { CloseClipboard(); }};
    auto memory = GetClipboardData(CF_UNICODETEXT);
    if (!memory) return {};
    auto text = static_cast<const wchar_t*>(GlobalLock(memory));
    if (!text) return {};
    ScopeExit unlock{[&] { GlobalUnlock(memory); }};
    return text;
}

// 截图编码完全独立于应用渲染实现，不依赖已退役的图片缓存模块。
void capture(HWND window, const fs::path& destination) {
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    DwmFlush();
    RECT rectangle{};
    expect(GetClientRect(window, &rectangle) != FALSE, "无法读取截图区域");
    const UINT width = static_cast<UINT>(rectangle.right), height = static_cast<UINT>(rectangle.bottom);
    expect(width && height, "截图区域为空");
    HDC source = GetDC(window);
    expect(source != nullptr, "无法读取窗口画面");
    ScopeExit releaseSource{[&] { ReleaseDC(window, source); }};
    HDC memory = CreateCompatibleDC(source);
    expect(memory != nullptr, "无法创建截图设备");
    ScopeExit releaseMemory{[&] { DeleteDC(memory); }};
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = static_cast<LONG>(width);
    info.bmiHeader.biHeight = -static_cast<LONG>(height);
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    void* raw{};
    HBITMAP bitmap = CreateDIBSection(source, &info, DIB_RGB_COLORS, &raw, nullptr, 0);
    expect(bitmap && raw, "无法分配截图位图");
    ScopeExit releaseBitmap{[&] { DeleteObject(bitmap); }};
    const auto old = SelectObject(memory, bitmap);
    ScopeExit restore{[&] { SelectObject(memory, old); }};
    expect(BitBlt(memory, 0, 0, width, height, source, 0, 0, SRCCOPY) != FALSE, "无法捕获终端画面");
    GdiFlush();
    auto pixels = static_cast<BYTE*>(raw);
    const UINT stride = width * 4, size = stride * height;
    for (size_t index = 3; index < size; index += 4) pixels[index] = 255;
    ComPtr<IWICImagingFactory> factory;
    check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)), "WIC 初始化失败");
    ComPtr<IWICStream> stream;
    check(factory->CreateStream(&stream), "无法创建 PNG 流");
    check(stream->InitializeFromFilename(destination.c_str(), GENERIC_WRITE), "无法创建截图文件");
    ComPtr<IWICBitmapEncoder> encoder;
    check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder), "无法创建 PNG 编码器");
    check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), "无法初始化 PNG 编码器");
    ComPtr<IWICBitmapFrameEncode> frame;
    check(encoder->CreateNewFrame(&frame, nullptr), "无法创建 PNG 帧");
    check(frame->Initialize(nullptr), "无法初始化 PNG 帧");
    check(frame->SetSize(width, height), "无法设置 PNG 尺寸");
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    check(frame->SetPixelFormat(&format), "无法设置 PNG 像素格式");
    expect(IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA), "PNG 编码器不支持截图像素格式");
    check(frame->WritePixels(height, stride, size, pixels), "PNG 写入失败");
    check(frame->Commit(), "PNG 帧提交失败");
    check(encoder->Commit(), "PNG 截图提交失败");
}

class Terminal {
public:
    Terminal(HWND window, fs::path log) : window_(window), input_(GetDlgItem(window, 10)), log_(std::move(log)) {
        expect(input_ != nullptr, "终端缺少原生命令输入框");
        check(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation_)), "UIA 初始化失败");
        check(automation_->ElementFromHandle(window_, &root_), "UIA 无法读取终端");
    }

    Json state() const {
        const auto values = events(log_, "terminal_state");
        return values.empty() ? Json::object() : values.back();
    }
    void stateIs(const std::function<bool(const Json&)>& predicate, const char* message) const {
        expect(waitFor([&] { return predicate(state()); }), message);
    }
    void field(const char* prompt, const char* field) const {
        stateIs([&](const Json& value) {
            return value.value("prompt", "") == prompt && value.value("field", "") == field && !value.value("busy", false);
        }, "提示流未到达预期字段");
    }
    void idle() const {
        stateIs([](const Json& value) { return value.contains("prompt") && value.value("prompt", "").empty() && !value.value("busy", false); }, "终端操作未结束");
    }
    ComPtr<IUIAutomationElement> element(const wchar_t* name) const { return named(automation_.Get(), root_.Get(), name); }
    void inputIs(const std::wstring& value) const {
        expect(waitFor([&] { return remoteText(input_) == value; }), "输入框内容与真实键盘输入不一致");
    }
    void replace(const std::wstring& value) const {
        key('A', VK_CONTROL);
        key(VK_BACK);
        type(value);
        inputIs(value);
    }
    void command(const std::wstring& value) const {
        if (IsWindowVisible(input_) && state().value("mode", "") == "SEARCH") {
            key(VK_ESCAPE);
            stateIs([](const Json& value) { return value.value("mode", "") != "SEARCH"; }, "无法结束搜索输入");
        }
        type(L":");
        type(value);
        inputIs(value);
        ComPtr<IUIAutomationElement> inputElement;
        check(automation_->ElementFromHandle(input_, &inputElement), "UIA 无法访问正在编辑的命令行");
        ComPtr<IUIAutomationValuePattern> inputValue;
        check(inputElement->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&inputValue)), "命令行没有暴露可编辑文本");
        BSTR actual{}; check(inputValue->get_CurrentValue(&actual), "UIA 无法读取命令行文本");
        const bool accessibleValueMatches = actual && std::wstring(actual) == value;
        SysFreeString(actual); expect(accessibleValueMatches, "辅助功能读取的命令与可见输入不同");
        stateIs([&](const Json& state) { return state.value("mode", "") == "COMMAND" && state.value("input", "") == utf8(value); }, "真实命令输入未到达终端状态");
        key(VK_RETURN);
        if (value != L"q") stateIs([](const Json& state) { return state.value("mode", "") != "COMMAND"; }, "命令未被执行");
    }
    void select(const wchar_t* title) const {
        command(L"find " + std::wstring(title));
        ComPtr<IUIAutomationElement> row;
        expect(waitFor([&] { row = element(title); return row != nullptr; }), "搜索没有返回目标书签");
        clickElement(row.Get());
        focused(title);
    }
    void focused(const wchar_t* selected) const {
        expect(waitFor([&] {
            GUITHREADINFO info{sizeof(info)};
            if (!GetGUIThreadInfo(GetWindowThreadProcessId(window_, nullptr), &info) || info.hwndFocus != window_) return false;
            auto row = element(selected);
            BOOL focused{};
            return row && SUCCEEDED(row->get_CurrentHasKeyboardFocus(&focused)) && focused;
        }), "点击搜索结果后列表没有取得原生与 UIA 键盘焦点");
    }
    void buffer(const char* name) const {
        stateIs([&](const Json& value) { return value.value("buffer", "") == name && !value.value("busy", false); }, "终端没有显示目标缓冲区");
    }
    bool textVisible(const std::wstring& fragment) const {
        ComPtr<IUIAutomationCondition> condition;
        check(automation_->CreateTrueCondition(&condition), "无法枚举 UIA 可见文本");
        ComPtr<IUIAutomationElementArray> elements;
        check(root_->FindAll(TreeScope_Descendants, condition.Get(), &elements), "无法读取终端 UIA 内容");
        int count{};
        check(elements->get_Length(&count), "无法读取 UIA 条目数量");
        for (int index = 0; index < count; ++index) {
            ComPtr<IUIAutomationElement> element;
            check(elements->GetElement(index, &element), "无法读取 UIA 条目");
            BSTR name{};
            check(element->get_CurrentName(&name), "无法读取 UIA 文本");
            const bool found = name && std::wstring_view(name, SysStringLen(name)).find(fragment) != std::wstring_view::npos;
            SysFreeString(name);
            if (found) return true;
        }
        return false;
    }
    void job(const std::wstring& value) const {
        const auto saved = events(log_, "saved").size();
        command(value);
        expect(waitFor([&] { return events(log_, "saved").size() > saved; }), "真实文件操作没有完成成功事件");
        buffer("job");
        idle();
        expect(waitFor([&] { return textVisible(L"exit 0"); }), "文件任务没有显示成功退出结果");
    }
    void hideAndResume(HWND controller) const {
        const auto text = remoteText(input_);
        expect(!text.empty() && text.size() < 65536, "草稿选区验收需要非空短输入");
        key(VK_END);
        key(VK_LEFT, VK_SHIFT);
        LRESULT selection{};
        const bool selected = waitFor([&] {
            selection = SendMessageW(input_, EM_GETSEL, 0, 0);
            return LOWORD(selection) == text.size() - 1 && HIWORD(selection) == text.size();
        });
        if (!selected) {
            GUITHREADINFO info{sizeof(info)}; GetGUIThreadInfo(GetWindowThreadProcessId(window_, nullptr), &info);
            std::cerr << "selection=" << LOWORD(selection) << "," << HIWORD(selection) << " length=" << text.size() << " focusInput=" << (info.hwndFocus == input_) << " text=" << utf8(remoteText(input_)) << '\n';
        }
        expect(selected, "真实 Shift+Left 未建立草稿选区");
        const auto previous = state();
        key(VK_F4, VK_MENU);
        expect(waitFor([&] { return !IsWindowVisible(window_); }), "Alt+F4 没有收起终端");
        PostMessageW(controller, wmActivate, 0, 0);
        expect(waitFor([&] { return IsWindowVisible(window_); }), "控制器无法重新展开终端");
        foreground(window_);
        inputIs(text);
        stateIs([&](const Json& value) {
            return value.value("prompt", "") == previous.value("prompt", "") &&
                value.value("field", "") == previous.value("field", "") &&
                value.value("buffer", "") == previous.value("buffer", "");
        }, "收起改变了草稿模式或字段");
        expect(SendMessageW(input_, EM_GETSEL, 0, 0) == selection, "重新展开丢失草稿光标选区");
        key(VK_END);
    }
private:
    HWND window_{}, input_{};
    fs::path log_;
    ComPtr<IUIAutomation> automation_;
    ComPtr<IUIAutomationElement> root_;
};

Document document(const fs::path& directory) { return Document::decode(readFile(directory / L"bookmarks.json")); }

void awaitDocument(const fs::path& directory, const std::function<bool(const Document&)>& predicate, const char* message) {
    expect(waitFor([&] {
        try { return predicate(document(directory)); }
        catch (const std::exception&) { return false; }
    }), message);
}

const Bookmark* titled(const Document& data, const std::string& title) {
    const auto found = std::find_if(data.bookmarks.begin(), data.bookmarks.end(), [&](const Bookmark& bookmark) { return bookmark.title == title; });
    return found == data.bookmarks.end() ? nullptr : &*found;
}

class AccessibilityEvents final : public Microsoft::WRL::RuntimeClass<Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>, IUIAutomationFocusChangedEventHandler, IUIAutomationStructureChangedEventHandler> {
public:
    DWORD process{};
    std::atomic<bool> expanded{false};
    std::mutex mutex;
    std::wstring focused;
    bool matches(IUIAutomationElement* sender) const {
        int id{}; return sender && SUCCEEDED(sender->get_CurrentProcessId(&id)) && static_cast<DWORD>(id) == process;
    }
    HRESULT STDMETHODCALLTYPE HandleFocusChangedEvent(IUIAutomationElement* sender) override {
        if (!matches(sender)) return S_OK;
        BSTR id{}, name{};
        if (SUCCEEDED(sender->get_CurrentAutomationId(&id)) && id && std::wstring_view(id).starts_with(L"Frog.Item.") && SUCCEEDED(sender->get_CurrentName(&name))) {
            std::lock_guard lock(mutex); focused = name ? name : L"";
        }
        SysFreeString(id); SysFreeString(name); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE HandleStructureChangedEvent(IUIAutomationElement* sender, StructureChangeType type, SAFEARRAY*) override {
        if (!matches(sender) || type != StructureChangeType_ChildrenInvalidated) return S_OK;
        // 回调内重新查询树，既检查已发布的新结构，也覆盖Provider锁重入。
        ComPtr<IUIAutomation> automation;
        if (SUCCEEDED(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)))) {
            try { if (named(automation.Get(), sender, L"文件夹中的中文书签")) expanded = true; } catch (const std::exception&) {}
        }
        return S_OK;
    }
    bool focusedOn(const wchar_t* name) { std::lock_guard lock(mutex); return focused == name; }
};

void reviewRegressions(Terminal& terminal, HWND window, HANDLE process, const fs::path& directory, const fs::path& log, const Document& seed, const std::string& first, const std::string& second) {
    terminal.select(L"排序甲");
    terminal.command(L"delete"); terminal.field("delete", "confirm"); key('N');
    terminal.command(L"help"); terminal.buffer("help");
    expect(document(directory) == seed, "小写n取消删除修改了书签");
    key(VK_ESCAPE); terminal.buffer("");
    std::cout << "PASS delete-lowercase-n-cancels-without-new-prompt\n";

    terminal.command(L"add"); terminal.field("add", "url"); terminal.replace(L"https://example.com/");
    key('Q', VK_CONTROL, VK_MENU); type(L"sentinel");
    expect(waitFor([&] { return WaitForSingleObject(process, 0) == WAIT_OBJECT_0 || terminal.state().value("input", "").ends_with("sentinel"); }), "AltGr组合后的输入未到达草稿");
    expect(WaitForSingleObject(process, 0) == WAIT_TIMEOUT, "AltGr+Q错误触发了退出");
    terminal.field("add", "url");
    expect(terminal.state().value("input", "").starts_with("https://example.com/"), "AltGr输入丢失原始草稿");
    key(VK_ESCAPE); terminal.idle();
    std::cout << "PASS altgr-chord-preserves-process-and-draft\n";

    terminal.command(L"calc"); terminal.buffer("calc");
    auto paste = [&](const std::wstring& text) { copyText(window, text); key('A', VK_CONTROL); key('V', VK_CONTROL); };
    paste(L"１０÷４"); terminal.inputIs(L"10/4"); key(VK_RETURN);
    expect(waitFor([&] { return terminal.element(L"10/4 = 2.5") != nullptr; }), "Unicode粘贴除法变成了另一算式");
    paste(L"2×3"); terminal.inputIs(L"2*3"); key(VK_RETURN);
    expect(waitFor([&] { return terminal.element(L"2*3 = 6") != nullptr; }), "Unicode粘贴乘法结果错误");
    paste(L"2&3"); terminal.inputIs(L"2&3"); key(VK_RETURN);
    terminal.stateIs([](const Json& state) { return !state.value("error", "").empty(); }, "未知字符算式未报错");
    key(VK_UP); terminal.inputIs(L"2*3");
    const std::wstring overlong = L"1" + std::wstring(255, L' ') + L"+2";
    paste(overlong); terminal.inputIs(overlong); key(VK_RETURN);
    terminal.stateIs([](const Json& state) { return !state.value("error", "").empty(); }, "超长算式被截成有效前缀");
    key(VK_UP); terminal.inputIs(L"2*3");
    terminal.command(L"calc clear"); key(VK_ESCAPE); terminal.buffer("");
    std::cout << "PASS calc-unicode-paste-invalid-and-overlong-preserved\n";

    terminal.command(L"group root");
    auto source = terminal.element(L"排序甲"); expect(source != nullptr, "悬停合并缺少源书签");
    check(source->SetFocus(), "无法选中悬停合并源"); terminal.focused(L"排序甲"); type(L"o");
    dragElement(source.Get(), terminal.element(L"排序乙").Get(), true);
    awaitDocument(directory, [&](const Document& data) {
        auto a = data.bookmark(first), b = data.bookmark(second);
        return a && b && a->groupId && a->groupId == b->groupId && data.groups.size() == seed.groups.size() + 1;
    }, "持续微动悬停没有将两条根书签合并成文件夹");
    terminal.idle(); key(VK_ESCAPE);
    const auto updates = events(log, "external_updated").size();
    atomicWrite(directory / L"bookmarks.json", seed.encode());
    expect(waitFor([&] { return events(log, "external_updated").size() > updates; }), "回归后无法恢复隔离种子数据");
    terminal.command(L"group root"); terminal.idle();
    std::cout << "PASS drag-merge-with-continuous-pointer-motion\n";

    ComPtr<IUIAutomation> automation; ComPtr<IUIAutomationElement> root;
    check(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)), "无法创建事件订阅客户端");
    check(automation->ElementFromHandle(window, &root), "无法查询事件订阅根节点");
    auto observer = Microsoft::WRL::Make<AccessibilityEvents>(); GetWindowThreadProcessId(window, &observer->process);
    check(automation->AddFocusChangedEventHandler(nullptr, observer.Get()), "无法订阅焦点事件");
    ScopeExit removeFocus{[&] { automation->RemoveFocusChangedEventHandler(observer.Get()); }};
    check(automation->AddStructureChangedEventHandler(root.Get(), TreeScope_Subtree, nullptr, observer.Get()), "无法订阅结构事件");
    ScopeExit removeStructure{[&] { automation->RemoveStructureChangedEventHandler(root.Get(), observer.Get()); }};
    clickElement(terminal.element(L"排序甲").Get()); terminal.focused(L"排序甲");
    key(VK_DOWN); terminal.focused(L"排序乙");
    expect(waitFor([&] { return observer->focusedOn(L"排序乙"); }), "键盘选择变化没有发送目标UIA焦点事件");
    type(L":"); terminal.inputIs(L"");
    terminal.stateIs([](const Json& state) { return state.value("mode", "") == "COMMAND"; }, "未进入命令输入");
    BOOL rowFocused = TRUE;
    auto selected = terminal.element(L"排序乙"); expect(selected != nullptr, "输入期间选中行消失");
    check(selected->get_CurrentHasKeyboardFocus(&rowFocused), "无法读取虚拟行焦点");
    expect(!rowFocused, "原生输入框焦点被虚拟选中行冒领");
    key(VK_ESCAPE); terminal.focused(L"排序乙");
    invoke(terminal.element(L"树展开验收").Get());
    expect(waitFor([&] { return observer->expanded.load(); }), "展开树没有发送可读取新子项的结构事件");
    invoke(terminal.element(L"树展开验收").Get());
    expect(waitFor([&] { return terminal.element(L"文件夹中的中文书签") == nullptr; }), "事件回归后树未折叠");
    std::cout << "PASS uia-focus-structure-events-and-native-input-focus\n";
}

void edgeFixture(const fs::path& directory, const std::string& duplicateUrl) {
    fs::create_directories(directory / L"Default");
    auto url = [](const char* id, const char* name, const std::string& value) {
        return Json{{"id", id}, {"type", "url"}, {"name", name}, {"url", value}, {"date_added", "13300000000000000"}};
    };
    Json importedFolder{{"id", "4"}, {"type", "folder"}, {"name", "Edge 中文文件夹"},
        {"children", Json::array({url("5", "Edge 文件夹书签", "https://edge.example/folder")})}};
    Json bar{{"id", "1"}, {"type", "folder"}, {"name", "收藏夹栏"},
        {"children", Json::array({url("2", "Edge 根书签", "https://edge.example/root"), url("3", "不可重复导入", duplicateUrl), importedFolder})}};
    Json other{{"id", "6"}, {"type", "folder"}, {"name", "其他收藏夹"}, {"children", Json::array()}};
    Json synced{{"id", "7"}, {"type", "folder"}, {"name", "移动收藏夹"}, {"children", Json::array()}};
    atomicWrite(directory / L"Default" / L"Bookmarks", Json{{"version", 1}, {"roots", {{"bookmark_bar", bar}, {"other", other}, {"synced", synced}}}}.dump());
}
}

int wmain(int argc, wchar_t** argv) {
    try {
        expect(argc >= 2, "用法：frog-smoke 应用路径 [截图与诊断目录]");
        check(CoInitializeEx(nullptr, COINIT_MULTITHREADED), "COM 初始化失败");
        ScopeExit uninitialize{[] { CoUninitialize(); }};
        const auto runId = wide(uuid());
        const fs::path temporary = fs::temp_directory_path() / (L"Frog-terminal-smoke-" + runId);
        const fs::path dataDirectory = temporary / L"data";
        const fs::path artifacts = argc >= 3 ? fs::absolute(argv[2]) : fs::temp_directory_path() / (L"Frog-terminal-evidence-" + runId);
        fs::create_directories(dataDirectory);
        fs::create_directories(artifacts);
        ScopeExit cleanup{[&] { std::error_code error; fs::remove_all(temporary, error); }};
        const fs::path log = temporary / L"diagnostics.jsonl";
        ScopeExit evidence{[&] {
            std::error_code error;
            if (fs::exists(log, error)) fs::copy_file(log, artifacts / L"application.jsonl", fs::copy_options::overwrite_existing, error);
        }};
        std::cout << "ARTIFACTS " << utf8(artifacts.wstring()) << '\n';

        Document seed;
        const auto folder = seed.addGroup("树展开验收");
        seed.upsert("", "文件夹中的中文书签", "https://example.com/inside", folder);
        const auto first = seed.upsert("", "排序甲", "https://example.com/first", {});
        const auto second = seed.upsert("", "排序乙", "https://example.com/second", {});
        atomicWrite(dataDirectory / L"bookmarks.json", seed.encode());
        const auto commandLine = L"\"" + fs::absolute(argv[1]).wstring() + L"\" --data-directory \"" + dataDirectory.wstring() + L"\" --diagnostics \"" + log.wstring() + L"\"";
        const auto process = launch(commandLine + L" --background");
        Handle processHandle(process.hProcess);
        ScopeExit stop{[&] {
            if (WaitForSingleObject(processHandle, 0) != WAIT_OBJECT_0) {
                TerminateProcess(processHandle, 1);
                WaitForSingleObject(processHandle, 3000);
            }
        }};
        HWND window{}, controller{};
        ScopeExit failedFrame{[&] {
            if (window && IsWindowVisible(window) && WaitForSingleObject(processHandle, 0) != WAIT_OBJECT_0) {
                try { capture(window, artifacts / L"last-frame.png"); }
                catch (const std::exception& error) { std::cerr << "截图失败：" << error.what() << '\n'; }
            }
        }};
        expect(waitFor([&] {
            controller = findWindow(process.dwProcessId, L"FrogController");
            return controller && !events(log, "data_loaded").empty();
        }), "隔离后台实例未就绪");
        expect(findWindow(process.dwProcessId, L"FrogLauncher") == nullptr, "后台启动不应创建终端窗口");
        expect(!events(log, "process_started").empty(), "缺少真实进程启动诊断");
        std::cout << "PASS isolated-background-lazy-window\n";

        const auto secondary = launch(commandLine);
        Handle secondaryHandle(secondary.hProcess);
        ScopeExit stopSecondary{[&] {
            if (WaitForSingleObject(secondaryHandle, 0) != WAIT_OBJECT_0) {
                TerminateProcess(secondaryHandle, 1);
                WaitForSingleObject(secondaryHandle, 3000);
            }
        }};
        expect(WaitForSingleObject(secondaryHandle, 7000) == WAIT_OBJECT_0, "第二实例没有转交并退出");
        DWORD secondaryExit{};
        expect(GetExitCodeProcess(secondaryHandle, &secondaryExit) && secondaryExit == 0, "第二实例转交失败");
        expect(waitFor([&] {
            window = findWindow(process.dwProcessId, L"FrogLauncher");
            return window && IsWindowVisible(window) && !events(log, "first_interactive").empty();
        }), "单实例转交没有唤起终端");
        AllowSetForegroundWindow(process.dwProcessId);
        foreground(window);
        Terminal terminal(window, log);
        terminal.idle();
        std::cout << "PASS single-instance-terminal-first-paint\n";
        reviewRegressions(terminal, window, processHandle, dataDirectory, log, seed, first, second);
        if (argc >= 4 && std::wstring_view(argv[3]) == L"--review-only") {
            terminal.command(L"q");
            expect(WaitForSingleObject(processHandle, 7000) == WAIT_OBJECT_0, "审查回归后无法正常退出");
            std::cout << "PASS review-regressions\n"; return 0;
        }

        terminal.command(L"group root");
        terminal.idle();
        expect(terminal.element(L"文件夹中的中文书签") == nullptr, "折叠的树仍暴露不可见书签");
        invoke(terminal.element(L"树展开验收").Get());
        expect(waitFor([&] { return terminal.element(L"文件夹中的中文书签") != nullptr; }), "UIA 调用没有展开树");
        capture(window, artifacts / L"tree-expanded.png");
        invoke(terminal.element(L"树展开验收").Get());
        expect(waitFor([&] { return terminal.element(L"文件夹中的中文书签") == nullptr; }), "UIA 调用没有折叠树");
        terminal.command(L"find 文件夹中的中文");
        expect(waitFor([&] { return terminal.element(L"文件夹中的中文书签") != nullptr; }), "搜索没有穿透折叠文件夹");
        clickElement(terminal.element(L"文件夹中的中文书签").Get());
        terminal.focused(L"文件夹中的中文书签");
        terminal.command(L"copy");
        expect(waitFor([&] { return clipboardText() == L"https://example.com/inside"; }), "搜索点击后命令没有作用于所选结果");
        terminal.command(L"group 不存在的文件夹");
        expect(terminal.element(L"文件夹中的中文书签") != nullptr && terminal.element(L"排序甲") == nullptr, "失败的文件夹导航改变了搜索结果");
        terminal.command(L"find 不存在的搜索结果");
        terminal.inputIs(L"不存在的搜索结果");
        expect(waitFor([&] { return terminal.element(L"文件夹中的中文书签") == nullptr; }), "无匹配搜索仍显示旧结果");
        key(VK_ESCAPE);
        terminal.stateIs([](const Json& value) { return value.value("mode", "") == "NORMAL"; }, "Esc 没有结束搜索并恢复列表");
        terminal.idle();
        std::cout << "PASS tree-uia-expand-search-click-focus\n";

        const auto beforeAdd = readFile(dataDirectory / L"bookmarks.json");
        terminal.command(L"add");
        terminal.field("add", "url");
        terminal.replace(L"https://example.org/新增");
        key(VK_RETURN);
        terminal.field("add", "title");
        terminal.replace(L"三步添加中文");
        key(VK_TAB, VK_SHIFT);
        terminal.field("add", "url");
        terminal.inputIs(L"https://example.org/新增");
        key(VK_RETURN);
        terminal.field("add", "title");
        terminal.inputIs(L"三步添加中文");
        key(VK_RETURN);
        terminal.field("add", "location");
        key(VK_TAB, VK_SHIFT);
        terminal.field("add", "title");
        terminal.inputIs(L"三步添加中文");
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeAdd, "三步添加确认前写入了数据");
        capture(window, artifacts / L"add-draft.png");

        terminal.hideAndResume(controller);
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeAdd, "收起提交了未完成草稿");
        terminal.field("add", "title");
        terminal.inputIs(L"三步添加中文");
        key(VK_RETURN);
        terminal.field("add", "location");
        key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) {
            const auto bookmark = titled(data, "三步添加中文");
            return data.bookmarks.size() == seed.bookmarks.size() + 1 && bookmark && bookmark->url == "https://example.org/新增" && !bookmark->groupId;
        }, "三步添加没有原子保存根目录书签");
        terminal.idle();
        std::cout << "PASS add-three-steps-backtrack-hide-preserves-draft\n";

        terminal.select(L"三步添加中文");
        const auto beforeCancel = readFile(dataDirectory / L"bookmarks.json");
        terminal.command(L"edit");
        terminal.field("edit", "title");
        terminal.replace(L"取消不保存标题");
        key(VK_TAB);
        terminal.field("edit", "url");
        terminal.replace(L"https://cancel.example/path");
        key(VK_ESCAPE);
        terminal.idle();
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeCancel, "取消编辑仍保存了字段");
        terminal.command(L"edit");
        terminal.field("edit", "title");
        terminal.inputIs(L"三步添加中文");
        terminal.replace(L"双字段保存标题");
        key(VK_TAB);
        terminal.field("edit", "url");
        terminal.replace(L"javascript:alert(1)");
        key(VK_RETURN);
        terminal.stateIs([](const Json& state) { return state.value("prompt", "") == "edit" && !state.value("error", "").empty(); }, "无效网址没有显示编辑失败");
        terminal.inputIs(L"javascript:alert(1)");
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeCancel, "无效网址破坏了原始数据");
        key(VK_TAB, VK_SHIFT);
        terminal.field("edit", "title");
        terminal.inputIs(L"双字段保存标题");
        key(VK_TAB);
        terminal.field("edit", "url");
        terminal.replace(L"https://edited.example/双字段");
        const auto failures = events(log, "save_failed").size();
        {
            Handle lock(CreateFileW((dataDirectory / L"bookmarks.json").c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
            expect(lock.valid(), "无法建立隔离数据文件的写入失败条件");
            key(VK_RETURN);
            expect(waitFor([&] { return events(log, "save_failed").size() > failures; }), "真实写入失败未被报告");
            terminal.field("edit", "url");
            terminal.inputIs(L"https://edited.example/双字段");
            key(VK_TAB);
            terminal.field("edit", "title");
            terminal.inputIs(L"双字段保存标题");
            expect(readFile(dataDirectory / L"bookmarks.json") == beforeCancel, "写入失败改变了原文件");
            capture(window, artifacts / L"edit-failure-retains-fields.png");
        }
        key(VK_RETURN);
        awaitDocument(dataDirectory, [](const Document& data) {
            const auto bookmark = titled(data, "双字段保存标题");
            return bookmark && bookmark->url == "https://edited.example/双字段";
        }, "解除写入故障后重试没有联合保存两个字段");
        terminal.idle();
        std::cout << "PASS edit-two-fields-cancel-validation-io-failure-retry\n";

        terminal.select(L"双字段保存标题");
        terminal.command(L"copy");
        expect(waitFor([&] { return clipboardText() == L"https://edited.example/双字段"; }), "复制网址没有写入真实剪贴板");
        terminal.command(L"edit");
        terminal.field("edit", "title");
        terminal.replace(L"冲突重试保留草稿");
        auto external = document(dataDirectory);
        for (auto& bookmark : external.bookmarks) if (bookmark.id == first) bookmark.title = "外部修改必须保留";
        const auto updates = events(log, "external_updated").size();
        atomicWrite(dataDirectory / L"bookmarks.json", external.encode());
        expect(waitFor([&] { return events(log, "external_updated").size() > updates; }), "目录监听没有加载真实外部更新");
        const auto conflicts = events(log, "save_conflict").size();
        key(VK_RETURN);
        expect(waitFor([&] { return events(log, "save_conflict").size() > conflicts; }), "旧编辑草稿没有报告外部冲突");
        terminal.field("edit", "title");
        terminal.inputIs(L"冲突重试保留草稿");
        expect(document(dataDirectory) == external, "冲突覆盖了外部数据");
        key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) {
            return titled(data, "冲突重试保留草稿") && data.bookmark(first) && data.bookmark(first)->title == "外部修改必须保留";
        }, "显式重试没有合并保留外部版本与当前草稿");
        terminal.idle();
        std::cout << "PASS clipboard-url-external-conflict-explicit-retry\n";

        terminal.command(L"group root");
        terminal.idle();
        clickElement(terminal.element(L"排序乙").Get());
        terminal.focused(L"排序乙");
        type(L"o");
        key(VK_UP, VK_SHIFT);
        awaitDocument(dataDirectory, [&](const Document& data) { return data.bookmark(second) && data.bookmark(first) && data.bookmark(second)->order < data.bookmark(first)->order; }, "整理模式上移没有保存兄弟顺序");
        key(VK_ESCAPE);
        terminal.idle();
        capture(window, artifacts / L"tree-reordered.png");
        terminal.select(L"冲突重试保留草稿");
        const auto beforeDelete = document(dataDirectory);
        terminal.command(L"delete");
        terminal.field("delete", "confirm");
        expect(document(dataDirectory) == beforeDelete, "删除确认前已修改数据");
        key(VK_RETURN);
        terminal.idle();
        expect(document(dataDirectory) == beforeDelete, "删除确认默认值不是取消");
        terminal.command(L"delete");
        terminal.field("delete", "confirm");
        key(VK_ESCAPE);
        terminal.idle();
        expect(document(dataDirectory) == beforeDelete, "Esc 没有取消删除");
        terminal.command(L"delete");
        terminal.field("delete", "confirm");
        key('Y');
        awaitDocument(dataDirectory, [&](const Document& data) { return !titled(data, "冲突重试保留草稿") && data.bookmarks.size() + 1 == beforeDelete.bookmarks.size(); }, "y 没有确认删除唯一所选书签");
        terminal.idle();
        std::cout << "PASS sibling-order-delete-confirm-and-cancel\n";
        terminal.select(L"排序乙"); terminal.command(L"move"); terminal.field("move", "to");
        terminal.replace(L"新建文件夹"); key(VK_RETURN); terminal.field("move", "name");
        terminal.replace(L"移动创建验收"); key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) { auto b = data.bookmark(second); return b && b->groupId && data.group(*b->groupId)->name == "移动创建验收"; }, "移动没有原子创建文件夹并迁入书签");
        terminal.idle();
        terminal.command(L"group 移动创建验收"); terminal.command(L"rename"); terminal.field("rename", "name");
        terminal.replace(L"重命名验收"); key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) { auto b = data.bookmark(second); return b && b->groupId && data.group(*b->groupId)->name == "重命名验收"; }, "文件夹重命名没有保存");
        terminal.idle();
        terminal.select(L"排序乙"); terminal.command(L"move"); terminal.field("move", "to");
        terminal.replace(L"根目录"); key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) { return !data.bookmark(second)->groupId; }, "书签没有移回根目录");
        terminal.idle();
        terminal.command(L"group 重命名验收"); terminal.command(L"delete"); terminal.field("delete", "confirm"); key('Y');
        awaitDocument(dataDirectory, [&](const Document& data) { return data.groups.size() == 1; }, "空文件夹删除失败");
        terminal.idle();
        terminal.command(L"group root");
        auto dragSource = terminal.element(L"排序乙");
        expect(dragSource != nullptr, "无法找到拖动源 排序乙");
        check(dragSource->SetFocus(), "无法选择拖动源"); terminal.focused(L"排序乙"); type(L"o");
        dragElement(terminal.element(L"排序乙").Get(), terminal.element(L"树展开验收").Get());
        awaitDocument(dataDirectory, [&](const Document& data) { return data.bookmark(second)->groupId == Location(folder); }, "真实鼠标拖动没有迁入文件夹");
        terminal.idle();
        key(VK_ESCAPE); terminal.select(L"排序乙"); terminal.command(L"move"); terminal.field("move", "to");
        terminal.replace(L"根目录"); key(VK_RETURN);
        awaitDocument(dataDirectory, [&](const Document& data) { return !data.bookmark(second)->groupId; }, "拖动后不能移出文件夹");
        terminal.idle(); std::cout << "PASS move-new-folder-rename-empty-delete-native-drag\n";

        const auto beforeCalc = readFile(dataDirectory / L"bookmarks.json");
        terminal.command(L"calc");
        terminal.buffer("calc");
        terminal.replace(L"(2 + 3) * 4 - 6 / 2");
        terminal.hideAndResume(controller);
        key(VK_RETURN);
        type(L"c");
        expect(waitFor([&] { return clipboardText() == L"17"; }), "计算器未计算真实带括号优先级表达式");
        expect(waitFor([&] { return terminal.element(L"结果 17") != nullptr && terminal.element(L"(2 + 3) * 4 - 6 / 2 = 17") != nullptr; }), "UIA 未暴露真实计算结果及历史");
        terminal.replace(L"-2.5 * (8 - 2)");
        key(VK_RETURN);
        type(L"c");
        expect(waitFor([&] { return clipboardText() == L"-15"; }), "计算器负数小数结果错误");
        expect(waitFor([&] { return terminal.element(L"-2.5 * (8 - 2) = -15") != nullptr; }), "第二条计算历史没有显示");
        key(VK_UP);
        terminal.inputIs(L"-2.5 * (8 - 2)");
        key(VK_DOWN);
        terminal.inputIs(L"(2 + 3) * 4 - 6 / 2");
        type(L"c");
        expect(waitFor([&] { return clipboardText() == L"17"; }), "历史选择没有复制对应历史结果");
        capture(window, artifacts / L"calculator-history.png");
        terminal.replace(L"1 / 0");
        key(VK_RETURN);
        terminal.stateIs([](const Json& state) { return !state.value("error", "").empty(); }, "除零没有报告真实计算错误");
        terminal.inputIs(L"1 / 0");
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeCalc, "计算器修改了书签文件");
        terminal.command(L"group 不存在的文件夹");
        terminal.buffer("calc"); terminal.inputIs(L"1 / 0");
        expect(waitFor([&] { return terminal.textVisible(L"找不到文件夹"); }), "计算器中的失败导航没有可见错误反馈");
        terminal.command(L"calc wrong");
        terminal.buffer("calc"); terminal.inputIs(L"1 / 0");
        expect(waitFor([&] { return terminal.textVisible(L"用法：:calc"); }), "计算器中的命令错误不可见");
        terminal.command(L"help");
        terminal.buffer("help");
        expect(waitFor([&] { return terminal.textVisible(L":add"); }), "帮助没有通过 UIA 暴露真实命令说明");
        capture(window, artifacts / L"help.png");
        terminal.command(L"set");
        terminal.buffer("settings");
        expect(waitFor([&] { return terminal.textVisible(dataDirectory.wstring()); }), "设置没有显示当前隔离数据目录");
        capture(window, artifacts / L"settings.png");
        terminal.command(L"log");
        terminal.buffer("log");
        type(L"G");
        expect(waitFor([&] { return terminal.textVisible(L":log"); }), "日志没有显示刚刚执行的真实命令");
        capture(window, artifacts / L"log.png");
        expect(readFile(dataDirectory / L"bookmarks.json") == beforeCalc, "只读帮助、设置或日志改变了书签");
        std::cout << "PASS calc-expressions-history-copy-errors-settings-help-log\n";

        const fs::path backup = temporary / L"真实 中文 backup.json";
        const auto backedUp = document(dataDirectory);
        terminal.job(L"backup " + backup.wstring());
        expect(waitFor([&] { return fs::exists(backup); }), "备份命令未创建真实文件");
        terminal.idle();
        expect(Document::decode(readFile(backup)) == backedUp, "备份内容与当前真实数据不一致");
        terminal.command(L"mkdir 恢复前临时文件夹");
        awaitDocument(dataDirectory, [&](const Document& data) { return data.groups.size() == backedUp.groups.size() + 1; }, "无法建立恢复前修改");
        terminal.idle();
        terminal.job(L"restore " + backup.wstring());
        awaitDocument(dataDirectory, [&](const Document& data) { return data == backedUp; }, "恢复没有整体替换真实数据");
        terminal.idle();

        const fs::path otherDirectory = temporary / L"其他 中文 data";
        fs::create_directories(otherDirectory);
        Document other;
        other.upsert("", "另一个目录独有书签", "https://other.example/data", {});
        atomicWrite(otherDirectory / L"bookmarks.json", other.encode());
        terminal.job(L"cd " + otherDirectory.wstring());
        terminal.command(L"group root");
        expect(waitFor([&] { return terminal.element(L"另一个目录独有书签") != nullptr; }), "切换目录没有显示目标真实数据");
        terminal.idle();
        terminal.command(L"mkdir 只写入切换后目录");
        awaitDocument(otherDirectory, [](const Document& data) { return data.groups.size() == 1 && data.groups.front().name == "只写入切换后目录"; }, "切换后修改没有写入新目录");
        terminal.idle();
        expect(document(dataDirectory) == backedUp, "切换后修改污染了旧目录");
        terminal.job(L"cd " + dataDirectory.wstring());
        terminal.command(L"group root");
        expect(waitFor([&] { return terminal.element(L"外部修改必须保留") != nullptr; }), "切回原目录没有恢复原数据");
        terminal.idle();
        expect(document(otherDirectory).groups.size() == 1, "切回原目录覆盖了新目录数据");
        std::cout << "PASS real-backup-restore-directory-switch-isolation\n";

        const fs::path edgeDirectory = temporary / L"隔离 Edge User Data";
        edgeFixture(edgeDirectory, backedUp.bookmark(first)->url);
        const auto edgeBytes = readFile(edgeDirectory / L"Default" / L"Bookmarks");
        terminal.job(L"import edge " + edgeDirectory.wstring());
        awaitDocument(dataDirectory, [&](const Document& data) {
            const auto inFolder = titled(data, "Edge 文件夹书签");
            return data.bookmarks.size() == backedUp.bookmarks.size() + 2 && titled(data, "Edge 根书签") && inFolder && inFolder->groupId.has_value();
        }, "Edge fixture 未导入真实 URL、文件夹或没有去重");
        terminal.idle();
        const auto imported = document(dataDirectory);
        const auto importedBookmark = titled(imported, "Edge 文件夹书签");
        expect(importedBookmark && importedBookmark->groupId && imported.group(*importedBookmark->groupId) && imported.group(*importedBookmark->groupId)->name.find("Edge 中文文件夹") != std::string::npos, "Edge 文件夹归属丢失");
        expect(readFile(edgeDirectory / L"Default" / L"Bookmarks") == edgeBytes, "导入修改了 Edge 原始文件");
        terminal.job(L"import edge " + edgeDirectory.wstring());
        terminal.idle();
        expect(document(dataDirectory) == imported, "重复 Edge 导入改变了已有书签");
        capture(window, artifacts / L"edge-import.png");
        std::cout << "PASS edge-real-fixture-read-only-import-deduplication\n";

        type(L":hel");
        terminal.inputIs(L"hel");
        terminal.hideAndResume(controller);
        type(L"p");
        terminal.inputIs(L"help");
        key(VK_RETURN);
        terminal.buffer("help");
        expect(waitFor([&] { return terminal.textVisible(L":add"); }), "收起后未能继续执行保留的命令草稿");

        terminal.command(L"find 无匹配的收起搜索");
        terminal.inputIs(L"无匹配的收起搜索");
        key(VK_F4, VK_MENU);
        expect(waitFor([&] { return !IsWindowVisible(window); }), "最终收起失败");
        PostMessageW(controller, wmActivate, 0, 0);
        expect(waitFor([&] { return IsWindowVisible(window); }), "最终重新展开失败");
        foreground(window);
        terminal.inputIs(L"");
        terminal.idle();
        expect(document(dataDirectory) == imported, "窗口生命周期改变了书签数据");
        expect(!events(log, "hidden").empty() && !events(log, "reopened").empty(), "缺少真实收起与重开诊断");
        capture(window, artifacts / L"terminal-final.png");
        terminal.command(L"q");
        expect(WaitForSingleObject(processHandle, 7000) == WAIT_OBJECT_0, ":q 没有正常退出真实进程");
        DWORD code{};
        expect(GetExitCodeProcess(processHandle, &code) && code == 0, "终端退出码异常");
        expect(document(dataDirectory) == imported, "正常退出改变了书签数据");
        std::cout << "PASS search-hide-clear-draft-retention-normal-exit\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n';
        return 1;
    }
}
