# 第 2 段验收记录

2026-11-04，Mac mini（Mac16,10 / M4），macOS 26.5。装置：`./handy/handy-menubar`（常驻）+ `./handy/handy-clip` / `./handy/handy-hint`。

日志：`~/Library/Caches/handy/hint.log`，ISO8601 带毫秒。`since_write_ms` = 收到触发时离写入时间戳的毫秒差；`after_ms` = 面板从首次显示到最后隐藏的时长。

## 1. 写入 → 提示 ≤ 200ms

真实链路（`handy-clip` 写剪贴板后发触发）：

```
11:45:13.119Z recv trigger=1 since_write_ms=1 sound=on text=已复制到剪贴板
11:45:13.119Z shown trigger=1 panel=1 visible_for=2.0s
```

交付前又用仓库里的脚本原样跑了一次：

```
11:47:50.806Z app_start pid=37048 sound_default=on
11:47:52.947Z recv trigger=1 since_write_ms=1 sound=on text=已复制到剪贴板
```

预编译的 `handy-hint` 连发 10 次，`since_write_ms` 分别 3/4/3/2/2/2/2/2/2/2 ms，最大 4ms。均远低于 200ms。

## 2. 提示持续可见 ≥ 1.5s

```
11:45:15.218Z hidden after_ms=2192 triggers=1 shown_sessions=1
11:45:38.052Z hidden after_ms=2096 triggers=1 shown_sessions=1
11:46:42.578Z hidden after_ms=3312 triggers=11 shown_sessions=2
```

前两条是单次触发（2.19s / 2.10s）；第三条是 10 连按后隐藏（从第一次按下起算 3.31s）。都 ≥1.5s。

## 3. 关提示音 → 重启仍静音

```
$ ./handy/handy-hint --sound off
sound=off
（ps 确认旧进程退出后重启）
11:45:35.573Z app_start pid=36906 sound_default=off settings=.../Handy/settings.plist
11:45:35.952Z recv trigger=1 since_write_ms=2 sound=off text=重启后提示
```

设置落在 `~/Library/Application Support/Handy/settings.plist`（0600）。测完已 `--sound on` 复位成默认有声音。

## 4. 连按 10 次：不崩、不堆叠

10 次调用在 1885ms 内发完（`swiftc -O` 预编译的 handy-hint；脚本模式每次现编译约 0.6s，行为一致）：

```
11:46:39.267Z recv trigger=2  ... text=连按第1次
...
11:46:40.476Z recv trigger=11 ... text=连按第10次
11:46:40.476Z shown trigger=11 panel=1 visible_for=2.0s
11:46:42.578Z hidden after_ms=3312 triggers=11 shown_sessions=2
```

10 次 `recv` / 10 次 `shown panel=1`，只有最后一次之后一条 `hidden`，`shown_sessions` 只加了 1（整段连续可见算一次）。进程存活：`ps -p 36906` → `01:08` uptime。截图 `hint-burst.png` 里只有一块浮层，文字是第 10 次的「连按第10次」；常规写入的浮层见 `hint-screenshot.png`。

## 5. 提示前后前台 app 不变

`osascript ... first application process whose frontmost is true`：连按前 `Google Chrome`，连按后 `Google Chrome`；单次触发同样保持 Chrome（最终那次：写入前 / 写入后均 `Google Chrome`）。浮层是 `canBecomeKey=false` + `.nonactivatingPanel`，`ignoresMouseEvents=true`。

## 6. 没申请任何权限

源码里没有 AX / CGEvent 调用，grep 命中的三处都是注释：

```
$ grep -nE 'AXUIElement|AXIsProcessTrusted|CGEvent|CGPreflight' handy/handy-* | grep -v '//'
（无输出）
```

运行期间无 TCC 弹窗。

## 局限 / 没验证的

- 只验了单屏；多屏时按鼠标所在屏放右上角，没实测。
- 可见时长固定 2.0s，没做可配置。
- 提示音用 `NSSound` 播系统 `Pop.aiff`，没测蓝牙耳机 / 输出设备切换。
- 没有 launchd 守护，进程被杀就没提示（`handy-clip` 仍能正常写入）。
