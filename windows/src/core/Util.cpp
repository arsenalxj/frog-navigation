#include "Util.h"
#include <shlobj.h>
#include <bcrypt.h>
#include <icu.h>
#include <iomanip>
#include <sstream>

namespace frog {
std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    require(n > 0, "文字不是有效的 UTF-8。");
    std::wstring out(n, 0);
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), out.data(), n);
    return out;
}
std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    require(n > 0, "文字包含无效的 Unicode 字符。");
    std::string out(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), n, nullptr, nullptr);
    return out;
}
std::string trim(const std::string& text) {
    auto value = wide(text);
    auto space = [](wchar_t c) { return iswspace(c) || c == 0x3000 || c == 0xA0; };
    size_t first = 0, last = value.size();
    while (first < last && space(value[first])) ++first;
    while (last > first && space(value[last - 1])) --last;
    return utf8(value.substr(first, last - first));
}
std::string lower(const std::string& text) {
    auto value = wide(text);
    if (value.empty()) return {};
    int n = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr, 0);
    std::wstring out(n, 0);
    LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(), static_cast<int>(value.size()), out.data(), n, nullptr, nullptr, 0);
    return utf8(out);
}
size_t characters(const std::string& text) {
    auto value = wide(text);
    UErrorCode error = U_ZERO_ERROR;
    auto* iterator = ubrk_open(UBRK_CHARACTER, "", reinterpret_cast<const UChar*>(value.data()), static_cast<int32_t>(value.size()), &error);
    require(U_SUCCESS(error) && iterator, "无法检查文字长度。");
    size_t count = 0;
    while (ubrk_next(iterator) != UBRK_DONE) ++count;
    ubrk_close(iterator);
    return count;
}
std::string uuid() {
    GUID value{}; check(CoCreateGuid(&value), "无法创建 ID。");
    wchar_t buffer[40]{}; StringFromGUID2(value, buffer, 40);
    return utf8(std::wstring(buffer + 1, 36));
}
std::string hash(const std::string& text) {
    BCRYPT_ALG_HANDLE algorithm{};
    require(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0, "无法初始化 SHA-256。");
    ScopeExit cleanup{[&] { BCryptCloseAlgorithmProvider(algorithm, 0); }};
    unsigned char digest[32]{};
    require(BCryptHash(algorithm, nullptr, 0, reinterpret_cast<PUCHAR>(const_cast<char*>(text.data())), static_cast<ULONG>(text.size()), digest, 32) == 0, "SHA-256 计算失败。");
    std::ostringstream out;
    for (auto c : digest) out << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(c);
    return out.str();
}
std::string winError(const std::string& operation, DWORD code) {
    wchar_t* message{};
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, code, 0, reinterpret_cast<LPWSTR>(&message), 0, nullptr);
    std::string out = operation + "：" + (message ? utf8(message) : std::to_string(code));
    if (message) LocalFree(message);
    return out;
}
fs::path localDirectory() {
    PWSTR value{}; check(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &value), "无法读取本地应用数据目录。");
    fs::path result(value); CoTaskMemFree(value); return result / L"Frog";
}
fs::path executablePath() {
    std::wstring out(32768, 0); DWORD n = GetModuleFileNameW(nullptr, out.data(), static_cast<DWORD>(out.size()));
    require(n > 0 && n < out.size(), "无法读取应用路径。"); out.resize(n); return out;
}
std::wstring windowText(HWND window) {
    std::wstring out(GetWindowTextLengthW(window) + 1, 0);
    int n = GetWindowTextW(window, out.data(), static_cast<int>(out.size())); out.resize(n); return out;
}
double milliseconds() {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
std::string percentEncode(const std::string& text) {
    const char* digits = "0123456789ABCDEF"; std::string out;
    for (unsigned char c : text) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~') out += c;
        else { out += '%'; out += digits[c >> 4]; out += digits[c & 15]; }
    }
    return out;
}
void require(bool condition, const std::string& message) { if (!condition) throw Error(message); }
void check(HRESULT result, const std::string& message) { if (FAILED(result)) throw Error(winError(message, static_cast<DWORD>(result))); }
}
