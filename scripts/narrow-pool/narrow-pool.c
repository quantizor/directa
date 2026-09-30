/*
 * Loaded into the test process by scripts/test-narrow-pool.sh through
 * DYLD_INSERT_LIBRARIES. It does two things.
 *
 * Narrow: Swift's cooperative pool is sized by the kernel at one thread per
 * core for each QoS class. This parks (cores - NARROW_POOL_WIDTH) blocks on
 * the default-QoS cooperative queue for the life of the process, so the test
 * suite gets NARROW_POOL_WIDTH threads there (3 by default, a GitHub macOS
 * runner's size), timers and actor hops included. Work at another QoS still
 * gets that class's full width; Swift Testing and the daemon code run at the
 * default QoS, so that is the class that matters here.
 *
 * Watch: every 100 ms it reads every thread's dispatch queue, run state, and
 * program counter. A cooperative-pool thread (one serving a cooperative
 * root queue, whatever its QoS) that is not one of the parked ones and has
 * stayed in a call that waits for another event (the list is
 * isWaitingForAnEvent: a semaphore, a condition, a child process, a pipe read
 * or poll, a sleep, a Mach message) for NARROW_POOL_BLOCKED_SECONDS (1 by
 * default) is blocking the pool: it prints one "BLOCKED:" line per episode and, when
 * NARROW_POOL_SAMPLE_DIR is set, runs /usr/bin/sample on the process into
 * that directory so the stack names the call. A thread busy on the CPU, or
 * inside a slow kernel call that is itself the work (a sysctl sweep, a file
 * stat), is load, not blocking, and is never reported. Every read of another
 * thread's memory (its dispatch slot, its stack) goes through
 * mach_vm_read_overwrite, because that thread can exit and have its stack
 * unmapped between task_threads listing it and the read.
 *
 * Blind spots: a wait shorter than the threshold is not reported however
 * often it repeats; a thread spinning in user space while waiting, or
 * waiting through a call not on the list (a contended os_unfair_lock),
 * reads as working; a blocked thread of another QoS class is watched but
 * that class was not narrowed.
 *
 * Only the process named NARROW_POOL_PROCESS (default swiftpm-testing-helper)
 * is touched, and DYLD_INSERT_LIBRARIES is removed from its environment so
 * the processes a test spawns run unmodified.
 */
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_PARKED 256
#define MAX_TRACKED 1024

static pthread_mutex_t parkedLock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t parked[MAX_PARKED];
static int parkedCount;

/* One pool thread seen blocked: since when, on which pass it was last seen
   blocked (a gap in passes ends the episode), and whether it was reported. */
typedef struct {
    uint64_t lastPass;
    int reported;
    uint64_t since;
    uint64_t thread;
} Tracked;

static Tracked tracked[MAX_TRACKED];
static int trackedCount;
static dispatch_queue_t cooperativeQueues[6];
static unsigned long blockedEpisodes;
static double worstBlockedSeconds;

static uint64_t nowNanos(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void park(void *context) {
    uint64_t self;
    pthread_threadid_np(NULL, &self);
    pthread_mutex_lock(&parkedLock);
    if (parkedCount < MAX_PARKED) parked[parkedCount++] = self;
    pthread_mutex_unlock(&parkedLock);
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t never = PTHREAD_COND_INITIALIZER;
    pthread_mutex_lock(&mutex);
    for (;;) pthread_cond_wait(&never, &mutex);
}

static int isParked(uint64_t thread) {
    int found = 0;
    pthread_mutex_lock(&parkedLock);
    for (int index = 0; index < parkedCount && !found; index++) found = parked[index] == thread;
    pthread_mutex_unlock(&parkedLock);
    return found;
}

/* Copies memory another thread owns (its stack, its thread-local slots),
   answering 0 rather than faulting when that thread exited and its stack was
   unmapped after task_threads listed it. */
static int readOtherThreadMemory(uintptr_t address, void *out, size_t size) {
    mach_vm_size_t copied = 0;
    return mach_vm_read_overwrite(mach_task_self(), address, size, (mach_vm_address_t)(uintptr_t)out, &copied)
        == KERN_SUCCESS && copied == size;
}

/* The cooperative root queue the thread is running on, or NULL when it is on
   none or on any other queue. The queue pointer is only compared against the
   immortal cooperative root queues, never dereferenced, since any other queue
   the thread names may be released while this reads it. */
static dispatch_queue_t cooperativeQueue(thread_identifier_info_data_t *identity) {
    dispatch_queue_t queue = NULL;
    if (!identity->dispatch_qaddr || !readOtherThreadMemory(identity->dispatch_qaddr, &queue, sizeof queue)) return NULL;
    for (size_t index = 0; index < sizeof cooperativeQueues / sizeof cooperativeQueues[0]; index++) {
        if (queue && queue == cooperativeQueues[index]) return queue;
    }
    return NULL;
}

static int endsWith(const char *text, const char *suffix) {
    size_t length = strlen(text), suffixLength = strlen(suffix);
    return length >= suffixLength && strcmp(text + length - suffixLength, suffix) == 0;
}

/* Whether the thread is parked in a call that waits for another event (a
   semaphore, a condition, a child process, a pipe or socket, a timer, a
   Mach message), read from the symbol at its program counter. A thread in
   any other kernel call (a sysctl sweep, a file stat, a lock briefly
   contended) is doing work, however long the call takes. */
static int isWaitingForAnEvent(const arm_thread_state64_t *state) {
    static const char *const waits[] = {
        "__psynch_cvwait", "__read_nocancel", "__select", "__select_nocancel", "__semwait_signal",
        "__semwait_signal_nocancel", "__sigsuspend", "__wait4", "__wait4_nocancel", "kevent", "kevent_id",
        "kevent_qos", "mach_msg2_trap", "mach_msg_trap", "poll", "read", "semaphore_timedwait_trap",
        "semaphore_wait_trap", "waitid",
    };
    Dl_info info;
    if (!dladdr((const void *)arm_thread_state64_get_pc(*state), &info) || !info.dli_sname) return 0;
    for (size_t index = 0; index < sizeof waits / sizeof waits[0]; index++) {
        if (strcmp(info.dli_sname, waits[index]) == 0) return 1;
    }
    return 0;
}

/* Prints the waiting thread's stack by walking its frame-pointer chain, which
   is stable while the thread sits in the kernel: the report names the call
   at the moment it was caught rather than whatever runs by the time a
   separate sampler attaches. */
static void printStack(const arm_thread_state64_t *state) {
    Dl_info info;
    uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(*state);
    uintptr_t lr = (uintptr_t)arm_thread_state64_get_lr(*state);
    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(*state);
    uintptr_t frames[40] = {pc, lr};
    int count = 2;
    while (fp && (fp & 7) == 0 && count < 40) {
        uintptr_t record[2];
        if (!readOtherThreadMemory(fp, record, sizeof record)) break;
        uintptr_t next = record[0], ret = record[1];
        if (!ret || next <= fp) break;
        frames[count++] = ret;
        fp = next;
    }
    for (int index = 0; index < count; index++) {
        uintptr_t address = frames[index] & 0x0000000FFFFFFFFFULL;
        if (dladdr((const void *)address, &info) && info.dli_sname) {
            fprintf(stderr, "[narrow-pool]     %s + %lu\n", info.dli_sname, (unsigned long)(address - (uintptr_t)info.dli_saddr));
        } else {
            fprintf(stderr, "[narrow-pool]     0x%lx\n", (unsigned long)address);
        }
    }
}

/* The thread's entry, else a new one, reusing a slot whose episode ended
   (not seen blocked on the previous pass) once the table is full. */
static Tracked *track(uint64_t thread, uint64_t pass) {
    Tracked *ended = NULL;
    for (int index = 0; index < trackedCount; index++) {
        if (tracked[index].thread == thread) return &tracked[index];
        if (!ended && tracked[index].lastPass + 1 < pass) ended = &tracked[index];
    }
    Tracked *entry = trackedCount < MAX_TRACKED ? &tracked[trackedCount++] : ended;
    if (entry) *entry = (Tracked){.lastPass = 0, .reported = 0, .since = 0, .thread = thread};
    return entry;
}

static void sampleProcess(const char *directory, unsigned long episode) {
    char command[2048];
    snprintf(command, sizeof command, "/usr/bin/sample %d 1 -file '%s/blocked-%lu.txt' >/dev/null 2>&1 &",
             getpid(), directory, episode);
    system(command);
}

static void *watch(void *context) {
    pthread_setname_np("narrow-pool.watch");
    const char *thresholdText = getenv("NARROW_POOL_BLOCKED_SECONDS");
    double threshold = thresholdText ? atof(thresholdText) : 1.0;
    const char *sampleDirectory = getenv("NARROW_POOL_SAMPLE_DIR");
    for (uint64_t pass = 1;; pass++) {
        usleep(100000);
        uint64_t now = nowNanos();
        thread_act_array_t threads;
        mach_msg_type_number_t count;
        if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) continue;
        for (mach_msg_type_number_t index = 0; index < count; index++) {
            thread_identifier_info_data_t identity;
            thread_basic_info_data_t basic;
            mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
            int known = thread_info(threads[index], THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &size)
                == KERN_SUCCESS;
            size = THREAD_BASIC_INFO_COUNT;
            known = known
                && thread_info(threads[index], THREAD_BASIC_INFO, (thread_info_t)&basic, &size) == KERN_SUCCESS;
            dispatch_queue_t queue = known ? cooperativeQueue(&identity) : NULL;
            arm_thread_state64_t state;
            mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
            int waiting = queue
                && (basic.run_state == TH_STATE_WAITING || basic.run_state == TH_STATE_UNINTERRUPTIBLE)
                && !isParked(identity.thread_id)
                && thread_get_state(threads[index], ARM_THREAD_STATE64, (thread_state_t)&state, &stateCount)
                    == KERN_SUCCESS
                && isWaitingForAnEvent(&state);
            mach_port_deallocate(mach_task_self(), threads[index]);
            if (!waiting) continue;
            Tracked *entry = track(identity.thread_id, pass);
            if (!entry) continue;
            if (entry->since == 0 || entry->lastPass != pass - 1) {
                entry->reported = 0;
                entry->since = now;
            }
            entry->lastPass = pass;
            double seconds = (now - entry->since) / 1e9;
            if (seconds > worstBlockedSeconds) worstBlockedSeconds = seconds;
            if (seconds >= threshold && !entry->reported) {
                entry->reported = 1;
                blockedEpisodes++;
                fprintf(stderr, "[narrow-pool] BLOCKED: cooperative thread %llu has waited %.1fs on %s in:\n",
                        (unsigned long long)identity.thread_id, seconds, dispatch_queue_get_label(queue));
                printStack(&state);
                if (sampleDirectory) sampleProcess(sampleDirectory, blockedEpisodes);
            }
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    }
    return NULL;
}

static void summary(void) {
    fprintf(stderr, "[narrow-pool] %lu blocked episode(s), longest wait on a pool thread %.1fs\n", blockedEpisodes,
            worstBlockedSeconds);
}

__attribute__((constructor)) static void install(void) {
    const char *target = getenv("NARROW_POOL_PROCESS");
    if (strcmp(getprogname(), target ? target : "swiftpm-testing-helper") != 0) return;
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char *widthText = getenv("NARROW_POOL_WIDTH");
    long width = widthText ? strtol(widthText, NULL, 10) : 3;
    long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (width < 1) width = 1;
    /* QOS_CLASS_DEFAULT with the private cooperative flag (0x4): the queue
       Swift's global executor uses for default-priority tasks. */
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0x4);
    if (!queue || !endsWith(dispatch_queue_get_label(queue), ".cooperative")) {
        fprintf(stderr, "[narrow-pool] error: no default-QoS cooperative queue on this system; the pool was not narrowed\n");
        exit(97);
    }
    static const dispatch_qos_class_t classes[] = {
        QOS_CLASS_BACKGROUND, QOS_CLASS_DEFAULT, QOS_CLASS_USER_INITIATED, QOS_CLASS_USER_INTERACTIVE,
        QOS_CLASS_UTILITY, 0x05 /* maintenance, which the public header does not name */,
    };
    for (size_t index = 0; index < sizeof classes / sizeof classes[0]; index++) {
        cooperativeQueues[index] = dispatch_get_global_queue(classes[index], 0x4);
    }
    for (long index = 0; index < cores - width; index++) dispatch_async_f(queue, NULL, park);
    pthread_t thread;
    pthread_create(&thread, NULL, watch, NULL);
    pthread_detach(thread);
    atexit(summary);
    fprintf(stderr, "[narrow-pool] cooperative pool narrowed to %ld of %ld threads\n", width, cores);
}
