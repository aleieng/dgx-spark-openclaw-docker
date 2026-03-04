#!/usr/bin/env bash
# ============================================================
#  DGX Spark 一键停止脚本
#  功能：停止 vLLM 容器 + OpenClaw Gateway
# ============================================================
set -euo pipefail

# ── 用户配置区（与 start_all.sh 保持一致）───────────────────
VLLM_CONTAINER_NAME="vllm-minimax"             # Docker 容器名称
GATEWAY_PORT=18789                              # OpenClaw Gateway 端口
# ─────────────────────────────────────────────────────────────

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${YELLOW}正在停止所有服务...${NC}"

# ── 停止 OpenClaw Gateway ─────────────────────────────────────
if command -v openclaw &>/dev/null && openclaw gateway stop 2>/dev/null; then
    echo -e "${GREEN}  ✓ OpenClaw Gateway 已停止${NC}"
else
    PID=$(lsof -ti ":${GATEWAY_PORT}" 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
        echo -e "${GREEN}  ✓ OpenClaw Gateway 已强制停止${NC}"
    else
        echo -e "${YELLOW}  - OpenClaw Gateway 未在运行${NC}"
    fi
fi

# ── 停止 vLLM 容器 ────────────────────────────────────────────
if docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
    docker stop "$VLLM_CONTAINER_NAME" 2>/dev/null || true
    echo -e "${GREEN}  ✓ vLLM 容器已停止${NC}"
else
    echo -e "${YELLOW}  - vLLM 容器未在运行${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}所有服务已停止。${NC}"
