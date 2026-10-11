#!/usr/bin/env bash
# ============================================================
# 期权与加密日报自动生成脚本（"定时 @ 手册" 的实现）
# 手册：options-briefing-playbook.md
# 建议 cron：TZ=Asia/Shanghai 0 5 * * 2-6
#   （美东 16:00 收盘 = CST 04:00/05:00，05:00 已有当日收盘快照；
#     必须早于每日简报 run-briefing.sh 的 06:00，简报会读这份日报）
# 功能：
#   1. 用 pi-agent（非交互 -p）执行 options-briefing-playbook.md
#   2. 只加载 options-gex + optioncharts + tradingview 三个技能
#      （项目级 .agents/skills/ 下，--no-skills + --skill 显式加载，不受项目信任门控影响）
#   3. 工作目录 = 仓库根（与手册内相对路径一致），日志输出到 briefing-playbook/
# 产物：briefing-playbook/options-briefing-YYYY-MM-DD.md
# ============================================================
set -uo pipefail

# 仓库根 = 本脚本所在目录（本机 /home/limour/pi-playbook，cron 机器 /root/pi-playbook 均可）
PLAYBOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIEFING_DIR="$PLAYBOOK_DIR/briefing-playbook"
PLAYBOOK_FILE="$PLAYBOOK_DIR/options-briefing-playbook.md"
# pi 通过 micromamba 环境的 npx 解析，避免 pi 更新后 ~/.npm/_npx/<hash> 路径失效
PI_CMD=("$HOME/micromamba/envs/pi/bin/npx" --yes @earendil-works/pi-coding-agent pi)
[ -x "${PI_CMD[0]}" ] || PI_CMD=(/root/micromamba/envs/pi/bin/npx --yes @earendil-works/pi-coding-agent pi)

# 1) 载入用户环境（MINIFLUX_URL/MINIFLUX_API_KEY、BRAVE_API_KEY、PATH 等）
#    cron 环境很干净，必须显式 source
[ -f "$HOME/.config/ai-env.sh" ] && . "$HOME/.config/ai-env.sh"

# 2) 技能 bin + node 加入 PATH（ai-env.sh 会重置 PATH，所以必须放在 source 之后）
export PATH="$PLAYBOOK_DIR/.agents/skills/options-gex/bin:$PLAYBOOK_DIR/.agents/skills/optioncharts/bin:$PLAYBOOK_DIR/.agents/skills/tradingview/bin:/root/micromamba/envs/pi/bin:$HOME/micromamba/envs/pi/bin:$PATH"
export PLAYBOOK_DIR

mkdir -p "$BRIEFING_DIR"
cd "$PLAYBOOK_DIR" || exit 1

LOG_FILE="$BRIEFING_DIR/run-options-$(date +%Y-%m-%d).log"
LOCK_FILE="$BRIEFING_DIR/options-briefing.lock"
TODAY=$(date +%F)
TODAY_BRIEFING="$BRIEFING_DIR/options-briefing-$TODAY.md"

# 3) 幂等：今天的日报已经生成过就跳过（想强制重跑先删掉该文件）
if [ -s "$TODAY_BRIEFING" ]; then
    echo "[$(date '+%F %T')] 今天的期权日报已存在（$TODAY_BRIEFING），本次跳过" >> "$LOG_FILE"
    exit 0
fi

# 4) 防重入：上一次还没跑完就跳过本次
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[$(date '+%F %T')] 上次执行尚未结束，本次跳过" >> "$LOG_FILE"
    exit 0
fi

{
    echo ""
    echo "============================================================"
    echo "[$(date '+%F %T')] 开始执行期权日报任务"
    echo "cwd:      $PLAYBOOK_DIR"
    echo "playbook: $PLAYBOOK_FILE"
    echo "target:   $TODAY_BRIEFING"
    echo "============================================================"

    # 5) 用 pi-agent 执行手册：只保留期权/加密相关的三个技能
    "${PI_CMD[@]}" --no-skills \
        --skill "$PLAYBOOK_DIR/.agents/skills/options-gex" \
        --skill "$PLAYBOOK_DIR/.agents/skills/optioncharts" \
        --skill "$PLAYBOOK_DIR/.agents/skills/tradingview" \
        --provider axon --model deepseek-flash \
        -p "@$PLAYBOOK_FILE"
    rc=$?

    echo ""
    echo "============================================================"
    echo "[$(date '+%F %T')] 执行结束 exit=$rc"
    if [ -s "$TODAY_BRIEFING" ]; then
        echo "产物: $TODAY_BRIEFING ($(wc -c < "$TODAY_BRIEFING") bytes)"
    else
        echo "产物: 缺失（$TODAY_BRIEFING 未生成）"
        [ "$rc" -eq 0 ] && rc=1   # 产物缺失时不能报成功（实测 2026-10-10 曾 exit=0 但无产物）
    fi
    echo "============================================================"
    exit $rc
} >> "$LOG_FILE" 2>&1
