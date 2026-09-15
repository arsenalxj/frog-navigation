#include "platform/Integration.h"
#include "platform/Images.h"
#include "core/State.h"
#include <UIAutomation.h>
#include <iostream>
#include <set>
#include <windowsx.h>

using namespace frog;
namespace {
void expect(bool value, const char* message) { require(value, message); }
bool waitFor(const std::function<bool()>& condition, int timeout = 5000) { double started = milliseconds(); do { if (condition()) return true; Sleep(25); } while (milliseconds() - started < timeout); return false; }
std::vector<Json> events(const fs::path& path, const char* name) {
    std::vector<Json> out; if (!fs::exists(path)) return out;
    std::ifstream input(path);
    for (std::string line; std::getline(input, line);) { auto event = Json::parse(line, nullptr, false); if (!event.is_discarded() && event.value("event", "") == name) out.push_back(std::move(event)); }
    return out;
}
HWND findWindow(DWORD pid, const wchar_t* name) {
    struct Context { DWORD pid; const wchar_t* name; HWND found{}; } context{pid, name};
    EnumWindows([](HWND window, LPARAM ref) -> BOOL { auto& c = *reinterpret_cast<Context*>(ref); DWORD pid{}; GetWindowThreadProcessId(window, &pid); wchar_t cls[80]{}; GetClassNameW(window, cls, 80); if (pid == c.pid && _wcsicmp(cls, c.name) == 0) { c.found = window; return FALSE; } return TRUE; }, reinterpret_cast<LPARAM>(&context));
    return context.found;
}
PROCESS_INFORMATION launch(const std::wstring& command) {
    auto writable = command; STARTUPINFOW startup{sizeof(startup)}; startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE; PROCESS_INFORMATION process{};
    expect(CreateProcessW(nullptr, writable.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process), "无法启动测试进程"); CloseHandle(process.hThread); return process;
}
void foreground(HWND window) {
    auto thread = GetCurrentThreadId(), active = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
    bool attached = active != thread && AttachThreadInput(thread, active, TRUE);
    SetForegroundWindow(window);
    if (attached) AttachThreadInput(thread, active, FALSE);
    expect(waitFor([&] { return IsWindowVisible(window) && GetForegroundWindow() == window; }), "测试窗口未取得前台焦点");
}
std::wstring remoteText(HWND window) {
    std::wstring value(static_cast<size_t>(SendMessageW(window, WM_GETTEXTLENGTH, 0, 0)) + 1, 0);
    auto length = SendMessageW(window, WM_GETTEXT, value.size(), reinterpret_cast<LPARAM>(value.data())); value.resize(static_cast<size_t>(length)); return value;
}
void capture(HWND window, const fs::path& destination) {
    RECT rect{}; GetClientRect(window, &rect); UINT width = rect.right, height = rect.bottom;
    HDC source = GetDC(window), memory = CreateCompatibleDC(source); BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -static_cast<LONG>(height); info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    void* raw{}; HBITMAP bitmap = CreateDIBSection(source, &info, DIB_RGB_COLORS, &raw, nullptr, 0); auto old = SelectObject(memory, bitmap);
    ScopeExit cleanup{[&] { SelectObject(memory, old); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(window, source); }};
    expect(BitBlt(memory, 0, 0, width, height, source, 0, 0, SRCCOPY), "无法捕获测试窗口");
    Pixels pixels{width, height, std::vector<unsigned char>(static_cast<size_t>(width) * height * 4)}; memcpy(pixels.bgra.data(), raw, pixels.bgra.size());
    for (size_t i = 3; i < pixels.bgra.size(); i += 4) pixels.bgra[i] = 255;
    atomicWrite(destination, encodePng(pixels));
}
ComPtr<IUIAutomationElement> named(IUIAutomation* automation, IUIAutomationElement* root, const wchar_t* title) {
    VARIANT name{}; name.vt = VT_BSTR; name.bstrVal = SysAllocString(title); ComPtr<IUIAutomationCondition> condition;
    automation->CreatePropertyCondition(UIA_NamePropertyId, name, &condition); VariantClear(&name);
    ComPtr<IUIAutomationElement> result; root->FindFirst(TreeScope_Descendants, condition.Get(), &result); return result;
}
void invokeElement(IUIAutomationElement* element) {
    expect(element != nullptr, "UIA 未找到目标条目"); ComPtr<IUIAutomationInvokePattern> invoke;
    check(element->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&invoke)), "缺少 Invoke 接口"); check(invoke->Invoke(), "UIA 调用失败");
}
POINT elementPoint(IUIAutomationElement* element, HWND window) {
    expect(element != nullptr, "UIA 未找到拖动条目"); RECT rect{}; element->get_CurrentBoundingRectangle(&rect);
    POINT point{(rect.left + rect.right) / 2, rect.top + (rect.bottom - rect.top) / 3}; ScreenToClient(window, &point); return point;
}
}
int wmain(int argc, wchar_t** argv) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); ScopeExit com{[] { CoUninitialize(); }};
    fs::path temp = fs::temp_directory_path() / wide("Frog-smoke-" + uuid()); fs::create_directories(temp);
    ScopeExit cleanup{[&] { std::error_code ec; fs::remove_all(temp, ec); }};
    try {
        expect(argc >= 2, "缺少应用路径"); fs::path artifacts = argc >= 3 ? fs::path(argv[2]) : temp / L"artifacts"; fs::create_directories(artifacts);
        ScopeExit evidence{[&] { if (fs::exists(temp / "diagnostics.jsonl")) fs::copy_file(temp / "diagnostics.jsonl", artifacts / "application.jsonl", fs::copy_options::overwrite_existing); }};
        Document data; auto group = data.addGroup("界面验收文件夹"); data.upsert("", "文件夹内中文", "example.com", group);
        for (int i = 0; i < 180; ++i) data.upsert("", "书签 " + std::to_string(i), "https://example.com/" + std::to_string(i), {});
        atomicWrite(temp / "bookmarks.json", data.encode()); auto before = readFile(temp / "bookmarks.json");
        auto command = L"\"" + std::wstring(argv[1]) + L"\" --offline --data-directory \"" + temp.wstring() + L"\" --diagnostics \"" + (temp / "diagnostics.jsonl").wstring() + L"\"";
        auto process = launch(command + L" --background"); Handle processHandle(process.hProcess);
        ScopeExit stop{[&] { if (WaitForSingleObject(processHandle, 0) != WAIT_OBJECT_0) { TerminateProcess(processHandle, 1); WaitForSingleObject(processHandle, 3000); } }};
        HWND controller{}; expect(waitFor([&] { controller = findWindow(process.dwProcessId, L"FrogController"); return controller != nullptr && fs::exists(temp / "diagnostics.jsonl"); }), "后台进程未就绪");
        Sleep(150); expect(findWindow(process.dwProcessId, L"FrogLauncher") == nullptr, "后台启动不应创建主界面");
        std::cout << "PASS background-lazy-window\n";
        auto log = temp / "diagnostics.jsonl";
        expect(waitFor([&] { return !events(log, "process_started").empty(); }), "缺少缓存目录诊断事件");
        auto cache = fs::path(wide(events(log, "process_started").front().at("iconCacheDirectory").get<std::string>()));
        expect(fs::weakly_canonical(cache.parent_path()) == fs::weakly_canonical(fs::temp_directory_path()) && cache.filename().wstring().starts_with(L"Frog-session-"), "图标缓存不属于本次隔离实例");
        ScopeExit removeCache{[&] { std::error_code ec; fs::remove_all(cache, ec); }};
        fs::create_directories(cache);
        Pixels icon{72, 72, std::vector<unsigned char>(72 * 72 * 4, 255)};
        for (size_t i = 0; i < icon.bgra.size(); i += 4) { icon.bgra[i] = 80; icon.bgra[i + 1] = 180; icon.bgra[i + 2] = 20; }
        auto png = encodePng(icon);
        for (const auto& bookmark : data.bookmarks) atomicWrite(cache / wide(hash(bookmark.url) + ".png"), png);
        auto second = launch(command); Handle secondHandle(second.hProcess);
        ScopeExit stopSecond{[&] { if (WaitForSingleObject(secondHandle, 0) != WAIT_OBJECT_0) { TerminateProcess(secondHandle, 1); WaitForSingleObject(secondHandle, 3000); } }};
        expect(WaitForSingleObject(secondHandle, 5000) == WAIT_OBJECT_0, "第二实例未退出"); DWORD secondCode{}; GetExitCodeProcess(secondHandle, &secondCode); expect(secondCode == 0, "第二实例转交失败");
        HWND window{}; expect(waitFor([&] { window = findWindow(process.dwProcessId, L"FrogLauncher"); return window && IsWindowVisible(window); }), "未唤起现有窗口");
        AllowSetForegroundWindow(process.dwProcessId); foreground(window);
        expect(waitFor([&] { return readFile(temp / "diagnostics.jsonl").find("first_interactive") != std::string::npos; }), "首次绘制未完成");
        RECT actual{}; GetWindowRect(window, &actual); auto expected = monitorWorkArea(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST)); expect(EqualRect(&actual, &expected), "窗口未铺满工作区");
        std::cout << "PASS single-instance-work-area-first-paint\n";
        auto firstFrame = events(log, "first_interactive").back(); auto rendererGeneration = firstFrame.at("rendererGeneration").get<uint64_t>();
        auto loadedIcons = [&] { size_t count = 0; for (const auto& event : events(log, "image_completed")) if (event.value("source", "") == "cache" && event.value("loaded", false)) ++count; return count; };
        ViewState view; RECT client{}; GetClientRect(window, &client); float dpi = GetDpiForWindow(window) / 96.0f; view.layout = {client.right / dpi, client.bottom / dpi};
        size_t expectedLoads = view.visibleItems(data).size();
        expect(waitFor([&] { return loadedIcons() >= expectedLoads; }), "首页缓存图标未加载完成");
        auto reopen = [&](size_t iconCount, bool sameRenderer) {
            auto before = events(log, "reopened").size();
            SendMessageW(window, WM_CLOSE, 0, 0); expect(!IsWindowVisible(window), "收起失败");
            // 等待窗口管理器完成收起后的前台切换，再模拟用户重新展开。
            Sleep(150);
            AllowSetForegroundWindow(process.dwProcessId); SendMessageW(controller, wmActivate, 0, 0); foreground(window);
            expect(waitFor([&] { return events(log, "reopened").size() > before; }), "重新展开没有首帧事件");
            const auto frame = events(log, "reopened").back();
            expect(frame.at("iconsDrawn") == iconCount && frame.at("readyIconsDrawn") == iconCount, "再次展开首帧未直接使用所有已缓存图标");
            expect(frame.at("bitmapCount").get<size_t>() <= 128, "内存位图缓存超过上限");
            if (sameRenderer) expect(frame.at("rendererGeneration") == rendererGeneration, "正常收起重建了绘制表面");
        };
        for (int i = 0; i < 3; ++i) reopen(expectedLoads, true);
        expect(loadedIcons() == expectedLoads, "重新展开重复读取了已有位图的磁盘缓存");
        std::cout << "PASS cached-icons-first-frame-without-reload\n";
        for (int page = 1; page < view.pageCount(data); ++page) {
            view.turn(data, 1); auto count = view.visibleItems(data).size(); expectedLoads += count;
            PostMessageW(window, WM_KEYDOWN, VK_NEXT, 0);
            expect(waitFor([&] { return loadedIcons() >= expectedLoads; }), "翻页缓存图标未加载完成");
            reopen(count, true);
        }
        expect(events(log, "reopened").back().at("bitmapCount") == 128, "缓存上限测试没有覆盖淘汰场景");
        const auto beforeReturn = events(log, "image_completed").size();
        for (int page = view.page(); page > 0; --page) PostMessageW(window, WM_KEYDOWN, VK_PRIOR, 0);
        view.rootPage = 0; std::set<std::string> initialKeys;
        for (const auto& item : view.visibleItems(data)) { auto bookmark = data.bookmark(item.id); if (!bookmark && item.folder) bookmark = data.bookmark(data.items(item.id).front().id); if (bookmark) initialKeys.insert(hash(bookmark->url)); }
        expect(waitFor([&] { auto recent = events(log, "image_completed"); auto missing = initialKeys; for (size_t i = beforeReturn; i < recent.size(); ++i) if (recent[i].value("loaded", false)) missing.erase(recent[i].value("key", "")); return missing.empty(); }), "被淘汰的首页图标未重新加载");
        reopen(initialKeys.size(), true);
        std::cout << "PASS bitmap-cache-limit-and-evicted-icons-reload\n";
        auto beforeRebuild = loadedIcons();
        RECT suggested{}; GetWindowRect(window, &suggested); DWORD_PTR dpiResult{};
        auto dpiSent = SendMessageTimeoutW(window, WM_DPICHANGED, MAKEWPARAM(static_cast<UINT>(dpi * 96), static_cast<UINT>(dpi * 96)),
            reinterpret_cast<LPARAM>(&suggested), SMTO_ABORTIFHUNG, 5000, &dpiResult);
        require(dpiSent != 0, winError("无法发送 DPI 重建消息"));
        expect(waitFor([&] { return loadedIcons() >= beforeRebuild + initialKeys.size(); }), "绘制资源失效后未恢复缓存图标");
        reopen(initialKeys.size(), false);
        expect(events(log, "reopened").back().at("rendererGeneration").get<uint64_t>() > rendererGeneration, "资源重建测试未创建新绘制表面");
        std::cout << "PASS recreated-renderer-restores-cached-icons\n";
        Sleep(280); capture(window, artifacts / "launchpad.png");
        ComPtr<IUIAutomation> automation; check(CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation)), "UIA 初始化失败");
        ComPtr<IUIAutomationElement> root; check(automation->ElementFromHandle(window, &root), "UIA 无法读取根窗口");
        VARIANT name{}; name.vt = VT_BSTR; name.bstrVal = SysAllocString(L"界面验收文件夹"); ComPtr<IUIAutomationCondition> condition; automation->CreatePropertyCondition(UIA_NamePropertyId, name, &condition); VariantClear(&name);
        ComPtr<IUIAutomationElement> folder; root->FindFirst(TreeScope_Descendants, condition.Get(), &folder); expect(folder != nullptr, "自绘文件夹未暴露给 UIA");
        ComPtr<IUIAutomationInvokePattern> invoke; check(folder->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&invoke)), "UIA 不支持打开文件夹"); check(invoke->Invoke(), "UIA 打开失败"); Sleep(120);
        std::cout << "PASS uia-folder-invoke\n";
        SendMessageW(window, WM_COMMAND, 12, 0); expect(waitFor([&] { return IsWindowVisible(GetDlgItem(window, 201)); }), "添加表单未打开");
        expect(named(automation.Get(), root.Get(), L"网址") != nullptr, "原生输入框缺少辅助功能名称");
        PostMessageW(GetDlgItem(window, 201), WM_KEYDOWN, VK_RETURN, 0); Sleep(180);
        expect(IsWindow(window) && IsWindowVisible(GetDlgItem(window, 201)), "无效的键盘提交关闭了应用或表单");
        std::cout << "PASS invalid-keyboard-submit-preserves-form\n";
        SendMessageW(GetDlgItem(window, 201), WM_SETTEXT, 0, reinterpret_cast<LPARAM>(L"example.org/中文")); SendMessageW(GetDlgItem(window, 202), WM_SETTEXT, 0, reinterpret_cast<LPARAM>(L"原生中文验收"));
        Sleep(80); capture(window, artifacts / "bookmark-form.png");
        SendMessageW(window, WM_CLOSE, 0, 0); expect(!IsWindowVisible(window), "关闭未收起"); PostMessageW(controller, wmActivate, 0, 0); expect(waitFor([&] { return IsWindowVisible(window); }), "无法重新展开");
        expect(remoteText(GetDlgItem(window, 202)) == L"原生中文验收", "收起丢失编辑草稿");
        expect(waitFor([&] { SendMessageW(window, WM_COMMAND, 221, 0); try { return Document::decode(readFile(temp / "bookmarks.json")).bookmarks.size() == data.bookmarks.size() + 1; } catch (...) { return false; } }), "原生添加未保存");
        auto saved = Document::decode(readFile(temp / "bookmarks.json")); auto found = saved.search("原生中文验收"); expect(found.size() == 1 && saved.bookmark(found[0].id)->groupId == Location(group), "文件夹内添加归属错误");
        std::cout << "PASS native-form-chinese-save-draft-resume\n";
        Sleep(220); capture(window, artifacts / "folder.png");
        SendMessageW(window, WM_COMMAND, 12, 0); SendMessageW(GetDlgItem(window, 201), WM_SETTEXT, 0, reinterpret_cast<LPARAM>(L"example.org/conflict")); SendMessageW(GetDlgItem(window, 202), WM_SETTEXT, 0, reinterpret_cast<LPARAM>(L"冲突保留草稿"));
        auto external = saved; external.bookmarks[1].title = "外部更新标题"; atomicWrite(temp / "bookmarks.json", external.encode());
        expect(waitFor([&] { return readFile(temp / "diagnostics.jsonl").find("external_updated") != std::string::npos; }), "外部更新未被监听");
        SendMessageW(window, WM_COMMAND, 221, 0);
        expect(waitFor([&] { return readFile(temp / "diagnostics.jsonl").find("save_conflict") != std::string::npos; }), "旧草稿未提示冲突");
        expect(remoteText(GetDlgItem(window, 202)) == L"冲突保留草稿" && Document::decode(readFile(temp / "bookmarks.json")) == external, "冲突丢失数据或草稿");
        SendMessageW(window, WM_COMMAND, 221, 0); expect(waitFor([&] { return Document::decode(readFile(temp / "bookmarks.json")).bookmarks.size() == external.bookmarks.size() + 1; }), "显式重试未保存");
        std::cout << "PASS external-update-conflict-draft-retry\n";
        Sleep(240); invokeElement(named(automation.Get(), root.Get(), L"返回根目录").Get()); Sleep(260);
        auto source = named(automation.Get(), root.Get(), L"书签 2"), target = named(automation.Get(), root.Get(), L"书签 1");
        auto from = elementPoint(source.Get(), window), to = elementPoint(target.Get(), window);
        auto dragBefore = readFile(temp / "bookmarks.json");
        SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(from.x, from.y)); SendMessageW(window, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(to.x, to.y)); SendMessageW(window, WM_LBUTTONUP, 0, MAKELPARAM(to.x, to.y));
        expect(waitFor([&] { return readFile(temp / "bookmarks.json") != dragBefore; }), "原生拖拽排序未保存");
        auto ordered = Document::decode(readFile(temp / "bookmarks.json")); expect(ordered.bookmark(ordered.search("https://example.com/2")[0].id) != nullptr, "排序后书签丢失");
        expect(ordered.bookmark(data.bookmarks[3].id)->order < ordered.bookmark(data.bookmarks[2].id)->order, "拖拽后顺序错误");
        std::cout << "PASS native-drag-reorder\n";
        Sleep(240);
        source = named(automation.Get(), root.Get(), L"书签 1"); target = named(automation.Get(), root.Get(), L"书签 2"); from = elementPoint(source.Get(), window); to = elementPoint(target.Get(), window);
        SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(from.x, from.y)); SendMessageW(window, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(to.x, to.y)); Sleep(730); SendMessageW(window, WM_LBUTTONUP, 0, MAKELPARAM(to.x, to.y));
        expect(waitFor([&] { return Document::decode(readFile(temp / "bookmarks.json")).groups.size() == 2; }), "停留创建文件夹未保存");
        auto merged = Document::decode(readFile(temp / "bookmarks.json")); expect(merged.bookmark(data.bookmarks[2].id)->groupId == merged.bookmark(data.bookmarks[3].id)->groupId, "成组后归属错误");
        std::cout << "PASS native-drag-hover-merge\n";
        SendMessageW(window, WM_SYSCOMMAND, SC_MINIMIZE, 0); expect(!IsWindowVisible(window), "任务栏最小化未转为收起");
        auto finalData = readFile(temp / "bookmarks.json"); PostMessageW(controller, wmActivate, 0, 0); expect(waitFor([&] { return IsWindowVisible(window); }), "收起后无法唤起");
        expect(readFile(temp / "bookmarks.json") == finalData && before != finalData, "生命周期修改了数据");
        SendMessageW(window, WM_COMMAND, 11, 0); Sleep(80); capture(window, artifacts / "settings.png");
        SendMessageW(GetDlgItem(window, 401), CB_SETCURSEL, 1, 0); SendMessageW(window, WM_COMMAND, MAKEWPARAM(401, CBN_SELCHANGE), 0); Sleep(100); capture(window, artifacts / "settings-dark.png");
        SendMessageW(window, WM_COMMAND, 230, 0); Sleep(280); capture(window, artifacts / "launchpad-dark.png");
        std::cout << "PASS appearance-switch-isolated\n";
        SendMessageW(window, WM_COMMAND, 11, 0); SendMessageW(window, WM_COMMAND, 304, 0); SendMessageW(window, WM_COMMAND, 440, 0);
        expect(WaitForSingleObject(processHandle, 5000) == WAIT_OBJECT_0, "正常退出失败"); DWORD code{}; GetExitCodeProcess(processHandle, &code); expect(code == 0, "退出码异常");
        std::cout << "PASS taskbar-hide-normal-exit\n"; return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
