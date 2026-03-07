# DGX Spark + OpenClaw: 本地大模型一键部署方案

本项目提供了一套在 NVIDIA DGX Spark 上一键部署本地大模型（以 MiniMax-M2.5-REAP-NVFP4 为例）并接入 OpenClaw 作为 AI Agent 前端的完整解决方案。

## 特性

- **一键部署**：提供 `install.sh`, `start_all.sh` 两个脚本，实现环境安装、服务启动的全流程自动化。
- **DGX Spark 专属优化**：使用 `avarok/dgx-vllm-nvfp4-kernel` 社区优化镜像，充分利用 GB10 架构的 NVFP4 量化能力。
- **中国网络优化**：安装脚本内置国内镜像源，无需 VPN 即可高速下载 Docker 镜像和 HuggingFace 模型。
- **断点续传**：模型下载支持断点续传，可随时中断并重新运行脚本继续下载。
- **动态端口**：支持通过 `--port` 参数指定 OpenClaw Gateway 对外端口，避免端口冲突。
- **本地化推理**：所有推理均在本地 DGX Spark 完成，数据无需上云，零 API 成本。

## 快速开始

**硬件要求**：NVIDIA DGX Spark

**软件要求**：Ubuntu 22.04+, Docker, Node.js/npm, curl, wget, jq

### 1. 克隆仓库

```bash
git clone https://github.com/your-username/dgx-spark-openclaw.git
cd dgx-spark-openclaw
```

### 2. 安装环境与模型（首次运行）

该脚本会自动检查并安装依赖、拉取 Docker 镜像、并下载约 78GB 的模型文件。请确保网络通畅和足够的磁盘空间。

```bash
chmod +x install.sh
./install.sh
```

### 3. 启动所有服务

该脚本会自动启动 vLLM 推理服务和 OpenClaw Gateway，并打印出浏览器访问链接。

```bash
chmod +x start_all.sh

# 使用默认端口 18789 启动
./start_all.sh

# 或指定端口 8080 启动
./start_all.sh --port 8080
```

将脚本输出的“局域网访问”链接复制到浏览器即可开始使用。

### 4. 停止所有服务

```bash
./start_all.sh stop
```

## 脚本说明

| 脚本 | 功能 |
|---|---|
| `install.sh` | 自动安装所有依赖、配置国内镜像、拉取 Docker 镜像、下载 HuggingFace 模型 |
| `start_all.sh` | 一键启动 vLLM 推理服务和 OpenClaw Gateway，支持 `--port` 参数和 `stop` 命令 |

## 详细文档

完整的部署步骤、参数解析、常见问题排查，请参考 [详细部署文档](./docs/deployment_guide.md)。

## 贡献

欢迎提交 Pull Request 或 Issue。

## 作者

Ken He

## License

[MIT](./LICENSE)
