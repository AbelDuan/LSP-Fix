# Vector 软重启实现（源码级提取 + 本机实测）

对象：Vector v2.2 (3080) · 仓库 [JingMatrix/Vector](https://github.com/JingMatrix/Vector)（GPL-3.0）

## 1. 一句话

Vector 的「软重启」= **用 init 的 `ctl.restart` 机制重启「主 zygote」**——不是重启设备，也不是重启 system_server。

## 2. 源码

`daemon/src/main/kotlin/org/matrix/vector/daemon/VectorDaemon.kt:244`

```kotlin
fun softReboot() {
  Log.w(TAG, "Soft reboot: restarting the primary zygote")
  SystemProperties.set("ctl.restart", "zygote")
}
```

同文件 249–258 行的孪生函数（极易混淆）：

```kotlin
fun restartSystemServer() {
  Log.w(TAG, "Restarting system_server...")
  val restartTarget = if (64bit && 32bit) "zygote_secondary" else "zygote"
  SystemProperties.set("ctl.restart", restartTarget)
}
```

它只重启**次** zygote，让 system_server 重新 fork（日志里的 `Restarting system_server...` 就是它）。

源码注释（原文）：

> `system_server` is forked from the *primary* zygote, so restarting that is what restarts the framework — on a 64/32 device the primary init service is still called `zygote` (it runs app_process64) and `zygote_secondary` is the 32-bit one. Restarting the secondary leaves system_server running, which is right for `restartSystemServer`'s own purpose and wrong for this one; they are separate functions for that reason.

## 3. 调用链（管理器 → 守护进程 → init）

| 层 | 文件:行 | 内容 |
|---|---|---|
| UI | `manager/.../ui/components/PackageActionMenu.kt:159` | 装完模块后确认框 → `daemon.softReboot()` |
| UI | `manager/.../ui/screens/modules/ScopeViewModel.kt:778` | 改作用域后 `softRebootForFramework()` |
| 客户端 | `manager/.../ipc/DaemonClient.kt:310` | `suspend fun softReboot(): Result<Unit> = runIpc { it.softReboot() }` |
| 接口 | `services/manager-service/src/main/aidl/org/matrix/vector/ipc/IManagerService.aidl:626` | `void softReboot();` |
| 服务端 | `daemon/.../ipc/ManagerService.kt:317` | `override fun softReboot() = VectorDaemon.softReboot()` |
| 实现 | `daemon/.../VectorDaemon.kt:246` | `SystemProperties.set("ctl.restart", "zygote")` |

## 4. 等价命令（不依赖管理器 UI）

```sh
setprop ctl.restart zygote             # 主 zygote 换代 = 框架重建（Vector 的「软重启」）
setprop ctl.restart zygote_secondary   # 仅次 zygote 换代（Vector 自救那条；system_server 会重新 fork）
```

前提：调用域能写 `ctl.restart` 属性。非特权域会被 SELinux 拒（`avc: denied { set } for property=ctl.restart$zygote`）；
Vector 的 daemon 跑在特权域，因此它调用总能成功。

## 5. 本机实测（2026-09-30 16:14）

| 时点 | zygote64 | system_server | vectord | 内核 uptime | Vector 注入 |
|---|---|---|---|---|---|
| 执行前 16:14:17 | 30010 | 30167 | 11459 | 连续 | —— |
| 执行后 16:17:54 | **16532** | **16688** | **11459（不变）** | **59573s 连续（内核未重启）** | 16:14:19 `Got system server binder via serial on attempt 1` → 16:14:23 `Successfully injected Vector IPC binder for applications` |

ZN 侧同时 `zygote_states:1`（已接管新 zygote）、`inject_state:1`；`com.android.phone` 正常。

## 6. 为什么它比「重启守护进程」可靠

- 软重启只换 zygote/system_server，**守护进程 vectord 不动**（世代不换）；
- 新框架起来时，daemon 的桥接与模块 fd 通道正是它自己建立的那套 → fork 注入一次成功；
- 对照：手动重启 daemon 会打断 zygote↔daemon 的 fd 通道（见 [事故报告](incident-2026-09-29-zygote-fd.md)），把 App 全部打不开。

## 7. RCA 修正

「软重启后 Vector 挂不上」的正解 = **再软重启一次 zygote（本方案）**，而不是重启守护进程。
重设守护进程只应作为最后手段，且其代价与风险见事故报告。

## 8. 本仓库的用法

Xposed Guard 模块的 action 按钮已改为本方案（先打印状态，再执行；3 分钟防连点锁；前后采样写入
`/data/adb/modules/xposed_guard/last_softreboot.txt`）。旧方案备份：`legacy/action-daemon-restart.sh`。
