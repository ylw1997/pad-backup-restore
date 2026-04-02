# PAD 备份恢复工具

这个目录建议只保留下面这些必要文件：

- `pad-backup-restore.ps1`
- `运行-PAD备份恢复工具.cmd`
- 你自己创建出来的备份包 `.zip`

## 文件说明

### `pad-backup-restore.ps1`

单文件版 Power Automate Desktop 备份恢复工具。

支持：

- 备份本机指定自动化
- 从备份包恢复到本机指定自动化
- 自动列出本机可选 Flow ID
- 备份包默认保存在脚本所在目录

### `运行-PAD备份恢复工具.cmd`

双击入口。

平时直接双击这个文件即可，它会启动 `pad-backup-restore.ps1`。

## 使用方法

### 一、备份

1. 完全关闭 Power Automate Desktop。
2. 双击 `运行-PAD备份恢复工具.cmd`。
3. 输入 `1`，选择“备份自动化”。
4. 从列表中选择要备份的自动化。
5. 工具会在当前目录生成一个新的 `.zip` 备份包。

备份包命名格式：

```text
FlowId_yyyyMMdd_HHmmss.zip
```

### 二、恢复

1. 先在目标账号里新建一个空白自动化。
2. 保存后，完全关闭 Power Automate Desktop。
3. 双击 `运行-PAD备份恢复工具.cmd`。
4. 输入 `2`，选择“从备份包恢复”。
5. 先选择当前目录里的备份包。
6. 再选择要恢复到的目标 Flow ID。
7. 恢复完成后，打开 Power Automate Desktop，进入目标自动化并手动保存一次。

## 备份包内容

工具生成的备份包包含：

- `settings`
- `workspace`
- `full-package`
- `full-package.meta`
- `partial-package`
- `partial-package.meta`
- `manifest.json`

恢复时最关键的是：

- `full-package`
- `workspace`
- `settings`

## 注意事项

- 运行工具前必须关闭 Power Automate Desktop。
- 恢复前建议先新建一个空白自动化作为目标流。
- 刚新建的空流名称有时不在 `full-package`，而是在本地 `flowMetadata` 缓存里，工具已经兼容这种情况。
- 恢复完成后，建议立刻打开目标自动化并保存一次。
- 建议只保留已经验证可用的备份包，避免目录里备份包太多不好选。

## 推荐目录结构

```text
微信\
├─ pad-backup-restore.ps1
├─ 运行-PAD备份恢复工具.cmd
└─ 某个确认可用的备份包.zip
```

以后迁移到其他电脑时，直接复制整个文件夹即可。
