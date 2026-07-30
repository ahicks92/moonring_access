#!/usr/bin/env bash
# walk-path.sh — walk the player to a target tile using a BFS path computed
# over the same walkability facts the exploration cursor exposes (the "mental
# map" a player builds by scouting). Doors count as passable; a step that
# doesn't move is retried once (bump-to-open), popups are dismissed as they
# appear. Usage: walk-path.sh <x> <y> [enter]

set -u
BASE=http://127.0.0.1:8771
TX=${1:?target x}; TY=${2:?target y}

path=$(curl -s -X POST --data "
local m = require('ma_map')
local p = G_stateGame.actorManager.player.position
local sx, sy, tx, ty = p.x, p.y, $TX, $TY
local function pass(x, y)
    local r = tostring(m.root(x, y) or '')
    if (r:find('door') or r:find('gate')) and not r:find('Locked') then return true end
    return m.walkable(x, y) == true
end
local function key(x, y) return x * 1000 + y end
local Q, prev, seen = { {sx, sy} }, {}, { [key(sx, sy)] = true }
local DIRS = { {1,0,'d'}, {-1,0,'a'}, {0,1,'s'}, {0,-1,'w'} }
local found = false
local head = 1
while head <= #Q do
    local cx, cy = Q[head][1], Q[head][2]
    head = head + 1
    if cx == tx and cy == ty then found = true break end
    for _, d in ipairs(DIRS) do
        local nx, ny = cx + d[1], cy + d[2]
        local k = key(nx, ny)
        if not seen[k] and math.abs(nx - sx) < 60 and math.abs(ny - sy) < 60 and pass(nx, ny) then
            seen[k] = true
            prev[k] = { cx, cy, d[3] }
            Q[#Q + 1] = { nx, ny }
        end
    end
end
if not found then return 'NOPATH' end
local steps, x, y = {}, tx, ty
while not (x == sx and y == sy) do
    local pr = prev[key(x, y)]
    table.insert(steps, 1, pr[3])
    x, y = pr[1], pr[2]
end
return table.concat(steps, ' ')
" $BASE/eval)

if [ "$path" = "NOPATH" ] || [ -z "$path" ]; then
    echo "no path found to $TX,$TY"
    exit 1
fi
echo "path (${path// /,}) — $(echo $path | wc -w) steps"

pos() {
    curl -s -X POST --data "local p=G_stateGame.actorManager.player.position; return p.x..','..p.y" $BASE/eval
}

for k in $path; do
    # Dismiss anything modal first.
    for _ in 1 2 3; do
        OV=$(curl -s $BASE/gui | head -1)
        case "$OV" in
            *alert*|*tutorial*|*number*) curl -s -X POST --data "space" $BASE/key >/dev/null; sleep 0.8;;
            *) break;;
        esac
    done
    BEFORE=$(pos)
    curl -s -X POST --data "$k" $BASE/key >/dev/null
    sleep 0.6
    AFTER=$(pos)
    if [ "$BEFORE" = "$AFTER" ]; then
        # A door bump: the press opened it; step again.
        curl -s -X POST --data "$k" $BASE/key >/dev/null
        sleep 0.6
        AFTER=$(pos)
        if [ "$BEFORE" = "$AFTER" ]; then
            echo "stuck at $AFTER on step '$k'"
        fi
    fi
done

echo "final: $(pos)"
if [ "${3:-}" = "enter" ]; then
    curl -s -X POST --data "e" $BASE/key >/dev/null
    sleep 3
    echo "pressed enter at target"
fi
