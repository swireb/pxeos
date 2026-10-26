CC ?= cc
PKG_CONFIG ?= pkg-config
override CFLAGS += -std=c11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Wformat=2
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags json-c openssl)
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c openssl)
SOURCES = rootpxe-storage-io.c storage_context.c storage_fs.c storage_mount.c
rootpxe-storage-io: $(SOURCES) storage_context.h storage_fs.h storage_mount.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS) $(LDLIBS)
