#pragma once
#include <cstddef>
#include <string>

namespace frog::calculator {
inline constexpr size_t maxLength = 256;
// Normalize supported glyphs one UTF-16 unit at a time; preserve unknown input and length.
std::string normalize(const std::string& source);
std::string format(double value);
double evaluate(const std::string& source);
}
