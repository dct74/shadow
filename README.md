# Shadow

一个轻量级的 Swift 命令行工具，为 PNG、JPEG 等格式的图片自动添加 macOS 风格的双层窗口阴影效果。

## 功能特性

- **双层阴影复刻** — 模拟 macOS 窗口阴影的两层叠加效果（外层大范围淡阴影 + 内层紧致深阴影），视觉效果自然真实
- **批量处理** — 支持同时传入多个文件或文件夹路径，自动递归扫描目录下的所有图片
- **保持原始比例** — 在原图四周扩展透明区域绘制阴影，不裁剪、不缩放原图
- **保留元数据** — 输出图片会保留原始文件的 EXIF 等信息
- **命令行友好** — 轻量无依赖，处理时显示旋转动画，处理完成后按颜色区分成功/失败数量
- **广泛格式支持** — 输入支持 PNG、JPEG、BMP、TIFF、WebP，输出统一为 PNG

## 环境要求

- Apple Silicon macOS 12.0+ (Monterey 及以上)
- Xcode 14+ 或 Swift 5.7+（仅编译时需要）
- 运行无需额外依赖

## 安装

```bash
brew install --formula dct74/tap/shadow
```

## 使用方法

### 基本用法

```bash
# 处理单张图片
./shadow path/to/image.png

# 同时处理多张图片
./shadow image1.png image2.jpeg image3.webp

# 处理文件夹内所有图片（递归）
./shadow path/to/folder/

# 同时处理多个文件夹和文件
./shadow folder1/ folder2/ image.png
```

### 输出

处理后的图片保存在原图同目录下，命名格式为 `原文件名_shadow.png`。

例如：
- `photo.png` → `photo_shadow.png`
- `screenshot.jpeg` → `screenshot_shadow.png`

### 效果预览

工具会在图片四周添加 **130px** 的透明内边距，并绘制两层叠加阴影：

| 参数 | 外层阴影 | 内层阴影 |
|------|---------|---------|
| 偏移量 (Y) | -8px | -18px |
| 模糊半径 | 70px | 50px |
| 颜色/不透明度 | 黑色 / 10% | 黑色 / 30% |

## 示例

```bash
# 为截图添加阴影
./shadow ~/Desktop/screenshot.png
# 输出: ~/Desktop/screenshot_shadow.png

# 批量处理某个目录下所有图片
./shadow ~/Pictures/screenshots/
```

## 技术说明

- 基于 **CoreGraphics** 和 **AppKit** 框架实现图像处理
- 使用 `CGContext` 的 `setShadow` API 实现双层阴影绘制
- 通过 Alpha 遮罩（`makeAlphaMask`）提取图像轮廓作为阴影基准，确保阴影贴合图片透明边缘
