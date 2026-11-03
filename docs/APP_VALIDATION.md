# Mac 应用验证记录

## 结构

`SlideReader` 抽象由合成切片和原生 TIFF 实现。TIFF 文件以只读方式打开，libtiff 句柄按文件串行访问。视口按需读取邻近视野中心的 tile，取消已过时的请求，Metal 使用 R8Unorm 或 R16Unorm 纹理和 96 MiB 的像素纹理 LRU 预算。全片预览与当前视口 tile 的缓存分开。导出从 level 0 直接读取，TIFF 逐 tile 写入，PNG 限制像素数。导出先写临时目录，所有文件完成后再移入目标目录。

## 0.3.1 JPEG 与 PNG 导出

- 在 ROI 导出菜单提供 PNG、JPEG 和 TIFF。PNG 与 JPEG 共用渲染和标尺路径。JPEG 使用质量 0.95 的有损编码。
- 独立解码验证 PNG 和 TIFF 的渲染像素一致，检查 JPEG 的图像尺寸、颜色误差及标尺，并比对三种格式的 ROI 元数据。
- 发布包为 Apple Silicon 本机开发预览构建，使用 ad-hoc 签名。

## 0.3.0 ROI、测量与标尺

- 在 App 中绘制矩形、多边形和测距线，重命名矩形并拖动顶点。验证多个条目共存和编辑后的面积变化。
- 在演示切片将 X、Y 比例同时加倍，距离随之加倍，面积变为四倍。真实 MRXS 以待核验的文件像素尺寸显示标尺。
- 在六通道 TIFF 上保存命名 ROI 和灰度设置，重开文件恢复。测试覆盖本地设置序列化、非方形像素的距离和面积、自相交多边形拒绝，以及灰度和热度映射。
- 独立回读带标尺的 PNG 与分块 TIFF，校验图像一致、标尺位置、ROI 名称和校准来源。真实 MRXS 的 338,000 个抽样像素与探测器逐像素一致。

## 0.2.1 MRXS 颜色显示

- 读取 INI 中的 `COLOR_*`、启用时的 `MODIFIED_COLOR_*` 和有效 `GAMMA`。样例色表为蓝、绿、粉红、红、白。
- 根据概览非零像素的分位数设置每通道黑白点，保留高分辨率亮部余量。样例五个默认显示窗口依次为 4–26、7–25、7–25、3–18、6–48。界面验证打开样例后使用该范围，并保留手动调整。
- 使用同一份解码概览和同一色表对比 0–255 映射与新范围。RGB 最大与最小分量相差至少 32 的像素从 0 增至 5,902 个，概览共 10,735 个像素。10 个跨 tile 区域和各金字塔层的像素回归仍然一致。
- INI 的厂商 Brightness / Contrast 数值在此版本不参与映射。与 SlideViewer 的具体呈现需要相同位置、倍率与通道开关的并排对照。

## 0.2.0 原生 MRXS 预览

- Swift 读取同名目录中的 INI、Index 和 Data 文件。使用原有静态 libjpeg-turbo 解码 8-bit IPP JPEG 三分量，按存储组批量解码。发布包无需额外运行时。
- 本机窗口直接打开用户样例，显示五个候选通道、48,896×58,112 像素全片，验证适合窗口、缩放和第 4 通道单显。
- 用 `scripts/test-app.sh "$SLIDE"` 复查真实样本和 TIFF 回归。原生后端与独立 Python 探测器在 10 个 level-0 跨 tile 区域的 320,000 个像素完全一致，并对其余九级分别做取样比较。厂商滤镜对应关系和绝对空间坐标仍待独立验证。
- MRXS 原始像素导出和物理标尺关闭。渲染导出的 JSON 标明候选网格、待核验通道和未扫描区域的显示规则。

## 0.1.x 本机验证

- Apple M1 Pro、16 GiB、macOS 27.0.1。应用为 arm64，二进制声明最低 macOS 14.0。通过本地签名核验。依赖检查显示 TIFF 与 JPEG 库静态链接。
- 独立生成一份 6 通道、16-bit、大端序 BigTIFF 及 SubIFD 金字塔，另生成 LZW 分块、Deflate strip、灰度 JPEG、IFD 反序、RGB 和尺寸不匹配样本。读取层验证通道顺序、坐标、边缘与跨 tile/strip 的像素值。
- 在 ROI 导出测试中，原始 uint8 和 uint16 保留。调整显示参数后再导出的 6 通道原始 ROI 仍和输入逐像素一致。独立 Python 解码验证了 TIFF 与 PNG 的渲染像素一致性。
- 在实际窗口验证 Metal 六通道演示、单显、缩放、矩形选择、原生文件选择器和导出面板。窗口打开六通道 BigTIFF 后导出 80×54 ROI，独立回读确认六个 uint16 平面逐像素一致。用本地占位 MRXS 验证转换提示。
- 原始 MRXS 回归通过 7 项测试。真实提供的样本仍处于实验性 tile 诊断阶段。
- 当前版本验证范围是本机开发构建。另一台干净 Mac、15 分钟真实 WSI 交互和缓存 P95 指标仍待有对照的实际数据验证。

## 依赖

构建脚本下载并锁定 libtiff 4.7.2 和 libjpeg-turbo 3.1.3。依赖许可文本随应用打包。

This software is based in part on the work of the Independent JPEG Group.

- [LibTIFF](https://libtiff.gitlab.io/libtiff/releases/v4.7.2.html)
- [libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo/releases/tag/3.1.3)
- [OME-TIFF 规范](https://ome-model.readthedocs.io/en/stable/ome-tiff/specification.html)
