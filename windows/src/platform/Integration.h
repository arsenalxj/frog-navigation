#pragma once
#include "core/Storage.h"
#include <fstream>

namespace frog {
constexpr UINT wmDispatch = WM_APP + 1, wmActivate = WM_APP + 2, wmDirectory = WM_APP + 3, wmTray = WM_APP + 4, wmCorner = WM_APP + 5, wmAccessibleInvoke = WM_APP + 6;
struct Options {
    bool background = false, offline = false, isolated = false;
    fs::path dataDirectory, diagnostics;
    static Options parse();
};
struct HotKey { bool enabled = true; UINT modifiers = MOD_CONTROL | MOD_ALT, key = VK_SPACE; bool operator==(const HotKey&) const = default; };
struct Preferences {
    fs::path dataDirectory;
    HotKey hotkey;
    bool cornersEnabled = false;
    unsigned corners = 0;
    int page = 0;
    std::string appearance = "system";
    static Preferences load(const Options& options);
    void save(const Options& options) const;
};
std::wstring hotkeyName(const HotKey& key);
class GlobalHotKey {
public:
    ~GlobalHotKey();
    void set(HWND window, const HotKey& key);
private:
    HWND window_{}; int id_ = 0; HotKey current_{false};
};
class Instance {
public:
    explicit Instance(const Options& options);
    ~Instance();
    bool primary() const { return primary_; }
    void listen(HWND window);
    std::wstring windowTitle() const { return L"Frog.Controller." + wide(key_); }
private:
    std::string key_;
    Handle mutex_, event_, stop_{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    bool primary_{};
    std::thread worker_;
};
class Corners {
public:
    ~Corners();
    void configure(HWND window, bool enabled, unsigned mask);
    void suppress(bool value) { suppressed_ = value; }
private:
    static LRESULT CALLBACK hookProc(int code, WPARAM wParam, LPARAM lParam);
    static Corners* active_;
    HHOOK hook_{}; HWND window_{}; unsigned mask_{};
    bool suppressed_ = false;
    int lastZone_ = -1; HMONITOR lastMonitor_{};
};
void setLoginStartup(bool enabled);
bool loginStartupRegistered();
bool loginStartupDisabled();
fs::path startupLink();
RECT monitorWorkArea(HMONITOR monitor);
bool openUrl(const std::string& url);
void copyText(HWND owner, const std::wstring& text);
void accessibleName(HWND window, const wchar_t* name);
std::optional<fs::path> chooseFile(HWND owner, bool save, bool folder = false);
struct Theme {
    bool dark = true, highContrast = false, reducedMotion = false;
    void update(const Preferences& preferences);
};
class Diagnostics {
public:
    explicit Diagnostics(const fs::path& path);
    void event(const std::string& name, Json details = Json::object());
private:
    std::ofstream stream_; std::mutex mutex_; double started_ = milliseconds();
};
}
