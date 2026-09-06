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

$(eval $(autotools-package))
