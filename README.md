> **Windows 阅读器 2.0.1** · [启动与迁移](release/v2-windows-x64/使用说明.md) · [验证记录](validation/Windows二版验收.md)

# 个人书房

Flutter 客户端配合个人 ASP.NET Core 10 服务端，提供普通文本书源搜索、TXT／EPUB 上传、章节阅读、离线缓存和跨设备进度同步。

- Windows 首版位于 release/windows-x64，启动顺序见 [使用说明](release/windows-x64/使用说明.md)。
- 客户端源码位于 client，包含 Windows、Android 和 macOS 工程。本轮只构建 Windows。
- 服务端源码位于 server。运行 dotnet run --project server/NovelServer.csproj 后，在客户端“连接”中填写地址和个人令牌。服务端控制台显示数据目录和令牌文件位置。
- validation 包含书源快照、逐源诊断、在线实读报告、可生成的 TXT／EPUB 样本，以及独立数据目录的可重复验收脚本。Flutter 原生端到端测试位于 client/integration_test。

## 构建

首次克隆后，在项目根目录用 PowerShell 7 运行以下命令。脚本按固定版本下载公开书源合集，校验 SHA-256，再准备服务端首次建库使用的两个书源。

```powershell
./validation/prepare-sources.ps1
dotnet publish server/NovelServer.csproj -c Release -r win-x64 --self-contained true -o release/v2-windows-x64/server
./validation/build-v2.ps1 -Task release
```

构建 Flutter 客户端需要先在 `client` 目录运行 `flutter pub get`，为构建脚本准备本机依赖缓存。发布后可从 `release/v2-windows-x64` 运行 `Start-Reader.cmd`。

服务端使用 dotnet publish server/NovelServer.csproj -c Release -r win-x64 --self-contained true。客户端在 client 中运行 flutter pub get 和 flutter build windows --release。此版本 Flutter 的 AOT 工具在本机中文绝对路径下无法读取 app.dill，采用临时英文路径构建，最终整体复制 runner/Release 到发布目录，并随包附带对应的 Visual C++ x64 运行库。

## 参考

[Legado MD3](https://github.com/HapeLee/legado-with-MD3) · [书源合集](https://raw.githubusercontent.com/liufuyou/read/main/sources/yck-novel.json) · [番茄参考项目](https://github.com/zhongbai2333/Tomato-Novel-Downloader)
