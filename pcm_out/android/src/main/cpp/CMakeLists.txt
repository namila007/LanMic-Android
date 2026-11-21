cmake_minimum_required(VERSION 3.22.1)
project(lanmic_audio CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(oboe REQUIRED CONFIG)

add_library(lanmic_audio SHARED jni_bridge.cpp jitter_ring.cpp audio_out.cpp frame_queue.cpp noise_gate.cpp)
target_compile_options(lanmic_audio PRIVATE -Wall)
target_link_libraries(lanmic_audio oboe::oboe log)
