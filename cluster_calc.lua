-- DiveTracker chart, part 1: clustering and ranking (pure maths, no widgets).

local Calc = {}

-- ======
-- Clustering (pure, no widgets)
-- ======

-- Greedy: repeatedly take the waypoint with the most free neighbours inside
-- `radius`, make its neighbours a cluster, remove them, until a best cluster is
-- smaller than minMembers. points = { {x=, y=}, ... }. Returns
-- { {x=centroid, y=centroid, count=n}, ... } biggest first.
local function ComputeClusters(points, radius, minMembers, maxPoints)
    local n = #points
    if n == 0 or n > maxPoints then return {} end
    local r2 = radius * radius

    local bx, by, buckets = {}, {}, {}
    for i = 1, n do
        local cx = math.floor(points[i].x / radius)
        local cy = math.floor(points[i].y / radius)
        bx[i], by[i] = cx, cy
        local key = cx .. "," .. cy
        local b = buckets[key]
        if not b then
            b = {}
            buckets[key] = b
        end
        b[#b + 1] = i
    end

    local nb = {}
    for i = 1, n do
        local list = {}
        local p = points[i]
        for ox = -1, 1 do
            for oy = -1, 1 do
                local b = buckets[(bx[i] + ox) .. "," .. (by[i] + oy)]
                if b then
                    for _, j in ipairs(b) do
                        local dx, dy = points[j].x - p.x, points[j].y - p.y
                        if dx * dx + dy * dy <= r2 then list[#list + 1] = j end
                    end
                end
            end
        end
        nb[i] = list
    end

    local free = {}
    for i = 1, n do free[i] = true end

    local out = {}
    while true do
        local best, bestCount = nil, 0
        for i = 1, n do
            if free[i] then
                local c = 0
                for _, j in ipairs(nb[i]) do
                    if free[j] then c = c + 1 end
                end
                if c > bestCount then best, bestCount = i, c end
            end
        end
        if not best or bestCount < minMembers then break end
        local sx, sy, m = 0, 0, 0
        for _, j in ipairs(nb[best]) do
            if free[j] then
                sx = sx + points[j].x
                sy = sy + points[j].y
                m = m + 1
                free[j] = nil
            end
        end
        out[#out + 1] = { x = sx / m, y = sy / m, count = m }
    end
    return out
end

-- Orders clusters by score for a given position. Returns
-- { {c=cluster, dist=metres, score=n}, ... } best first.
local function RankClusters(clusters, gx, gy, distScale)
    local list = {}
    for _, c in ipairs(clusters) do
        local dx, dy = c.x - gx, c.y - gy
        local dist = math.sqrt(dx * dx + dy * dy)
        list[#list + 1] = { c = c, dist = dist, score = c.count / (1 + dist / distScale) }
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.dist < b.dist
    end)
    return list
end

Calc.ComputeClusters = ComputeClusters
Calc.RankClusters = RankClusters

return Calc
