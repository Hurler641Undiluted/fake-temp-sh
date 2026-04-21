#!/bin/bash

CONFIG_FILE="config.txt"
MNT_BASE="/tmp/thermal_fake"
MAP_FILE="$MNT_BASE/.thermal_map.list"
STATE_FILE="$MNT_BASE/.state.env"
ACTIVE_FILE="$MNT_BASE/.active"
MUBEI_STATE_FILE="$MNT_BASE/.mubei_state.env"

if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] 请以 root 权限运行"
    exit 1
fi

EMUL_FIRST=1
ENABLE_MODE=1
STOP_THERMAL_SERVICES=0
UNMOUNT_STEP_DELAY_MS=120
DEBUG_LEVEL=1

BATT_TEMP=""
FAKE_CYCLE_COUNT=""
FAKE_UEVENT=1

MUBEI_ENABLE=0
HORAE_DISABLE=0

set -E
trap '''rc=$?; if [ "$rc" -ne 0 ] && [ "${DEBUG_LEVEL:-1}" -ge 1 ]; then echo "[$(timestamp)] [ERR ] 第${LINENO}行执行失败: ${BASH_COMMAND} (rc=$rc)" >&2; fi''' ERR

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_print() {
    local tag="$1"
    shift
    echo "[$(timestamp)] [$tag] $*"
}

log_ok() {
    if [ "${DEBUG_LEVEL:-1}" -ge 1 ]; then
        _log_print " OK " "$@"
    fi
    return 0
}

log_warn() {
    if [ "${DEBUG_LEVEL:-1}" -ge 1 ]; then
        _log_print "WARN" "$@"
    fi
    return 0
}

log_err() {
    if [ "${DEBUG_LEVEL:-1}" -ge 1 ]; then
        _log_print "ERR " "$@"
    fi
    return 0
}

log_info() {
    if [ "${DEBUG_LEVEL:-1}" -ge 1 ]; then
        _log_print "INFO" "$@"
    fi
    return 0
}

log_debug() {
    if [ "${DEBUG_LEVEL:-1}" -ge 2 ]; then
        _log_print "DBG " "$@"
    fi
    return 0
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

extract_numeric() {
    local input="$1"
    local num
    num=$(echo "$input" | grep -oE '[-]?[0-9]+([.][0-9]+)?' | head -n 1)
    [ -z "$num" ] && num="0"
    echo "$num"
}

raw_to_celsius_display() {
    local input="$1"
    local num
    num=$(extract_numeric "$input")

    awk -v n="$num" '
    BEGIN {
        if (n == "" || n == 0) {
            print "0℃"
            exit
        }
        if (n >= 1000 || n <= -1000) {
            v = n / 1000
        } else {
            v = n
        }
        s = sprintf("%.3f", v)
        sub(/\.?0+$/, "", s)
        print s "℃"
    }'
}

deci_to_celsius_display() {
    local input="$1"
    local num
    num=$(extract_numeric "$input")

    awk -v n="$num" '
    BEGIN {
        if (n == "" || n == 0) {
            print "0℃"
            exit
        }
        v = n / 10
        s = sprintf("%.1f", v)
        sub(/\.?0+$/, "", s)
        print s "℃"
    }'
}

value_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

sleep_ms() {
    local ms="$1"
    [ -z "$ms" ] && ms=0
    awk -v m="$ms" 'BEGIN { printf "%.3f\n", m / 1000 }' | {
        read -r sec
        sleep "$sec"
    }
}

create_default_config() {
    cat > "$CONFIG_FILE" <<'EOF'
# =========================
# thermal 规则
# =========================

# 按 CPU 类型匹配温度节点。
#cpu 36000 20000

# 按 GPU 类型匹配温度节点。
#gpu 36000 20000

# 按 battery 类型匹配温度节点。
#battery 36000 20000

# 按 shell 类型匹配温度节点。
#shell 36000 20000

# 按 wireless 类型匹配温度节点。
#wireless 36000 20000

# 按 ddr 类型匹配温度节点。
#ddr 36000 20000

# 按 sys-therm 类型匹配温度节点。
#sys-therm 36000 20000

* 36000 20000


# =========================
# 行为选项
# =========================

EMUL_FIRST=1
# 是否优先使用 emul_temp 改温度。
# 1 表示先写 emul_temp，失败后再尝试 bind temp；0 表示先 bind temp，失败后再写 emul_temp

ENABLE_MODE=1
# 写 emul_temp 之前，是否先把 mode 设为 enabled。
# 1 表示尝试启用；0 表示不处理 mode

STOP_THERMAL_SERVICES=0
# 启动时是否尝试停止系统热控服务。
# 1 表示尝试停止 thermal-engine、thermald、欧加相关热控服务；0 表示不处理

UNMOUNT_STEP_DELAY_MS=120
# 停止脚本时，每次卸载挂载点之间的间隔，单位毫秒。
# 某些机型卸载太快容易失败，可以适当调大

DEBUG_LEVEL=1
# 日志级别。
# 0 表示不输出日志；1 表示输出基本日志；2 表示输出完整日志


# =========================
# battery 伪装选项
# =========================

BATT_TEMP=
# 电池温度，使用 deci-℃ 风格数值。
# 例如 360 表示 36.0℃，385 表示 38.5℃；留空表示不改

FAKE_CYCLE_COUNT=
# 伪装充电循环次数。
# 留空表示不改

FAKE_UEVENT=1
# 是否同时伪造 battery 的 uevent。
# 1 表示生成 fake_uevent 并挂载；0 表示不处理


# =========================
# 欧加相关选项
# =========================

MUBEI_ENABLE=0
# 是否启用欧加真墓碑相关设置。
# 1 表示只处理 cgroup.freeze；0 表示不处理

HORAE_DISABLE=0
# 是否禁用 Horae 热控。
# 1 表示尝试停止 Horae 服务并关闭对应开关；0 表示不处理
EOF
}

save_state() {
    local horae_prev=""
    horae_prev=$(getprop persist.sys.horae.enable 2>/dev/null)

    mkdir -p "$MNT_BASE"
    {
        printf 'HORAE_DISABLE=%q\n' "$HORAE_DISABLE"
        printf 'HORAE_PREV_VALUE=%q\n' "$horae_prev"
        printf 'MUBEI_ENABLE=%q\n' "$MUBEI_ENABLE"
        printf 'UNMOUNT_STEP_DELAY_MS=%q\n' "$UNMOUNT_STEP_DELAY_MS"
        printf 'DEBUG_LEVEL=%q\n' "$DEBUG_LEVEL"
    } > "$STATE_FILE"
}

load_extra_config() {
    [ ! -f "$CONFIG_FILE" ] && return

    while IFS= read -r raw || [ -n "$raw" ]; do
        local line
        line=$(trim "$raw")
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            key=$(trim "$key")
            val=$(trim "$val")

            case "$key" in
                EMUL_FIRST) EMUL_FIRST="$val" ;;
                ENABLE_MODE) ENABLE_MODE="$val" ;;
                STOP_THERMAL_SERVICES) STOP_THERMAL_SERVICES="$val" ;;
                UNMOUNT_STEP_DELAY_MS) UNMOUNT_STEP_DELAY_MS="$val" ;;
                DEBUG_LEVEL) DEBUG_LEVEL="$val" ;;
                BATT_TEMP) BATT_TEMP="$val" ;;
                FAKE_CYCLE_COUNT) FAKE_CYCLE_COUNT="$val" ;;
                FAKE_UEVENT) FAKE_UEVENT="$val" ;;
                MUBEI_ENABLE) MUBEI_ENABLE="$val" ;;
                HORAE_DISABLE) HORAE_DISABLE="$val" ;;
            esac

            log_info "读取附加配置: $key=$val"
        fi
    done < "$CONFIG_FILE"

    case "$DEBUG_LEVEL" in
        0|1|2) ;;
        *) DEBUG_LEVEL=1 ;;
    esac

    case "$UNMOUNT_STEP_DELAY_MS" in
        ''|*[!0-9]*) UNMOUNT_STEP_DELAY_MS=120 ;;
    esac

    return 0
}

prop_get() {
    local key="$1"
    getprop "$key" 2>/dev/null
}

prop_set() {
    local key="$1"
    local val="$2"

    if command -v resetprop >/dev/null 2>&1; then
        resetprop "$key" "$val" >/dev/null 2>&1
    else
        setprop "$key" "$val" >/dev/null 2>&1
    fi
}

init_service_stop() {
    local svc="$1"

    command stop "$svc" >/dev/null 2>&1 && log_ok "已执行: stop $svc" || log_warn "执行失败或不存在: stop $svc"
    command setprop ctl.stop "$svc" >/dev/null 2>&1 && log_ok "已请求停止服务: $svc" || true
}

init_service_start() {
    local svc="$1"

    command start "$svc" >/dev/null 2>&1 && log_ok "已执行: start $svc" || true
    command setprop ctl.start "$svc" >/dev/null 2>&1 && log_ok "已请求启动服务: $svc" || true
}

is_path_mounted_now() {
    local target="$1"
    grep -F " $target " /proc/self/mountinfo >/dev/null 2>&1
}

is_already_mounted() {
    local target="$1"
    grep -q "^${target}|" "$MAP_FILE" 2>/dev/null && return 0
    is_path_mounted_now "$target" && return 0
    return 1
}

record_mount() {
    local target="$1"
    local source="$2"
    echo "${target}|${source}" >> "$MAP_FILE"
}

bind_fake_file() {
    local target="$1"
    local value="$2"

    [ -e "$target" ] || {
        log_warn "目标不存在，跳过挂载: $target"
        return 1
    }

    if is_already_mounted "$target"; then
        log_warn "目标已挂载，跳过重复挂载: $target"
        return 0
    fi

    local tmp_file
    tmp_file=$(mktemp "$MNT_BASE/data_XXXXXXXXX") || {
        log_err "创建临时文件失败: $target"
        return 1
    }

    printf '%s' "$value" > "$tmp_file"

    if mount --bind "$tmp_file" "$target" 2>/dev/null; then
        record_mount "$target" "$tmp_file"
        log_ok "bind挂载成功: $target <= $value"
        return 0
    fi

    rm -f "$tmp_file"
    log_err "bind挂载失败: $target <= $value"
    return 1
}

bind_existing_targets_with_value() {
    local value="$1"
    shift
    local path

    for path in "$@"; do
        [ -e "$path" ] || {
            log_warn "节点不存在，跳过: $path"
            continue
        }
        bind_fake_file "$path" "$value"
    done
}

bind_existing_targets_with_file() {
    local src_file="$1"
    shift
    local path

    for path in "$@"; do
        [ -e "$path" ] || {
            log_warn "节点不存在，跳过: $path"
            continue
        }

        if is_already_mounted "$path"; then
            log_warn "目标已挂载，跳过重复挂载: $path"
            continue
        fi

        if mount --bind "$src_file" "$path" 2>/dev/null; then
            record_mount "$path" "$src_file"
            log_ok "文件挂载成功: $path <= $src_file"
        else
            log_err "文件挂载失败: $path <= $src_file"
        fi
    done
}

write_emul_temp() {
    local dir_path="$1"
    local raw_target="$2"
    local emul_file="$dir_path/emul_temp"
    local mode_file="$dir_path/mode"

    [ -w "$emul_file" ] || {
        log_warn "emul_temp不可写或不存在: $emul_file"
        return 1
    }

    if [ "$ENABLE_MODE" = "1" ] && [ -w "$mode_file" ]; then
        echo "enabled" > "$mode_file" 2>/dev/null
        log_info "已尝试启用mode: $mode_file => enabled"
    fi

    if printf '%s' "$raw_target" > "$emul_file" 2>/dev/null; then
        log_ok "emul_temp写入成功: $emul_file <= $raw_target ($(raw_to_celsius_display "$raw_target"))"
        return 0
    fi

    log_err "emul_temp写入失败: $emul_file <= $raw_target"
    return 1
}

stop_thermal_services_once() {
    [ "$STOP_THERMAL_SERVICES" = "1" ] || return 0

    log_info "开始尝试停止热控服务"

    init_service_stop "thermal-engine"
    init_service_stop "vendor.thermal-engine"
    init_service_stop "vendor.thermal_manager"
    init_service_stop "thermald"
    init_service_stop "vendor.oplus.ormsHalService-aidl-defaults"

    command setprop init.svc.thermal-engine stopped >/dev/null 2>&1 && log_ok "已设置属性: init.svc.thermal-engine=stopped" || true
    command setprop init.svc.android.thermal-hal stopped >/dev/null 2>&1 && log_ok "已设置属性: init.svc.android.thermal-hal=stopped" || true
}

format_batt_temp_to_deci() {
    extract_numeric "$1"
}

generate_fake_uevent_content() {
    local temp_deci="$1"
    local cycle="$2"
    local target_file="$3"
    local src_uevent="/sys/class/power_supply/battery/uevent"

    : > "$target_file"

    if [ -f "$src_uevent" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                POWER_SUPPLY_TEMP=*)
                    if [ -n "$temp_deci" ]; then
                        echo "POWER_SUPPLY_TEMP=$temp_deci" >> "$target_file"
                    else
                        echo "$line" >> "$target_file"
                    fi
                    ;;
                POWER_SUPPLY_CYCLE_COUNT=*)
                    if [ -n "$cycle" ]; then
                        echo "POWER_SUPPLY_CYCLE_COUNT=$cycle" >> "$target_file"
                    else
                        echo "$line" >> "$target_file"
                    fi
                    ;;
                *)
                    echo "$line" >> "$target_file"
                    ;;
            esac
        done < "$src_uevent"
    else
        [ -n "$temp_deci" ] && echo "POWER_SUPPLY_TEMP=$temp_deci" >> "$target_file"
        [ -n "$cycle" ] && echo "POWER_SUPPLY_CYCLE_COUNT=$cycle" >> "$target_file"
    fi

    log_ok "已生成 fake_uevent 文件: $target_file"
}

spoof_battery_nodes() {
    local batt_temp_deci=""
    [ -n "$BATT_TEMP" ] && batt_temp_deci=$(format_batt_temp_to_deci "$BATT_TEMP")

    log_info "开始处理 battery 相关节点"

    if [ -n "$batt_temp_deci" ]; then
        log_info "电池温度目标: 原始输入=$BATT_TEMP, 写入值=$batt_temp_deci, 显示=$(deci_to_celsius_display "$batt_temp_deci")"
        bind_existing_targets_with_value "$batt_temp_deci" \
            /sys/class/power_supply/battery/temp \
            /sys/class/oplus_chg/battery/temp \
            /sys/class/oplus_chg/battery/batt_temp \
            /sys/class/oplus_chg/battery/temp_level \
            /sys/devices/platform/soc/soc:oplus,mms_gauge/oplus_mms/gauge/battery/temp
    else
        log_warn "未配置 BATT_TEMP，跳过电池温度伪装"
    fi

    if [ -n "$FAKE_CYCLE_COUNT" ]; then
        log_info "循环次数目标: $FAKE_CYCLE_COUNT"
        bind_existing_targets_with_value "$FAKE_CYCLE_COUNT" \
            /sys/class/power_supply/battery/cycle_count \
            /sys/class/power_supply/battery/cycle \
            /sys/class/power_supply/battery/battery_cycle \
            /sys/class/power_supply/battery/batt_cycle \
            /sys/class/power_supply/bms/cycle_count \
            /sys/class/power_supply/bms/battery_cycle \
            /sys/class/oplus_chg/battery/cycle_count \
            /sys/class/oplus_chg/battery/charge_cycle \
            /sys/class/oplus_chg/battery/batt_chargecycles \
            /sys/class/oplus_chg/battery/battery_cc \
            /sys/devices/platform/soc/soc:oplus,mms_gauge/oplus_mms/gauge/battery/cycle_count
    else
        log_warn "未配置 FAKE_CYCLE_COUNT，跳过循环次数伪装"
    fi

    if [ "$FAKE_UEVENT" = "1" ]; then
        local fake_uevent_file="$MNT_BASE/fake_uevent"
        generate_fake_uevent_content "$batt_temp_deci" "$FAKE_CYCLE_COUNT" "$fake_uevent_file"
        bind_existing_targets_with_file "$fake_uevent_file" \
            /sys/class/power_supply/battery/uevent
    else
        log_warn "FAKE_UEVENT=0，跳过 uevent 伪装"
    fi
}

capture_mubei_original_state() {
    [ "$MUBEI_ENABLE" = "1" ] || return 0

    local f1 f2
    f1=""
    f2=""
    [ -f /sys/fs/cgroup/unfrozen/cgroup.freeze ] && f1=$(cat /sys/fs/cgroup/unfrozen/cgroup.freeze 2>/dev/null)
    [ -f /sys/fs/cgroup/frozen/cgroup.freeze ] && f2=$(cat /sys/fs/cgroup/frozen/cgroup.freeze 2>/dev/null)

    {
        printf 'CGROUP_UNFROZEN_FREEZE=%q
' "$f1"
        printf 'CGROUP_FROZEN_FREEZE=%q
' "$f2"
    } > "$MUBEI_STATE_FILE"
}

apply_mubei_once() {
    [ "$MUBEI_ENABLE" = "1" ] || return 0

    capture_mubei_original_state

    if [ -f /sys/fs/cgroup/unfrozen/cgroup.freeze ]; then
        echo 1 > /sys/fs/cgroup/unfrozen/cgroup.freeze 2>/dev/null && log_ok "已设置 /sys/fs/cgroup/unfrozen/cgroup.freeze=1" || log_warn "设置 /sys/fs/cgroup/unfrozen/cgroup.freeze 失败"
    fi

    if [ -f /sys/fs/cgroup/frozen/cgroup.freeze ]; then
        echo 1 > /sys/fs/cgroup/frozen/cgroup.freeze 2>/dev/null && log_ok "已设置 /sys/fs/cgroup/frozen/cgroup.freeze=1" || log_warn "设置 /sys/fs/cgroup/frozen/cgroup.freeze 失败"
    fi

    return 0
}

restore_mubei_once() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    [ "$MUBEI_ENABLE" = "1" ] || return 0
    [ -f "$MUBEI_STATE_FILE" ] || return 0

    . "$MUBEI_STATE_FILE"

    if [ -f /sys/fs/cgroup/unfrozen/cgroup.freeze ]; then
        echo "${CGROUP_UNFROZEN_FREEZE:-0}" > /sys/fs/cgroup/unfrozen/cgroup.freeze 2>/dev/null && log_ok "已恢复 /sys/fs/cgroup/unfrozen/cgroup.freeze=${CGROUP_UNFROZEN_FREEZE:-0}" || true
    fi

    if [ -f /sys/fs/cgroup/frozen/cgroup.freeze ]; then
        echo "${CGROUP_FROZEN_FREEZE:-0}" > /sys/fs/cgroup/frozen/cgroup.freeze 2>/dev/null && log_ok "已恢复 /sys/fs/cgroup/frozen/cgroup.freeze=${CGROUP_FROZEN_FREEZE:-0}" || true
    fi

    return 0
}

disable_horae_once() {
    [ "$HORAE_DISABLE" = "1" ] || return 0

    local current=""
    current=$(getprop persist.sys.horae.enable 2>/dev/null)

    if [ "$current" != "0" ]; then
        prop_set persist.sys.horae.enable 0 && log_ok "已关闭 Horae 持久开关：persist.sys.horae.enable=0" || true
    else
        log_info "Horae 持久开关已经是关闭状态，跳过重复设置"
    fi

    init_service_stop "horae"
    return 0
}

restore_horae_once() {
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    [ "$HORAE_DISABLE" = "1" ] || return 0

    local restore_val="${HORAE_PREV_VALUE:-1}"

    prop_set persist.sys.horae.enable "$restore_val" && log_ok "已恢复 Horae 持久开关：persist.sys.horae.enable=$restore_val" || true

    if [ "$restore_val" = "1" ]; then
        init_service_start "horae"
    fi

    return 0
}

recover_mount_map_from_mountinfo() {
    mkdir -p "$MNT_BASE"
    : > "$MAP_FILE"

    awk -v base="$MNT_BASE/" '
    {
        sep = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "-") {
                sep = i
                break
            }
        }
        if (sep > 0) {
            mnt = $5
            src = $(sep + 2)
            if (index(src, base) == 1) {
                print mnt "|" src
            }
        }
    }' /proc/self/mountinfo >> "$MAP_FILE"
    return 0
}

mount_priority() {
    local path="$1"
    case "$path" in
        */battery/temp|*/battery/batt_temp|*/gauge/battery/temp) echo 90 ;;
        */battery/temp_level) echo 85 ;;
        */battery/cycle_count|*/battery/cycle|*/battery/battery_cycle|*/battery/batt_cycle|*/battery/charge_cycle|*/battery/batt_chargecycles|*/battery/battery_cc) echo 70 ;;
        */battery/uevent) echo 60 ;;
        *) echo 10 ;;
    esac
}

has_residual_state() {
    [ -f "$ACTIVE_FILE" ] && return 0
    [ -s "$MAP_FILE" ] && return 0
    [ -f "$STATE_FILE" ] && return 0
    [ -f "$MUBEI_STATE_FILE" ] && return 0
    grep -F "$MNT_BASE/" /proc/self/mountinfo >/dev/null 2>&1 && return 0
    return 1
}

stop_core() {
    log_info "开始卸载与清理"

    local failed_unmount=0
    local entries=""
    local target source pri
    local -a removable_sources=()

    if [ ! -s "$MAP_FILE" ]; then
        recover_mount_map_from_mountinfo
    fi
    log_info "正在恢复硬件真实温度读取..."
    for dir_path in /sys/class/thermal/thermal_zone*; do
        if [ -w "$dir_path/emul_temp" ]; then
            echo 0 > "$dir_path/emul_temp"
            # 如果之前改了 mode，也改回去
            [ -w "$dir_path/mode" ] && echo "enabled" > "$dir_path/mode" 
        fi
    done
    if [ -s "$MAP_FILE" ]; then
        while IFS='|' read -r target source; do
            [ -z "$target" ] && continue
            pri=$(mount_priority "$target")
            entries="${entries}${pri}|${target}|${source}"$'\n'
        done < "$MAP_FILE"

        exec 3> "$MNT_BASE/.unmount_results"
        echo "$entries" | sort -t'|' -k1,1nr | while IFS='|' read -r pri mnt_point tmp_file; do
            [ -z "$mnt_point" ] && continue

            log_debug "准备卸载: priority=$pri, target=$mnt_point, source=$tmp_file"

            if umount -l "$mnt_point" 2>/dev/null; then
                log_ok "已卸载: $mnt_point"
                echo "$tmp_file" >&3
            else
                log_warn "卸载失败或未挂载: $mnt_point"
                echo "__UNMOUNT_FAILED__" >&3
            fi

            sleep_ms "$UNMOUNT_STEP_DELAY_MS"
        done
        exec 3>&-

        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "__UNMOUNT_FAILED__" ]; then
                failed_unmount=1
            elif [ -n "$line" ]; then
                removable_sources+=("$line")
            fi
        done < "$MNT_BASE/.unmount_results"

        rm -f "$MNT_BASE/.unmount_results"
    else
        log_warn "没有找到挂载记录，当前没有需要卸载的挂载点"
    fi

    restore_mubei_once
    restore_horae_once
    rm -f "$ACTIVE_FILE"

    if [ "$failed_unmount" -eq 0 ]; then
        local uniq_file
        printf '%s\n' "${removable_sources[@]}" | awk 'NF && !seen[$0]++' | while IFS= read -r uniq_file; do
            [ -e "$uniq_file" ] || continue
            rm -f "$uniq_file"
            log_ok "已删除临时文件: $uniq_file"
        done

        rm -f "$MAP_FILE" "$STATE_FILE" "$MUBEI_STATE_FILE" "$ACTIVE_FILE"
        rm -rf "$MNT_BASE"
        log_ok "已清理目录: $MNT_BASE"
        log_ok "全部还原完成"
    else
        log_warn "存在卸载失败，为避免残留挂载指向失效文件，已保留临时文件和状态目录，请手动检查后再清理: $MNT_BASE"
    fi

    return 0
}

preclean_stale_state_once() {
    if has_residual_state; then
        log_warn "检测到上次运行残留状态，先做一次清理再重新应用配置"
        stop_core
    fi
}

script_start() {
    if [ ! -f "$CONFIG_FILE" ]; then
        create_default_config
        echo "未找到 $CONFIG_FILE，已自动生成默认模板，请先按需修改后再运行"
        exit 1
    fi

    load_extra_config
    preclean_stale_state_once

    mkdir -p "$MNT_BASE"
    touch "$MAP_FILE"

    save_state
    echo "1" > "$ACTIVE_FILE"

    log_info "加载配置文件: $CONFIG_FILE"
    log_info "当前选项: EMUL_FIRST=$EMUL_FIRST, ENABLE_MODE=$ENABLE_MODE, STOP_THERMAL_SERVICES=$STOP_THERMAL_SERVICES, DEBUG_LEVEL=$DEBUG_LEVEL, UNMOUNT_STEP_DELAY_MS=$UNMOUNT_STEP_DELAY_MS, MUBEI_ENABLE=$MUBEI_ENABLE, HORAE_DISABLE=$HORAE_DISABLE"
    [ -n "$BATT_TEMP" ] && log_info "当前 BATT_TEMP=$BATT_TEMP ($(deci_to_celsius_display "$BATT_TEMP"))"
    [ -n "$FAKE_CYCLE_COUNT" ] && log_info "当前 FAKE_CYCLE_COUNT=$FAKE_CYCLE_COUNT"

    stop_thermal_services_once
    apply_mubei_once
    disable_horae_once

    log_info "开始 thermal 处理，策略: 优先 emul_temp，失败再 bind temp"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        local line
        line=$(trim "$raw_line")

        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue

        local type_pattern
        local target_val
        local threshold
        local raw_target
        local raw_threshold

        type_pattern=$(echo "$line" | awk '{print $1}')
        target_val=$(echo "$line" | awk '{print $2}')
        threshold=$(echo "$line" | awk '{print $3}')

        [ -z "$type_pattern" ] && continue
        [ -z "$target_val" ] && continue
        [ -z "$threshold" ] && threshold=0

        raw_target="$target_val"
        raw_threshold="$threshold"

        log_info "处理规则: type匹配=$type_pattern, 目标值=$raw_target ($(raw_to_celsius_display "$raw_target")), 阈值=$raw_threshold ($(raw_to_celsius_display "$raw_threshold"))"

        local dir_path
        for dir_path in /sys/class/thermal/*; do
            [ ! -d "$dir_path" ] && continue

            local type_file="$dir_path/type"
            local temp_file="$dir_path/temp"
            local emul_file="$dir_path/emul_temp"
            local zone_name
            local actual_type
            local current_val
            local done_flag

            zone_name=$(basename "$dir_path")

            if [ ! -f "$type_file" ]; then
                log_debug "跳过 $zone_name: 缺少 type 文件"
                continue
            fi

            if [ ! -f "$temp_file" ] && [ ! -f "$emul_file" ]; then
                log_debug "跳过 $zone_name: temp 和 emul_temp 都不存在"
                continue
            fi

            actual_type=$(cat "$type_file" 2>/dev/null)
            [ -z "$actual_type" ] && actual_type="<empty>"

            if [ -f "$temp_file" ]; then
                current_val=$(cat "$temp_file" 2>/dev/null)
            else
                current_val=0
            fi
            [ -z "$current_val" ] && current_val=0

            log_debug "扫描节点: zone=$zone_name, type=$actual_type, 当前值=$current_val ($(raw_to_celsius_display "$current_val"))"

            if [[ "$actual_type" =~ $type_pattern || "$type_pattern" == "*" ]]; then
                log_info "匹配成功: zone=$zone_name, type=$actual_type"

                if value_lt "$current_val" "$raw_threshold"; then
                    log_warn "因低于阈值而跳过: zone=$zone_name, type=$actual_type, 当前=$current_val ($(raw_to_celsius_display "$current_val")), 阈值=$raw_threshold ($(raw_to_celsius_display "$raw_threshold"))"
                    continue
                fi

                done_flag=0

                if [ "$EMUL_FIRST" = "1" ]; then
                    log_info "优先尝试 emul_temp: $zone_name"
                    if write_emul_temp "$dir_path" "$raw_target"; then
                        done_flag=1
                    fi
                fi

                if [ "$done_flag" = "0" ] && [ -f "$temp_file" ]; then
                    log_info "尝试 bind temp: $temp_file"
                    if bind_fake_file "$temp_file" "$raw_target"; then
                        done_flag=1
                    fi
                fi

                if [ "$done_flag" = "0" ] && [ "$EMUL_FIRST" != "1" ]; then
                    log_info "后备尝试 emul_temp: $zone_name"
                    if write_emul_temp "$dir_path" "$raw_target"; then
                        done_flag=1
                    fi
                fi

                if [ "$done_flag" = "1" ]; then
                    log_ok "规则处理成功: zone=$zone_name, type=$actual_type, 目标=$raw_target"
                else
                    log_err "规则处理失败: zone=$zone_name, type=$actual_type"
                fi
            else
                log_debug "未匹配: zone=$zone_name, type=$actual_type, pattern=$type_pattern"
            fi
        done
    done < "$CONFIG_FILE"

    spoof_battery_nodes

    log_ok "全部处理完成"
    return 0
}

script_stop() {
    load_extra_config
    stop_core
    return 0
}

action="$1"
if [ -z "$action" ]; then
    [ -f "$ACTIVE_FILE" ] && action=0 || action=1
fi

case "$action" in
    1) script_start ;;
    0) script_stop ;;
    *) echo "用法: $0 [1|0]"; exit 1 ;;
esac
