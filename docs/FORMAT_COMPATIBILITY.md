# MRXS 格式兼容性

| 对象 | 当前证据 |
| --- | --- |
| 样例文件布局 | 同名入口和 sidecar，38 个索引引用的数据文件 |
| 样例索引 | Index.dat 01.02，zoom/mask/filter/focus 层级，按元数据使用混合基数定位候选流 |
| 压缩 | 实测样例为 8-bit JPEG，三分量数据使用 Adobe transform 0、4:4:4、Intel IPP 标记 |
| 通道 | 依据滤镜声明与存储槽列出候选通道，原始滤镜身份和槽位顺序待官方对照 |
| 焦平面 | 当前探测范围为显式零 Z 步长及单一 extended-focus 层 |
| JPEG XR | 本机合成灰度 uint16 编解码和索引读取测试通过，真实 MRXS JPEG XR 待验证 |
| 像素尺寸 | 报告 INI 声明的 X/Y 值，缺失时返回 null |
| 拼接与尺寸 | tile 索引网格与 tile 内坐标已记录，拼接位置和全片尺寸待独立核对 |
| 诊断 TIFF | 单分量 tile 内裁剪，保留解码 dtype，省略物理标尺和全片原点 |

`verified_decodable_channel_count` 统计在 level 0 至少一次成功取到所请求候选分量的元数据通道。`verified_raw_bit_depth` 保持 null，`encoded_sample_precision_bits` 单独记录 JPEG SOF 精度。`reversed_slot_candidate` 记录 level 0 上反向槽位的摘要，用于比较 RGB/BGR 两种解释。

探测报告同时记录各流索引数量、相同索引位置数、选中 tile 的压缩类型和像素摘要。相邻索引测试只确认两侧 payload 可读，拼接接缝的几何与像素准确性需要官方区域对照。
