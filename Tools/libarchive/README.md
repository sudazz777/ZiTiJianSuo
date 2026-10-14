# libarchive headers

`archive.h` and `archive_entry.h` are the public API headers from libarchive v3.3.3:

- https://github.com/libarchive/libarchive/blob/v3.3.3/libarchive/archive.h
- https://github.com/libarchive/libarchive/blob/v3.3.3/libarchive/archive_entry.h

The macOS SDK ships the system library but does not include these headers. The build includes these declarations and links to macOS `libarchive`; no downloaded libarchive binary is bundled. The original copyright and BSD license notices remain in both headers. The bridge uses APIs available in the macOS system library.
