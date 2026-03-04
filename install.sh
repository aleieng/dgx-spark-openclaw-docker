#!/usr/bin/env bash
# ============================================================
#  DGX Spark 环境安装脚本
#  功能：检查环境、安装依赖、下载模型
# ============================================================
set -euo pipefail

# ── 用户配置区（按需修改）────────────────────────────────────
MODEL_DIR="$HOME/openclaw_project/models"       # 模型下载目录
MODEL_NAME="MiniMax-M2.5-REAP-NVFP4"           # 模型文件夹名称
MODEL_REPO="lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4" # 模型仓库
# ─────────────────────────────────────────────────────────────

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║   DGX Spark · MiniMax-M2.5 · OpenClaw       ║"
    echo "║            环境安装脚本                      ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_banner

# ── 步骤 1：检查依赖 ──────────────────────────────────────────
echo -e "${YELLOW}[1/4] 检查基础依赖...${NC}"

if ! command -v docker &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker${NC}"; exit 1
fi
if ! command -v curl &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 curl，请先安装 curl${NC}"; exit 1
fi
if ! command -v npm &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 npm，请先安装 Node.js 和 npm${NC}"; exit 1
fi
echo -e "${GREEN}  ✓ 基础依赖检查通过${NC}"

# ── 步骤 2：安装 OpenClaw 和 hf-cli ───────────────────────────
echo ""
echo -e "${YELLOW}[2/4] 安装 OpenClaw 和 HuggingFace CLI...${NC}"

if ! command -v openclaw &>/dev/null; then
    echo "    正在全局安装 OpenClaw..."
    if sudo npm install -g openclaw; then
        echo -e "${GREEN}  ✓ OpenClaw 安装成功${NC}"
    else
        echo -e "${RED}  ✗ OpenClaw 安装失败，请检查 npm 配置${NC}"; exit 1
    fi
else
    echo -e "${GREEN}  ✓ OpenClaw 已安装${NC}"
fi

if ! command -v hf &>/dev/null; then
    echo "    正在安装 HuggingFace CLI..."
    if curl -LsSf https://hf.co/cli/install.sh | bash; then
        echo -e "${GREEN}  ✓ HuggingFace CLI 安装成功${NC}"
    else
        echo -e "${RED}  ✗ HuggingFace CLI 安装失败，请检查网络${NC}"; exit 1
    fi
else
    echo -e "${GREEN}  ✓ HuggingFace CLI 已安装${NC}"
fi

# ── 步骤 3：拉取 Docker 镜像 ──────────────────────────────────
echo ""
echo -e "${YELLOW}[3/4] 拉取 vLLM Docker 镜像...${NC}"
echo "    镜像名：avarok/dgx-vllm-nvfp4-kernel:v22"
if sudo docker pull avarok/dgx-vllm-nvfp4-kernel:v22; then
    echo -e "${GREEN}  ✓ Docker 镜像拉取成功${NC}"
else
    echo -e "${RED}  ✗ Docker 镜像拉取失败，请检查网络或 Docker 配置${NC}"; exit 1
fi

# ── 步骤 4：下载模型文件 ──────────────────────────────────────
echo ""
echo -e "${YELLOW}[4/4] 下载 MiniMax-M2.5-REAP-NVFP4 模型...${NC}"

if [[ -d "${MODEL_DIR}/${MODEL_NAME}" ]]; then
    echo -e "${GREEN}  ✓ 模型目录已存在，跳过下载：${MODEL_DIR}/${MODEL_NAME}${NC}"
else
    echo "    模型将下载到：${MODEL_DIR}/${MODEL_NAME}"
    echo "    仓库地址：${MODEL_REPO}"
    echo "    （模型较大，约 78GB，请耐心等待...）"
    
    # 使用 hf-mirror.com 镜像加速
    export HF_ENDPOINT=https://hf-mirror.com
    if ~/.local/bin/hf download "$MODEL_REPO" \
      --local-dir "${MODEL_DIR}/${MODEL_NAME}" \
      --repo-type model; then
        echo -e "${GREEN}  ✓ 模型下载成功！${NC}"
    else
        echo -e "${RED}  ✗ 模型下载失败，请检查网络或 hf-mirror.com 镜像站状态${NC}"; exit 1
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}🎉 环境安装完成！现在可以运行 ./start_all.sh 启动服务了。${NC}"
