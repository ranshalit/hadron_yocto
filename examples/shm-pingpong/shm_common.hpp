#pragma once
//
// Shared definitions for the shm-pingpong demo.
//
// Two processes (ping + pong) talk through one POSIX shared-memory region and
// two POSIX named semaphores. This works under qemu-aarch64-static because each
// qemu-user process is a normal *host* process: shm_open()/sem_open() are
// translated to real host syscalls, so both emulated ARM processes share the
// same /dev/shm objects on the host kernel.
//
#include <atomic>
#include <cstdint>

// Names of the kernel objects (live under /dev/shm on the host).
constexpr const char* SHM_NAME   = "/hadron_pingpong_shm";
constexpr const char* SEM_PING   = "/hadron_pingpong_ping"; // posted by ping, waited by pong
constexpr const char* SEM_PONG   = "/hadron_pingpong_pong"; // posted by pong, waited by ping

constexpr int   MSG_MAX   = 256;
constexpr int   ROUNDS    = 5;   // how many ping<->pong exchanges

// The object living in shared memory. std::atomic gives us a well-defined
// cross-process memory model for the counter without extra locking.
struct SharedRegion {
    std::atomic<std::uint32_t> counter;   // incremented by each side in turn
    char                       message[MSG_MAX];
};
