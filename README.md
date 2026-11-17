# Shocrot

简约的 macOS 截图 + OCR + 翻译菜单栏工具。纯 Swift（AppKit + SwiftUI），无第三方依赖；OCR 使用系统内置 Vision，完全离线。

## 功能

- **区域截图**：自动吸附窗口、放大镜取色（按 C 复制色值）、像素尺寸提示、8 向调整与拖动、方向键微调
- **标注**：矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字、序号、测量；8 色 3 档粗细；撤销/重做；按住 ⇧ 画正方形 / 45° 箭头
- **滚动截图**：框选后滚动页面，自动拼接成长图
- **录屏**：录制选区为 MP4（⌃⌘⎋ 或 HUD 按钮停止），可在预览卡片中导出循环 GIF（帧率和最大宽度在设置里选）
- **美化**：预览卡片一键加渐变背景、圆角和阴影
- **文字识别**：框选即识别，自动复制；结果窗口可编辑、按行点选复制、保留换行/合并为段、翻译、搜索；同时识别二维码/条形码
- **翻译**：划词翻译、截图翻译、输入翻译共用一个浮动面板；自动检测语言（母语 ↔ 第二语言），单词显示系统词典释义，朗读、复制、固定窗口
  - **Apple 翻译**：系统离线翻译，缺少语言包时可在面板内一键下载
  - **Google 翻译**：免费、无需配置（需联网，默认关闭）
  - **大模型**：任意 OpenAI 兼容接口（OpenAI、DeepSeek、Ollama、LM Studio…），流式输出；本地思考模型可“关闭思考”秒出结果；API Key 存于钥匙串
- **贴图**：截图钉在屏幕最上层，滚轮缩放、⌥/⌘+滚轮调透明度、⌘R / ⇧⌘R 旋转、右键翻转，双击或 Esc 关闭
- **历史记录**：最近 200 张截图，可按识别过的文字搜索
- 全屏截图、贴图剪贴板、识别剪贴板图片 / 图片文件、可自定义全局快捷键、开机启动

## 默认快捷键

| 操作 | 快捷键 |
| --- | --- |
| 区域截图 | ⌥⇧A |
| 识别文字 | ⌥⇧T |
| 全屏截图 | ⌥⇧F |
| 贴图剪贴板 | ⌥⇧P |
| 划词翻译 | ⌥⇧D |
| 截图翻译 | ⌥⇧X |
| 输入翻译 | ⌥⇧I |

截图时：↩ / ⌘C / 双击 复制，⌘S 保存，⇧⌘S 另存为，⌘T 识别文字，⌘D 翻译，⌘P 贴图，⌘L 滚动截图，⌘R 录屏，⌘Z 撤销，⌘A 全屏选区，Esc / 右键 取消。

## URL Scheme

`shocrot://capture`、`ocr`、`fullscreen`、`pin`、`ocr-clipboard`、`translate?text=…`、`translate-selection`、`translate-capture`、`history`、`settings`，可在快捷指令、Raycast、Alfred 中调用。

## 命令行 OCR

```sh
/Applications/Shocrot.app/Contents/MacOS/Shocrot --ocr image.png
```

## 扩展

- OCR 引擎：实现 `OCREngine`（`Sources/Shocrot/OCR/OCRService.swift`），赋值给 `OCRService.engine`
- 翻译服务：实现 `TranslationService`（`Sources/Shocrot/Translate/TranslationService.swift`），加入 `TranslationServices.enabled`

## 构建

```sh
scripts/build_app.sh            # 生成 build/Shocrot.app（通用二进制）
scripts/build_app.sh --install  # 同时安装到 /Applications
```

需要 macOS 26+、Xcode 26+。划词翻译需要“辅助功能”权限。首次使用需在“系统设置 › 隐私与安全性 › 录屏与系统录音”中允许 Shocrot，然后重启应用。构建时优先使用本地证书 `Shocrot Local Signing`（用 `scripts/make_local_cert.sh` 创建），重新构建后权限不会失效；没有证书时退回 ad-hoc 签名，每次重新构建后可能需要重新授权。

版本号：`SHOCROT_VERSION=1.2.0 scripts/build_app.sh` 指定版本，默认取 `VERSION` 变量；构建号自动取 git 提交数。

调试：`SHOCROT_DEMO_IMAGE=<png> .build/debug/Shocrot` 会用该图片模拟屏幕并自动进入截图（仅 Debug 构建），无需录屏权限即可调试覆盖层。

本机 `swift build` / `swift test` 时，SwiftPM 会往用户的 TemporaryItems 写 `output-file-map.json`。沙箱若拒绝这次写入（EPERM），报错看起来像普通 I/O 错误，测试还没启动就停了。源码没有这个缺陷；放开 TemporaryItems 的写入后再跑即可。
