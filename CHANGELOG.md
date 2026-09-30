## v1.4 (2026-09-30)

- feat(action): action 改为 Vector 式软重启（setprop ctl.restart zygote，等价 VectorDaemon.kt:244 softReboot）；先打印 ZN/Vector 状态、3 分钟防连点锁、前后采样写入 last_softreboot.txt
- docs: 新增 docs/vector-soft-reboot-implementation.md（源码级提取 + 调用链 + 实测 + RCA 修正）
- chore(legacy): 旧方案（重启守护进程）备份到 legacy/action-daemon-restart.sh 与 legacy/zn_restart.sh
- fix(rca): 修正「挂不上」首选恢复手段——应为软重启主 zygote，而非重启守护进程

# Changelog

遵循 Conventional Commits 风格的条目；版本号与本机 KSU 模块 `module.prop` 一致。

## v1.3 (2026-09-29) — 事故后加固

- **fix(zn_restart): 默认拒跑**。新增硬闸 `--i-understand-the-risk`，脚本头部注明
  2026-09-29 事故（运行中重启 zygiskd 打断 zygote↔daemon 的 fd 通道 → App 全部无法启动，
  需框架级软重启/完整开机恢复）与恢复条件。
- **docs: 新增事故报告与两份 RCA**（Vector 挂不上 / ZN 红标），补全证据链与恢复配方。
- **docs(README): 禁止清单**（6 条），把踩过的坑固化为团队规则。
- 功能保持不变：`action.sh` 判定规则与恢复动作与 v1.2 一致。

## v1.2 (2026-09-29)

- feat(zn_restart): 新增实验性 `zn_restart.sh`，用于尝试免重启清除 ZN 崩溃归因红标。
  > 结果与代价：红标 `1→0`、未触发重启；但 `zygote_states 1→0`，随后（v1.2 使用后）暴露
  > App 全部无法启动的事故。见 v1.3 的加固与 docs/incident-2026-09-29-zygote-fd.md。
- feat(action): ZN 状态段落新增 `issue类型`/`崩溃进程名` 的 hex 解码与提示行。

## v1.1 (2026-09-29)

- feat(action): ZygiskNext 状态人类可读化 —— `Zygisk 注入 1 -> RUNNING`、
  `Zygote 监视器`、`denylist 策略 0 -> DISABLED`、`问题模块` 归因展示，
  并注明"崩溃归因是会话内粘性记录，不代表此刻仍在崩"。
- fix(action): 修正 `pidof zygote` 取不到（真身是 `zygote64`）导致的空判据。

## v1.0 (2026-09-29)

- feat: 首个版本。KernelSU 模块 `xposed_guard`：
  - `action.sh`：显示 ZygiskNext / Vector / system_server / zygote 状态；
    仅在判定不健康时恢复 Vector 守护进程（`cd` 模块目录 + 正常模式 + `--system-server-max-retry=3`）；
    健康时零动作、自愈中不动手、带 3 分钟锁防止重复恢复。
  - `module.prop`：模块元信息（`action.sh` 存在即出现 action 按钮）。
  - `README.txt`：使用说明与边界。
