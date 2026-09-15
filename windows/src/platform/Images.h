#pragma once
#include "core/Storage.h"
#include <map>

namespace frog {
struct Pixels { UINT width{}, height{}; std::vector<unsigned char> bgra; };
std::shared_ptr<Pixels> decodeImage(const std::string& bytes, UINT size, bool square = true);
std::string encodePng(const Pixels& pixels);
std::vector<std::string> htmlIcons(const std::string& html, const std::string& baseUrl);
class Images {
public:
    enum class Source { cache, network, wallpaper };
    struct Result {
        uint64_t generation{}, request{};
        std::string url; std::shared_ptr<Pixels> pixels;
        Source source = Source::cache; bool deferred = false;
        double queueMs{}, loadMs{}, totalMs{};
    };
    using Completion = std::function<void(Result)>;
    Images(fs::path cache, bool offline, Completion completion);
    ~Images();
    // 返回本次请求的标识；重复请求共享标识，0 表示暂未接收。
    uint64_t request(const std::string& url, UINT size, bool refresh = false);
    uint64_t wallpaper(HMONITOR monitor);
    void pause();
    void resume();
    uint64_t generation() const { return generation_.load(); }
private:
    struct Job {
        std::string url; UINT size{}; bool refresh{}; uint64_t generation{}, request{}; HMONITOR monitor{};
        double requestedAt{}, queuedAt{}, queueMs{}, loadMs{};
    };
    void run(bool cacheWorker);
    bool current(const Job& job);
    bool currentLocked(const Job& job) const;
    void complete(const Job& job, std::shared_ptr<Pixels> pixels, Source source, bool deferred = false);
    std::shared_ptr<Pixels> loadCache(const Job& job);
    std::shared_ptr<Pixels> downloadIcon(const Job& job);
    std::shared_ptr<Pixels> loadWallpaper(HMONITOR monitor);
    void prune();
    fs::path cache_; bool offline_{}; Completion completion_;
    std::mutex mutex_, cacheWriteMutex_; std::condition_variable cacheCondition_, slowCondition_;
    std::deque<Job> cacheJobs_, slowJobs_; std::map<std::string, Job> pending_;
    uint64_t nextRequest_ = 0;
    bool stopping_ = false, paused_ = true;
    std::atomic<uint64_t> generation_{0};
    std::vector<std::thread> workers_;
};
}
