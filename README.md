# Handy · 剪贴板两段（写入 + 可见提示）

零 TCC：不碰 Accessibility / CGEvent，不申请任何权限。

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
