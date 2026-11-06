#include "core/Storage.h"
#include "platform/Integration.h"
#include <iostream>
#include <future>

using namespace frog;
namespace {
int passed = 0, failed = 0;
void test(const char* name, const std::function<void()>& run) {
    try { run(); ++passed; std::cout << "PASS " << name << '\n'; }
    catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << name << ": " << error.what() << '\n'; }
}
void expect(bool condition) { require(condition, "断言失败"); }
void rejects(const std::function<void()>& run) { bool thrown = false; try { run(); } catch (const std::exception&) { thrown = true; } expect(thrown); }
struct Temporary {
    fs::path path = fs::temp_directory_path() / wide("Frog-test-" + uuid());
    Temporary() { fs::create_directories(path); }
    ~Temporary() { std::error_code ec; fs::remove_all(path, ec); }
};
Document sample() { Document data; data.upsert("", "第一条中文", "example.com", {}); auto group = data.addGroup("开发工具"); data.upsert("", "文档", "example.org/docs", group); return data; }
}
int wmain(int argc, wchar_t** argv) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED); ScopeExit cleanup{[] { CoUninitialize(); }};
    test("macos-v1-roundtrip", [&] { expect(argc == 2); auto bytes = readFile(argv[1]); auto data = Document::decode(bytes); expect(data == Document::decode(data.encode())); expect(data.groups[1].name == "空文件夹"); expect(!data.bookmarks[0].groupId); expect(data.bookmarks[0].createdAt == 1756000000000.125); });
    test("required-fields", [] { auto json = Json::parse(sample().encode()); json["bookmarks"][0].erase("groupId"); rejects([&] { Document::decode(json.dump()); }); });
    test("strict-numeric-schema", [] { auto json = Json::parse(sample().encode()); json["schemaVersion"] = 1.0; rejects([&] { Document::decode(json.dump()); }); json["schemaVersion"] = 1; json["groups"][0]["order"] = 0.5; rejects([&] { Document::decode(json.dump()); }); });
    test("future-version", [] { auto json = Json::parse(sample().encode()); json["schemaVersion"] = 2; rejects([&] { Document::decode(json.dump()); }); });
    test("duplicate-id-case-insensitive", [] { auto data = sample(); auto b = data.bookmarks[0]; b.id = lower(b.id); data.bookmarks.push_back(b); rejects([&] { data.validate(); }); });
    test("uuid-required", [] { auto data = sample(); data.bookmarks[0].id = "b-demo"; rejects([&] { data.validate(); }); });
    test("group-reference-required", [] { auto data = sample(); data.bookmarks[0].groupId = uuid(); rejects([&] { data.validate(); }); });
    test("unicode-graphemes", [] { expect(characters("👨‍👩‍👧") == 1); expect(characters("é") == 1); std::string title; for (int i = 0; i < 120; ++i) title += "中文"; auto data = sample(); rejects([&] { data.upsert("", title, "example.com", {}); }); });
    test("utf8-errors", [] { rejects([] { wide(std::string("\xff")); }); });
    test("url-ports-ipv6", [] { expect(normalizeUrl(" example.com:8080/path ") == "https://example.com:8080/path"); expect(normalizeUrl("[::1]:8080") == "https://[::1]:8080"); expect(normalizeUrl("localhost:9000") == "https://localhost:9000"); });
    test("url-rejects-unsafe-input", [] { for (const auto* value : {"javascript:alert(1)", "file:///C:/test", "mailto:a@b.com", "ftp://example.com", "not a domain", "https://", "https://example.com/a b"}) rejects([&] { normalizeUrl(value); }); });
    test("search-url-encoding", [] { expect(searchUrl("中文 & a").find("%26") != std::string::npos); expect(searchUrl("example.com") == "https://example.com"); });
    test("root-mixed-order", [] { auto data = sample(); auto first = data.bookmarks[0].id, group = data.groups[0].id; data.move(group, {}, first); expect(data.items()[0].id == group); data.move(first, group); expect(data.items().size() == 1); data.move(first, {}, group); expect(data.items()[0].id == first); });
    test("nonempty-folder-protected", [] { auto data = sample(); rejects([&] { data.remove(data.groups[0].id); }); });
    test("empty-folder-delete", [] { auto data = sample(); auto group = data.addGroup("空"); data.remove(group); expect(!data.group(group)); });
    test("invalid-edit-new-folder-rollback", [] { auto data = sample(), before = data; rejects([&] { data.upsert(uuid(), "标题", "example.com", {}, "新文件夹"); }); expect(data == before); });
    test("merge-keeps-target-and-empty-source-folder", [] { auto data = sample(); auto target = data.bookmarks[0].id, source = data.bookmarks[1].id, old = data.groups[0].id; auto merged = data.merge(source, target); expect(data.items(merged)[0].id == target); expect(data.items(merged)[1].id == source); expect(data.items(old).empty()); expect(data.items()[0].id == merged); data.validate(); });
    test("folder-cannot-nest", [] { auto data = sample(); auto another = data.addGroup("另一个"); auto before = data; rejects([&] { data.move(data.groups[0].id, another); }); expect(data == before); });
    test("invalid-reorder-rollback", [] { auto data = sample(), before = data; rejects([&] { data.reorder({}, {data.bookmarks[0].id, data.bookmarks[0].id}); }); expect(data == before); });
    test("extreme-order-normalized-on-edit", [] { auto data = sample(); data.bookmarks[0].order = INT64_MAX; auto json = data.encode(); expect(Document::decode(json).bookmarks[0].order == INT64_MAX); data.upsert("", "新", "example.com", {}); for (const auto& item : data.items()) expect(item.order < 4); });
    test("search-logical-order", [] { auto data = sample(); expect(data.search("EXAMPLE").size() == 2); expect(data.search("文档").front().id == data.bookmarks[1].id); expect(data.search("  ").size() == 2); });
    test("storage-atomic-save", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto data = sample(); auto next = store.save(data, state.bytes); expect(next.document == Document::decode(readFile(temp.path / "bookmarks.json"))); expect(std::distance(fs::directory_iterator(temp.path), fs::directory_iterator()) == 1); });
    test("conflict-preserves-external", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto external = sample(); atomicWrite(temp.path / "bookmarks.json", external.encode()); rejects([&] { store.save({}, state.bytes); }); expect(store.reload().document == external); });
    test("corrupt-file-preserved", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); atomicWrite(temp.path / "bookmarks.json", "{broken"); rejects([&] { store.reload(); }); rejects([&] { store.save(sample(), state.bytes); }); expect(readFile(temp.path / "bookmarks.json") == "{broken"); });
    test("missing-file-not-recreated-on-save", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); fs::remove(temp.path / "bookmarks.json"); rejects([&] { store.save(sample(), state.bytes); }); expect(!fs::exists(temp.path / "bookmarks.json")); });
    test("configured-file-missing-at-startup", [] { Temporary temp; Storage store; rejects([&] { store.open(temp.path, false, {}, false); }); expect(!fs::exists(temp.path / "bookmarks.json")); });
    test("read-only-target-rollback", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto path = temp.path / "bookmarks.json"; SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_READONLY); ScopeExit restore{[&] { SetFileAttributesW(path.c_str(), FILE_ATTRIBUTE_NORMAL); }}; rejects([&] { store.save(sample(), state.bytes); }); expect(readFile(path) == state.bytes); });
    test("directory-unavailable", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); fs::remove(temp.path / "bookmarks.json"); fs::remove(temp.path); rejects([&] { store.save(sample(), state.bytes); }); });
    test("switch-seeds-empty-and-loads-existing", [] { Temporary a, b, c; Storage store; auto state = store.open(a.path, false, sample()); auto copied = store.open(b.path, false, state.document); expect(copied.document == state.document); auto existing = Document{}; atomicWrite(c.path / "bookmarks.json", existing.encode()); expect(store.open(c.path, false, state.document).document == existing); });
    test("invalid-switch-keeps-current-directory", [] { Temporary a, b; Storage store; auto state = store.open(a.path, false, sample()); atomicWrite(b.path / "bookmarks.json", "bad"); rejects([&] { store.open(b.path, false); }); expect(store.reload().directory == fs::weakly_canonical(a.path)); });
    test("backup-and-restore-replace-all", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false, sample()); auto backup = temp.path / "backup.json"; store.backup(backup, state.document); auto empty = store.save({}, state.bytes); expect(store.restore(backup, empty.bytes).document == state.document); rejects([&] { store.backup(temp.path / "bookmarks.json", state.document); }); });
    test("backup-hardlink-protected", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false); auto alias = temp.path / "alias.json"; fs::create_hard_link(temp.path / "bookmarks.json", alias); rejects([&] { store.backup(alias, sample()); }); });
    test("invalid-restore-preserves-current", [] { Temporary temp; Storage store; auto state = store.open(temp.path, false, sample()); atomicWrite(temp.path / "bad.json", "[]"); rejects([&] { store.restore(temp.path / "bad.json", state.bytes); }); expect(store.reload().document == state.document); });
    test("directory-watcher-atomic-replacement", [] { Temporary temp; Storage store; store.open(temp.path, false); std::atomic<int> changes{0}; DirectoryWatcher watcher; watcher.start(temp.path, [&] { ++changes; }); Sleep(80); atomicWrite(temp.path / "bookmarks.json", sample().encode()); for (int i = 0; i < 100 && changes == 0; ++i) Sleep(10); watcher.stop(); expect(changes > 0); });
    test("serial-queue-order", [] { std::vector<int> results; std::promise<void> done; { SerialQueue queue; for (int i = 0; i < 50; ++i) queue.post([&, i] { results.push_back(i); }); queue.post([&] { done.set_value(); }); expect(done.get_future().wait_for(std::chrono::seconds(3)) == std::future_status::ready); } for (int i = 0; i < 50; ++i) expect(results[i] == i); });
    test("global-hotkey-conflict-keeps-old", [] { auto a = CreateWindowExW(0, L"STATIC", L"FrogTestA", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr); auto b = CreateWindowExW(0, L"STATIC", L"FrogTestB", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr); ScopeExit close{[&] { DestroyWindow(a); DestroyWindow(b); }}; GlobalHotKey first, second; HotKey key{true, MOD_CONTROL | MOD_ALT | MOD_SHIFT, VK_F23}; first.set(a, key); rejects([&] { second.set(b, key); }); first.set(a, {false}); second.set(b, key); });
    std::cout << passed << " passed, " << failed << " failed\n"; return failed ? 1 : 0;
}
