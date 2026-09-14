#include "Storage.h"
#include <algorithm>

namespace frog {
std::string readFile(const fs::path& path, size_t limit) {
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    require(file.valid(), winError("无法读取 " + utf8(path.filename().wstring())));
    BY_HANDLE_FILE_INFORMATION info{};
    require(GetFileInformationByHandle(file, &info) && !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY), "数据必须是普通文件。");
    LARGE_INTEGER size{};
    require(GetFileSizeEx(file, &size) && size.QuadPart >= 0 && static_cast<uint64_t>(size.QuadPart) <= limit, "文件超过允许的大小。");
    std::string out(static_cast<size_t>(size.QuadPart), 0); size_t offset = 0;
    while (offset < out.size()) {
        DWORD actual{};
        require(ReadFile(file, out.data() + offset, static_cast<DWORD>(std::min<size_t>(out.size() - offset, 65536)), &actual, nullptr) && actual, "文件在读取时发生变化，请重试。");
        offset += actual;
    }
    char extra{}; DWORD actual{};
    require(ReadFile(file, &extra, 1, &actual, nullptr) && actual == 0, "文件在读取时发生变化，请重试。");
    return out;
}
bool sameFile(const fs::path& left, const fs::path& right) {
    std::error_code ec;
    if (fs::equivalent(left, right, ec)) return true;
    return lower(utf8(fs::weakly_canonical(left).wstring())) == lower(utf8(fs::weakly_canonical(right).wstring()));
}
void atomicWrite(const fs::path& path, const std::string& bytes, const std::optional<std::string>& expected, bool onlyMissing) {
    require(bytes.size() <= documentLimit, "书签数据超过 32 MB，原文件保持不变。");
    require(fs::is_directory(path.parent_path()), "数据目录不存在或暂时不可用，请恢复目录后重试。");
    auto temporary = path.parent_path() / wide(".frog-" + uuid() + ".tmp");
    ScopeExit cleanup{[&] { DeleteFileW(temporary.c_str()); }};
    {
        Handle file(CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr));
        require(file.valid(), winError("无法创建临时文件，请检查目录权限"));
        size_t offset = 0;
        while (offset < bytes.size()) {
            DWORD written{};
            require(WriteFile(file, bytes.data() + offset, static_cast<DWORD>(std::min<size_t>(65536, bytes.size() - offset)), &written, nullptr) && written, winError("写入失败")); offset += written;
        }
        require(FlushFileBuffers(file), winError("无法同步数据到磁盘"));
    }
    if (expected) {
        const auto current = readFile(path);
        if (current != *expected) throw Conflict("检测到外部更新，已保留未提交的输入。请重试本次修改。");
    }
    if (onlyMissing || !fs::exists(path)) {
        require(!expected, "数据文件暂时缺失，请恢复 bookmarks.json 后重试。");
        require(MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH), winError("目标已变化或无法保存，请重新读取"));
        return;
    }
    // 保存旧文件直到核对完成，以保留快照检查与替换间到达的外部版本。
    auto backup = path.parent_path() / wide(".frog-conflict-" + uuid() + ".json");
    if (!ReplaceFileW(path.c_str(), temporary.c_str(), backup.c_str(), 0, nullptr, nullptr)) {
        DWORD error = GetLastError();
        if (!fs::exists(path) && fs::exists(backup)) MoveFileExW(backup.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH);
        throw Error(winError("原子替换失败，请重试", error) + (fs::exists(backup) ? " 原始文件副本保存在 " + utf8(backup.wstring()) : ""));
    }
    if (expected && readFile(backup) != *expected) {
        if (readFile(path) == bytes) {
            auto recovery = path.parent_path() / wide(".frog-conflict-" + uuid() + ".json");
            require(ReplaceFileW(path.c_str(), backup.c_str(), recovery.c_str(), 0, nullptr, nullptr), "检测到并发更新，外部版本保存在 " + utf8(backup.wstring()) + "，请恢复该文件后重试。");
            if (readFile(recovery) == bytes) DeleteFileW(recovery.c_str());
            else throw Conflict("再次收到并发更新，附加版本保存在 " + utf8(recovery.wstring()) + "。草稿已保留，请核对后重试。");
        }
        throw Conflict("保存时收到外部更新，已保留外部版本和编辑草稿，请重新读取并重试。");
    }
    DeleteFileW(backup.c_str());
}
Snapshot Storage::open(const fs::path& directory, bool createDirectory, const Document& seed, bool initializeIfMissing) {
    std::lock_guard lock(mutex_);
    if (createDirectory) fs::create_directories(directory);
    require(fs::is_directory(directory), "所选目录不存在或暂时不可用。");
    auto path = directory / L"bookmarks.json";
    if (!fs::exists(path)) {
        require(initializeIfMissing, "已配置的数据文件暂时缺失，请恢复 bookmarks.json 后重试，或选择其他数据目录。");
        atomicWrite(path, seed.encode(), {}, true);
    }
    auto bytes = readFile(path); auto document = Document::decode(bytes);
    directory_ = fs::weakly_canonical(directory);
    return {std::move(document), std::move(bytes), directory_};
}
Snapshot Storage::reload() {
    std::lock_guard lock(mutex_);
    require(!directory_.empty(), "数据尚未成功载入，请选择数据目录或重试读取。");
    auto bytes = readFile(directory_ / L"bookmarks.json"); return {Document::decode(bytes), std::move(bytes), directory_};
}
Snapshot Storage::save(const Document& document, const std::string& expected) {
    std::lock_guard lock(mutex_);
    require(!directory_.empty(), "数据尚未成功载入，无法保存。");
    auto bytes = document.encode(); atomicWrite(directory_ / L"bookmarks.json", bytes, expected);
    return {document, std::move(bytes), directory_};
}
void Storage::backup(const fs::path& destination, const Document& document) {
    std::lock_guard lock(mutex_);
    require(!sameFile(destination, directory_ / L"bookmarks.json"), "备份位置不能是正在使用的 bookmarks.json，请另选位置。");
    atomicWrite(destination, document.encode());
}
Snapshot Storage::restore(const fs::path& source, const std::string& expected) {
    auto document = Document::decode(readFile(source)); return save(document, expected);
}
SerialQueue::SerialQueue() : worker_([this] {
    for (;;) {
        std::function<void()> task;
        { std::unique_lock lock(mutex_); condition_.wait(lock, [&] { return stopping_ || !tasks_.empty(); });
          if (stopping_ && tasks_.empty()) return; task = std::move(tasks_.front()); tasks_.pop_front(); }
        task();
    }
}) {}
SerialQueue::~SerialQueue() {
    { std::lock_guard lock(mutex_); stopping_ = true; } condition_.notify_all(); if (worker_.joinable()) worker_.join();
}
void SerialQueue::post(std::function<void()> task) {
    { std::lock_guard lock(mutex_); if (stopping_) return; tasks_.push_back(std::move(task)); } condition_.notify_one();
}
DirectoryWatcher::~DirectoryWatcher() { stop(); }
void DirectoryWatcher::stop() { SetEvent(stopEvent_); if (worker_.joinable()) worker_.join(); }
void DirectoryWatcher::start(const fs::path& directory, std::function<void()> callback) {
    stop(); ResetEvent(stopEvent_); running_ = true;
    worker_ = std::thread([this, directory, callback = std::move(callback)] {
        ScopeExit finished{[this] { running_ = false; }};
        Handle file(CreateFileW(directory.c_str(), FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, nullptr));
        if (!file.valid()) { callback(); return; }
        Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        alignas(DWORD) unsigned char buffer[8192]{};
        for (;;) {
            OVERLAPPED operation{}; operation.hEvent = event; ResetEvent(event);
            if (!ReadDirectoryChangesW(file, buffer, sizeof(buffer), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_ATTRIBUTES, nullptr, &operation, nullptr)) { callback(); break; }
            HANDLE events[]{stopEvent_, event}; DWORD waited = WaitForMultipleObjects(2, events, FALSE, INFINITE);
            if (waited != WAIT_OBJECT_0 + 1) { CancelIoEx(file, &operation); WaitForSingleObject(event, INFINITE); break; }
            DWORD bytes{};
            if (!GetOverlappedResult(file, &operation, &bytes, FALSE)) { callback(); break; }
            bool relevant = bytes == 0;
            for (DWORD offset = 0; bytes && offset < bytes;) {
                auto* change = reinterpret_cast<FILE_NOTIFY_INFORMATION*>(buffer + offset);
                if (_wcsicmp(std::wstring(change->FileName, change->FileNameLength / sizeof(wchar_t)).c_str(), L"bookmarks.json") == 0) relevant = true;
                if (!change->NextEntryOffset) break;
                offset += change->NextEntryOffset;
            }
            if (relevant) callback();
        }
    });
}
}
