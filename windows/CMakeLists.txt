cmake_minimum_required(VERSION 3.20)
project(ghostty-windows CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Path to the libghostty build output, containing include/ and lib/. Build
# libghostty first from the repository root, e.g.:
#
#   zig build -Dapp-runtime=none
#
# then point CMake at the result with -DGHOSTTY_DIR=<path-to>/zig-out.
set(GHOSTTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../zig-out" CACHE PATH
    "Path to the libghostty install prefix (with include/ and lib/).")

find_library(GHOSTTY_LIBRARY
    NAMES ghostty ghostty-internal
    PATHS "${GHOSTTY_DIR}/lib"
    REQUIRED)

# WIN32 selects the GUI subsystem so our entry point is wWinMain.
add_executable(ghostty WIN32 main.cpp)
target_include_directories(ghostty PRIVATE "${GHOSTTY_DIR}/include")
target_link_libraries(ghostty PRIVATE "${GHOSTTY_LIBRARY}")

# Build for Unicode and target Windows 10 (for the per-monitor DPI APIs).
target_compile_definitions(ghostty PRIVATE UNICODE _UNICODE WINVER=0x0A00 _WIN32_WINNT=0x0A00)

# MSVC defaults the GUI entry point to WinMain; point it at the wide entry.
if(MSVC)
    target_link_options(ghostty PRIVATE /ENTRY:wWinMainCRTStartup)
endif()
