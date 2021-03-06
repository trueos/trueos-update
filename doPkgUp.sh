#!/bin/sh

# Don't change these, get set dynamically at upgrade time by trueos-update
PKG_FLAG="%%PKG_FLAG%%"
REALPKGDLCACHE="%%REALPKGDLCACHE%%"
PKGFILENAME="%%PKGFILENAME%%"

update_bootloader()
{
  local ROOTPOOL=`mount | grep 'on / ' | cut -d '/' -f 1`
  if [ -z "$ROOTPOOL" ] ; then return ; fi

  # Thow the new boot-loader on each disk
  for disk in $(sysctl -n kern.disks); do

    # Why CD's show up in kern.disks? Dunno...
    echo $disk | grep -q "^cd[0-9]"
    if [ $? -eq 0 ] ; then continue ; fi

    # Check if the disk has a gptid on the second "p2" partition
    gptid=$(gpart list $disk | grep rawuuid | sed -n 2p | awk '{print $2}')
    # If we didn't find a gptid for this disk / partition, set to a bogus name so we dont match
    if [ -z "$gptid" ] ; then gptid="bogusdisknamenotused" ; fi

    # Does this disk exist in freenas-boot?
    zpool status ${ROOTPOOL} | grep -q -e " ${disk}p" -e " gptid/$gptid "
    if [ $? -ne 0 ] ; then continue ; fi
    if gpart show ${disk} | grep -q freebsd-boot; then
      echo "Updating to latest GPT/BIOS bootloader..."
      part=$(gpart show ${disk} | grep " freebsd-boot " | awk '{print $3}')
      gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i ${part} /dev/${disk}
    elif gpart show ${disk} | grep -q " efi "; then
      if [ ! -d "/boot/efi" ] ; then
        mkdir -p /boot/efi
      fi
      part=$(gpart show ${disk} | grep " efi " | awk '{print $3}')
      if mount -t msdosfs /dev/${disk}p${part} /boot/efi; then
	echo "Updating to latest EFI bootloader..."
	# If they are using rEFInd and we have a bootx64-trueos.efi
	if [ -e "/boot/efi/efi/boot/bootx64-trueos.efi" ] ; then
          cp /boot/boot1.efi /boot/efi/efi/boot/bootx64-trueos.efi
	else
          cp /boot/boot1.efi /boot/efi/efi/boot/bootx64.efi
	fi
        umount -f /boot/efi
      fi
    fi
  done
}

## Try to get error status of first command in pipeline ##
run_cmd_wtee()
{
  ((((${1} 2>&1 ; echo $? >&3 ) | tee -a ${2} >&4 ) 3>&1) | (read xs; exit $xs)) 4>&1
  return $?
}

# Set the cache directory
PKG_CFLAG="-C /var/db/trueos-update/.pkgUpdate.conf"
echo "PKG_CACHEDIR: $REALPKGDLCACHE" > /var/db/trueos-update/.pkgUpdate.conf
echo "PKG_DBDIR: /var/db/trueos-update/pkgdb" >> /var/db/trueos-update/.pkgUpdate.conf

# Need to export this before installing pkgs, some scripts may try to be interactive
PACKAGE_BUILDING="YES"
export PACKAGE_BUILDING

# Cleanup the old /compat/linux for left-overs
umount /compat/linux/proc >/dev/null 2>/dev/null
umount /compat/linux/sys >/dev/null 2>/dev/null
rm -rf /compat/linux
mkdir -p /compat/linux/proc
mkdir -p /compat/linux/sys
mkdir -p /compat/linux/usr
mkdir -p /compat/linux/dev
mkdir -p /compat/linux/run
ln -s /usr/home /compat/linux/usr/home

# Make sure the various openrc dirs exist
mkdir -p /etc/runlevels 2>/dev/null
mkdir -p /etc/runlevels/boot 2>/dev/null
mkdir -p /etc/runlevels/default 2>/dev/null
mkdir -p /etc/runlevels/nonetwork 2>/dev/null
mkdir -p /etc/runlevels/shutdown 2>/dev/null
mkdir -p /etc/runlevels/sysinit 2>/dev/null
mkdir -p /libexec/rc/init.d 2>/dev/null

cd ${REALPKGDLCACHE}
find . -type file -print | sort > /tmp/.pkgUpList

while read pkgfile
do
  if [ -e '/pkg-add.log' ]; then rm /pkg-add.log; fi

  # Get the pkg origin
  unset ORIGIN
  ORIGIN=$(pkg-static ${PKG_CFLAG} ${PKG_FLAG} info -o -F ${pkgfile} | awk '{print $2}')

  # If this is empty
  if [ -z "$ORIGIN" ] ; then
     echo "Empty ORIGIN for $pkgfile!"
     continue
  fi

  # Skip base packages
  if [ "$ORIGIN" = "base" ] ; then continue ; fi

  # Is the package already installed?
  pkg-static ${PKG_CFLAG} ${PKG_FLAG} info -e ${ORIGIN}
  if [ $? -eq 0 ] ; then
	  echo "Skipping already installed: $ORIGIN"
	  continue
  fi

  # Install the package
  echo "Installing $pkgfile..."
  run_cmd_wtee "pkg-static ${PKG_CFLAG} ${PKG_FLAG} add ${pkgfile}" "/pkg-add.log"
  if [ $? -ne 0 ] ; then
     echo "Failed installing ${pkgfile}"
     cat /pkg-add.log
     echo "Failed installing ${pkgfile}" >>/failed-pkg-list
     cat /pkg-add.log >>/failed-pkg-list
  fi
done < /tmp/.pkgUpList
rm /tmp/.pkgUpList
if [ -e '/pkg-add.log' ]; then rm /pkg-add.log; fi

# Update kernel hints
kldxref /boot/kernel /boot/modules

echo "Moving updated pkg repo..."
rm -rf /var/db/pkg.preUpgrade 2>/dev/null
mv /var/db/pkg /var/db/pkg.preUpgrade
mv /var/db/trueos-update/pkgdb /var/db/pkg

# Clean the pkg cache
rm -rf /var/cache/trueos-update

# Save the log files
if [ ! -d "/var/trueos-update" ] ; then
  mkdir -p /var/trueos-update
fi

touch /failed-pkg-list
mv /failed-pkg-list /var/trueos-update/
pkg-static info > /var/trueos-update/current-pkg-list

# Build top-level list of pkgs installed
pkg-static query -e '%a = 0' '%o' | grep -v '^base$' | sort > /var/trueos-update/current-user-pkgs

# Update the boot-loader to latest
update_bootloader

exit 0
