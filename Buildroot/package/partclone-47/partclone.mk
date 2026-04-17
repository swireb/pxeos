################################################################################
#
# partclone (0.3.47)
#
################################################################################

PARTCLONE_47_VERSION = 0.3.47
PARTCLONE_47_SOURCE = partclone-$(PARTCLONE_47_VERSION).tar.gz
PARTCLONE_47_SITE = $(call github,Thomas-Tsai,partclone,$(PARTCLONE_47_VERSION))
PARTCLONE_47_INSTALL_STAGING = YES
PARTCLONE_47_AUTORECONF = YES
PARTCLONE_47_DEPENDENCIES += host-pkgconf host-gettext util-linux e2fsprogs liburcu
PARTCLONE_47_CONF_OPTS = --enable-static-linking --enable-xfs --enable-btrfs --enable-ntfs --enable-extfs --enable-fat --enable-hfsp --enable-apfs --enable-ncursesw --enable-f2fs --disable-xxhash
PARTCLONE_47_EXTRA_LIBS = -ldl -latomic
PARTCLONE_47_CONF_ENV += LIBS="$(PARTCLONE_47_EXTRA_LIBS)"

define PARTCLONE_47_PRE_CONFIGURE_AUTOGEN
	cd $(@D)/ && ./autogen
endef

PARTCLONE_47_PRE_CONFIGURE_HOOKS += PARTCLONE_47_PRE_CONFIGURE_AUTOGEN

$(eval $(autotools-package))
