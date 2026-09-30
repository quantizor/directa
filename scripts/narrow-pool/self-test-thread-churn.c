/* Self-test for narrow-pool.c (scripts/test-narrow-pool.sh --self-test): a
   process that starts and ends short-lived detached threads for a while, so
   the watcher's read of another thread's memory meets a thread that already
   exited and had its stack unmapped. A watcher that faults on that read
   kills this process (exit 139); a correct one lets it print "survived" and
   exit 0. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static atomic_int live;

static void *brief(void *context) {
    usleep(50);
    atomic_fetch_sub(&live, 1);
    return NULL;
}

int main(int argc, char **argv) {
    int seconds = argc > 1 ? atoi(argv[1]) : 30;
    time_t end = time(NULL) + seconds;
    unsigned long made = 0;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    while (time(NULL) < end) {
        while (atomic_load(&live) >= 64) usleep(10);
        pthread_t thread;
        atomic_fetch_add(&live, 1);
        if (pthread_create(&thread, &attr, brief, NULL) != 0) atomic_fetch_sub(&live, 1); else made++;
    }
    printf("survived, %lu threads\n", made);
    return 0;
}
