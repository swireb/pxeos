CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2
CFLAGS += -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror -Wformat=2
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags json-c libxml-2.0 hivex)
LDLIBS += $(shell $(PKG_CONFIG) --libs json-c libxml-2.0 hivex)

SOURCES = rootpxe-offline-identities.c efi-identities.c

rootpxe-offline-identities: $(SOURCES) efi-identities.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS) $(LDLIBS)

clean:
	rm -f rootpxe-offline-identities
