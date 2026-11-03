# Mac MIF Viewer

Apple Silicon 上运行的原生荧光切片查看器。开发预览版 0.3.1。

## 打开应用

从 [GitHub Releases](https://github.com/xuxiaoooo/MacMIFViewer/releases/latest) 下载 arm64 ZIP，解压后打开 `Mac MIF Viewer.app`。从源码构建的产物位于 `dist/`。启动时显示六通道合成演示。应用将 libtiff 和 libjpeg-turbo 静态链接到程序中。查看和导出在本机完成，运行时只需要 macOS 自带框架。

## 查看切片

1. 点击 **打开切片…**，选择一个 MRXS 或单文件 OME-TIFF，或多选同一空间位置、分辨率和焦平面的灰度 TIFF。分通道文件按自然文件名顺序载入。
2. 滚轮或双指捏合缩放，拖拽平移。点击右侧全片导航可定位，也可以点 **适合窗口** 返回全片。
3. 通道列表可切换可见性、单显和 Merge。每通道可用伪彩、灰度或热度色图，并调黑点、白点和 Gamma。伪彩支持 RGB 拉条、快捷色样和系统色板。
4. 用 **矩形** 拖出 ROI，或用 **多边形** 逐点点击后双击、回车或按 **完成多边形**。用 **测距** 拖出线段。右侧 **ROI 与测量** 可选择、重命名、定位或删除条目。选中条目后拖动顶点即可编辑。Esc 取消绘制或选中状态。
5. 在 **标尺** 菜单中切换显示，或输入独立核验的 X、Y 像素尺寸。MRXS 文件标尺默认标注待核验。没有物理尺寸时显示像素标尺。
6. **导出 ROI** 针对当前选中的矩形或多边形。渲染 PNG、JPEG 和 TIFF 在标尺开启时附带标尺。PNG 为无损图像，JPEG 为质量 0.95 的有损图像。每次创建一个新目录，含图像、ROI JSON 和 CSV。多边形图像为 level-0 外接矩形，顶点单独记录。PNG 和 JPEG 的 ROI 限制在 1200 万像素和单边 8192 px 以内。
7. 本地切片的 ROI、校准和通道显示设置会自动保存至应用支持目录，重开同一文件时恢复。

## 兼容范围

- 1–8 个独立的 uint8 / uint16 灰度通道。OME-TIFF 支持单文件、单图像、单 Z/T、IFD 通道映射和 SubIFD 金字塔。分通道 TIFF 支持独立单平面与 SubIFD。
- 支持有界 tile/strip 读取。构建测试覆盖 Deflate、LZW 和灰度 JPEG。没有足够低分辨率级的大片，缩小时使用明确标注的稀疏概览。
- 可浏览混合位深的分通道 TIFF。Raw OME-TIFF 要求所有通道同位深，并输出全部通道的解码像素。渲染导出应用通道可见性、单显、强度映射和伪彩。
- 文件物理标尺来自 OME-XML、一致的 TIFF Resolution 标签或 MRXS 声明值。MRXS 声明值保持待核验状态。手动校准和测量结果记录在导出 JSON。
- MRXS 原生预览支持本机样例的 8-bit IPP JPEG 规则网格变体。将 `.mrxs` 与同名配套目录放在同一位置，从应用打开入口文件即可。支持全片导航和独立通道显示。
- MRXS 默认采用切片保存的通道伪彩和 Gamma，并从全片概览估计每通道显示范围。可用「自动对比度」恢复这些范围。亮度和对比度曲线由本 App 计算。
- MRXS 预览采用候选反向槽位，未扫描区域显示为黑色。厂商通道、物理标尺和全片坐标核验完成前，MRXS 只开放渲染预览导出。16-bit、JPEG XR、带位置偏移和多焦平面的 MRXS 仍需各自验证。

## 开发构建与回归

```sh
cd MacMIFViewer
scripts/build-app.sh
scripts/test-app.sh
```

首次构建需要 Apple Command Line Tools，以及用于编译依赖的 CMake 或带 venv 的 Python。回归脚本使用下方探测器 venv。应用目标为 Apple Silicon 和 macOS 14+，当前实测为 Apple M1 Pro、macOS 27.0.1。构建产物使用本地 ad-hoc 签名，跨设备分发需另行验证 Developer ID 签名与公证。

## S0 MRXS 探测器

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r tools/mrxs_probe/requirements.lock
.venv/bin/python -m pip install --no-deps -e tools/mrxs_probe
.venv/bin/python -m mrxs_probe inspect '/path/to/Sample.mrxs' \
  --report local/compatibility.json --roi-dir local/diagnostic-rois
.venv/bin/python -m unittest discover -s tools/mrxs_probe/tests -v
```

保留同名 sidecar 目录。每次运行选择新的输出路径。省略 `--roi-dir` 可只生成 JSON。退出码 0 表示完成诊断采样，2 表示输入或兼容性错误，1 表示输出写入失败。是否通过原生读取验收请查阅报告和阶段结论。

- [格式兼容性](docs/FORMAT_COMPATIBILITY.md)
- [真实样本 S0 结果与跨 tile 区域读取](docs/spike_results.md)
- [解码器评估](docs/DECODER_DECISION.md)
