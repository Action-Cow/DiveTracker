-- DiveTracker chart, part 2: small widget helpers shared by the chart files.

local api = require("api")

local UI = {}

-- Non-interactive widgets must not swallow clicks / drags meant for the window.
function UI.NoClick(w)
    pcall(function() w:Clickable(false) end)
end

-- Same look as the DiveTracker bar: a see-through black rectangle, white text.
function UI.StyleButton(btn, text, width)
    btn:SetText(text)
    btn:SetExtent(width or (#text * 7 + 14), 20)
    local bg = btn:CreateColorDrawable(0, 0, 0, 0.6, "background")
    bg:AddAnchor("TOPLEFT", btn, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", btn, 0, 0)
    pcall(function() btn.style:SetAlign(ALIGN.CENTER) end)
    pcall(function() ApplyTextColor(btn, FONT_COLOR.WHITE) end)
    pcall(function() btn.style:SetColor(1, 1, 1, 1) end)
    pcall(function()
        btn:SetHandler("OnEnter", function() pcall(function() bg:SetColor(0.25, 0.25, 0.25, 0.75) end) end)
        btn:SetHandler("OnLeave", function() pcall(function() bg:SetColor(0, 0, 0, 0.6) end) end)
    end)
    return bg
end

function UI.MakeSolid(parent, id, r, g, b, a)
    local w = parent:CreateChildWidget("window", id, 0, true)
    UI.NoClick(w)
    local bg = w:CreateColorDrawable(r, g, b, a, "background")
    bg:AddAnchor("TOPLEFT", w, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", w, 0, 0)
    return w
end

function UI.Place(w, parent, x, y, ww, hh)
    w:SetExtent(ww, hh)
    w:RemoveAllAnchors()
    w:AddAnchor("TOPLEFT", parent, x, y)
end

function UI.MakeLabel(parent, id, align)
    local l = parent:CreateChildWidget("label", id, 0, true)
    l:SetText("")
    l.style:SetAlign(align)
    if FONT_SIZE and FONT_SIZE.SMALL then l.style:SetFontSize(FONT_SIZE.SMALL) end
    ApplyTextColor(l, FONT_COLOR.WHITE)
    UI.NoClick(l)
    return l
end

function UI.PoolGet(pool, i, make)
    local item = pool[i]
    if not item then
        item = make(i)
        pool[i] = item
    end
    return item
end

function UI.PoolHideFrom(pool, from)
    for i = from, #pool do
        pool[i]:Show(false)
        if pool[i].box then pool[i].box:Show(false) end
    end
end

-- Label on a black see-through box so it stays readable over dots and lines.
-- The box is created first, so the label draws on top of it.
function UI.MakeBoxedLabel(parent, id, align)
    local box = UI.MakeSolid(parent, id .. "Box", 0, 0, 0, 0.78)
    box:Show(false)
    local l = UI.MakeLabel(parent, id, align)
    l.box = box
    return l
end

-- Places a boxed label with its top-left at (x, y), or centred on x. It is
-- kept inside maxW x maxH (children are not clipped, so it must not stick out).
function UI.PlaceBoxedLabel(l, parent, text, x, y, centered, maxW, maxH)
    local w = math.floor(#text * 6.5 + 8)
    local lx = centered and (x - w / 2) or x
    if lx > maxW - w then lx = maxW - w end
    if lx < 0 then lx = 0 end
    if y > maxH - 14 then y = maxH - 14 end
    if y < 0 then y = 0 end
    l:SetText(text)
    l:SetExtent(w, 14)
    l:RemoveAllAnchors()
    l:AddAnchor("TOPLEFT", parent, lx, y)
    UI.Place(l.box, parent, lx, y, w, 14)
    l.box:Show(true)
    l:Show(true)
end

return UI
