#!/usr/bin/env bash
# ============================================================
#  DGX Spark 环境安装脚本
#  功能：检查环境、自动安装依赖、下载模型
# ============================================================
set -euo pipefail

# ── 用户配置区（按需修改）────────────────────────────────────
MODEL_DIR="$HOME/openclaw_project/models"               # 模型下载目录
MODEL_NAME="MiniMax-M2.5-REAP-NVFP4"                   # 模型文件夹名称
MODEL_REPO="lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4" # HuggingFace 仓库
HF_ENDPOINT="https://hf-mirror.com"                    # 国内镜像源（无需科学上网）
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

# ── 步骤 1：检查并安装基础依赖 ────────────────────────────────
echo -e "${YELLOW}[1/5] 检查基础依赖...${NC}"

# Docker（必须手动安装，脚本无法自动处理）
if ! command -v docker &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker：https://docs.docker.com/engine/install/ubuntu/${NC}"
    exit 1
fi

# 检查 Docker 权限：如果当前用户无法访问 Docker Socket，自动将其加入 docker 组
if ! docker info &>/dev/null 2>&1; then
    echo "    当前用户没有 Docker 权限，正在自动修复..."
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}  ⚠ 已将用户 ${USER} 加入 docker 组。${NC}"
    echo -e "${YELLOW}    请运行以下命令使权限生效，然后重新运行本脚本：${NC}"
    echo -e "${CYAN}      newgrp docker${NC}"
    echo -e "${CYAN}      或者注销重新登录： logout 然后重新 SSH${NC}"
    exit 0
fi
echo -e "${GREEN}  ✓ docker${NC}"

# curl
if ! command -v curl &>/dev/null; then
    echo "    正在安装 curl..."
    sudo apt-get update -qq && sudo apt-get install -y curl
fi
echo -e "${GREEN}  ✓ curl${NC}"

# wget（模型下载必须）
if ! command -v wget &>/dev/null; then
    echo "    正在安装 wget..."
    sudo apt-get update -qq && sudo apt-get install -y wget
fi
echo -e "${GREEN}  ✓ wget${NC}"

# Node.js + npm（使用 NodeSource 官方脚本安装 LTS 版本）
if ! command -v npm &>/dev/null; then
    echo "    未找到 npm，正在自动安装 Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
    echo -e "${GREEN}  ✓ Node.js $(node -v) / npm $(npm -v) 安装成功${NC}"
else
    echo -e "${GREEN}  ✓ Node.js $(node -v) / npm $(npm -v)${NC}"
fi

# ── 步骤 2：安装 OpenClaw ──────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/5] 安装 OpenClaw...${NC}"

if ! command -v openclaw &>/dev/null; then
    echo "    正在全局安装 OpenClaw..."
    # 强制 npm 使用 HTTPS 替代 SSH 访问 GitHub，避免 publickey 错误
    git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
    git config --global url."https://github.com/".insteadOf "git@github.com:"
    if sudo npm install -g openclaw; then
        echo -e "${GREEN}  ✓ OpenClaw $(openclaw --version 2>/dev/null || echo '') 安装成功${NC}"
    else
        echo -e "${RED}  ✗ OpenClaw 安装失败，请检查 npm 配置${NC}"; exit 1
    fi
else
    echo -e "${GREEN}  ✓ OpenClaw 已安装${NC}"
fi

# ── 步骤 3：安装 HuggingFace CLI（仅用于鉴权，下载由 wget 完成）──
echo ""
echo -e "${YELLOW}[3/5] 检查工具依赖...${NC}"

# 确保 jq 可用（用于解析 HF API JSON）
if ! command -v jq &>/dev/null; then
    echo "    正在安装 jq..."
    sudo apt-get update -qq && sudo apt-get install -y jq
fi
echo -e "${GREEN}  ✓ jq${NC}"

# ── 步骤 4：准备 vLLM Docker 镜像 ──────────────────────────────────
echo ""
echo -e "${YELLOW}[4/5] 准备 vLLM Docker 镜像...${NC}"
echo "    目标镜像：avarok/dgx-vllm-nvfp4-kernel:v22"
echo ""

# 检查镜像是否已在本地
if docker image inspect avarok/dgx-vllm-nvfp4-kernel:v22 &>/dev/null; then
    echo -e "${GREEN}  ✓ 镜像已在本地，跳过拉取${NC}"
else
    # ── 方案 A：写入最新国内镜像源并重启 Docker ──
    echo "    写入国内镜像加速源（每次刷新，确保最新可用列表）..."
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json > /dev/null <<'DOCKEREOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://hub.rat.dev",
    "https://dockerproxy.net",
    "https://proxy.vvvv.ee",
    "https://docker.m.daocloud.io",
    "https://registry.cyou"
  ]
}
DOCKEREOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    sleep 3
    echo -e "${GREEN}  ✓ Docker 国内镜像加速已配置${NC}"

    # ── 方案 A1：通过 registry-mirrors 直接 pull ──
    echo "    尝试通过 registry-mirrors 拉取镜像..."
    echo "    ────────────────────────────────────────"
    set +e
    docker pull avarok/dgx-vllm-nvfp4-kernel:v22
    PULL_STATUS=$?
    set -e
    echo "    ────────────────────────────────────────"

    # ── 方案 A2：如果 A1 失败，逐一尝试镜像源前缀拉取 ──
    if [[ $PULL_STATUS -ne 0 ]]; then
        echo -e "${YELLOW}  ⚠ registry-mirrors 方式失败，改用镜像源前缀拉取...${NC}"
        # 列表顺序为 2025-2026 年实测可用源（dongyubin/DockerHub 中收录）
        MIRROR_PREFIXES=(
            "docker.1ms.run"
            "hub.rat.dev"
            "dockerproxy.net"
            "proxy.vvvv.ee"
            "docker.m.daocloud.io"
            "registry.cyou"
        )
        TARGET_IMAGE="avarok/dgx-vllm-nvfp4-kernel:v22"
        for MIRROR in "${MIRROR_PREFIXES[@]}"; do
            MIRROR_IMAGE="${MIRROR}/${TARGET_IMAGE}"
            echo "    尝试： docker pull ${MIRROR_IMAGE}"
            echo "    ────────────────────────────────────────"
            set +e
            docker pull "${MIRROR_IMAGE}"
            PULL_STATUS=$?
            set -e
            echo "    ────────────────────────────────────────"
            if [[ $PULL_STATUS -eq 0 ]]; then
                # 拉取成功，重标签为标准名称
                docker tag "${MIRROR_IMAGE}" "${TARGET_IMAGE}"
                echo -e "${GREEN}  ✓ 通过 ${MIRROR} 拉取成功，已重标签为 ${TARGET_IMAGE}${NC}"
                break
            else
                echo -e "${YELLOW}    该镜像源失败，尝试下一个...${NC}"
            fi
        done
    fi

    if [[ $PULL_STATUS -eq 0 ]]; then
        echo -e "${GREEN}  ✓ Docker 镜像拉取成功${NC}"
    else
        # ── 方案 B：所有镜像源均失败，尝试从 GitHub 本地构建 ──
        echo -e "${YELLOW}  ⚠ 所有镜像源均失败，尝试本地构建镜像...${NC}"
        BUILD_DIR="/tmp/dgx-vllm-build"
        rm -rf "$BUILD_DIR"
        echo "    正在克隆 avarok/dgx-vllm 仓库..."
        set +e
        git clone --depth=1 https://github.com/Avarok-Cybersecurity/dgx-vllm.git "$BUILD_DIR"
        CLONE_STATUS=$?
        set -e
        if [[ $CLONE_STATUS -eq 0 ]]; then
            echo "    正在本地构建 Docker 镜像（首次构建需要 30-60 分钟）..."
            echo "    ────────────────────────────────────────"
            set +e
            docker build -t avarok/dgx-vllm-nvfp4-kernel:v22 "$BUILD_DIR"
            BUILD_STATUS=$?
            set -e
            echo "    ────────────────────────────────────────"
            if [[ $BUILD_STATUS -eq 0 ]]; then
                echo -e "${GREEN}  ✓ 镜像本地构建成功${NC}"
                rm -rf "$BUILD_DIR"
            else
                echo -e "${RED}  ✗ 镜像构建失败${NC}"
                echo -e "${YELLOW}    请手动拉取镜像后重新运行本脚本：${NC}"
                echo -e "${CYAN}    docker pull avarok/dgx-vllm-nvfp4-kernel:v22${NC}"
                exit 1
            fi
        else
            echo -e "${RED}  ✗ GitHub 克隆失败${NC}"
            echo -e "${YELLOW}    请手动拉取镜像：${NC}"
            echo -e "${CYAN}    docker pull avarok/dgx-vllm-nvfp4-kernel:v22${NC}"
            echo -e "    或先配置镜像源再重试："
            echo -e "${CYAN}    sudo tee /etc/docker/daemon.json <<'EOF'${NC}"
            echo -e "${CYAN}    {\"registry-mirrors\":[\"https://docker.1ms.run\",\"https://hub.rat.dev\"]}${NC}"
            echo -e "${CYAN}    EOF${NC}"
            echo -e "${CYAN}    sudo systemctl restart docker && docker pull avarok/dgx-vllm-nvfp4-kernel:v22${NC}"
            exit 1
        fi
    fi
fi

# ── 步骤 5：下载模型文件 ──────────────────────────────────────
# 策略：通过 HF API 获取文件列表和大小，用 wget -c 逐文件下载
# 完全绕过 XetHub 协议（cas-bridge.xethub.hf.co），直接走 hf-mirror.com HTTP
# 支持断点续传：重复运行时自动跳过已完整下载的文件
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[5/5] 下载 MiniMax-M2.5-REAP-NVFP4 模型...${NC}"

DEST_DIR="${MODEL_DIR}/${MODEL_NAME}"
HFD_CACHE="${DEST_DIR}/.hfd"
METADATA_FILE="${HFD_CACHE}/repo_metadata.json"

mkdir -p "$DEST_DIR" "$HFD_CACHE"

echo "    下载目录：${DEST_DIR}"
echo "    仓库地址：${MODEL_REPO}"
echo "    镜像源：  ${HF_ENDPOINT}"
echo "    模型约 78GB，支持断点续传，可随时 Ctrl+C 后重新运行继续"
echo ""

# ── 5.1 获取仓库文件元数据 ──
API_URL="${HF_ENDPOINT}/api/models/${MODEL_REPO}"
echo "    正在获取文件列表（${API_URL}）..."
HTTP_CODE=$(curl -L -s -w "%{http_code}" -o "$METADATA_FILE" "$API_URL")
if [[ "$HTTP_CODE" != "200" ]]; then
    echo -e "${RED}  ✗ 无法获取文件列表（HTTP ${HTTP_CODE}），请检查网络或镜像源是否可用${NC}"
    echo -e "    API URL: ${API_URL}"
    rm -f "$METADATA_FILE"
    exit 1
fi
echo -e "${GREEN}  ✓ 文件列表获取成功${NC}"

# ── 5.2 解析文件列表（rfilename + size）──
# 使用 jq 解析，输出格式：<size> <rfilename>（每行一个文件）
FILE_LIST=$(jq -r '.siblings[] | select(.rfilename != null) | [(.size // 0 | tostring), .rfilename] | join(" ")' "$METADATA_FILE")
TOTAL_FILES=$(echo "$FILE_LIST" | grep -c '.' || true)
echo "    共 ${TOTAL_FILES} 个文件需要检查"
echo ""

# ── 5.3 逐文件检查完整性并下载 ──
DOWNLOADED=0
SKIPPED=0
FAILED=0

while IFS=' ' read -r EXPECTED_SIZE RFILENAME; do
    [[ -z "$RFILENAME" ]] && continue

    LOCAL_FILE="${DEST_DIR}/${RFILENAME}"
    FILE_DIR=$(dirname "$LOCAL_FILE")
    mkdir -p "$FILE_DIR"

    # 检查文件是否已完整下载（大小匹配）
    if [[ -f "$LOCAL_FILE" && "$EXPECTED_SIZE" -gt 0 ]]; then
        ACTUAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || echo 0)
        if [[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]]; then
            echo -e "    ${GREEN}[跳过]${NC} ${RFILENAME} （已完整，${EXPECTED_SIZE} 字节）"
            SKIPPED=$((SKIPPED + 1))
            continue
        elif [[ "$ACTUAL_SIZE" -gt 0 ]]; then
            echo "    [续传] ${RFILENAME} （已有 ${ACTUAL_SIZE}/${EXPECTED_SIZE} 字节）"
        fi
    fi

    # 构造直接 HTTP 下载 URL（绕过 XetHub，走 hf-mirror.com 标准路径）
    DOWNLOAD_URL="${HF_ENDPOINT}/${MODEL_REPO}/resolve/main/${RFILENAME}"

    # 格式化文件大小显示
    if [[ "$EXPECTED_SIZE" -gt 0 ]]; then
        SIZE_MB=$(echo "scale=1; $EXPECTED_SIZE / 1048576" | bc)
        SIZE_HINT="${SIZE_MB} MB"
    else
        SIZE_HINT="大小未知"
    fi
    echo -e "    ${CYAN}[下载]${NC} ${RFILENAME} (${SIZE_HINT})"

    # 最多重试 5 次，每次失败后等待 10 秒再重试
    MAX_RETRIES=5
    WGET_STATUS=1
    for RETRY in $(seq 1 $MAX_RETRIES); do
        set +e
        # --progress=bar:force:noscroll 强制在脚本/非 TTY 环境中显示进度条
        wget --progress=bar:force:noscroll -c \
            --retry-connrefused \
            --tries=1 \
            --timeout=120 \
            -O "$LOCAL_FILE" \
            "$DOWNLOAD_URL" 2>&1
        WGET_STATUS=$?
        set -e
        if [[ $WGET_STATUS -eq 0 ]]; then
            break
        fi
        if [[ $RETRY -lt $MAX_RETRIES ]]; then
            echo -e "    ${YELLOW}[重试 ${RETRY}/${MAX_RETRIES}]${NC} 等待 10 秒后重试..."
            sleep 10
        fi
    done

    if [[ $WGET_STATUS -eq 0 ]]; then
        # 下载完成后再次验证大小
        if [[ "$EXPECTED_SIZE" -gt 0 ]]; then
            ACTUAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || echo 0)
            if [[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]]; then
                echo -e "    ${GREEN}[完成]${NC} ${RFILENAME} ✓"
                DOWNLOADED=$((DOWNLOADED + 1))
            else
                echo -e "    ${YELLOW}[警告]${NC} ${RFILENAME} 大小不匹配（期望 ${EXPECTED_SIZE}，实际 ${ACTUAL_SIZE}），将在下次运行时重新下载"
                rm -f "$LOCAL_FILE"
                FAILED=$((FAILED + 1))
            fi
        else
            echo -e "    ${GREEN}[完成]${NC} ${RFILENAME} ✓"
            DOWNLOADED=$((DOWNLOADED + 1))
        fi
    else
        echo -e "    ${RED}[失败]${NC} ${RFILENAME}（已重试 ${MAX_RETRIES} 次，将在下次运行时继续）"
        FAILED=$((FAILED + 1))
    fi

done <<< "$FILE_LIST"

echo ""
echo "    ────────────────────────────────────────"
echo -e "    下载完成：${GREEN}${DOWNLOADED} 个新下载${NC}，${CYAN}${SKIPPED} 个已跳过${NC}，${RED}${FAILED} 个失败${NC}"
echo "    ────────────────────────────────────────"

if [[ $FAILED -gt 0 ]]; then
    echo -e "${YELLOW}  ⚠ 有 ${FAILED} 个文件下载失败，请重新运行本脚本继续下载${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ 模型下载完成！${NC}"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  🎉 环境安装完成！                           ║${NC}"
echo -e "${GREEN}${BOLD}║  运行 ./start_all.sh 即可启动所有服务        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
