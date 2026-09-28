# DashBeam HarmonyOS

该目录包含 DashBeam 的原生 HarmonyOS 版本，不使用 WebView。界面由 ArkUI/ArkTS 实现，传输链路为 ArkTS -> Node-API C++ -> Rust staticlib -> DashBeam native/protocol engine。

## 工程基线

- Bundle name：`com.dashbeam.harmony`
- Target / compatible SDK：HarmonyOS 6.1.1(24)
- 本机构建 SDK：API 26
- Native ABI：`arm64-v8a`、`x86_64`
- 设备声明：Phone、Tablet、PC/2in1；折叠、宽折叠和三折叠使用对应 Phone 大屏形态

## 已接入能力

- 五个原生页面：发送、接收、设备、历史、设置，并根据窗口宽度、旋转和折叠状态响应布局。
- DocumentViewPicker 文件选择、URI 持久授权、沙箱暂存、接收目录选择及完成后导出。
- Rust/Iroh 真实发送、接收、元数据、进度、取消和冲突重命名；历史只记录真实完成结果。
- 持久 NodeService、设备身份、附近发现、配对票据、附近配对、已配对设备和传输邀请。
- 附近发现仅由 Rust `iroh-mdns-address-lookup` 链路提供；旧 ArkTS mDNS 适配器已移除。
- DATA_TRANSFER 长时任务、系统实况窗进度、后台配对/邀请通知和通知授权。
- 系统取消长时任务时按 `continuousTaskId` 取消对应 native session；进程重启后清理无法恢复的孤儿长时任务。
- App Linking：处理 `https://app.dashbeam.net/receive?ticket=...` 的冷启动和热启动，只预填票据、切换接收页并读取元数据，不自动下载。

## 构建与运行

```powershell
cd harmony
devecocli build
devecocli build --product default
devecocli run --device "<device-name>" --module entry --skip-build
```

当前未签名开发产物：

- `entry/build/default/outputs/default/entry-default-unsigned.hap`
- `build/outputs/default/harmony-default-unsigned.app`

HarmonyOS API 24 模拟器允许安装该开发 HAP，但这不代表真机分发、App Linking 域名校验或应用市场签名已通过。

## 网络与通知

设置页可填写自定义 Relay URL 和 Discovery URL（HTTPS，或仅本机回环 HTTP）；DNS Origin 需要配合自定义 Discovery URL 使用。留空时沿用默认公开服务。更改网络配置后重启应用，设备节点才会采用新设置；发送、接收和元数据解析会读取当前已保存的设置。

通知权限不会在首次启动时弹出。需要后台配对和传输邀请提醒时，可在设置页主动点击「开启通知」；拒绝后也可再次申请。通知未授权不影响前台文件选择与传输操作。

## App Linking 发布条件

客户端已经声明独立 browsable skill，包含 HTTPS host、`/receive` 路径和 `domainVerify: true`。正式验证仍需要：

1. 在 AGC 注册 `app.dashbeam.net`，并取得该应用的 `appIdentifier`。
2. 在站点发布 `https://app.dashbeam.net/.well-known/applinking.json`；仓库目前没有该文件，因为 `appIdentifier` 不能由 bundle name 推导。
3. 准备与 `com.dashbeam.harmony` 和测试设备匹配的 `.p12`、`.cer`、`.p7b` 手动签名材料。
4. 在 `build-profile.json5` 的 `signingConfigs` 配置加密密码、alias、证书、Profile 和密钥库。

App Linking 官方要求使用手动签名，DevEco 自动签名和未签名模拟器包不能用于证明链接验证成功。

## 已执行的形态验证

以下实例均为 HarmonyOS 6.1.1(24) Release，已真实安装 HAP、启动 `EntryAbility` 并检查 DashBeam crash 日志：

| 形态 | 实例 | 结果 |
| --- | --- | --- |
| Phone | Mate 80 Pro Max | 安装、启动成功，无 crash |
| Tablet | MatePad Pro 13 | 安装、启动成功，无 crash |
| PC/2in1 | DashBeam 2in1 API24 | 安装、启动成功，无 crash |
| Foldable | Jiyuu Foldable API24 | open、half-open、close、open 成功，无 crash |
| WideFold | DashBeam WideFold API24 | close、open 成功，无 crash；该镜像不接受 half-open |
| TripleFold | DashBeam TripleFold API24 | single、double、两种混合半折、triple 成功，无 crash |

该矩阵证明安装、启动和形态切换没有产生应用崩溃，不等同于视觉像素级验收或双设备端到端传输测试。`devecocli` 当前不提供设备截图/触控命令，未伪造这些结果。