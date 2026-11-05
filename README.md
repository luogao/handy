# Handy · 第 1 段（剪贴板写入）

`./handy-clip "文本"` 写入 `NSPasteboardTypeString`；首次写入前备份原剪贴板全部类型，`./handy-clip --restore` 还回去。零 TCC，不碰 Accessibility / CGEvent。

```bash
./handy/handy-clip "测试 中文，换行
第二行 🎤" && pbpaste
./handy/handy-clip --restore     # 回到写入前的内容
./handy/handy-clip --status      # 备份状态
```

- 备份位置：`~/Library/Caches/handy/clipboard-backup.plist`（0600），可用 `HANDY_CLIP_STATE_DIR` 覆盖。
- 退出码：成功 0；无参数 / 无备份 / 写入失败 1。无参数时 stderr 打 usage。
- 非选项参数按一个空格拼接；要保留换行就把整段文本作为一个参数传进来。
- 第 2 段（可见提示）不在本目录范围。
