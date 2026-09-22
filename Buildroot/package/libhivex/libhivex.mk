################################################################################
# libhivex
################################################################################

LIBHIVEX_VERSION = 1.3.24
LIBHIVEX_SOURCE = hivex-$(LIBHIVEX_VERSION).tar.gz
LIBHIVEX_SITE = https://download.libguestfs.org/hivex
LIBHIVEX_LICENSE = LGPL-2.1
LIBHIVEX_LICENSE_FILES = LICENSE
LIBHIVEX_INSTALL_STAGING = YES
# configure invokes pod2man even though target language bindings are disabled.
# host-perl supplies that documentation generator without adding target Perl.
LIBHIVEX_DEPENDENCIES = host-pkgconf host-perl
LIBHIVEX_CONF_OPTS = --disable-ocaml --disable-perl --disable-python --disable-ruby --disable-static

# Do not invoke the upstream top-level recursive targets: images/ runs the
# target-built mklarge helper, while xml/ and sh/ build unused CLI tools.
# lib/ links against gnulib/lib/libgnu.la; lib/ and include/ own the required
# library/pkg-config and public-header install rules, respectively.
define LIBHIVEX_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/gnulib/lib
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/lib
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/include
endef

define LIBHIVEX_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/lib DESTDIR=$(STAGING_DIR) install
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/include DESTDIR=$(STAGING_DIR) install
endef

define LIBHIVEX_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/lib DESTDIR=$(TARGET_DIR) install
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/include DESTDIR=$(TARGET_DIR) install
endef

$(eval $(autotools-package))
