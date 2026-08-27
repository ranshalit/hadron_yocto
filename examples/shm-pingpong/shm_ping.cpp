// ping: creates the shared memory + semaphores, then drives the conversation.
#include "shm_common.hpp"

#include <cstdio>
#include <cstring>
#include <cerrno>

#include <fcntl.h>
#include <semaphore.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main() {
    // Start from a clean slate in case a previous run crashed.
    shm_unlink(SHM_NAME);
    sem_unlink(SEM_PING);
    sem_unlink(SEM_PONG);

    int fd = shm_open(SHM_NAME, O_CREAT | O_RDWR, 0600);
    if (fd < 0) { perror("ping: shm_open"); return 1; }
    if (ftruncate(fd, sizeof(SharedRegion)) != 0) { perror("ping: ftruncate"); return 1; }

    void* addr = mmap(nullptr, sizeof(SharedRegion), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) { perror("ping: mmap"); return 1; }
    auto* shared = new (addr) SharedRegion{};
    shared->counter.store(0);

    // ping starts "empty" so pong blocks until we post; pong starts "empty" too.
    sem_t* sem_ping = sem_open(SEM_PING, O_CREAT, 0600, 0);
    sem_t* sem_pong = sem_open(SEM_PONG, O_CREAT, 0600, 0);
    if (sem_ping == SEM_FAILED || sem_pong == SEM_FAILED) { perror("ping: sem_open"); return 1; }

    printf("[ping] ready, shm=%s. Waiting for pong to join...\n", SHM_NAME);
    fflush(stdout);

    for (int round = 1; round <= ROUNDS; ++round) {
        std::uint32_t v = shared->counter.fetch_add(1) + 1;
        snprintf(shared->message, MSG_MAX, "ping round %d (counter=%u)", round, v);
        printf("[ping] -> %s\n", shared->message);
        fflush(stdout);

        sem_post(sem_ping);   // wake pong
        sem_wait(sem_pong);   // wait for pong's reply

        printf("[ping] <- %s (counter=%u)\n", shared->message, shared->counter.load());
        fflush(stdout);
    }

    printf("[ping] done after %d rounds, final counter=%u\n", ROUNDS, shared->counter.load());
    fflush(stdout);

    munmap(addr, sizeof(SharedRegion));
    close(fd);
    sem_close(sem_ping);
    sem_close(sem_pong);
    // ping owns the objects, so it cleans them up.
    shm_unlink(SHM_NAME);
    sem_unlink(SEM_PING);
    sem_unlink(SEM_PONG);
    return 0;
}
