#!/usr/bin/env bash
# ============================================================
# 每日简报自动生成脚本
# 定时：cron 每天早上 6:00 执行（0 6 * * *）
# 功能：
#   1. 用 pi-agent（非交互 -p）执行 briefing-playbook.md
#   2. 只加载 miniflux + hn-briefing 两个技能（--no-skills + --skill）
#   3. 工作目录 = pi-playbook（与 playbook 内相对路径一致），执行日志/错误输出到 briefing-playbook/
# ============================================================
set -uo pipefail

PLAYBOOK_DIR="/home/limour/pi-playbook"
BRIEFING_DIR="$PLAYBOOK_DIR/briefing-playbook"
PLAYBOOK_FILE="$PLAYBOOK_DIR/briefing-playbook.md"
# pi 通过 micromamba 环境的 npx 解析，避免 pi 更新后 ~/.npm/_npx/<hash> 路径失效
PI_CMD=(/home/limour/micromamba/envs/pi/bin/npx --yes @earendil-works/pi-coding-agent pi)

# 1) 载入用户环境（MINIFLUX_URL/MINIFLUX_API_KEY、BRAVE_API_KEY、PATH 等）
#    cron 环境很干净，必须显式 source
[ -f "$HOME/.config/ai-env.sh" ] && . "$HOME/.config/ai-env.sh"

# 2) 技能 bin + node（pi 的 shebang 需要）加入 PATH；ai-env.sh 会重置 PATH，所以必须放在 source 之后
export PATH="/home/limour/micromamba/envs/pi/bin:/home/limour/.pi/agent/skills/miniflux/bin:/home/limour/.agents/skills/hn-briefing/bin:$PATH"

mkdir -p "$BRIEFING_DIR"
cd "$PLAYBOOK_DIR" || exit 1

LOG_FILE="$BRIEFING_DIR/run-$(date +%Y-%m-%d).log"

# 3) 防重入：上一次还没跑完（如生成/推送耗时过长）就跳过本次
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] 上次执行尚未结束，本次跳过" >> "$LOG_FILE"
    exit 0
fi

{
    echo ""
    echo "============================================================"
    echo "[$(date '+%F %T')] 开始执行简报任务"
    echo "cwd:      $PLAYBOOK_DIR"
    echo "playbook: $PLAYBOOK_FILE"
    echo "============================================================"

    # 4) 用 pi-agent 执行 playbook：只保留 miniflux 与 hn-briefing 技能
    "${PI_CMD[@]}" --no-skills \
        --skill /home/limour/.pi/agent/skills/miniflux \
        --skill /home/limour/.agents/skills/hn-briefing \
        --provider axon --model deepseek-v4-flash \
        -p "@$PLAYBOOK_FILE"
    rc=$?

    echo ""
    echo "============================================================"
    echo "[$(date '+%F %T')] 执行结束 exit=$rc"
    echo "============================================================"
    exit $rc
} >> "$LOG_FILE" 2>&1
