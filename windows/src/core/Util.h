#pragma once
#include <windows.h>
#include <wrl/client.h>
#include <filesystem>
#include <string>
#include <vector>
#include <functional>
#include <optional>
#include <stdexcept>
#include <chrono>

namespace frog {
namespace fs = std::filesystem;
template<class T> using ComPtr = Microsoft::WRL::ComPtr<T>;
struct Error : std::runtime_error { using runtime_error::runtime_error; };
std::wstring wide(const std::string& text);
std::string utf8(const std::wstring& text);
std::string trim(const std::string& text);
std::string lower(const std::string& text);
size_t characters(const std::string& text);
std::string uuid();
std::string hash(const std::string& text);
std::string winError(const std::string& operation, DWORD code = GetLastError());
fs::path localDirectory();
fs::path executablePath();
std::wstring windowText(HWND window);
double milliseconds();
std::string percentEncode(const std::string& text);
void require(bool condition, const std::string& message);
void check(HRESULT result, const std::string& message);
struct Handle {
    HANDLE value = INVALID_HANDLE_VALUE;
    Handle() = default;
    explicit Handle(HANDLE h) : value(h) {}
    ~Handle() { if (valid()) CloseHandle(value); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    Handle(Handle&& other) noexcept : value(other.value) { other.value = INVALID_HANDLE_VALUE; }
    bool valid() const { return value != INVALID_HANDLE_VALUE && value != nullptr; }
    operator HANDLE() const { return value; }
};
struct ScopeExit {
    std::function<void()> action;
    ~ScopeExit() { if (action) action(); }
};
}
