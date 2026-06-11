################################################################################
#
# partclone
#
################################################################################

PARTCLONE_33_VERSION = 0.3.33
PARTCLONE_33_SOURCE = partclone-$(PARTCLONE_33_VERSION).tar.gz
PARTCLONE_33_SITE = $(call github,Thomas-Tsai,partclone,$(PARTCLONE_33_VERSION))
PARTCLONE_33_INSTALL_STAGING = YES
PARTCLONE_33_AUTORECONF = YES
PARTCLONE_33_DEPENDENCIES += attr e2fsprogs libgcrypt lzo xz zlib xfsprogs ncurses host-pkgconf
PARTCLONE_33_CONF_OPTS = --enable-static --enable-xfs --enable-btrfs --enable-ntfs --enable-extfs --enable-fat --enable-hfsp --enable-apfs --enable-ncursesw --enable-f2fs
PARTCLONE_33_EXTRA_LIBS = -ldl -latomic
PARTCLONE_33_CONF_ENV += LIBS="$(PARTCLONE_33_EXTRA_LIBS)"

define PARTCLONE_33_LINK_LIBRARIES_TOOL
	ln -f -s $(BUILD_DIR)/xfsprogs-*/include/xfs $(STAGING_DIR)/usr/include/
	ln -f -s $(BUILD_DIR)/xfsprogs-*/libxfs/.libs/libxfs.* $(STAGING_DIR)/usr/lib/
	ln -f -s $(@D)/fail-mbr/fail-mbr.bin $(@D)/fail-mbr/fail-mbr.bin.orig
endef

PARTCLONE_33_POST_PATCH_HOOKS += PARTCLONE_33_LINK_LIBRARIES_TOOL

$(eval $(autotools-package))
