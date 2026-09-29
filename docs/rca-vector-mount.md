# Vector 在软重启后"挂不上"的 RCA 与恢复配方

对象：**Vector v2.2 (3080)**，模块目录 `/data/adb/modules/zygisk_vector`，依赖 Zygisk Next 1.5.0。

---

## 1. 现象

- 软重启（框架重启 / zygote 重启）之后，Vector 的**系统服务注入失败**：
  模块列表里像在跑，但框架实际未生效；管理器显示未激活/需修复。
- 反复软重启无效；用隐藏类模块"刷新模块"再软重启也无效。

## 2. 证据链（Vector 自己的日志，`/data/adb/lspd/log/verbose_*.log`）

一次典型的失败世代（2026-09-29 17:20，用户软重启之后）：

```
17:20:47.689 E/VectorNative : DEX fetch transaction failed.
17:20:47.689 E/VectorNative : Failed to fetch framework DEX for system_server.
17:20:48.191 I/VectorDaemon : `activity` service not ready, waiting 1s...      ×4
17:20:51.818 I/VectorNative : System server process detected. Marking for injection.
17:20:51.923 W/VectorNative : Failed to get system server binder via serial, will retry in 1 second...
   …（每秒一次，共 10 次）
17:21:01.942 E/VectorNative : Failed to get system server binder after 10 attempts. Aborting.
17:21:01.942 E/VectorNative : Failed to get system server IPC binder. Aborting injection.
17:21:06.212 W/VectorDaemon : No response from bridge, retrying...
17:21:09.213 E/VectorDaemon : Failed to inject VectorService into system_server
17:21:09.213 W/VectorDaemon : Restarting system_server...
```

一次成功的世代（2026-09-29 19:44，框架重启之后）：

```
19:44:49.280 I/VectorNative : Got system server binder via serial on attempt 1.
19:44:53.647 I/VectorDaemon : Successfully injected Vector IPC binder for applications.
```

注入成功的功能级证据（同一 pid = system_server）：

```
18:46:18.419 VectorLegacyBridge : Loading legacy module com.omarea.vtools (Scene) → XposedInterface
18:46:18.431 VectorLegacyBridge : Loading legacy module io.github.sothx.FixHyperMagicWindowCloudConfig → MainHook
18:46:18.431 VectorLegacyBridge : Loading legacy module cn.myflv.noactive → core.HandleHook
18:46:19.569 VectorModuleManager: Loading module com.sevtinge.hyperceiler … Loaded successfully.
```

## 3. 根因

1. **守护进程只在内核开机阶段启动**：模块 `service.sh` 里
   `unshare --propagation slave -m "$MODDIR/daemon" --system-server-max-retry=3 &`，
   而 KSU 只在 post-fs-data / service 阶段跑模块脚本。
   ⇒ 软重启（zygote/system_server 换代）**不会重启守护进程**，两者世代错位。
2. 新的 system_server fork 时，zygote 侧要向守护进程取框架 DEX；system_server 侧要凭
   "serial" 从守护进程取 IPC binder。世代错位后两条路都断，10 次重试后 Vector 放弃注入。
3. **Vector 的自救是"杀掉 system_server 重来"**，预算由 `--system-server-max-retry` 控制（模块给的是 3）。
   ⇒ 守护进程与 zygote 世代不一致时，会看到连续多次框架重启。
4. **`--late-inject` 不是解药**：该模式把 proxy 从 `serial` 换成 `serial_vector`，
   实测导致 fork 侧 binder 拿不到（`Got system server binder … ` 变为全败），反而更糟。

## 4. 恢复配方（免内核重启，已验证）

```sh
# 1) 结束旧守护进程
for p in $(pidof vectord); do kill "$p"; done; sleep 3
for p in $(pidof vectord); do kill -9 "$p"; done; sleep 1

# 2) 以模块目录为工作目录、正常模式启动（不要加 --late-inject）
cd /data/adb/modules/zygisk_vector
setsid /system/bin/app_process -Djava.class.path=$PWD/daemon.apk /system/bin \
    --nice-name=vectord org.matrix.vector.daemon.VectorDaemon \
    --system-server-max-retry=3 >/dev/null 2>&1 &

# 3) 等它自愈：Vector 会先杀一次当前 system_server，新 fork 那代成功后注入
```

**预期代价**：**1 次框架重启**（system_server 换代，内核不重启，`uptime` 不归零）。

**验收判据**（三条都满足才算成功）：

1. 日志出现 `Got system server binder via serial on attempt 1.`
2. 日志出现 `Successfully injected Vector IPC binder for applications.`
3. system_server 进程里出现模块装载记录（`VectorLegacyBridge: Loading legacy module …`）

`zygiskd status` 里 `modules_with_issue` **不会**因本操作变化（见
[ZN 红标 RCA](rca-zygisknext-badge.md)）。

## 5. 关键陷阱

| 陷阱 | 后果 | 正确做法 |
|---|---|---|
| 启动时没 `cd` 到模块目录 | daemon 按相对路径找不到 `framework/vector.dex`、`bin/dex2oat*`（根是只读 erofs）→ 注入失败并杀 system_server | 必须 `cd /data/adb/modules/zygisk_vector` |
| 用 `--late-inject` | proxy 变 `serial_vector`，fork 侧 binder 全败 | 用正常模式 |
| 守护进程崩溃不处理 | `vectord` 会以 `StackOverflowError: stack size 991KB` 崩（Vector 2.2 缺陷），ZN 会把红标记到 Vector 头上 | 向 `JingMatrix/Vector` 报上游；或等修复版本 |

## 6. 上游状态

`https://raw.githubusercontent.com/JingMatrix/Vector/master/zygisk/update.json`

```json
{ "version": "v2.2", "versionCode": 3080, "zipUrl": "…/Vector-v2.2-3080-Release.zip" }
```

⇒ 本机装的 `v2.2 (3080)` **即上游最新**，没有"升级就好了"这条路；`vectord` 的栈溢出属上游缺陷。
