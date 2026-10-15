-- DiveTracker chart, part 3: the grid lines and degree labels.
--
-- Grid.Layout(ctx, cx, cy, ppd) draws the part of the chart around the global
-- point (cx, cy) metres at ppd pixels per degree. ctx fields:
--   win (window holding the labels), sea (layer holding the lines),
--   w, h (frame size px), marginL, marginT (frame position in win),
--   mpd (metres per degree).

local UI = require("DiveTracker/cluster_ui")

local Grid = {}

local pools = { majV = {}, minV = {}, majH = {}, minH = {} }
local lonLabels, latLabels = {}, {}

local function LonText(deg)
    if deg < 0 then return string.format("%dW", -deg) end
    if deg > 0 then return string.format("%dE", deg) end
    return "0"
end

local function LatText(deg)
    if deg < 0 then return string.format("%dS", -deg) end
    if deg > 0 then return string.format("%dN", deg) end
    return "0"
end

local function Line(ctx, pool, i, tag, major)
    return UI.PoolGet(pool, i, function(k)
        if major then return UI.MakeSolid(ctx.sea, tag .. k, 0.7, 0.85, 1.0, 0.24) end
        return UI.MakeSolid(ctx.sea, tag .. k, 0.55, 0.75, 0.9, 0.07)
    end)
end

local function LonLabel(ctx, n)
    return UI.PoolGet(lonLabels, n, function(k)
        local lb = UI.MakeLabel(ctx.win, "CMLon" .. k, ALIGN.CENTER)
        lb:SetExtent(30, 14)
        return lb
    end)
end

local function LatLabel(ctx, n)
    return UI.PoolGet(latLabels, n, function(k)
        local lb = UI.MakeLabel(ctx.win, "CMLat" .. k, ALIGN.LEFT)
        lb:SetExtent(ctx.marginL - (ctx.labelX or 6), 14)
        return lb
    end)
end

-- One axis: vertical lines (lon) or horizontal lines (lat).
local function Axis(ctx, vertical, cx, cy, ppd, step, minor)
    local mpd = ctx.mpd
    local mpp = mpd / ppd
    local first, last
    if vertical then
        first = math.ceil((cx - ctx.w / 2 * mpp) / mpd)
        last = math.floor((cx + ctx.w / 2 * mpp) / mpd)
    else
        first = math.ceil((cy - ctx.h / 2 * mpp) / mpd)
        last = math.floor((cy + ctx.h / 2 * mpp) / mpd)
    end
    local poolMaj = vertical and pools.majV or pools.majH
    local poolMin = vertical and pools.minV or pools.minH
    local tagMaj = vertical and "CMGMV" or "CMGMH"
    local tagMin = vertical and "CMGNV" or "CMGNH"
    local nMaj, nMin, nLab = 0, 0, 0
    for d = first, last do
        local major = (d % step == 0)
        if major or minor then
            local p
            if vertical then
                p = math.floor((d * mpd - cx) / mpp + ctx.w / 2 + 0.5)
            else
                p = math.floor(ctx.h / 2 - (d * mpd - cy) / mpp + 0.5)
            end
            local line
            if major then
                nMaj = nMaj + 1
                line = Line(ctx, poolMaj, nMaj, tagMaj, true)
            else
                nMin = nMin + 1
                line = Line(ctx, poolMin, nMin, tagMin, false)
            end
            if vertical then
                UI.Place(line, ctx.sea, p, 0, 1, ctx.h)
            else
                UI.Place(line, ctx.sea, 0, p, ctx.w, 1)
            end
            line:Show(true)
            if major then
                nLab = nLab + 1
                local l
                if vertical then
                    l = LonLabel(ctx, nLab)
                    l:SetText(LonText(d))
                else
                    l = LatLabel(ctx, nLab)
                    l:SetText(LatText(d))
                end
                l:RemoveAllAnchors()
                if vertical then
                    l:AddAnchor("TOPLEFT", ctx.win, ctx.marginL + p - 15, ctx.marginT - 16)
                else
                    l:AddAnchor("TOPLEFT", ctx.win, ctx.labelX or 6, ctx.marginT + p - 7)
                end
                l:Show(true)
            end
        end
    end
    UI.PoolHideFrom(poolMaj, nMaj + 1)
    UI.PoolHideFrom(poolMin, nMin + 1)
    UI.PoolHideFrom(vertical and lonLabels or latLabels, nLab + 1)
end

-- Forget all widgets (the window they live in is gone after an unload).
function Grid.Reset()
    pools.majV, pools.minV, pools.majH, pools.minH = {}, {}, {}, {}
    lonLabels, latLabels = {}, {}
end

function Grid.Layout(ctx, cx, cy, ppd)
    local step = 10
    local choices = { 1, 2, 5, 10 }
    for i = 1, #choices do
        if ppd * choices[i] >= 34 then
            step = choices[i]
            break
        end
    end
    local minor = ppd >= 20
    Axis(ctx, true, cx, cy, ppd, step, minor)
    Axis(ctx, false, cx, cy, ppd, step, minor)
end

return Grid