#ifndef FONT_ARCHIVE_BRIDGE_H
#define FONT_ARCHIVE_BRIDGE_H
#include <stddef.h>
int fontfinder_extract_archive(const char *archive_path, const char *output_path,
                              size_t *remaining_entries, unsigned long long *remaining_bytes,
                              char *error_buffer, size_t error_buffer_size);
#endif
