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
# 0. 工具链可用性检查
# ==========================================
REQUIRED_TOOLS=("i2ctransfer" "zip" "top" "iostat" "journalctl" "awk" "sed")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "[-] 警告: 发现缺失的必要工具: ${MISSING_TOOLS[*]}"
    if [ "$IGNORE_TOOLS" = true ]; then
        echo "[!] 参数 --ignore 已启用，跳过工具检查，继续执行（部分指令可能失效）..."
    else
        echo "[-] 请先安装缺失的工具。例如: sudo apt-get update && sudo apt-get install i2c-tools zip sysstat"
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
    # 兜底通过核心数或其他特征探测，这里默认根据模型匹配
    echo "[!] 无法通过设备树准确识别 RK3568/RK3588，默认尝试使用 3568 规则(I2C-5)..."
    CHIP_TYPE="UNKNOWN"
    I2C_BUS="5"
fi

echo "[*] 检测到芯片架构: $CHIP_TYPE (设备树: $MODEL_INFO)"

# ==========================================
# 2. 读取并转换 SN 逻辑
# ==========================================
SN_STR=""
echo "[*] 正在从 I2C-$I2C_BUS 读取硬件 SN..."

# 执行 i2ctransfer 读取并捕获原始十六进制输出
RAW_HEX=$(i2ctransfer -y -f "$I2C_BUS" w2@0x57 0x10 0x00 r30 2>/dev/null || echo "")

if [ -z "$RAW_HEX" ]; then
    echo "[!] 警告: 无法通过 I2C-$I2C_BUS 0x57 读取 SN，改用默认值 'UNKNOWN_SN'"
    SN_STR="UNKNOWN_SN"
else
    # 模拟前端 JS 的高效转换逻辑：清洗 0x、过滤 0xff、转换为 ASCII
    for hex in $RAW_HEX; do
        clean_hex=$(echo "$hex" | sed 's/^0x//i')
        decimal=$((16#$clean_hex))
        
        # 过滤 0xff (255) 和非打印或无效字符
        if [ "$decimal" -ne 255 ] && [ "$decimal" -gt 31 ] && [ "$decimal" -lt 127 ]; then
            # 将十进制转为 ASCII 字符
            char=$(printf "\\$(printf '%03o' "$decimal")")
            SN_STR="${SN_STR}${char}"
        fi
    done
fi

# 清洗可能导致目录名合规问题的空白字符
SN_STR=$(echo "$SN_STR" | tr -d '[:space:]')
[ -z "$SN_STR" ] && SN_STR="EMPTY_SN"
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
# 🟢 第一层：OS 基础与环境层 (OS & Environment)
# ==========================================
echo "[*] 正在收集：第一层 OS 基础与环境信息..."
{
    echo "=== 1. 内核版本 ==="; uname -a
    echo -e "\n=== 2. 系统发行版 ==="; cat /etc/os-release 2>/dev/null
    echo -e "\n=== 3. 根文件系统构建信息 ==="; cat /etc/buildinfo 2>/dev/null
    echo -e "\n=== 4. 原始 I2C 硬件 SN 输出 ==="; echo "$RAW_HEX"
    echo -e "\n=== 5. 磁盘空间 ==="; df -h
    echo -e "\n=== 6. 分区挂载状态 ==="; mount
    echo -e "\n=== 7. Machine ID ==="; cat /etc/machine-id 2>/dev/null
    echo -e "\n=== 8. Dri Summary ==="; cat /sys/kernel/debug/dri/0/summary 2>/dev/null
} > "$LOG_DIR/layer1_os_environment.txt"

# ==========================================
# 🟡 第二层：Rockchip 独有硬件层
# ==========================================
echo "[*] 正在收集：第二层 瑞芯微硬件性能指标..."
{
    echo "=== 1. CPU 各核实时频率 ==="
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        if [ -f "$cpu" ]; then echo "$cpu: $(cat "$cpu")"; fi
    done
    
    echo -e "\n=== 2. 各热敏点温度 (thermal_zone) ==="
    for zone in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$zone" ]; then echo "$zone: $(cat "$zone")"; fi
    done

    echo -e "\n=== 3. GPU 频率 ==="
    cat /sys/class/devfreq/*gpu/cur_freq 2>/dev/null || echo "GPU node not found"
    
    echo -e "\n=== 4. DDR 频率 ==="
    cat /sys/class/devfreq/dmc/cur_freq 2>/dev/null || echo "DDR node not found"
    
    echo -e "\n=== 5. NPU 负载 ==="
    if [ -d "/sys/kernel/debug/rknpu" ]; then
        cat /sys/kernel/debug/rknpu/load 2>/dev/null
    else
        echo "NPU debugfs node closed."
    fi
} > "$LOG_DIR/layer2_rk_hardware.txt"

# ==========================================
# 🟠 第三层：内核与底层总线层 (Kernel & Bus)
# ==========================================
echo "[*] 正在收集：第三层 内核与底层总线日志..."
dmesg -T > "$LOG_DIR/layer3_dmesg.log"
{
    echo "=== 1. PCIe 设备列表 ==="; lspci 2>/dev/null || echo "lspci failed"
    echo -e "\n=== 2. USB 设备列表 ==="; lsusb 2>/dev/null || echo "lsusb failed"
    echo -e "\n=== 3. 系统中断分配及触发频率 ==="; cat /proc/interrupts
} > "$LOG_DIR/layer3_bus_interrupts.txt"

# ==========================================
# 🔵 第四层：系统资源与网络层 (Resources & Network)
# ==========================================
echo "[*] 正在收集：第四层 系统资源与IO网络堆栈..."
{
    echo "=== 1. 整体内存 free ==="; free -m
    echo -e "\n=== 2. 详细内存 meminfo ==="; cat /proc/meminfo
    echo -e "\n=== 3. CMA 连续内存分配 ==="; cat /proc/meminfo | grep -i cma
    echo -e "\n=== 4. 全局打开文件句柄总数 ==="; cat /proc/sys/fs/file-nr
    echo -e "\n=== 5. 网络接口与 IP ==="; ip a
    echo -e "\n=== 6. 路由表 ==="; ip route
    echo -e "\n=== 7. 网络连接状态与端口占用 ==="
    if command -v ss &> /dev/null; then ss -antp; else netstat -anp; fi
} > "$LOG_DIR/layer4_resources_network.txt"

# 抓取进程快照快照 (兼容标准 Linux 与 BusyBox)
if top -h 2>&1 | grep -q "BusyBox"; then
    top -n 1 > "$LOG_DIR/layer4_process_snapshot.txt"
else
    top -b -n 1 > "$LOG_DIR/layer4_process_snapshot.txt"
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
    echo "[✓] 最终调试结果件路径: $ZIP_TARGET"
    
    # 彻底安全地删除未打包的日志原始临时目录
    rm -rf "$LOG_DIR"
    echo "[✓] 原始非压缩临时目录已被安全清理。"
else
    echo "[-] 错误: 打包压缩失败，请手动检查 $LOG_DIR"
    exit 1
fi

exit 0
