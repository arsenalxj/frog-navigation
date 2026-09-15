#include "Images.h"
#include <wincodec.h>
#include <winhttp.h>
#include <shobjidl.h>
#include <shlwapi.h>
#include <d2d1_3.h>
#include <d2d1svg.h>
#include <d3d11.h>
#include <cmath>
#include <regex>
#include <algorithm>

namespace frog {
namespace {
ComPtr<IWICImagingFactory> factory() {
    ComPtr<IWICImagingFactory> out;
    check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&out)), "无法初始化图像解码器。"); return out;
}
std::shared_ptr<Pixels> decodeSvg(const std::string& bytes, UINT size) {
    require(bytes.size() <= 2 * 1024 * 1024 && size > 0 && size <= 256, "SVG 图标尺寸超出限制。");
    // 独立的软件渲染设备不依赖启动台窗口或显卡，随本次解码释放。
    ComPtr<ID3D11Device> graphics;
    check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                           nullptr, 0, D3D11_SDK_VERSION, &graphics, nullptr, nullptr), "无法初始化 SVG 渲染设备。");
    ComPtr<IDXGIDevice> dxgi; check(graphics.As(&dxgi), "无法初始化 SVG 图像设备。");
    ComPtr<ID2D1Device> device; check(D2D1CreateDevice(dxgi.Get(), nullptr, &device), "无法初始化 SVG 绘图设备。");
    ComPtr<ID2D1DeviceContext> base;
    check(device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &base), "无法初始化 SVG 绘图上下文。");
    ComPtr<ID2D1DeviceContext5> context; check(base.As(&context), "系统不支持原生 SVG 图标。");
    ComPtr<IStream> stream;
    stream.Attach(SHCreateMemStream(reinterpret_cast<const BYTE*>(bytes.data()), static_cast<UINT>(bytes.size())));
    require(stream != nullptr, "无法读取 SVG 图标。");
    const float targetSize = static_cast<float>(size);
    ComPtr<ID2D1SvgDocument> document;
    check(context->CreateSvgDocument(stream.Get(), D2D1::SizeF(targetSize, targetSize), &document), "SVG 文档无效。");
    ComPtr<ID2D1SvgElement> root; document->GetRoot(&root);
    require(root != nullptr && root->GetTagNameLength() == 3, "图像不是 SVG 文档。");
    wchar_t tag[4]{}; check(root->GetTagName(tag, 4), "无法读取 SVG 根元素。");
    require(std::wstring(tag) == L"svg", "图像不是 SVG 文档。");

    D2D1_SVG_VIEWBOX viewBox{};
    const bool hasViewBox = root->IsAttributeSpecified(L"viewBox");
    if (hasViewBox) {
        check(root->GetAttributeValue(L"viewBox", D2D1_SVG_ATTRIBUTE_POD_TYPE_VIEWBOX, &viewBox, sizeof(viewBox)), "SVG viewBox 无效。");
        require(std::isfinite(viewBox.x) && std::isfinite(viewBox.y) && std::isfinite(viewBox.width) &&
                std::isfinite(viewBox.height) && viewBox.width > 0 && viewBox.height > 0, "SVG viewBox 尺寸无效。");
    }
    auto dimension = [&](const wchar_t* name, float fallback) {
        if (!root->IsAttributeSpecified(name)) return fallback;
        D2D1_SVG_LENGTH length{};
        check(root->GetAttributeValue(name, &length), "SVG 宽高无效。");
        require(std::isfinite(length.value) && length.value > 0, "SVG 宽高无效。");
        return length.units == D2D1_SVG_LENGTH_UNITS_PERCENTAGE ? fallback * length.value / 100.0f : length.value;
    };
    const float width = dimension(L"width", hasViewBox ? viewBox.width : targetSize);
    const float height = dimension(L"height", hasViewBox ? viewBox.height : targetSize);
    require(std::isfinite(width) && std::isfinite(height) && width > 0 && height > 0 && width <= 4096 && height <= 4096,
            "SVG 图标尺寸超出限制。");
    // 明确根视口后再按短边放大并居中裁剪，与现有位图图标的铺满规则一致。
    check(document->SetViewportSize(D2D1::SizeF(width, height)), "无法设置 SVG 视口。");
    check(root->SetAttributeValue(L"width", D2D1_SVG_LENGTH{width, D2D1_SVG_LENGTH_UNITS_NUMBER}), "无法设置 SVG 宽度。");
    check(root->SetAttributeValue(L"height", D2D1_SVG_LENGTH{height, D2D1_SVG_LENGTH_UNITS_NUMBER}), "无法设置 SVG 高度。");

    const auto format = D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED);
    ComPtr<ID2D1Bitmap1> target;
    auto targetProperties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET, format, 96, 96);
    check(context->CreateBitmap(D2D1::SizeU(size, size), nullptr, 0, &targetProperties, &target), "无法创建 SVG 图像。");
    context->SetTarget(target.Get()); context->SetDpi(96, 96);
    const float scale = targetSize / std::min(width, height);
    require(std::isfinite(scale) && std::isfinite(width * scale) && std::isfinite(height * scale), "SVG 图标比例超出限制。");
    context->SetTransform(D2D1::Matrix3x2F::Scale(scale, scale) *
                          D2D1::Matrix3x2F::Translation((targetSize - width * scale) / 2, (targetSize - height * scale) / 2));
    context->BeginDraw(); context->Clear(D2D1::ColorF(0, 0, 0, 0)); context->DrawSvgDocument(document.Get());
    check(context->EndDraw(), "SVG 图标渲染失败。");
    context->SetTarget(nullptr);

    ComPtr<ID2D1Bitmap1> readable;
    auto readProperties = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW, format, 96, 96);
    check(context->CreateBitmap(D2D1::SizeU(size, size), nullptr, 0, &readProperties, &readable), "无法创建 SVG 像素缓冲。");
    check(readable->CopyFromBitmap(nullptr, target.Get(), nullptr), "无法复制 SVG 图像。");
    D2D1_MAPPED_RECT mapped{}; check(readable->Map(D2D1_MAP_OPTIONS_READ, &mapped), "无法读取 SVG 像素。");
    ScopeExit unmap{[&] { readable->Unmap(); }};
    auto out = std::make_shared<Pixels>(); out->width = out->height = size; out->bgra.resize(static_cast<size_t>(size) * size * 4);
    for (UINT y = 0; y < size; ++y) std::copy_n(mapped.bits + static_cast<size_t>(y) * mapped.pitch, size * 4, out->bgra.data() + static_cast<size_t>(y) * size * 4);
    return out;
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
    ComPtr<IWICBitmapDecoder> decoder;
    const HRESULT decoded = imaging->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(decoded) && square) return decodeSvg(bytes, size);
    check(decoded, "图像格式不受支持。");
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
    workers_.emplace_back([this] { run(true); });
    for (int i = 0; i < 2; ++i) workers_.emplace_back([this] { run(false); });
}
Images::~Images() {
    { std::lock_guard lock(mutex_); stopping_ = true; ++generation_; cacheJobs_.clear(); slowJobs_.clear(); pending_.clear(); }
    cacheCondition_.notify_all(); slowCondition_.notify_all();
    for (auto& worker : workers_) worker.join();
}
void Images::pause() { std::lock_guard lock(mutex_); paused_ = true; ++generation_; cacheJobs_.clear(); slowJobs_.clear(); pending_.clear(); }
void Images::resume() { std::lock_guard lock(mutex_); paused_ = false; }
uint64_t Images::request(const std::string& url, UINT size, bool refresh) {
    std::lock_guard lock(mutex_);
    if (paused_ || stopping_) return 0;
    size = std::clamp(size, 32u, 192u); refresh = refresh && !offline_;
    if (auto it = pending_.find(url); it != pending_.end()) {
        if (it->second.size >= size && (!refresh || it->second.refresh)) return it->second.request;
        size = std::max(size, it->second.size); refresh = refresh || it->second.refresh;
    }
    auto& queue = refresh ? slowJobs_ : cacheJobs_;
    if (queue.size() >= 128 && std::none_of(queue.begin(), queue.end(), [&](const Job& job) { return job.url == url; })) return 0;
    // 同一 URL 的较大尺寸或显式刷新取代旧任务；进行中的任务通过标识检查失效。
    std::erase_if(cacheJobs_, [&](const Job& job) { return job.url == url; });
    std::erase_if(slowJobs_, [&](const Job& job) { return job.url == url; });
    auto now = milliseconds(); Job job{url, size, refresh, generation_.load(), ++nextRequest_, {}, now, now};
    pending_[url] = job; queue.push_back(job);
    (refresh ? slowCondition_ : cacheCondition_).notify_one(); return job.request;
}
uint64_t Images::wallpaper(HMONITOR monitor) {
    std::lock_guard lock(mutex_); if (paused_ || stopping_ || !monitor) return 0;
    if (auto it = pending_.find("__wallpaper__"); it != pending_.end() && it->second.monitor == monitor) return it->second.request;
    std::erase_if(slowJobs_, [](const Job& job) { return job.monitor != nullptr; });
    auto now = milliseconds(); Job job{"__wallpaper__", 128, false, generation_.load(), ++nextRequest_, monitor, now, now};
    pending_[job.url] = job; slowJobs_.push_front(job); slowCondition_.notify_one(); return job.request;
}
bool Images::currentLocked(const Job& job) const {
    auto it = pending_.find(job.url);
    return !stopping_ && !paused_ && job.generation == generation_ && it != pending_.end() && it->second.request == job.request;
}
bool Images::current(const Job& job) { std::lock_guard lock(mutex_); return currentLocked(job); }
void Images::complete(const Job& job, std::shared_ptr<Pixels> pixels, Source source, bool deferred) {
    { std::lock_guard lock(mutex_); if (!currentLocked(job)) return; pending_.erase(job.url); }
    completion_({job.generation, job.request, job.url, std::move(pixels), source, deferred, job.queueMs, job.loadMs, milliseconds() - job.requestedAt});
}
void Images::run(bool cacheWorker) {
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ScopeExit cleanup{[&] { if (SUCCEEDED(initialized)) CoUninitialize(); }};
    auto& queue = cacheWorker ? cacheJobs_ : slowJobs_;
    auto& condition = cacheWorker ? cacheCondition_ : slowCondition_;
    for (;;) {
        Job job;
        { std::unique_lock lock(mutex_); condition.wait(lock, [&] { return stopping_ || !queue.empty(); }); if (stopping_) return;
            job = std::move(queue.front()); queue.pop_front(); if (!currentLocked(job)) continue; }
        auto started = milliseconds(); job.queueMs += started - job.queuedAt;
        std::shared_ptr<Pixels> pixels;
        try { pixels = cacheWorker ? loadCache(job) : (job.monitor ? loadWallpaper(job.monitor) : downloadIcon(job)); } catch (const std::exception&) {}
        job.loadMs += milliseconds() - started;
        bool deferred = false;
        if (cacheWorker && !pixels && !offline_) {
            std::lock_guard lock(mutex_); if (!currentLocked(job)) continue;
            if (slowJobs_.size() < 128) { job.queuedAt = milliseconds(); slowJobs_.push_back(job); slowCondition_.notify_one(); continue; }
            deferred = true;
        }
        complete(job, std::move(pixels), cacheWorker ? Source::cache : (job.monitor ? Source::wallpaper : Source::network), deferred);
    }
}
std::shared_ptr<Pixels> Images::loadCache(const Job& job) {
    auto path = cache_ / wide(hash(job.url) + ".png");
    if (current(job) && fs::exists(path)) return decodeImage(readFile(path, 2 * 1024 * 1024), job.size);
    return {};
}
std::shared_ptr<Pixels> Images::downloadIcon(const Job& job) {
    auto cancelled = [&] { return !current(job); };
    if (offline_ || cancelled()) return {};
    require(validUrl(job.url), "无效的图标源地址。");
    auto origin = job.url.substr(0, job.url.find('/', job.url.find("://") + 3));
    std::shared_ptr<Pixels> result;
    auto attempt = [&](const std::string& url) { if (!cancelled()) try { result = decodeImage(download(url, 2 * 1024 * 1024, false, cancelled), job.size); } catch (const std::exception&) {} };
    attempt(origin + "/favicon.ico");
    if (!result && !cancelled()) try {
        auto html = download(origin + "/", 10240, true, cancelled);
        for (const auto& icon : htmlIcons(html, origin + "/")) { attempt(icon); if (result) break; }
    } catch (const std::exception&) {}
    if (result && !cancelled()) try {
        auto png = encodePng(*result);
        // 缓存发布串行化，避免已经被取代的下载在新结果之后写回旧图；不占用任务队列锁。
        std::lock_guard lock(cacheWriteMutex_);
        if (!cancelled()) { fs::create_directories(cache_); atomicWrite(cache_ / wide(hash(job.url) + ".png"), png); prune(); }
    } catch (const std::exception&) {}
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
