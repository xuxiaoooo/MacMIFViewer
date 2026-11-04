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

## 发布可自动安装的版本

更新器从 GitHub 的最新正式 Release 检查版本。使用递增的 `v主.次.补丁` 标签，并更新 `Info.plist` 中的版本和构建号。Release 必须同时上传 arm64 ZIP 和与之对应的 64 字节 Ed25519 签名。先上传两个文件到草稿，再发布为最新正式版。

```sh
scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ViewerApp/Resources/Info.plist)
public_key=$(/usr/libexec/PlistBuddy -c 'Print :MIFUpdatePublicKey' ViewerApp/Resources/Info.plist)
zip="$PWD/.build/Mac-MIF-Viewer-${version}-arm64.zip"
key="$HOME/Library/Application Support/MacMIFViewer Release Signing/update-ed25519.key"
ditto -c -k --keepParent 'dist/Mac MIF Viewer.app' "$zip"
xcrun swift scripts/sign-update.swift "$key" "$zip" "$public_key"
gh release create "v${version}" "$zip" "$zip.sig" --verify-tag --draft
```

私钥只存放在发布者机器上并保留安全备份。仓库和安装包只包含公钥。初次为独立分支建立信任时，可在仓库外的私有目录使用 `umask 077` 和 `scripts/sign-update.swift --generate`（通过 `xcrun swift` 运行）生成密钥，将输出的公钥放入该分支的 `MIFUpdatePublicKey`。现有安装依赖原有公钥，常规发布需要沿用原签名密钥。更新签名用于校验 ZIP 的来源和完整性，Apple Developer ID 签名及公证另行处理。
