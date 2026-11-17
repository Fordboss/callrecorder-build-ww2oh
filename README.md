# 通话录音机（低体积版）· 巨魔可用

基于开源项目 **Lessica/TrollRecorder** 的 CLI 录音逻辑改造而来，把"录几分钟几百兆"改成**约 0.24 MB/分钟**（缩小约 80 倍）。

## 一、为什么原版几百兆？

开源 CLI 的 `call-recorder.mm` 里有一段"障眼法"：

```
第 132 行：mDataFormat.mFormatID = kAudioFormatMPEG4AAC;   ← 表面设了 AAC
第 158 行：mDataFormat = *([audioFormat streamDescription]); ← 又被 Float32 PCM 覆盖
写文件时：kAudioFileCAFType（无损容器）
```

结果实际录出来是 **44.1kHz / 双声道 / 32bit 浮点 PCM**，约 20 MB/分钟 —— 几分钟当然几百兆。那句 AAC 设置等于白写。

## 二、我改了什么

采集链路（`ATAudioTap` tap 系统/电话音频）完全保留，只重写了"怎么落盘"：

```
tap → AudioQueue（PCM，原样）→ ExtAudioFile 编码成 AAC → 写 .m4a
```

| 参数 | 原版 | 本版 |
|---|---|---|
| 编码 | Float32 PCM（无损） | AAC（压缩） |
| 容器 | CAF | M4A |
| 采样率 | 44100 Hz | **16000 Hz** |
| 声道 | 双声道 | **单声道** |
| 码率 | 约 1400 kbps | **32 kbps** |
| 体积/分钟 | 约 20 MB | **约 0.24 MB** |

`ExtAudioFile` 编码是 Apple 官方 API，也是原项目 `mixer.mm` 里已在用的成熟写法，比"直接改格式字段"可靠得多。

**想再调音质/体积**：改 `CallRecorder/RecorderEngine.mm` 顶部三行
- `kSampleRate` 16kHz → 44kHz：更保真，体积翻倍
- `kAACBitRate` 32000 → 64000：音质更好，体积翻倍
- `kChannels` 1 → 2：立体声，体积翻倍

## 三、能录什么

App 里三个选项：
- **通话双方**（系统音频 tap）：电话里对方+自己的声音
- **麦克风**：环境音
- **扬声器**：设备外放声音

> ⚠️ "通话双方"录制依赖私有权限 `com.apple.coreaudio.CanTapTelephony` 等。
> 这些权限已写进 entitlements，由巨魔（TrollStore）用 CoreTrust 漏洞坐实。
> **能否成功、以及具体 iOS 版本是否支持，需要在你的真机上验证**——我这边 Windows 无法编译和测试。
> 这也是闭源 TrollRecorder 卖 Pro 的原因之一：它替你处理了各种机型的兼容。

## 四、云编译步骤（不用 Mac）

1. GitHub 新建一个 **Public** 仓库。
2. 把本文件夹全部内容上传（`CallRecorder/`、`project.yml`、`.github/` 一个都别漏，`.github` 是隐藏目录）。
3. 仓库 `Actions` → 点 `编译通话录音机 IPA (巨魔可用)` → `Run workflow`。
4. 等 3~6 分钟，在本次运行页面底部 `Artifacts` 下载 **`CallRecorder-IPA`**。
5. 解压得到 `CallRecorder.ipa` → 传到 iPhone → 文件 App 长按 → 共享 → **TrollStore** → Install。
6. 首次打开选"通话双方"，点开始录音，打一通电话，结束后看列表播放验证。

## 五、必须知道的几个现实

1. **这改不了你已装的 TrollRecorder App**：那个 App 是闭源收费的，源码不公开。本工程是用它开源的 CLI 逻辑重做的独立 App，不影响你原来的 App。
2. **私有 API 有兼容风险**：`ATAudioTap` 是私有接口，不同 iOS 版本行为可能不同。如果点了录音没反应/没保存，多半是权限或 tap 在你机型上不可用——把现象（iOS 版本、机型、报错）发我，我再调。
3. **通话录音的合法性**：各地法律对通话录音要求不同，请自行确认你所在地区的规定，仅用于合法用途。
4. 录音全部存在 App 的「文稿」目录，不联网、不上传。

## 六、工程结构

```
CallRecorderIPA/
├── .github/workflows/build.yml   # 云编译 + ad-hoc 签名 + 打包 IPA
├── project.yml                   # XcodeGen 工程描述
└── CallRecorder/
    ├── main.m / AppDelegate.*    # 入口
    ├── RecorderEngine.h/.mm      # ★ 核心录音引擎（体积参数在 .mm 顶部）
    ├── ViewController.mm         # 界面
    ├── Info.plist                # 麦克风权限、后台音频
    ├── CallRecorder.entitlements # ★ 通话录音私有权限
    └── include/*.h               # ATAudioTap 等私有 API 头文件
```

另附 `CallRecorderLite/` 是**纯命令行版**（给越狱环境用，巨魔装不了 CLI），已同样改成低体积：`cli/call-recorder.mm` 顶部三个常量可调。
