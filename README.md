> **Windows 阅读器 2.0.1** · [启动与迁移](release/v2-windows-x64/使用说明.md) · [验证记录](validation/Windows二版验收.md)

# 阅读

Flutter 客户端配合个人 ASP.NET Core 10 服务端，提供普通文本书源搜索、TXT／EPUB 上传、章节阅读、离线缓存和跨设备进度同步。

Ubuntu 服务器可直接通过 [Docker Compose 部署](docs/docker-ubuntu.md)。新书库的书源列表为空，可在客户端的「书源管理」导入。

- Windows 首版位于 release/windows-x64，启动顺序见 [使用说明](release/windows-x64/使用说明.md)。
- 客户端源码位于 client，包含 Windows、Android 和 macOS 工程。各平台构建方式见下文。
- 服务端源码位于 server。运行 dotnet run --project server/NovelServer.csproj 后，在客户端“连接”中填写地址和个人令牌。服务端控制台显示数据目录和令牌文件位置。
- validation 包含书源快照、逐源诊断、在线实读报告、可生成的 TXT／EPUB 样本，以及独立数据目录的可重复验收脚本。Flutter 原生端到端测试位于 client/integration_test。

## 构建

### Windows

在项目根目录用 PowerShell 7 执行 Windows 构建。

```powershell
dotnet publish server/NovelServer.csproj -c Release -r win-x64 --self-contained true -o release/v2-windows-x64/server
./validation/build-v2.ps1 -Task release
```

构建 Flutter 客户端需要先在 `client` 目录运行 `flutter pub get`，为构建脚本准备本机依赖缓存。发布后可从 `release/v2-windows-x64` 运行 `Start-Reader.cmd`。

服务端使用 dotnet publish server/NovelServer.csproj -c Release -r win-x64 --self-contained true。客户端在 client 中运行 flutter pub get 和 flutter build windows --release。此版本 Flutter 的 AOT 工具在本机中文绝对路径下无法读取 app.dill，采用临时英文路径构建，最终整体复制 runner/Release 到发布目录，并随包附带对应的 Visual C++ x64 运行库。

### macOS 与 Android

在 macOS 上安装 Xcode、Flutter 和 Android SDK 后，从仓库根目录执行：

```sh
cd client
flutter pub get --enforce-lockfile
flutter analyze --no-pub --no-fatal-infos
flutter test --no-pub
flutter build macos --release --no-pub
flutter build apk --release
```

Android 发布命令保留默认的依赖准备步骤，以重新生成不含测试插件的注册代码；直接使用 `--no-pub` 可能触发 [Flutter 的插件注册问题](https://github.com/flutter/flutter/issues/169336)。

macOS 应用位于 `client/build/macos/Build/Products/Release/阅读.app`，可复制到“应用程序”。Android 安装包位于 `client/build/app/outputs/flutter-apk/app-release.apk`。两端通过“我的 → 连接与同步”连接已有服务端；手机填写服务器的局域网地址，不能使用指向手机自身的 `127.0.0.1`。

2.0.1 的本地发布文件位于忽略版本控制的 `release/2.0.1/`，包含 macOS 通用 ZIP、Android 通用 APK、使用说明、构建日志和 `SHA256SUMS`。当前 Android Release 沿用调试密钥签名，macOS 使用 ad-hoc 签名，未进行 Apple 公证或应用商店上传。

## 参考

[Legado MD3](https://github.com/HapeLee/legado-with-MD3) · [书源合集](https://raw.githubusercontent.com/liufuyou/read/main/sources/yck-novel.json) · [番茄参考项目](https://github.com/zhongbai2333/Tomato-Novel-Downloader)
