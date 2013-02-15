#!/bin/sh

#
# Copyright (c) 2013 Vojtech Horky
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# - Redistributions of source code must retain the above copyright
#   notice, this list of conditions and the following disclaimer.
# - Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
# - The name of the author may not be used to endorse or promote products
#   derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

[ -z "$HSCT_HOME" ] && HSCT_HOME=`dirname "$0"`
HSCT_SOURCES_DIR=`pwd`/sources
HSCT_BUILD_DIR=`pwd`/build
HSCT_INCLUDE_DIR=`pwd`/include
HSCT_LIB_DIR=`pwd`/libs
HSCT_MISC_DIR=`pwd`/misc
HSCT_DISABLED_CFLAGS="-Werror -Werror-implicit-function-declaration"

hsct_usage() {
	echo "$1 action [package]"
	echo "action can be one of following:"
	echo "   clean    Clean built directory."
	echo "   build    Build given package."
	echo "   package  Save installable files to allow cleaning."
	echo "   install  Install to uspace/dist of HelenOS."
	exit $2
}

hsct_info() {
	echo ">>>" "$@" >&2
}

hsct_info2() {
	echo "     ->" "$@" >&2
}

msg() {
	hsct_info "$@"
}

hsct_fatal() {
	echo "$@" >&2
	exit 4
}

hsct_run_echo() {
	echo "[hsct]:" "$@"
	"$@"
}

run() {
	hsct_run_echo "$@"
}

# hsct_get_config CONFIG_FILE variable
hsct_get_config() {
	grep '^[ \t]*'"$2" "$1" | cut '-d=' -f 2 | \
		sed -e 's/^[ \t]*//' -e 's/[ \t]*$//'
}

hsct_fetch() {
	mkdir -p "$HSCT_SOURCES_DIR"
	hsct_info "Fetching sources..."
	for _url in $shipsources; do
		_filename=`basename "$_url"`
		if [ "$_filename" = "$_url" ]; then
			continue
		fi
		if ! [ -r "$HSCT_SOURCES_DIR/$_filename" ]; then
			hsct_info2 "Fetching $_filename..."
			wget "$_url" -O "$HSCT_SOURCES_DIR/$_filename" || \
				hsct_fatal "Failed to fetch $_url."
		fi
		# TODO - check MD5
	done
}


# get_var_from_makefile CC Makefile.common
hsct_get_var_from_makefile() {
	# echo "make -C `dirname "$2"` -f - -s __armagedon_" >&2
	(
		echo "$3"
		echo "$4"
		echo "$5"
		echo "__genesis__:"
		echo
		echo "CONFIG_DEBUG=n"
		echo include `basename "$2"`
		echo "CONFIG_DEBUG=n"
		echo
		echo "__armagedon__:"
		echo "	echo \$($1)"
		echo
	)  | make -C `dirname "$2"` -f - -s __armagedon__
}

hsct_get_var_from_uspace() {
	if [ -z "$2" ]; then
		hsct_get_var_from_makefile "$1" "$HSCT_HELENOS_ROOT/uspace/Makefile.common" "USPACE_PREFIX=$HSCT_HELENOS_ROOT/uspace"
	else
		hsct_get_var_from_makefile "$1" "$HSCT_HELENOS_ROOT/uspace/$2" "USPACE_PREFIX=$HSCT_HELENOS_ROOT/uspace" "$3" "$4"
	fi
}

hsct_prepare_env_build() {
	hsct_info "Obtaining CC, CFLAGS etc."
	export HSCT_CC=`hsct_get_var_from_uspace CC`
	export HSCT_AS=`hsct_get_var_from_uspace AS`
	export HSCT_LD=`hsct_get_var_from_uspace LD`
	export HSCT_AR=`hsct_get_var_from_uspace AR`
	export HSCT_STRIP=`hsct_get_var_from_uspace STRIP`
	export HSCT_OBJCOPY=`hsct_get_var_from_uspace OBJCOPY`
	export HSCT_OBJDUMP=`hsct_get_var_from_uspace OBJDUMP`
	# HelenOS do not use ranlib or nm but some applications require it
	export HSCT_RANLIB=`echo "$AR" | sed 's/-ar$/-ranlib/'`
	export HSCT_NM=`echo "$AR" | sed 's/-ar$/-nm/'`

	# Get the flags
	_CFLAGS=`hsct_get_var_from_uspace CFLAGS`
	_LDFLAGS=`hsct_get_var_from_uspace LFLAGS`
	_LINKER_SCRIPT=`hsct_get_var_from_uspace LINKER_SCRIPT`
	
	# Get rid of the disabled CFLAGS
	_CFLAGS_OLD="$_CFLAGS"
	_CFLAGS=""
	for _flag in $_CFLAGS_OLD; do
		_disabled=false
		for _disabled_flag in $HSCT_DISABLED_CFLAGS; do
			if [ "$_disabled_flag" = "$_flag" ]; then
				_disabled=true
				break
			fi
		done
		if ! $_disabled; then
			_CFLAGS="$_CFLAGS $_flag"
		fi
	done
	
	
	
	_POSIX_LIB="$HSCT_HELENOS_ROOT/uspace/lib/posix"
	# Include paths
	_POSIX_INCLUDES="-I$_POSIX_LIB/include/posix -I$_POSIX_LIB/include"
	# Paths to libraries
	_POSIX_LIBS_LFLAGS="-L$_POSIX_LIB -L$HSCT_HELENOS_ROOT/uspace/lib/c -L$HSCT_HELENOS_ROOT/uspace/lib/softint -L$HSCT_HELENOS_ROOT/uspace/lib/softfloat"
	# Actually used libraries
	# The --whole-archive is used to allow correct linking of static libraries
	# (otherwise, the ordering is crucial and we usally cannot change that in the
	# application Makefiles).
	_POSIX_LINK_LFLAGS="--whole-archive --start-group -lposix -lsoftint --end-group --no-whole-archive -lc"
	_POSIX_BASE_LFLAGS="-n -T $_LINKER_SCRIPT"


	# Update LDFLAGS
	_LDFLAGS="$_LDFLAGS $_POSIX_LIBS_LFLAGS $_POSIX_LINK_LFLAGS $_POSIX_BASE_LFLAGS"

	# The LDFLAGS might be used through CC, thus prefixing with -Wl is required
	_LDFLAGS_FOR_CC=""
	for _flag in $_LDFLAGS; do
		_LDFLAGS_FOR_CC="$_LDFLAGS_FOR_CC -Wl,$_flag"
	done
	
	# Update the CFLAGS
	export HSCT_CFLAGS="$_POSIX_INCLUDES $_CFLAGS"
	export HSCT_LDFLAGS_FOR_CC="$_LDFLAGS_FOR_CC"
	export HSCT_LDFLAGS="$_LDFLAGS"
	
	# Target architecture
	_UARCH=`hsct_get_var_from_uspace UARCH`
	_TARGET=""
	case $_UARCH in
		ia32)
			_TARGET="i686-pc-linux-gnu"
			;;
		amd64)
			_TARGET="amd64-linux-gnu"
			;;
		mips32)
			_TARGET="mipsel-linux-gnu"
			;;
		*)
			hsct_fatal "Unsupported architecture $_UARCH."
			;;
	esac
	export HSCT_GNU_TARGET="$_TARGET"
}

hsct_prepare_env_package() {
	export HSCT_INCLUDE_DIR
	export HSCT_LIB_DIR
	export HSCT_MISC_DIR
}

hsct_clean() {
	hsct_info "Cleaning build directory..."
	rm -rf "$HSCT_BUILD_DIR/$shipname/"*
}

hsct_build() {
	mkdir -p "$HSCT_BUILD_DIR/$shipname"
	if [ -e "$HSCT_BUILD_DIR/${shipname}.built" ]; then
		hsct_info "No need to build $shipname."
		return 0;
	fi
	
	hsct_fetch
	
	for _url in $shipsources; do
		_filename=`basename "$_url"`
		if [ "$_filename" = "$_url" ]; then
			_origin="$HSCT_HOME/$shipname/$_filename" 
		else
			_origin="$HSCT_SOURCES_DIR/$_filename"
		fi
		ln -sf "$_origin" "$HSCT_BUILD_DIR/$shipname/$_filename"
	done
	
	hsct_prepare_env_build
	
	(
		cd "$HSCT_BUILD_DIR/$shipname/"
		hsct_info "Building..."
		build || hsct_fatal "Build failed!"
	) || exit $?
	touch "$HSCT_BUILD_DIR/${shipname}.built"
}

hsct_package() {
	mkdir -p "$HSCT_INCLUDE_DIR" || hsct_fatal "Failed to create include directory."
	mkdir -p "$HSCT_LIB_DIR" || hsct_fatal "Failed to create library directory."
	mkdir -p "$HSCT_MISC_DIR" || hsct_fatal "Failed to create miscellaneous directory."
	
	if [ -e "$HSCT_BUILD_DIR/${shipname}.packaged" ]; then
		hsct_info "No need to package $shipname."
		return 0;
	fi
	
	hsct_build
	
	hsct_prepare_env_package
	
	(	
		cd "$HSCT_BUILD_DIR/$shipname/"
		hsct_info "Packaging..."
		package || hsct_fatal "Packaging failed!"
	) || exit $?
	touch "$HSCT_BUILD_DIR/${shipname}.packaged"
}

hsct_install() {
	hsct_package

	hsct_prepare_env_package
	
	(	
		hsct_info "Installing..."
		dist || hsct_fatal "Installing failed!"
	) || exit $?
}

HSCT_CONFIG=hsct.conf
HSCT_HELENOS_ROOT=`hsct_get_config "$HSCT_CONFIG" root`
if [ -z "$HSCT_HELENOS_ROOT" ]; then
	hsct_fatal "root not set in $HSCT_CONFIG"
fi
HSCT_DIST="$HSCT_HELENOS_ROOT/uspace/dist"


case "$1" in
	help)
		hsct_usage "$0" 0
		;;
	clean|build|package|install)
		HSCT_HARBOUR_NAME="$2"
		if [ -z "$HSCT_HARBOUR_NAME" ]; then
			hsct_usage "$0" 1
		fi
		;;
	*)
		hsct_usage "$0" 1
		;;
esac


if ! [ -d "$HSCT_HOME/$HSCT_HARBOUR_NAME" ]; then
	echo "Unknown package $1" >&2
	exit 3
fi

if ! [ -r "$HSCT_HOME/$HSCT_HARBOUR_NAME/HARBOUR" ]; then
	echo "HARBOUR file missing." >&2
	exit 3
fi

source "$HSCT_HOME/$HSCT_HARBOUR_NAME/HARBOUR"

case "$1" in
	clean)
		hsct_clean
		;;
	build)
		hsct_build
		;;
	package)
		hsct_package
		;;
	install)
		hsct_install
		;;
	*)
		hsct_fatal "Internal error, we shall not get to this point!"
		;;
esac