# MacMTP

[English](README.md)

MacMTP 能将你的 MTP 设备，比如你的 Android 手机，直接挂载到 Finder 中。简单纯粹，不多不少。

## 安装

从 [Releases](https://github.com/ClassicOldSong/MacMTP/releases/latest) 下载 MacMTP，或通过 Homebrew 安装：

> **重要：** 从 Releases 下载后，请先将 `MacMTP.app` 移到“应用程序”文件夹，再打开使用。

```sh
brew install --cask ClassicOldSong/tap/macmtp
```

## 环境要求

* macOS 13 或更高版本
* Apple Clang 与 macOS SDK（Xcode 或命令行工具）
* CMake 3.24 或更高版本
* Ninja

## 构建

```sh
MACMTP_TEAM_ID=TEAMID \
MACMTP_CODE_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
./scripts/build.sh
```

## 注意事项

* 请解锁手机并选择 MTP / 文件传输 USB 模式。
* 执行文件操作时，请避免断开设备连接。

## 开源许可

MacMTP 基于 GNU LGPL v2.1 (GNU Lesser General Public License, version 2.1) 协议开源。详见 [LICENSE](LICENSE)。随附的第三方依赖说明请参阅 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 支持项目

如果你想支持 MacMTP，请扫描下方二维码：

![支持开发者](SUPPORT_QR.JPG)

您的支持也会帮助我的其他项目：

- [AirBeam](https://github.com/ClassicOldSong/AirBeam) - Android 外接屏空鼠与触控板
- [Apollo](https://github.com/ClassicOldSong/Apollo)
- [Artemis](https://github.com/ClassicOldSong/moonlight-android)
- [Plexsonic](https://github.com/ClassicOldSong/Plexsonic) - 通过 Subsonic/OpenSubsonic 兼容接口访问 Plex 音乐库的本地桥接服务
- [rEFui](https://github.com/SudoMaker/rEFui)
- [Methanol](https://github.com/SudoMaker/methanol)
