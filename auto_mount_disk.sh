#!/usr/bin/env bash
# 自动挂载磁盘并设置开机启动（按磁盘级别选择 /dev/sdX）
# 只允许选择“未被系统使用”的磁盘：没有已挂载/有文件系统的分区

set -u  # 不用 -e，自己控制错误处理

#---------------------------
# 函数：检查是否为 root
#---------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "请使用 root 权限运行本脚本，例如：sudo $0"
        exit 1
    fi
}

#---------------------------
# 函数：列出磁盘 & 选择磁盘 (/dev/sdX)
# 规则：
#   - 只看 TYPE=disk 的设备
#   - 如果该磁盘下面有任何分区已经挂载或已有文件系统，则视为“已被占用”，不可选
#   - 典型场景：/dev/sdb 是系统盘（有 /、/boot 等挂载），就会被标记为不可选
#   - /dev/sda 为新盘，无分区或无文件系统，则可以选择
#---------------------------
select_disk() {
    echo "=== 当前磁盘列表（物理磁盘级别） ==="
    echo

    # 只列出 NAME/SIZE/TYPE，-d 表示只显示磁盘本身，不包含分区
    mapfile -t DISK_LINES < <(lsblk -o NAME,SIZE,TYPE -dn)

    AVAILABLE_DISKS=()
    local index=1

    for line in "${DISK_LINES[@]}"; do
        # 例如：sda 465.8G disk
        set -- $line
        local name="$1"
        local size="$2"
        local type="$3"

        [[ "$type" != "disk" ]] && continue

        local dev="/dev/$name"

        # 检查该磁盘是否“已被使用”：
        # 条件：任一子分区存在 FSTYPE 或 MOUNTPOINT（说明上面要么有文件系统，要么已经挂载）
        local used=""
        # lsblk 该磁盘及其子分区；tail -n +2 跳过磁盘本身，只看子分区
        while read -r cname cfstype cmount ctype; do
            # 只看分区/加密卷/LVM 等
            if [[ "$ctype" = "part" || "$ctype" = "crypt" || "$ctype" = "lvm" ]]; then
                if [[ -n "$cmount" || -n "$cfstype" ]]; then
                    used=1
                    break
                fi
            fi
        done < <(lsblk -o NAME,FSTYPE,MOUNTPOINT,TYPE -nr "$dev" | tail -n +2)

        if [[ -n "$used" ]]; then
            printf "  [×] %s  大小: %s  （已有系统使用或分区已挂载，禁止选择）\n" "$dev" "$size"
        else
            printf "  [%d] %s  大小: %s  （可选）\n" "$index" "$dev" "$size"
            AVAILABLE_DISKS+=("$dev")
            ((index++))
        fi
    done

    if [[ "${#AVAILABLE_DISKS[@]}" -eq 0 ]]; then
        echo
        echo "没有找到可供挂载的空闲磁盘。"
        echo "说明所有磁盘都已经有分区并被使用，或者 lsblk 结果异常。"
        exit 1
    fi

    echo
    echo "请选择要挂载的磁盘编号："
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo "输入不是数字，退出。"
        exit 1
    fi

    if (( choice < 1 || choice > ${#AVAILABLE_DISKS[@]} )); then
        echo "编号不在可选范围内，退出。"
        exit 1
    fi

    SELECTED_DEV="${AVAILABLE_DISKS[choice-1]}"

    echo
    echo "你选择的磁盘是：$SELECTED_DEV"
}

#---------------------------
# 函数：输入挂载目录
#---------------------------
ask_mount_point() {
    echo
    echo "请输入要挂载到的目录（例如 /mnt/data 或 /data）："
    read -r MOUNT_POINT

    if [[ -z "$MOUNT_POINT" ]]; then
        echo "挂载目录不能为空，退出。"
        exit 1
    fi

    if [[ ! -e "$MOUNT_POINT" ]]; then
        echo "目录 $MOUNT_POINT 不存在，是否创建？(y/n)"
        read -r ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            mkdir -p "$MOUNT_POINT" || { echo "创建目录失败"; exit 1; }
        else
            echo "未创建目录，退出。"
            exit 1
        fi
    fi
}

#---------------------------
# 函数：检测已有文件系统
#   - 如果整块磁盘已有文件系统（少见，但可能是无分区直接 mkfs /dev/sdX），直接用
#   - 如果没有文件系统，也没有被分区使用，则让用户选择一种文件系统并格式化整块磁盘
#---------------------------
prepare_filesystem() {
    echo
    echo "检测 $SELECTED_DEV 的文件系统类型..."

    # 1. 先看磁盘自身是否已有文件系统
    EXISTING_FS="$(blkid -o value -s TYPE "$SELECTED_DEV" 2>/dev/null || true)"

    if [[ -n "$EXISTING_FS" ]]; then
        echo "检测到 $SELECTED_DEV 已有文件系统：$EXISTING_FS"
        echo "根据你的要求，不会进行格式化，将直接使用该文件系统挂载。"
        FINAL_FS="$EXISTING_FS"
        return
    fi

    # 2. 再看有没有子分区（理论上 select_disk 已经排除“有分区在用”的磁盘）
    HAS_PARTS="$(lsblk -nr -o TYPE "$SELECTED_DEV" | grep -c 'part' || true)"
    if [[ "$HAS_PARTS" -gt 0 ]]; then
        echo "警告：$SELECTED_DEV 下面存在分区，但未检测到磁盘本身的文件系统。"
        echo "为了避免误操作，脚本不自动处理这种情况，请手动分区/格式化。"
        exit 1
    fi

    echo "未检测到现有文件系统，且该磁盘下面没有分区，视为一块新盘。"
    echo "你需要为该磁盘创建文件系统（这会清空整块磁盘的所有数据！）"
    echo

    echo "请选择要格式化的文件系统类型："
    echo "  [1] ext4   （Linux 默认常用）"
    echo "  [2] xfs    （高性能，常用于服务器）"
    echo "  [3] btrfs  （支持快照/子卷等高级功能）"
    echo "  [4] f2fs   （闪存设备优化，例如 SSD/eMMC）"
    echo "  [5] vfat   （兼容性好，常用于 U 盘/EFI）"
    echo "  [6] ntfs   （与 Windows 兼容，需要 ntfs-3g）"
    echo "  [0] 取消并退出"
    read -r fs_choice

    case "$fs_choice" in
        1) FINAL_FS="ext4";  MKFS_CMD="mkfs.ext4" ;;
        2) FINAL_FS="xfs";   MKFS_CMD="mkfs.xfs" ;;
        3) FINAL_FS="btrfs"; MKFS_CMD="mkfs.btrfs" ;;
        4) FINAL_FS="f2fs";  MKFS_CMD="mkfs.f2fs" ;;
        5) FINAL_FS="vfat";  MKFS_CMD="mkfs.vfat" ;;
        6) FINAL_FS="ntfs";  MKFS_CMD="mkfs.ntfs" ;; # 需要 ntfs-3g
        0) echo "用户取消，退出。"; exit 0 ;;
        *) echo "不支持的选项，退出。"; exit 1 ;;
    esac

    echo
    echo "警告：即将对整块磁盘 $SELECTED_DEV 执行格式化：$MKFS_CMD"
    echo "这将清空该磁盘上的所有数据，确认继续？(yes/no)"
    read -r confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "未输入 'yes'，取消操作。"
        exit 1
    fi

    echo "开始格式化 $SELECTED_DEV 为 $FINAL_FS ..."
    $MKFS_CMD "$SELECTED_DEV" || { echo "格式化失败！"; exit 1; }
    echo "格式化完成。"
}

#---------------------------
# 函数：测试挂载
#---------------------------
test_mount() {
    echo
    echo "开始测试挂载 $SELECTED_DEV 到 $MOUNT_POINT，文件系统：$FINAL_FS"

    # 如果挂载点已被占用，先尝试卸载
    if mount | grep -q "on $MOUNT_POINT "; then
        echo "检测到 $MOUNT_POINT 已挂载，尝试先卸载..."
        umount "$MOUNT_POINT" || { echo "卸载失败，请手动检查。"; exit 1; }
    fi

    if mount | grep -q "^$SELECTED_DEV "; then
        echo "检测到 $SELECTED_DEV 已被挂载到其他位置，请先手动卸载后再运行此脚本。"
        exit 1
    fi

    mount -t "$FINAL_FS" "$SELECTED_DEV" "$MOUNT_POINT"
    if [[ $? -ne 0 ]]; then
        echo "挂载失败，请检查文件系统类型、目录以及内核模块是否支持。"
        exit 1
    fi

    echo "挂载成功！当前挂载情况："
    df -h "$MOUNT_POINT"
}

#---------------------------
# 函数：写入 /etc/fstab 实现开机自动挂载
# 使用 UUID，避免设备名变化问题
#---------------------------
setup_fstab() {
    echo
    echo "开始配置 /etc/fstab，实现开机自动挂载..."

    UUID_VAL="$(blkid -o value -s UUID "$SELECTED_DEV" 2>/dev/null || true)"
    if [[ -z "$UUID_VAL" ]]; then
        echo "未能获取 $SELECTED_DEV 的 UUID，无法安全地写入 /etc/fstab。"
        echo "你可以手动查看 blkid 输出后自行编辑 /etc/fstab。"
        return
    fi

    # 根据文件系统类型设置 fsck 顺序
    local dump=0
    local pass=0
    case "$FINAL_FS" in
        ext2|ext3|ext4)
            pass=2 ;;
        *)
            pass=0 ;;
    esac

    local fstab_line="UUID=$UUID_VAL  $MOUNT_POINT  $FINAL_FS  defaults  $dump  $pass"

    # 检查是否已存在相同 UUID 或挂载点条目
    if grep -q "$UUID_VAL" /etc/fstab; then
        echo "/etc/fstab 中已存在该磁盘的 UUID 条目："
        grep "$UUID_VAL" /etc/fstab
        echo "出于安全考虑，不自动重复写入。请自行确认和修改 /etc/fstab。"
    elif grep -qE "[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab; then
        echo "/etc/fstab 中已存在挂载点 $MOUNT_POINT 的条目："
        grep -E "[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab
        echo "出于安全考虑，不自动重复写入。请自行确认和修改 /etc/fstab。"
    else
        echo "$fstab_line" >> /etc/fstab
        echo "已写入 /etc/fstab："
        echo "  $fstab_line"
    fi

    echo
    echo "测试 /etc/fstab 配置：运行 mount -a ..."
    mount -a
    if [[ $? -ne 0 ]]; then
        echo "mount -a 出现错误，请检查 /etc/fstab 配置。"
        exit 1
    fi
    echo "mount -a 执行成功，开机自动挂载配置正常。"
}

#---------------------------
# 主流程
#---------------------------
main() {
    check_root
    select_disk
    ask_mount_point
    prepare_filesystem
    test_mount
    setup_fstab

    echo
    echo "=== 全部完成 ==="
    echo "磁盘：$SELECTED_DEV"
    echo "挂载点：$MOUNT_POINT"
    echo "文件系统：$FINAL_FS"
    echo "已经挂载并配置为开机自动挂载。"
}

main "$@"
