#include "ui/Launcher.h"
#include <commctrl.h>
#include <shellapi.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    using namespace frog;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ScopeExit cleanup{[&] { if (SUCCEEDED(initialized)) CoUninitialize(); }};
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES}; InitCommonControlsEx(&controls);
    try {
        auto options = Options::parse(); Instance instance(options); if (!instance.primary()) return 0;
        Launcher launcher(std::move(options), instance); return launcher.run();
    } catch (const std::exception& error) {
        MessageBoxW(nullptr, wide(error.what()).c_str(), L"青蛙导航无法启动", MB_OK | MB_ICONERROR); return 1;
    }
}
