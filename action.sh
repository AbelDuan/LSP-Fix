#!/system/bin/sh
# =============================================================================
# Xposed Guard · Vector / ZygiskNext 状态显示与一键恢复
#   用法：无参数 = 显示状态并在不健康时自动恢复
#         status  = 只看状态，绝不动设备
#         recover = 强制恢复
#   恢复动作 = 以模块目录为工作目录重启 Vector 守护进程 vectord。
#   ⚠ Vector 在注入失败时会自行重启一次框架(system_server)，因此恢复期间可能出现
#     一次"软重启"（内核不重启，uptime 不断）。这是 Vector 自身的设计，
#     不是本脚本在重启设备。
#   ⚠ 本脚本【不会】执行 zygiskd exit：ZN 的启动脚本只在开机阶段运行，
#     守护进程退出后没有任何机制把它拉起，会让 zygisk 模块整体停摆到下次开机。
# =============================================================================
MODDIR=${0%/*}
VECMOD=/data/adb/modules/zygisk_vector
ZN=/data/adb/modules/zygisksu/bin/zygiskd
LOCK=$MODDIR/.recovering
ACTLOG=/data/local/tmp/xposed_guard.log
LSPDLOG=/data/adb/lspd/log
MODE="$1"

if [ -x /system/bin/setsid ]; then SETSID=/system/bin/setsid; else SETSID=""; fi

latest_vec_log() { ls -t $LSPDLOG/verbose_*.log 2>/dev/null | head -1; }

last_event_of() {
  grep -E "Successfully injected|Failed to inject|Restarting system_server" "$1" 2>/dev/null | tail -1
}

hex2str() {
  s="$1"; r=""
  while [ -n "$s" ]; do
    b=$(echo "$s" | cut -c1-2)
    s=$(echo "$s" | cut -c3-)
    [ -n "$b" ] && r="$r$(printf "%b" "\\x$b")"
  done
  echo "$r"
}

zn_inject_name() {
  case "$1" in
    1) echo "RUNNING（Zygisk 注入正常）" ;;
    2) echo "STOP_BY_USER（被用户手动停止）" ;;
    3) echo "STOP_BY_CRASH（因 crash 被自动停止）" ;;
    *) echo "未知($1)" ;;
  esac
}

zn_deny_name() {
  case "$1" in
    0) echo "DISABLED" ;;
    1) echo "ENFORCED" ;;
    2) echo "JUST_UMOUNT" ;;
    *) echo "未知($1)" ;;
  esac
}

show_zn() {
  if [ ! -x "$ZN" ]; then
    echo "zygiskd 不存在或不可执行：$ZN"
    return
  fi
  zs=$("$ZN" status 2>/dev/null)
  inj=$(echo "$zs" | sed -n "s/^inject_state://p")
  zyg=$(echo "$zs" | sed -n "s/^zygote_states://p")
  z0=$(echo "$zs" | sed -n "s/^zygote_state_0://p")
  z0s=$(echo "$z0" | cut -d, -f1)
  z0p=$(echo "$z0" | cut -d, -f3)
  den=$(echo "$zs" | sed -n "s/^denylist_policy://p")
  iss=$(echo "$zs" | sed -n "s/^modules_with_issue://p")
  echo "版本/root      : $(echo "$zs" | sed -n "s/^version://p")  |  $(echo "$zs" | sed -n "s/^root_status://p")"
  echo "Zygisk 注入    : $inj  -> $(zn_inject_name "$inj")"
  echo "Zygote 监视器  : $zyg 个  |  首个: 注入=$(zn_inject_name "$z0s") pid=${z0p:-?}"
  echo "denylist 策略  : $den  -> $(zn_deny_name "$den")"
  echo "模块(64/32)    : $(echo "$zs" | sed -n "s/^modules64://p")  /  $(echo "$zs" | sed -n "s/^modules32://p")"
  if [ -n "$iss" ] && [ "$iss" != "0" ] && [ "$iss" != "0," ]; then
    cnt=$(echo "$iss" | cut -d, -f1)
    item=$(echo "$iss" | cut -d, -f2- | cut -d, -f1)
    mname=$(echo "$item" | cut -d= -f1)
    mtype=$(echo "$item" | cut -d= -f2 | cut -d@ -f1)
    mhex=$(echo "$item" | cut -d= -f2 | cut -d@ -f2)
    case "$mhex" in
      ""|*[!0-9a-fA-F]*) mproc="$mhex" ;;
      *) mproc=$(hex2str "$mhex") ;;
    esac
    echo "问题模块       : $cnt 个"
    echo "   · $mname  issue类型=$mtype  崩溃进程=${mproc:-?}"
    echo "   ^ 这是 ZN 的【崩溃归因存档】：某崩溃进程的线程回溯里出现该模块的代码。"
    echo "     它是历史记录（本次 zygiskd 会话内粘性），不代表此刻仍在崩；"
    echo "     只有 zygiskd 全新启动（完整开机）才会重算，且只要它不再崩就不会再出现。"
    echo "     ⚠ zn_restart.sh 已于 2026-09-29 实测导致 App 全部无法启动（打断 zygote↔daemon"
    echo "       的 fd 通道，每次 fork 报 '!(fd != -1)'），现已默认拒跑；本 action 永不执行它。"
  else
    echo "问题模块       : 无"
  fi
  echo "提示           : 若 Zygisk 注入显示 STOP_BY_CRASH/STOP_BY_USER，可到 ZN 的网页"
  echo "                 （KSU 管理器 → Zygisk Next → 网页/WebUI 的 dashboard）重新开启 Zygote Monitor。"
}

show_status() {
  echo "===== 系统 ====="
  echo "system_server : $(pidof system_server)"
  echo "zygote64      : $(pidof zygote64)"
  echo "内核 uptime   : $(cut -d" " -f1 /proc/uptime) 秒（不归零=内核没重启）"
  echo
  echo "===== ZygiskNext ====="
  show_zn
  echo
  echo "===== Vector ====="
  vp=$(pidof vectord)
  if [ -z "$vp" ]; then
    echo "守护进程 vectord : 未运行"
  else
    vcwd=$(readlink /proc/$vp/cwd 2>/dev/null)
    echo "守护进程 vectord : pid=$vp"
    echo "工作目录         : $vcwd"
    if [ "$vcwd" != "$VECMOD" ]; then
      echo "                   ^ 不正确（应为 $VECMOD）"
    fi
  fi
  L=$(latest_vec_log)
  if [ -n "$L" ]; then
    echo "最新日志         : $L"
    echo "-- 最近注入事件（末 6 条）--"
    grep -E "daemon started|Successfully injected|Failed to inject|Restarting system_server|Got system server binder|activity. service|DEX fetch" "$L" 2>/dev/null | tail -6 | cut -c1-160
    echo "-- 判据：最后一条关键事件 --"
    last_event_of "$L" | cut -c1-160
  else
    echo "（找不到日志 $LSPDLOG/verbose_*.log）"
  fi
}

decide() {
  ss=$(pidof system_server)
  [ -z "$ss" ] && return 3
  vp=$(pidof vectord)
  [ -z "$vp" ] && return 1
  vcwd=$(readlink /proc/$vp/cwd 2>/dev/null)
  [ "$vcwd" != "$VECMOD" ] && return 1
  L=$(latest_vec_log)
  [ -z "$L" ] && return 3
  ev=$(last_event_of "$L")
  case "$ev" in
    *"Successfully injected"*) return 0 ;;
    *"Restarting system_server"*)
      now=$(date +%s); lm=$(stat -c %Y "$L" 2>/dev/null)
      [ -n "$lm" ] && [ $((now - lm)) -lt 120 ] && return 2
      return 1 ;;
    *) return 1 ;;
  esac
}

do_recover() {
  echo
  echo "===== 执行恢复 ====="
  echo "重启 Vector 守护进程；Vector 注入失败时会自行重启一次框架，可能看到一次软重启（内核不重启）。"
  for p in $(pidof vectord); do kill "$p" 2>/dev/null; done
  sleep 3
  for p in $(pidof vectord); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  cd "$VECMOD" || { echo "错误：无法进入 $VECMOD"; return 1; }
  $SETSID /system/bin/app_process -Djava.class.path="$VECMOD/daemon.apk" /system/bin \
      --nice-name=vectord org.matrix.vector.daemon.VectorDaemon \
      --system-server-max-retry=3 >/dev/null 2>&1 &
  sleep 3
  np=$(pidof vectord)
  if [ -z "$np" ]; then
    echo "错误：守护进程未能启动，请看 $LSPDLOG 最新日志"
    return 1
  fi
  echo "守护进程已启动：pid=$np（工作目录 $VECMOD），等待自愈，最长 60 秒…"
  i=0
  while [ $i -lt 12 ]; do
    sleep 5
    i=$((i + 1))
    L=$(latest_vec_log)
    ev=$(last_event_of "$L")
    case "$ev" in
      *"Successfully injected"*) echo "第 $((i * 5)) 秒：注入成功 ✓"; break ;;
    esac
  done
  echo
  echo "===== 恢复后 ====="
  show_status
  echo "[$(date "+%F %T")] recover: ss=$(pidof system_server) vec=$(pidof vectord) event=$(last_event_of "$(latest_vec_log)")" >> "$ACTLOG"
}

case "$MODE" in
  status) show_status; exit 0 ;;
  recover) do_recover; exit 0 ;;
esac

show_status
echo
if [ -f "$LOCK" ]; then
  now=$(date +%s); lm=$(stat -c %Y "$LOCK" 2>/dev/null)
  if [ -n "$lm" ] && [ $((now - lm)) -lt 180 ]; then
    echo "== 判定：上一次恢复仍在进行中，本次不做动作，请稍后再点 =="
    exit 0
  fi
fi
decide; rc=$?
case "$rc" in
  0) echo "== 判定：Vector 健康（守护进程在位、工作目录正确、最近事件=注入成功），无需恢复 ==" ; exit 0 ;;
  1) echo "== 判定：需要恢复（守护进程缺失 / 工作目录错误 / 最近事件不是注入成功）=="
     touch "$LOCK"; do_recover; rm -f "$LOCK"; exit 0 ;;
  2) echo "== 判定：Vector 正在自愈（最近事件=Restarting 且日志刚更新），等 1-2 分钟再点 ==" ; exit 0 ;;
  *) echo "== 判定：system_server 不在或 Vector 无日志，可能正在重启，稍后再点 ==" ; exit 1 ;;
esac
