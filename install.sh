#!/bin/bash
set -e

PROG=$0
PROGS="dd curl mkfs.ext4 mkfs.vfat fatlabel parted partprobe grub2-install"
DISTRO=/run/k3os/iso

if [ "$K3OS_DEBUG" = true ]; then
    set -x
fi

get_url()
{
    FROM=$1
    TO=$2
    case $FROM in
        ftp*|http*|tftp*)
            curl -o $TO -fL ${FROM}
            ;;
        *)
            cp -f $FROM $TO
            ;;
    esac
}

cleanup2()
{
    if [ -L rootfs ]; then
        rm rootfs
    fi
    if [ -n "${TARGET}" ]; then
        umount ${TARGET}/boot/efi || true
        umount ${TARGET} || true
    fi

    losetup -d ${ISO_DEVICE} || true
    umount $DISTRO || true
}

cleanup()
{
    EXIT=$?
    cleanup2 2>/dev/null || true
    return $EXIT
}

usage()
{
    echo "Usage: $PROG [--force-efi] [--debug] [--tty TTY] [--poweroff] [--takeover] [--no-format] [--config https://.../config.yaml] DEVICE ISO_URL"
    echo ""
    echo "Example: $PROG /dev/vda https://github.com/rancher/k3os/releases/download/v0.8.0/k3os.iso"
    echo ""
    echo "DEVICE must be the disk that will be partitioned (/dev/vda) and the boot loader installed to."
    echo "If you are using --no-format a filesystem with the label K3OS_STATE must exist and optionally"
    echo "K3OS_BOOT, K3OS_OEM may exist."
    echo ""
    echo "The parameters names refer to the same names used in the cmdline, refer to README.md for"
    echo "more info."
    echo ""
    exit 1
}

do_format()
{
    if [ "$K3OS_INSTALL_NO_FORMAT" = "true" ]; then
        return 0
    fi

    dd if=/dev/zero of=${DEVICE} bs=1M count=1
    parted -s ${DEVICE} mklabel ${PARTTABLE}
    if [ "${PARTTABLE}" = "gpt" ]; then
        parted -s ${DEVICE} mkpart primary fat32 0% 50MB
    fi
    parted -s ${DEVICE} mkpart primary ext4 50MB 4GB
    parted -s ${DEVICE} mkpart primary ext4 4GB 8GB
    parted -s ${DEVICE} mkpart primary ext4 8GB 100%
    parted -s ${DEVICE} set 1 ${BOOTFLAG} on
    partprobe 2>/dev/null || true
    sleep 2

    PREFIX=${DEVICE}
    if [ ! -e ${PREFIX}1 ]; then
        PREFIX=${DEVICE}p
    fi

    if [ "${PARTTABLE}" = "gpt" ]; then
        EFI=${PREFIX}1
        BOOT=${PREFIX}2
        OEM=${PREFIX}3
        STATE=${PREFIX}4
    else
        BOOT=${PREFIX}1
        OEM=${PREFIX}2
        STATE=${PREFIX}3
    fi

    if [ -n "${EFI}" ]; then
        mkfs.vfat -F 32 ${EFI}
        fatlabel ${EFI} K3OS_EFI
    fi
    mkfs.ext4 -F -L K3OS_BOOT ${BOOT}
    mkfs.ext4 -F -L K3OS_OEM ${OEM}
    mkfs.ext4 -F -L K3OS_STATE ${STATE}
}

do_mount()
{
    if [ -n "$STATE" ]; then
        STATE=$(blkid -L K3OS_STATE)
    fi
    if [ -n "$BOOT" ]; then
        BOOT=$(blkid -L K3OS_BOOT)
    fi
    if [ -n "$EFI" ]; then
        EFI=$(blkid -L K3OS_EFI)
    fi
    if [ -n "$OEM" ]; then
        OEM=$(blkid -L K3OS_OEM)
    fi

    if [ -z "${STATE}" ]; then
        echo "Failed to find filesystem with label K3OS_STATE"
        return 1
    fi

    if [ -z "${BOOT}" ]; then
        echo "Failed to find filesystem with label K3OS_STATE"
        return 1
    fi

    TARGET=/run/k3os/target
    mkdir -p ${TARGET}
    mount ${STATE} ${TARGET}

    mkdir -p ${TARGET}/boot
    if [ -n "${BOOT}" ]; then
        mount ${BOOT} ${TARGET}/boot
    fi

    if [ -n "${EFI}" ]; then
        mkdir -p ${TARGET}/boot/efi
        mount ${EFI} ${TARGET}/boot/efi
    fi

    if [ -n "${OEM}" ]; then
        mkdir -p ${TARGET}/usr/share/k3os/oem
        mount ${OEM} ${TARGET}/usr/share/k3os/oem
    fi

    mkdir -p ${TARGET}
}

do_copy()
{
    cp ${DISTRO}/{initrd,vmlinuz} ${TARGET}/boot/

    if [ "$K3OS_INSTALL_NO_FORMAT" != "true" ]; then
        echo $DEVICE 2 > $TARGET/.growpart
    fi

    if [ -n "$OEM" ] && [ "$(ls -1 /usr/share/oem 2>/dev/null | wc -l)" -gt 0 ]; then
        cp -rf /usr/share/oem/* ${TARGET}/usr/share/oem/
    fi

    if [ -n "$K3OS_INSTALL_CONFIG_URL" ]; then
        get_url "$K3OS_INSTALL_CONFIG_URL" ${TARGET}/usr/share/k3os/oem/config.d/install.yaml
        chmod 600 ${TARGET}/usr/share/k3os/oem/config.d/install.yaml
    fi

    touch ${TARGET}/.factory-reset
}

install_grub()
{
    if [ "$K3OS_INSTALL_DEBUG" ]; then
        GRUB_DEBUG="k3os.debug"
    fi

    mkdir -p ${TARGET}/boot/grub2
    cat > ${TARGET}/boot/grub2/grub.cfg << EOF
set default=0
set timeout=10

set gfxmode=auto
set gfxpayload=keep
insmod all_video
insmod gfxterm

menuentry "k3OS Current" {
  search.fs_label K3OS_BOOT root
  set root=(\$root)
  linux /vmlinuz-current printk.devkmsg=on console=tty1 $GRUB_DEBUG
  initrd /initrd-current
}

menuentry "k3OS Previous" {
  search.fs_label K3OS_BOOT root
  set root=(\$root)
  linux /vmlinuz-previous printk.devkmsg=on console=tty1 $GRUB_DEBUG
  initrd /initrd-previous
}

menuentry "k3OS Rescue Shell" {
  search.fs_label K3OS_BOOT root
  set root=(\$root)
  linux /vmlinuz-current printk.devkmsg=on rescue console=tty1
  initrd /initrd-current
}
EOF

    if [ -z "${K3OS_INSTALL_TTY}" ]; then
        TTY=$(tty | sed 's!/dev/!!')
    else
        TTY=$K3OS_INSTALL_TTY
    fi
    if [ -e "/dev/$TTY" ] && [ "$TTY" != tty1 ] && [ -n "$TTY" ]; then
        sed -i "s!console=tty1!console=tty1 console=${TTY}!g" ${TARGET}/boot/grub2/grub.cfg
    fi

    if [ "$K3OS_INSTALL_NO_FORMAT" = "true" ]; then
        return 0
    fi

    if [ "$K3OS_INSTALL_FORCE_EFI" = "true" ]; then
        GRUB_TARGET="--target=x86_64-efi"
    fi

    # This is a nasty hack. If I don't do with grub2-install complain that it
    # can determine the root device (which I don't know why it needs to know)
    ln -s ${BOOT} rootfs

    grub2-install ${GRUB_TARGET} --boot-directory=${TARGET}/boot ${DEVICE}
}

get_iso()
{
    ISO_DEVICE=$(blkid -L K3OS || true)
    if [ -z "${ISO_DEVICE}" ]; then
        for i in $(lsblk -o NAME,TYPE -n | grep -w disk | awk '{print $1}'); do
            mkdir -p ${DISTRO}
            if mount -t iso9660 -o ro /dev/$i ${DISTRO}; then
                ISO_DEVICE="/dev/$i"
                umount ${DISTRO}
                break
            fi
        done
    fi

    if [ -z "${ISO_DEVICE}" ] && [ -n "$K3OS_INSTALL_ISO_URL" ]; then
        TEMP_FILE=$(mktemp -d ${TARGET} k3os.XXXXXXXX.iso)
        get_url ${K3OS_INSTALL_ISO_URL} ${TEMP_FILE}
        ISO_DEVICE=$(losetup --show -f $TEMP_FILE)
        rm -f $TEMP_FILE
    fi

    if [ -z "${ISO_DEVICE}" ]; then
        echo "#### There is no k3os ISO device"
        return 1
    fi

    mkdir -p $DISTRO
    mount -t iso9660 -o ro $ISO_DEVICE $DISTRO
}

setup_style()
{
    PARTTABLE=gpt
    if [ "$K3OS_INSTALL_FORCE_EFI" = "true" ] || [ -e /sys/firmware/efi ]; then
        BOOTFLAG=esp
        if [ ! -e /sys/firmware/efi ]; then
            echo WARNING: installing EFI on to a system that does not support EFI
        fi
    else
        PARTTABLE=msdos
        BOOTFLAG=boot
    fi
}

validate_progs()
{
    for i in $PROGS; do
        if [ ! -x "$(which $i)" ]; then
            MISSING="${MISSING} $i"
        fi
    done

    if [ -n "${MISSING}" ]; then
        echo "The following required programs are missing for installation: ${MISSING}"
        exit 1
    fi
}

validate_device()
{
    DEVICE=$K3OS_INSTALL_DEVICE
    if [ ! -b ${DEVICE} ]; then
        echo "You should use an available device. Device ${DEVICE} does not exist."
        exit 1
    fi
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --no-format)
            K3OS_INSTALL_NO_FORMAT=true
            ;;
        --force-efi)
            K3OS_INSTALL_FORCE_EFI=true
            ;;
        --debug)
            set -x
            K3OS_INSTALL_DEBUG=true
            ;;
        --config)
            shift 1
            K3OS_INSTALL_CONFIG_URL=$1
            ;;
        --tty)
            shift 1
            K3OS_INSTALL_TTY=$1
            ;;
        -h)
            usage
            ;;
        --help)
            usage
            ;;
        *)
            if [ "$#" -gt 2 ]; then
                usage
            fi
            INTERACTIVE=true
            K3OS_INSTALL_DEVICE=$1
            K3OS_INSTALL_ISO_URL=$2
            break
            ;;
    esac
    shift 1
done

if [ -e /etc/environment ]; then
    source /etc/environment
fi

if [ -e /etc/os-release ]; then
    source /etc/os-release

    if [ -z "$K3OS_INSTALL_ISO_URL" ]; then
        K3OS_INSTALL_ISO_URL=${ISO_URL}
    fi
fi

if [ -z "$K3OS_INSTALL_DEVICE" ]; then
    usage
fi

validate_progs
validate_device

trap cleanup exit

setup_style
do_format
do_mount
get_iso
do_copy
install_grub

if [ -n "$INTERACTIVE" ]; then
    exit 0
fi

echo " * Rebooting system in 5 seconds (CTRL+C to cancel)"
sleep 5
reboot -f
