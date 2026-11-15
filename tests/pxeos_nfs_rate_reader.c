/* Read-only NFSv4.2 throughput fixture, compiled into the isolated guest. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/magic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <time.h>
#include <unistd.h>

#define SECOND_NS UINT64_C(1000000000)
#define BLOCK_SIZE (1024U * 1024U)
#define PAYLOAD_SIZE (16U * BLOCK_SIZE)
#define SAMPLE_SIZE 4096U

static uint64_t now_ns(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(1);
    }
    return (uint64_t)now.tv_sec * SECOND_NS + (uint64_t)now.tv_nsec;
}

static uint64_t parse_ns(const char *text)
{
    char *end;
    unsigned long long value;

    if (text[0] < '0' || text[0] > '9')
        return 0;
    errno = 0;
    value = strtoull(text, &end, 10);
    return errno || *end || value > INT64_MAX ? 0 : (uint64_t)value;
}

static int wait_until(uint64_t ns)
{
    const struct timespec target = {ns / SECOND_NS, ns % SECOND_NS};
    int result;

    do {
        result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &target, NULL);
    } while (result == EINTR);
    if (result) {
        fprintf(stderr, "clock_nanosleep: %s\n", strerror(result));
        return 1;
    }
    return 0;
}

static bool check_sample(const unsigned char *buffer, size_t size)
{
    if (size > SAMPLE_SIZE)
        size = SAMPLE_SIZE;
    for (size_t index = 0; index < size; index++) {
        if (buffer[index] != (unsigned char)index)
            return false;
    }
    return true;
}

static int measure(uint64_t start, uint64_t deadline)
{
    struct stat metadata;
    struct statfs filesystem;
    unsigned char *buffer;
    uint64_t first = 0, bytes = 0, operations = 0;
    off_t offset = 0;
    int result = 0;
    ssize_t last_size = 0;
    int file;

    if (wait_until(start))
        return 1;
    if (now_ns() >= deadline) {
        puts("RATE_MISSED_WINDOW");
        return 0;
    }

    file = open("/mnt/payload", O_RDONLY | O_DIRECT | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) {
        perror("open NFS payload");
        return 1;
    }
    if (fstat(file, &metadata) || fstatfs(file, &filesystem)
            || !S_ISREG(metadata.st_mode) || metadata.st_size != PAYLOAD_SIZE
            || filesystem.f_type != NFS_SUPER_MAGIC) {
        fputs("Unexpected NFS payload type, size or filesystem\n", stderr);
        close(file);
        return 1;
    }
    buffer = aligned_alloc(SAMPLE_SIZE, BLOCK_SIZE);
    if (!buffer) {
        perror("aligned_alloc");
        close(file);
        return 1;
    }

    while (now_ns() < deadline) {
        ssize_t size = pread(file, buffer, BLOCK_SIZE, offset);
        int read_error = errno;
        uint64_t completed = now_ns();

        if (size > 0)
            last_size = size;
        if (completed > deadline)
            break;
        if (size < 0 && read_error == EINTR)
            continue;
        if (size <= 0) {
            fprintf(stderr, "NFS pread: %s\n", size < 0 ? strerror(read_error) : "unexpected EOF");
            result = 1;
            break;
        }
        if (!first) {
            if (!check_sample(buffer, (size_t)size)) {
                puts("RATE_SAMPLE_ERROR first");
                result = 1;
                break;
            }
            first = completed;
            puts("RATE_SAMPLE_OK first");
        }
        bytes += (uint64_t)size;
        operations++;
        /* Each whole line is available to the controller even if a later read hangs. */
        printf("RATE_PROGRESS %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 "\n",
                first, completed, bytes, operations);
        if (size != BLOCK_SIZE) {
            fputs("NFS pread: unexpected short read\n", stderr);
            result = 1;
            break;
        }
        offset += size;
        if (offset == PAYLOAD_SIZE)
            offset = 0;
    }
    if (last_size > 0) {
        if (!check_sample(buffer, (size_t)last_size)) {
            puts("RATE_SAMPLE_ERROR last");
            result = 1;
        } else {
            puts("RATE_SAMPLE_OK last");
        }
    }
    free(buffer);
    close(file);
    return result;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 2 && strcmp(argv[1], "--clock") == 0) {
        printf("%" PRIu64 "\n", now_ns());
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--wait") == 0) {
        uint64_t target = parse_ns(argv[2]);

        if (target)
            return wait_until(target);
    }
    if (argc == 4 && strcmp(argv[1], "--read") == 0) {
        uint64_t start = parse_ns(argv[2]);
        uint64_t deadline = parse_ns(argv[3]);

        if (start && deadline > start && deadline - start == 60 * SECOND_NS)
            return measure(start, deadline);
    }
    fputs("Expected --clock, --wait target, or --read with a 60-second window\n", stderr);
    return 2;
}

