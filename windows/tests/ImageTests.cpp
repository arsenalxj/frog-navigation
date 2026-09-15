#include <winsock2.h>
#include <ws2tcpip.h>
#include "platform/Images.h"
#include <future>
#include <iostream>
#include <set>

using namespace frog;
namespace {
void expect(bool value, const char* message) { require(value, message); }
struct Temporary {
    fs::path path = fs::temp_directory_path() / wide("Frog-images-" + uuid());
    Temporary() { fs::create_directories(path); }
    ~Temporary() { std::error_code ec; fs::remove_all(path, ec); }
};
// 本机服务器通过条件变量控制响应，测试先确认请求已到达，再检查缓存能否完成。
class IconServer {
public:
    explicit IconServer(std::string body) : body_(std::move(body)) {
        WSADATA data{}; require(WSAStartup(MAKEWORD(2, 2), &data) == 0, "无法初始化测试网络。");
        listener_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); require(listener_ != INVALID_SOCKET, "无法创建测试服务器。");
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        require(bind(listener_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0 && listen(listener_, 16) == 0, "无法监听测试端口。");
        int length = sizeof(address); getsockname(listener_, reinterpret_cast<sockaddr*>(&address), &length); port_ = ntohs(address.sin_port);
        acceptor_ = std::thread([this] {
            while (!stopping_) {
                fd_set ready; FD_ZERO(&ready); FD_SET(listener_, &ready); timeval timeout{0, 100000};
                if (select(0, &ready, nullptr, nullptr, &timeout) <= 0) continue;
                auto client = accept(listener_, nullptr, nullptr); if (client == INVALID_SOCKET) continue;
                clients_.push_back(client); workers_.emplace_back([this, client] { respond(client); });
            }
        });
    }
    ~IconServer() {
        stopping_ = true; release(); acceptor_.join(); closesocket(listener_);
        for (auto client : clients_) shutdown(client, SD_BOTH);
        for (auto& worker : workers_) worker.join();
        for (auto client : clients_) closesocket(client);
        WSACleanup();
    }
    std::string url(const char* path) const { return "http://127.0.0.1:" + std::to_string(port_) + path; }
    bool waitRequests(size_t count) { std::unique_lock lock(mutex_); return condition_.wait_for(lock, std::chrono::seconds(3), [&] { return requests_ >= count; }); }
    void release() { { std::lock_guard lock(mutex_); released_ = true; } condition_.notify_all(); }
    void releaseRequest(size_t number) { { std::lock_guard lock(mutex_); releasedRequests_.insert(number); } condition_.notify_all(); }
    void setBody(std::string body) { std::lock_guard lock(mutex_); body_ = std::move(body); }
private:
    void respond(SOCKET client) {
        std::string request; char buffer[1024];
        while (request.find("\r\n\r\n") == std::string::npos && request.size() < 8192) { int count = recv(client, buffer, sizeof(buffer), 0); if (count <= 0) return; request.append(buffer, count); }
        std::string body;
        { std::unique_lock lock(mutex_); auto number = ++requests_; body = body_; condition_.notify_all(); condition_.wait(lock, [&] { return released_ || releasedRequests_.contains(number) || stopping_; }); }
        if (stopping_) return;
        auto response = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\nContent-Length: " + std::to_string(body.size()) + "\r\n\r\n" + body;
        size_t sent = 0; while (sent < response.size()) { int count = send(client, response.data() + sent, static_cast<int>(response.size() - sent), 0); if (count <= 0) break; sent += count; }
        shutdown(client, SD_SEND);
    }
    SOCKET listener_ = INVALID_SOCKET; unsigned short port_{};
    std::atomic<bool> stopping_{false}; std::thread acceptor_; std::vector<std::thread> workers_; std::vector<SOCKET> clients_;
    std::mutex mutex_; std::condition_variable condition_; bool released_ = false; size_t requests_ = 0; std::string body_; std::set<size_t> releasedRequests_;
};
class Results {
public:
    void add(Images::Result result) { { std::lock_guard lock(mutex_); values_.push_back(std::move(result)); } condition_.notify_all(); }
    Images::Result get(uint64_t request, int timeout = 3000) {
        std::unique_lock lock(mutex_);
        auto find = [&] { return std::find_if(values_.begin(), values_.end(), [&](const auto& value) { return value.request == request; }); };
        expect(condition_.wait_for(lock, std::chrono::milliseconds(timeout), [&] { return find() != values_.end(); }), "等待图标结果超时。");
        return *find();
    }
    size_t size() { std::lock_guard lock(mutex_); return values_.size(); }
private:
    std::mutex mutex_; std::condition_variable condition_; std::vector<Images::Result> values_;
};
std::string solidPng(unsigned char red, unsigned char green, unsigned char blue) {
    Pixels icon{72, 72, std::vector<unsigned char>(72 * 72 * 4, 255)};
    for (size_t i = 0; i < icon.bgra.size(); i += 4) { icon.bgra[i] = blue; icon.bgra[i + 1] = green; icon.bgra[i + 2] = red; }
    return encodePng(icon);
}
}
int wmain() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED); ScopeExit com{[] { CoUninitialize(); }};
    try {
        Temporary temp; Pixels icon{72, 72, std::vector<unsigned char>(72 * 72 * 4, 255)}; auto png = encodePng(icon);
        const std::string cachedUrl = "https://cached.example/bookmark"; atomicWrite(temp.path / wide(hash(cachedUrl) + ".png"), png);
        IconServer server(png); std::promise<std::shared_ptr<Pixels>> ready; auto loaded = ready.get_future();
        Images images(temp.path, false, [&](Images::Result result) { if (result.url == cachedUrl) ready.set_value(std::move(result.pixels)); });
        ScopeExit release{[&] { server.release(); }};
        images.resume(); images.request(server.url("/one"), 72); images.request(server.url("/two"), 72);
        expect(server.waitRequests(2), "两个网络请求没有进入等待状态。");
        auto start = milliseconds(); images.request(cachedUrl, 72);
        expect(loaded.wait_for(std::chrono::milliseconds(750)) == std::future_status::ready, "已有缓存被两个等待响应的网络请求阻塞。");
        expect(loaded.get() != nullptr, "已有缓存没有成功解码。");
        std::cout << "PASS cached-icons-bypass-blocked-downloads " << milliseconds() - start << " ms\n";
        images.pause(); server.release();

        {
            Temporary cache; IconServer blocked(png); Results results;
            auto url = blocked.url("/one"); atomicWrite(cache.path / wide(hash(cachedUrl) + ".png"), png);
            Images loader(cache.path, false, [&](Images::Result result) { results.add(std::move(result)); });
            ScopeExit unblock{[&] { blocked.release(); }};
            loader.resume(); auto oldRequest = loader.request(url, 32); loader.request(blocked.url("/two"), 32);
            expect(blocked.waitRequests(2), "重开测试的网络任务未就绪。");
            loader.pause(); expect(loader.request(cachedUrl, 72) == 0, "暂停时仍接收了任务。");
            atomicWrite(cache.path / wide(hash(url) + ".png"), png); loader.resume();
            auto newRequest = loader.request(url, 96); expect(newRequest != oldRequest, "重开复用了旧请求标识。");
            auto result = results.get(newRequest, 750);
            expect(result.generation == loader.generation() && result.pixels && result.pixels->width == 96 && result.source == Images::Source::cache, "重开结果的代次、尺寸或来源错误。");
            blocked.release(); loader.pause();
            std::cout << "PASS reopen-cache-while-old-downloads-are-blocked\n";
        }
        {
            Temporary cache; IconServer blocked(solidPng(255, 0, 0)); Results results; auto url = blocked.url("/refresh");
            {
                Images loader(cache.path, false, [&](Images::Result result) { results.add(std::move(result)); }); ScopeExit unblock{[&] { blocked.release(); }};
                loader.resume(); auto oldRequest = loader.request(url, 32);
                expect(blocked.waitRequests(1), "旧图标请求未到达服务器。");
                expect(loader.request(url, 32) == oldRequest, "相同请求没有去重。");
                blocked.setBody(solidPng(0, 0, 255)); auto refresh = loader.request(url, 144, true);
                expect(refresh != oldRequest && loader.request(url, 72) == refresh, "刷新或尺寸升级没有正确合并。");
                expect(blocked.waitRequests(2), "刷新请求未开始。"); blocked.releaseRequest(2);
                auto result = results.get(refresh);
                expect(result.pixels && result.pixels->width == 144 && result.pixels->bgra[0] == 255 && result.pixels->bgra[2] == 0, "刷新没有返回新的蓝色图标。");
                blocked.releaseRequest(1);
            }
            auto cached = decodeImage(readFile(cache.path / wide(hash(url) + ".png")), 144);
            expect(results.size() == 1 && cached->bgra[0] == 255 && cached->bgra[2] == 0, "旧请求覆盖了刷新结果或发出了过期回调。");
            std::cout << "PASS duplicate-size-refresh-and-stale-download\n";
        }
        {
            Temporary cache; IconServer online(png); online.release(); Results results; auto url = online.url("/corrupt");
            auto path = cache.path / wide(hash(url) + ".png"); atomicWrite(path, "broken cache");
            Images loader(cache.path, false, [&](Images::Result result) { results.add(std::move(result)); }); loader.resume();
            auto repaired = results.get(loader.request(url, 72));
            expect(repaired.pixels && repaired.source == Images::Source::network && decodeImage(readFile(path), 72)->bgra == icon.bgra, "损坏缓存没有通过下载恢复。");
            auto before = readFile(path); online.setBody("invalid image"); auto failed = results.get(loader.request(url, 72, true));
            expect(!failed.pixels && !failed.deferred && readFile(path) == before, "刷新失败改写了已有缓存。");
            auto cached = results.get(loader.request(url, 96)); expect(cached.pixels && cached.source == Images::Source::cache && cached.pixels->width == 96, "失败后已有缓存不能继续使用。");
            std::cout << "PASS corrupt-cache-recovery-and-failed-refresh-preserves-cache\n";
        }
        {
            Temporary cache; IconServer blocked(png); Results results;
            atomicWrite(cache.path / wide(hash(cachedUrl) + ".png"), png);
            Images loader(cache.path, false, [&](Images::Result result) { results.add(std::move(result)); }); ScopeExit unblock{[&] { blocked.release(); }};
            loader.resume(); loader.request(blocked.url("/one"), 72); loader.request(blocked.url("/two"), 72);
            expect(blocked.waitRequests(2), "队列容量测试未进入网络等待。");
            for (int i = 0; i < 128; ++i) expect(loader.request(blocked.url(("/queued-" + std::to_string(i)).c_str()), 72, true) != 0, "网络队列提前拒绝任务。");
            expect(loader.request(blocked.url("/overflow"), 72, true) == 0, "网络队列没有限制容量。");
            auto cached = results.get(loader.request(cachedUrl, 72), 750); expect(cached.pixels && cached.source == Images::Source::cache, "已满的网络队列阻止了缓存读取。");
            auto deferred = results.get(loader.request(blocked.url("/deferred"), 72), 750); expect(deferred.deferred && !deferred.pixels, "网络队列满时没有反馈可重试状态。");
            loader.pause(); blocked.release();
            std::cout << "PASS network-capacity-does-not-starve-cache\n";
        }
        {
            Temporary cache; atomicWrite(cache.path / wide(hash(cachedUrl) + ".png"), png); Results results;
            std::promise<void> entered, unblock; auto resumed = unblock.get_future().share();
            Images loader(cache.path, true, [&](Images::Result result) { if (result.url == cachedUrl) { entered.set_value(); resumed.wait(); } results.add(std::move(result)); });
            ScopeExit releaseCallback{[&] { unblock.set_value(); }};
            loader.resume(); loader.request(cachedUrl, 72); expect(entered.get_future().wait_for(std::chrono::seconds(3)) == std::future_status::ready, "缓存容量测试未就绪。");
            for (int i = 0; i < 128; ++i) expect(loader.request("https://offline.example/" + std::to_string(i), 72) != 0, "缓存队列提前拒绝任务。");
            expect(loader.request("https://offline.example/overflow", 72) == 0, "缓存队列没有反馈容量限制。");
            loader.pause();
            std::cout << "PASS cache-capacity-is-bounded-and-reported\n";
        }
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL image-cache: " << error.what() << '\n'; return 1; }
}
