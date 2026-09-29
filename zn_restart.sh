#!/system/bin/sh
# =============================================================================
# ⚠ 实验性工具：重启 ZygiskNext 守护进程，用于尝试清除 ZN 的"崩溃归因"红标
#   （modules_with_issue）。红标是 zygiskd 会话内的粘性记录，只有 zygiskd
#   全新启动才会重算；本脚本用与开机阶段相同的命令把它重新拉起。
#
#   ⚠⚠ 已验证的事故（2026-09-29）：运行中重启 zygiskd 会打断 zygote↔daemon 的 fd 通道。
#      症状：所有新进程 fork 时 abort —— `Abort message: '!(fd != -1)'`，
#            backtrace 落在 hma_oss_zygisk / libzygisk.so / Zygote.forkAndSpecialize；
#            手机表现「App 全部打不开、来电不显示」，且 ZN 没有 adopt/re-inject 命令，
#            补跑 service-stage 也无效 —— **只有框架级软重启 / 完整开机可恢复**。
#      时间线：19:21 执行本脚本 → 19:31~19:43 App 全崩 → 19:44 框架级软重启后恢复。
#      详见仓库文档 docs/incident-2026-09-29-zygote-fd.md。
#
#   因此本脚本默认【拒绝执行】，必须显式声明风险：
#       sh zn_restart.sh --i-understand-the-risk
#
#   其它代价：
#     · 即使执行，ZN 红标清除也不影响任何功能（inject_state=1 即注入正常）；
#     · 本脚本会先把 ZN 状态目录备份到 /data/local/tmp/zn_backup_<时间戳>/。
#   本脚本不会被 action.sh 调用，也不会开机自动执行。
# =============================================================================
if [ "$1" != "--i-understand-the-risk" ]; then
  echo "拒绝执行：本脚本 2026-09-29 实测会让 App 全部无法启动（打断 zygote↔daemon 的 fd 通道），"
  echo "          且只有框架级软重启 / 完整开机才能恢复。"
  echo "          红标本身不影响功能，建议等下一次完整开机自然重算即可。"
  echo "          如确要复现（必须能接受一次完整开机）：sh zn_restart.sh --i-understand-the-risk"
  exit 1
fi

ZNMOD=/data/adb/modules/zygisksu
LOG=/data/local/tmp/xposed_guard.log
BK=/data/local/tmp/zn_backup_$(date +%Y%m%d-%H%M%S)

echo "===== ZN 守护进程重启（实验性）====="
echo "风险提示：若重启失败，Zygisk 注入会停摆到下次完整开机。"
echo

echo "== 0. 现行状态 =="
"$ZNMOD/bin/zygiskd" status 2>/dev/null | grep -E "inject_state|zygote_states|modules_with_issue|modules64"
echo

echo "== 1. 备份 =="
mkdir -p "$BK"
cp -a /data/adb/zygisksu/. "$BK"/ 2>/dev/null
cp -f "$ZNMOD/module.prop" "$BK/module.prop" 2>/dev/null
echo "已备份到 $BK"
echo

echo "== 2. 请求旧守护进程退出 =="
"$ZNMOD/bin/zygiskd" exit 2>&1 | head -5
sleep 5
echo "残留进程："
ps -A | grep -E "zygiskd|zn-daemon|zn-nsdaemon|zn-zygisk-companion" | head -10
echo

echo "== 3. 以开机相同方式重新启动 =="
cd "$ZNMOD" || { echo "错误：无法进入 $ZNMOD"; exit 1; }
setsid ./bin/zygiskd daemon >/dev/null 2>&1 &
sleep 6
echo

echo "== 4. 复核 =="
echo "-- 进程 --"
ps -A | grep -E "zygiskd|zn-daemon|zn-nsdaemon|zn-zygisk-companion" | head -8
echo "-- 状态 --"
"$ZNMOD/bin/zygiskd" status 2>&1 | grep -E "inject_state|zygote_states|zygote_state_0|modules_w.?ith_issue|modules64|modules32" | head -10
echo
echo "判读：inject_state=1 为正常；modules_with_issue 若消失即红标已清。"
echo "预期副作用：zygote_states 会变成 0 —— 新守护进程只登记它启动之后新起的 zygote，"
echo "  不接管已在运行的那一个，ZN 摘要里因此暂时不显示 ✅zygote。注入不受影响"
echo "  （注入代码已在 zygote 内存里，新应用照旧继承），下次框架重启/完整开机自动恢复登记。"
echo "实测记录（2026-09-29 19:21）：红标清除成功、未触发框架重启、Vector 未受影响。"
echo "若状态取不到或注入异常，请完整开机恢复（备份在 $BK）。"
echo "[$(date "+%F %T")] zn_restart executed (backup=$BK)" >> "$LOG"
