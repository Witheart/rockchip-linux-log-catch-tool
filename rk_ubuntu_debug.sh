#!/bin/bash
# ==============================================================================
# 脚本名称: rk_ubuntu_debug.sh
# 描述: Ubuntu debug 系统信息及日志捕捉脚本 (针对 RK3568/RK3588 系列)
# 作者: 吴思含（Witheart）
# 更新时间: 20260521
# ==============================================================================

# 严格模式：遇到未定义变量报错
set -u

# 初始化默认参数
IGNORE_TOOLS=false
JOURNAL_BOOTS=10
ZIP_PASSWORD="Pi3.14159"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--ignore)
            IGNORE_TOOLS=true
            shift
            ;;
        -j)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                JOURNAL_BOOTS=$2
                shift 2
            else
                echo "[-] 错误: -j 参数后需要指定数字"
                exit 1
            fi
            ;;
        *)
            echo "[-] 未知参数: $1"
            echo "使用方法: $0 [-i|--ignore] [-j 抓取开机日志数量]"
            exit 1
            ;;
    esac
done

# ==========================================
# 0. 工具链可用性检查 (已加入 xrandr)
# ==========================================
REQUIRED_TOOLS=("i2ctransfer" "zip" "top" "iostat" "journalctl" "awk" "sed" "grep" "xrandr")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "[-] 警告: 发现缺失的必要工具: ${MISSING_TOOLS[*]}"
    if [ "$IGNORE_TOOLS" = true ]; then
        echo "[!] 参数 --ignore 已启用，跳过工具检查，继续执行..."
    else
        echo "[-] 请先安装缺失的工具。例如: sudo apt-get update && sudo apt-get install i2c-tools zip sysstat x11-xserver-utils"
        echo "[-] 或者附加 '-i' 或 '--ignore' 参数运行以忽略此错误。"
        exit 1
    fi
fi

# ==========================================
# 1. 判断芯片型号 (RK3568 还是 RK3588)
# ==========================================
MODEL_INFO=""
if [ -f /sys/firmware/devicetree/base/model ]; then
    MODEL_INFO=$(cat /sys/firmware/devicetree/base/model 2>/dev/null)
fi

CHIP_TYPE=""
I2C_BUS=""

if echo "$MODEL_INFO" | grep -iq "rk3568"; then
    CHIP_TYPE="RK3568"
    I2C_BUS="5"
elif echo "$MODEL_INFO" | grep -iq "rk3588"; then
    CHIP_TYPE="RK3588"
    I2C_BUS="6"
else
    echo "[!] 无法通过设备树准确识别 RK3568/RK3588，默认尝试使用 3568 规则(I2C-5)..."
    CHIP_TYPE="UNKNOWN"
    I2C_BUS="5"
fi

echo "[*] 检测到芯片架构: $CHIP_TYPE (设备树: $MODEL_INFO)"

# ==========================================
# 2. 读取并转换 SN 逻辑 (支持 0x00 截断)
# ==========================================
SN_STR=""
echo "[*] 正在从 I2C-$I2C_BUS 读取硬件 SN..."

# 执行 i2ctransfer 读取并捕获原始十六进制输出
RAW_HEX=$(i2ctransfer -y -f "$I2C_BUS" w2@0x57 0x10 0x00 r30 2>/dev/null || echo "")

if [ -z "$RAW_HEX" ]; then
    echo "[!] 警告: 无法通过 I2C-$I2C_BUS 0x57 读取 SN，改用默认值 'UNKNOWN_SN'"
    SN_STR="UNKNOWN_SN"
else
    # 稳健的字节级循环转换
    for hex in $RAW_HEX; do
        # 确保去掉可能存在的 0x 前缀
        clean_hex=$(echo "$hex" | sed 's/^0x//i')
        
        # 将16进制转换为10进制整数
        if [[ "$clean_hex" =~ ^[0-9a-fA-F]+$ ]]; then
            decimal=$((16#$clean_hex))
            
            # 核心修正：如果检测到 0x00 (\0 字符串结束符)，立刻终止后续解析
            if [ "$decimal" -eq 0 ]; then
                break
            fi
            
            # 过滤 0xff (255) 以及不可见控制字符 (ASCII 32-126 是合法可见字符)
            if [ "$decimal" -ne 255 ] && [ "$decimal" -ge 32 ] && [ "$decimal" -le 126 ]; then
                # 利用 printf 将十进制安全转为对应字符
                char=$(printf "\\$(printf '%03o' "$decimal")")
                SN_STR="${SN_STR}${char}"
            fi
        fi
    done
fi

# 移除首尾可能残余的空白，并做最终检查
SN_STR=$(echo "$SN_STR" | tr -d '[:space:]')
if [ -z "$SN_STR" ] || [ "$SN_STR" = "EMPTY_SN" ]; then
    SN_STR="PARSE_ERR_SN"
fi
echo "[*] 解析后的物理 SN: $SN_STR"

# ==========================================
# 3. 创建带时间戳的统一日志目录
# ==========================================
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DIR_NAME="log-${SN_STR}-${TIMESTAMP}"
LOG_DIR="/tmp/${DIR_NAME}"

mkdir -p "$LOG_DIR"
echo "[*] 正在收集调试信息至临时目录: $LOG_DIR"

# ==========================================
# 🟢 第一层：OS 基础与环境层 (OS & Environment) -> 每份日志单独保存
# ==========================================
echo "[*] 正在收集：第一层 OS 基础与环境信息..."
uname -a > "$LOG_DIR/layer1_uname.txt" 2>&1
cat /etc/os-release > "$LOG_DIR/layer1_os_release.txt" 2>&1
cat /etc/buildinfo > "$LOG_DIR/layer1_buildinfo.txt" 2>&1
echo "$RAW_HEX" > "$LOG_DIR/layer1_raw_sn_hex.txt" 2>&1
echo "$SN_STR" > "$LOG_DIR/layer1_parsed_sn_ascii.txt" 2>&1
df -h > "$LOG_DIR/layer1_disk_usage.txt" 2>&1
mount > "$LOG_DIR/layer1_mount_status.txt" 2>&1
cat /etc/machine-id > "$LOG_DIR/layer1_machine_id.txt" 2>&1
cat /sys/kernel/debug/dri/0/summary > "$LOG_DIR/layer1_dri_summary.txt" 2>&1

# 抓取 X11/Wayland 屏幕显示架构状态 (如在无图形界面下运行，会捕获错误信息作为参考)
xrandr --verbose > "$LOG_DIR/layer1_xrandr_display.txt" 2>&1

# ==========================================
# 🟡 第二层：Rockchip 独有硬件层 -> 每份日志单独保存
# ==========================================
echo "[*] 正在收集：第二层 瑞芯微硬件性能指标..."

# CPU 各核频率单独保存
> "$LOG_DIR/layer2_cpu_freq.txt"
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    if [ -f "$cpu" ]; then echo "$cpu: $(cat "$cpu")" >> "$LOG_DIR/layer2_cpu_freq.txt"; fi
done

# 温度单独保存
> "$LOG_DIR/layer2_thermal_zone.txt"
for zone in /sys/class/thermal/thermal_zone*/temp; do
    if [ -f "$zone" ]; then echo "$zone: $(cat "$zone")" >> "$LOG_DIR/layer2_thermal_zone.txt"; fi
done

# GPU频率单独保存
cat /sys/class/devfreq/*gpu/cur_freq > "$LOG_DIR/layer2_gpu_freq.txt" 2>&1

# DDR 频率单独保存 (针对 RK3588 与 RK3568 做策略兼容切换)
if [ -f /sys/class/devfreq/dmc/cur_freq ]; then
    cat /sys/class/devfreq/dmc/cur_freq > "$LOG_DIR/layer2_ddr_freq.txt" 2>&1
else
    # 3568 或者部分特殊固件上尝试使用时钟树抓取 DDR
    if [ -f /sys/kernel/debug/clk/clk_summary ]; then
        cat /sys/kernel/debug/clk/clk_summary | grep -i ddr > "$LOG_DIR/layer2_ddr_freq.txt" 2>&1
    else
        echo "DDR node and clk_summary not found" > "$LOG_DIR/layer2_ddr_freq.txt"
    fi
fi

# NPU 负载单独保存
if [ -d "/sys/kernel/debug/rknpu" ]; then
    cat /sys/kernel/debug/rknpu/load > "$LOG_DIR/layer2_rknpu_load.txt" 2>&1
else
    echo "NPU debugfs node closed." > "$LOG_DIR/layer2_rknpu_load.txt"
fi

# ==========================================
# 🟠 第三层：内核与底层总线层 (Kernel & Bus) -> 每份日志单独保存
# ==========================================
echo "[*] 正在收集：第三层 内核与底层总线日志..."
dmesg -T > "$LOG_DIR/layer3_dmesg.log" 2>&1
lspci -v > "$LOG_DIR/layer3_lspci.txt" 2>&1 || lspci > "$LOG_DIR/layer3_lspci.txt" 2>&1
lsusb > "$LOG_DIR/layer3_lsusb.txt" 2>&1
cat /proc/interrupts > "$LOG_DIR/layer3_interrupts.txt" 2>&1

# ==========================================
# 🔵 第四层：系统资源与网络层 (Resources & Network) -> 每份日志单独保存
# ==========================================
echo "[*] 正在收集：第四层 系统资源与IO网络堆栈..."
free -m > "$LOG_DIR/layer4_free_m.txt" 2>&1
cat /proc/meminfo > "$LOG_DIR/layer4_meminfo.txt" 2>&1
cat /proc/meminfo | grep -i cma > "$LOG_DIR/layer4_cma_info.txt" 2>&1
cat /proc/sys/fs/file-nr > "$LOG_DIR/layer4_file_handles.txt" 2>&1
ip a > "$LOG_DIR/layer4_ip_address.txt" 2>&1
ip route > "$LOG_DIR/layer4_ip_route.txt" 2>&1

if command -v ss &> /dev/null; then 
    ss -antp > "$LOG_DIR/layer4_network_connections.txt" 2>&1
else 
    netstat -anp > "$LOG_DIR/layer4_network_connections.txt" 2>&1
fi

# 抓取进程快照快照 (兼容标准 Linux 与 BusyBox)
if top -h 2>&1 | grep -q "BusyBox"; then
    top -n 1 > "$LOG_DIR/layer4_top_processes.txt" 2>&1
else
    top -b -n 1 > "$LOG_DIR/layer4_top_processes.txt" 2>&1
fi

# 抓取 Iostat 扩展指标
iostat -x 1 2 > "$LOG_DIR/layer4_iostat.txt" 2>/dev/null

# ==========================================
# 🔴 第五层：业务与应用层 (Journalctl 深度抓取)
# ==========================================
echo "[*] 正在收集：第五层 Journalctl 级联开机日志..."
JOURNAL_DIR="$LOG_DIR/journalctl"
mkdir -p "$JOURNAL_DIR"

# 导出开机列表以便研发人员核对时间线
journalctl --list-boots > "$JOURNAL_DIR/boot_list.txt" 2>/dev/null

# 自动解析获取实际最大可用 Boots 数量
AVAILABLE_BOOTS=$(journalctl --list-boots 2>/dev/null | wc -l)
echo "[*] 系统当前存储了 $AVAILABLE_BOOTS 个开机周期，计划抓取最大数量: $JOURNAL_BOOTS"

# 确定本次循环最终需要抓取的条数
LOOP_LIMIT=$JOURNAL_BOOTS
if [ "$AVAILABLE_BOOTS" -lt "$JOURNAL_BOOTS" ]; then
    LOOP_LIMIT=$AVAILABLE_BOOTS
fi

# 从最新的一次(0)向前滚，抓取最近的 N 次日志并带有清晰序号标志
for (( i=0; i<LOOP_LIMIT; i++ )); do
    # 计算 journalctl 内对应的 boot 偏移值 (当前为 0，上一次为 -1，依此类推)
    BOOT_OFFSET=$(( -i ))
    
    # 提取开机对应的大致时间戳，用于美化文件名
    BOOT_TIME=$(journalctl --list-boots 2>/dev/null | grep -E "^\s*${BOOT_OFFSET}\s" | awk '{print $3"_"$4}' | tr -d ':/')
    [ -z "$BOOT_TIME" ] && BOOT_TIME="unknown_time"

    echo "    -> 正在抓取启动次序: $BOOT_OFFSET ($BOOT_TIME)"
    journalctl -b "$BOOT_OFFSET" --no-pager > "$JOURNAL_DIR/boot_${BOOT_OFFSET}_${BOOT_TIME}.log" 2>/dev/null
done

# ==========================================
# 6. 加密压缩与彻底清理
# ==========================================
ZIP_TARGET="/tmp/${DIR_NAME}.zip"
echo "[*] 数据采集完毕，开始进行密码加密打包..."

# 进入 /tmp 目录进行压缩，避免将绝对路径打入压缩包
cd /tmp || exit
zip -q -r -P "$ZIP_PASSWORD" "$ZIP_TARGET" "$DIR_NAME"

if [ -f "$ZIP_TARGET" ]; then
    echo "[✓] 压缩包加密完成！密码为: $ZIP_PASSWORD"
    echo "[✓] 最终调试结果文件路径: $ZIP_TARGET"
    
    # 彻底安全地删除未打包的日志原始临时目录
    rm -rf "$LOG_DIR"
    echo "[✓] 原始非压缩临时目录已被安全清理。"
else
    echo "[-] 错误: 打包压缩失败，请手动检查 $LOG_DIR"
    exit 1
fi

exit 0