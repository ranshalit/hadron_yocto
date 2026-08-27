// pong: attaches to the shared memory ping created, then replies each round.
#include "shm_common.hpp"

#include <cstdio>
#include <cstring>
#include <cerrno>

#include <fcntl.h>
#include <semaphore.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <ctime>

int main() {
    // Wait for ping to create the shm object (retry for a few seconds).
    int fd = -1;
    for (int i = 0; i < 100; ++i) {
        fd = shm_open(SHM_NAME, O_RDWR, 0600);
        if (fd >= 0) break;
        struct timespec ts{0, 50 * 1000 * 1000}; // 50 ms
        nanosleep(&ts, nullptr);
    }
    if (fd < 0) { perror("pong: shm_open (is ping running?)"); return 1; }

    void* addr = mmap(nullptr, sizeof(SharedRegion), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) { perror("pong: mmap"); return 1; }
    auto* shared = static_cast<SharedRegion*>(addr);

    sem_t* sem_ping = sem_open(SEM_PING, O_CREAT, 0600, 0);
    sem_t* sem_pong = sem_open(SEM_PONG, O_CREAT, 0600, 0);
    if (sem_ping == SEM_FAILED || sem_pong == SEM_FAILED) { perror("pong: sem_open"); return 1; }

    printf("[pong] attached to shm=%s\n", SHM_NAME);
    fflush(stdout);

    for (int round = 1; round <= ROUNDS; ++round) {
        sem_wait(sem_ping);   // wait for ping's message

        printf("[pong] <- %s (counter=%u)\n", shared->message, shared->counter.load());
        fflush(stdout);

        std::uint32_t v = shared->counter.fetch_add(1) + 1;
        snprintf(shared->message, MSG_MAX, "pong reply %d (counter=%u)", round, v);
        printf("[pong] -> %s\n", shared->message);
        fflush(stdout);

        sem_post(sem_pong);   // wake ping
    }

    printf("[pong] done after %d rounds, final counter=%u\n", ROUNDS, shared->counter.load());
    fflush(stdout);

    munmap(addr, sizeof(SharedRegion));
    close(fd);
    sem_close(sem_ping);
    sem_close(sem_pong);
    return 0;
}
