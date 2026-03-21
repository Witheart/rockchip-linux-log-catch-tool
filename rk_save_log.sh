#!/bin/bash

set -e

# =============================
# 强制 sudo 运行
# =============================
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] 请使用 sudo 运行本脚本"
    exit 1
fi

# =============================
# 脚本目录 & 日志目录
# =============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="${SCRIPT_DIR}/log-${TIMESTAMP}"

mkdir -p "$LOG_DIR"
cd "$LOG_DIR"

echo "[INFO] 日志保存目录：$LOG_DIR"
echo

# =============================
# 基础信息采集
# =============================
echo "[INFO] 收集系统基础信息..."

if [ -f /etc/buildinfo ]; then
    cp /etc/buildinfo buildinfo.log
fi

cat /etc/machine-id > machine-id.log

if [ -f /sys/kernel/debug/dri/0/summary ]; then
    cat /sys/kernel/debug/dri/0/summary > dri.log
fi

journalctl --list-boots > list-boots.log

# =============================
# 获取 SN 与 运行 Stress 测试
# =============================
echo "[INFO] 正在获取 SN 信息..."
i2ctransfer -y -f 6 w2@0x57 0x10 0x00 r30 > SN 2>&1

echo "[INFO] 正在收集日志..."
stressapptest -s 20 -i 4 -C 4 -W --stop_on_errors -M 13000 > test 2>&1

# =============================
# dmesg（当前启动）
# =============================
echo "[INFO] 保存当前启动的 dmesg..."
dmesg -T > dmesg-current.log

# =============================
# 显示启动列表
# =============================
echo
echo "========== 启动记录列表 =========="
cat list-boots.log
echo "=================================="
echo

# 提取 boot index
BOOT_INDEXES=($(awk '{print $1}' list-boots.log))

# =============================
# 菜单
# =============================
echo "请选择操作："
echo "a) 保存所有启动日志"
echo "b) 选择范围保存（如 -3 到 0）"
echo "c) 选择特定启动保存（如 -3 -1 0）"
echo
read -rp "请输入选项 [a/b/c]: " choice

# =============================
# 功能函数
# =============================
save_one_boot() {
    local idx="$1"
    local outfile="boot_${idx}.log"
    echo "[INFO] 保存 boot $idx -> $outfile"
    journalctl -b "$idx" > "$outfile"
}

# =============================
# 处理用户选择
# =============================
case "$choice" in
    a)
        echo "[INFO] 保存所有启动日志..."
        for idx in "${BOOT_INDEXES[@]}"; do
            save_one_boot "$idx"
        done
        ;;
    b)
        read -rp "请输入起始 boot index（如 -3）: " start
        read -rp "请输入结束 boot index（如 0）: " end

        echo "[INFO] 保存范围：$start 到 $end"

        for idx in "${BOOT_INDEXES[@]}"; do
            if (( idx >= start && idx <= end )); then
                save_one_boot "$idx"
            fi
        done
        ;;
    c)
        read -rp "请输入要保存的 boot index（空格分隔，如 -3 -1 0）: " -a selected

        for idx in "${selected[@]}"; do
            save_one_boot "$idx"
        done
        ;;
    *)
        echo "[ERROR] 无效选项"
        exit 1
        ;;
esac

# =============================
# 收尾：打包与加密
# =============================
echo
echo "[INFO] 正在打包日志..."

# 返回上级目录进行打包
cd "$SCRIPT_DIR"

ZIP_NAME="log-${TIMESTAMP}.zip"
DIR_NAME="log-${TIMESTAMP}"

# 检查 zip 命令是否存在
if command -v zip >/dev/null 2>&1; then
    # -r 递归, -P 密码, -q 安静模式
    zip -r -q -P "Pi3.14159" "$ZIP_NAME" "$DIR_NAME"
    
    if [ $? -eq 0 ]; then
        echo "[INFO] 打包成功：$ZIP_NAME"
        rm -rf "$DIR_NAME"
    else
        echo "[ERROR] 打包失败。"
    fi
else
    echo "[ERROR] 未找到 zip 命令，无法打包。"
fi

echo
echo "[DONE] 操作完成："
ls -lh "$ZIP_NAME" 2>/dev/null || ls -ld "$DIR_NAME"

