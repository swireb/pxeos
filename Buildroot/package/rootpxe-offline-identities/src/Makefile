CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2
CFLAGS += -std=c11 -D_FILE_OFFSET_BITS=64 -Wall -Wextra -Werror -Wformat=2
CPPFLAGS += $(shell $(PKG_CONFIG) --cflags hivex)
LDLIBS += $(shell $(PKG_CONFIG) --libs hivex)

SOURCES = rootpxe-offline-identities.c

rootpxe-offline-identities: $(SOURCES)
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $(SOURCES) $(LDFLAGS) $(LDLIBS)

clean:
	rm -f rootpxe-offline-identities
