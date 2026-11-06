#include <initguid.h>
#include "Integration.h"
#include <shlobj.h>
#include <knownfolders.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <sddl.h>
#include <oleacc.h>
#include <algorithm>

namespace frog {
Options Options::parse() {
    int count{}; auto argv = CommandLineToArgvW(GetCommandLineW(), &count);
    require(argv != nullptr, "无法读取启动参数。"); ScopeExit cleanup{[&] { LocalFree(argv); }};
    Options options;
    for (int i = 1; i < count; ++i) {
        std::wstring arg = argv[i];
        if (arg == L"--background") options.background = true;
        else if (arg == L"--data-directory") {
            require(i + 1 < count && !std::wstring(argv[i + 1]).starts_with(L"--"), "--data-directory 需要目录路径。");
            options.dataDirectory = fs::absolute(argv[++i]).lexically_normal(); options.isolated = true;
        } else if (arg == L"--diagnostics") {
            if (i + 1 < count && !std::wstring(argv[i + 1]).starts_with(L"--")) options.diagnostics = fs::absolute(argv[++i]);
            else options.diagnostics = fs::temp_directory_path() / L"Frog-diagnostics.jsonl";
        } else throw Error("未知启动参数：" + utf8(arg));
    }
    return options;
}
const char* HotKey::validationError() const {
    if ((modifiers & ~(MOD_ALT | MOD_CONTROL | MOD_SHIFT | MOD_WIN)) != 0 || key == 0 || key >= 255)
        return "快捷键的修饰键或按键无效。";
    if ((modifiers & (MOD_CONTROL | MOD_ALT | MOD_WIN)) == 0 || key == VK_ESCAPE || key == VK_F4)
        return "请选择至少包含 Ctrl、Alt 或 Win 的组合键，且不要使用 Esc 或 F4。";
    if (!(modifiers & MOD_ALT)) {
        const bool navigation = key >= VK_PRIOR && key <= VK_DOWN;
        const bool controlCommand = (modifiers & MOD_CONTROL) &&
            (key == 'N' || key == 'F' || key == 'Q' || key == 'H' || key == VK_OEM_COMMA ||
             key == 'A' || key == 'C' || key == 'X' || key == 'V' || key == 'Z' || key == 'Y' ||
             key == VK_INSERT || key == VK_DELETE || key == VK_BACK);
        if (navigation || controlCommand) return "该组合与应用内导航、命令或文本编辑冲突，请选择其他快捷键。";
    }
    return nullptr;
}
Preferences Preferences::load(const Options& options) {
    Preferences prefs; prefs.dataDirectory = options.isolated ? options.dataDirectory : localDirectory() / L"Data";
    if (options.isolated) { prefs.hotkey.enabled = false; prefs.cornersEnabled = false; return prefs; }
    auto path = localDirectory() / L"preferences.json";
    if (!fs::exists(path)) return prefs;
    return decode(readFile(path, 1024 * 1024), prefs.dataDirectory);
}
Preferences Preferences::decode(const std::string& bytes, const fs::path& defaultDataDirectory) {
    Preferences prefs; prefs.dataDirectory = defaultDataDirectory;
    auto data = Json::parse(bytes);
    prefs.dataDirectory = wide(data.value("dataDirectory", utf8(prefs.dataDirectory.wstring())));
    require(prefs.dataDirectory.is_absolute(), "偏好的数据目录必须为绝对路径。");
    prefs.expandedGroupIDs = data.value("expandedGroupIDs", std::vector<std::string>{});
    prefs.cornersEnabled = data.value("cornersEnabled", true); prefs.corners = data.value("corners", 4u) & 15;
    if (data.contains("hotkey")) {
        const auto& key = data.at("hotkey");
        prefs.hotkey = {key.value("enabled", true), key.value("modifiers", UINT(MOD_CONTROL | MOD_ALT)), key.value("key", UINT(VK_SPACE))};
        if (prefs.hotkey.validationError()) prefs.hotkey = HotKey{prefs.hotkey.enabled};
    }
    return prefs;
}
void Preferences::save(const Options& options) const {
    if (options.isolated) return;
    auto dir = localDirectory(); fs::create_directories(dir);
    Json data{{"dataDirectory", utf8(dataDirectory.wstring())}, {"expandedGroupIDs", expandedGroupIDs}, {"cornersEnabled", cornersEnabled}, {"corners", corners},
        {"hotkey", {{"enabled", hotkey.enabled}, {"modifiers", hotkey.modifiers}, {"key", hotkey.key}}}};
    atomicWrite(dir / L"preferences.json", data.dump(2) + "\n");
}
std::wstring hotkeyName(const HotKey& key) {
    std::wstring out;
    if (key.modifiers & MOD_CONTROL) out += L"Ctrl + "; if (key.modifiers & MOD_ALT) out += L"Alt + ";
    if (key.modifiers & MOD_SHIFT) out += L"Shift + "; if (key.modifiers & MOD_WIN) out += L"Win + ";
    if (key.key == VK_SPACE) out += L"Space";
    else { wchar_t name[80]{}; GetKeyNameTextW(static_cast<LONG>(MapVirtualKeyW(key.key, MAPVK_VK_TO_VSC) << 16), name, 80); out += name; }
    return out;
}
GlobalHotKey::~GlobalHotKey() { if (id_) UnregisterHotKey(window_, id_); }
void GlobalHotKey::set(HWND window, const HotKey& key) {
    if (window_ == window && key == current_) return;
    if (key.enabled) {
        if (const auto* error = key.validationError()) throw Error(error);
        int next = id_ == 101 ? 102 : 101;
        require(RegisterHotKey(window, next, key.modifiers | MOD_NOREPEAT, key.key), "该快捷键已被系统或其他应用占用，原快捷键保持不变。");
        if (id_) UnregisterHotKey(window_, id_); id_ = next;
    } else { if (id_) UnregisterHotKey(window_, id_); id_ = 0; }
    window_ = window; current_ = key;
}
namespace {
std::string userKey() {
    HANDLE token{}; require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token), winError("无法读取当前用户")); Handle owner(token);
    DWORD bytes{}; GetTokenInformation(token, TokenUser, nullptr, 0, &bytes); std::vector<unsigned char> buffer(bytes);
    require(GetTokenInformation(token, TokenUser, buffer.data(), bytes, &bytes), winError("无法读取用户标识"));
    LPWSTR sid{}; require(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sid), "无法转换用户标识。");
    auto result = utf8(sid); LocalFree(sid); return result;
}
}
Instance::Instance(const Options& options)
    : key_(hash(userKey() + (options.isolated ? lower(utf8(fs::weakly_canonical(options.dataDirectory).wstring())) : "default"))),
      mutex_(CreateMutexW(nullptr, FALSE, (L"Local\\Frog.Mutex." + wide(key_)).c_str())) {
    require(mutex_.valid(), winError("无法创建单实例锁"));
    DWORD ownership = WaitForSingleObject(mutex_, 0);
    require(ownership == WAIT_OBJECT_0 || ownership == WAIT_ABANDONED || ownership == WAIT_TIMEOUT, "无法检查单实例锁。");
    primary_ = ownership != WAIT_TIMEOUT;
    event_.value = CreateEventW(nullptr, FALSE, FALSE, (L"Local\\Frog.Activate." + wide(key_)).c_str());
    require(event_.valid(), winError("无法创建唤起事件"));
    if (!primary_) {
        HWND existing = FindWindowW(L"FrogController", windowTitle().c_str());
        DWORD pid{}; if (existing) GetWindowThreadProcessId(existing, &pid); if (pid) AllowSetForegroundWindow(pid);
        if (!options.background) SetEvent(event_);
    }
}
Instance::~Instance() { SetEvent(stop_); if (worker_.joinable()) worker_.join(); if (primary_) ReleaseMutex(mutex_); }
void Instance::listen(HWND window) {
    worker_ = std::thread([this, window] {
        HANDLE events[]{stop_, event_};
        while (WaitForMultipleObjects(2, events, FALSE, INFINITE) == WAIT_OBJECT_0 + 1) PostMessageW(window, wmActivate, 0, 0);
    });
}
Corners* Corners::active_{};
Corners::~Corners() { if (hook_) UnhookWindowsHookEx(hook_); if (active_ == this) active_ = nullptr; }
void Corners::configure(HWND window, bool enabled, unsigned mask) {
    if (hook_) { UnhookWindowsHookEx(hook_); hook_ = nullptr; }
    active_ = this; window_ = window; mask_ = mask; lastZone_ = -1;
    POINT point{}; GetCursorPos(&point); lastMonitor_ = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(info)};
    if (GetMonitorInfoW(lastMonitor_, &info)) {
        const auto& r = info.rcMonitor;
        if (point.x <= r.left + 2 && point.y <= r.top + 2) lastZone_ = 0;
        else if (point.x >= r.right - 3 && point.y <= r.top + 2) lastZone_ = 1;
        else if (point.x <= r.left + 2 && point.y >= r.bottom - 3) lastZone_ = 2;
        else if (point.x >= r.right - 3 && point.y >= r.bottom - 3) lastZone_ = 3;
    }
    if (enabled && mask) { hook_ = SetWindowsHookExW(WH_MOUSE_LL, hookProc, GetModuleHandleW(nullptr), 0); require(hook_ != nullptr, winError("无法启用屏幕触角")); }
}
LRESULT CALLBACK Corners::hookProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && wParam == WM_MOUSEMOVE && active_) {
        auto& self = *active_; auto* data = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        auto monitor = MonitorFromPoint(data->pt, MONITOR_DEFAULTTONEAREST); MONITORINFO info{sizeof(info)}; GetMonitorInfoW(monitor, &info);
        auto r = info.rcMonitor; int x = data->pt.x, y = data->pt.y, zone = -1;
        if (x <= r.left + 2 && y <= r.top + 2) zone = 0;
        else if (x >= r.right - 3 && y <= r.top + 2) zone = 1;
        else if (x <= r.left + 2 && y >= r.bottom - 3) zone = 2;
        else if (x >= r.right - 3 && y >= r.bottom - 3) zone = 3;
        bool entered = zone >= 0 && (self.lastZone_ != zone || self.lastMonitor_ != monitor);
        self.lastZone_ = zone; self.lastMonitor_ = monitor;
        if (entered && !self.suppressed_ && (self.mask_ & (1u << zone)) && !(data->flags & LLMHF_INJECTED) &&
            !(GetAsyncKeyState(VK_LBUTTON) & 0x8000) && !(GetAsyncKeyState(VK_RBUTTON) & 0x8000)) PostMessageW(self.window_, wmCorner, 0, 0);
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}
fs::path startupLink() {
    PWSTR value{}; check(SHGetKnownFolderPath(FOLDERID_Startup, KF_FLAG_CREATE, nullptr, &value), "无法读取启动目录。");
    fs::path result(value); CoTaskMemFree(value); return result / L"Frog.lnk";
}
bool loginStartupRegistered() {
    auto path = startupLink(); if (!fs::exists(path)) return false;
    ComPtr<IShellLinkW> link; if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)))) return false;
    ComPtr<IPersistFile> file; link.As(&file); if (FAILED(file->Load(path.c_str(), STGM_READ))) return false;
    wchar_t target[32768]{}, arguments[1024]{}; link->GetPath(target, 32768, nullptr, SLGP_RAWPATH); link->GetArguments(arguments, 1024);
    return sameFile(target, executablePath()) && std::wstring(arguments) == L"--background";
}
bool loginStartupDisabled() {
    BYTE data[24]{}; DWORD size = sizeof(data);
    auto result = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\StartupFolder", L"Frog.lnk", RRF_RT_REG_BINARY, nullptr, data, &size);
    return result == ERROR_SUCCESS && size >= 4 && (data[0] == 3 || data[0] == 7);
}
void setLoginStartup(bool enabled) {
    auto path = startupLink();
    if (!enabled) { if (fs::exists(path)) require(DeleteFileW(path.c_str()), winError("无法移除登录启动快捷方式")); return; }
    ComPtr<IShellLinkW> link; check(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link)), "无法创建启动快捷方式。");
    check(link->SetPath(executablePath().c_str()), "无法设置启动路径。"); link->SetArguments(L"--background"); link->SetDescription(L"青蛙导航书签启动台");
    link->SetWorkingDirectory(executablePath().parent_path().c_str()); link->SetIconLocation(executablePath().c_str(), 0);
    ComPtr<IPersistFile> file; link.As(&file); check(file->Save(path.c_str(), TRUE), "无法保存启动快捷方式。");
}
bool openUrl(const std::string& url) {
    if (!validUrl(url)) return false;
    return reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", wide(url).c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
}
void copyText(HWND owner, const std::wstring& text) {
    require(OpenClipboard(owner), "剪贴板暂时被其他应用占用，请重试。"); ScopeExit close{[] { CloseClipboard(); }};
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, (text.size() + 1) * sizeof(wchar_t)); require(data != nullptr, "无法分配剪贴板内存。");
    auto memory = GlobalLock(data); if (!memory) { GlobalFree(data); throw Error("无法写入剪贴板。"); }
    memcpy(memory, text.c_str(), (text.size() + 1) * sizeof(wchar_t)); GlobalUnlock(data); EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, data)) { GlobalFree(data); throw Error("复制失败，请重试。"); }
}
void accessibleName(HWND window, const wchar_t* name) {
    ComPtr<IAccPropServices> properties;
    if (SUCCEEDED(CoCreateInstance(CLSID_AccPropServices, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&properties)))) properties->SetHwndPropStr(window, static_cast<DWORD>(OBJID_CLIENT), CHILDID_SELF, PROPID_ACC_NAME, name);
}
Diagnostics::Diagnostics(const fs::path& path) {
    if (!path.empty()) { fs::create_directories(path.parent_path()); stream_.open(path, std::ios::app); require(stream_.is_open(), "无法创建诊断日志。"); }
}
void Diagnostics::event(const std::string& name, Json details) {
    std::lock_guard lock(mutex_); if (!stream_.is_open()) return;
    details["event"] = name; details["elapsedMs"] = milliseconds() - started_; details["pid"] = GetCurrentProcessId();
    stream_ << details.dump() << '\n'; stream_.flush();
}
}
