cmake_minimum_required(VERSION 3.10)
project(shm-pingpong CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(shm_ping shm_ping.cpp)
add_executable(shm_pong shm_pong.cpp)

# shm_open()/sem_open() live in librt/libpthread on this toolchain.
find_library(RT_LIB rt)
if(RT_LIB)
    target_link_libraries(shm_ping ${RT_LIB})
    target_link_libraries(shm_pong ${RT_LIB})
endif()
find_package(Threads REQUIRED)
target_link_libraries(shm_ping Threads::Threads)
target_link_libraries(shm_pong Threads::Threads)
