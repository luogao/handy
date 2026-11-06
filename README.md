# Handy · 三段（写入剪贴板 + 可见提示 + 麦克风录音）

前两段零 TCC；第 3 段只申请麦克风一项，不碰 Accessibility / 输入监控 / CGEvent。

## 第 1 段：写入剪贴板

`./handy-clip "文本"` 写入 `NSPasteboardTypeString`；首次写入前备份原剪贴板全部类型，`./handy-clip --restore` 还回去。

```bash
./handy/handy-clip "测试 中文，换行
第二行 🎤" && pbpaste
./handy/handy-clip --restore     # 回到写入前的内容
./handy/handy-clip --status      # 备份状态
```

- 备份位置：`~/Library/Caches/handy/clipboard-backup.plist`（0600），可用 `HANDY_CLIP_STATE_DIR` 覆盖。
- 退出码：成功 0；无参数 / 无备份 / 写入失败 1。无参数时 stderr 打 usage。
- 非选项参数按一个空格拼接；要保留换行就把整段文本作为一个参数传进来。

## 第 2 段：可见提示

先起常驻的菜单栏进程（出现 `mic.fill` 图标，关掉进程提示就没了）：

```bash
./handy/handy-menubar &
```

之后每次写入剪贴板，屏幕右上角出现 2 秒浮层：

```bash
./handy/handy-clip "测试 中文"     # 写剪贴板 + 弹提示
./handy/handy-hint --trigger       # 只弹提示，不碰剪贴板（测面板用）
./handy/handy-hint --sound off     # 关提示音（落盘，重启仍生效）
./handy/handy-hint --sound on
./handy/handy-hint --status        # 看当前设置
```

- 浮层是不抢焦点、不拦点击的非激活 `NSPanel`；连按只复用同一个面板并重置 2 秒计时，不会堆叠。
- 触发通道是 `DistributedNotificationCenter`；菜单栏进程没在跑时，`handy-clip` 的写入照常成功。
- 日志：`~/Library/Caches/handy/hint.log`（毫秒时间戳，含 `since_write_ms`），可用 `HANDY_LOG_DIR` / `HANDY_SETTINGS_DIR` / `HANDY_CLIP_STATE_DIR` 覆盖目录。
- 提示音开关：`~/Library/Application Support/Handy/settings.plist`（0600）。
- 选型：没用 `UNUserNotificationCenter` —— CLI 进程没有 app bundle / bundle id，注册通知中心要打包签名；改用 NSStatusItem + NSPanel，零权限、时长可控。
- 验收数据与截图见 [HINT.md](HINT.md)。

> 两个入口都是 `#!/usr/bin/env swift` 脚本，每次调用要现编译（约 0.6s）。演示/验收时如果要真正「连按」，可以 `swiftc -O` 预编译一份再调，行为一致。

## 第 3 段：麦克风录音

```bash
./handy/handy-mic --list            # devices(N)；无设备时 devices(0)，exit 0
./handy/handy-mic --record 3        # 录 3 秒到 ~/Library/Caches/handy/recordings/*.wav
./handy/handy-mic --hotkey          # 常驻：按住 ⌃⌥H 录，松开落盘
./handy/handy-mic --check           # 只注册热键、报告状态后退出（无设备也能验）
```

- 入口是 shell 包装：首次调用用 `swiftc` 把 `handy-mic.swift` 编译到 `handy/.build/`（约 2s），之后直接跑二进制。
- 先数设备再要权限：无设备时 `--record` / `--hotkey` 立刻 `exit 3` + `no audio input device`，不调用 `requestAccess`，不会卡 20 秒。
- 热键用 Carbon `RegisterEventHotKey`（⌃⌥H），不装 CGEventTap、不申请辅助功能 / 输入监控。
- 录音格式 16kHz / 单声道 / 16-bit PCM WAV；热键模式松手 <200ms 丢弃并提示，>60s 自动停。
- 退出码：0 成功；1 用法 / IO；3 无输入设备；4 麦克风权限被拒；5 热键注册失败。
- 本机没有麦克风，**录音本身没验过**，验收边界见 [SEG3.md](../../apps/handy/SEG3.md)。
