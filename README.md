# DeskLift

使用 SwiftUI、AppKit 和 CoreBluetooth 开发的原生 macOS 升降桌控制应用，面向 LINAK DPI1C 蓝牙控制器。

## 功能

- 扫描并手动连接升降桌，读取校准后的实际高度。
- 启动时自动连接上次成功使用的桌子，可在设备面板关闭。
- 按住升降、停止、移动到指定高度。
- 原生菜单栏控制：高度显示、红绿连接状态、升降按钮、记忆档位和当前高度持续时间。
- 按设备保存本机坐姿、站姿预设。
- 读取控制器的四个内部记忆档位，确认后写入并进行两次读回校验。
- 单独删除非空的内部记忆档位，确认后清空并进行两次空值读回校验。
- 为内部记忆档位设置本机名称；名称按设备保存，不写入控制器。
- 提供 App Intents 动作，供快捷指令和 Siri 调用高度查询、停止、指定高度和本机预设操作。
- 通过局域网直接控制米家显示器挂灯 2：开关、亮度、色温及状态读回，设备 Token 保存在 macOS 钥匙串中。

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

全量测试还包含独立子进程回归：断开的标准输出、标准错误、本机 socketpair，以及启动器在子进程启动后关闭管道。图形进程将 `SIGPIPE` 转为 I/O 失败，网络写入仍检查错误且不重发；命令行入口保留原有管道输出语义，`SIGTERM` 等其他信号不变。

仅运行协议命令行检查：

```sh
./scripts/test.sh --cli
```

检查自动化启动器断开输出后的图形进程存活情况（仅使用预览数据，不连接硬件）：

```sh
python3 scripts/diagnose-launcher-pipes.py --app /Applications/DeskLift.app
```

## Siri 与签名

默认构建采用临时签名。当前验证环境中的 Siri / 快捷指令执行需要有效的 Apple 开发签名身份，可通过环境变量指定：

```sh
DESKLIFT_SIGNING_IDENTITY='Apple Development: Your Name (XXXXXXXXXX)' \
DESKLIFT_DEVELOPMENT_TEAM='XXXXXXXXXX' \
./scripts/build.sh
```

安装签名后的应用，在 macOS「快捷指令」中添加 DeskLift 动作并保存命名快捷指令，即可通过 Siri 调用。开发签名证书的执行验证尚待完成。

## 米家显示器挂灯 2

在主窗口工具栏点击「挂灯」，或选择「窗口 → 米家挂灯」（⌘5）；菜单栏也提供「米家挂灯…」入口。

首次配置填写挂灯的局域网 IPv4 地址及 32 位设备 Token，点击「保存并连接」。只有型号和设备响应通过验证后才会保存凭据。后续打开面板只读取状态，电源开关及松开滑块时才发送对应的绝对值控制命令；每次写入后读回确认，失败时不会自动重发。可通过「刷新状态」同步旋钮或米家 App 的操作结果。

挂灯与 Mac 需在同一可互通的局域网，不依赖 Home Assistant 或米家网关。首次获取 Token 需要米家账号；DeskLift 的运行时控制直接访问挂灯，不调用米家云。Token 不写入用户偏好或应用资源；可在面板中替换，留空则保留已保存的 Token，「忘记设备」会移除本机钥匙串中的配置。

目前验证型号为 `xiaomi.light.bar2`、固件 `1.1.3`（MCU `0027`），已实测开关、亮度和色温写入及读回。其他型号不接受写入，其他固件仍需验证。未做互联网完全断开后的运行测试。挂灯功能独立于升降桌，不会触发桌子运动。

配置完成后，也可用以下只读命令检查原生局域网通信；它不会初始化桌子的蓝牙连接：

```sh
build/DeskLift.app/Contents/MacOS/DeskLift --verify-mijia-light
```

## 控制器内部记忆

读写和删除流程包含连接会话、校准值和静止状态检查。写入、删除均需在界面确认，只发送一次对应的保存或清空命令；读回无法确认时不自动重试或回滚。删除只针对选定档位，本机名称和坐站预设继续保留。已在真实 DPI1C 上验证记忆读取，以及写入、删除确认框的取消流程；实际保存和清空尚未进行实机验证。其他控制器或固件的兼容性需要另行验证。

## 项目结构

- `Sources/`：原生界面、蓝牙控制、协议和 App Intents。
- `Tests/`：协议及状态机测试。
- `scripts/`：构建、测试和图标生成脚本。
- `DeskLift.xcodeproj/`：Xcode 工程和共享 scheme。

## 第三方声明

部分 DPI1C 协议实现参考 [ha-linak-dpi1c-control](https://github.com/kkqq9320/ha-linak-dpi1c-control)，对应版本及 MIT 许可保留在 [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt)。DeskLift 是独立项目，与 LINAK 无关联。
