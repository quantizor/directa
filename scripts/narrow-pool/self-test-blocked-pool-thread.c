/* Self-test for narrow-pool.c (scripts/test-narrow-pool.sh --self-test): a
   cooperative-pool thread that waits on a semaphore for longer than the
   watcher's threshold, which the watcher must report as a BLOCKED line whose
   stack names the waiting function. */
#include <dispatch/dispatch.h>
#include <unistd.h>

void blockThePool(void *context) {
    volatile long result = dispatch_semaphore_wait(dispatch_semaphore_create(0), dispatch_time(DISPATCH_TIME_NOW, 2500000000LL));
    (void)result;
}

int main(void) {
    dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0x4), NULL, blockThePool);
    sleep(4);
    return 0;
}
