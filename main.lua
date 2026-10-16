local api = require("api")

-- Separate chart module (grid map of your waypoints). Loaded defensively so a
-- problem in it can never stop the rest of the addon from loading.
local chartOk, ClusterMap = pcall(require, "DiveTracker/cluster_map")
if not chartOk or type(ClusterMap) ~= "table" or type(ClusterMap.Init) ~= "function" then
    api.Log:Err("[DiveTracker] Failed to load cluster_map module: " .. tostring(ClusterMap))
    ClusterMap = nil
end

local DiveTracker = {
    name = "DiveTracker",
    author = "Actioncow",
    desc = "Diving HUD: air, speed, depth, compass, waypoints",
    version = "0.1.0"
}

local BAR_POS_PATH = "DiveTracker/bar_position.txt"
local IFACE_POS_PATH = "DiveTracker/interface_position.txt"
local MANUAL_NAME = "(manual)"   -- pseudo item name while the interface checkbox stands in for a device
-- Two separate waypoint sets, chosen with the icon buttons next to Add/Remove.
-- Type 1 is the original chest file; type 2 (pots) has its own file.
local WAYPOINT_TYPES = {
    { path = "DiveTracker/waypoints.txt", icon = "chest.png" },
    { path = "DiveTracker/waypoints_pot.txt", icon = "pot.png" },
}
local RECOVERY_PATH = "DiveTracker/recovery_count.txt"
local SETTINGS_PATH = "DiveTracker/settings.txt"

-- Item counted by the treasure counter and shown in "Bags Left".
-- Using it fires REMOVED_ITEM with reason "consume".
local RECOVERY_ITEM_ID = 19035

-- Waypoint overlay: how far away markers are shown (selectable in the HUD),
-- and how they fade. Markers are fully opaque up to FADE_START of the range,
-- then fade linearly to FADE_MIN_ALPHA at the edge of the range.
local RANGE_OPTIONS = { 100, 250, 500, 750, 1000, 1500, 2000, 3000 }
local DEFAULT_RANGE = 500
local FADE_START = 0.5
local FADE_MIN_ALPHA = 0.2

-- Guidance: the remaining waypoints are ordered into a short route. Its next
-- stop is the compass chest target, and a faint dotted line leads from you
-- through the next few stops.
local GUIDE_ARRIVE_DIST = 12        -- metres: a stop counts as reached
local GUIDE_HYSTERESIS = 15         -- switch target only if another is this much closer
local ROUTE = {                  -- guide route / dotted line settings
    PLAN_MAX = 60,  -- most stops planned ahead
    LINE_STOPS = 5,  -- stops the dotted line leads through
    DOT_POOL = 150,  -- most dots on screen at once
    DOT_SIZE = 4,
    START_GAP = 3,  -- first dot this far from you
    STEP_MIN = 5,  -- dot spacing: 8% of the distance, at least 5 m
    STEP_FRAC = 0.08,
    MAX_ITER = 450,
    MIN_GAP = 14,  -- px: no two dots closer than this on screen
    MIN_DEPTH = 2,  -- ignore dots this close to the camera
    Z_OFFSET = -1,  -- line ends sit this far below the waypoint
    START_Z_OFFSET = -1,  -- the line starts this far below your position (not at your head)
}

-- ======
-- State
-- ======

-- Breathing alarm: the bar flashes red in the last WARN_SECONDS. The game also
-- has a quirk: when a device reaches ~1 s it jumps back to ~59 s and stays
-- there for a while before it vanishes. Seen right after a reading of
-- DEPLETED_AT or less, a reading up to DEPLETED_MAX_SHOWN counts as "empty".
local WARN_SECONDS = 60
local DEPLETED_AT = 5
local DEPLETED_MAX_SHOWN = 60
local FLASH_MS = 400

local BAR_WIDTH = 230
local BAR_HEIGHT = 60
local FILL_HEIGHT = 16
local FILL_MARGIN = 4

-- widgets
local barWindow = nil
local ifaceWindow = nil      -- the separate "Dive Tracker Interface" checkbox window
local fillBar = nil
local warnBar = nil
local warnActive = false
local warnAcc = 0
local depleted = false
local speedLabel = nil
local timeLabel = nil
local bagLabel = nil
local recoveryLabel = nil
local depthLabel = nil
local wpBtn = nil
local remwpBtn = nil
local mapBtn = nil
local overlayWidget = nil
local eventWindow = nil
local rangeBtn = nil

local nextBtn = nil
local resetBtn = nil

-- Guidance: nearest waypoint that has not been skipped with "Next".
local guideSkipped = {}     -- waypoint key -> true
local guideVisited = {}     -- waypoint key -> true once reached through the routing
local guideKey = nil        -- key of the current target
local guideActive = false
local guideBearing = 0      -- degrees, from you to the target
local guideDist = 0
local routeStops = {}       -- ordered markers, next stop first
local routeSource = nil     -- overlayLabels table the route was planned from
local routeDirty = true     -- replan on the next frame
local routeArmed = {}       -- stop key -> true once you have been away from it
local routeWidget = nil
local routeDots = {}
local routeDotsShown = 0
local routeFrame = 0
local guideIcon = nil
local guideText = nil

-- "Track" / "Overlay" checkboxes (saved in settings.txt).
local trackEnabled = true
local overlayEnabled = true
local guidesEnabled = true
local interfaceEnabled = false   -- manual "Dive Tracker Interface" mode (no device needed)

local overlayRange = DEFAULT_RANGE
local recoveryCount = 0
local waypoints = {}          -- the set of the selected type only
local wpType = 1              -- 1 = chests, 2 = pots (saved in settings.txt)

-- Skipped / visited marks are kept per waypoint type, so Reset only touches
-- the selected type. guideSkipped / guideVisited always point at its tables.
local marksByType = { { skipped = {}, visited = {} }, { skipped = {}, visited = {} } }
local function UseTypeMarks()
    guideSkipped = marksByType[wpType].skipped
    guideVisited = marksByType[wpType].visited
end
local overlayLabels = {}

-- Breathing device tracking (see UpdateBar).
local knownMaxLifeSpan = nil
local lastLifeSpan = nil
local lastItemName = nil

-- Movement heading from consecutive sextant readings.
local currCoords = nil
local prevCoords = nil
local heading = 0
local headingKnown = false   -- true once movement gave a heading

local function FormatMinSec(totalSeconds)
    local t = math.floor(totalSeconds)
    local m = math.floor(t / 60)
    local s = t % 60
    return string.format("%d:%02d", m, s)
end

-- The bar is anchored to its drag-handle window (a thin strip above it), and
-- the handle is what the player drags. The handle's top-left sits at
-- (HANDLE.OX, HANDLE.OY) relative to the bar's top-left: 1 px left of the
-- black bar, and 12 px tall ending 3 px below the top of the bar window.
-- bar_position.txt still stores the bar's own offset, as before.
local HANDLE = { W = 230, H = 12, OX = -1, OY = -9 }

local function SaveBarPosition()
    if handleWindow then
        local x, y = handleWindow:GetOffset()
        if x and y then
            api.File:Write(BAR_POS_PATH, { x = x - HANDLE.OX, y = y - HANDLE.OY })
        end
    end
end

local function LoadBarPosition()
    if handleWindow then
        local data = api.File:Read(BAR_POS_PATH)
        if type(data) == "table" and data.x and data.y then
            local scale = api.Interface:GetUIScale()
            handleWindow:RemoveAllAnchors()
            handleWindow:AddAnchor("TOPLEFT", "UIParent", (data.x + HANDLE.OX) * scale, (data.y + HANDLE.OY) * scale)
        end
    end
end

-- Shows / hides the bar together with its handle.
local function SetBarShown(on)
    if barWindow then barWindow:Show(on) end
    if handleWindow then handleWindow:Show(on) end
end

-- ======
-- Global (sextant) positioning
-- World x/y only mean something inside the zone you are in; sextants are
-- global. +x = East, +y = North, and one arcsecond is 1024/3600 m. Within a
-- zone   world = global - offset   with a constant offset, so waypoints are
-- stored globally and the offset is tracked here. On a zone change the
-- offset jumps (by multiples of 1024 m); that is detected (GEO_SNAP_METERS
-- for GEO_SNAP_FRAMES frames in a row) and the offset is re-learned, with
-- the overlay hidden for those few frames.
-- ======

local METERS_PER_ARCSEC = 1024 / 3600
local GEO_SNAP_METERS = 8
local GEO_SNAP_FRAMES = 3
local GEO_MAX_AVG = 600

local geoOffX, geoOffY = nil, nil
local geoOffN = 0
local geoSettled = false
local geoPendingFrames = 0
local geoPendingX, geoPendingY = 0, 0

local function SextantToGlobal(c)
    local lon = c.deg_long * 3600 + c.min_long * 60 + c.sec_long
    if c.longitude == "W" then lon = -lon end
    local lat = c.deg_lat * 3600 + c.min_lat * 60 + c.sec_lat
    if c.latitude == "S" then lat = -lat end
    return lon * METERS_PER_ARCSEC, lat * METERS_PER_ARCSEC
end

-- Saved waypoints made before global storage only have sextant fields.
local function WaypointGlobal(wp)
    if wp.gx and wp.gy then return wp.gx, wp.gy end
    return SextantToGlobal(wp)
end

local function UpdateGeoOffset(px, py, sext)
    if not px or type(sext) ~= "table" then return end
    local gx, gy = SextantToGlobal(sext)
    local sx, sy = gx - px, gy - py

    if geoOffX == nil then
        geoOffX, geoOffY, geoOffN = sx, sy, 1
        geoSettled = true
        return
    end

    local dx, dy = sx - geoOffX, sy - geoOffY
    if dx * dx + dy * dy > GEO_SNAP_METERS * GEO_SNAP_METERS then
        -- Needs several consecutive frames that agree with each other
        -- before we believe the zone really changed.
        local pdx, pdy = sx - geoPendingX, sy - geoPendingY
        if geoPendingFrames > 0 and (pdx * pdx + pdy * pdy) > GEO_SNAP_METERS * GEO_SNAP_METERS then
            geoPendingFrames = 0
        end
        geoPendingFrames = geoPendingFrames + 1
        geoPendingX, geoPendingY = sx, sy
        geoSettled = false
        if geoPendingFrames >= GEO_SNAP_FRAMES then
            geoOffX, geoOffY, geoOffN = sx, sy, 1
            geoPendingFrames = 0
            geoSettled = true
        end
    else
        geoPendingFrames = 0
        geoSettled = true
        -- Running mean (capped) so the +-0.14 m integer-second rounding
        -- averages out while you move.
        geoOffN = math.min(geoOffN + 1, GEO_MAX_AVG)
        geoOffX = geoOffX + dx / geoOffN
        geoOffY = geoOffY + dy / geoOffN
    end
end

-- ======
-- Pixel-based compass
-- One label per mark (every 15 degrees). Each frame a mark's x position is
-- computed in screen units from its angle relative to the heading, so the
-- tape slides continuously. Marks outside the visible band are hidden.
-- ======

local COMPASS_PIXELS_PER_DEGREE = 2.0   -- zoom: bigger = fewer degrees visible
local COMPASS_MARK_STEP = 15            -- degrees between marks
local COMPASS_MARK_W = 40
local COMPASS_MARK_H = 20
local COMPASS_MARK_Y = 3
local GUIDE_ICON_SIZE = 16
local COMPASS_EDGE_MARGIN = 14          -- hide marks this close to the ends
local COMPASS_NAMES = { [0]="N", [45]="NE", [90]="E", [135]="SE", [180]="S", [225]="SW", [270]="W", [315]="NW" }

local compassMarks = {}
local compassParent = nil

local current_visual_heading = 0.0
local target_heading = 0.0
local starting_heading = 0.0
local last_update_time = 0.0

local function BuildCompass(parent)
    compassParent = parent
    compassMarks = {}
    for angle = 0, 359, COMPASS_MARK_STEP do
        local mark = parent:CreateChildWidget("label", "DiveTrackerCompassMark" .. angle, 0, true)
        mark:SetExtent(COMPASS_MARK_W, COMPASS_MARK_H)
        mark:SetText(COMPASS_NAMES[angle] or "|")
        mark.style:SetAlign(ALIGN.CENTER)
        if FONT_SIZE and FONT_SIZE.SMALL then mark.style:SetFontSize(FONT_SIZE.SMALL) end
        ApplyTextColor(mark, FONT_COLOR.WHITE)
        mark:Show(false)
        mark.angle = angle
        mark.lastX = nil
        compassMarks[#compassMarks + 1] = mark
    end

    -- Chest icon + distance for the guided waypoint (positioned each frame
    -- by UpdateGuideMarker).
    guideIcon = parent:CreateChildWidget("label", "DiveTrackerGuideIcon", 0, true)
    guideIcon:SetExtent(GUIDE_ICON_SIZE, GUIDE_ICON_SIZE)
    guideIcon:AddAnchor("TOPLEFT", parent, BAR_WIDTH / 2 - GUIDE_ICON_SIZE / 2, 4)
    guideIcon.dot = guideIcon:CreateImageDrawable("Dot", "overlay")
    guideIcon.dot:SetTexture(api.baseDir .. "/DiveTracker/images/" .. WAYPOINT_TYPES[wpType].icon)
    guideIcon.dot:SetExtent(GUIDE_ICON_SIZE, GUIDE_ICON_SIZE)
    guideIcon.dot:AddAnchor("TOPLEFT", guideIcon, 0, 0)
    guideIcon.dot:Show(true)
    guideIcon:Show(false)

    -- "Target: N m" sits just below the compass, centred under the red marker.
    guideText = parent:CreateChildWidget("label", "DiveTrackerGuideText", 0, true)
    guideText:SetExtent(120, GUIDE_ICON_SIZE)
    guideText:SetText("")
    guideText.style:SetAlign(ALIGN.CENTER)
    if FONT_SIZE and FONT_SIZE.SMALL then guideText.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(guideText, FONT_COLOR.WHITE)
    guideText:AddAnchor("TOP", parent, "BOTTOM", 0, 2)
    guideText:Show(false)
end

local function UpdateCompass(visualHeading)
    if not compassParent then return end
    local half = BAR_WIDTH / 2
    for _, mark in ipairs(compassMarks) do
        -- signed angle from the heading to this mark, -180..180
        local delta = (mark.angle - visualHeading + 540) % 360 - 180
        local x = delta * COMPASS_PIXELS_PER_DEGREE
        if math.abs(x) <= half - COMPASS_EDGE_MARGIN then
            local left = half + x - COMPASS_MARK_W / 2
            if mark.lastX == nil or math.abs(left - mark.lastX) >= 0.05 then
                mark:RemoveAllAnchors()
                mark:AddAnchor("TOPLEFT", compassParent, left, COMPASS_MARK_Y)
                mark.lastX = left
            end
            if not mark.shown then
                mark:Show(true)
                mark.shown = true
            end
        elseif mark.shown then
            mark:Show(false)
            mark.shown = false
            mark.lastX = nil
        end
    end
end

-- Places the chest icon on the compass at the bearing of the guided
-- waypoint (pinned to the edge when it is outside the visible range) and
-- shows its distance in the label below the compass.
local guideLastLeft = nil
local guideLastDist = nil
local guideShown = false

local function UpdateGuideMarker(visualHeading)
    if not guideIcon then return end
    if not guideActive then
        if guideShown then
            guideIcon:Show(false)
            guideText:Show(false)
            guideShown = false
        end
        return
    end

    local half = BAR_WIDTH / 2
    local limit = half - GUIDE_ICON_SIZE / 2 - 2
    local delta = (guideBearing - visualHeading + 540) % 360 - 180
    local x = delta * COMPASS_PIXELS_PER_DEGREE
    if x > limit then x = limit elseif x < -limit then x = -limit end

    local left = half + x - GUIDE_ICON_SIZE / 2
    if guideLastLeft == nil or math.abs(left - guideLastLeft) >= 0.05 then
        guideIcon:RemoveAllAnchors()
        guideIcon:AddAnchor("TOPLEFT", compassParent, left, 4)
        guideLastLeft = left
    end

    local d = math.floor(guideDist)
    if d ~= guideLastDist then
        guideLastDist = d
        guideText:SetText(string.format("Target: %d m", d))
    end

    if not guideShown then
        guideIcon:Show(true)
        guideText:Show(true)
        guideShown = true
    end
end

-- Eases the displayed heading toward the latest measured heading over
-- 1000 ms (smoothstep) along the shortest way around the circle, and
-- returns the current visual heading in degrees.
local function getSmoothHeading(raw_heading)
    local current_time = api.Time:GetUiMsec()

    if raw_heading and raw_heading ~= target_heading then
        starting_heading = current_visual_heading
        target_heading = raw_heading
        last_update_time = current_time
    end

    local progress = math.min((current_time - last_update_time) / 1000, 1.0)
    progress = progress * progress * (3 - 2 * progress)

    local diff = (target_heading - starting_heading + 180) % 360 - 180
    current_visual_heading = (starting_heading + diff * progress + 360) % 360
    return current_visual_heading
end

-- Sextants as one flat number (arcseconds). North/East positive.
local function toTotalSeconds(deg, min, sec, hemisphere)
    local total = (deg * 3600) + (min * 60) + sec
    if hemisphere == "S" or hemisphere == "W" then
        total = -total
    end
    return total
end

-- Navigation heading (North = 0, clockwise) of the movement from
-- `previous` to `current`; false when standing still, nil without data.
local function calculateHeading(current, previous)
    if current == nil or previous == nil then return end

    local x1 = toTotalSeconds(previous.deg_long, previous.min_long, previous.sec_long, previous.longitude)
    local y1 = toTotalSeconds(previous.deg_lat, previous.min_lat, previous.sec_lat, previous.latitude)
    local x2 = toTotalSeconds(current.deg_long, current.min_long, current.sec_long, current.longitude)
    local y2 = toTotalSeconds(current.deg_lat, current.min_lat, current.sec_lat, current.latitude)

    local dx = x2 - x1
    local dy = y2 - y1
    if dx == 0 and dy == 0 then
        return false
    end

    -- atan2 gives the unit-circle angle (0 = East); heading = 90 - angle.
    local angle_deg = math.deg(math.atan2(dy, dx))
    return (90 - angle_deg + 360) % 360
end

-- ======
-- Waypoint overlay (markers drawn over the world)
-- ======

local function BuildOverlay()
    -- Drop the previous labels first, otherwise every Add/Remove leaves the
    -- old markers behind.
    for _, old in ipairs(overlayLabels) do
        pcall(function() old:Show(false) end)
        pcall(function() api.Interface:Free(old) end)
    end
    overlayLabels = {}
    if overlayWidget ~= nil then
        overlayWidget:Show(false)
        overlayWidget = nil
    end

    overlayWidget = api.Interface:CreateEmptyWindow("OverlayHandler", "UIParent")
    overlayWidget:SetExtent(1, 1)
    overlayWidget:AddAnchor("LEFT", "UIParent", 0, 0)
    overlayWidget:Show(true)

    for index, value in ipairs(waypoints) do
        local overlayLabel = overlayWidget:CreateChildWidget("label", "OverlayLabel" .. index, 0, true)
        overlayLabel:SetText("Distance: ")  -- becomes "Dist. (Visited): " once reached
        overlayLabel.style:SetAlign(ALIGN.CENTER)
        if FONT_SIZE and FONT_SIZE.SMALL then overlayLabel.style:SetFontSize(FONT_SIZE.SMALL) end
        ApplyTextColor(overlayLabel, FONT_COLOR.WHITE)
        overlayLabel:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        overlayLabel:Show(true)

        table.insert(overlayLabels, overlayLabel)

        overlayLabel.gx, overlayLabel.gy = WaypointGlobal(value)
        overlayLabel.z = value.z
        overlayLabel.key = string.format("%.1f,%.1f,%.1f", overlayLabel.gx, overlayLabel.gy, value.z or 0)

        overlayLabel.dot = overlayLabel:CreateImageDrawable("Dot", "overlay")
        overlayLabel.dot:SetTexture(api.baseDir .. "/DiveTracker/images/" .. WAYPOINT_TYPES[wpType].icon)
        overlayLabel.dot:SetExtent(20, 20)
        overlayLabel.dot:AddAnchor("TOP", overlayLabel, 0, 80)
        overlayLabel.dot:Show(true)
    end
end

-- Fades the text and the icon of one marker. t = distance / range (0..1).
local function ApplyOverlayFade(marker, t)
    local a = 1
    if t > FADE_START then
        a = 1 - (t - FADE_START) / (1 - FADE_START) * (1 - FADE_MIN_ALPHA)
    end
    if a < FADE_MIN_ALPHA then a = FADE_MIN_ALPHA end
    if marker.lastAlpha and math.abs(marker.lastAlpha - a) < 0.01 then return end
    marker.lastAlpha = a
    pcall(function() marker.style:SetColor(1, 1, 1, a) end)
    if not marker.iconFadeFailed then
        local ok = pcall(function() marker.dot:SetColor(1, 1, 1, a) end)
        if not ok then marker.iconFadeFailed = true end
    end
end

-- The game's world-to-screen function does not let y go above the top of the
-- screen: a point that should be above it comes back with y set to a fixed
-- value (360 at 1440 px high, UI scale 1.2) while x keeps its real value. Seen
-- when looking down, it makes points ahead of you reappear part way down the
-- screen and swing sideways as you tilt further. Those positions are bogus.
local function IsClampedY(y, screenH, uiScale)
    return math.abs(y - screenH * 0.25) < 0.05 or math.abs(y - 0.3 * screenH / uiScale) < 0.05
end

local function UpdateOverlay(px, py, pz)
    if not px or geoOffX == nil then return end

    if not overlayEnabled then
        for _, value in ipairs(overlayLabels) do
            value:Show(false)
            value.dot:Show(false)
        end
        return
    end

    -- While the zone offset is being re-learned (a few frames at a border)
    -- the projection would be wrong, so hide everything.
    if not geoSettled then
        for _, value in ipairs(overlayLabels) do
            value:Show(false)
            value.dot:Show(false)
        end
        return
    end

    local uiScale = api.Interface:GetUIScale()
    local screenW = api.Interface:GetScreenWidth()
    local screenH = api.Interface:GetScreenHeight()

    for _, value in ipairs(overlayLabels) do
        if value.gx then
            -- global -> this zone's world coordinates
            local wx = value.gx - geoOffX
            local wy = value.gy - geoOffY
            local wz = value.z

            local dx, dy, dz = wx - px, wy - py, wz - pz
            local dist = math.sqrt(dx * dx + dy * dy + dz * dz)

            value:Show(false)
            value.dot:Show(false)

            if dist < overlayRange then
                local x, y, d = X2Util:ConvertWorldToScreen(wx, wy, wz - 1)
                local iconx = X2Util:ConvertWorldToScreen(wx, wy, wz - 1.5)

                -- d is the signed distance from the camera (negative = behind
                -- it). Extreme camera pitch makes x/y explode, so also require
                -- the point to be on screen.
                if x and y and d and iconx and d > 0 and x > 0 and y > 0 and x < screenW and y < screenH
                    and not IsClampedY(y, screenH, uiScale) then
                    ApplyOverlayFade(value, dist / overlayRange)
                    value:SetText(string.format(guideVisited[value.key] and "Dist. (Visited): %d m" or "Distance: %d m", math.floor(dist)))
                    value:RemoveAllAnchors()
                    value:AddAnchor("TOPLEFT", "UIParent", x / uiScale, y / uiScale)

                    -- Icon size: 10 px minimum, growing only when closer than
                    -- 41 m. Clamped for all distances since it also centres
                    -- the icon.
                    local s = 51 - dist
                    if dist > 500 or s < 10 then s = 10 end
                    value.dot:SetExtent(s, s)

                    value.dot:RemoveAllAnchors()
                    value.dot:AddAnchor("TOPLEFT", "UIParent", (iconx - s / 2) / uiScale, y / uiScale + 10)

                    value:Show(true)
                    value.dot:Show(true)
                end
            end
        end
    end
end

-- Plans the route: the first stop is the target (the nearest waypoint to you);
-- each following stop is the waypoint nearest to the stop before it, so the
-- line always goes on to the closest remaining point. Only runs when the
-- target changes or the waypoints change, not per frame.
local function PlanRoute(first)
    routeStops = { first }
    routeArmed = {}

    local cand = {}
    for _, m in ipairs(overlayLabels) do
        if m.gx and m ~= first and not guideSkipped[m.key] then
            cand[#cand + 1] = m
        end
    end

    local cur = first
    for _ = 2, ROUTE.PLAN_MAX do
        local best, bi = math.huge, nil
        local cx, cy, cz = cur.gx, cur.gy, cur.z or 0
        for i, m in ipairs(cand) do
            local dx, dy, dz = m.gx - cx, m.gy - cy, (m.z or cz) - cz
            local d = dx * dx + dy * dy + dz * dz
            if d < best then best, bi = d, i end
        end
        if not bi then break end
        cur = cand[bi]
        routeStops[#routeStops + 1] = cur
        table.remove(cand, bi)
    end
end

-- The target is always the nearest waypoint that has not been skipped or
-- reached (it only switches when another is clearly closer, to stop flicker);
-- the route behind it is replanned whenever the target or the waypoints change.
-- A stop counts as reached when you come within GUIDE_ARRIVE_DIST of it after
-- having been farther away, so a waypoint you just added under yourself is not
-- skipped immediately. All maths is in global metres, so it works across zones.
local function UpdateGuideTarget(px, py, pz)
    guideActive = false
    if not (trackEnabled or guidesEnabled) then return end
    if geoOffX == nil or not geoSettled then return end
    local pgx, pgy = px + geoOffX, py + geoOffY

    if routeSource ~= overlayLabels then
        routeSource = overlayLabels
        routeDirty = true
    end

    local best, bestD, cur, curD = nil, 0, nil, 0
    for _, m in ipairs(overlayLabels) do
        if m.gx and not guideSkipped[m.key] then
            local dx, dy, dz = m.gx - pgx, m.gy - pgy, (m.z or pz) - pz
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if m.key == guideKey then cur, curD = m, d end
            if best == nil or d < bestD then best, bestD = m, d end
        end
    end

    if best == nil then
        guideKey = nil
        routeStops = {}
        return
    end

    local target, targetD = best, bestD
    if cur and curD <= bestD + GUIDE_HYSTERESIS then target, targetD = cur, curD end

    if routeDirty or target.key ~= guideKey or routeStops[1] ~= target then
        routeDirty = false
        guideKey = target.key
        PlanRoute(target)
    end

    if targetD > GUIDE_ARRIVE_DIST * 1.5 then
        routeArmed[target.key] = true
    elseif targetD <= GUIDE_ARRIVE_DIST and routeArmed[target.key] then
        guideSkipped[target.key] = true
        guideVisited[target.key] = true
        routeDirty = true
        guideKey = nil
        return
    end

    local dx, dy = target.gx - pgx, target.gy - pgy
    guideDist = targetD
    -- navigation bearing (North = 0, clockwise)
    guideBearing = (90 - math.deg(math.atan2(dy, dx)) + 360) % 360
    guideActive = trackEnabled
end

-- Dotted guide line: dots are placed along you -> stop 1 -> stop 2 ... in
-- world space (spacing grows with distance so it looks even on screen) and
-- each is projected to the screen; dots behind the camera or off screen are
-- simply not drawn. Updated every other frame.
local function UpdateRouteLines(px, py, pz)
    if not routeWidget then return end

    local used = 0
    local active = guidesEnabled and overlayEnabled and geoSettled and geoOffX ~= nil and routeStops[1] ~= nil
    if active then
        routeFrame = routeFrame + 1
        if routeFrame % 2 == 0 then return end

        local uiScale = api.Interface:GetUIScale()
        local screenW = api.Interface:GetScreenWidth()
        local screenH = api.Interface:GetScreenHeight()
        local pgx, pgy = px + geoOffX, py + geoOffY
        local half = ROUTE.DOT_SIZE / 2

        local lastSx, lastSy = nil, nil     -- screen position of the last dot drawn
        local minGap2 = ROUTE.MIN_GAP * ROUTE.MIN_GAP
        local ax, ay, az = pgx, pgy, pz + ROUTE.START_Z_OFFSET
        local carry = ROUTE.START_GAP
        local iter = 0
        local stops = math.min(#routeStops, ROUTE.LINE_STOPS)

        for s = 1, stops do
            local m = routeStops[s]
            local bx, by, bz = m.gx, m.gy, (m.z or pz) + ROUTE.Z_OFFSET
            local sx, sy, sz = bx - ax, by - ay, bz - az
            local len = math.sqrt(sx * sx + sy * sy + sz * sz)
            if len > 0.01 then
                local pos = carry
                while pos < len and used < ROUTE.DOT_POOL and iter < ROUTE.MAX_ITER do
                    iter = iter + 1
                    local t = pos / len
                    local gx, gy, gz = ax + sx * t, ay + sy * t, az + sz * t
                    local rx, ry, rz = gx - pgx, gy - pgy, gz - pz
                    local r = math.sqrt(rx * rx + ry * ry + rz * rz)
                    if r < overlayRange then
                        local x, y, d = X2Util:ConvertWorldToScreen(gx - geoOffX, gy - geoOffY, gz)
                        -- Looking steeply down (or along a vertical stretch) many dots
                        -- land on nearly the same pixels, so skip any dot too close to
                        -- the previous one, and anything almost in the camera plane,
                        -- where the projection is unreliable.
                        if x and y and d and d > ROUTE.MIN_DEPTH and x > 0 and y > 0 and x < screenW and y < screenH
                            and not IsClampedY(y, screenH, uiScale)
                            and (lastSx == nil or (x - lastSx) ^ 2 + (y - lastSy) ^ 2 >= minGap2) then
                            lastSx, lastSy = x, y
                            used = used + 1
                            local dot = routeDots[used]
                            local left, top = x / uiScale - half, y / uiScale - half
                            if dot.lastX ~= left or dot.lastY ~= top then
                                dot:RemoveAllAnchors()
                                dot:AddAnchor("TOPLEFT", "UIParent", left, top)
                                dot.lastX, dot.lastY = left, top
                            end
                            if not dot.shown then
                                dot:Show(true)
                                dot.shown = true
                            end
                        end
                    end
                    pos = pos + math.max(ROUTE.STEP_MIN, ROUTE.STEP_FRAC * r)
                end
                carry = pos - len
            end
            ax, ay, az = bx, by, bz
        end
    end

    for i = used + 1, routeDotsShown do
        local dot = routeDots[i]
        if dot.shown then
            dot:Show(false)
            dot.shown = false
        end
    end
    routeDotsShown = used
end

local function BuildRouteLines()
    routeWidget = api.Interface:CreateEmptyWindow("DiveTrackerRoute", "UIParent")
    routeWidget:SetExtent(1, 1)
    routeWidget:AddAnchor("LEFT", "UIParent", 0, 0)
    routeWidget:Show(false)

    routeDots = {}
    routeDotsShown = 0
    for i = 1, ROUTE.DOT_POOL do
        local dot = routeWidget:CreateChildWidget("window", "DiveTrackerRouteDot" .. i, 0, true)
        dot:SetExtent(ROUTE.DOT_SIZE, ROUTE.DOT_SIZE)
        dot:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        local bg = dot:CreateColorDrawable(0.6, 0.9, 1, 0.45, "background")
        bg:AddAnchor("TOPLEFT", dot, 0, 0)
        bg:AddAnchor("BOTTOMRIGHT", dot, 0, 0)
        pcall(function() dot:Clickable(false) end)
        dot:Show(false)
        dot.shown = false
        routeDots[i] = dot
    end
end

-- Once per frame: read position + sextants, refresh the zone offset, draw.
local function GeoFrame()
    local px, py, pz = api.Unit:UnitWorldPosition("player")
    if not px then return end
    UpdateGeoOffset(px, py, api.Map:GetPlayerSextants())
    UpdateOverlay(px, py, pz)
    UpdateGuideTarget(px, py, pz)
    UpdateRouteLines(px, py, pz)
end

-- "Next": skip the current target; the next nearest one takes over.
local function GuideNext()
    local m = routeStops[1]
    if m then
        guideSkipped[m.key] = true
        guideKey = nil
    end
    routeDirty = true
end

-- "Reset": forget the skipped/reached waypoints and replan with all of them.
local function GuideReset()
    marksByType[wpType] = { skipped = {}, visited = {} }
    UseTypeMarks()
    guideKey = nil
    routeDirty = true
end

-- ======
-- Waypoints
-- ======

local function LoadWaypoints()
    local ok, data = pcall(function() return api.File:Read(WAYPOINT_TYPES[wpType].path) end)
    if ok and type(data) == "table" then
        waypoints = data
        BuildOverlay()
    end
end

local function SaveWaypoints()
    local ok, err = pcall(function()
        api.File:Write(WAYPOINT_TYPES[wpType].path, waypoints)
    end)
    if not ok then
        api.Log:Err("[DiveTracker] Failed to save waypoints: " .. tostring(err))
    end
    LoadWaypoints()
end

-- Selects the chest (1) or pot (2) set. Overlay, route, guide icon and chart
-- all follow, since they only ever see the selected set. Skipped / visited
-- marks are keyed by position, so they simply stay valid per set.
local SaveSettings   -- defined with the other settings code below
local typeButtons = {}

local function RefreshTypeButtons()
    for t, b in ipairs(typeButtons) do
        pcall(function()
            if t == wpType then b.bg:SetColor(1, 1, 1, 0.35) else b.bg:SetColor(0, 0, 0, 0.6) end
        end)
    end
end

local function SetWaypointType(t)
    if t == wpType then return end
    wpType = t
    UseTypeMarks()
    waypoints = {}
    guideKey = nil
    routeDirty = true
    if guideIcon and guideIcon.dot then
        pcall(function()
            guideIcon.dot:SetTexture(api.baseDir .. "/DiveTracker/images/" .. WAYPOINT_TYPES[wpType].icon)
        end)
    end
    BuildOverlay()          -- empty first, so a missing file leaves a clean set
    LoadWaypoints()
    SaveSettings()
    RefreshTypeButtons()
end

local function AddNewWaypoint()
    local ok, err = pcall(function()
        local c = api.Map:GetPlayerSextants()
        local px, py, pz = api.Unit:UnitWorldPosition("player")
        -- Stored globally (sub-second precise once the offset has settled).
        -- World x/y are deliberately not stored: they are only valid in the
        -- zone you are standing in.
        if geoOffX then
            c.gx, c.gy = px + geoOffX, py + geoOffY
        else
            c.gx, c.gy = SextantToGlobal(c)
        end
        c.z = pz
        table.insert(waypoints, c)
        SaveWaypoints()
    end)
    if not ok then
        api.Log:Err("[DiveTracker] Failed to add new waypoint: " .. tostring(err))
    end
end

-- Removes the nearest waypoint within 10 m (3D, in global metres).
local function RemoveWaypoint()
    local px, py, pz = api.Unit:UnitWorldPosition("player")
    if not px or geoOffX == nil then return end
    local pgx, pgy = px + geoOffX, py + geoOffY

    local nearest_obj = nil
    local nearest_dist_sq = 10 * 10

    for index, value in ipairs(waypoints) do
        local gx, gy = WaypointGlobal(value)
        local dx = gx - pgx
        local dy = gy - pgy
        local dz = (value.z or pz) - pz
        local dist_sq = (dx * dx) + (dy * dy) + (dz * dz)

        if dist_sq <= nearest_dist_sq then
            nearest_dist_sq = dist_sq
            nearest_obj = index
        end
    end

    if nearest_obj ~= nil then
        table.remove(waypoints, nearest_obj)
        SaveWaypoints()
    end
end

-- ======
-- Recovery counter, bag count and item events
-- ======

local function SaveRecoveryCount()
    local ok, err = pcall(function()
        api.File:Write(RECOVERY_PATH, { count = recoveryCount })
    end)
    if not ok then
        api.Log:Err("[DiveTracker] Failed to save recovery count: " .. tostring(err))
    end
end

local function LoadRecoveryCount()
    local ok, data = pcall(function() return api.File:Read(RECOVERY_PATH) end)
    if ok and type(data) == "table" and type(data.count) == "number" then
        recoveryCount = data.count
    else
        recoveryCount = 0
    end
end

local function UpdateRecoveriesLabel()
    if recoveryLabel then
        pcall(function() recoveryLabel:SetText("Treasures Lifted: " .. tostring(recoveryCount)) end)
    end
end

-- Pouches left in the bag. CountBagItemByItemType takes the item type,
-- which is the same number as the <id> in the item link "|i<id>,...".
local function UpdateBagLabel()
    if not bagLabel then return end
    local ok, n = pcall(function()
        return api.Bag:CountBagItemByItemType(RECOVERY_ITEM_ID)
    end)
    if ok and type(n) == "number" then
        pcall(function() bagLabel:SetText("Bags Left: " .. tostring(n)) end)
    end
end

-- REMOVED_ITEM args: itemLink, count, reason, ...
local function OnItemRemoved(itemLink, _, reason)
    if reason ~= "consume" or type(itemLink) ~= "string" then return end
    local _, _, id = string.find(itemLink, "|i(%d+)")
    if tonumber(id) ~= RECOVERY_ITEM_ID then return end
    recoveryCount = recoveryCount + 1
    SaveRecoveryCount()
    UpdateRecoveriesLabel()
end

-- Events are registered on a hidden widget (RegisterEvent + OnEvent).
local function BuildEventWindow()
    local ok, err = pcall(function()
        eventWindow = api.Interface:CreateEmptyWindow("DiveTrackerEventWindow", "UIParent")
        eventWindow:SetExtent(1, 1)
        eventWindow:AddAnchor("TOPLEFT", "UIParent", 0, 0)
        function eventWindow:OnEvent(event, ...)
            if event == "BAG_UPDATE" or event == "ADDED_ITEM" or event == "REMOVED_ITEM" then
                UpdateBagLabel()
            end
            if event == "REMOVED_ITEM" then
                local hok, herr = pcall(OnItemRemoved, ...)
                if not hok then
                    api.Log:Err("[DiveTracker] OnItemRemoved error: " .. tostring(herr))
                end
            end
        end
        eventWindow:SetHandler("OnEvent", eventWindow.OnEvent)
        eventWindow:RegisterEvent("REMOVED_ITEM")
        eventWindow:RegisterEvent("ADDED_ITEM")
        eventWindow:RegisterEvent("BAG_UPDATE")
    end)
    if not ok then
        api.Log:Err("[DiveTracker] Could not set up item events: " .. tostring(err))
    end
end

-- ======
-- Button style: see-through black rectangle with white text, like the bar
-- ======

-- Side columns, mirrored about the vertical centre of the black bar (it spans
-- x -1..229 and y 6..61 inside the bar window). Two buttons of BTN_H with
-- BTN_GAP between them are exactly as tall as the bar; the rows below continue
-- at the same pitch.
local BTN_W = 96
local BTN_H = 25
local BTN_GAP = 5
local SIDE_GAP = 4              -- black bar to buttons, the same on both sides
local BAR_VIS_LEFT, BAR_VIS_RIGHT, BAR_VIS_TOP = -1, 229, 6
local CHECK_PITCH = 15          -- distance between checkbox rows (half the button pitch)

local function RowTop(row)
    return BAR_VIS_TOP + (row - 1) * (BTN_H + BTN_GAP)
end

-- Row 1 and 2 are beside the bar, rows 3 and up below it.
local function PlaceLeft(btn, row)
    btn:AddAnchor("TOPRIGHT", barWindow, "TOPLEFT", BAR_VIS_LEFT - SIDE_GAP, RowTop(row))
end

local function PlaceRight(btn, row)
    btn:AddAnchor("TOPLEFT", barWindow, "TOPRIGHT", BAR_VIS_RIGHT + SIDE_GAP - BAR_WIDTH, RowTop(row))
end

local function StyleButton(btn, text, width, height)
    btn:SetText(text)
    btn:SetExtent(width or BTN_W, height or BTN_H)
    local bg = btn:CreateColorDrawable(0, 0, 0, 0.6, "background")
    bg:AddAnchor("TOPLEFT", btn, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    btn.bg = bg
    pcall(function() btn.style:SetAlign(ALIGN.CENTER) end)
    pcall(function() ApplyTextColor(btn, FONT_COLOR.WHITE) end)
    pcall(function() btn.style:SetColor(1, 1, 1, 1) end)
    pcall(function()
        btn:SetHandler("OnEnter", function() pcall(function() bg:SetColor(0.25, 0.25, 0.25, 0.75) end) end)
        btn:SetHandler("OnLeave", function() pcall(function() bg:SetColor(0, 0, 0, 0.6) end) end)
    end)
    return bg
end

-- ======
-- Overlay range setting (drop-down list to the right of the Add/Remove buttons)
-- ======

local function RangeLabel(value)
    return tostring(value) .. " m"
end

local function RangeIndex(value)
    for i, v in ipairs(RANGE_OPTIONS) do
        if v == value then return i end
    end
    return nil
end

local function LoadSettings()
    local ok, data = pcall(function() return api.File:Read(SETTINGS_PATH) end)
    overlayRange = DEFAULT_RANGE
    trackEnabled = true
    overlayEnabled = true
    guidesEnabled = true
    interfaceEnabled = false
    wpType = 1
    if ok and type(data) == "table" then
        if RangeIndex(data.range) then
            overlayRange = data.range
        elseif type(data.range) == "number" and data.range > RANGE_OPTIONS[#RANGE_OPTIONS] then
            -- saved from an older version that offered 4000/5000
            overlayRange = RANGE_OPTIONS[#RANGE_OPTIONS]
        end
        if data.track == false then trackEnabled = false end
        if data.overlay == false then overlayEnabled = false end
        if data.guides == false then guidesEnabled = false end
        if data.interface == true then interfaceEnabled = true end
        if data.wptype == 2 then wpType = 2 end
    end
end

SaveSettings = function()
    pcall(function()
        api.File:Write(SETTINGS_PATH, {
            range = overlayRange,
            track = trackEnabled,
            overlay = overlayEnabled,
            guides = guidesEnabled,
            interface = interfaceEnabled,
            wptype = wpType,
        })
    end)
end

local rangeList = nil        -- popup window holding one button per range
local rangeItems = {}

local function RefreshRangeItems()
    for i, item in ipairs(rangeItems) do
        local on = RANGE_OPTIONS[i] == overlayRange
        pcall(function()
            item.bg:SetColor(on and 0.3 or 0, on and 0.3 or 0, on and 0.3 or 0, on and 0.85 or 0.6)
        end)
        item.selected = on
    end
end

local function SetOverlayRange(value)
    if not RangeIndex(value) then return end
    overlayRange = value
    SaveSettings()
    if rangeBtn then
        pcall(function() rangeBtn:SetText("Range: " .. RangeLabel(value)) end)
    end
    RefreshRangeItems()
end

-- A button showing the current range; clicking it opens a list of the ranges.
local function BuildRangeSelector()
    rangeBtn = barWindow:CreateChildWidget("button", "rangeBtn", 0, true)
    StyleButton(rangeBtn, "Range: " .. RangeLabel(overlayRange))
    PlaceRight(rangeBtn, 3)

    local itemH = 20
    rangeList = barWindow:CreateChildWidget("window", "rangeList", 0, true)
    rangeList:SetExtent(BTN_W, #RANGE_OPTIONS * itemH)
    -- Opens upwards, to the right of the button, so it never leaves the screen.
    rangeList:AddAnchor("BOTTOMLEFT", rangeBtn, "BOTTOMRIGHT", 4, 10)
    rangeList:Show(false)

    for i, v in ipairs(RANGE_OPTIONS) do
        local item = rangeList:CreateChildWidget("button", "rangeItem" .. i, 0, true)
        item.bg = StyleButton(item, RangeLabel(v), BTN_W, 20)
        -- Keep the selected row highlighted when the mouse leaves it.
        pcall(function()
            item:SetHandler("OnLeave", function()
                pcall(function()
                    if item.selected then item.bg:SetColor(0.3, 0.3, 0.3, 0.85)
                    else item.bg:SetColor(0, 0, 0, 0.6) end
                end)
            end)
        end)
        item:AddAnchor("TOPLEFT", rangeList, 0, (i - 1) * itemH)
        function item:OnClick()
            SetOverlayRange(RANGE_OPTIONS[i])
            rangeList:Show(false)
        end
        item:SetHandler("OnClick", item.OnClick)
        rangeItems[i] = item
    end
    RefreshRangeItems()

    function rangeBtn:OnClick()
        rangeList:Show(not rangeList:IsVisible())
    end
    rangeBtn:SetHandler("OnClick", rangeBtn.OnClick)
end

-- ======
-- HUD bar
-- ======

-- Checkbox built from plain widgets (box, tick, label and a click area), so it
-- does not depend on a checkbox widget type. It sits on the left of the window
-- with its right edge 4 px from the window, like the Next/Reset buttons.
-- slot 1: the top of its box is level with the top of the compass / Range button.
local function BuildCheckbox(id, text, slot, initial, onChange)
    local checked = initial and true or false
    -- vertical centre of the row, relative to the centre of the bar window
    local yOffset = RowTop(3) + 14 / 2 - BAR_HEIGHT / 2 + (slot - 1) * CHECK_PITCH   -- box is 14 px tall
    local rightEdge = BAR_VIS_LEFT - SIDE_GAP

    local box = barWindow:CreateChildWidget("window", id .. "Box", 0, true)
    box:SetExtent(14, 14)
    box:AddAnchor("RIGHT", barWindow, "LEFT", rightEdge, yOffset)
    local border = box:CreateColorDrawable(1, 1, 1, 0.8, "background")
    border:AddAnchor("TOPLEFT", box, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", box, 0, 0)
    local inner = box:CreateColorDrawable(0, 0, 0, 0.8, "background")
    inner:AddAnchor("TOPLEFT", box, 1, 1)
    inner:AddAnchor("BOTTOMRIGHT", box, -1, -1)

    local tick = box:CreateChildWidget("window", id .. "Tick", 0, true)
    tick:AddAnchor("TOPLEFT", box, 3, 3)
    tick:AddAnchor("BOTTOMRIGHT", box, -3, -3)
    local tickBg = tick:CreateColorDrawable(0.3, 0.9, 0.4, 1, "background")
    tickBg:AddAnchor("TOPLEFT", tick, 0, 0)
    tickBg:AddAnchor("BOTTOMRIGHT", tick, 0, 0)
    tick:Show(checked)

    local label = barWindow:CreateChildWidget("label", id .. "Label", 0, true)
    label:SetText(text)
    label.style:SetAlign(ALIGN.RIGHT)
    if FONT_SIZE and FONT_SIZE.SMALL then label.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(label, FONT_COLOR.WHITE)
    label:AddAnchor("RIGHT", box, "LEFT", -4, 0)

    -- Click area over the box and its label (created last so it is on top).
    local hit = barWindow:CreateChildWidget("button", id .. "Hit", 0, true)
    hit:SetExtent(70, 14)
    hit:AddAnchor("RIGHT", barWindow, "LEFT", rightEdge, yOffset)
    function hit:OnClick()
        checked = not checked
        tick:Show(checked)
        onChange(checked)
    end
    hit:SetHandler("OnClick", hit.OnClick)
end

local function BuildBar()
    -- Drag handle: its own small window above the bar (the same drag pattern
    -- as the bar used before); the bar is anchored to it and follows.
    handleWindow = api.Interface:CreateEmptyWindow("DiveTrackerHandle", "UIParent")
    handleWindow:SetExtent(HANDLE.W, HANDLE.H)
    handleWindow:AddAnchor("BOTTOM", "UIParent", HANDLE.OX + HANDLE.W / 2 - BAR_WIDTH / 2, -(260 + BAR_HEIGHT - (HANDLE.OY + HANDLE.H)))
    handleWindow:Show(false)
    handleWindow:EnableDrag(true)
    function handleWindow:OnDragStart() self:StartMoving() end
    handleWindow:SetHandler("OnDragStart", handleWindow.OnDragStart)
    function handleWindow:OnDragStop()
        self:StopMovingOrSizing()
        SaveBarPosition()
    end
    handleWindow:SetHandler("OnDragStop", handleWindow.OnDragStop)

    local gripBg = handleWindow:CreateColorDrawable(1, 1, 1, 0.22, "background")
    gripBg:AddAnchor("TOPLEFT", handleWindow, 0, 0)
    gripBg:AddAnchor("BOTTOMRIGHT", handleWindow, 0, 0)
    for i = 0, 2 do
        local y = 3 + i * 3
        local line = handleWindow:CreateColorDrawable(1, 1, 1, 0.75, "background")
        line:AddAnchor("TOPLEFT", handleWindow, 101, y)
        line:AddAnchor("BOTTOMRIGHT", handleWindow, 129 - HANDLE.W, y + 1 - HANDLE.H)
    end

    barWindow = api.Interface:CreateEmptyWindow("DiveTrackerBar", "UIParent")
    barWindow:SetExtent(BAR_WIDTH, BAR_HEIGHT)
    barWindow:AddAnchor("TOPLEFT", handleWindow, "TOPLEFT", -HANDLE.OX, -HANDLE.OY)
    barWindow:Show(false)

    -- Black semi-transparent backgrounds (labels area, oxygen strip, compass).
    local backBar1 = barWindow:CreateChildWidget("window", "DiveTrackerBack1", 0, true)
    backBar1:SetExtent(BAR_WIDTH, 55)
    backBar1:AddAnchor("BOTTOMLEFT", barWindow, FILL_MARGIN - 5, -FILL_MARGIN + 5)
    local backBg = backBar1:CreateColorDrawable(0, 0, 0, 0.5, "background")
    backBg:AddAnchor("TOPLEFT", backBar1, 0, 0)
    backBg:AddAnchor("BOTTOMRIGHT", backBar1, 0, 0)

    local backBar3 = barWindow:CreateChildWidget("window", "DiveTrackerBack3", 0, true)
    backBar3:SetExtent(212, 15)
    backBar3:AddAnchor("BOTTOMLEFT", barWindow, FILL_MARGIN, -FILL_MARGIN)
    local backBg3 = backBar3:CreateColorDrawable(0, 0, 0, 0.5, "background")
    backBg3:AddAnchor("TOPLEFT", backBar3, 0, 0)
    backBg3:AddAnchor("BOTTOMRIGHT", backBar3, 0, 0)

    local compassBar = barWindow:CreateChildWidget("window", "DiveTrackerBack2", 0, true)
    -- Same top and height as the Range button (row 3 of the side columns).
    compassBar:SetExtent(BAR_WIDTH, BTN_H)
    compassBar:AddAnchor("BOTTOMLEFT", barWindow, 0, RowTop(3) + BTN_H - BAR_HEIGHT)
    local backBg2 = compassBar:CreateColorDrawable(0, 0, 0, 0.5, "background")
    backBg2:AddAnchor("TOPLEFT", compassBar, 0, 0)
    backBg2:AddAnchor("BOTTOMRIGHT", compassBar, 0, 0)
    BuildCompass(compassBar)

    -- Blue fill bar: left edge fixed, width recomputed each update so it
    -- shrinks from the right as oxygen depletes. CreateColorDrawable gives a
    -- flat fill with no texture/gradient.
    fillBar = barWindow:CreateChildWidget("window", "DiveTrackerFill", 0, true)
    fillBar:SetExtent(BAR_WIDTH - FILL_MARGIN * 2, FILL_HEIGHT)
    fillBar:AddAnchor("BOTTOMLEFT", barWindow, FILL_MARGIN, -FILL_MARGIN)
    local fillOk, fillErr = pcall(function()
        local fillBg = fillBar:CreateColorDrawable(0.2, 0.55, 0.95, 0.65, "background")
        fillBg:AddAnchor("TOPLEFT", fillBar, 0, 0)
        fillBg:AddAnchor("BOTTOMRIGHT", fillBar, 0, 0)
    end)
    if not fillOk then
        api.Log:Err("[DiveTracker] Fill bar color drawable failed: " .. tostring(fillErr))
    end

    -- Red strip over the oxygen bar, flashed by UpdateWarnFlash.
    warnBar = barWindow:CreateChildWidget("window", "DiveTrackerWarn", 0, true)
    warnBar:SetExtent(BAR_WIDTH - FILL_MARGIN * 2, FILL_HEIGHT)
    warnBar:AddAnchor("BOTTOMLEFT", barWindow, FILL_MARGIN, -FILL_MARGIN)
    pcall(function() warnBar:Clickable(false) end)
    local warnBg = warnBar:CreateColorDrawable(1, 0.1, 0.1, 0.7, "background")
    warnBg:AddAnchor("TOPLEFT", warnBar, 0, 0)
    warnBg:AddAnchor("BOTTOMRIGHT", warnBar, 0, 0)
    warnBar:Show(false)

    -- Labels above the blue fill.
    speedLabel = barWindow:CreateChildWidget("label", "DiveTrackerSpeedLabel", 0, true)
    speedLabel:SetText("")
    speedLabel.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then speedLabel.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(speedLabel, FONT_COLOR.WHITE)
    speedLabel:AddAnchor("TOPLEFT", barWindow, FILL_MARGIN, 15)

    timeLabel = barWindow:CreateChildWidget("label", "DiveTrackerTimeLabel", 0, true)
    timeLabel:SetText("")
    timeLabel.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then timeLabel.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(timeLabel, FONT_COLOR.WHITE)
    timeLabel:AddAnchor("LEFT", speedLabel, "RIGHT", 80, 0)

    bagLabel = barWindow:CreateChildWidget("label", "DiveTrackerBagLabel", 0, true)
    bagLabel:SetText("Bags Left:")
    bagLabel.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then bagLabel.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(bagLabel, FONT_COLOR.WHITE)
    bagLabel:AddAnchor("LEFT", speedLabel, "RIGHT", 0, 15)

    recoveryLabel = barWindow:CreateChildWidget("label", "DiveTrackerRecoveryLabel", 0, true)
    recoveryLabel:SetText("Treasures Lifted:")
    recoveryLabel.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then recoveryLabel.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(recoveryLabel, FONT_COLOR.WHITE)
    recoveryLabel:AddAnchor("LEFT", timeLabel, "RIGHT", 0, 15)

    depthLabel = barWindow:CreateChildWidget("label", "DiveTrackerDepthLabel", 0, true)
    depthLabel:SetText("Depth: ")
    depthLabel.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then depthLabel.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(depthLabel, FONT_COLOR.WHITE)
    depthLabel:AddAnchor("LEFT", timeLabel, "RIGHT", 80, 0)

    -- Red centre marker on the compass.
    local redBar = barWindow:CreateChildWidget("window", "DiveTrackerRedBar", 0, true)
    redBar:SetExtent(2, 20)
    redBar:AddAnchor("BOTTOMLEFT", compassBar, BAR_WIDTH / 2 - 1, -FILL_MARGIN + 2)
    local redBg = redBar:CreateColorDrawable(1, 0, 0, 0.5, "background")
    redBg:AddAnchor("TOPLEFT", redBar, 0, 0)
    redBg:AddAnchor("BOTTOMRIGHT", redBar, 0, 0)

    -- Waypoint buttons.
    wpBtn = barWindow:CreateChildWidget("button", "wpBtn", 0, true)
    StyleButton(wpBtn, "Add")
    PlaceRight(wpBtn, 1)
    function wpBtn:OnClick()
        AddNewWaypoint()
    end
    wpBtn:SetHandler("OnClick", wpBtn.OnClick)

    remwpBtn = barWindow:CreateChildWidget("button", "remwpBtn", 0, true)
    StyleButton(remwpBtn, "Remove")
    PlaceRight(remwpBtn, 2)
    function remwpBtn:OnClick()
        RemoveWaypoint()
    end
    remwpBtn:SetHandler("OnClick", remwpBtn.OnClick)

    -- Radio buttons for the waypoint type: one icon per row, to the right of
    -- Add / Remove. The selected one has a lighter background.
    for t = 1, 2 do
        local b = barWindow:CreateChildWidget("button", "wpType" .. t, 0, true)
        b:SetExtent(BTN_H, BTN_H)
        b:AddAnchor("TOPLEFT", barWindow, "TOPRIGHT", BAR_VIS_RIGHT + SIDE_GAP - BAR_WIDTH + BTN_W + SIDE_GAP, RowTop(t))
        b.bg = b:CreateColorDrawable(0, 0, 0, 0.6, "background")
        b.bg:AddAnchor("TOPLEFT", b, 0, 0)
        b.bg:AddAnchor("BOTTOMRIGHT", b, 0, 0)
        local icon = b:CreateImageDrawable("Icon", "overlay")
        icon:SetTexture(api.baseDir .. "/DiveTracker/images/" .. WAYPOINT_TYPES[t].icon)
        icon:SetExtent(BTN_H - 6, BTN_H - 6)
        icon:AddAnchor("CENTER", b, 0, 0)
        function b:OnClick() SetWaypointType(t) end
        b:SetHandler("OnClick", b.OnClick)
        typeButtons[t] = b
    end
    RefreshTypeButtons()

    -- Opens / closes the wreck chart (cluster_map.lua).
    if ClusterMap then
        mapBtn = barWindow:CreateChildWidget("button", "mapBtn", 0, true)
        StyleButton(mapBtn, "Map")
        PlaceRight(mapBtn, 4)
        function mapBtn:OnClick()
            local ok, err = pcall(ClusterMap.Toggle)
            if not ok then api.Log:Err("[DiveTracker] Map toggle failed: " .. tostring(err)) end
        end
        mapBtn:SetHandler("OnClick", mapBtn.OnClick)
    end

    BuildRangeSelector()

    -- Guidance buttons on the left side.
    nextBtn = barWindow:CreateChildWidget("button", "nextBtn", 0, true)
    StyleButton(nextBtn, "Next")
    PlaceLeft(nextBtn, 1)
    function nextBtn:OnClick()
        GuideNext()
    end
    nextBtn:SetHandler("OnClick", nextBtn.OnClick)

    resetBtn = barWindow:CreateChildWidget("button", "resetBtn", 0, true)
    StyleButton(resetBtn, "Reset")
    PlaceLeft(resetBtn, 2)
    function resetBtn:OnClick()
        GuideReset()
    end
    resetBtn:SetHandler("OnClick", resetBtn.OnClick)

    BuildCheckbox("trackChk", "Track", 1, trackEnabled, function(on)
        trackEnabled = on
        routeDirty = true
        SaveSettings()
    end)
    BuildCheckbox("overlayChk", "Overlay", 2, overlayEnabled, function(on)
        overlayEnabled = on
        SaveSettings()
    end)
    BuildCheckbox("guidesChk", "Guides", 3, guidesEnabled, function(on)
        guidesEnabled = on
        routeDirty = true
        SaveSettings()
    end)

    LoadBarPosition()
end

-- Separate small window with one checkbox: "Dive Tracker Interface". Always
-- visible and draggable. Checked = the bar, overlay, route and chart behave as
-- if a breathing device were equipped (air shows 0:00, no red alarm).
local UpdateBar   -- defined below

local function BuildInterfaceWindow()
    local function SaveIfacePosition()
        if ifaceWindow then
            local x, y = ifaceWindow:GetOffset()
            if x and y then
                api.File:Write(IFACE_POS_PATH, { x = x, y = y })
            end
        end
    end

    local function LoadIfacePosition()
        if ifaceWindow then
            local data = api.File:Read(IFACE_POS_PATH)
            if type(data) == "table" and data.x and data.y then
                ifaceWindow:RemoveAllAnchors()
                ifaceWindow:AddAnchor("TOPLEFT", "UIParent", data.x * api.Interface:GetUIScale(), data.y * api.Interface:GetUIScale())
            end
        end
    end

    ifaceWindow = api.Interface:CreateEmptyWindow("DiveTrackerInterface", "UIParent")
    ifaceWindow:SetExtent(180, 30)
    ifaceWindow:AddAnchor("BOTTOM", "UIParent", 0, -225)
    ifaceWindow:EnableDrag(true)
    function ifaceWindow:OnDragStart() self:StartMoving() end
    ifaceWindow:SetHandler("OnDragStart", ifaceWindow.OnDragStart)
    function ifaceWindow:OnDragStop()
        self:StopMovingOrSizing()
        SaveIfacePosition()
    end
    ifaceWindow:SetHandler("OnDragStop", ifaceWindow.OnDragStop)

    local bg = ifaceWindow:CreateColorDrawable(0, 0, 0, 0.5, "background")
    bg:AddAnchor("TOPLEFT", ifaceWindow, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", ifaceWindow, 0, 0)

    -- Drag grip on the left: lighter strip with three vertical lines. It is
    -- drawn on the window itself, so grabbing it drags the window.
    local grip = ifaceWindow:CreateColorDrawable(1, 1, 1, 0.22, "background")
    grip:AddAnchor("TOPLEFT", ifaceWindow, 0, 0)
    grip:AddAnchor("BOTTOMRIGHT", ifaceWindow, 16 - 180, 0)
    for i = -1, 1 do
        local x = 8 + i * 3
        local line = ifaceWindow:CreateColorDrawable(1, 1, 1, 0.75, "background")
        line:AddAnchor("TOPLEFT", ifaceWindow, x, 8)
        line:AddAnchor("BOTTOMRIGHT", ifaceWindow, x + 1 - 180, -8)
    end

    local box = ifaceWindow:CreateChildWidget("window", "ifaceChkBox", 0, true)
    box:SetExtent(14, 14)
    box:AddAnchor("LEFT", ifaceWindow, "LEFT", 24, 0)
    local border = box:CreateColorDrawable(1, 1, 1, 0.8, "background")
    border:AddAnchor("TOPLEFT", box, 0, 0)
    border:AddAnchor("BOTTOMRIGHT", box, 0, 0)
    local inner = box:CreateColorDrawable(0, 0, 0, 0.8, "background")
    inner:AddAnchor("TOPLEFT", box, 1, 1)
    inner:AddAnchor("BOTTOMRIGHT", box, -1, -1)

    local tick = box:CreateChildWidget("window", "ifaceChkTick", 0, true)
    tick:AddAnchor("TOPLEFT", box, 3, 3)
    tick:AddAnchor("BOTTOMRIGHT", box, -3, -3)
    local tickBg = tick:CreateColorDrawable(0.3, 0.9, 0.4, 1, "background")
    tickBg:AddAnchor("TOPLEFT", tick, 0, 0)
    tickBg:AddAnchor("BOTTOMRIGHT", tick, 0, 0)
    tick:Show(interfaceEnabled)

    local label = ifaceWindow:CreateChildWidget("label", "ifaceChkLabel", 0, true)
    label:SetText("Free Dive")
    label.style:SetAlign(ALIGN.LEFT)
    if FONT_SIZE and FONT_SIZE.SMALL then label.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(label, FONT_COLOR.WHITE)
    label:AddAnchor("LEFT", box, "RIGHT", 4, 0)

    local hit = ifaceWindow:CreateChildWidget("button", "ifaceChkHit", 0, true)
    hit:SetExtent(138, 14)
    hit:AddAnchor("LEFT", ifaceWindow, "LEFT", 24, 0)
    function hit:OnClick()
        interfaceEnabled = not interfaceEnabled
        tick:Show(interfaceEnabled)
        SaveSettings()
        pcall(UpdateBar)   -- react at once instead of waiting for the next second
    end
    hit:SetHandler("OnClick", hit.OnClick)

    LoadIfacePosition()   -- before Show, same order as the bar
    ifaceWindow:Show(true)
end

-- Other backpack items also carry a lifeSpan (plain expiry timers), so only
-- accept items that are underwater breathing devices: their name says
-- "Breathing Device" and/or their description mentions "underwater".
local function IsBreathingDevice(info)
    if type(info) ~= "table" or type(info.lifeSpan) ~= "number" then return false end
    local name = type(info.name) == "string" and string.lower(info.name) or ""
    local desc = type(info.description) == "string" and string.lower(info.description) or ""
    return string.find(name, "breathing", 1, true) ~= nil
        or string.find(desc, "underwater", 1, true) ~= nil
end

-- Called once a second (throttled in OnUpdateHandler). Reads the backpack
-- slot; if lifeSpan is nil (no breathing device equipped) the bar and the
-- waypoint overlay hide. Otherwise it resizes the fill, updates the labels
-- and detects a tank swap by watching for the item name changing or the
-- remaining time jumping upward, resetting the known capacity either way.
UpdateBar = function()
    if not barWindow then return end

    local ok, info = pcall(function()
        return api.Equipment:GetEquippedItemTooltipInfo(EQUIP_SLOT.BACKPACK)
    end)

    local lifeSpan = nil
    local itemName = nil
    if ok and IsBreathingDevice(info) then
        lifeSpan = info.lifeSpan
        itemName = info.name
    end

    -- No device, but the interface checkbox is on: act as if one were equipped.
    local manual = false
    if lifeSpan == nil and interfaceEnabled then
        manual = true
        lifeSpan = 0
        itemName = MANUAL_NAME
    end

    if lifeSpan == nil then
        SetBarShown(false)
        if overlayWidget then overlayWidget:Show(false) end
        if routeWidget then routeWidget:Show(false) end
        -- Close (not just hide) the chart, so it starts closed with the next device.
        if ClusterMap then
            pcall(ClusterMap.SetAllowed, false)
            pcall(ClusterMap.Hide)
        end
        depleted = false
        warnActive = false
        if warnBar then warnBar:Show(false) end
        knownMaxLifeSpan = nil
        lastLifeSpan = nil
        lastItemName = nil
        return
    end

    -- The game's "back to ~59 s" quirk (see WARN_SECONDS): treat as empty.
    if manual then
        depleted = false
    elseif depleted then
        if itemName ~= lastItemName or lifeSpan > DEPLETED_MAX_SHOWN then
            depleted = false            -- a different / refilled device
        else
            lifeSpan = 0
        end
    elseif lastLifeSpan and lastLifeSpan <= DEPLETED_AT and itemName == lastItemName
        and lifeSpan > lastLifeSpan and lifeSpan <= DEPLETED_MAX_SHOWN then
        depleted = true
        lifeSpan = 0
    end
    warnActive = not manual and (depleted or lifeSpan <= WARN_SECONDS)

    if itemName ~= lastItemName or (lastLifeSpan and lifeSpan > lastLifeSpan) then
        knownMaxLifeSpan = lifeSpan
        -- A different / fresh device: the chart starts closed again. Switching
        -- to or from the manual interface mode keeps it as it is.
        if ClusterMap and not manual and lastItemName ~= MANUAL_NAME then pcall(ClusterMap.Hide) end
    elseif knownMaxLifeSpan == nil then
        knownMaxLifeSpan = lifeSpan
    end
    lastLifeSpan = lifeSpan
    lastItemName = itemName

    SetBarShown(true)
    if overlayWidget then overlayWidget:Show(true) end
    if routeWidget then routeWidget:Show(true) end
    if ClusterMap then pcall(ClusterMap.SetAllowed, true) end

    UpdateBagLabel()

    local pct = 1
    if manual then
        pct = 0
    elseif knownMaxLifeSpan and knownMaxLifeSpan > 0 then
        pct = lifeSpan / knownMaxLifeSpan
        if pct > 1 then pct = 1 end
        if pct < 0 then pct = 0 end
    end

    if fillBar then
        pcall(function()
            fillBar:SetExtent((BAR_WIDTH - FILL_MARGIN * 2) * pct, FILL_HEIGHT)
        end)
    end

    if timeLabel then
        pcall(function() timeLabel:SetText("Air Left: " .. FormatMinSec(lifeSpan)) end)
    end

    if speedLabel then
        local okSpeed, unitInfo = pcall(function() return api.Unit:UnitInfo("player") end)
        local speed = (okSpeed and type(unitInfo) == "table") and unitInfo.move_speed or nil
        if speed then
            pcall(function() speedLabel:SetText(string.format("Speed: %.1f m/s", speed)) end)
        end
    end

    -- Heading from the movement between two consecutive readings.
    prevCoords = currCoords
    currCoords = api.Map:GetPlayerSextants()
    local newHeading = calculateHeading(currCoords, prevCoords)
    if newHeading then
        heading = newHeading
        headingKnown = true
    end

    if depthLabel then
        local _, _, z = api.Unit:UnitWorldPosition("player")
        if z then
            depthLabel:SetText(string.format("Depth: %d m", math.floor(100 - z)))
        end
    end
end

-- ======
-- Update loop / load / unload
-- ======

-- ======
-- Chart feed (cluster_map.lua)
-- ======

local chartList, chartSrc, chartCount = {}, nil, -1

-- { {gx=, gy=}, ... } for every waypoint; rebuilt only when the list changes.
local function ChartWaypoints()
    if waypoints ~= chartSrc or #waypoints ~= chartCount then
        chartSrc, chartCount = waypoints, #waypoints
        chartList = {}
        for _, wp in ipairs(waypoints) do
            local gx, gy = WaypointGlobal(wp)
            chartList[#chartList + 1] = { gx = gx, gy = gy }
        end
    end
    return chartList
end

-- Player position in global metres, nil while the zone offset is unsettled.
local function ChartPlayer()
    if geoOffX == nil or not geoSettled then return nil end
    local px, py = api.Unit:UnitWorldPosition("player")
    if not px then return nil end
    return px + geoOffX, py + geoOffY
end

-- Direction of travel for the chart's view cone; nil until you have moved.
local function ChartHeading()
    if not headingKnown then return nil end
    return heading
end

local chartErrLogged = false

-- Blinks the red strip while the breathing alarm is active (runs every frame).
local function UpdateWarnFlash(dt)
    if not warnBar then return end
    if not warnActive then
        warnAcc = 0
        warnBar:Show(false)
        return
    end
    warnAcc = (warnAcc + (dt or 16.6)) % (FLASH_MS * 2)
    warnBar:Show(warnAcc < FLASH_MS)
end

local geoErrLogged = false
local guideErrLogged = false
local updateErrorLogged = false
local updateAccumulatorMs = 0

local function OnUpdateHandler(dt)
    local visualHeading = getSmoothHeading(heading)
    UpdateCompass(visualHeading)

    local gok, gerr = pcall(GeoFrame)
    if not gok and not geoErrLogged then
        geoErrLogged = true
        api.Log:Err("[DiveTracker] Geo/overlay error (further occurrences suppressed): " .. tostring(gerr))
    end

    pcall(UpdateWarnFlash, dt)

    local mok, merr = pcall(UpdateGuideMarker, visualHeading)
    if not mok and not guideErrLogged then
        guideErrLogged = true
        api.Log:Err("[DiveTracker] Guide marker error (further occurrences suppressed): " .. tostring(merr))
    end

    if ClusterMap then
        local cok, cerr = pcall(ClusterMap.Update, dt)
        if not cok and not chartErrLogged then
            chartErrLogged = true
            api.Log:Err("[DiveTracker] Chart error (further occurrences suppressed): " .. tostring(cerr))
        end
    end

    -- The bar itself only needs refreshing once a second.
    updateAccumulatorMs = updateAccumulatorMs + (dt or 16.6)
    if updateAccumulatorMs < 1000 then return end
    updateAccumulatorMs = updateAccumulatorMs % 1000

    local ok, err = pcall(UpdateBar)
    if not ok and not updateErrorLogged then
        updateErrorLogged = true
        api.Log:Err("[DiveTracker] Bar update error (further occurrences suppressed): " .. tostring(err))
    end
end

local function OnLoad()
    LoadSettings()
    UseTypeMarks()
    LoadRecoveryCount()
    BuildBar()
    BuildInterfaceWindow()
    BuildEventWindow()
    UpdateRecoveriesLabel()
    UpdateBagLabel()
    LoadWaypoints()
    BuildOverlay()
    BuildRouteLines()
    if ClusterMap then
        local iok, ierr = pcall(ClusterMap.Init, { getWaypoints = ChartWaypoints, getPlayer = ChartPlayer, getHeading = ChartHeading })
        if not iok then api.Log:Err("[DiveTracker] Chart init failed: " .. tostring(ierr)) end
    end
    api.On("UPDATE", OnUpdateHandler)
end

local function OnUnload()
    SetBarShown(false)
    barWindow = nil
    handleWindow = nil
    if ifaceWindow then
        ifaceWindow:Show(false)
        ifaceWindow = nil
    end
    if eventWindow then
        eventWindow:Show(false)
        eventWindow = nil
    end
    if overlayWidget then
        overlayWidget:Show(false)
        overlayWidget = nil
    end
    if routeWidget then
        routeWidget:Show(false)
        routeWidget = nil
    end
    if ClusterMap then pcall(ClusterMap.Unload) end
    api.Log:Info("[DiveTracker] Unloaded.")
end

DiveTracker.OnLoad = OnLoad
DiveTracker.OnUnload = OnUnload

return DiveTracker