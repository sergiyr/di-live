#!/bin/sh
set -e
. /usr/share/debconf/confmodule

MISSING=/dev/.udev/firmware-missing
DENIED=/tmp/missing-firmware-denied

if [ "x$1" = "x-n" ]; then
	NONINTERACTIVE=1
else
	NONINTERACTIVE=""
fi

log () {
	logger -t check-missing-firmware "$@"
}

# Not all drivers register themselves if firmware is missing; in that
# case determine the module via the device's modalias.
get_module () {
	local devpath=$1

	if [ -d $devpath/driver ]; then
		# The realpath of the destination of the driver/module
		# symlink should be something like "/sys/module/e100"
		basename $(realpath $devpath/driver/module) || true
	elif [ -e $devpath/modalias ]; then
		modalias="$(cat $devpath/modalias)"
		# Take the last module returned by modprobe
		modprobe --show-depends "$modalias" 2>/dev/null | \
			sed -n -e '$s#^.*/\([^.]*\)\.ko.*$#\1#p'
	fi
}

check_missing () {
	# Give modules some time to request firmware.
	sleep 1
	
	modules=""
	files=""
	if [ -d "$MISSING" ]; then
		for file in $(find $MISSING -type l); do
			# decode firmware filename as encoded by
			# udev firmware.agent
			fwfile="$(basename $file | sed -e 's#\\x2f#/#g')"
			
			# strip probably nonexistant firmware subdirectory
			devpath="$(readlink $file | sed 's/\/firmware\/.*//')"
			# the symlink is supposed to point to the device in /sys
			if ! echo "$devpath" | grep -q '^/sys/'; then
				devpath="/sys$devpath"
			fi

			module=$(get_module "$devpath")
			if [ -z "$module" ]; then
				log "failed to determine module from $devpath"
				continue
			fi

			rm -f "$file"

			if grep -q "^$fwfile$" $DENIED 2>/dev/null; then
				continue
			fi

			modules="$module${modules:+ $modules}"
			files="$fwfile${files:+ $files}"
		done
	fi

	if [ -n "$modules" ]; then
		log "missing firmware files ($files) for $modules"
		return 0
	else
		log "no missing firmware in $MISSING"
		return 1
	fi
}

# If found, copy firmware file; preserve subdirs.
try_copy () {
	local fwfile=$1
	local sdir file f target

	sdir=$(dirname $fwfile | sed "s/^\.$//")
	file=$(basename $fwfile)
	for f in "/media/$fwfile" "/media/firmware/$fwfile" \
		 ${sdir:+"/media/$file" "/media/firmware/$file"}; do
		if [ -e "$f" ]; then
			target="/lib/firmware${sdir:+/$sdir}"
			log "copying loose file $file from '$(dirname $f)' to '$target'"
			mkdir -p "$target"
			rm -f "$target/$file"
			cp -aL "$f" "$target" || true
			break
		fi
	done
}

first_try=1
first_ask=1
ask_load_firmware () {
	if [ "$first_try" ]; then
		first_try=""
		return 0
	fi

	if [ "$NONINTERACTIVE" ]; then
		if [ ! "$first_ask" ]; then
			return 1
		else
			first_ask=""
			return 0
		fi
	fi

	db_subst hw-detect/load_firmware FILES "$files"
	if ! db_input high hw-detect/load_firmware; then
		if [ ! "$first_ask" ]; then
			exit 1;
		else
			first_ask=""
		fi
	fi
	if ! db_go; then
		exit 10 # back up
	fi
	db_get hw-detect/load_firmware
	if [ "$RET" = true ]; then
		return 0
	else
		echo "$files" | tr ' ' '\n' >> $DENIED
		return 1
	fi
}

list_deb_firmware () {
	ar p "$1" data.tar.gz | tar zt \
		| grep '^\./lib/firmware/' \
		| sed -e 's!^\./lib/firmware/!!' \
		| grep -v '^$'
}

check_deb_arch () {
	arch=$(ar p "$1" control.tar.gz | tar zxO ./control | grep '^Architecture:' | sed -e 's/Architecture: *//')
	[ "$arch" = all ] || [ "$arch" = "$(udpkg --print-architecture)" ]
}

# Remove non-accepted firmware package
remove_pkg() {
	pkgname="$1"
	# Remove all files listed in /var/lib/dpkg/info/$pkgname.md5sum
	for file in $(cut -d" " -f 2- /var/lib/dpkg/info/$pkgname.md5sum) ; do
		rm /$file
	done
}

install_firmware_pkg () {
	if echo "$1" | grep -q '\.deb$'; then
		# cache deb for installation into /target later
		mkdir -p /var/cache/firmware/
		cp -aL "$1" /var/cache/firmware/ || true
		filename="$(basename "$1")"
		pkgname="$(echo $filename |cut -d_ -f1)"
		udpkg --unpack "/var/cache/firmware/$filename"
		if [ -f /var/lib/dpkg/info/$pkgname.preinst ] ; then
			# Run preinst script to see if the firmware
			# license is accepted Exit code of preinst
			# decide if the package should be installed or
			# not.
			if /var/lib/dpkg/info/$pkgname.preinst ; then
				:
			else
				remove_pkg "$pkgname"
				rm "/var/cache/firmware/$filename"
			fi
		fi
	else
		udpkg --unpack "$1"
	fi
}

# Try to load udebs (or debs) that contain the missing firmware.
# This does not use anna because debs can have arbitrary
# dependencies, which anna might try to install.
check_for_firmware() {
	echo "$files" | sed -e 's/ /\n/g' >/tmp/grepfor
	for filename in $@; do
		if [ -f "$filename" ]; then
			if check_deb_arch "$filename" && list_deb_firmware "$filename" | grep -qf /tmp/grepfor; then
				log "installing firmware package $filename"
				install_firmware_pkg "$filename" || true
			fi
		fi
	done
	rm -f /tmp/grepfor
}

while check_missing && ask_load_firmware; do
	# first, check if needed firmware (u)debs are available on the
	# PXE initrd or the installation CD.
	if [ -d /firmware ]; then
		check_for_firmware /firmware/*.deb /firmware/*.udeb
	fi
	if [ -d /cdrom/firmware ]; then
		check_for_firmware /cdrom/firmware/*.deb /cdrom/firmware/*.udeb
	fi

	# second, look for loose firmware files on the media device.
	if mountmedia; then
		for file in $files; do
			try_copy "$file"
		done
		umount /media || true
	fi

	# last, look for firmware (u)debs on the media device
	if mountmedia driver; then
		check_for_firmware /media/*.deb /media/*.udeb /media/*.ude /media/firmware/*.deb /media/firmware/*.udeb /media/firmware/*.ude
		umount /media || true
	fi

	# remove and reload modules so they see the new firmware
	# Sort to only reload a given module once if it ask for more
	# than one firmware file (example iwlagn)
	for module in $(echo $modules | tr " " "\n" | sort -u); do
		modprobe -r $module || true
		modprobe $module || true
	done
done
