#include "platform/Images.h"
#include <iostream>
#include <future>

using namespace frog;
int wmain(int argc, wchar_t** argv) {
    try {
        require(argc == 2, "请提供隔离的图标缓存目录。");
        auto directory = fs::absolute(argv[1]); fs::create_directories(directory);
        std::promise<void> finished; std::mutex mutex; Json results = Json::array();
        const std::vector<std::string> urls{"https://github.com", "https://www.microsoft.com"};
        Images images(directory, false, [&](uint64_t, std::string url, std::shared_ptr<Pixels> pixels) {
            std::lock_guard lock(mutex);
            results.push_back({{"url", url}, {"loaded", pixels != nullptr}, {"width", pixels ? pixels->width : 0}, {"height", pixels ? pixels->height : 0}});
            if (results.size() == urls.size()) finished.set_value();
        });
        images.resume(); for (const auto& url : urls) images.request(url, 96, true);
        bool completed = finished.get_future().wait_for(std::chrono::seconds(35)) == std::future_status::ready;
        if (!completed) images.pause();
        std::lock_guard lock(mutex); Json report{{"completed", completed}, {"results", results}};
        atomicWrite(directory / "network-report.json", report.dump(2)); std::cout << report.dump(2) << '\n';
        bool success = completed; for (const auto& result : results) success = success && result.at("loaded").get<bool>();
        return success ? 0 : 1;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
