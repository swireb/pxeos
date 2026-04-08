
#############################################################
#
# pxeos
#
#############################################################
PXEOS_VERSION = 1
PXEOS_DEPENDENCIES = parted
# 原始下载链接：https://www.fogproject.org/fog_1.tar.gz
PXEOS_SITE_METHOD = local
PXEOS_SITE = $(TOPDIR)/package/pxeos

define PXEOS_BUILD_CMDS
	cp -rf $(PXEOS_SITE)/src $(@D)
	$(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)/src \
	CXXFLAGS="$(TARGET_CXXFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)"
endef

define PXEOS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/src/pxeosmbrfix $(TARGET_DIR)/bin/pxeosmbrfix
	$(STRIPCMD) $(STRIP_STRIP_ALL) $(TARGET_DIR)/bin/pxeosmbrfix
endef

$(eval $(generic-package))
