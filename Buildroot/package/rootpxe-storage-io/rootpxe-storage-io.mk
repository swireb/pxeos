ROOTPXE_STORAGE_IO_VERSION = 1
ROOTPXE_STORAGE_IO_SITE_METHOD = local
ROOTPXE_STORAGE_IO_SITE = $(TOPDIR)/package/rootpxe-storage-io/src
ROOTPXE_STORAGE_IO_DEPENDENCIES = json-c openssl

define ROOTPXE_STORAGE_IO_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)"
endef

define ROOTPXE_STORAGE_IO_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rootpxe-storage-io $(TARGET_DIR)/usr/sbin/rootpxe-storage-io
	$(STRIPCMD) $(STRIP_STRIP_ALL) $(TARGET_DIR)/usr/sbin/rootpxe-storage-io
endef

$(eval $(generic-package))
