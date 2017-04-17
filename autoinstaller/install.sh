#!/bin/sh

set -e

# These functions pulled from void's excellent mklive.sh
VAI_info_msg() {
    printf "\033[1m%s\n\033[m" "$@"
}

VAI_print_step() {
    CURRENT_STEP=$((CURRENT_STEP+1))
    VAI_info_msg "[${CURRENT_STEP}/${STEP_COUNT}] $*"
}

# ----------------------- Install Functions ------------------------

VAI_welcome() {
    clear
    printf "=============================================================\n"
    printf "================ Void Linux Auto-Installer ==================\n"
    printf "=============================================================\n"
}

VAI_get_address() {
    # Enable the hook for resolv.conf
    mkdir -p /usr/lib/dhcpcd/dhcpcd-hooks
    ln -sf /usr/libexec/dhcpcd-hooks/20-resolv.conf /usr/lib/dhcpcd/dhcpcd-hooks/

    # Get an IP address
    dhcpcd -w -L --timeout 0
}

VAI_partition_disks() {
    local disk_vars="$(set | grep 'disk_' | awk 'BEGIN {FS="="}; { print $1 };' )";
    local disks="$(echo "$disk_vars" | awk 'BEGIN {FS="_"}; { print $2 };' | sort | uniq)";
    for disk in $disks
    do
        VAI_partition_disk "$disk_vars" "$disk";
    done;
}

VAI_partition_disk() {
    local disk_vars="$1";
    local disk="$2";
    local dev="$(eval "echo \$disk_${disk}_dev")";
    if [ -z "$dev" ]; then
        dev="$default_disk";
        eval "disk_${disk}_dev=\$default_disk";
    fi

    local table="$(eval "echo \$disk_${disk}_table")";
    if [ -z "$table" ]; then
        table="gpt";
    fi;

    local script="label: $table"$'\n'$'\n';
    local partitions="$(echo "$disk_vars" | grep "disk_${disk}_partition" | awk 'BEGIN {FS="_"}; { print $4 };' | sort | uniq)";

    for partition in $partitions
    do
        script="${script}"$'\n'"$(VAI_create_partition_script_line "$disk" "$partition" "$table")";
    done

    VAI_info_msg "Writing following script to $dev"
    echo "$script";

    echo "$script" | sfdisk "$dev";

    for partition in $partitions
    do
        VAI_format_disk_partition "$disk" "$partition";
    done
}

VAI_create_partition_script_line() {
    local disk="$1";
    local partition="$2";
    local table="$3";
    local partition_prefix="disk_${disk}_partition_${partition}";
    local size="$(eval "echo \$${partition_prefix}_size")";
    local type="$(eval "echo \$${partition_prefix}_type")";
    local fs="$(eval "echo \$${partition_prefix}_fs")";
    local line="";

    if [ "$table" = "dos" ]; then
        if [ "$type" = "efi" ]; then
            type="ef";
        elif [ "$type" = "swap" -o "$fs" = "swap" ]; then
            type="82";
        elif [ "$type" = "lvm" -o "$fs" = "lvm" ]; then
            type="8e";
        else
            type="83"
        fi;
    else
        if [ "$type" = "efi" ]; then
            type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
        elif [ "$type" = "swap" ]; then
            type="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F";
        else
            type="0FC63DAF-8483-4772-8E79-3D69D8477DE4";
        fi;
    fi;

    if [ ! -z "$size" ]; then
        line="${line}size=${size},";
    fi

    line="${line}type=${type},";

    echo "${line}";
}

VAI_format_disk_partition() {
    local disk="$1";
    local partition="$2";
    local partition_prefix="disk_${disk}_partition_${partition}";
    local disk_dev="$(eval "echo \$disk_${disk}_dev")";
    local dev="${disk_dev}${partition}";
    local fs="$(eval "echo \$${partition_prefix}_fs")";
    local label="$(eval "echo \$${partition_prefix}_label")";
    local lvm="$(eval "echo \$${partition_prefix}_lvm")";
    local luks="$(eval "echo \$${partition_prefix}_luks")";

    VAI_format_partition "${fs}" "${dev}" "${label}" "${lvm}" "${luks}";
}

VAI_format_partition() {
    local fs="$1";
    local dev="$2";
    local label="$3";
    local lvm="$4";
    local luks="$5";

    VAI_info_msg "Creating a ${fs} partition on ${dev}";

    # ext
    if [ "$fs" = "ext2" -o "$fs" = "ext3" -o "$fs" = "ext4" ]; then
        command="mkfs.${fs} -F"
        if [ ! -z "$label" ]; then
            command="$command -L '$label'";
        fi;
        eval "$command ${dev}";
    fi;

    # xfs
    if [ "$fs" = "xfs" ]; then
        command="mkfs.xfs -f"
        if [ ! -z "$label" ]; then
            command="$command -L '$label'";
        fi;
        eval "$command ${dev}";
    fi

    # fat32
    if [ "$fs" = "fat" -o "$fs" = "fat32" ]; then
        command="mkfs.vfat -F32";
        if [ ! -z "$label" ]; then
            command="$command -n '$label'";
        fi;
        eval "$command ${dev}";
    fi

    # swap
    if [ "$fs" = "swap" ]; then
        mkswap -f "${dev}";
    fi;

    # lvm
    if [ "$fs" = "lvm" ]; then
        has_lvm="1";

        vgcreate -f "${lvm}" "${dev}";

        VAI_lvm_create_pool "${lvm}";
    fi;

    # luks
    if [ "$fs" = "luks" ]; then
        has_luks="1";

        VAI_luks_create_disk "${dev}" "${luks}";
    fi;
}

VAI_luks_create_disk() {
    local dev="$1";
    local luks="$2";
    local pass="$(eval "echo \$luks_${luks}_pass")";

    if [ -z "$pass" ]; then
        cryptsetup luksFormat "${dev}";
        cryptsetup luksOpen "${dev}" "${luks}";
    else
        echo "$pass" | cryptsetup luksFormat -d - "${dev}";
        echo "$pass" | cryptsetup luksOpen -d - "${dev}" "${luks}";
        pass="";
    fi

    VAI_luks_format_partition "${luks}";
}

VAI_lvm_create_pool() {
    local pool="$1";
    local pool_vars="$(set | grep "lvm_${pool}" | awk 'BEGIN {FS="="}; { print $1 };' )";
    local pool_volumes="$(echo "$pool_vars" | awk 'BEGIN {FS="_"}; { print $4 };' | awk '!x[$0]++')";

    for volume in $pool_volumes
    do
        VAI_lvm_create_volume "$pool" "$volume";
    done
}

VAI_lvm_create_volume() {
    local pool="$1";
    local volume="$2";
    local size="$(eval "echo \$lvm_${pool}_volume_${volume}_size")";

    lvcreate --name "${volume}" -L "${size}" "${pool}";

    VAI_lvm_format_partition "${pool}" "${volume}";
}

VAI_luks_format_partition() {
    local name="$1";
    local dev="/dev/mapper/${name}";
    local fs="$(eval "echo \$luks_${name}_fs")";
    local label="$(eval "echo \$luks_${name}_label")";
    local luks="$(eval "echo \$luks_${name}_luks")";
    local lvm="$(eval "echo \$luks_${name}_lvm")";

    VAI_format_partition "$fs" "$dev" "$label" "$lvm" "$luks";
}

VAI_lvm_format_partition() {
    local pool="$1";
    local volume="$2";
    local dev="/dev/mapper/${pool}-${volume}";
    local fs="$(eval "echo \$lvm_${pool}_volume_${volume}_fs")";
    local label="$(eval "echo \$lvm_${pool}_volume_${volume}_label")";
    local luks="$(eval "echo \$lvm_${pool}_volume_${volume}_luks")";
    local lvm="$(eval "echo \$lvm_${pool}_volume_${volume}_lvm")";

    VAI_format_partition "$fs" "$dev" "$label" "$luks" "$lvm";
}

VAI_get_mounts() {
    local disk_vars="$(set | grep 'disk_' | awk 'BEGIN {FS="="}; { print $1 };' )";
    local mounts="$(set | grep 'disk_\|lvm_\|luks_' | awk 'BEGIN {FS="="}; { print $1 };' |  grep '_mount$' )";
    local mount_dev="";
    local path="";
    local dev="";
    local disk="";
    local partition="";
    local mount_options="";

    for mount in $mounts
    do
        type="$(echo "$mount" | awk 'BEGIN {FS="_"}; { print $1 };')";
        case "$type" in
            disk)
                path="$(eval "echo \$$mount")";
                disk="$(echo $mount | awk 'BEGIN {FS="_"}; { print $2 };')";
                partition="$(echo $mount | awk 'BEGIN {FS="_"}; { print $4 };')";
                fs="$(eval "echo \$disk_${disk}_partition_${partition}_fs")";
                mount_options="$(eval "echo \$disk_${disk}_partition_${partition}_mount_options")";
                dev="$(eval "echo \$disk_${disk}_dev")${partition}";
                mount_dev="${mount_dev}$(echo "$path" | wc -c) $path $dev $fs $mount_options"$'\n';
                ;;
            lvm)
                path="$(eval "echo \$$mount")";
                pool="$(echo $mount | awk 'BEGIN {FS="_"}; { print $2 };')";
                volume="$(echo $mount | awk 'BEGIN {FS="_"}; { print $4 };')";
                fs="$(eval "echo \$lvm_${pool}_volume_${volume}_fs")";\
                mount_options="$(eval "echo \$lvm_${pool}_volume_${volume}_mount_options")";
                dev="/dev/mapper/${pool}-${volume}";
                mount_dev="${mount_dev}$(echo "$path" | wc -c) $path $dev $fs $mount_options"$'\n';
        esac
    done

    echo "$mount_dev" | sort -nk1;
}

VAI_mount_target() {
    local mounts="$(VAI_get_mounts)";

    for dev in $(echo "$mounts" | awk '{print $3}')
    do
        path="$(echo "$mounts" | grep "$dev " | awk '{print $2}')";

        if [ "$path" = "swap" ]; then
            continue;
        fi

        echo "Mounting '$dev' on '$path'";

        mkdir -p "${target}${path}";
        mount "$dev" "${target}${path}";
    done
}

VAI_install_xbps_keys() {
    mkdir -p "${target}/var/db/xbps/keys"
    cp /var/db/xbps/keys/* "${target}/var/db/xbps/keys"
}

VAI_install_base_system() {
    base_pkgs="base-system grub grub-x86_64-efi grub-i386-efi";

    if [ "$has_lvm" = "1" ]; then
        base_pkgs="${base_pkgs} lvm2";
    fi;

    if [ "$has_luks" = "1" ]; then
        base_pkgs="${base_pkgs} cryptsetup";
    fi;

    # Install a base system
    XBPS_ARCH="${XBPS_ARCH}" xbps-install -Sy -R "${xbpsrepository}" -r /mnt $base_pkgs;

    # Install additional packages
    if [  -n "${pkgs}" ] ; then
        XBPS_ARCH="${XBPS_ARCH}" xbps-install -Sy -R "${xbpsrepository}" -r /mnt $pkgs;
    fi
}

VAI_prepare_chroot() {
    # Mount dev, bind, proc, etc into chroot
    mount -t proc proc "${target}/proc"
    mount -t sysfs sys "${target}/sys"
    mount -o rbind /dev "${target}/dev"
}

VAI_configure_sudo() {
    # Give wheel sudo
    echo "%wheel ALL=(ALL) ALL" > "${target}/etc/sudoers.d/wheel"
}

VAI_correct_root_permissions() {
    chroot "${target}" chown root:root /
    chroot "${target}" chmod 755 /
}

VAI_configure_hostname() {
    # Set the hostname
    echo "${hostname}" > "${target}/etc/hostname"
}

VAI_configure_rc_conf() {
    # Set the value of various tokens
    sed -i "s:Europe/Madrid:${timezone}:" "${target}/etc/rc.conf"
    sed -i "s:\"es\":\"${keymap}\":" "${target}/etc/rc.conf"

    # Activate various tokens
    sed -i "s:#HARDWARECLOCK:HARDWARECLOCK:" "${target}/etc/rc.conf"
    sed -i "s:#TIMEZONE:TIMEZONE:" "${target}/etc/rc.conf"
    sed -i "s:#KEYMAP:KEYMAP:" "${target}/etc/rc.conf"
}

VAI_add_user() {
    chroot "${target}" useradd -m -s /bin/bash -U -G wheel,users,audio,video,cdrom,input "${username}"
    if [ -z "${password}" ] ; then
        chroot "${target}" passwd "${username}"
    else
        # For reasons that remain unclear, this does not work in musl
        echo "${username}:${password}" | chpasswd -c SHA512 -R "${target}"
fi
}

VAI_configure_grub() {
    # Set hostonly
    echo "hostonly=yes" > "${target}/etc/dracut.conf.d/hostonly.conf"

    if [ "$has_luks" = "1" -o "$has_lvm" = "1" ]; then
        # add rd.auto=1 to GRUB_CMDLINE_LINUX_DEFAULT
        sed -i 's:GRUB_CMDLINE_LINUX_DEFAULT="\([^"]\+\)":GRUB_CMDLINE_LINUX_DEFAULT="\1 rd.auto=1":' "${target}/etc/default/grub";
    fi

    if [ "$has_luks" = "1" ]; then
        echo "GRUB_ENABLE_CRYPTODISK=y" >> "${target}/etc/default/grub";
    fi

    # Choose the newest kernel
    kernel_version="$(chroot "${target}" xbps-query linux | awk -F "[-_]" '/pkgver/ {print $2}')"

    local disk="$(eval "echo \$disk_${boot_disk}_dev")";

    # Install grub
    chroot "${target}" grub-install "${disk}"
    chroot "${target}" xbps-reconfigure -f "linux${kernel_version}"

    # Correct the grub install
    chroot "${target}" update-grub
}

VAI_configure_fstab() {
    local path="";
    local dev="";
    local uuid="";
    local fs="";
    local mounts="$(VAI_get_mounts)";

    for dev in $(echo "$mounts" | awk '{print $3}')
    do
        path="$(echo "$mounts" | grep "$dev " | awk '{print $2}')";
        fs="$(echo "$mounts" | grep "$dev " | awk '{print $4}')";
        options="$(echo "$mounts" | grep "$dev " | awk '{print $5}')";
        pass="2";

        if [ "$path" = "/" ]; then
            pass="1";
        elif [ "$fs" = "swap" ]; then
            pass="0";
        fi

        if [ "$fs" = "fat32" -o "$fs" = "fat" ]; then
            fs="vfat";
        fi

        uuid="$(blkid -s UUID -o value "${dev}")";
        echo "UUID=${uuid} ${path} ${fs} ${options:-defaults} 0 ${pass}" >> "${target}/etc/fstab"
    done
}

VAI_configure_locale() {
    # Set the libc-locale iff glibc
    case "${XBPS_ARCH}" in
        *-musl)
            VAI_info_msg "Glibc locales are not supported on musl"
            ;;
        *)
            sed -i "/${libclocale}/s/#//" "${target}/etc/default/libc-locales"

            chroot "${target}" xbps-reconfigure -f glibc-locales
            ;;
    esac
}

VAI_end_action() {
    case $end_action in
        reboot)
            VAI_info_msg "Rebooting the system"
            sync
            umount -R "${target}"
            reboot -f
            ;;
        shutdown)
            VAI_info_msg "Shutting down the system"
            sync
            umount -R "${target}"
            poweroff -f
            ;;
        script)
            VAI_info_msg "Running user provided script"
            xbps-uhelper fetch "${end_script}>/script"
            chmod +x /script
            target=${target} xbpsrepository=${xbpsrepository} /script
            ;;
        func)
            VAI_info_msg "Running user provided function"
            end_function
            ;;
    esac
}

VAI_configure_autoinstall() {
    # -------------------------- Setup defaults ---------------------------
    default_disk="$(lsblk -ipo NAME,TYPE,MOUNTPOINT | awk '{if ($2=="disk") {disks[$1]=0; last=$1} if ($3=="/") {disks[last]++}} END {for (a in disks) {if(disks[a] == 0){print a; break}}}')"
    hostname="$(ip -4 -o -r a | awk -F'[ ./]' '{x=$7} END {print x}')"
    target="/mnt"
    timezone="America/Chicago"
    keymap="us"
    libclocale="en_US.UTF-8"
    username="voidlinux"
    end_action="shutdown"
    end_script="/bin/true"
    has_lvm="0";
    has_luks="0";

    XBPS_ARCH="$(xbps-uhelper arch)"
    case $XBPS_ARCH in
        *-musl)
            xbpsrepository="https://repo.voidlinux.eu/current/musl"
            ;;
        *)
            xbpsrepository="https://repo.voidlinux.eu/current"
            ;;
    esac

    # --------------- Pull config URL out of kernel cmdline -------------------------
    if getargbool 0 autourl ; then
        xbps-uhelper fetch "$(getarg autourl)>/etc/autoinstall.cfg"

    else
        mv /etc/autoinstall.default /etc/autoinstall.cfg
    fi

    # Read in the resulting config file which we got via some method
    if [ -f /etc/autoinstall.cfg ] ; then
        VAI_info_msg "Reading configuration file"
        . /etc/autoinstall.cfg
    fi

    cat <<_EOF > /etc/lvm/lvm.conf
global {
    locking_type = 1
    use_lvmetad = 0
}
_EOF
}

VAI_main() {
    CURRENT_STEP=0
    STEP_COUNT=16

    VAI_welcome

    VAI_print_step "Bring up the network"
    VAI_get_address

    VAI_print_step "Configuring installer"
    VAI_configure_autoinstall

    VAI_print_step "Configuring disk using recipe defined in config"
    VAI_partition_disks

    VAI_print_step "Mounting the target filesystems"
    VAI_mount_target

    VAI_print_step "Installing XBPS keys"
    VAI_install_xbps_keys

    VAI_print_step "Installing the base system"
    VAI_install_base_system

    VAI_print_step "Granting sudo to default user"
    VAI_configure_sudo

    VAI_print_step "Setting hostname"
    VAI_configure_hostname

    VAI_print_step "Configure rc.conf"
    VAI_configure_rc_conf

    VAI_print_step "Preparing the chroot"
    VAI_prepare_chroot

    VAI_print_step "Fix ownership of /"
    VAI_correct_root_permissions

    VAI_print_step "Adding default user"
    VAI_add_user

    VAI_print_step "Configuring GRUB"
    VAI_configure_grub

    VAI_print_step "Configuring /etc/fstab"
    VAI_configure_fstab

    VAI_print_step "Configuring libc-locales"
    VAI_configure_locale

    VAI_print_step "Performing end-action"
    VAI_end_action
}

# If we are using the autoinstaller, launch it
if getargbool 0 auto  ; then
    VAI_main
fi

# Very important to release this before returning to dracut code
set +e
