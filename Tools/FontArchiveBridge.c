#include "FontArchiveBridge.h"
#include <archive.h>
#include <archive_entry.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(char *message, size_t capacity, const char *text) {
    if (capacity) snprintf(message, capacity, "%s", text);
    return -1;
}
static int unsafe_path(const char *name) {
    if (!name || name[0] == '/' || strchr(name, '\\')) return 1;
    const char *part = name;
    while (*part) {
        const char *end = strchr(part, '/');
        size_t size = end ? (size_t)(end - part) : strlen(part);
        if (size == 2 && part[0] == '.' && part[1] == '.') return 1;
        if (!end) break;
        part = end + 1;
    }
    return 0;
}
int fontfinder_extract_archive(const char *source, const char *output,
                              size_t *entries, unsigned long long *bytes,
                              char *message, size_t capacity) {
    struct archive *reader = archive_read_new();
    if (!reader) return fail(message, capacity, "Unable to open ZIP archive.");
    archive_read_support_format_zip(reader);
    archive_read_support_filter_all(reader);
    int result = 0;
    if (archive_read_open_filename(reader, source, 65536) != ARCHIVE_OK) {
        result = fail(message, capacity, "ZIP archive is damaged or encrypted.");
        goto finish;
    }
    struct archive_entry *entry;
    size_t number = 0;
    int status;
    while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if (unsafe_path(name) || archive_entry_symlink(entry) || archive_entry_hardlink(entry)) {
            result = fail(message, capacity, "ZIP archive contains an unsafe path or link."); break;
        }
        if (!*entries) { result = fail(message, capacity, "Too many ZIP entries."); break; }
        --*entries;
        if (archive_entry_filetype(entry) == AE_IFDIR) { archive_read_data_skip(reader); continue; }
        if (archive_entry_filetype(entry) != AE_IFREG) { result = fail(message, capacity, "Unsupported ZIP entry type."); break; }
        la_int64_t size = archive_entry_size(entry);
        if (size < 0 || (unsigned long long)size > *bytes) { result = fail(message, capacity, "ZIP archive exceeds extraction limit."); break; }
        const char *extension = strrchr(name, '.');
        int supported = extension && (!strcasecmp(extension, ".ttf") || !strcasecmp(extension, ".otf") || !strcasecmp(extension, ".ttc") || !strcasecmp(extension, ".zip"));
        if (!supported || !strncmp(name, "__MACOSX/", 9)) { archive_read_data_skip(reader); continue; }
        if ((unsigned long long)size > 256ULL * 1024 * 1024) { result = fail(message, capacity, "A ZIP entry exceeds 256 MiB."); break; }
        char destination[4096];
        int length = snprintf(destination, sizeof(destination), "%s/item-%zu%s", output, ++number, extension);
        if (length < 0 || (size_t)length >= sizeof(destination)) { result = fail(message, capacity, "ZIP output path is too long."); break; }
        // Archive entry names never become filesystem paths. Output is flat and
        // exclusively created inside the app's private temporary job directory.
        int file = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (file < 0) { result = fail(message, capacity, "Unable to save extracted font."); break; }
        char buffer[65536];
        la_ssize_t count;
        unsigned long long extracted = 0;
        while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
            if ((unsigned long long)count > *bytes || extracted + (unsigned long long)count > 256ULL * 1024 * 1024) {
                result = fail(message, capacity, "ZIP archive exceeds extraction limit."); break;
            }
            *bytes -= (unsigned long long)count;
            extracted += (unsigned long long)count;
            la_ssize_t offset = 0;
            while (offset < count) {
                ssize_t written = write(file, buffer + offset, (size_t)(count - offset));
                if (written < 0 && errno == EINTR) continue;
                if (written <= 0) { result = fail(message, capacity, "Unable to write extracted font."); break; }
                offset += written;
            }
            if (result) break;
        }
        close(file);
        if (!result && count < 0) result = fail(message, capacity, "ZIP contents are damaged or encrypted.");
        if (!result && extracted != (unsigned long long)size) result = fail(message, capacity, "ZIP entry size does not match its metadata.");
        if (result) { unlink(destination); break; }
    }
    if (!result && status != ARCHIVE_EOF) result = fail(message, capacity, "ZIP archive is incomplete.");
finish:
    archive_read_free(reader);
    return result;
}
