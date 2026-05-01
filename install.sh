#!/usr/bin/env bash
# ============================================================
#  DGX Spark 环境安装脚本
#  作者：Ken He
#  功能：交互式选择模型，自动安装依赖、下载模型
#  支持模型（推理框架已自动绑定）：
#    1) Qwen3.5-35B-A3B          → vLLM（约 70GB BF16）
#    2) MiniMax-M2.5-REAP-NVFP4  → vLLM（约 78GB NVFP4）
#    3) GLM-4.7-Flash            → Ollama（约 19GB Q4）
# ============================================================
set -euo pipefail

# ── 全局配置 ──────────────────────────────────────────────────
DEPLOY_CONFIG="$HOME/.openclaw_deploy_config"   # 部署配置持久化文件
MODEL_BASE_DIR="$HOME/openclaw_project/models"  # 模型根目录
HF_ENDPOINT="https://hf-mirror.com"             # 国内 HF 镜像源
OPENCLAW_IMAGE="ghcr.io/openclaw/openclaw:latest" # OpenClaw 官方 Docker 镜像

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   DGX Spark · 本地大模型 · OpenClaw                 ║"
    echo "║              环境安装脚本                            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_banner

# ════════════════════════════════════════════════════════════════
# 步骤 0：交互式选择模型（框架自动绑定）
# ════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[0/5] 选择部署模型${NC}"
echo ""
echo -e "  请选择要部署的大模型（推理框架已自动绑定，无需手动选择）："
echo ""
echo -e "    ${CYAN}1)${NC} Qwen3.5-35B-A3B           ${YELLOW}(约 70GB · BF16 · vLLM)${NC}"
echo -e "       最新 Qwen3.5 MoE，激活参数 3.5B，推理能力强"
echo ""
echo -e "    ${CYAN}2)${NC} MiniMax-M2.5-REAP-NVFP4   ${YELLOW}(约 78GB · NVFP4 · vLLM)${NC}"
echo -e "       MiniMax 旗舰 MoE，专用 NVFP4 内核，工具调用优化"
echo ""
echo -e "    ${CYAN}3)${NC} GLM-4.7-Flash             ${YELLOW}(约 19GB · Q4 · Ollama)${NC}"
echo -e "       Z.AI 30B-A3B MoE 推理模型，最轻量，秒级启动"
echo ""
read -rp "  输入选项 [1/2/3]（默认 1）: " MODEL_CHOICE
MODEL_CHOICE="${MODEL_CHOICE:-1}"

case "$MODEL_CHOICE" in
    1)
        SELECTED_MODEL="qwen35"
        SELECTED_FRAMEWORK="vllm"
        MODEL_DISPLAY="Qwen3.5-35B-A3B"
        FRAMEWORK_DISPLAY="vLLM"
        MODEL_NAME="Qwen3.5-35B-A3B"
        MODEL_REPO="Qwen/Qwen3.5-35B-A3B"
        VLLM_IMAGE="vllm/vllm-openai:cu130-nightly"
        VLLM_PORT=8000
        OLLAMA_PORT=11434
        ;;
    2)
        SELECTED_MODEL="minimax"
        SELECTED_FRAMEWORK="vllm"
        MODEL_DISPLAY="MiniMax-M2.5-REAP-NVFP4"
        FRAMEWORK_DISPLAY="vLLM（专用 NVFP4 内核）"
        MODEL_NAME="MiniMax-M2.5-REAP-NVFP4"
        MODEL_REPO="lukealonso/MiniMax-M2.5-REAP-139B-A10B-NVFP4"
        VLLM_IMAGE="avarok/dgx-vllm-nvfp4-kernel:v22"
        VLLM_PORT=8000
        OLLAMA_PORT=11434
        ;;
    3)
        SELECTED_MODEL="glm"
        SELECTED_FRAMEWORK="ollama"
        MODEL_DISPLAY="GLM-4.7-Flash"
        FRAMEWORK_DISPLAY="Ollama"
        MODEL_NAME="glm-4.7-flash"
        MODEL_REPO=""  # Ollama 自行管理，无需 HF 下载
        VLLM_IMAGE=""
        VLLM_PORT=8000
        OLLAMA_PORT=11434
        ;;
    *)
        echo -e "${RED}  ✗ 无效选项，退出${NC}"; exit 1 ;;
esac

echo ""
echo -e "  ${GREEN}${BOLD}部署方案已确认：${NC}"
echo -e "    模型：${CYAN}${MODEL_DISPLAY}${NC}"
echo -e "    框架：${CYAN}${FRAMEWORK_DISPLAY}${NC}"
echo ""

# 持久化部署配置（供 start_all.sh 读取）
mkdir -p "$(dirname "$DEPLOY_CONFIG")"
cat > "$DEPLOY_CONFIG" <<EOF
# DGX Spark 部署配置（由 install.sh 自动生成）
SELECTED_MODEL="${SELECTED_MODEL}"
SELECTED_FRAMEWORK="${SELECTED_FRAMEWORK}"
MODEL_DISPLAY="${MODEL_DISPLAY}"
FRAMEWORK_DISPLAY="${FRAMEWORK_DISPLAY}"
MODEL_NAME="${MODEL_NAME}"
MODEL_REPO="${MODEL_REPO}"
VLLM_IMAGE="${VLLM_IMAGE}"
MODEL_BASE_DIR="${MODEL_BASE_DIR}"
VLLM_PORT=${VLLM_PORT}
OLLAMA_PORT=${OLLAMA_PORT}
OPENCLAW_IMAGE="${OPENCLAW_IMAGE}"
EOF
echo -e "${GREEN}  ✓ 部署配置已保存至 ${DEPLOY_CONFIG}${NC}"

# ════════════════════════════════════════════════════════════════
# 步骤 1：检查并安装基础依赖
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[1/5] 检查基础依赖...${NC}"

# Docker（OpenClaw Gateway 容器与 vLLM 必须）
if ! command -v docker &>/dev/null; then
    echo -e "${RED}  ✗ 未找到 docker，请先安装 Docker：https://docs.docker.com/engine/install/ubuntu/${NC}"
    exit 1
fi
# 检查 Docker 权限
if ! docker info &>/dev/null 2>&1; then
    echo "    当前用户没有 Docker 权限，正在自动修复..."
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}  ⚠ 已将用户 ${USER} 加入 docker 组。${NC}"
    echo -e "${YELLOW}    请运行以下命令使权限生效，然后重新运行本脚本：${NC}"
    echo -e "${CYAN}      newgrp docker${NC}"
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

# jq（解析 HF API JSON）
if ! command -v jq &>/dev/null; then
    echo "    正在安装 jq..."
    sudo apt-get update -qq && sudo apt-get install -y jq
fi
echo -e "${GREEN}  ✓ jq${NC}"

# Ollama 框架专属依赖
if [[ "$SELECTED_FRAMEWORK" == "ollama" ]]; then
    if ! command -v ollama &>/dev/null; then
        echo "    正在安装 Ollama..."
        curl -fsSL https://ollama.com/install.sh | sh
        echo -e "${GREEN}  ✓ Ollama 安装成功${NC}"
    else
        echo -e "${GREEN}  ✓ Ollama $(ollama --version 2>/dev/null || echo '')${NC}"
    fi
fi

# ════════════════════════════════════════════════════════════════
# 步骤 2：准备 OpenClaw Docker 镜像
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[2/5] 准备 OpenClaw Docker 镜像...${NC}"

echo "    目标镜像：${OPENCLAW_IMAGE}"
if docker image inspect "$OPENCLAW_IMAGE" &>/dev/null; then
    echo -e "${GREEN}  ✓ OpenClaw 镜像已在本地，跳过拉取${NC}"
else
    echo "    正在拉取 OpenClaw 官方镜像..."
    if docker pull "$OPENCLAW_IMAGE"; then
        echo -e "${GREEN}  ✓ OpenClaw Docker 镜像准备完成${NC}"
    else
        echo -e "${RED}  ✗ OpenClaw 镜像拉取失败，请检查网络或手动执行：${NC}"
        echo -e "${CYAN}      docker pull ${OPENCLAW_IMAGE}${NC}"
        exit 1
    fi
fi

# ════════════════════════════════════════════════════════════════
# 步骤 3：准备推理框架（Docker 镜像 / Ollama）
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[3/5] 准备推理框架：${FRAMEWORK_DISPLAY}...${NC}"

case "$SELECTED_FRAMEWORK" in
    # ── vLLM ──────────────────────────────────────────────────
    vllm)
        echo "    目标镜像：${VLLM_IMAGE}"
        echo ""
        if docker image inspect "$VLLM_IMAGE" &>/dev/null; then
            echo -e "${GREEN}  ✓ 镜像已在本地，跳过拉取${NC}"
        else
            MIRROR_PREFIXES=(
                "docker.1ms.run"
                "hub.rat.dev"
                "dockerproxy.net"
                "proxy.vvvv.ee"
                "docker.m.daocloud.io"
                "registry.cyou"
            )

            # 默认不修改 /etc/docker/daemon.json，避免覆盖用户已有 Docker 配置。
            # 如需合并写入 registry-mirrors，请显式运行：
            #   CONFIGURE_DOCKER_MIRRORS=1 ./install.sh
            if [[ "${CONFIGURE_DOCKER_MIRRORS:-0}" == "1" ]]; then
                echo "    合并写入 Docker registry-mirrors（保留已有 daemon.json 配置）..."
                DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
                TMP_DAEMON_JSON="$(mktemp)"
                if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
                    if ! jq empty "$DOCKER_DAEMON_JSON" >/dev/null 2>&1; then
                        echo -e "${YELLOW}  ⚠ ${DOCKER_DAEMON_JSON} 不是有效 JSON，跳过自动写入镜像源${NC}"
                        rm -f "$TMP_DAEMON_JSON"
                    else
                        jq '.["registry-mirrors"] = ((.["registry-mirrors"] // []) + [
                            "https://docker.1ms.run",
                            "https://hub.rat.dev",
                            "https://dockerproxy.net",
                            "https://proxy.vvvv.ee",
                            "https://docker.m.daocloud.io",
                            "https://registry.cyou"
                        ] | unique)' "$DOCKER_DAEMON_JSON" > "$TMP_DAEMON_JSON"
                    fi
                else
                    jq -n '{
                        "registry-mirrors": [
                            "https://docker.1ms.run",
                            "https://hub.rat.dev",
                            "https://dockerproxy.net",
                            "https://proxy.vvvv.ee",
                            "https://docker.m.daocloud.io",
                            "https://registry.cyou"
                        ]
                    }' > "$TMP_DAEMON_JSON"
                fi
                if [[ -s "$TMP_DAEMON_JSON" ]]; then
                    sudo mkdir -p /etc/docker
                    if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
                        sudo cp "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
                    fi
                    sudo tee "$DOCKER_DAEMON_JSON" < "$TMP_DAEMON_JSON" > /dev/null
                    rm -f "$TMP_DAEMON_JSON"
                    sudo systemctl daemon-reload
                    sudo systemctl restart docker
                    sleep 3
                    echo -e "${GREEN}  ✓ Docker registry-mirrors 已合并配置${NC}"
                fi
            else
                echo -e "${YELLOW}  ⚠ 默认不修改 /etc/docker/daemon.json；如需写入镜像源，请使用 CONFIGURE_DOCKER_MIRRORS=1${NC}"
            fi

            # 方案 A：直接 pull（可使用用户已有 Docker 配置）
            echo "    尝试直接拉取镜像..."
            set +e
            docker pull "$VLLM_IMAGE"
            PULL_STATUS=$?
            set -e

            # 方案 B：逐一尝试镜像源前缀，不修改 Docker daemon 配置
            if [[ $PULL_STATUS -ne 0 ]]; then
                echo -e "${YELLOW}  ⚠ 直接拉取失败，改用镜像源前缀拉取...${NC}"
                for MIRROR in "${MIRROR_PREFIXES[@]}"; do
                    MIRROR_IMAGE="${MIRROR}/${VLLM_IMAGE}"
                    echo "    尝试：docker pull ${MIRROR_IMAGE}"
                    set +e
                    docker pull "${MIRROR_IMAGE}"
                    PULL_STATUS=$?
                    set -e
                    if [[ $PULL_STATUS -eq 0 ]]; then
                        docker tag "${MIRROR_IMAGE}" "${VLLM_IMAGE}"
                        echo -e "${GREEN}  ✓ 通过 ${MIRROR} 拉取成功${NC}"
                        break
                    fi
                done
            fi

            if [[ $PULL_STATUS -ne 0 ]]; then
                echo -e "${RED}  ✗ 所有镜像源均失败，请手动拉取后重新运行：${NC}"
                echo -e "${CYAN}    docker pull ${VLLM_IMAGE}${NC}"
                exit 1
            fi
            echo -e "${GREEN}  ✓ Docker 镜像拉取成功${NC}"
        fi
        ;;

    # ── Ollama ────────────────────────────────────────────────────────
    ollama)
        # 配置 Ollama 镜像源（优先使用 ModelScope，国内速度快）
        echo -e "    配置 Ollama 镜像源（ModelScope）..."
        mkdir -p ~/.ollama
        cat > ~/.ollama/config.json << 'OLLAMA_CFG'
{
  "registry": {
    "mirrors": {
      "registry.ollama.ai": "https://ollama.modelscope.cn"
    }
  }
}
OLLAMA_CFG
        echo -e "${GREEN}  ✓ Ollama 镜像源已配置（ollama.modelscope.cn）${NC}"
        echo -e "${GREEN}  ✓ Ollama 框架准备完成${NC}"
        ;;
esac

# ════════════════════════════════════════════════════════════════
# 步骤 4：下载模型文件
# ════════════════════════════════════════════════════════════════
echo ""

if [[ "$SELECTED_FRAMEWORK" == "ollama" ]]; then
    echo -e "${YELLOW}[4/5] 下载模型文件：${MODEL_DISPLAY}（Ollama）...${NC}"
    echo -e "    模型：${CYAN}${MODEL_NAME}${NC}（约 19GB，支持断点续传）"
    echo ""

    # 确保 ollama 服务正在运行
    # 注意：启动时必须清除代理环境变量，避免代理拦截导致 TLS 超时
    if ! pgrep -x ollama &>/dev/null; then
        echo -e "    正在启动 Ollama 服务..."
        env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
            NO_PROXY="*" no_proxy="*" \
            ollama serve &>/dev/null &
        OLLAMA_BG_PID=$!
        sleep 3
    fi

    # 检查模型是否已下载
    if ollama list 2>/dev/null | grep -q "${MODEL_NAME}"; then
        echo -e "${GREEN}  ✓ 模型 ${MODEL_NAME} 已存在，跳过下载${NC}"
    else
        # 通过 ~/.ollama/config.json 已配置 ModelScope 镜像源
        # ollama pull 会自动走镜像，下载官方格式（支持 tools + thinking）
        echo -e "    镜像源：${CYAN}ollama.modelscope.cn${NC}（官方格式，支持工具调用）"
        echo -e "    可 Ctrl+C 中断，下次运行自动续传"
        echo ""
        PULL_OK=false
        for _attempt in 1 2 3; do
            [[ ${_attempt} -gt 1 ]] && echo -e "    尝试第 ${_attempt} 次..."
            if env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
                   NO_PROXY="*" no_proxy="*" \
                   ollama pull "${MODEL_NAME}"; then
                PULL_OK=true
                break
            fi
            [[ ${_attempt} -lt 3 ]] && echo -e "    拉取失败，5 秒后重试..." && sleep 5
        done
        if ${PULL_OK}; then
            echo -e "${GREEN}  ✓ 模型 ${MODEL_NAME} 下载完成${NC}"
        else
            echo -e "${RED}  ✗ 模型下载失败。请检查网络后手动运行：${NC}"
            echo -e "    ${CYAN}ollama pull ${MODEL_NAME}${NC}"
        fi
    fi
else
    echo -e "${YELLOW}[4/5] 下载模型文件：${MODEL_DISPLAY}...${NC}"

    DEST_DIR="${MODEL_BASE_DIR}/${MODEL_NAME}"
    HFD_CACHE="${DEST_DIR}/.hfd"
    METADATA_FILE="${HFD_CACHE}/repo_metadata.json"

    mkdir -p "$DEST_DIR" "$HFD_CACHE"

    echo "    下载目录：${DEST_DIR}"
    echo "    仓库地址：${MODEL_REPO}"
    echo "    支持断点续传，可随时 Ctrl+C 后重新运行继续"
    echo ""

    # ── 确定 hf 命令路径 ──────────────────────────────────────
    HF_CMD=""
    if command -v hf &>/dev/null; then
        HF_CMD="hf"
    elif command -v huggingface-cli &>/dev/null; then
        HF_CMD="huggingface-cli"
    fi

    # ── 确定 modelscope 命令路径（Qwen 专用）────────────────────
    MS_CMD=""
    if [[ "$SELECTED_MODEL" == "qwen35" ]]; then
        if command -v modelscope &>/dev/null; then
            MS_CMD="modelscope"
        else
            # 尝试安装 modelscope
            echo "    正在安装 modelscope 下载工具..."
            set +e
            pip3 install -q modelscope -i https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null
            set -e
            if command -v modelscope &>/dev/null; then
                MS_CMD="modelscope"
                echo -e "${GREEN}  ✓ modelscope 安装成功${NC}"
            else
                echo -e "${YELLOW}  ⚠ modelscope 安装失败，将跳过 ModelScope 下载方案${NC}"
            fi
        fi
        # ModelScope 上 Qwen 的仓库 ID（与 HuggingFace 相同格式）
        MS_MODEL_REPO="${MODEL_REPO}"
    fi

    # ── 通过 HF API 获取文件元数据 ────────────────────────────
    _fetch_metadata() {
        local api_url="$1"
        local http_code
        http_code=$(curl -L -s --connect-timeout 15 --max-time 30 \
            -w "%{http_code}" -o "$METADATA_FILE" "$api_url" 2>/dev/null)
        echo "$http_code"
    }

    echo "    正在获取文件列表..."
    META_OK=false
    HTTP_CODE=$(_fetch_metadata "https://huggingface.co/api/models/${MODEL_REPO}")
    if [[ "$HTTP_CODE" == "200" ]]; then
        META_OK=true
        echo -e "${GREEN}  ✓ 文件列表获取成功（官方 API）${NC}"
    else
        HTTP_CODE=$(_fetch_metadata "${HF_ENDPOINT}/api/models/${MODEL_REPO}")
        if [[ "$HTTP_CODE" == "200" ]]; then
            META_OK=true
            echo -e "${GREEN}  ✓ 文件列表获取成功（镜像 API）${NC}"
        else
            echo -e "${YELLOW}  ⚠ 无法获取文件列表（将跳过完整性预检，仍会尝试下载）${NC}"
        fi
    fi

    FILE_LIST=""
    TOTAL_FILES=0
    if [[ "$META_OK" == "true" ]]; then
        FILE_LIST=$(jq -r '.siblings[] | select(.rfilename != null) | [(.size // 0 | tostring), .rfilename] | join(" ")' "$METADATA_FILE" 2>/dev/null || true)
        TOTAL_FILES=$(echo "$FILE_LIST" | grep -c '.' 2>/dev/null || echo 0)
        echo "    共 ${TOTAL_FILES} 个文件"
    fi

    # ── 完整性检查函数（使用 HF 文件列表，适用于 HF/wget 下载后校验）─────
    _check_all_complete() {
        [[ "$META_OK" != "true" || -z "$FILE_LIST" ]] && return 1
        local all_ok=true
        while IFS=' ' read -r exp_size rfilename; do
            [[ -z "$rfilename" ]] && continue
            local local_file="${DEST_DIR}/${rfilename}"
            if [[ ! -f "$local_file" ]]; then
                all_ok=false; break
            fi
            if [[ "$exp_size" -gt 0 ]]; then
                local actual_size
                actual_size=$(stat -c%s "$local_file" 2>/dev/null || echo 0)
                if [[ "$actual_size" -ne "$exp_size" ]]; then
                    all_ok=false; break
                fi
            fi
            if [[ "$rfilename" == *.json ]]; then
                if ! python3 -c "import json; json.load(open('${local_file}'))" 2>/dev/null; then
                    echo -e "    ${YELLOW}[JSON损坏]${NC} ${rfilename}，将重新下载"
                    rm -f "$local_file"
                    all_ok=false; break
                fi
            fi
        done <<< "$FILE_LIST"
        [[ "$all_ok" == "true" ]]
    }

    # ── 轻量校验函数（用于 ModelScope 下载后校验，不依赖 HF 文件大小）──────
    # ModelScope 与 HF 的文件大小可能存在细微差异（如 index.json 格式不同），
    # 因此只校验：关键 JSON 文件存在且合法 + 所有 safetensors 分片存在且非空
    _check_ms_complete() {
        # 1. 关键 JSON 文件
        for key_json in config.json generation_config.json tokenizer_config.json; do
            local f="${DEST_DIR}/${key_json}"
            if [[ ! -f "$f" ]]; then return 1; fi
            if ! python3 -c "import json; json.load(open('${f}'))" 2>/dev/null; then
                echo -e "    ${YELLOW}[JSON损坏]${NC} ${key_json}"
                rm -f "$f"
                return 1
            fi
        done
        # 2. 所有 safetensors 分片存在且非空（大小 > 1MB）
        local shard_count
        shard_count=$(find "$DEST_DIR" -maxdepth 1 -name '*.safetensors' -size +1M 2>/dev/null | wc -l)
        if [[ "$shard_count" -eq 0 ]]; then return 1; fi
        return 0
    }

    if _check_all_complete; then
        echo -e "${GREEN}  ✓ 模型已完整下载，跳过下载步骤${NC}"
    else
        DOWNLOAD_SUCCESS=false

        # 方案 MS：ModelScope 下载（仅 Qwen，国内优先）
        if [[ "$SELECTED_MODEL" == "qwen35" && -n "$MS_CMD" ]]; then
            echo ""
            echo -e "${CYAN}  ▶ 方案 MS：使用 ModelScope（魔搭社区）下载...${NC}"
            set +e
            modelscope download \
                --model "${MS_MODEL_REPO}" \
                --local_dir "$DEST_DIR"
            MS_STATUS=$?
            set -e
            if [[ $MS_STATUS -eq 0 ]]; then
                if _check_ms_complete; then
                    # ModelScope 可能不包含 model.safetensors.index.json，补充下载
                    INDEX_FILE="${DEST_DIR}/model.safetensors.index.json"
                    if [[ ! -f "$INDEX_FILE" || ! -s "$INDEX_FILE" ]]; then
                        echo -e "    补充下载 model.safetensors.index.json..."
                        INDEX_URL="${HF_ENDPOINT}/${MODEL_REPO}/resolve/main/model.safetensors.index.json"
                        set +e
                        wget -q --timeout=60 -O "$INDEX_FILE" "$INDEX_URL" 2>/dev/null
                        set -e
                        if [[ -s "$INDEX_FILE" ]]; then
                            echo -e "    ${GREEN}[完成]${NC} model.safetensors.index.json ✓"
                        else
                            echo -e "    ${YELLOW}[警告]${NC} model.safetensors.index.json 补充失败，不影响模型加载"
                            rm -f "$INDEX_FILE" 2>/dev/null || true
                        fi
                    fi
                    echo -e "${GREEN}  ✓ 方案 MS（ModelScope）下载成功${NC}"
                    DOWNLOAD_SUCCESS=true
                else
                    echo -e "${YELLOW}  ⚠ 方案 MS 完成但关键文件校验不通过，尝试方案 A...${NC}"
                fi
            else
                echo -e "${YELLOW}  ⚠ 方案 MS 失败（退出码 ${MS_STATUS}），尝试方案 A...${NC}"
            fi
        fi

        # 方案 A：hf download（官方 HuggingFace）
        if [[ "$DOWNLOAD_SUCCESS" == "false" && -n "$HF_CMD" ]]; then
            echo ""
            echo -e "${CYAN}  ▶ 方案 A：使用 hf download（官方 HuggingFace）...${NC}"
            set +e
            "$HF_CMD" download "$MODEL_REPO" \
                --local-dir "$DEST_DIR" \
                --repo-type model
            HF_STATUS=$?
            set -e
            if [[ $HF_STATUS -eq 0 ]]; then
                if _check_all_complete || [[ "$META_OK" != "true" ]]; then
                    echo -e "${GREEN}  ✓ 方案 A 下载成功${NC}"
                    DOWNLOAD_SUCCESS=true
                else
                    echo -e "${YELLOW}  ⚠ 方案 A 完成但文件校验不通过，尝试方案 B...${NC}"
                fi
            else
                echo -e "${YELLOW}  ⚠ 方案 A 失败（退出码 ${HF_STATUS}），尝试方案 B...${NC}"
            fi
        else
            if [[ "$DOWNLOAD_SUCCESS" == "false" ]]; then
                echo -e "${YELLOW}  ⚠ 未找到 hf / huggingface-cli 命令，跳过方案 A...${NC}"
            fi
        fi

        # 方案 B：hf download + hf-mirror.com 镜像
        if [[ "$DOWNLOAD_SUCCESS" == "false" && -n "$HF_CMD" ]]; then
            echo ""
            echo -e "${CYAN}  ▶ 方案 B：使用 hf download + hf-mirror.com 镜像...${NC}"
            set +e
            HF_HUB_DISABLE_XET=1 \
            HF_ENDPOINT="${HF_ENDPOINT}" \
            "$HF_CMD" download "$MODEL_REPO" \
                --local-dir "$DEST_DIR" \
                --repo-type model
            HF_STATUS=$?
            set -e
            if [[ $HF_STATUS -eq 0 ]]; then
                if _check_all_complete || [[ "$META_OK" != "true" ]]; then
                    echo -e "${GREEN}  ✓ 方案 B 下载成功${NC}"
                    DOWNLOAD_SUCCESS=true
                else
                    echo -e "${YELLOW}  ⚠ 方案 B 完成但文件校验不通过，尝试方案 C...${NC}"
                fi
            else
                echo -e "${YELLOW}  ⚠ 方案 B 失败（退出码 ${HF_STATUS}），尝试方案 C...${NC}"
            fi
        fi

        # 方案 C：wget 逐文件直接下载（绕过 XetHub）
        if [[ "$DOWNLOAD_SUCCESS" == "false" ]]; then
            echo ""
            echo -e "${CYAN}  ▶ 方案 C：wget 逐文件直接下载（hf-mirror.com 标准 HTTP）...${NC}"

            if [[ "$META_OK" != "true" || -z "$FILE_LIST" ]]; then
                echo -e "${RED}  ✗ 无法获取文件列表，方案 C 无法执行，请检查网络后重新运行${NC}"
                exit 1
            fi

            echo "    共 ${TOTAL_FILES} 个文件需要检查"
            echo ""

            WGET_DOWNLOADED=0
            WGET_SKIPPED=0
            WGET_FAILED=0

            while IFS=' ' read -r EXPECTED_SIZE RFILENAME; do
                [[ -z "$RFILENAME" ]] && continue

                LOCAL_FILE="${DEST_DIR}/${RFILENAME}"
                FILE_DIR=$(dirname "$LOCAL_FILE")
                mkdir -p "$FILE_DIR"

                if [[ -f "$LOCAL_FILE" ]]; then
                    if [[ "$EXPECTED_SIZE" -gt 0 ]]; then
                        ACTUAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || echo 0)
                        if [[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]]; then
                            if [[ "$RFILENAME" == *.json ]]; then
                                if python3 -c "import json; json.load(open('${LOCAL_FILE}'))" 2>/dev/null; then
                                    echo -e "    ${GREEN}[跳过]${NC} ${RFILENAME} （已完整）"
                                    WGET_SKIPPED=$((WGET_SKIPPED + 1))
                                    continue
                                else
                                    echo -e "    ${YELLOW}[JSON损坏]${NC} ${RFILENAME}，将重新下载"
                                    rm -f "$LOCAL_FILE"
                                fi
                            else
                                echo -e "    ${GREEN}[跳过]${NC} ${RFILENAME} （已完整）"
                                WGET_SKIPPED=$((WGET_SKIPPED + 1))
                                continue
                            fi
                        elif [[ "$ACTUAL_SIZE" -gt 0 ]]; then
                            SIZE_MB_ACTUAL=$(echo "scale=1; $ACTUAL_SIZE / 1048576" | bc)
                            SIZE_MB_EXP=$(echo "scale=1; $EXPECTED_SIZE / 1048576" | bc)
                            echo "    [续传] ${RFILENAME} （已有 ${SIZE_MB_ACTUAL}/${SIZE_MB_EXP} MB）"
                        fi
                    else
                        if [[ "$RFILENAME" == *.json ]]; then
                            if python3 -c "import json; json.load(open('${LOCAL_FILE}'))" 2>/dev/null; then
                                echo -e "    ${GREEN}[跳过]${NC} ${RFILENAME} （JSON 校验通过）"
                                WGET_SKIPPED=$((WGET_SKIPPED + 1))
                                continue
                            else
                                echo -e "    ${YELLOW}[JSON损坏]${NC} ${RFILENAME}，将重新下载"
                                rm -f "$LOCAL_FILE"
                            fi
                        else
                            echo -e "    ${GREEN}[跳过]${NC} ${RFILENAME} （文件已存在）"
                            WGET_SKIPPED=$((WGET_SKIPPED + 1))
                            continue
                        fi
                    fi
                fi

                DOWNLOAD_URL="${HF_ENDPOINT}/${MODEL_REPO}/resolve/main/${RFILENAME}"
                if [[ "$EXPECTED_SIZE" -gt 0 ]]; then
                    SIZE_MB=$(echo "scale=1; $EXPECTED_SIZE / 1048576" | bc)
                    SIZE_HINT="${SIZE_MB} MB"
                else
                    SIZE_HINT="大小未知"
                fi
                echo -e "    ${CYAN}[下载]${NC} ${RFILENAME} (${SIZE_HINT})"

                WGET_STATUS=1
                for RETRY in $(seq 1 5); do
                    set +e
                    wget --progress=bar:force:noscroll -c \
                        --retry-connrefused \
                        --tries=1 \
                        --timeout=120 \
                        -O "$LOCAL_FILE" \
                        "$DOWNLOAD_URL" 2>&1
                    WGET_STATUS=$?
                    set -e
                    if [[ $WGET_STATUS -eq 0 ]]; then break; fi
                    if [[ $RETRY -lt 5 ]]; then
                        echo -e "    ${YELLOW}[重试 ${RETRY}/5]${NC} 等待 10 秒后重试..."
                        sleep 10
                    fi
                done

                if [[ $WGET_STATUS -eq 0 ]]; then
                    if [[ "$EXPECTED_SIZE" -gt 0 ]]; then
                        ACTUAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || echo 0)
                        if [[ "$ACTUAL_SIZE" -eq "$EXPECTED_SIZE" ]]; then
                            echo -e "    ${GREEN}[完成]${NC} ${RFILENAME} ✓"
                            WGET_DOWNLOADED=$((WGET_DOWNLOADED + 1))
                        else
                            echo -e "    ${YELLOW}[警告]${NC} ${RFILENAME} 大小不匹配，将在下次运行时重新下载"
                            rm -f "$LOCAL_FILE"
                            WGET_FAILED=$((WGET_FAILED + 1))
                        fi
                    else
                        echo -e "    ${GREEN}[完成]${NC} ${RFILENAME} ✓"
                        WGET_DOWNLOADED=$((WGET_DOWNLOADED + 1))
                    fi
                else
                    echo -e "    ${RED}[失败]${NC} ${RFILENAME}（已重试 5 次，将在下次运行时继续）"
                    WGET_FAILED=$((WGET_FAILED + 1))
                fi

            done <<< "$FILE_LIST"

            echo ""
            echo "    ────────────────────────────────────────"
            echo -e "    方案 C 结果：${GREEN}${WGET_DOWNLOADED} 个新下载${NC}，${CYAN}${WGET_SKIPPED} 个已跳过${NC}，${RED}${WGET_FAILED} 个失败${NC}"
            echo "    ────────────────────────────────────────"

            if [[ $WGET_FAILED -gt 0 ]]; then
                echo -e "${YELLOW}  ⚠ 有 ${WGET_FAILED} 个文件下载失败，请重新运行本脚本继续下载${NC}"
                exit 1
            fi

            DOWNLOAD_SUCCESS=true
        fi

        if [[ "$DOWNLOAD_SUCCESS" != "true" ]]; then
            echo -e "${RED}  ✗ 所有下载方案均失败，请检查网络后重新运行${NC}"
            exit 1
        fi
    fi

    echo -e "${GREEN}  ✓ 模型下载完成！${NC}"
fi

# ════════════════════════════════════════════════════════════════
# 步骤 5：完成提示
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[5/5] 安装完成${NC}"
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  🎉 环境安装完成！                                   ║${NC}"
echo -e "${GREEN}${BOLD}║  运行 ./start_all.sh 即可启动所有服务                ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
