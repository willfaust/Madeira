# Experimental unsigned IPA / 实验版安装说明

Download only from this repository's [GitHub Releases](https://github.com/Jelly-RayTian/Madeira-Experimental/releases).
The first prerelease archives the local **2026-10-20 Debug integer-output build**.
It predates this repository's publication and was not freshly built from the
release tag. Source and build prerequisites are published, but bit-for-bit
reproducibility is not claimed. Earlier screenshots precede this IPA and do not
prove this particular build enters the same scene or fixes the later failure.

## 安装步骤

1. 下载 `Madeira-Experimental-2026-10-20-Debug-unsigned.ipa`；可用同页的 `SHA256SUMS.txt` 核对文件。
2. 用你自己的有效证书和描述文件在 iPad 上签名安装。安装包没有证书、配对文件或账号数据。
3. **这个历史包保留原 Madeira 标识 `com.willfaust.madeora`。** 签名工具若保留该标识，可能替换现有 Madeira。先备份存档；想并存安装，就在签名工具中使用你的证书允许的独立标识，同时正确处理嵌入的 JIT 扩展。不要为了安装而卸载有游戏数据的旧 App。
4. 使用你已经配置好的 StikDebug/JIT 方法给新进程启用 JIT；保留安装包中的 JIT 扩展与框架。每次重新启动后重新启用。
5. 自行导入合法持有的游戏，先运行通用 Vulkan 测试；不要把游戏文件上传到本项目。
6. 低日志基础配置见 Release 附件 `detroit-baseline.cfg`，复制到 App 文档根目录并命名 `madeira.cfg`。第一次尝试不要叠加其他实验配置。

基础配置内容：

```ini
env.WINEDEBUG = err+all,err-virtual,warn+vulkan
env.MADEIRA_VK_METAL_LIBRARY_OPTIMIZATION = default
env.MADEIRA_VK_ZERO_UNBOUND_VERTEX_INPUTS = 1
```

`detroit-integer-output-experimental.cfg` 是单独可选的实验配置，额外打开整数输出策略和诊断。该策略默认关闭，只有 Mac 原生读回验证，尚无这份 IPA 的新策略实机成功证明。不要把它当成已经确认的底特律崩溃修复。

## Known limits

- Earlier game scene/camera observations were on an Apple M5 iPad with iPadOS26; other devices/OS versions are not verified.
- Shader compilation can be very slow, and black screens or later pipeline/submit failures remain possible. No stable frame rate or full-game completion is claimed.
- The package uses cached native build prerequisites; it is not a clean-machine rebuild. Bundle version0.1.3/build4 is inherited and is not an official upstream release.
- This is the broader experiment, not the default-off PR400 fixture package.
- `BUILD-MANIFEST.json` records the asset SHA256, App UUID, Vulkan DLL hashes, unsigned status and verification boundaries without private device logs.
