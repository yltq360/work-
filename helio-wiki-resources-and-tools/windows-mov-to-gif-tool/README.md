# MOV → GIF（Windows 本地转换工具）

把 MOV 文件拖到 `mov-to-gif.bat` 上，即可在 MOV 所在目录生成同名 GIF。

这个工具的默认策略是：保持源视频的分辨率和帧时间，不主动缩放、不裁剪、不添加降帧滤镜，也不缩短时长。音频会被忽略，因为 GIF 不支持音频。

## 文件

- `mov-to-gif.bat`：拖放和命令行入口。
- `mov-to-gif.ps1`：检测工具、读取媒体信息、转换并验收。
- `ffmpeg-setup-instructions/README.md`：FFmpeg 下载与放置说明。

## FFmpeg 准备

脚本按以下顺序寻找 `ffmpeg.exe` 和 `ffprobe.exe`：

1. 当前脚本所在目录；
2. 系统 `PATH`。

两个程序必须同时存在。缺少任何一个时，脚本会明确报错并返回非零退出码，不会静默失败。Git 仓库不直接保存这两个大型第三方二进制文件；请按 `ffmpeg-setup-instructions/README.md` 获取并放置，或配置系统 `PATH`。

## 最简单的用法

把一个或多个 `.mov` 文件直接拖到 `mov-to-gif.bat` 上。

拖放打开的窗口在转换或报错后会等待按键，不会一闪而过。自动化调用如果不需要等待，可先设置环境变量 `MOV_TO_GIF_NO_PAUSE=1`。

也可以在命令行使用：

```bat
mov-to-gif.bat "D:\Videos\demo.mov"
mov-to-gif.bat "D:\Videos\one.mov" "D:\Videos\two.mov"
```

默认输出位置是每个 MOV 的原目录，默认输出名为 `原文件名.gif`。

为防止意外覆盖，若目标 GIF 已存在，该文件会失败并给出提示。确认要覆盖时显式使用：

```bat
mov-to-gif.bat -Force "D:\Videos\demo.mov"
```

## 转换策略

脚本执行两遍 FFmpeg：

1. `palettegen=stats_mode=full` 扫描完整视频并生成调色板；
2. `paletteuse=dither=sierra2_4a` 使用调色板编码 GIF。

两遍方式避免在单个 `split + palettegen + paletteuse` 图中等待调色板时积压整段全尺寸帧。默认流程没有 `scale`、`fps` 或 `crop` 滤镜；脚本会检测 FFmpeg 能力，新版使用 `-fps_mode passthrough`，旧版使用 `-vsync 0` 来请求传递源帧时间戳，并使用 `-loop 0` 设置无限循环。

转换前会用 `ffprobe` 显示源分辨率、`avg_frame_rate` / `r_frame_rate` 和时长。转换后会再次显示 GIF 分辨率、时长和实际文件大小，并严格检查输出宽高是否与源视频一致。

## GIF 固有限制

- GIF 每帧延迟以 1/100 秒为单位。60 FPS 的理想帧间隔约为 1.667/100 秒，无法被 GIF 数学意义上完全表示。脚本不主动添加降帧滤镜，但 FFmpeg/GIF 格式仍必须量化帧延迟；部分浏览器/查看器还会把很短的帧延迟钳制到更长的值，因此高 FPS GIF 的播放节奏可能出现明显误差。
- GIF 每帧最多使用 256 色。`palettegen + paletteuse` 能明显改善颜色，但无法做到视觉无损。
- 高分辨率、高 FPS 或长视频会生成非常大的 GIF，并消耗较多 CPU、内存和磁盘空间。脚本不会为了成功而自动降低分辨率、FPS、时长或质量；如果 FFmpeg 被系统终止，控制台会保留 FFmpeg 输出并明确报告失败。

本工具没有默认启用任何“低内存降级”。如需另做缩放或降帧版本，应由用户主动选择并使用单独参数/脚本，不能冒充原质量模式。

## 返回码和失败处理

- `0`：全部文件转换成功；
- `1`：至少一个输入或转换失败；
- `2`：缺少 FFmpeg/FFprobe、FFmpeg 不支持安全时间戳传递，或没有提供输入文件。

多个文件会逐个处理：一个失败不会阻止后续文件。FFmpeg 的原始终端输出会直接显示，随后附带步骤名称和退出码。转换使用随机命名的临时调色板和临时 GIF；失败时只清理本次创建的临时文件，不会删除源 MOV。
