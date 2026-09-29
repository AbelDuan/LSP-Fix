# 事故报告：运行中重启 zygiskd 打断 zygote↔daemon 通道，App 全部无法启动

- 日期：2026-09-29
- 机型：Xiaomi 2608BPX34C（lhasa）/ Android 17 / HyperOS OS4.0.21.0.XPNCNXM
- 组件：Zygisk Next 1.5.0 (843) + Vector 2.2 (3080) + KernelSU 32601
- 触发动作：`zn_restart.sh`（= 备份 → `zygiskd exit` → `./bin/zygiskd daemon`）
- 影响：**所有新进程无法 fork**，电话 App 打不开、来电不显示；仅框架级软重启/完整开机可恢复
- 结论：**不要在运行中重启 zygiskd**；`zn_restart.sh` 已改为默认拒跑

---

## 1. 时间线

| 时间 | 事件 |
|---|---|
| 19:21 | 执行 `zn_restart.sh`：`zygiskd exit` → `zygiskd daemon` |
| 19:21 | ✅ 红标 `modules_with_issue: 1 → 0`；✅ 未触发框架重启；⚠️ `zygote_states: 1 → 0` |
| 19:31–19:43 | ❌ 用户报告电话 App 打不开、来电不显示；dropbox 被 `system_app_native_crash` 刷屏 |
| 19:33 | 尝试补跑 `zygiskd service-stage`（ZN 开机的第二阶段）→ **无效**，`zygote_states` 仍 0，abort 继续 |
| 19:44 | 获用户授权，按 `daemon → service-stage →（结束主 zygote）` 顺序执行框架级软重启 |
| 19:44 | ✅ 恢复：ZN `zygote_states:1`（`zygote_state_0: 1,0,12595,zygote,0`）、红标 0、`inject_state:1`；Vector 于 19:44:49/19:44:53 注入成功；`com.android.phone` 正常运行 |
| 19:44+ | `Abort message: '!(fd != -1)'` 零新增（最后一条停在 19:43:39，即重启前） |

## 2. 症状与证据

崩溃缓冲（`logcat -b crash`）：

```
Abort message: '!(fd != -1)'
backtrace:
  #01 pc … /data/adb/modules/hma_oss_zygisk/zygisk/arm64-v8a.so
  #02 pc … /data/adb/modules/zygisksu/lib64/libzygisk.so
  #03 … #06  libzygisk.so
  #07 art_jni_trampoline
  #08 com.android.internal.os.Zygote.forkAndSpecialize+260
  #09 com.android.internal.os.ZygoteConnection.processCommand
  #10 com.android.internal.os.ZygoteServer.runSelectLoop
  #11 com.android.internal.os.ZygoteInit.main+3460
```

dropbox 条目（同一签名，进程名各异 —— 都是**zygote fork 出来的子进程在 specializes 阶段 abort**）：

```
19:31 system_app_native_crash   Process: com.xiaomi.phone            Cmdline: zygote64
19:31 system_app_native_crash   Process: com.miui.securitycore       Cmdline: zygote64
19:31 system_app_native_crash   Process: com.milink.crossdeviceservice  Cmdline: zygote64
19:33 crash buffer              Cmdline: usap64 / zygote64           Abort message: '!(fd != -1)'
```

即：**fork 路径整体不可用** → 任何 App（含电话、来电 UI）都起不来。
数据未受影响，仅进程无法创建。

## 3. 机理

1. 运行中的 zygote 里已加载 `libzygisk` 与各模块的 `.so`，并且**依赖守护进程提供的 fd /
   companion 通道**来完成每次 `forkAndSpecialize`。
2. 运行中把守护进程换掉后：
   - 新守护进程**无法接管已在运行的 zygote**（ZN 的监视器只登记"它启动之后新起的 zygote"，
     于是 `zygote_states:0`）；
   - 旧 companions/nsdaemons 绑在已退出的守护进程上 → 通道失效；
   - 于是每次 fork 取 fd 得到 `-1`，`LOG_ALWAYS_FATAL("!(fd != -1)")` 直接 abort。
3. ZN **没有** adopt / re-inject / reset 之类命令可用来补救（其命令面见
   [ZN RCA](rca-zygisknext-badge.md#4-为什么这个红标清不掉)），
   `service-stage` 也无法接管运行中的 zygote。
4. ZN 自带的 `emulated-soft-reboot.sh` 只做 `zygiskd exit` —— 名字本身说明：
   **守护进程退出后必须让 zygote 重来**（即需要框架级重启/完整开机）。

## 4. 恢复配方（需与用户确认；本机已实测）

```sh
# ① 清理旧一代 ZN 进程（守护 / nsdaemon / companion）
for p in $(ps -A | grep -E "zn-daemon|zn-nsdaemon|zn-zygisk-companion|zygiskd" | awk '{print $2}'); do kill -9 "$p"; done

# ② 按开机顺序重建 ZN（必须先于新 zygote 就位）
cd /data/adb/modules/zygisksu
setsid ./bin/zygiskd daemon >/dev/null 2>&1 &
sleep 5
setsid ./bin/zygiskd service-stage >/dev/null 2>&1 &
sleep 5

# ③ 触发框架级软重启（结束主 zygote，init 会自动拉起新的一代）
kill -9 $(pidof zygote64)
```

- **顺序是关键**：守护进程必须在新 zygote 出现之前就位，新的 zygote 才会被接管
  （本次恢复后 `zygote_states:1`）。
- 该操作会让框架整体重启（内核不动，`uptime` 不归零）；所有 App 会重启一次。
- ⚠ 本仓库不代替用户做重启决定；`ctl.restart zygote` 在本机被 SELinux 拒（`avc: denied { set }
  for property=ctl.restart$zygote`），故用"结束主 zygote"的方式。

## 5. 教训与现有防护

1. **"能清红标"不值得拿"App 全崩"去换**。红标本身不影响功能（`inject_state:1` 即正常）。
2. `zn_restart.sh` 已加硬闸：默认**拒绝执行**，必须显式
   `sh zn_restart.sh --i-understand-the-risk`，并在脚本头部注明本事故与恢复条件。
3. 任何"运行中替换框架相关守护进程"的操作，都要先问三个问题：
   - 它会不会让**已在运行**的 zygote 失去通道？
   - 有没有官方的 re-adopt / reset 入口？（ZN：没有）
   - 出事后的恢复手段是什么？需要几次重启？
4. 事故事后复核显示：**框架级软重启后 ZN 与 Vector 都能自行回到健康态**
   （ZN 由开机阶段脚本装配；Vector 的守护进程若在同世代内运行良好，也会在新 fork 上注入成功）。
