-- DiveTracker chart: a plain naval-style grid (1 square = 1 degree = 1024 m)
-- showing your own waypoints, translucent circles around clusters of them, and
-- dotted lines from you to the best clusters. No base map is drawn.
--
-- The window is a fixed frame onto a larger chart: drag the map to pan, use
-- + / - (or the mouse wheel) to zoom, "Me" to centre on yourself. Drag the
-- frame edge / title to move the window itself.
--
-- Loaded by main.lua. main.lua hands over two callbacks:
--   getWaypoints() -> list of { gx, gy, ... }   (global metres, east / north)
--   getPlayer()    -> gx, gy of the player, or nil when not known yet
--   getHeading()   -> direction of travel in degrees (north 0, clockwise), or
--                     nil while unknown (optional)
-- and calls Update(dt) every frame and Toggle() from its "Map" button.
--
-- Split over small files: cluster_calc (clusters), cluster_ui (widget
-- helpers), cluster_grid (grid and labels) and this one (the window).

local api = require("api")
local UI = require("DiveTracker/cluster_ui")
local Calc = require("DiveTracker/cluster_calc")
local Grid = require("DiveTracker/cluster_grid")

local ClusterMap = {}

-- ======
-- Settings (edit these)
-- ======

-- The chart extent in degrees (the view cannot be panned past it). The
-- north-west corner is the anchor: 19 W, 3 N.
local LON_WEST, LON_EAST = -19, 15
local LAT_NORTH, LAT_SOUTH = 3, -27
local MPD = 1024                        -- metres per degree

-- The visible frame in pixels, and the zoom steps in pixels per degree.
local VIEW_W, VIEW_H = 760, 620
local ZOOMS = { 10, 14, 20, 28, 40, 56, 80, 112, 160, 224 }
local DEFAULT_ZOOM = 6

-- A cluster is a circle of this radius that holds at least this many waypoints.
local CLUSTER_RADIUS = 800              -- metres
local CLUSTER_MIN_MEMBERS = 4
local CLUSTER_MAX_SHOWN = 60
local CLUSTER_MAX_POINTS = 1500         -- clustering is skipped past this many

-- The best clusters to dive at are ranked by size, discounted by distance:
-- score = count / (1 + distance / RANK_DIST_SCALE).
local RANK_DIST_SCALE = 3000            -- metres
local LINE_COUNT = 5
local LINE_MAX_DOTS = 60
local LINE_MIN_STEP = 9                 -- px between line dots

local WP_DOT_MAX = 600
local WP_DOT_SIZE = 3
local LINE_DOT_SIZE = 3

-- The view cone in front of the player: a centre ray and two side rays, made
-- of small dots at these distances (px) and angles (degrees off the heading).
local HEAD_DOT_SIZE = 3
local HEAD_TURN_MIN = 3                 -- degrees of change that redraw the cone
local HEAD_RAYS = {
    { angle = 0, radii = { 10, 16, 22, 28, 34 }, alpha = 0.95 },
    { angle = -24, radii = { 14, 22, 30 }, alpha = 0.5 },
    { angle = 24, radii = { 14, 22, 30 }, alpha = 0.5 },
}

local REFRESH_MS = 250
local PAN_REFRESH_MS = 50

-- Window margins (px): left holds the latitude labels, top the header and the
-- longitude labels, bottom the status line.
local MARGIN_L, MARGIN_T, MARGIN_R, MARGIN_B = 34, 44, 10, 26
local LABEL_X = 6                   -- left edge of the latitude labels, title and status line

local POS_PATH = "DiveTracker/map_position.txt"
local TEX_DIR = "/DiveTracker/images/"

local X0, X1 = LON_WEST * MPD, LON_EAST * MPD
local Y0, Y1 = LAT_NORTH * MPD, LAT_SOUTH * MPD

-- ======
-- State
-- ======

local cfg = nil                 -- { getWaypoints, getPlayer }
local zoomIndex = DEFAULT_ZOOM
local viewCX, viewCY = nil, nil -- global metres at the centre of the frame
local centred = false           -- false until the view was centred on you / moved
local win, panWin = nil, nil
local visible = false           -- the player wants the chart open
local allowed = true            -- false while no breathing device is equipped
local acc = 0

local layers = {}               -- sea, circles, lines, dots, top
local gridCtx = nil
local statusLabel, closeBtn, zoomInBtn, zoomOutBtn, meBtn
local playerOuter, playerInner

local wpPool, circlePool, countPool, rankPool = {}, {}, {}, {}
local linePools = {}
local headPools = {}
local lastHeading = nil

local srcTable, srcCount = nil, -1
local wpPoints = {}             -- { {x=, y=} } global metres
local clusters = {}             -- all clusters, biggest first
local dirtyData, dirtyView, dirtyPlayer = true, true, true
local lastPX, lastPY = nil, nil

local panning = false
local panOX, panOY, panCX, panCY = 0, 0, 0, 0
local panAcc = 0

local function Mpp() return MPD / ZOOMS[zoomIndex] end

-- global metres -> pixels inside the frame (top-left origin)
local function ToView(gx, gy)
    local mpp = Mpp()
    return VIEW_W / 2 + (gx - viewCX) / mpp, VIEW_H / 2 - (gy - viewCY) / mpp
end

local function Inside(px, py, margin)
    margin = margin or 0
    return px >= margin and py >= margin and px <= VIEW_W - margin and py <= VIEW_H - margin
end

local function ClampView()
    if viewCX < X0 then viewCX = X0 elseif viewCX > X1 then viewCX = X1 end
    if viewCY > Y0 then viewCY = Y0 elseif viewCY < Y1 then viewCY = Y1 end
end

local function SavePosition()
    if not win then return end
    local ok, x, y = pcall(function() return win:GetOffset() end)
    if ok and x and y then
        pcall(function() api.File:Write(POS_PATH, { x = x, y = y, zoom = zoomIndex }) end)
    end
end

local function LoadSaved()
    local ok, data = pcall(function() return api.File:Read(POS_PATH) end)
    if ok and type(data) == "table" then
        if type(data.zoom) == "number" and ZOOMS[data.zoom] then zoomIndex = data.zoom end
        return data
    end
    return nil
end

-- ======
-- Drawing: dots, circles, counts
-- ======

local function DrawDots()
    local shown = 0
    for _, p in ipairs(wpPoints) do
        local px, py = ToView(p.x, p.y)
        if shown < WP_DOT_MAX and Inside(px, py, WP_DOT_SIZE) then
            shown = shown + 1
            local d = UI.PoolGet(wpPool, shown, function(i)
                return UI.MakeSolid(layers.dots, "CMWp" .. i, 0.96, 0.96, 0.96, 0.8)
            end)
            UI.Place(d, layers.dots, px - WP_DOT_SIZE / 2, py - WP_DOT_SIZE / 2, WP_DOT_SIZE, WP_DOT_SIZE)
            d:Show(true)
        end
    end
    UI.PoolHideFrom(wpPool, shown + 1)
end

local function MakeCircle(k)
    local w = layers.circles:CreateChildWidget("window", "CMCircle" .. k, 0, true)
    UI.NoClick(w)
    w.img = w:CreateImageDrawable("CMCircleImg" .. k, "overlay")
    w.tex = nil
    return w
end

local function CircleTexture(ratio)
    if ratio >= 0.66 then return "cluster_hot.png" end
    if ratio >= 0.33 then return "cluster_warm.png" end
    return "cluster_cool.png"
end

local function DrawCircle(n, c, px, py, radiusPx, maxCount)
    local circ = UI.PoolGet(circlePool, n, MakeCircle)
    local tex = CircleTexture(c.count / maxCount)
    if circ.tex ~= tex then
        circ.tex = tex
        circ.img:SetTexture(api.baseDir .. TEX_DIR .. tex)
    end
    local diam = radiusPx * 2
    UI.Place(circ, layers.circles, px - radiusPx, py - radiusPx, diam, diam)
    circ.img:SetExtent(diam, diam)
    circ.img:RemoveAllAnchors()
    circ.img:AddAnchor("TOPLEFT", circ, 0, 0)
    circ:Show(true)

    local lbl = UI.PoolGet(countPool, n, function(k)
        return UI.MakeBoxedLabel(layers.top, "CMCount" .. k, ALIGN.CENTER)
    end)
    UI.PlaceBoxedLabel(lbl, layers.top, string.format("%d", c.count), px, py - 7, true, VIEW_W, VIEW_H)
end

local function DrawCircles()
    local maxCount = 1
    for _, c in ipairs(clusters) do
        if c.count > maxCount then maxCount = c.count end
    end
    local radiusPx = CLUSTER_RADIUS / Mpp()
    local n = 0
    for _, c in ipairs(clusters) do
        local px, py = ToView(c.x, c.y)
        -- Whole circle must fit: children are not clipped by the frame.
        if Inside(px, py, radiusPx + 1) then
            n = n + 1
            DrawCircle(n, c, px, py, radiusPx, maxCount)
        end
    end
    UI.PoolHideFrom(circlePool, n + 1)
    UI.PoolHideFrom(countPool, n + 1)
end

local function LayoutView()
    dirtyView = false
    Grid.Layout(gridCtx, viewCX, viewCY, ZOOMS[zoomIndex])
    DrawDots()
    DrawCircles()
    dirtyPlayer = true
end

-- ======
-- Drawing: player, lines, rank labels
-- ======

local function GetLinePool(r)
    local pool = linePools[r]
    if not pool then
        pool = {}
        linePools[r] = pool
    end
    return pool
end

-- Dotted line from the player to one cluster. Returns the last dot that was
-- inside the frame (or nil).
local function DrawLine(r, pool, ppx, ppy, dx, dy, len, radiusPx)
    local used = 0
    local lastX, lastY = nil, nil
    local startAt = 6
    local span = len - radiusPx - startAt
    if span > 4 and len > 0 then
        local n = math.floor(span / LINE_MIN_STEP) + 1
        if n > 400 then n = 400 end
        local step = span / n
        local ux, uy = dx / len, dy / len
        local alpha = (r == 1) and 0.95 or 0.55
        for k = 1, n do
            local s = startAt + (k - 0.5) * step
            local x, y = ppx + ux * s, ppy + uy * s
            -- Dots outside the frame are skipped (nothing clips them).
            if used < LINE_MAX_DOTS and Inside(x, y, LINE_DOT_SIZE) then
                used = used + 1
                local d = UI.PoolGet(pool, used, function(i)
                    return UI.MakeSolid(layers.lines, "CMLine" .. r .. "_" .. i, 1.0, 0.85, 0.3, alpha)
                end)
                UI.Place(d, layers.lines, x - LINE_DOT_SIZE / 2, y - LINE_DOT_SIZE / 2,
                    LINE_DOT_SIZE, LINE_DOT_SIZE)
                d:Show(true)
                lastX, lastY = x, y
            end
        end
    end
    UI.PoolHideFrom(pool, used + 1)
    return lastX, lastY
end

local function HideRank(rl)
    rl:Show(false)
    rl.box:Show(false)
end

local function DrawRank(r, e, ppx, ppy, radiusPx)
    local pool = GetLinePool(r)
    local rl = UI.PoolGet(rankPool, r, function(k)
        return UI.MakeBoxedLabel(layers.top, "CMRank" .. k, ALIGN.CENTER)
    end)
    if not e then
        UI.PoolHideFrom(pool, 1)
        HideRank(rl)
        return
    end
    local c = e.c
    local cpx, cpy = ToView(c.x, c.y)
    local dx, dy = cpx - ppx, cpy - ppy
    local len = math.sqrt(dx * dx + dy * dy)
    local lastX, lastY = DrawLine(r, pool, ppx, ppy, dx, dy, len, radiusPx)

    local text = string.format("#%d  %.1f km", r, e.dist / 1000)
    if Inside(cpx, cpy, radiusPx) then
        UI.PlaceBoxedLabel(rl, layers.top, text, cpx + radiusPx + 3, cpy - 7, false, VIEW_W, VIEW_H)
    elseif lastX then
        -- Cluster is outside the frame: label the end of the visible line.
        UI.PlaceBoxedLabel(rl, layers.top, text, lastX + 6, lastY - 7, false, VIEW_W, VIEW_H)
    else
        HideRank(rl)
    end
end

-- The view cone: shows where the player is heading. h is in degrees, north 0,
-- clockwise; the screen y axis points down.
local function DrawHeading(ppx, ppy, h)
    for i, ray in ipairs(HEAD_RAYS) do
        local pool = headPools[i]
        if not pool then
            pool = {}
            headPools[i] = pool
        end
        local a = math.rad(h + ray.angle)
        local ux, uy = math.sin(a), -math.cos(a)
        local used = 0
        for _, rad in ipairs(ray.radii) do
            local x, y = ppx + ux * rad, ppy + uy * rad
            if Inside(x, y, HEAD_DOT_SIZE) then
                used = used + 1
                local d = UI.PoolGet(pool, used, function(k)
                    return UI.MakeSolid(layers.top, "CMHead" .. i .. "_" .. k, 0.8, 0.95, 1.0, ray.alpha)
                end)
                UI.Place(d, layers.top, x - HEAD_DOT_SIZE / 2, y - HEAD_DOT_SIZE / 2, HEAD_DOT_SIZE, HEAD_DOT_SIZE)
                d:Show(true)
            end
        end
        UI.PoolHideFrom(pool, used + 1)
    end
end

local function HideHeading()
    for i = 1, #HEAD_RAYS do
        if headPools[i] then UI.PoolHideFrom(headPools[i], 1) end
    end
end

local function HidePlayerStuff()
    playerOuter:Show(false)
    playerInner:Show(false)
    HideHeading()
    for r = 1, LINE_COUNT do
        if linePools[r] then UI.PoolHideFrom(linePools[r], 1) end
    end
    UI.PoolHideFrom(rankPool, 1)
end

local function LayoutPlayer()
    dirtyPlayer = false
    local pgx, pgy = nil, nil
    if cfg and cfg.getPlayer then pgx, pgy = cfg.getPlayer() end

    local status
    if #wpPoints == 0 then
        status = "No waypoints yet. Add some with the Add button."
    else
        status = string.format("%d waypoints, %d clusters (%d m, %d+ each). Drag to pan, + / - to zoom.",
            #wpPoints, #clusters, CLUSTER_RADIUS, CLUSTER_MIN_MEMBERS)
    end

    if not pgx then
        HidePlayerStuff()
        statusLabel:SetText(status)
        lastPX, lastPY = nil, nil
        return
    end

    local ppx, ppy = ToView(pgx, pgy)
    if Inside(ppx, ppy, 5) then
        UI.Place(playerOuter, layers.top, ppx - 5, ppy - 5, 10, 10)
        UI.Place(playerInner, layers.top, ppx - 3, ppy - 3, 6, 6)
        playerOuter:Show(true)
        playerInner:Show(true)
        local h = cfg and cfg.getHeading and cfg.getHeading() or nil
        lastHeading = h
        if h then DrawHeading(ppx, ppy, h) else HideHeading() end
    else
        playerOuter:Show(false)
        playerInner:Show(false)
        HideHeading()
        status = status .. " You are outside the frame: press Me."
    end

    local radiusPx = CLUSTER_RADIUS / Mpp()
    local ranked = Calc.RankClusters(clusters, pgx, pgy, RANK_DIST_SCALE)
    for r = 1, LINE_COUNT do
        DrawRank(r, ranked[r], ppx, ppy, radiusPx)
    end
    statusLabel:SetText(status)
    lastPX, lastPY = pgx, pgy
end

-- ======
-- Data and refresh
-- ======

local function ComputeData()
    dirtyData = false
    local wps = cfg and cfg.getWaypoints and cfg.getWaypoints() or {}
    srcTable, srcCount = wps, #wps
    wpPoints = {}
    for _, m in ipairs(wps) do
        if m.gx and m.gy then wpPoints[#wpPoints + 1] = { x = m.gx, y = m.gy } end
    end
    local all = Calc.ComputeClusters(wpPoints, CLUSTER_RADIUS, CLUSTER_MIN_MEMBERS, CLUSTER_MAX_POINTS)
    clusters = {}
    for _, c in ipairs(all) do
        clusters[#clusters + 1] = c
        if #clusters >= CLUSTER_MAX_SHOWN then break end
    end
    dirtyView = true
    dirtyPlayer = true
end

-- Centres the frame on the player. Returns true when the position was known.
local function CentreOnPlayer()
    local pgx, pgy = nil, nil
    if cfg and cfg.getPlayer then pgx, pgy = cfg.getPlayer() end
    if not pgx then return false end
    viewCX, viewCY = pgx, pgy
    ClampView()
    centred = true
    dirtyView = true
    dirtyPlayer = true
    return true
end

-- First view when nothing is known about the player yet: the middle of the
-- waypoints, or of the chart.
local function ProvisionalCentre()
    if viewCX then return end
    if #wpPoints > 0 then
        local sx, sy = 0, 0
        for _, p in ipairs(wpPoints) do
            sx = sx + p.x
            sy = sy + p.y
        end
        viewCX, viewCY = sx / #wpPoints, sy / #wpPoints
    else
        viewCX, viewCY = (X0 + X1) / 2, (Y0 + Y1) / 2
    end
    ClampView()
end

local function PlayerMoved()
    local pgx, pgy = nil, nil
    if cfg and cfg.getPlayer then pgx, pgy = cfg.getPlayer() end
    if (pgx == nil) ~= (lastPX == nil) then return true end
    if pgx ~= nil and (math.abs(pgx - lastPX) > 1 or math.abs(pgy - lastPY) > 1) then return true end
    local h = cfg and cfg.getHeading and cfg.getHeading() or nil
    if (h == nil) ~= (lastHeading == nil) then return true end
    if h ~= nil then
        local diff = math.abs((h - lastHeading + 180) % 360 - 180)
        if diff > HEAD_TURN_MIN then return true end
    end
    return false
end

local function Refresh()
    local wps = cfg and cfg.getWaypoints and cfg.getWaypoints() or {}
    if wps ~= srcTable or #wps ~= srcCount then dirtyData = true end
    if dirtyData then ComputeData() end
    if not centred then
        if not CentreOnPlayer() then ProvisionalCentre() end
        dirtyView = true
    end
    if dirtyView then LayoutView() end
    if not dirtyPlayer and PlayerMoved() then dirtyPlayer = true end
    if dirtyPlayer then LayoutPlayer() end
end

local function SetZoom(i)
    if not ZOOMS[i] or i == zoomIndex then return end
    zoomIndex = i
    centred = true
    dirtyView = true
    dirtyPlayer = true
    SavePosition()
    if win and visible then Refresh() end
end

-- ======
-- Panning: the invisible pan window over the frame is dragged by the game like
-- any window; how far it moved is how far the map moves.
-- ======

local function ResetPanWindow()
    if not panWin then return end
    panWin:RemoveAllAnchors()
    panWin:SetExtent(VIEW_W, VIEW_H)
    panWin:AddAnchor("TOPLEFT", win, MARGIN_L, MARGIN_T)
end

local function UpdatePan()
    if not panning or not panWin then return end
    local ok, x, y = pcall(function() return panWin:GetOffset() end)
    if not ok or not x then return end
    local scale = 1
    pcall(function() scale = api.Interface:GetUIScale() or 1 end)
    local mpp = Mpp()
    viewCX = panCX - (x - panOX) * scale * mpp
    viewCY = panCY + (y - panOY) * scale * mpp
    ClampView()
    dirtyView = true
    dirtyPlayer = true
end

local function PanDragStart()
    local ok, x, y = pcall(function() return panWin:GetOffset() end)
    if not ok or not x then return end
    panOX, panOY, panCX, panCY = x, y, viewCX, viewCY
    panning = true
    panAcc = 0
    centred = true
    pcall(function() panWin:StartMoving() end)
end

local function PanDragStop()
    pcall(function() panWin:StopMovingOrSizing() end)
    UpdatePan()
    panning = false
    ResetPanWindow()
    Refresh()
end

-- ======
-- Window
-- ======

local function OnWindowHide()
    if allowed then visible = false end
end

local function BuildFrame()
    win = api.Interface:CreateEmptyWindow("DiveTrackerChart", "UIParent")
    win:SetExtent(MARGIN_L + VIEW_W + MARGIN_R, MARGIN_T + VIEW_H + MARGIN_B)
    win:AddAnchor("CENTER", "UIParent", 0, 0)
    win:Show(false)
    win:EnableDrag(true)
    function win:OnDragStart() self:StartMoving() end
    win:SetHandler("OnDragStart", win.OnDragStart)
    function win:OnDragStop()
        self:StopMovingOrSizing()
        SavePosition()
    end
    win:SetHandler("OnDragStop", win.OnDragStop)

    -- Escape closes the chart like a normal game window. The game hides the
    -- window itself, so the OnHide handler keeps `visible` in step with it.
    local escOk, escErr = pcall(function() win:SetCloseOnEscape(true) end)
    if not escOk then
        api.Log:Err("[DiveTracker] Escape-to-close not available for the chart: " .. tostring(escErr))
    end
    pcall(function() win:SetHandler("OnHide", OnWindowHide) end)

    local back = UI.MakeSolid(win, "CMBack", 0.02, 0.04, 0.07, 0.88)
    back:AddAnchor("TOPLEFT", win, 0, 0)
    back:AddAnchor("BOTTOMRIGHT", win, 0, 0)
end

local function MakeLayer(id)
    local w = win:CreateChildWidget("window", id, 0, true)
    UI.NoClick(w)
    UI.Place(w, win, MARGIN_L, MARGIN_T, VIEW_W, VIEW_H)
    return w
end

-- Layers, bottom to top, all exactly the size of the frame.
local function BuildLayers()
    layers.sea = UI.MakeSolid(win, "CMSea", 0.05, 0.15, 0.24, 0.92)
    UI.Place(layers.sea, win, MARGIN_L, MARGIN_T, VIEW_W, VIEW_H)
    layers.circles = MakeLayer("CMCircles")
    layers.lines = MakeLayer("CMLines")
    layers.dots = MakeLayer("CMDots")
    layers.top = MakeLayer("CMTop")

    gridCtx = { win = win, sea = layers.sea, w = VIEW_W, h = VIEW_H,
        marginL = MARGIN_L, marginT = MARGIN_T, mpd = MPD, labelX = LABEL_X }

    playerOuter = UI.MakeSolid(layers.top, "CMPlayerO", 1, 1, 1, 1)
    playerInner = UI.MakeSolid(layers.top, "CMPlayerI", 1, 0.8, 0.1, 1)
    playerOuter:Show(false)
    playerInner:Show(false)

    local title = UI.MakeLabel(win, "CMTitle", ALIGN.LEFT)
    title:SetText("Wreck Chart")
    title:AddAnchor("TOPLEFT", win, LABEL_X, 10)

    statusLabel = UI.MakeLabel(win, "CMStatus", ALIGN.LEFT)
    statusLabel:SetExtent(MARGIN_L + VIEW_W, 14)
    statusLabel:AddAnchor("TOPLEFT", win, LABEL_X, MARGIN_T + VIEW_H + 6)
end

-- The drag-to-pan area sits on top of the frame. It is created after the
-- layers so it is above them; everything below it ignores clicks.
local function BuildPanArea()
    panWin = win:CreateChildWidget("window", "CMPan", 0, true)
    panWin:SetExtent(VIEW_W, VIEW_H)
    panWin:AddAnchor("TOPLEFT", win, MARGIN_L, MARGIN_T)
    pcall(function() panWin:EnableDrag(true) end)
    pcall(function() panWin:SetHandler("OnDragStart", PanDragStart) end)
    pcall(function() panWin:SetHandler("OnDragStop", PanDragStop) end)
    pcall(function() panWin:SetHandler("OnWheelUp", function() SetZoom(zoomIndex + 1) end) end)
    pcall(function() panWin:SetHandler("OnWheelDown", function() SetZoom(zoomIndex - 1) end) end)
end

local function MakeButton(id, text, width, anchorWidget, point, relPoint, x)
    local b = win:CreateChildWidget("button", id, 0, true)
    UI.StyleButton(b, text, width)
    if anchorWidget == win then
        b:AddAnchor(point, win, x, 6)
    else
        b:AddAnchor(point, anchorWidget, relPoint, x, 0)
    end
    return b
end

local function BuildButtons()
    closeBtn = MakeButton("CMClose", "Close", 50, win, "TOPRIGHT", nil, -8)
    function closeBtn:OnClick() ClusterMap.Hide() end
    closeBtn:SetHandler("OnClick", closeBtn.OnClick)

    zoomOutBtn = MakeButton("CMZoomOut", "-", 26, closeBtn, "RIGHT", "LEFT", -4)
    function zoomOutBtn:OnClick() SetZoom(zoomIndex - 1) end
    zoomOutBtn:SetHandler("OnClick", zoomOutBtn.OnClick)

    zoomInBtn = MakeButton("CMZoomIn", "+", 26, zoomOutBtn, "RIGHT", "LEFT", -4)
    function zoomInBtn:OnClick() SetZoom(zoomIndex + 1) end
    zoomInBtn:SetHandler("OnClick", zoomInBtn.OnClick)

    meBtn = MakeButton("CMMe", "Me", 36, zoomInBtn, "RIGHT", "LEFT", -4)
    function meBtn:OnClick()
        CentreOnPlayer()
        Refresh()
    end
    meBtn:SetHandler("OnClick", meBtn.OnClick)
end

local function Build()
    local saved = LoadSaved()
    BuildFrame()
    BuildLayers()
    BuildPanArea()
    BuildButtons()
    if saved and saved.x and saved.y then
        win:RemoveAllAnchors()
        local s = api.Interface:GetUIScale()
        win:AddAnchor("TOPLEFT", "UIParent", saved.x * s, saved.y * s)
    end
end

-- ======
-- Public API
-- ======

function ClusterMap.Init(config)
    cfg = config
end

function ClusterMap.Show()
    if not win then Build() end
    visible = true
    if not allowed then return end
    win:Show(true)
    panning = false
    ResetPanWindow()
    centred = false             -- open centred on you, like a fresh chart
    dirtyData = true
    dirtyView = true
    dirtyPlayer = true
    Refresh()
end

function ClusterMap.Hide()
    visible = false
    panning = false
    if win then win:Show(false) end
end

function ClusterMap.Toggle()
    if visible then ClusterMap.Hide() else ClusterMap.Show() end
end

function ClusterMap.IsVisible() return visible end

-- Called by main.lua every second: false hides the chart (no breathing device
-- equipped), true brings it back if it was open.
function ClusterMap.SetAllowed(flag)
    flag = flag and true or false
    if flag == allowed then return end
    allowed = flag
    if win then
        win:Show(allowed and visible)
        if allowed and visible then
            dirtyView = true
            dirtyPlayer = true
        end
    end
end

function ClusterMap.Update(dt)
    if not visible or not allowed or not win then return end
    dt = dt or 16.6
    if panning then
        UpdatePan()
        panAcc = panAcc + dt
        if panAcc >= PAN_REFRESH_MS then
            panAcc = 0
            Refresh()
        end
        return
    end
    acc = acc + dt
    if acc < REFRESH_MS then return end
    acc = 0
    Refresh()
end

function ClusterMap.Unload()
    visible = false
    panning = false
    if win then
        win:Show(false)
        win = nil
    end
    panWin = nil
    -- every widget lived in the window that is now gone
    layers = {}
    wpPool, circlePool, countPool, rankPool, linePools = {}, {}, {}, {}, {}
    headPools = {}
    Grid.Reset()
end

return ClusterMap