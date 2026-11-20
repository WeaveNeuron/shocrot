[English](README.md) | 简体中文

# Shocrot

Shocrot 是一款轻量的 macOS 菜单栏工具，一个快捷键就能截图、录屏、标注、识别文字（OCR）和翻译。纯 Swift 编写（AppKit + SwiftUI），没有第三方依赖；文字识别使用 macOS 内置的 Vision 框架，完全离线。

## 功能亮点

- **区域截图**：自动吸附窗口，放大镜取色（按 C 复制色值），显示像素尺寸，8 向调整与拖动，方向键微调；⌥单击可单独截取窗口（带阴影）。
- **标注**：矩形、椭圆、箭头、画笔、荧光笔、马赛克、文字、序号、测量；8 种颜色、3 档粗细；撤销与重做；按住 ⇧ 画正方形或 45° 箭头。
- **滚动截图**：框选后滚动页面，自动拼接成长图。
- **录屏**：把选区录制为 MP4（⌃⌘⎋ 或 HUD 按钮停止），可在预览卡片中导出循环 GIF，帧率和最大宽度在设置里选。
- **美化**：预览卡片一键加渐变背景、圆角和阴影。
- **文字识别**：框选即识别并自动复制；结果窗口可编辑、按行点选复制、保留换行或合并为段、翻译、搜索；同时识别二维码和条形码。
- **翻译**：划词翻译、截图翻译、输入翻译共用一个浮动面板；自动检测语言（首选语言 ↔ 第二语言），单词显示系统词典释义，支持朗读、复制和固定窗口。
  - **Apple 翻译**：系统离线翻译，缺少语言包时可在面板内一键下载。
  - **Google 翻译**：免费、无需配置（需联网，默认关闭）。
  - **大模型**：任意 OpenAI 兼容接口（OpenAI、DeepSeek、Ollama、LM Studio…），流式输出；本地推理模型可“关闭思考”秒出结果；API Key 保存在钥匙串中。
- **贴图**：把截图钉在所有窗口之上；滚轮缩放，⌥/⌘ + 滚轮调透明度，⌘R / ⇧⌘R 旋转，右键翻转，双击或 Esc 关闭。
- **历史记录**：保留最近 200 张截图，可按识别过的文字搜索。
- 全屏截图、贴图剪贴板、识别剪贴板图片或图片文件中的文字、自定义全局快捷键、登录时自动启动。
- **界面语言**：支持英文和简体中文。默认跟随系统语言，也可以在“设置 › 通用 › 语言”中切换，重新启动 App 后生效。
- **默认保护隐私**：所有处理都在本机完成；只有手动开启后才会使用联网翻译（Google 或云端大模型）。

## 系统要求

- macOS 26 或更高版本
- Apple 芯片或 Intel 芯片的 Mac（通用二进制）
- 从源码构建：Xcode 26 或更高版本（Swift 6 工具链）

## 下载安装

1. 打开 GitHub Releases 上的[最新版本](https://github.com/WeaveNeuron/shocrot/releases/latest)；全部版本见 [Releases 页面](https://github.com/WeaveNeuron/shocrot/releases)。
2. 在 **Assets** 中下载 `Shocrot-<版本号>-macOS-universal.dmg`（或 `.zip` 压缩包）。如需校验，可同时下载对应的 `.sha256` 文件并运行：

   ```sh
   cd ~/Downloads
   shasum -a 256 -c Shocrot-<版本号>-macOS-universal.dmg.sha256
   ```

3. 双击打开 `.dmg`，把 **Shocrot.app** 拖进 **Applications** 文件夹（如用 `.zip`，双击解压后移入“应用程序”文件夹）。
4. 从“应用程序”中打开 Shocrot。它常驻菜单栏（不在 Dock 中显示），首次打开会显示欢迎窗口。
5. 点击“屏幕录制”旁的“去开启”，在“系统设置 › 隐私与安全性 › 录屏与系统录音”中允许 Shocrot，然后按提示重新启动 Shocrot。

更新时，退出 Shocrot，用新版本替换“应用程序”中的旧版本即可。

## 权限说明

| 权限 | 用途 | 是否必需 |
| --- | --- | --- |
| 屏幕录制 | 截图、录屏、文字识别与截图翻译 | 必需 |
| 辅助功能 | 划词翻译；截图时用滚轮选择窗口里的控件 | 可选 |

“辅助功能”只在第一次用到相关功能时才会请求。两项权限都可以随时在“设置 › 通用”中查看和开启。

## 快捷键

全局快捷键（可在“设置 › 快捷键”中修改）：

| 操作 | 快捷键 |
| --- | --- |
| 区域截图 | ⌥⇧A |
| 识别文字 (OCR) | ⌥⇧T |
| 全屏截图 | ⌥⇧F |
| 贴图剪贴板 | ⌥⇧P |
| 划词翻译 | ⌥⇧D |
| 截图翻译 | ⌥⇧X |
| 输入翻译 | ⌥⇧I |

截图时：

| 操作 | 快捷键 |
| --- | --- |
| 复制并完成 | ↩ / ⌘C / 双击 |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 识别文字 / 翻译 / 贴图 | ⌘T / ⌘D / ⌘P |
| 滚动截图 / 录屏 | ⌘L / ⌘R |
| 录屏中停止并保存 | ⌃⌘⎋ |
| 标注工具 | R O A P H M T N U |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| 微调选区 | 方向键（按住 ⇧ 为 10 倍） |
| 复制取色 / 全屏选区 | C / ⌘A |
| 单独截取窗口 | ⌥单击 |
| 取消 | Esc / 右键 |

## 自动化

### URL Scheme

`shocrot://capture`、`ocr`、`fullscreen`、`pin`、`ocr-clipboard`、`translate?text=…`、`translate-selection`、`translate-capture`、`history`、`settings`，可在快捷指令、Raycast、Alfred 或 `open` 命令中调用：

```sh
open "shocrot://translate?text=Hello"
```

### 命令行 OCR

```sh
/Applications/Shocrot.app/Contents/MacOS/Shocrot --ocr image.png
```

## 从源码构建

```sh
git clone https://github.com/WeaveNeuron/shocrot.git
cd shocrot
swift build        # Debug 构建
swift test         # 单元测试
scripts/build_app.sh            # 生成 build/Shocrot.app（Release，通用二进制）
scripts/build_app.sh --install  # 同时安装到 /Applications
```

`scripts/build_app.sh` 的参数：

| 参数 | 作用 |
| --- | --- |
| `--install` | 安装到 /Applications（会先退出正在运行的 Shocrot）。 |
| `--package` | 生成 `build/Shocrot-<版本号>-macOS-universal.zip` 及对应的 `.sha256`，可直接上传到 GitHub Release。 |
| `--notarize` | 公证并装订（需要 Developer ID Application 证书和 `notarytool` 钥匙串配置），完成后自动打包。 |
| `--adhoc` | 使用 ad-hoc 签名，不读取钥匙串，适合本地检查和 CI。 |

版本号来自 `SHOCROT_VERSION`（例如 `SHOCROT_VERSION=1.2.0 scripts/build_app.sh --package`），构建号自动取 git 提交数。签名身份按以下顺序选择：`SHOCROT_SIGN_IDENTITY`、`SHOCROT_TEAM_ID` 对应的 Developer ID Application 证书、自签名证书 `Shocrot Local Signing`（用 `scripts/make_local_cert.sh` 创建）、ad-hoc。使用固定证书时，重新构建后隐私权限不会失效；ad-hoc 签名则可能每次构建后都要重新授权。

### 本地化

界面文案位于 `Sources/Shocrot/Resources/<语言>.lproj/Localizable.strings`，Info.plist 的文案位于同目录的 `InfoPlist.strings`。英文（`en`）是开发语言和回落语言，简体中文（`zh-Hans`）保持相同的键。代码中使用 `L("key")`、`L("key", 参数…)` 或 `L10n.plural("key", 数量)`。单元测试会检查代码用到的每个键在两种语言中都存在，且译文的格式占位符一致。

### 开发说明

- 无需录屏权限即可调试截图覆盖层：`SHOCROT_DEMO_IMAGE=<png> .build/debug/Shocrot` 会用这张图片模拟屏幕并自动进入截图（仅 Debug 构建）。
- 文字识别引擎：实现 `OCREngine`（`Sources/Shocrot/OCR/OCRService.swift`），赋值给 `OCRService.engine`。
- 翻译服务：实现 `TranslationService`（`Sources/Shocrot/Translate/TranslationService.swift`），加入 `TranslationServices.enabled`。
- 本机运行 `swift build` / `swift test` 时，SwiftPM 会往用户的 TemporaryItems 写 `output-file-map.json`。如果沙箱拒绝这次写入（EPERM），报错看起来像普通 I/O 错误，测试还没启动就停了；放开 TemporaryItems 的写入后再运行即可。

## 开源协议

Copyright 2026 WeaveNeuron LTD.

基于 [Apache License, Version 2.0](LICENSE) 开源。
