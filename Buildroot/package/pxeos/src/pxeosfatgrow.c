/*
 * Grow a FAT16/FAT32 file system to the length already exposed by a Linux
 * partition device.  This program deliberately does not create, edit, or
 * commit a partition table: the only libparted mutator it calls is the FAT
 * file-system resize API.
 */

#include <parted/parted.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#define FAT_BOOT_SECTOR_SIZE 512
#define FAT_BPB_BYTES_PER_SECTOR 11
#define FAT_BPB_HIDDEN_SECTORS 28
#define FAT_BPB_TOTAL_SECTORS_32 32
#define FAT32_BPB_FAT_SIZE 36
#define FAT32_BPB_BACKUP_BOOT 50

static int exception_seen;
static int allow_same_type_choice;
static PedExceptionOption same_type_choice;

static PedExceptionOption
cancel_exception(PedException *exception)
{
    if (allow_same_type_choice
        && exception->type == PED_EXCEPTION_INFORMATION
        && exception->options == PED_EXCEPTION_YES_NO_CANCEL)
        return same_type_choice;
    (void) exception;
    exception_seen = 1;
    return PED_EXCEPTION_CANCEL;
}

static uint16_t
get_le16(const unsigned char *p)
{
    return (uint16_t) p[0] | ((uint16_t) p[1] << 8);
}

static uint32_t
get_le32(const unsigned char *p)
{
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8)
        | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static void
put_le32(unsigned char *p, uint32_t value)
{
    p[0] = (unsigned char) value;
    p[1] = (unsigned char) (value >> 8);
    p[2] = (unsigned char) (value >> 16);
    p[3] = (unsigned char) (value >> 24);
}

static int
read_partition_start(const struct stat *st, uint32_t *start)
{
    char path[96];
    FILE *file;
    unsigned long long value;

    if (snprintf(path, sizeof(path), "/sys/dev/block/%u:%u/start",
                 major(st->st_rdev), minor(st->st_rdev)) >= (int) sizeof(path))
        return 0;
    file = fopen(path, "r");
    if (!file)
        return 0;
    if (fscanf(file, "%llu", &value) != 1 || value > UINT32_MAX) {
        fclose(file);
        return 0;
    }
    fclose(file);
    *start = (uint32_t) value;
    return 1;
}

static int
is_mounted(const struct stat *st)
{
    FILE *file;
    char line[4096];
    unsigned int mounted_major;
    unsigned int mounted_minor;

    file = fopen("/proc/self/mountinfo", "r");
    if (!file)
        return 1;
    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "%*u %*u %u:%u", &mounted_major,
                   &mounted_minor) == 2
            && mounted_major == major(st->st_rdev)
            && mounted_minor == minor(st->st_rdev)) {
            fclose(file);
            return 1;
        }
    }
    fclose(file);
    return 0;
}

static int
is_linux_partition(const struct stat *st)
{
    char path[96];

    if (snprintf(path, sizeof(path), "/sys/dev/block/%u:%u/partition",
                 major(st->st_rdev), minor(st->st_rdev)) >= (int) sizeof(path))
        return 0;
    return access(path, R_OK) == 0;
}

/*
 * Keep all bytes from the old boot sector, then copy only the fields whose
 * values describe the newly-sized FAT geometry.  Parted 3.6 otherwise writes
 * a generic OEM string, volume label, boot code, and hidden-sector value.
 */
static void
merge_boot_sector(unsigned char *merged, const unsigned char *original,
                  const unsigned char *resized, int is_fat32,
                  uint32_t hidden_sectors)
{
    memcpy(merged, original, FAT_BOOT_SECTOR_SIZE);

    /* BPB: bytes/sector through FAT16 FAT size. */
    memcpy(merged + FAT_BPB_BYTES_PER_SECTOR,
           resized + FAT_BPB_BYTES_PER_SECTOR, 13);
    put_le32(merged + FAT_BPB_HIDDEN_SECTORS, hidden_sectors);
    memcpy(merged + FAT_BPB_TOTAL_SECTORS_32,
           resized + FAT_BPB_TOTAL_SECTORS_32, 4);
    if (is_fat32) {
        /* FAT32 size, flags, version, root cluster, FSInfo, backup boot. */
        memcpy(merged + FAT32_BPB_FAT_SIZE,
               resized + FAT32_BPB_FAT_SIZE, 16);
    }
}

static int
boot_identity_matches(const unsigned char *before, const unsigned char *after,
                      int is_fat32, uint32_t hidden_sectors)
{
    unsigned char expected[FAT_BOOT_SECTOR_SIZE];

    memcpy(expected, before, sizeof(expected));
    put_le32(expected + FAT_BPB_HIDDEN_SECTORS, hidden_sectors);
    if (memcmp(expected, after, FAT_BPB_BYTES_PER_SECTOR) != 0)
        return 0;
    if (memcmp(expected + 24, after + 24, 4) != 0
        || memcmp(expected + FAT_BPB_HIDDEN_SECTORS,
                  after + FAT_BPB_HIDDEN_SECTORS, 4) != 0)
        return 0;
    if (is_fat32)
        return memcmp(expected + 52, after + 52,
                      FAT_BOOT_SECTOR_SIZE - 52) == 0;
    return memcmp(expected + 36, after + 36,
                  FAT_BOOT_SECTOR_SIZE - 36) == 0;
}

static int
boot_geometry_matches(const unsigned char *main_boot,
                      const unsigned char *backup_boot)
{
    return memcmp(main_boot + FAT_BPB_BYTES_PER_SECTOR,
                  backup_boot + FAT_BPB_BYTES_PER_SECTOR, 13) == 0
        && memcmp(main_boot + FAT_BPB_HIDDEN_SECTORS,
                  backup_boot + FAT_BPB_HIDDEN_SECTORS, 8) == 0
        && memcmp(main_boot + FAT32_BPB_FAT_SIZE,
                  backup_boot + FAT32_BPB_FAT_SIZE, 16) == 0;
}

static int
validate_boot_sector(const unsigned char *boot)
{
    if (get_le16(boot + FAT_BPB_BYTES_PER_SECTOR) != FAT_BOOT_SECTOR_SIZE) {
        fprintf(stderr, "pxeosfatgrow: only 512-byte FAT logical sectors are supported\n");
        return 0;
    }
    if (get_le16(boot + 510) != 0xaa55) {
        fprintf(stderr, "pxeosfatgrow: invalid FAT boot sector signature\n");
        return 0;
    }
    return 1;
}

static int
run(const char *path)
{
    struct stat st;
    PedDevice *device = NULL;
    PedDisk *disk = NULL;
    PedGeometry *target = NULL;
    PedFileSystem *fs = NULL;
    PedFileSystem *verified = NULL;
    unsigned char before[FAT_BOOT_SECTOR_SIZE];
    unsigned char resized[FAT_BOOT_SECTOR_SIZE];
    unsigned char merged[FAT_BOOT_SECTOR_SIZE];
    unsigned char backup_before[FAT_BOOT_SECTOR_SIZE];
    unsigned char backup_merged[FAT_BOOT_SECTOR_SIZE];
    unsigned char backup_after[FAT_BOOT_SECTOR_SIZE];
    char fs_name[8];
    int is_fat32;
    int is_block;
    uint32_t hidden_sectors;
    uint16_t old_backup_sector = 0;
    uint16_t new_backup_sector = 0;
    int result = 1;

    if (stat(path, &st) != 0) {
        fprintf(stderr, "pxeosfatgrow: cannot stat %s: %s\n", path, strerror(errno));
        return 1;
    }
    is_block = S_ISBLK(st.st_mode);
    if (!is_block && !S_ISREG(st.st_mode)) {
        fprintf(stderr, "pxeosfatgrow: input must be a block partition or regular FAT image\n");
        return 1;
    }
    if (is_block) {
        if (!is_linux_partition(&st)) {
            fprintf(stderr, "pxeosfatgrow: refusing a whole-disk block device\n");
            return 1;
        }
        if (is_mounted(&st)) {
            fprintf(stderr, "pxeosfatgrow: refusing a mounted partition\n");
            return 1;
        }
        if (!read_partition_start(&st, &hidden_sectors)) {
            fprintf(stderr, "pxeosfatgrow: cannot read the partition start sector\n");
            return 1;
        }
    }

    ped_exception_set_handler(cancel_exception);
    device = ped_device_get(path);
    if (!device || !ped_device_open(device)) {
        fprintf(stderr, "pxeosfatgrow: cannot open input device\n");
        goto out;
    }
    if (device->sector_size != FAT_BOOT_SECTOR_SIZE) {
        fprintf(stderr, "pxeosfatgrow: only 512-byte device sectors are supported\n");
        goto out;
    }
    if (!is_block) {
        /* A regular-file input is safe only as an unpartitioned FAT image. */
        exception_seen = 0;
        disk = ped_disk_new(device);
        if (disk && (!disk->type || !disk->type->name
                     || strcmp(disk->type->name, "loop") != 0)) {
            ped_disk_destroy(disk);
            disk = NULL;
            fprintf(stderr, "pxeosfatgrow: refusing a disk image with a partition table\n");
            goto out;
        }
        if (disk) {
            ped_disk_destroy(disk);
            disk = NULL;
        }
        exception_seen = 0;
    }
    target = ped_geometry_new(device, 0, device->length);
    if (!target || !ped_geometry_read(target, before, 0, 1)
        || !validate_boot_sector(before))
        goto out;
    if (!is_block)
        hidden_sectors = get_le32(before + FAT_BPB_HIDDEN_SECTORS);

    exception_seen = 0;
    fs = ped_file_system_open(target);
    if (!fs || exception_seen || !fs->type || !fs->type->name) {
        fprintf(stderr, "pxeosfatgrow: unsupported or invalid file system\n");
        goto out;
    }
    if (snprintf(fs_name, sizeof(fs_name), "%s", fs->type->name)
        >= (int) sizeof(fs_name)) {
        fprintf(stderr, "pxeosfatgrow: unsupported file system name\n");
        goto out;
    }
    is_fat32 = strcmp(fs_name, "fat32") == 0;
    if (!is_fat32 && strcmp(fs_name, "fat16") != 0) {
        fprintf(stderr, "pxeosfatgrow: only FAT16 and FAT32 are supported\n");
        goto out;
    }
    if (fs->geom->length > target->length) {
        fprintf(stderr, "pxeosfatgrow: refusing to shrink a file system\n");
        goto out;
    }
    if (fs->geom->length == target->length) {
        result = 0;
        goto out;
    }
    if (is_fat32) {
        old_backup_sector = get_le16(before + FAT32_BPB_BACKUP_BOOT);
        if (old_backup_sector == 0
            || old_backup_sector >= get_le16(before + 14)
            || old_backup_sector >= device->length
            || !ped_geometry_read(target, backup_before, old_backup_sector, 1)
            || !validate_boot_sector(backup_before)
            || memcmp(before, backup_before, sizeof(before)) != 0) {
            fprintf(stderr, "pxeosfatgrow: invalid FAT32 backup boot sector\n");
            goto out;
        }
    }

    /*
     * The only allowed choice is to retain the existing FAT type when both
     * FAT16 and FAT32 fit.  Every warning, ignore choice, and conversion is
     * cancelled by the exception handler before resize.c starts writing.
     */
    exception_seen = 0;
    allow_same_type_choice = 1;
    same_type_choice = is_fat32 ? PED_EXCEPTION_YES : PED_EXCEPTION_NO;
    if (!ped_file_system_resize(fs, target, NULL) || exception_seen) {
        allow_same_type_choice = 0;
        fprintf(stderr, "pxeosfatgrow: FAT grow was rejected or failed\n");
        goto out;
    }
    allow_same_type_choice = 0;
    if (!ped_geometry_read(target, resized, 0, 1)) {
        fprintf(stderr, "pxeosfatgrow: cannot read resized boot sector\n");
        goto out;
    }
    if (is_fat32) {
        new_backup_sector = get_le16(resized + FAT32_BPB_BACKUP_BOOT);
        if (new_backup_sector == 0
            || new_backup_sector >= get_le16(resized + 14)
            || new_backup_sector >= device->length) {
            fprintf(stderr, "pxeosfatgrow: resized FAT32 backup boot sector is invalid\n");
            goto out;
        }
    }
    merge_boot_sector(merged, before, resized, is_fat32, hidden_sectors);
    if (is_fat32)
        merge_boot_sector(backup_merged, backup_before, resized, 1,
                          hidden_sectors);
    if (!ped_geometry_write(target, merged, 0, 1)
        || (is_fat32 && !ped_geometry_write(target, backup_merged,
                                             new_backup_sector, 1))
        || !ped_geometry_sync(target)) {
        fprintf(stderr, "pxeosfatgrow: cannot restore FAT boot identity\n");
        goto out;
    }
    if (!ped_geometry_read(target, resized, 0, 1)
        || !boot_identity_matches(before, resized, is_fat32, hidden_sectors)) {
        fprintf(stderr, "pxeosfatgrow: FAT boot identity verification failed\n");
        goto out;
    }
    if (is_fat32 && (!ped_geometry_read(target, backup_after, new_backup_sector, 1)
        || memcmp(backup_merged, backup_after, sizeof(backup_merged)) != 0
        || !boot_identity_matches(backup_before, backup_after, 1, hidden_sectors)
        || !boot_geometry_matches(merged, backup_after))) {
        fprintf(stderr, "pxeosfatgrow: FAT32 backup boot verification failed\n");
        goto out;
    }

    ped_file_system_close(fs);
    fs = NULL;
    exception_seen = 0;
    verified = ped_file_system_open(target);
    if (!verified || exception_seen || !verified->type
        || strcmp(verified->type->name, fs_name) != 0
        || verified->geom->length != target->length) {
        fprintf(stderr, "pxeosfatgrow: resized FAT geometry verification failed\n");
        goto out;
    }
    result = 0;

out:
    if (verified)
        ped_file_system_close(verified);
    if (fs)
        ped_file_system_close(fs);
    if (target)
        ped_geometry_destroy(target);
    if (device) {
        if (device->open_count > 0)
            ped_device_close(device);
        ped_device_destroy(device);
    }
    return result;
}

int
main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: pxeosfatgrow <partition-device-or-fat-image>\n");
        return 2;
    }
    return run(argv[1]);
}
