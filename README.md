# LSP-Fix · Xposed Guard

真机排障与运维仓库：**Xiaomi 2608BPX34C（lhasa）/ HyperOS OS4.0.21.0.XPNCNXM / Android 17 /
KernelSU 32601 + Zygisk Next 1.5.0(843) + Vector 2.2(3080)**。

解决两件事：

1. **「软重启之后 Vector（Xposed 框架）挂不上」** —— 反复软重启、用隐藏模块刷新模块都没用；
2. **「ZygiskNext 报模块导致崩溃」** —— 红标消不掉。

并把它背后的**根因、逐条证据、恢复手法**与**一个带 action 按钮的 KernelSU 运维模块**固化在本仓库。

> 姊妹项目：[XRingO3SceneLP](https://github.com/AbelDuan/XRingO3SceneLP)（同机的 Scene O3 调度方案）

---

## 0. 一个问题一个答案

| 你看到的现象 | 真实原因 | 怎么处置 |
|---|---|---|
| 软重启后 Vector 模块在跑、但框架不生效 | Vector 守护进程**只在内核开机阶段**由模块 `service.sh` 启动；软重启只换 zygote/system_server，守护进程与新一代 zygote **世代错位**，新 system_server 取不到框架 DEX 与 IPC binder | 以模块目录为工作目录、**正常模式**重启 `vectord` → Vector 自行重启一次框架后注入成功（本模块 action 自动判定 + 执行） |
| ZN 报「模块存在问题：Vector 出现在 vectord 的崩溃线程回溯中」 | ZN 的**崩溃归因**：zygote 死亡后它扫前 1 分钟墓碑，谁出现在崩溃栈里就算谁的问题。本例是 `vectord` 自己崩（`StackOverflowError: stack size 991KB`，Vector 2.2 的缺陷） | 该标记是 **zygiskd 会话内粘性**记录，外部无法清除，**下次完整开机**重算；**不影响功能** |
| ZN 显示 `STOP_BY_CRASH` / `STOP_BY_USER`（注入停止） | ZN 的 Zygote 监视器检测到 zygote 反复重启会**自动停用**，Zygisk 注入随之停止 | 到 ZN 网页 dashboard 重新开启 Zygote Monitor |
| **App 全部打不开、来电不显示** | **本仓库复现过的自伤**：运行中重启 `zygiskd` 打断 zygote↔daemon 的 fd 通道 → 每次 fork 断言 `'!(fd != -1)'` → 进程 abort | **只有框架级软重启 / 完整开机可恢复**，详见[事故报告](docs/incident-2026-09-29-zygote-fd.md) |

---

## 1. 交付物：Xposed Guard 模块

### 1.1 文件

| 文件 | 作用 |
|---|---|
| `module.prop` | KernelSU 模块元信息 |
| `action.sh` | **action 按钮**：显示 ZygiskNext / Vector / system_server / zygote 状态；仅当判定不健康时才恢复 Vector 守护进程 |
| `zn_restart.sh` | ⚠ **危险**：重启 zygiskd（曾用于尝试清 ZN 红标）。**2026-09-29 实测会让 App 全部无法启动**，现已默认拒跑，需显式加 `--i-understand-the-risk` |

### 1.2 安装

```sh
D=/data/adb/modules/xposed_guard
mkdir -p $D
cp module.prop action.sh zn_restart.sh $D/
chmod 755 $D/action.sh $D/zn_restart.sh
```

装完在 KernelSU 管理器里重开一次模块页即可看到卡片与 **action** 按钮（`action.sh` 存在即出现）。

### 1.3 action 输出（实测样例）

```
===== 系统 =====
system_server : 1362
zygote64      : 1080
内核 uptime   : 11950 秒（不归零=内核没重启）

===== ZygiskNext =====
版本/root      : 1.5.0-843-5217106-release  |  ✅KernelSU (32601)
Zygisk 注入    : 1  -> RUNNING（Zygisk 注入正常）
Zygote 监视器  : 1 个  |  首个: 注入=RUNNING pid=1080
denylist 策略  : 0  -> DISABLED
模块(64/32)    : 3,zygisk_vector,hma_oss_zygisk,zygisk-sui  /  同名 32 位
问题模块       : 1 个
   · zygisk_vector  issue类型=3  崩溃进程=vectord      ← @766563746f7264 自动 hex 解码
   ^ 崩溃归因存档：会话内粘性，不代表此刻仍在崩；只有 zygiskd 全新启动（完整开机）才重算
提示           : 若注入显示 STOP_BY_CRASH/STOP_BY_USER，去 ZN 网页 dashboard 重开 Zygote Monitor

===== Vector =====
守护进程 vectord : pid=973
工作目录         : /data/adb/modules/zygisk_vector
-- 最近注入事件（末 6 条）--
… Got system server binder via serial on attempt 1.
… Successfully injected Vector IPC binder for applications.
-- 判据：最后一条关键事件 --
… Successfully injected …
```

### 1.4 判定规则（健康时**绝不动手**，避免白挨重启）

| 判定 | 条件 | 动作 |
|---|---|---|
| 健康 | `vectord` 在位 + 工作目录 = `/data/adb/modules/zygisk_vector` + 最新日志最后一条关键事件是 `Successfully injected` | 只报告，**零动作** |
| 正在自愈 | 最后事件是 `Restarting system_server` 且该日志 120 秒内更新过 | 提示等 1–2 分钟，**不动手** |
| 需要恢复 | 守护进程缺失 / 工作目录错误 / 最后事件是 `Failed to inject` | 重启守护进程 → 最长 60 秒轮询到注入成功 → 再报状态 |
| 异常 | 无 system_server 或无日志 | 提示稍后再点，不动手 |

恢复动作本身（与模块 `service.sh` 开机时做的事一致，仅少了 mount namespace 包装）：

```sh
cd /data/adb/modules/zygisk_vector
setsid /system/bin/app_process -Djava.class.path=$PWD/daemon.apk /system/bin \
    --nice-name=vectord org.matrix.vector.daemon.VectorDaemon \
    --system-server-max-retry=3 >/dev/null 2>&1 &
```

---

## 2. ⚠️ 禁止清单（每一条都是踩出来的）

1. **不要在运行中重启 `zygiskd`**（不要 `zygiskd exit`，也不要跑 `zn_restart.sh`）：会打断 zygote↔daemon 的 fd 通道，**App 全部无法启动**，只能靠框架级软重启/完整开机救回。见[事故报告](docs/incident-2026-09-29-zygote-fd.md)。
2. **不要给 Vector 守护进程加 `--late-inject`**：它把 proxy 换成 `serial_vector`，实测让 fork 侧 binder 全败（`Failed to get system server binder via serial` ×10）。
3. **启动 `vectord` 必须 `cd` 到模块目录**：否则按相对路径找不到 `framework/vector.dex` 与 `bin/dex2oat*`，而根目录是只读 erofs，补不了软链。
4. **不要删 `/data/tombstones` 来"清 ZN 红标"**：ZN 不按需重算，只会毁掉崩溃证据。
5. **不要指望重启 Vector 守护进程能清 ZN 红标**：实测无效（ZN 自己的报告写着 `no relevant tombstone frame found`，标记仍在）。
6. 不要执行 `setprop ctl.restart adbd`（本机已知会永久断掉 adbd）；`ctl.restart zygote` 在本机被 SELinux 拒绝（`avc: denied { set } for property=ctl.restart$zygote`），软重启要用"结束主 zygote"的方式。

---

## 3. 实测记录（2026-09-29）

| 时间 | 事件 | 结果 |
|---|---|---|
| 18:16 | 首次尝试修 Vector（漏 `cd`，CWD=`/`） | 守护进程起得来但发不出 DEX → Vector 自愈杀 system_server ×3 |
| 18:36 | 第二次尝试（`cd` 正确 + `--late-inject`） | late-inject 换 proxy 致 fork 侧全败 → 又杀 ×3 |
| 18:46 | 第三次（`cd` 正确 + 正常模式） | **1 次框架重启后注入成功**：`Got system server binder on attempt 1` + `Successfully injected`，system_server 内开始装载 16 个模块 |
| 19:21 | 跑 `zn_restart.sh` 清 ZN 红标 | 红标 `1→0` ✓、**未触发重启** ✓，但 `zygote_states` 由 1 变 0（新守护进程不接管已在运行的 zygote） |
| 19:31–19:43 | **事故**：App 全部无法启动（电话打不开、来电不显示） | 每次 fork 报 `Abort message: '!(fd != -1)'`，dropbox 被 `system_app_native_crash` 刷屏 |
| 19:33 | 补跑 `zygiskd service-stage` | ❌ 无效（无法接管运行中的 zygote；ZN 无 adopt/re-inject 命令） |
| 19:44 | 获用户授权：按 `daemon → service-stage → 结束主 zygote` 的顺序做框架级软重启 | **恢复**：ZN `zygote_states:1`、红标 0、`inject_state:1`；Vector 于 19:44:49/19:44:53 自行注入成功；`com.android.phone` 正常；`!(fd != -1)` 零新增 |
| 20:25 | 复核 | 一切正常；本仓库建立 |

---

## 4. 环境与版本

- 机型：Xiaomi 2608BPX34C（`lhasa`），Android 17，HyperOS `OS4.0.21.0.XPNCNXM`，内核 `6.18.21-android17-5-g284297031c53`
- Root：KernelSU `32601`
- Zygisk 基座：Zygisk Next `1.5.0 (843-5217106-release)`
- Xposed：Vector `v2.2 (3080)` —— **上游最新即此版本**（`JingMatrix/Vector` 的 `update.json`），无更新可打
- 已知上游缺陷：`vectord` 以 `StackOverflowError: stack size 991KB`（binder 事务内）崩溃，ZN 会把它归因到 Vector 模块（红标来源）

---

## 5. 文档索引

- [docs/rca-vector-mount.md](docs/rca-vector-mount.md) —— Vector 软重启后挂不上的完整 RCA 与恢复配方
- [docs/rca-zygisknext-badge.md](docs/rca-zygisknext-badge.md) —— ZN 状态字段语义、崩溃归因、粘性红标、命令面盘点
- [docs/incident-2026-09-29-zygote-fd.md](docs/incident-2026-09-29-zygote-fd.md) —— **事故报告**：运行中重启 zygiskd 打断 fd 通道，App 全崩与恢复
- [CHANGELOG.md](CHANGELOG.md)

---

## 6. 免责与代价说明

- 本模块的 action 在**判定需要恢复**时会重启 Vector 守护进程；**Vector 自身会重启一次 Android 框架（system_server）**（内核不重启，`uptime` 不归零）。这是 Vector 的设计，不是本模块在重启设备。
- `zn_restart.sh` 已知会破坏 zygote↔daemon 通道，**仅在任何时刻都能接受一次完整开机的前提下**才允许复现，且默认拒跑。
- 所有恢复操作都需要 root；本仓库不含任何遥测、不含网络请求。