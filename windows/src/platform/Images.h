#pragma once
#include "core/Storage.h"
#include <set>

namespace frog {
struct Pixels { UINT width{}, height{}; std::vector<unsigned char> bgra; };
std::shared_ptr<Pixels> decodeImage(const std::string& bytes, UINT size, bool square = true);
std::string encodePng(const Pixels& pixels);
std::vector<std::string> htmlIcons(const std::string& html, const std::string& baseUrl);
class Images {
public:
    using Completion = std::function<void(uint64_t, std::string, std::shared_ptr<Pixels>)>;
    Images(fs::path cache, bool offline, Completion completion);
    ~Images();
    void request(const std::string& url, UINT size, bool refresh = false);
    void wallpaper(HMONITOR monitor);
    void pause();
    void resume();
    uint64_t generation() const { return generation_.load(); }
private:
    struct Job { std::string url; UINT size; bool refresh; uint64_t generation; HMONITOR monitor{}; };
    void run();
    std::shared_ptr<Pixels> load(const Job& job);
    std::shared_ptr<Pixels> loadWallpaper(HMONITOR monitor);
    void prune();
    fs::path cache_; bool offline_{}; Completion completion_;
    std::mutex mutex_; std::condition_variable condition_;
    std::deque<Job> jobs_; std::set<std::string> pending_;
    bool stopping_ = false, paused_ = true;
    std::atomic<uint64_t> generation_{0};
    std::vector<std::thread> workers_;
};
}
