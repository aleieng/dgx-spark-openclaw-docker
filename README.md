# DGX Spark + OpenClaw 本地大模型部署方案

本项目提供了一套在 NVIDIA DGX Spark 上一键部署本地大模型（以 MiniMax-M2.5-REAP-NVFP4 为例）并接入 OpenClaw 作为 AI Agent 前端的完整解决方案。

## 特性

- **一键部署**：提供 `install.sh`, `start_all.sh`, `stop.sh` 三个脚本，实现环境安装、服务启动、服务停止的全流程自动化。
- **DGX Spark 专属优化**：使用 `avarok/dgx-vllm-nvfp4-kernel` 社区优化镜像，充分利用 GB10 架构的 NVFP4 量化能力。
- **本地化模型**：所有推理均在本地 DGX Spark 完成，数据无需上云，零 API 成本。
- **动态日志**：启动脚本实时显示 vLLM 模型加载日志，进度一目了然。
- **局域网访问**：自动配置 Gateway，生成带 token 的局域网访问链接，方便团队协作和黑客松活动。

## 快速开始

**硬件要求**：NVIDIA DGX Spark

**软件要求**：Ubuntu 22.04+, Docker, Node.js/npm, curl

### 1. 克隆仓库

```bash
git clone <your-repo-url>
cd dgx-spark-openclaw
```

### 2. 安装环境与模型（首次运行）

该脚本会自动检查依赖、安装 OpenClaw、拉取 Docker 镜像、并下载约 78GB 的模型文件，请确保网络通畅和足够的磁盘空间。

```bash
chmod +x install.sh
./install.sh
```

### 3. 启动所有服务

该脚本会自动启动 vLLM 推理服务和 OpenClaw Gateway，并打印出浏览器访问链接。

```bash
chmod +x start_all.sh
./start_all.sh
```

将脚本输出的“局域网访问”链接复制到浏览器即可开始使用。

### 4. 停止所有服务

```bash
chmod +x stop.sh
./stop.sh
```

## 目录结构

```
. 
├── install.sh          # 环境安装与模型下载脚本
├── start_all.sh        # 一键启动所有服务脚本
├── stop.sh             # 一键停止所有服务脚本
├── docs/
│   └── deployment_guide.md # 详细部署与排错文档
└── README.md           # 本文档
```

## 详细文档

完整的部署步骤、参数解析、常见问题排查，请参考 [详细部署文档](./docs/deployment_guide.md)。

## 贡献

欢迎提交 Pull Request 或 Issue。

## License

MIT
[MIT](./LICENSE)
