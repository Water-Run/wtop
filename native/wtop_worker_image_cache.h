#ifndef WTOP_WORKER_IMAGE_CACHE_H
#define WTOP_WORKER_IMAGE_CACHE_H

/* Internal controller helpers, included after gpu_job and create_image.
 * Only immutable Linux executables share backing pages. Each controller owns
 * one reference until its child is reaped; no collector or Lua state is shared. */
#ifndef __APPLE__
struct shared_executable {
    int fd;
    unsigned users;
    struct stat identity;
};
static pthread_mutex_t image_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct shared_executable image_cache[2] = {{.fd = -1}, {.fd = -1}};

static int immutable_image(int fd) {
#if defined(F_GET_SEALS) && defined(F_SEAL_WRITE) && defined(F_SEAL_GROW) && defined(F_SEAL_SHRINK) && defined(F_SEAL_SEAL)
    int wanted = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
    int seals = fcntl(fd, F_GET_SEALS);
    return seals >= 0 && (seals & wanted) == wanted;
#else
    (void)fd;
    return 0;
#endif
}

static int cached_identity(const struct shared_executable *entry) {
    struct stat current;
    return entry->fd >= 0 && !fstat(entry->fd, &current)
        && current.st_dev == entry->identity.st_dev
        && current.st_ino == entry->identity.st_ino
        && current.st_size == entry->identity.st_size;
}

static int cached_immutable(const struct shared_executable *entry) {
    return cached_identity(entry) && immutable_image(entry->fd);
}

static int acquire_image(struct gpu_job *job, char image_path[PATH_MAX]) {
    image_path[0] = 0;
    unsigned slot = job->vendor < GPU_VENDOR_COUNT ? 0u : 1u;
    struct shared_executable *entry = &image_cache[slot];
    int saved = errno, duplicate = -1;
    pthread_mutex_lock(&image_mutex);
    if (entry->users && cached_immutable(entry)) {
        duplicate = fcntl(entry->fd, F_DUPFD_CLOEXEC, 10);
        if (duplicate >= 0) { ++entry->users; job->shared_image = 1; }
    }
    pthread_mutex_unlock(&image_mutex);
    if (duplicate >= 0) { errno = saved; return duplicate; }

    /* Construction stays outside the lock. Independent sources do not wait
     * on another controller's executable creation or filesystem fallback. */
    int file = create_image(job->vendor, image_path);
    if (file < 0) return -1;
    if (!immutable_image(file)) return file;
    saved = errno;
    pthread_mutex_lock(&image_mutex);
    if (!entry->users && entry->fd < 0) {
        int holder = fcntl(file, F_DUPFD_CLOEXEC, 10);
        struct stat identity;
        if (holder >= 0) {
            if (!fstat(holder, &identity)) {
                entry->fd = holder; entry->identity = identity;
                entry->users = 1; job->shared_image = 1;
            } else close(holder);
        }
    } else if (entry->users && cached_immutable(entry)) {
        duplicate = fcntl(entry->fd, F_DUPFD_CLOEXEC, 10);
        if (duplicate >= 0) { ++entry->users; job->shared_image = 1; }
    }
    pthread_mutex_unlock(&image_mutex);
    if (duplicate >= 0) { close(file); file = duplicate; }
    errno = saved;
    return file;
}

static void release_image(struct gpu_job *job) {
    if (!job->shared_image) return;
    int saved = errno;
    unsigned slot = job->vendor < GPU_VENDOR_COUNT ? 0u : 1u;
    struct shared_executable *entry = &image_cache[slot];
    pthread_mutex_lock(&image_mutex);
    if (entry->users && --entry->users == 0) {
        if (cached_identity(entry)) close(entry->fd);
        entry->fd = -1;
    }
    pthread_mutex_unlock(&image_mutex);
    job->shared_image = 0;
    errno = saved;
}
#else
static int acquire_image(struct gpu_job *job, char image_path[PATH_MAX]) {
    return create_image(job->vendor, image_path);
}
static void release_image(struct gpu_job *job) { (void)job; }
#endif

#endif
