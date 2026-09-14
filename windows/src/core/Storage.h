#pragma once
#include "Model.h"
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <atomic>

namespace frog {
constexpr size_t documentLimit = 32 * 1024 * 1024;
std::string readFile(const fs::path& path, size_t limit = documentLimit);
void atomicWrite(const fs::path& path, const std::string& bytes, const std::optional<std::string>& expected = {}, bool onlyMissing = false);
bool sameFile(const fs::path& left, const fs::path& right);
struct Snapshot { Document document; std::string bytes; fs::path directory; };
struct Conflict : Error { using Error::Error; };
class Storage {
public:
    Snapshot open(const fs::path& directory, bool createDirectory, const Document& seed = {}, bool initializeIfMissing = true);
    Snapshot reload();
    Snapshot save(const Document& document, const std::string& expected);
    void backup(const fs::path& destination, const Document& document);
    Snapshot restore(const fs::path& source, const std::string& expected);
private:
    std::mutex mutex_;
    fs::path directory_;
};
// 一个串行队列承载数据操作。UI 只在完成消息中提交快照。
class SerialQueue {
public:
    SerialQueue();
    ~SerialQueue();
    void post(std::function<void()> task);
private:
    std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<std::function<void()>> tasks_;
    bool stopping_ = false;
    std::thread worker_;
};
class DirectoryWatcher {
public:
    ~DirectoryWatcher();
    void start(const fs::path& directory, std::function<void()> callback);
    void stop();
    bool running() const { return running_.load(); }
private:
    Handle stopEvent_{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    std::thread worker_;
    std::atomic<bool> running_{false};
};
}
