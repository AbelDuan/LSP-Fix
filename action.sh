#!/system/bin/sh
# =============================================================================
# Xposed Guard · action = Vector 式软重启（重启主 zygote）
#
#   方案来源（Vector 2.2 源码，GPL-3.0）：
#     daemon/src/main/kotlin/org/matrix/vector/daemon/VectorDaemon.kt:244
#       fun softReboot() {
#         Log.w(TAG, "Soft reboot: restarting the primary zygote")
#         SystemProperties.set("ctl.restart", "zygote")
#       }
#     调用链：Manager UI → IManagerService.aidl:626 void softReboot()
#             → ManagerService.kt:317 → VectorDaemon.softReboot()
#     —— 即用 init 的 ctl.restart 机制重启「主 zygote」；system_server 由主 zygote fork，
#        所以重启主 zygote 就等于重建框架。**守护进程 vectord 不动**，
#        新 zygote/system_server 起来后由它自动注入，这就是"每次都能挂上"的原因。
#
#   本机实测（2026-09-30 16:14）：
#     PRE  zygote64=30010 system_server=30167 vectord=11459
#     ↓ setprop ctl.restart zygote
#     POST zygote64=16532 system_server=16688 vectord=11459（不变）
#          内核 uptime 连续未重启；16:14:19 Got binder on attempt 1
#          → 16:14:23 Successfully injected Vector IPC binder for applications
#
#   ⚠ 代价：框架级软重启 —— 屏幕全灭、所有 App 重启、约 20–40 秒；**内核不重启**
#     （uptime 不归零）。点一次即执行，不询问（防止误点：3 分钟内重复点击会被锁挡住）。
#
#   旧方案（重启 Vector 守护进程）已备份：
#     /data/adb/modules/xposed_guard/action.legacy-daemon-restart.sh.bak
#     仓库：legacy/action-daemon-restart.sh（要回退就把备份拷回 action.sh）
#
#   用法：无参数 = 执行；status = 只看状态不执行
# =============================================================================
MODDIR=${0%/*}
ZN=/data/adb/modules/zygisksu/bin/zygiskd
LOCK=$MODDIR/.softrebooting
ACTLOG=/data/local/tmp/xposed_guard.log
REPORT=$MODDIR/last_softreboot.txt
LSPDLOG=/data/adb/lspd/log
MODE="$1"

echo "===== Xposed Guard · Vector 式软重启 ====="
echo "机制：setprop ctl.restart zygote  (Vector 源码 VectorDaemon.kt:244 同一实现)"
echo
echo "-- 执行前状态 --"
echo "system_server : $(pidof system_server)"
echo "zygote64      : $(pidof zygote64)"
echo "vectord       : $(pidof vectord)   (本方案不动它)"
echo "内核 uptime   : $(cut -d" " -f1 /proc/uptime) 秒"
if [ -x "$ZN" ]; then
  "$ZN" status 2>/dev/null | grep -E "^(inject_state|zygote_states|modules_with_issue|modules64):" | sed "s/^/ZN /"
fi
L=$(ls -t $LSPDLOG/verbose_*.log 2>/dev/null | head -1)
if [ -n "$L" ]; then
  echo "-- Vector 最后一条关键事件 --"
  grep -E "Successfully injected|Failed to inject|Restarting system_server" "$L" 2>/dev/null | tail -1 | cut -c1-160
fi
echo

if [ "$MODE" = "status" ]; then
  echo "(status 模式：未执行软重启)"
  exit 0
fi

if [ -f "$LOCK" ]; then
  now=$(date +%s); lm=$(stat -c %Y "$LOCK" 2>/dev/null)
  if [ -n "$lm" ] && [ $((now - lm)) -lt 180 ]; then
    echo "== 3 分钟内已执行过一次软重启，本次不执行（锁文件 $LOCK）=="
    exit 0
  fi
fi
touch "$LOCK"

{
  echo "== 执行前 =="
  date
  echo "zygote64=$(pidof zygote64) system_server=$(pidof system_server) vectord=$(pidof vectord)"
  echo "uptime=$(cut -d" " -f1 /proc/uptime)"
} > "$REPORT"
{
  sleep 45
  echo "== 45 秒后采样 ==" >> "$REPORT"
  date >> "$REPORT"
  echo "zygote64=$(pidof zygote64) system_server=$(pidof system_server) vectord=$(pidof vectord)" >> "$REPORT"
  echo "uptime=$(cut -d" " -f1 /proc/uptime)" >> "$REPORT"
  "$ZN" status 2>&1 | grep -E "zygote_states|zygote_state_0|inject_state|modules_with_issue" >> "$REPORT"
  L2=$(ls -t $LSPDLOG/verbose_*.log 2>/dev/null | head -1)
  echo "vec_log=$L2" >> "$REPORT"
  grep -E "Got system server binder|Successfully injected|Failed to inject|Restarting system_server" "$L2" 2>/dev/null | tail -5 >> "$REPORT"
  echo "phone_procs=$(ps -A | grep -c "com.android.phone")" >> "$REPORT"
  rm -f "$LOCK"
} >/dev/null 2>&1 &

echo "== 触发：setprop ctl.restart zygote =="
z1=$(pidof zygote64)
setprop ctl.restart zygote
echo "setprop_exit=$?"
sleep 6
z2=$(pidof zygote64)
echo "zygote64: $z1 → $z2"
if [ "$z2" = "$z1" ]; then
  echo "setprop 未生效（可能被 SELinux 拒绝），回退等价手段：kill 主 zygote 让 init 重拉"
  kill -9 "$z2" 2>/dev/null && echo "killed zygote64 $z2"
else
  echo "setprop 生效：框架正在重建，屏幕会黑 20–40 秒，内核不重启。"
fi
echo "[$(date "+%F %T")] softreboot: $z1 -> $(pidof zygote64)" >> "$ACTLOG"
echo
echo "恢复情况已写入：$REPORT（45 秒后采样）；也可下次点 action 时先看这里。"
