# OpenFang DIY

OpenFang 个人定制脚本。

## 脚本说明

### setup-assistant.sh — 一键配置助手 Agent

新安装 OpenFang 后运行，自动完成：

1. 配置全局安全策略（关闭审批、开放 shell 执行）
2. 修改 assistant agent 为 glm-5 模型（不动 system_prompt）
3. 交互式输入 API Key（ZHIPU / DingTalk / Gemini）
4. 重启 daemon 并验证

```bash
cp setup-assistant.sh ~/.openfang/
chmod +x ~/.openfang/setup-assistant.sh
~/.openfang/setup-assistant.sh
```

### update-openfang.sh — 自动更新 + DingTalk Stream 补丁

拉取最新 OpenFang 源码，替换 dingtalk.rs 为 Stream 版本，编译并替换二进制。

```bash
cp update-openfang.sh ~/.openfang/
chmod +x ~/.openfang/update-openfang.sh
~/.openfang/update-openfang.sh          # 正常更新
~/.openfang/update-openfang.sh --force  # 强制更新
~/.openfang/update-openfang.sh --check  # 只检查版本
```

## 前置要求

- OpenFang 已安装（`~/.openfang/bin/openfang`）
- Rust 工具链（用于编译更新）
- DingTalk Stream 补丁文件（`~/.openfang/patches/dingtalk_stream.rs`）
