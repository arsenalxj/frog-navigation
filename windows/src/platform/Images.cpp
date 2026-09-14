#include "Images.h"
#include <wincodec.h>
#include <winhttp.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <regex>
#include <algorithm>

namespace frog {
namespace {
ComPtr<IWICImagingFactory> factory() {
    ComPtr<IWICImagingFactory> out;
    check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&out)), "无法初始化图像解码器。"); return out;
}
struct Internet {
    HINTERNET value{};
    ~Internet() { if (value) WinHttpCloseHandle(value); }
    operator HINTERNET() const { return value; }
};
std::wstring header(HINTERNET request, DWORD field) {
    DWORD size{}; WinHttpQueryHeaders(request, field, nullptr, nullptr, &size, nullptr);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || size > 65536) return {};
    std::wstring out(size / sizeof(wchar_t), 0);
    if (!WinHttpQueryHeaders(request, field, nullptr, out.data(), &size, nullptr)) return {};
    out.resize(size / sizeof(wchar_t)); while (!out.empty() && !out.back()) out.pop_back(); return out;
}
std::string combine(const std::string& base, const std::string& relative) {
    wchar_t buffer[16384]{}; DWORD size = 16384;
    check(UrlCombineW(wide(base).c_str(), wide(relative).c_str(), buffer, &size, 0), "图标地址无效。");
    auto out = utf8(buffer); require(validUrl(out), "图标地址仅允许 http 或 https。"); return out;
}
std::string download(std::string url, size_t limit, bool html, const std::function<bool()>& cancelled) {
    Internet session{WinHttpOpen(L"Frog/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)};
    require(session.value != nullptr, "无法建立网络会话。"); WinHttpSetTimeouts(session, 1200, 1200, 1500, 1500);
    double started = milliseconds();
    for (int redirects = 0; redirects <= 3; ++redirects) {
        require(!cancelled() && milliseconds() - started < 7000, "图标请求已取消或超时。");
        auto value = wide(url); URL_COMPONENTS parts{sizeof(parts)};
        parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = static_cast<DWORD>(-1);
        require(validUrl(url) && WinHttpCrackUrl(value.c_str(), 0, 0, &parts), "图标地址无效。");
        std::wstring host(parts.lpszHostName, parts.dwHostNameLength), path(parts.lpszUrlPath, parts.dwUrlPathLength);
        if (parts.dwExtraInfoLength) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
        if (path.empty()) path = L"/";
        Internet connection{WinHttpConnect(session, host.c_str(), parts.nPort, 0)}; require(connection.value != nullptr, "无法连接图标服务器。");
        Internet request{WinHttpOpenRequest(connection, L"GET", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)};
        require(request.value != nullptr, "无法建立图标请求。"); DWORD disable = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES;
        WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof(disable));
        require(WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) && !cancelled() && WinHttpReceiveResponse(request, nullptr), "图标请求失败。");
        DWORD status{}, bytes = sizeof(status); WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nullptr, &status, &bytes, nullptr);
        if (status >= 300 && status < 400) { require(redirects < 3, "图标重定向次数过多。"); url = combine(url, utf8(header(request, WINHTTP_QUERY_LOCATION))); continue; }
        require(status == 200, "图标服务器未返回有效内容。");
        auto type = lower(utf8(header(request, WINHTTP_QUERY_CONTENT_TYPE)));
        require(html ? (type.starts_with("text/html") || type.starts_with("application/xhtml")) : type.starts_with("image/"), "响应内容类型不正确。");
        std::string result;
        while (result.size() <= limit) {
            require(!cancelled() && milliseconds() - started < 7000, "图标请求已取消或超时。");
            char buffer[8192]{}; DWORD count{};
            DWORD wanted = static_cast<DWORD>(std::min<size_t>(sizeof(buffer), limit + 1 - result.size()));
            require(WinHttpReadData(request, buffer, wanted, &count), "读取图标失败。"); if (!count) return result;
            result.append(buffer, count);
            if (html && result.size() >= limit) { result.resize(limit); return result; }
        }
        throw Error("图标文件超过 2 MB。");
    }
    throw Error("图标重定向次数过多。");
}
}
std::shared_ptr<Pixels> decodeImage(const std::string& bytes, UINT size, bool square) {
    require(!bytes.empty() && bytes.size() <= documentLimit, "图像数据无效。");
    auto imaging = factory(); ComPtr<IWICStream> stream; check(imaging->CreateStream(&stream), "无法建立图像流。");
    check(stream->InitializeFromMemory(reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data())), static_cast<DWORD>(bytes.size())), "无法读取图像。");
    ComPtr<IWICBitmapDecoder> decoder; check(imaging->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder), "图像格式不受支持。");
    ComPtr<IWICBitmapFrameDecode> frame; UINT width{}, height{}, count{};
    check(decoder->GetFrameCount(&count), "无法读取图像帧。");
    // 与 macOS 一致，按有效短边选择最大的图像，避免放大 ICO 的低分辨率首帧。
    for (UINT index = 0; index < std::min(count, square ? 32u : 1u); ++index) {
        ComPtr<IWICBitmapFrameDecode> candidate; UINT candidateWidth{}, candidateHeight{};
        if (FAILED(decoder->GetFrame(index, &candidate)) || FAILED(candidate->GetSize(&candidateWidth, &candidateHeight))) continue;
        UINT limit = square ? 4096u : 16384u;
        if (!candidateWidth || !candidateHeight || candidateWidth > limit || candidateHeight > limit) continue;
        if (std::min(candidateWidth, candidateHeight) > std::min(width, height)) {
            frame = candidate; width = candidateWidth; height = candidateHeight;
        }
    }
    require(frame != nullptr, "图像尺寸超出限制或没有有效图像帧。");
    ComPtr<IWICBitmapSource> source;
    UINT targetWidth = size, targetHeight = size;
    if (square) {
        ComPtr<IWICBitmapClipper> clip; imaging->CreateBitmapClipper(&clip); UINT side = std::min(width, height);
        WICRect rect{static_cast<INT>((width - side) / 2), static_cast<INT>((height - side) / 2), static_cast<INT>(side), static_cast<INT>(side)};
        check(clip->Initialize(frame.Get(), &rect), "无法裁剪图标。"); clip.As(&source);
    } else { frame.As(&source); targetHeight = std::max(1u, static_cast<UINT>(static_cast<uint64_t>(height) * size / width)); require(targetHeight <= size * 8, "壁纸比例不受支持。"); }
    ComPtr<IWICBitmapScaler> scaler; imaging->CreateBitmapScaler(&scaler);
    check(scaler->Initialize(source.Get(), targetWidth, targetHeight, WICBitmapInterpolationModeFant), "无法缩放图像。");
    ComPtr<IWICFormatConverter> converter; imaging->CreateFormatConverter(&converter);
    check(converter->Initialize(scaler.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom), "无法转换图像格式。");
    auto out = std::make_shared<Pixels>(); out->width = targetWidth; out->height = targetHeight; out->bgra.resize(static_cast<size_t>(targetWidth) * targetHeight * 4);
    check(converter->CopyPixels(nullptr, targetWidth * 4, static_cast<UINT>(out->bgra.size()), out->bgra.data()), "无法读取图像像素。"); return out;
}
std::string encodePng(const Pixels& pixels) {
    auto imaging = factory(); ComPtr<IStream> stream; check(CreateStreamOnHGlobal(nullptr, TRUE, &stream), "无法编码图标。");
    ComPtr<IWICBitmapEncoder> encoder; imaging->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder); check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache), "无法初始化 PNG。");
    ComPtr<IWICBitmapFrameEncode> frame; ComPtr<IPropertyBag2> properties; encoder->CreateNewFrame(&frame, &properties); frame->Initialize(properties.Get()); frame->SetSize(pixels.width, pixels.height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA; check(frame->SetPixelFormat(&format), "无法设置 PNG 格式。");
    auto straight = pixels.bgra;
    for (size_t i = 0; i < straight.size(); i += 4) if (straight[i + 3]) for (size_t c = 0; c < 3; ++c) straight[i + c] = static_cast<unsigned char>(std::min(255, int(straight[i + c]) * 255 / straight[i + 3]));
    check(frame->WritePixels(pixels.height, pixels.width * 4, static_cast<UINT>(straight.size()), straight.data()), "无法写入 PNG。"); frame->Commit(); check(encoder->Commit(), "PNG 编码失败。");
    STATSTG stat{}; stream->Stat(&stat, STATFLAG_NONAME); LARGE_INTEGER zero{}; stream->Seek(zero, STREAM_SEEK_SET, nullptr);
    std::string out(static_cast<size_t>(stat.cbSize.QuadPart), 0); ULONG actual{}; stream->Read(out.data(), static_cast<ULONG>(out.size()), &actual); require(actual == out.size(), "PNG 编码不完整。"); return out;
}
std::vector<std::string> htmlIcons(const std::string& html, const std::string& baseUrl) {
    const std::regex tags(R"(<link\b[^>]{0,2048}>)", std::regex::icase);
    const std::regex attributes(R"rx(\b(rel|href)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))rx", std::regex::icase);
    std::vector<std::string> out;
    for (auto it = std::sregex_iterator(html.begin(), html.end(), tags); it != std::sregex_iterator() && out.size() < 6; ++it) {
        std::string tag = it->str(), rel, href;
        for (auto a = std::sregex_iterator(tag.begin(), tag.end(), attributes); a != std::sregex_iterator(); ++a) {
            auto value = (*a)[2].matched ? (*a)[2].str() : ((*a)[3].matched ? (*a)[3].str() : (*a)[4].str());
            if (lower((*a)[1].str()) == "rel") rel = lower(value); else href = value;
        }
        bool icon = false; std::istringstream tokens(rel); for (std::string token; tokens >> token;) if (token == "icon" || token == "apple-touch-icon") icon = true;
        if (!icon || href.empty()) continue;
        for (size_t at = 0; (at = href.find("&amp;", at)) != std::string::npos;) href.replace(at, 5, "&");
        try { out.push_back(combine(baseUrl, href)); } catch (const Error&) {}
    }
    return out;
}
Images::Images(fs::path cache, bool offline, Completion completion) : cache_(std::move(cache)), offline_(offline), completion_(std::move(completion)) {
    for (int i = 0; i < 2; ++i) workers_.emplace_back([this] { run(); });
}
Images::~Images() {
    { std::lock_guard lock(mutex_); stopping_ = true; ++generation_; jobs_.clear(); } condition_.notify_all();
    for (auto& worker : workers_) worker.join();
}
void Images::pause() { std::lock_guard lock(mutex_); paused_ = true; ++generation_; jobs_.clear(); pending_.clear(); }
void Images::resume() { std::lock_guard lock(mutex_); paused_ = false; }
void Images::request(const std::string& url, UINT size, bool refresh) {
    std::lock_guard lock(mutex_);
    if (paused_ || stopping_ || pending_.contains(url) || jobs_.size() >= 128) return;
    pending_.insert(url); jobs_.push_back({url, std::clamp(size, 32u, 192u), refresh, generation_.load(), {}}); condition_.notify_one();
}
void Images::wallpaper(HMONITOR monitor) {
    std::lock_guard lock(mutex_); if (paused_ || stopping_) return;
    jobs_.push_front({"__wallpaper__", 128, false, generation_.load(), monitor}); condition_.notify_one();
}
void Images::run() {
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ScopeExit cleanup{[&] { if (SUCCEEDED(initialized)) CoUninitialize(); }};
    for (;;) {
        Job job;
        { std::unique_lock lock(mutex_); condition_.wait(lock, [&] { return stopping_ || !jobs_.empty(); }); if (stopping_) return; job = jobs_.front(); jobs_.pop_front(); }
        std::shared_ptr<Pixels> pixels;
        try { pixels = job.monitor ? loadWallpaper(job.monitor) : load(job); } catch (const std::exception&) {}
        { std::lock_guard lock(mutex_); if (job.generation != generation_) continue; pending_.erase(job.url); }
        completion_(job.generation, job.url, std::move(pixels));
    }
}
std::shared_ptr<Pixels> Images::load(const Job& job) {
    auto path = cache_ / wide(hash(job.url) + ".png");
    auto cancelled = [&] { return job.generation != generation_.load(); };
    if (!job.refresh && fs::exists(path)) try { return decodeImage(readFile(path, 2 * 1024 * 1024), job.size); } catch (const std::exception&) {}
    if (offline_ || cancelled()) return {};
    auto value = wide(job.url); URL_COMPONENTS parts{sizeof(parts)}; parts.dwHostNameLength = static_cast<DWORD>(-1);
    require(WinHttpCrackUrl(value.c_str(), 0, 0, &parts), "无效的图标源地址。");
    auto origin = job.url.substr(0, job.url.find('/', job.url.find("://") + 3));
    std::shared_ptr<Pixels> result;
    auto attempt = [&](const std::string& url) { if (!cancelled()) try { result = decodeImage(download(url, 2 * 1024 * 1024, false, cancelled), job.size); } catch (const std::exception&) {} };
    attempt(origin + "/favicon.ico");
    if (!result && !cancelled()) try {
        auto html = download(origin + "/", 10240, true, cancelled);
        for (const auto& icon : htmlIcons(html, origin + "/")) { attempt(icon); if (result) break; }
    } catch (const std::exception&) {}
    if (!result) attempt("https://www.google.com/s2/favicons?domain=" + percentEncode(utf8(std::wstring(parts.lpszHostName, parts.dwHostNameLength))) + "&sz=128");
    if (result && !cancelled()) try { fs::create_directories(cache_); atomicWrite(path, encodePng(*result)); prune(); } catch (const std::exception&) {}
    return cancelled() ? nullptr : result;
}
std::shared_ptr<Pixels> Images::loadWallpaper(HMONITOR monitor) {
    ComPtr<IDesktopWallpaper> desktop; check(CoCreateInstance(CLSID_DesktopWallpaper, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&desktop)), "无法读取壁纸。");
    MONITORINFO info{sizeof(info)}; GetMonitorInfoW(monitor, &info); UINT count{}; desktop->GetMonitorDevicePathCount(&count);
    fs::path path;
    for (UINT i = 0; i < count; ++i) {
        LPWSTR device{}; if (FAILED(desktop->GetMonitorDevicePathAt(i, &device))) continue;
        RECT rect{}; desktop->GetMonitorRECT(device, &rect);
        if (EqualRect(&rect, &info.rcMonitor)) { LPWSTR wallpaper{}; if (SUCCEEDED(desktop->GetWallpaper(device, &wallpaper))) { path = wallpaper; CoTaskMemFree(wallpaper); } }
        CoTaskMemFree(device); if (!path.empty()) break;
    }
    if (path.empty()) { wchar_t wallpaper[32768]{}; SystemParametersInfoW(SPI_GETDESKWALLPAPER, 32768, wallpaper, 0); path = wallpaper; }
    if (path.empty()) return {};
    auto pixels = decodeImage(readFile(path), 128, false);
    // 在低分辨率壁纸上做可分离模糊，避免全屏离屏纹理的内存成本。
    for (int pass = 0; pass < 3; ++pass) {
        auto copy = pixels->bgra;
        for (UINT y = 0; y < pixels->height; ++y) for (UINT x = 0; x < pixels->width; ++x) {
            unsigned total[4]{}, countPixels{};
            for (int delta = -4; delta <= 4; ++delta) {
                int sx = static_cast<int>(x) + (pass % 2 == 0 ? delta : 0), sy = static_cast<int>(y) + (pass % 2 ? delta : 0);
                if (sx < 0 || sy < 0 || sx >= static_cast<int>(pixels->width) || sy >= static_cast<int>(pixels->height)) continue;
                size_t index = (static_cast<size_t>(sy) * pixels->width + sx) * 4; for (int c = 0; c < 4; ++c) total[c] += copy[index + c]; ++countPixels;
            }
            size_t index = (static_cast<size_t>(y) * pixels->width + x) * 4;
            for (int c = 0; c < 4; ++c) pixels->bgra[index + c] = static_cast<unsigned char>(total[c] / countPixels);
        }
    }
    return pixels;
}
void Images::prune() {
    std::vector<fs::directory_entry> files; uint64_t total = 0;
    for (const auto& entry : fs::directory_iterator(cache_)) if (entry.is_regular_file() && entry.path().extension() == L".png") { total += entry.file_size(); files.push_back(entry); }
    if (total <= 64 * 1024 * 1024) return;
    std::sort(files.begin(), files.end(), [](const auto& a, const auto& b) { return a.last_write_time() < b.last_write_time(); });
    for (const auto& entry : files) { if (total <= 48 * 1024 * 1024) break; auto size = entry.file_size(); if (DeleteFileW(entry.path().c_str())) total -= size; }
}
}
