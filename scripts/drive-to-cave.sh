#!/usr/bin/env bash
# drive-to-cave.sh — Phase 4 gate driver: walk the player from wherever they
# are in Yarrow to the Yarrow Cave entrance trigger (42,41) and enter it,
# using only what the mod exposes: /gui to know when a modal wants dismissing,
# the game's own movement keys, and /eval ONLY to read the player position as
# the loop's oracle (a human uses Ctrl+P speech for the same fact).
#
# Movement policy: greedy toward the target; when a whole batch moves nothing,
# try the perpendicular axis for a while (dumb wall-slide). Popups get Space.

set -u
BASE=http://127.0.0.1:8771
TX=42; TY=41

pos() {
    curl -s -X POST --data "local p=G_stateGame.actorManager.player.position; return p.x..','..p.y" $BASE/eval
}

overlay() {
    curl -s $BASE/gui | head -1
}

keys() {
    curl -s -X POST --data "$1" $BASE/key >/dev/null
}

LAST=""
STUCK=0
for i in $(seq 1 120); do
    OV=$(overlay)
    case "$OV" in
        *alert*|*tutorial*|*number*) keys "space"; sleep 0.8; continue;;
        *multi_choice*|*confirm*) keys "escape"; sleep 0.8; continue;;
    esac

    P=$(pos)
    X=${P%,*}; Y=${P#*,}
    if [ "$X" = "$TX" ] && [ "$Y" = "$TY" ]; then
        echo "ARRIVED at $P after $i rounds"
        # Enter the cave: the entrance is a bump/enter trigger.
        keys "e"
        sleep 3
        exit 0
    fi

    DX=$((TX - X)); DY=$((TY - Y))
    HK=$([ $DX -gt 0 ] && echo d || echo a)
    VK=$([ $DY -gt 0 ] && echo s || echo w)

    if [ "$P" = "$LAST" ]; then STUCK=$((STUCK + 1)); else STUCK=0; fi
    LAST=$P

    BATCH=""
    if [ $STUCK -ge 1 ]; then
        # Blocked: cycle through ALL four directions (greedy axes are exactly
        # the blocked ones when we are in a pocket), several steps each so a
        # detour actually clears the obstacle before greed resumes.
        DIRS=(s a w d)
        ALT=${DIRS[$(( (STUCK - 1) % 4 ))]}
        BATCH="$ALT $ALT $ALT $ALT"
    else
        # Greedy: interleave toward the target, dominant axis first.
        if [ ${DX#-} -ge ${DY#-} ]; then
            BATCH="$HK $HK $VK $HK $VK"
        else
            BATCH="$VK $VK $HK $VK $HK"
        fi
    fi
    keys "$BATCH"
    sleep 3
    echo "round $i: at $P stuck=$STUCK -> $BATCH"
done
echo "FAILED to arrive within 120 rounds (last: $(pos))"
exit 1
