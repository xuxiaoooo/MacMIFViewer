# S0 真实样本结果

**阶段结论：App 已提供样例变体的原生 MRXS 预览。** 正式通道和空间校验仍需厂商对照。当前只有一份 5 通道、8-bit JPEG 样本。S0 要求独立核验至少一份六通道样本的通道、原始像素与空间位置。

Apple M1 Pro、macOS 27.0.1、arm64 Python 3.12.3。本机只读检查 MRXS 与 sidecar，数据目录约 718 MiB。

- INI 声明 5 个滤镜、10 级金字塔、单一 extended-focus 图像。标尺声明为 X/Y 各 0.325 µm/px。
- 两个存储流在 level 0 各有 40,014 条有效记录，索引键完全一致。随机选择了 10 个共同位置，并额外读取其中一个位置的水平相邻 tile。其他层各抽最多 10 个共同位置。
- 共解码 154 个 JPEG payload，取出 385 个候选通道平面。JPEG SOF 标记精度为 8 bit，输出 `uint8`。
- 每个滤镜保存一份 64×64 的候选分量诊断 TIFF。文件使用 tile 局部坐标，位置与哈希记录在兼容性 JSON。

| INI 滤镜标签 | 存储组 / 槽 | level 0 候选槽最大值 | level 0 反向槽最大值 |
| --- | --- | ---: | ---: |
| DAPI | 0 / 0 | 55 | 112 |
| SpGreen-520 | 0 / 1 | 61 | 61 |
| CY5-690 | 0 / 2 | 112 | 55 |
| TEX REO-620 | 1 / 0 | 0 | 45 |
| SpAQUA-480 | 1 / 1 | 92 | 92 |

TEX REO-620 的 RGB 顺序候选在所有 77 个采样位置均为零。反转槽位后能读到信号，同时会交换第一个存储组中 DAPI 与 CY5-690 的候选分量。两种解释需要用官方通道图核对。

## Rust 交叉检查

Rust 候选后端给出的 level-0 尺寸是 48,896×58,112。在其坐标 `(24448, 29056)` 读取 128×128 ROI，以索引网格换算到 Python 对应 tile 内部裁剪。Rust 的分量顺序与 Python 的反向槽位吻合。五个通道的最大绝对像素差均为 1 个灰度级，平均绝对差在 0.0003–0.0031 灰度级。采用 RGB 顺序时，DAPI 和 CY5-690 的最大差均为 48，第 4 个滤镜的候选为全零。此交叉检查支持优先核对 BGR 槽位解释，滤镜身份和全片坐标仍须与厂商对照。

## 跨 tile 区域读取

开发工具已能读取候选 level-0 规则网格上的小区域，每次最多 512×512。它按区域交集取 tile，每组 tile 解码一次，再裁切独立分量。CLI 要求显式选择候选槽位顺序，遇到缺块、重叠、旋转或未知位置层就返回错误。读取过程只访问源文件，输出 JSON 数值摘要。

在此样例上固定随机种子选择了 10 个 80×80 ROI。每个 ROI 同时跨过水平和垂直 tile 接缝，覆盖四个相邻 tile。采用反向槽位，与 Rust 后端比较共 320,000 个像素，**99.895% 完全一致，最大差值 1 个灰度级**。这个测试校验了两套实现对当前网格布局的解释。官方滤镜身份与坐标仍需厂商 ROI 作为独立参照。

```sh
.venv/bin/python -m mrxs_probe.region "$SLIDE" --xywh 24448 29056 128 128 --slot-order reversed
```

复现交叉测试时，将 `tools/mrxs_probe/evaluation/region_oracle.rs` 放到固定版本的 openslide-pure-rs 的 `examples/` 目录，执行 `cargo build --features jpegxr --example region_oracle`。随后用探测器 venv 运行 `tools/mrxs_probe/evaluation/compare_regions.py "$SLIDE" "$ORACLE"`。两个变量分别是 MRXS 入口和编译出的 oracle 可执行文件。

## 补齐验收材料

1. 当前样本的官方独立灰度 TIFF。至少覆盖一组组织内位置和一组跨 tile 接缝的 ROI，附每个区域的 level-0 原点、宽高、X/Y µm/px、滤镜顺序、Z 位置、dtype 与导出处理设置。
2. 一份六通道或更多的 MRXS 及其同名 sidecar，附至少 10 个对照位置。再提供一份已知 16-bit 的真实样本和官方对照，可与六通道样本重合。
3. 核对五个滤镜的槽位，重点检查组 0 的槽 0/2 与组 1 的槽 0。确认拼接位置和尺度后，在相同坐标逐通道比较像素。若官方导出经过处理，记录偏差与导出条件。

直接读取验收期间可使用 SlideMaster 的分通道 Tiled TIFF 作为回退数据，导入前检查通道标签、图像尺寸、空间原点、标尺与位深。 [3DHISTECH SlideMaster](https://www.3dhistech.com/software/slidemaster/)

## 自动化回归

`.venv/bin/python -m unittest discover -s tools/mrxs_probe/tests -v` 通过 10 项测试，包括跨四块拼接、缺块和重叠拒绝。五份真实诊断 TIFF 回读后均为 64×64 uint8，像素哈希与 JSON 一致。真实样本探测退出码 0，报告状态为 `experimental_tile_samples`。
