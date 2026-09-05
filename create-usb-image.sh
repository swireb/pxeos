#!/bin/bash

set -e

dl_url=${1:-}
boot_assets_dir=${2:-}

if [ -z "$dl_url" ] || [ -z "$boot_assets_dir" ]; then
    echo "Usage: $0 <base URL for downloading bzImage and init.xz> --boot-assets <directory>"
    echo "       $0 <base URL for downloading bzImage and init.xz> <boot-assets-directory>"
    echo "The directory must contain verified memdisk, memtest.bin, ipxe.krn, and ipxe.efi assets."
    exit 1
fi

if [ "$boot_assets_dir" = "--boot-assets" ]; then
    boot_assets_dir=${3:-}
fi
[ -n "$boot_assets_dir" ] || { echo "Usage: $0 <base URL> --boot-assets <directory>" >&2; exit 1; }

validate_boot_asset() {
    local asset path mime magic
    asset="$1"
    path="$boot_assets_dir/$asset"
    [ -s "$path" ] && [ ! -L "$path" ] || { echo "Missing or empty boot asset: $asset" >&2; return 1; }
    mime=$(file -b --mime-type "$path") || return 1
    case "$mime" in text/*|application/json|application/xml|text/html) echo "Invalid boot asset (text/HTML): $asset" >&2; return 1;; esac
    if [ "$asset" = ipxe.efi ]; then
        magic=$(od -An -tx1 -N2 "$path" | tr -d '[:space:]') || return 1
        [ "$magic" = 4d5a ] || { echo "Invalid EFI boot asset: $asset" >&2; return 1; }
    fi
}

for boot_asset in memdisk memtest.bin ipxe.krn ipxe.efi; do
    validate_boot_asset "$boot_asset" || exit 1
done

if [ -f /tmp/pxeoskern.img ]; then
    echo Nuking old PXEOS Debug image
    rm -f /tmp/fos-usb.img
fi

echo Make a blank 128MB disk image
dd if=/dev/zero of=/tmp/fos-usb.img bs=1M count=128

echo Make the partition table, partition and set it bootable.
parted --script /tmp/fos-usb.img mklabel msdos mkpart p fat32 1 128 set 1 boot on

echo Map the partitions from the image file
kpartx -a -s /tmp/fos-usb.img
LOOPDEV=$(losetup -a | grep "/tmp/fos-usb.img" | grep -o "loop[0-9]*")

echo Make an vfat filesystem on the first partition.
mkfs -t vfat -n GRUB /dev/mapper/${LOOPDEV}p1

echo Mount the filesystem via loopback
mount /dev/mapper/${LOOPDEV}p1 /mnt

echo Install GRUB
grub-install --removable --no-nvram --no-uefi-secure-boot --efi-directory=/mnt --boot-directory=/mnt/boot --target=x86_64-efi

echo Download the PXEOS kernels and inits
wget -P /mnt/boot/ ${dl_url}/bzImage
wget -P /mnt/boot/ ${dl_url}/init.xz
for boot_asset in memdisk memtest.bin ipxe.krn ipxe.efi; do
    cp "$boot_assets_dir/$boot_asset" "/mnt/boot/$boot_asset"
done

cat > /mnt/boot/README.txt << 'EOF'

!! IMPORTANT !! Change the mypxeosip variable in the boot/grub/grub.cfg file to the IP address of your RootPXE server first!

This is the PXEOS USB image. It is designed to register machines, as well as deploy and capture images from a RootPXE server on machines that have trouble with PXE.

To use this image, you will need to create a bootable USB stick. You can use the following command to write this image to a USB stick:

dd if=fos-usb.img of=/dev/sdX bs=1M

Where /dev/sdX is the device name of your USB stick. Be very careful with this command, as it can destroy data on your hard drive if you specify the wrong device.

Once you have written the image to the USB stick, you can boot the target system from the USB stick. The system will boot into a FOG menu that will allow you to capture an image, deploy an image, register a host, or run a memory test.

EOF

echo Create the grub configuration file
cat > /mnt/boot/grub/grub.cfg << 'EOF'

set mypxeosip=http://change-this-to-your-rootpxe-ip
set myimage=/boot/bzImage
set myinits=/boot/init.xz
set myloglevel=4
set timeout=-1
insmod all_video

menuentry "1. PXEOS Image Deploy/Capture" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$mypxeosip/service/pxeos/ boottype=usb consoleblank=0 rootfstype=ext4
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "2. Perform Full Host Registration and Inventory" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$mypxeosip/service/pxeos/ boottype=usb consoleblank=0 rootfstype=ext4 mode=manreg
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "3. Quick Registration and Inventory" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$mypxeosip/service/pxeos/ boottype=usb consoleblank=0 rootfstype=ext4 mode=autoreg
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "4. Client System Information (Compatibility)" {
 echo loading the kernel
 linux  $myimage loglevel=$myloglevel initrd=init.xz root=/dev/ram0 rw ramdisk_size=275000 keymap= web=$mypxeosip/service/pxeos/ boottype=usb consoleblank=0 rootfstype=ext4 mode=sysinfo
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "5. Run Memtest86+" {
 linux /boot/memdisk iso raw
 initrd /boot/memtest.bin
}

menuentry "6. PXEOS Debug Kernel" {
 echo loading the kernel
 linux  $myimage loglevel=7 init=/sbin/init root=/dev/ram0 rw ramdisk_size=275000 keymap= boottype=usb consoleblank=0 rootfstype=ext4 isdebug=yes
 echo loading the virtual hard drive
 initrd $myinits
 echo booting kernel...
}

menuentry "7. PXEOS iPXE Jumpstart BIOS" {
 echo loading the kernel
 linux16  /boot/ipxe.krn
 echo booting iPXE...
}

menuentry "8. PXEOS iPXE Jumpstart EFI" {
 echo chain loading the kernel
 insmod chain
 chainloader /boot/ipxe.efi
 echo booting iPXE-efi...
}

EOF

echo Unmount the loopback
umount /mnt

echo Unmap the image
kpartx -d /tmp/fos-usb.img
