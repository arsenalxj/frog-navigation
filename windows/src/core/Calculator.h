#pragma once
#include <cstddef>
#include <string>

namespace frog::calculator {
inline constexpr size_t maxLength = 256;
std::string normalize(const std::string& source);
std::string filtered(const std::string& source);
std::string format(double value);
double evaluate(const std::string& source);
}
