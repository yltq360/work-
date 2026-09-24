# FFmpeg 放置目录

Git 仓库不包含 `ffmpeg.exe` 和 `ffprobe.exe`，因为当前 Windows 便携版单个文件略超过 GitHub 普通文件大小限制。

使用工具前，请从 [FFmpeg 官方下载页](https://ffmpeg.org/download.html)列出的 Windows build 提供方获取 FFmpeg，并将以下两个文件放到 `mov-to-gif.bat` 同一目录：

- `ffmpeg.exe`
- `ffprobe.exe`

也可以把它们所在目录加入系统 `PATH`。

本机工作副本可以保留这两个程序，但它们会被仓库根目录的 `.gitignore` 排除。
