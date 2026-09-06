################################################################################
# rootpxe-offline-identities
################################################################################

ROOTPXE_OFFLINE_IDENTITIES_VERSION = 1
ROOTPXE_OFFLINE_IDENTITIES_SITE_METHOD = local
ROOTPXE_OFFLINE_IDENTITIES_SITE = $(TOPDIR)/package/rootpxe-offline-identities/src
ROOTPXE_OFFLINE_IDENTITIES_DEPENDENCIES = json-c libxml2 libhivex

define ROOTPXE_OFFLINE_IDENTITIES_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS)" \
		PKG_CONFIG="$(PKG_CONFIG_HOST_BINARY)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define ROOTPXE_OFFLINE_IDENTITIES_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/rootpxe-offline-identities \
		$(TARGET_DIR)/usr/sbin/rootpxe-offline-identities
	$(STRIPCMD) $(STRIP_STRIP_ALL) \
		$(TARGET_DIR)/usr/sbin/rootpxe-offline-identities
endef

$(eval $(generic-package))
