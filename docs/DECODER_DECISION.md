# S0 解码器评估

当前 Python 探测器在本机只读执行。三个候选在独立开发目录评估，未加入应用依赖。完整应用后端的选择依赖独立 ROI 对照。

## A. mrxs2ometiff

- 版本 2026.5.20，提交 `f38375741d699e96d9b60a41dbc8708e90543e7f`。项目元数据声明 LGPL-2.1-only。该检出未发现独立许可证正文，后续集成前需确认许可与依赖分发条件。
- 在 arm64 venv 中用候选项目的 `parse_ini` 实读样例。抛出 `KeyError: 'LAYER_1_LEVEL_0_SECTION'`。它将 `HIER_1` 当作滤镜层，样例的该层是 zoom mask，滤镜定义在 `HIER_2`。
- `convert_one` 走 JPEG XR 解码与 uint16 转换，使用全幅磁盘 memmap，并可做配准和混合。它未提供惰性 ROI API。此次评估止于真实样本的元数据失败。
- 复现方式为在当前 venv 的 `PYTHONPATH` 加入该提交的 `src`，调用 `mrxs2ometiff.reader.parse_ini(Path(sidecar) / "Slidedat.ini")`。

[mrxs2ometiff 源码](https://github.com/Pamarcoux/mrxs2ometiff/tree/f38375741d699e96d9b60a41dbc8708e90543e7f)

## B. openslide-pure-rs

- 版本 0.2.2，提交 `cde6ea16c49ea60229172e74f4e1abfe0743fa25`，Cargo 声明 LGPL-2.1-only。Rust 1.99.1，aarch64-apple-darwin。
- `OpenSlide::read_region(channel, …)` 的 MIRAX 结果是单灰度 `GrayImage`，其缓冲类型是 `Vec<u8>`。代码存在多存储组与槽位转换逻辑。Cargo 的 `jpegxr` feature 本身不足以证明 MIRAX 路径支持 JPEG XR 或保留 uint16。
- 在 Apple Silicon 上启用 `jpegxr` feature 构建成功。后端报告 48,896×58,112、10 级、5 通道，读取了中心位置的五份 128×128 灰度 ROI。其全片尺寸与元数据网格乘 tile 大小一致，官方坐标原点仍待核对。
- 样例的注释以 `Intel(R) IPP JPEG encoder` 开头，与该提交分类器检查的 `Intel(R) JPEG Library` 不同。Rust 此次采用反向槽位，中心 ROI 与 Python 反向候选在每个像素上最多相差 1 个 8-bit 灰度级。两种解码器的输出哈希均有差异。详见阶段结果。

将项目中的 `tools/mrxs_probe/evaluation/s0_probe.rs` 放到候选仓库的 `examples/`，再执行 `cargo run --features jpegxr --example s0_probe -- "$SLIDE"`，其中 `SLIDE` 指向本机入口文件。

[openslide-pure-rs 源码](https://github.com/henriksson-lab/openslide-pure-rs/tree/cde6ea16c49ea60229172e74f4e1abfe0743fa25)

## C. bioformats2raw

- 版本 0.14.0-SNAPSHOT，提交 `14be604d738a4766bbfad9fb9c19165d8b34990e`，仓库附 GNU GPL v2 文本。Java 17.0.2 和 Gradle 9.3.1 下 `./gradlew --no-daemon installDist` 成功。
- 直接运行实验性 `MiraxReader.setId`，样例初始化报 `FormatException: Tile positions not found, image will be incorrect`。此次未得到 Java ROI，也未运行全幅转换。
- 复现时在候选仓库执行 `java -cp 'build/install/bioformats2raw/lib/*' /path/to/MiraxSpike.java "$SLIDE"`，探针源文件在 `tools/mrxs_probe/evaluation/`。上游 DEBUG 日志可能包含私有元数据，请仅在本机私有位置留存。

[bioformats2raw 源码](https://github.com/glencoesoftware/bioformats2raw/tree/14be604d738a4766bbfad9fb9c19165d8b34990e) · [第 4 通道问题记录](https://github.com/glencoesoftware/bioformats2raw/issues/244)

## D. 阶段决策

保留 Python 用于独立诊断。0.2.0 按用户要求接入样例变体的原生 MRXS 预览，复用现有 libjpeg-turbo。厂商通道标签、拼接原点和空间尺度仍需核验，原始数据导出保持关闭。
