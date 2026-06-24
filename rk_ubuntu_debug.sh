#!/bin/bash
# ==============================================================================
# 脚本名称: rk_ubuntu_debug.sh
# 描述: Ubuntu debug 系统信息及日志捕捉脚本 (针对 RK3568/RK3588 系列)
# 作者: 吴思含（Witheart）
# 更新时间: 20260521 (已增加日志交互选择与空日志检测功能)
# ==============================================================================

# 严格模式：遇到未定义变量报错
set -u

# 初始化默认参数
IGNORE_TOOLS=false
JOURNAL_BOOTS=10
J_PROVIDED=false # 用于标记用户是否在命令行传入了 -j 参数
ZIP_PASSWORD="Pi3.14159"
RUN_MODE="sudo"  # 默认 sudo 模式（向后兼容），可选 nosudo

# 帮助菜单函数
show_help() {
    echo "======================================================================"
    echo "  RK3568/3588 Ubuntu 一键调试日志捕捉工具 - 帮助手册"
    echo "======================================================================"
    echo "使用方法:"
    echo "  sudo $0 [参数]"
    echo ""
    echo "有效参数列表:"
    echo "  -h, --help        显示当前帮助说明菜单"
    echo "  -i, --ignore      忽略工具链缺失检查，强制越过报错执行"
    echo "  -j [数字]         指定要抓取的历史开机(boot)日志数量 (默认: 10 次)"
    echo "  -m [模式]         运行模式: sudo(默认) 或 nosudo"
    echo "                    sudo   = 以 root 权限运行全部命令（需 sudo 执行脚本）"
    echo "                    nosudo = 普通用户模式，跳过需要 root 的操作"
    echo "                    （当系统存在 D 状态进程导致 sudo 卡住时使用）"
    echo ""
    echo "使用示例:"
    echo "  示例 1 (标准一键抓取) : sudo $0"
    echo "  示例 2 (抓取最近5次开机): sudo $0 -j 5"
    echo "  示例 3 (无网环境强行运行): sudo $0 -i"
    echo "  示例 4 (普通用户模式): $0 -m nosudo"
    echo "======================================================================"
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--ignore)
            IGNORE_TOOLS=true
            shift
            ;;
        -m)
            if [[ -n "${2:-}" && ( "$2" = "sudo" || "$2" = "nosudo" ) ]]; then
                RUN_MODE=$2
                shift 2
            else
                echo "[-] 错误: -m 参数后需要指定 'sudo' 或 'nosudo'"
                exit 1
            fi
            ;;
        -j)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                JOURNAL_BOOTS=$2
                J_PROVIDED=true
                shift 2
            else
                echo "[-] 错误: -j 参数后需要指定数字"
                exit 1
            fi
            ;;
        *)
            echo "[-] 未知参数: $1"
            echo "提示: 可使用 '$0 -h' 或 '$0 --help' 查看可用参数列表。"
            exit 1
            ;;
    esac
done

# ==========================================
# 权限前置校验 (支持 sudo / nosudo 双模式)
# ==========================================
if [ "$RUN_MODE" = "sudo" ]; then
    if [ "$EUID" -ne 0 ]; then
        echo "========================================================="
        echo "[-] 拒绝执行: sudo 模式下必须具有 root 权限！"
        echo "[-] 核心硬件节点（如I2C、DDR时钟树、内核日志）必须要求 root 权限。"
        echo "[-] 请使用 sudo 重新执行脚本，或使用 '-m nosudo' 以普通用户模式运行。"
        echo "========================================================="
        exit 1
    fi
    echo "[*] 运行模式: sudo (root 权限)"
else
    echo "[!] 运行模式: nosudo (普通用户)"
    echo "[!] 注意: 需要 root 权限的操作（I2C、dmesg、debugfs 等）将被跳过。"
    echo "[!] 若系统存在 D 状态进程卡死问题，此模式可避免 sudo 卡住。"
fi

# ==========================================
# 0. 工具链可用性检查与动态定制安装提示
# ==========================================
REQUIRED_TOOLS=("i2ctransfer" "zip" "top" "iostat" "journalctl" "awk" "sed" "grep" "xrandr")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "[-] 警告: 发现系统缺失以下必要工具: ${MISSING_TOOLS[*]}"
    
    # 建立工具到具体 Ubuntu 软件包的映射树
    declare -A PKG_MAP
    PKG_MAP[i2ctransfer]="i2c-tools"
    PKG_MAP[zip]="zip"
    PKG_MAP[top]="procps"
    PKG_MAP[iostat]="sysstat"
    PKG_MAP[journalctl]="systemd"
    PKG_MAP[awk]="gawk"
    PKG_MAP[sed]="sed"
    PKG_MAP[grep]="grep"
    PKG_MAP[xrandr]="x11-xserver-utils"

    # 聚合真正需要安装的底层 deb 包名（去重）
    NEED_INSTALL_PKGS=""
    for m_tool in "${MISSING_TOOLS[@]}"; do
        pkg_name=${PKG_MAP[$m_tool]}
        if [[ ! "$NEED_INSTALL_PKGS" =~ "$pkg_name" ]]; then
            NEED_INSTALL_PKGS="$NEED_INSTALL_PKGS $pkg_name"
        fi
    done

    if [ "$IGNORE_TOOLS" = true ]; then
        echo "[!] 参数 --ignore 已启用，跳过工具限制强行执行（部分指令可能由于缺失包而无输出）..."
    else
        echo "========================================================="
        echo "[-] 错误: 核心依赖不满足，脚本终止。"
        echo "[-] 请执行以下命令安装缺失的组件，然后重新运行脚本:"
        echo "    sudo apt-get update && sudo apt-get install -y$NEED_INSTALL_PKGS"
        echo "========================================================="
        echo "[-] 提示: 你也可以追加 '-i' 或 '--ignore' 参数直接跳过环境检查。"
        exit 1
    fi
fi

# ==========================================
# 1. 判断芯片型号 (RK3568 还是 RK3588)
# ==========================================
MODEL_INFO=""
if [ -f /sys/firmware/devicetree/base/model ]; then
    MODEL_INFO=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
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

RAW_HEX=$(i2ctransfer -y -f "$I2C_BUS" w2@0x57 0x10 0x00 r30 2>/dev/null || echo "")

if [ -z "$RAW_HEX" ]; then
    echo "[!] 警告: 无法通过 I2C-$I2C_BUS 0x57 读取 SN，改用默认值 'UNKNOWN_SN'"
    SN_STR="UNKNOWN_SN"
else
    for hex in $RAW_HEX; do
        clean_hex=$(echo "$hex" | sed 's/^0x//i')
        if [[ "$clean_hex" =~ ^[0-9a-fA-F]+$ ]]; then
            decimal=$((16#$clean_hex))
            if [ "$decimal" -eq 0 ]; then
                break
            fi
            if [ "$decimal" -ne 255 ] && [ "$decimal" -ge 32 ] && [ "$decimal" -le 126 ]; then
                char=$(printf "\\$(printf '%03o' "$decimal")")
                SN_STR="${SN_STR}${char}"
            fi
        fi
    done
fi

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
# 🟢 第一层：OS 基础与环境层 (OS & Environment)
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
xrandr --verbose > "$LOG_DIR/layer1_xrandr_display.txt" 2>&1

# --- 显示环境检测（显示管理器 / 协议 / 桌面环境）---
echo "[*] 正在收集：显示环境信息（DM / 协议 / DE）..."
{
    echo "===== 显示管理器 (Display Manager) ====="
    # 尝试通过 systemd 查找正在运行的 DM 服务
    for dm in lightdm gdm3 sddm lxdm xdm slim; do
        if systemctl is-active --quiet "$dm" 2>/dev/null; then
            echo "[systemd] 活跃的显示管理器: $dm"
        fi
    done
    # 通过进程列表查漏
    ps -eo comm= 2>/dev/null | grep -iE 'lightdm|gdm|sddm|lxdm|xdm|slim' | sort -u | while read -r p; do
        echo "[ps] 检测到显示管理器进程: $p"
    done

    echo ""
    echo "===== 显示协议 (Display Protocol) ====="
    # XDG_SESSION_TYPE 是 systemd/logind 记录的当前会话类型
    echo "[env] \$XDG_SESSION_TYPE  = ${XDG_SESSION_TYPE:-未设置}"
    # Wayland 特征检测
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "[env] \$WAYLAND_DISPLAY   = $WAYLAND_DISPLAY (Wayland 活跃)"
    else
        echo "[env] \$WAYLAND_DISPLAY   = 未设置"
    fi
    # X11 特征检测
    if [ -n "${DISPLAY:-}" ]; then
        echo "[env] \$DISPLAY           = $DISPLAY (X11 活跃)"
    else
        echo "[env] \$DISPLAY           = 未设置"
    fi
    # loginctl 提供更可靠的会话信息
    if command -v loginctl &>/dev/null; then
        ACTIVE_SESSIONS=$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
        for sid in $ACTIVE_SESSIONS; do
            echo "--- loginctl session $sid ---"
            loginctl show-session "$sid" 2>/dev/null | grep -iE 'Type|Display|Desktop|Remote'
        done
    fi

    echo ""
    echo "===== 桌面环境 (Desktop Environment) ====="
    echo "[env] \$XDG_CURRENT_DESKTOP = ${XDG_CURRENT_DESKTOP:-未设置}"
    echo "[env] \$DESKTOP_SESSION     = ${DESKTOP_SESSION:-未设置}"
    echo "[env] \$GDMSESSION          = ${GDMSESSION:-未设置}"
    echo "[env] \$XDG_SESSION_DESKTOP = ${XDG_SESSION_DESKTOP:-未设置}"
    # 进程检测（gnome/kde/xfce/lxde 等典型 DE 组件）
    ps -eo comm= 2>/dev/null | grep -iE 'gnome-shell|plasmashell|xfdesktop|xfwm4|lxpanel|mate-panel|cinnamon|budgie-wm|sway|hyprland|i3' | sort -u | while read -r p; do
        echo "[ps] 检测到桌面环境组件: $p"
    done

    echo ""
    echo "===== 会话来源说明 (SSH / 本地) ====="
    if [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
        echo "[!] 当前为 SSH 远程会话，上述环境变量可能反映的是 SSH 会话而非本地桌面环境！"
        echo "[!] 建议同时查看 loginctl 输出或直接到设备桌面终端运行本脚本以获取准确信息。"
    else
        echo "[*] 当前非 SSH 会话，环境变量应能反映本地桌面环境。"
    fi
} > "$LOG_DIR/layer1_display_env.txt" 2>&1

# ==========================================
# 🟡 第二层：Rockchip 独有硬件层
# ==========================================
echo "[*] 正在收集：第二层 瑞芯微硬件性能指标..."

> "$LOG_DIR/layer2_cpu_freq.txt"
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    if [ -f "$cpu" ]; then echo "$cpu: $(cat "$cpu")" >> "$LOG_DIR/layer2_cpu_freq.txt"; fi
done

> "$LOG_DIR/layer2_thermal_zone.txt"
for zone in /sys/class/thermal/thermal_zone*/temp; do
    if [ -f "$zone" ]; then echo "$zone: $(cat "$zone")" >> "$LOG_DIR/layer2_thermal_zone.txt"; fi
done

cat /sys/class/devfreq/*gpu/cur_freq > "$LOG_DIR/layer2_gpu_freq.txt" 2>&1

if [ -f /sys/class/devfreq/dmc/cur_freq ]; then
    cat /sys/class/devfreq/dmc/cur_freq > "$LOG_DIR/layer2_ddr_freq.txt" 2>&1
else
    if [ -f /sys/kernel/debug/clk/clk_summary ]; then
        cat /sys/kernel/debug/clk/clk_summary | grep -i ddr > "$LOG_DIR/layer2_ddr_freq.txt" 2>&1
    else
        echo "DDR node and clk_summary not found" > "$LOG_DIR/layer2_ddr_freq.txt"
    fi
fi

if [ -d "/sys/kernel/debug/rknpu" ]; then
    cat /sys/kernel/debug/rknpu/load > "$LOG_DIR/layer2_rknpu_load.txt" 2>&1
else
    echo "NPU debugfs node closed." > "$LOG_DIR/layer2_rknpu_load.txt"
fi

# ==========================================
# 🟠 第三层：内核与底层总线层 (Kernel & Bus)
# ==========================================
echo "[*] 正在收集：第三层 内核与底层总线日志..."
dmesg -T > "$LOG_DIR/layer3_dmesg.log" 2>&1
lspci -v > "$LOG_DIR/layer3_lspci.txt" 2>&1 || lspci > "$LOG_DIR/layer3_lspci.txt" 2>&1
lsusb > "$LOG_DIR/layer3_lsusb.txt" 2>&1
cat /proc/interrupts > "$LOG_DIR/layer3_interrupts.txt" 2>&1

# ==========================================
# 🔵 第四层：系统资源与网络层 (Resources & Network)
# ==========================================
echo "[*] 正在收集：第四层 系统资源与IO网络堆栈..."
free -m > "$LOG_DIR/layer4_free_m.txt" 2>&1
cat /proc/meminfo > "$LOG_DIR/layer4_meminfo.txt" 2>&1
cat /proc/meminfo | grep -i cma > "$LOG_DIR/layer4_cma_info.txt" 2>&1
cat /proc/sys/fs/file-nr > "$LOG_DIR/layer4_file_handles.txt" 2>&1
ip a > "$LOG_DIR/layer4_ip_address.txt" 2>&1
ip route > "$LOG_DIR/layer4_ip_route.txt" 2>&1

# 无线网卡信息
if command -v iwconfig &>/dev/null; then
    iwconfig > "$LOG_DIR/layer4_iwconfig.txt" 2>&1
else
    echo "[!] iwconfig 未安装 (需 wireless-tools 包)" > "$LOG_DIR/layer4_iwconfig.txt"
fi

# 传统网络接口信息
if command -v ifconfig &>/dev/null; then
    ifconfig -a > "$LOG_DIR/layer4_ifconfig.txt" 2>&1
else
    echo "[!] ifconfig 未安装 (需 net-tools 包)" > "$LOG_DIR/layer4_ifconfig.txt"
fi

if command -v ss &> /dev/null; then 
    ss -antp > "$LOG_DIR/layer4_network_connections.txt" 2>&1
else 
    netstat -anp > "$LOG_DIR/layer4_network_connections.txt" 2>&1
fi

if top -h 2>&1 | grep -q "BusyBox"; then
    top -n 1 > "$LOG_DIR/layer4_top_processes.txt" 2>&1
else
    top -b -n 1 > "$LOG_DIR/layer4_top_processes.txt" 2>&1
fi

iostat -x 1 2 > "$LOG_DIR/layer4_iostat.txt" 2>/dev/null

# --- D 状态（不可中断睡眠）进程检测 ---
{
    echo "===== D 状态进程 (精简视图: pid,stat,wchan,comm) ====="
    ps -eo pid,stat,wchan:32,comm | awk 'NR==1 || $2 ~ /^D/ {print $0}'
    echo ""
    echo "===== D 状态进程 (完整视图: ps aux) ====="
    ps aux | awk 'NR==1 || $8 ~ /D/ {print $0}'
} > "$LOG_DIR/layer4_d_state_processes.txt" 2>&1

# ==========================================
# 🔴 第五层：业务与应用层 (Journalctl 深度抓取)
# ==========================================
echo "---------------------------------------------------------"
echo "[*] 正在收集：第五层 Journalctl 级联开机日志..."
JOURNAL_DIR="$LOG_DIR/journalctl"
mkdir -p "$JOURNAL_DIR"

# 导出开机列表以便研发人员核对时间线
journalctl --list-boots > "$JOURNAL_DIR/boot_list.txt" 2>/dev/null

# 自动解析获取实际最大可用 Boots 数量
AVAILABLE_BOOTS=$(journalctl --list-boots 2>/dev/null | wc -l)
echo "[i] 检测到系统当前共存储了 $AVAILABLE_BOOTS 次历史开机日志。"

# 如果用户没有在启动命令中提供 -j 参数，则提示用户输入
if [ "$J_PROVIDED" = false ]; then
    read -p "[?] 请输入需要抓取的最近日志次数 (直接回车默认抓取 10 次): " INPUT_BOOTS
    if [[ -n "$INPUT_BOOTS" && "$INPUT_BOOTS" =~ ^[0-9]+$ ]]; then
        JOURNAL_BOOTS=$INPUT_BOOTS
    elif [[ -n "$INPUT_BOOTS" ]]; then
        echo "[!] 输入无效，将使用默认值: 10"
        JOURNAL_BOOTS=10
    fi
fi

# 确定本次循环最终需要抓取的条数
LOOP_LIMIT=$JOURNAL_BOOTS
if [ "$AVAILABLE_BOOTS" -lt "$JOURNAL_BOOTS" ]; then
    LOOP_LIMIT=$AVAILABLE_BOOTS
    echo "[!] 请求抓取次数($JOURNAL_BOOTS)大于系统存储总数($AVAILABLE_BOOTS)，将抓取全部 $LOOP_LIMIT 次日志。"
else
    echo "[*] 计划抓取最近的 $LOOP_LIMIT 次日志。"
fi

EMPTY_LOGS_WARNING=""

# 从最新的一次(0)向前滚，抓取最近的 N 次日志并带有清晰序号标志
for (( i=0; i<LOOP_LIMIT; i++ )); do
    # 计算 journalctl 内对应的 boot 偏移值 (当前为 0，上一次为 -1，依此类推)
    BOOT_OFFSET=$(( -i ))
    
    # 提取开机对应的大致时间戳，用于美化文件名
    BOOT_TIME=$(journalctl --list-boots 2>/dev/null | grep -E "^\s*${BOOT_OFFSET}\s" | awk '{print $3"_"$4}' | tr -d ':/')
    [ -z "$BOOT_TIME" ] && BOOT_TIME="unknown_time"

    echo "    -> 正在抓取启动次序: $BOOT_OFFSET ($BOOT_TIME)"
    
    LOG_FILE="$JOURNAL_DIR/boot_${BOOT_OFFSET}_${BOOT_TIME}.log"
    journalctl -b "$BOOT_OFFSET" --no-pager > "$LOG_FILE" 2>/dev/null

    # 【新增检查逻辑】检测抓取出来的日志文件是否为空
    if [ ! -s "$LOG_FILE" ]; then
        echo "       [!] 异常提醒: 该启动次序的系统日志内容为空！"
        EMPTY_LOGS_WARNING="${EMPTY_LOGS_WARNING}\n       - 偏移 $BOOT_OFFSET (时间: $BOOT_TIME)"
    fi
done

# 如果有空日志，单独进行高亮警告输出
if [ -n "$EMPTY_LOGS_WARNING" ]; then
    echo "---------------------------------------------------------"
    echo -e "[!] 警告: 捕捉到部分 journalctl 日志为空，系统日志服务可能工作异常或被清空:${EMPTY_LOGS_WARNING}"
    echo "---------------------------------------------------------"
fi

# ==========================================
# 🔴 第五层附加：sysrq-trigger 内核转储 (D状态任务 + 全部任务)
# 说明：先触发内核 dump，再重新抓取 dmesg 和本次启动的 journalctl，
#       以便捕获内核写入的 D 状态任务堆栈等关键信息。
# ==========================================
SYSRQ_TRIGGER="/proc/sysrq-trigger"
if [ "$RUN_MODE" = "sudo" ]; then
    if [ -w "$SYSRQ_TRIGGER" ]; then
        echo "[*] 正在触发 sysrq-trigger：导出 D 状态任务 (w) 和全部任务 (t) ..."
        
        # 先确认 sysrq 功能已启用
        if [ -f /proc/sys/kernel/sysrq ]; then
            SYSRQ_VAL=$(cat /proc/sys/kernel/sysrq)
            if [ "$SYSRQ_VAL" = "0" ]; then
                echo "[!] /proc/sys/kernel/sysrq=0，尝试临时启用..."
                echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
            fi
        fi
        
        # 导出 D 状态任务
        echo w > "$SYSRQ_TRIGGER" 2>/dev/null && \
            echo "    [✓] sysrq w 已触发（D 状态任务已写入内核日志）" || \
            echo "    [!] sysrq w 触发失败"
        
        # 导出全部任务状态（信息量较大）
        echo t > "$SYSRQ_TRIGGER" 2>/dev/null && \
            echo "    [✓] sysrq t 已触发（全部任务状态已写入内核日志）" || \
            echo "    [!] sysrq t 触发失败"
        
        # 恢复 sysrq 原始值
        if [ -n "${SYSRQ_VAL:-}" ]; then
            echo "$SYSRQ_VAL" > /proc/sys/kernel/sysrq 2>/dev/null || true
        fi
        
        # 重新抓取 dmesg（包含 sysrq 导出的内核信息）
        echo "[*] 正在重新抓取 dmesg（含 sysrq 输出）..."
        dmesg -T > "$LOG_DIR/layer3_dmesg_after_sysrq.log" 2>&1
        
        # 重新抓取本次启动的 journalctl（sysrq 输出也可能记录在此）
        echo "[*] 正在重新抓取本次启动的 journalctl（含 sysrq 输出）..."
        journalctl -b 0 --no-pager > "$JOURNAL_DIR/boot_0_after_sysrq.log" 2>/dev/null
        
    else
        echo "[!] $SYSRQ_TRIGGER 不可写，跳过 sysrq-trigger 内核转储。"
    fi
else
    echo "[!] nosudo 模式下无法写入 $SYSRQ_TRIGGER，跳过 sysrq-trigger 内核转储。"
    echo "[!] 如需导出 D 状态任务堆栈，请使用 sudo 模式运行本脚本（注意：可能因 D 进程卡住）。"
fi

# ==========================================
# 6. 加密压缩与彻底清理 (带Log路径和回传研发提示)
# ==========================================
ZIP_TARGET="/tmp/${DIR_NAME}.zip"
echo "[*] 数据采集完毕，开始进行压缩打包..."

# 进入 /tmp 目录进行压缩，避免将绝对路径打入压缩包
cd /tmp || exit
zip -q -r -P "$ZIP_PASSWORD" "$ZIP_TARGET" "$DIR_NAME"

if [ -f "$ZIP_TARGET" ]; then
    # 彻底安全地删除未打包的日志原始临时目录
    rm -rf "$LOG_DIR"
    
    echo "========================================================="
    echo "[✓] 调试日志捕捉与归档成功！"
    echo "---------------------------------------------------------"
    echo "[📍 Log 本地位置]: $ZIP_TARGET"
    echo "---------------------------------------------------------"
    echo "[📢 重要提示]: 请将上述 zip 压缩包通过网络或 U 盘"
    echo "               回传给研发人员进行问题定位与故障深度分析。"
    echo "========================================================="
else
    echo "[-] 错误: 打包压缩失败，请手动检查系统 /tmp 空间及 $LOG_DIR"
    exit 1
fi

exit 0