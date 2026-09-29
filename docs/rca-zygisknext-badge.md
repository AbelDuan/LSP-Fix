# ZN 红标与状态字段 RCA：`modules_with_issue` 到底是什么

对象：**Zygisk Next 1.5.0 (843)**，模块目录 `/data/adb/modules/zygisksu`。

---

## 1. 你看到的报错

KSU 管理器里 Zygisk Next 的页面弹窗：

```
模块存在问题
模块 Vector 出现在以下进程的崩溃线程回溯中：vectord。
                                        [导出 Bugreport]
Vector          ⚠导致崩溃   (32)(64)
```

同时 `zygiskd status` 里：

```
modules_with_issue:1,zygisk_vector=3@766563746f7264
```

## 2. 字段解码

| 片段 | 含义 |
|---|---|
| `1` | 有问题的模块数 |
| `zygisk_vector` | 被归因的模块 |
| `3` | issue 类型（枚举里的 `Crash`） |
| `@766563746f7264` | **崩溃进程名的 hex**：`766563746f7264` → `vectord` |

ZN 的判定逻辑（从它的 `bugreports/*.txt` 与 `webroot` 前端代码反推）：

1. 监听 zygote 死亡；
2. 死亡后**往前扫 1 分钟的 tombstone**；
3. 若某 tombstone 的崩溃线程回溯里出现某个模块的路径（如
   `frame=/data/adb/modules/zygisk_vector/daemon.apk]`），就把该模块记为 `Crash` issue，
   并写进 `module.prop` 的 `description`（KSU 列表里显示的那段）。

ZN 自己的报告原文（`/data/adb/zygisksu/bugreports/20260929-172047-zygote-2002.txt`）：

```
zygote=zygote pid=2002 abi=64 status=0x9 signaled with KILL(9)
scan_window=1m report_time=20260929-172047
memory_type=0 temporary_switch_to_default=1
[tombstone] /data/tombstones/tombstone_14
timestamp=2026-09-29 17:20:02.692 signal=signal 11 (SIGSEGV), code 2 (SEGV_ACCERR)
cmdline=vectord app_name=vectord
modules=zygisk_vector
frame=/data/adb/modules/zygisk_vector/daemon.apk]
abort='JNI FatalError called: java.lang.Error thrown during binder transaction: java.lang.StackOverflowError: stack size 991KB'
```

`temporary_switch_to_default=1` = ZN 在被归因后**临时把模块全部切掉**（这是"挂不上"的 ZN 侧机制之一）。

## 3. 崩溃的其实是 vectord 自己

2026-09-29 当天 vectord 崩了 6 次，签名逐字节相同（Cmdline 已逐条核对，不是"日志里提到"）：

```
tombstone_03  17:12:00.98  cmdline=vectord  SIGSEGV(SEGV_ACCERR)  StackOverflowError 991KB
tombstone_08  17:14:17.07  cmdline=vectord  同签名
tombstone_12  17:17:33.05  cmdline=vectord  同签名
tombstone_14  17:20:02.69  cmdline=vectord  同签名
tombstone_17  17:20:47.09  cmdline=vectord  同签名
（前一日 00:01 一次同签名）
```

即：`vectord`（Vector 2.2 的守护进程）在 **binder 事务里栈溢出**（991KB 栈打爆），
崩溃帧落在 `zygisk_vector/daemon.apk` 内 → ZN 归因给 Vector 模块。
**这是 Vector 2.2 的缺陷，不是 Vector 把系统搞崩。**

## 4. 为什么这个红标"清不掉"

- **粘性**：18:46 恢复注入成功后，ZN 自己的报告写 `no relevant tombstone frame found in the
  last 1 minute`（近 1 分钟无相关墓碑），但 `modules_with_issue` **仍然在** →
  该标记不按需重算，是 **zygiskd 会话内的粘性记录**。
- **没有清除命令**：ZN 网页（跑在 KSU WebUI 桥上的 JS）调后端只有这些命令：

  ```
  zygiskd <status> / denylist-policy / enforce-denylist / linker / memory-type
  模块自带 emulated-soft-reboot.sh = `zygiskd exit`
  ```

  没有 `reset` / `clear` / `ack` / `monitor` 之类的命令。
- **删墓碑无效**：标记已在 daemon 内存里，删 `/data/tombstones` 只毁证据。
- **重启 Vector 守护进程无效**：已实测。
- **重启 zygiskd 有效但危险**：只有 zygiskd 全新启动（完整开机）会重算。
  运行中重启 zygiskd 会打断 zygote↔daemon 通道 → App 全崩，见
  [事故报告](incident-2026-09-29-zygote-fd.md)。

**结论**：红标 = 历史记录 + 会话粘性。它**不影响功能**（判据：`inject_state:1` 即注入正常），
只会在下一次完整开机后消失；只要 vectord 不再崩，就不会再出现。

## 5. ZN 的状态字段语义（从它的前端代码解出枚举）

```
inject_state:  1=RUNNING   2=STOP_BY_USER   3=STOP_BY_CRASH        （zygote 注入状态）
denylist_policy: 0=DISABLED  1=ENFORCED  2=JUST_UMOUNT
zygote_states:  N（被监视的 zygote 条目数）
zygote_state_0: <注入状态>,<...>,<pid>,<名称>,<...>
```

配套文案（ZN 自己的 UI 字符串，英文原文）：

```
"Zygote Monitor is running normally."
"Zygote Monitor stopped by user."
"Repeated restarts of Zygote has been detected, Zygote Monitor has automatically [stopped]"
"But Zygisk injecting was stopped due to multiple previous soft reboots of the [device]"
```

⇒ **反复软重启会让 ZN 自动停掉 Zygote 监视器，Zygisk 注入随之停止**——这才是"挂不上"在 ZN 侧
真正可恢复的一环。恢复入口：ZN 网页 → dashboard → `Zygote Monitor`。

## 6. 一句话总结

| 层 | 性质 | 能否清 | 影响功能 |
|---|---|---|---|
| `模块存在问题 / 导致崩溃`（崩溃归因） | 历史存档·会话粘性 | 否（只能等完整开机） | **否** |
| `inject_state = 2/3`（监视器停用） | 实时状态 | 是（ZN 网页重开 Zygote Monitor） | **是** |
