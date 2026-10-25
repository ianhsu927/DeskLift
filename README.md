# DeskLift

使用 SwiftUI、AppKit 和 CoreBluetooth 开发的原生 macOS 升降桌控制应用，面向 LINAK DPI1C 蓝牙控制器。

## 功能

- 扫描并手动连接升降桌，读取校准后的实际高度。
- 启动时自动连接上次成功使用的桌子，可在设备面板关闭。
- 按住升降、停止、移动到指定高度。
- 原生菜单栏控制：高度显示、红绿连接状态、升降按钮、记忆档位和当前高度持续时间。
- 按设备保存本机坐姿、站姿预设。
- 读取控制器的四个内部记忆档位，确认后写入并进行两次读回校验。
- 为内部记忆档位设置本机名称；名称按设备保存，不写入控制器。
- 提供 App Intents 动作，供快捷指令和 Siri 调用高度查询、停止、指定高度和本机预设操作。

## 构建与运行

当前工程面向 Apple Silicon（arm64），最低部署版本为 macOS 14。开发与验证使用 Xcode 27，脚本固定使用 `/Applications/Xcode.app/Contents/Developer`。

```sh
git clone https://github.com/ianhsu927/DeskLift.git
cd DeskLift
./scripts/build.sh
open build/DeskLift.app
```

首次使用需允许蓝牙访问，在应用内手动连接一次设备。成功读取高度和校准值后，应用会记住该设备；后续启动默认自动连接，可在设备面板关闭「启动时自动连接」。自动连接失败后不会持续重试，手动断开、睡眠或锁屏会取消本次尝试。应用不会在启动、连接或唤醒时自动移动桌子。

也可以打开 `DeskLift.xcodeproj`，选择共享的 `DeskLift` scheme。Xcode 默认启用 `--preview` 参数，使用预览数据；连接真实设备前，请在 Scheme → Run → Arguments 中关闭该参数。

## 测试

```sh
./scripts/test.sh
```

运行协议、状态机、安全策略和本机数据存储测试。测试不连接真实蓝牙设备，也不会驱动升降桌。

仅运行协议命令行检查：

```sh
./scripts/test.sh --cli
```

## Siri 与签名

默认构建采用临时签名。当前验证环境中的 Siri / 快捷指令执行需要有效的 Apple 开发签名身份，可通过环境变量指定：

```sh
DESKLIFT_SIGNING_IDENTITY='Apple Development: Your Name (XXXXXXXXXX)' \
DESKLIFT_DEVELOPMENT_TEAM='XXXXXXXXXX' \
./scripts/build.sh
```

安装签名后的应用，在 macOS「快捷指令」中添加 DeskLift 动作并保存命名快捷指令，即可通过 Siri 调用。开发签名证书的执行验证尚待完成。

## 控制器内部记忆

读写流程包含连接会话、校准值和静止状态检查。写入需在界面确认，只发送一次保存命令；读回无法确认时不自动重试或回滚。已在真实 DPI1C 上验证记忆读取和取消写入确认；持久写入尚未进行实机验证。其他控制器或固件的兼容性需要另行验证。

## 项目结构

- `Sources/`：原生界面、蓝牙控制、协议和 App Intents。
- `Tests/`：协议及状态机测试。
- `scripts/`：构建、测试和图标生成脚本。
- `DeskLift.xcodeproj/`：Xcode 工程和共享 scheme。

## 第三方声明

部分 DPI1C 协议实现参考 [ha-linak-dpi1c-control](https://github.com/kkqq9320/ha-linak-dpi1c-control)，对应版本及 MIT 许可保留在 [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt)。DeskLift 是独立项目，与 LINAK 无关联。
