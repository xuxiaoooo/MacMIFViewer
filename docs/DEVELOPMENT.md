# 开发与构建

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

- [格式兼容性](FORMAT_COMPATIBILITY.md)
- [真实样本 S0 结果与跨 tile 区域读取](spike_results.md)
- [解码器评估](DECODER_DECISION.md)
