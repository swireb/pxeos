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

# Only recurse through the C library and development-file prerequisites.
# images/ runs the target-built mklarge helper; xml and sh build CLI tools.
# MAKEOVERRIDES= keeps this top-level SUBDIRS value from leaking into the
# lib subdirectory's own recursive make calls.
LIBHIVEX_SUBDIRS = gnulib/lib generator lib include
LIBHIVEX_MAKE_OPTS = \
	MAKEOVERRIDES= \
	SUBDIRS="$(LIBHIVEX_SUBDIRS)"
LIBHIVEX_INSTALL_STAGING_OPTS = \
	MAKEOVERRIDES= \
	SUBDIRS="$(LIBHIVEX_SUBDIRS)" \
	DESTDIR=$(STAGING_DIR) install
LIBHIVEX_INSTALL_TARGET_OPTS = \
	MAKEOVERRIDES= \
	SUBDIRS="$(LIBHIVEX_SUBDIRS)" \
	DESTDIR=$(TARGET_DIR) install

$(eval $(autotools-package))
