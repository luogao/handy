# Handy · 四段（写入剪贴板 + 可见提示 + 麦克风录音 + 转写）

前三段里只有第 3 段申请麦克风一项，其余零 TCC；全程不碰 Accessibility / 输入监控 / CGEvent。
第 4 段接在第 3 段后面：松手 → 分段转写 → 词典校正 → 剪贴板 → 提示，一条链跑完。

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
./handy/handy-mic --hotkey          # 常驻：按住 ⌃⌥H 录，松开转写并写剪贴板
./handy/handy-mic --check           # 只注册热键、报告状态后退出（无设备也能验）
./handy/handy-mic --file 录音.wav   # 跳过录音，直接跑后面的链路（见第 4 段）
```

- 入口是 shell 包装：首次调用用 `swiftc` 把 `handy-mic.swift` 编译到 `handy/.build/`（约 2s），之后直接跑二进制。
- 先数设备再要权限：无设备时 `--record` / `--hotkey` 立刻 `exit 3` + `no audio input device`，不调用 `requestAccess`，不会卡 20 秒。
- 热键用 Carbon `RegisterEventHotKey`（⌃⌥H），不装 CGEventTap、不申请辅助功能 / 输入监控。
- 录音格式 16kHz / 单声道 / 16-bit PCM WAV；热键模式松手 <200ms 丢弃并提示，>60s 自动停。
- 退出码：0 成功；1 用法 / IO；3 无输入设备；4 麦克风权限被拒；5 热键注册失败。
- 本机没有麦克风，**录音本身没验过**，验收边界见 [SEG3.md](../../apps/handy/SEG3.md)。

## 第 4 段：转写

```bash
./handy/handy-transcribe 录音.wav                      # 文本打到 stdout（默认优先常驻 server）
./handy/handy-transcribe 录音.wav --clip               # 再写剪贴板 + 弹提示
./handy/handy-transcribe 录音.wav --terms "Multica|Hermes agent"   # 临时热词表
./handy/handy-transcribe 录音.wav --model /path/ggml-medium-q5_0.bin
./handy/handy-transcribe 录音.wav --no-server          # 强制旧 whisper-cli 路径（对照 / 兜底）
./handy/handy-transcribe --server-status               # server 状态 / 端口 / PID（停止时 exit 1）
./handy/handy-transcribe --stop-server                 # 停掉常驻 server + 看门狗
./handy/handy-mic --file 录音.wav                      # 走「录音结束」之后的同一条链，打印 elapsed_ms
```

- **默认走常驻 server**：第一次调用拉起一个 `whisper-server`（514MB 模型只加载一次），
  之后每段 `POST /inference`（multipart：`file`、`response_format=json`、`prompt`），
  段间热词 + 接上文的 prompt 照搬旧路径。12–24 秒口述热态实测 1.7s / 2.8s。
  为什么要有它：CLI 每段都带一次 ~0.75s 的模型加载，12.68s 切 2 段就是 3.16–3.59s，破 3.0s 线。
- 拉起前先 `GET http://127.0.0.1:<port>/`（200ms 超时）探活；不活则从 8931 起找空闲端口，
  起 server 后轮询就绪最多 5s。任何一步失败都打一行 `fallback=cli` 走旧路径，**功能与退出码语义不变**。
- 生命周期：server 与看门狗都 `setsid` 脱离父进程，空闲 **10 分钟**自退（`HANDY_SERVER_IDLE_SECONDS`
  可覆盖，最小 5s）；`--stop-server` 立即停。登记、日志在 `~/Library/Caches/handy/whisper-server.{json,port,log,heartbeat}`，
  目录可用 `HANDY_LOG_DIR` 覆盖。server 崩了看门狗会清掉登记，下次调用重新拉起。
- 解码参数：两条路径都用 whisper.cpp 默认的贪心解码；CLI 也不再传 `-bs 8`，同一段 wav
  两条路径逐字一致。beam 8 曾在 s02 上多认对一个同音字（工位 / 公位），但 server 带 beam 8
  会把 24s 口述拖到 4.6s、破 3.5s 线，长驻进程从第二个请求起还会翻回贪心的结果，只能统一贪心：
  整组 CER 1.96%（线 2.5%），s03 两条路径都是 6.00%。
- `-nf` 不要用：whisper.cpp 1.9.2 的 whisper-server 只解析 / 打印 `no_fallback`，从不写进
  `wparams`（`temperature_inc` 恒 0.2），关不掉温度回退；回退用的 rng 在长驻进程里只 seed
  一次且没有重置 API。跨请求的简繁漂移由 wrapper 的 `Hant-Hans` 归一到简体，不依赖 server 输出。
- 不新增权限：server 只是本机 127.0.0.1 的进程，没有引入任何新的系统权限或输入监听 API。

- 链路：`handy-mic --hotkey` 松手落盘 → `handy-transcribe --clip` → `handy-clip` 写剪贴板 → `handy-hint` 弹提示。
  热键模式和 `--file` 调的是同一个函数（`handy-mic.swift` 的 `finishRecording`），没有第二份实现。
- 分段：8–12 秒一段，切点取静音中点（10ms 帧 RMS、-35dB、≥0.25s），窗口里没有静音就硬切在 ~11 秒。
  分段在进程内用 `AVAudioFile` 做，**不依赖 ffmpeg / ffprobe**（POC 的 `run.py` 用 ffmpeg 是度量台口径）。
- 每段 `--prompt` = 热词表 + 上一段末尾 40 字（首段只放热词），`-l zh`。
  长音频单窗口加 prompt 会把整段写成 prompt 原文（POC.md 已复现），所以必须先分段。
- 词典校正：两档匹配（先只校大小写，再音近形变 相似度 ≥0.60、首字母不同不套）。
  词表默认读 `~/Library/Application Support/Handy/terms.txt`（一行一个，`#` 开头是注释），`--terms "A|B|C"` 覆盖。
- 简繁：whisper 的中文输出默认常是繁体，落盘前用系统 ICU（`Hant-Hans`）转简体；`--keep-hant` 关掉。
  POC 量 CER 时本来就用 zhconv 归一，产品输出也得归，否则用户粘出去的是繁体。
- 退出码：0 成功；1 用法 / 音频 / whisper 失败；2 模型不存在；3 找不到 `whisper-cli`。
  2 和 3 在读音频之前就判，缺件 20ms 内说清楚。
- 不进网络、不加依赖：模型只按路径传，缺了就报错，**没有首次启动下载**。
- 闸门：`bash apps/handy/tests/chain.sh`（合成音 10 句 + 长句 + 4 生造词 + 12s/24s 时延，
  CER 用 `apps/handy/poc/cer.py` 的口径）。`CHAIN_NO_SERVER=1` 切回 CLI 路径对照 CER，
  并把两条时延 case 标 skip（CLI 按设计就超线，不是回归项）。

