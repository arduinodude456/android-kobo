local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local bit = require("bit")
local ffi = require("ffi")
local gettime = require("socket").gettime
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local RFB = require("rfb")
local Screen = Device.screen

local BASE = "/mnt/onboard/.adds/android"
local SH = "sh " .. BASE .. "/android-start.sh"
local KEY_ESCAPE, KEY_HOME = 0xff1b, 0xff50 -- X11-Keysyms -> Android BACK / HOME

local function tail(path, n)
    local f = io.open(path, "r"); if not f then return "(kein Log)" end
    local lines = {}
    for l in f:lines() do lines[#lines + 1] = l; if #lines > n then table.remove(lines, 1) end end
    f:close(); return table.concat(lines, "\n")
end

local function grep_tail(path, pats, n)
    local f = io.open(path, "r"); if not f then return "(kein Log)" end
    local lines = {}
    for l in f:lines() do
        for _, p in ipairs(pats) do
            if l:find(p, 1, true) then
                lines[#lines + 1] = l:sub(1, 70); if #lines > n then table.remove(lines, 1) end
                break
            end
        end
    end
    f:close(); return table.concat(lines, "\n")
end

local stats = { sent = 0, last = "-" }
local function diag_text()
    local g = grep_tail(BASE .. "/run/console.log", { "INPUTDIAG", "/dev/input/", "BTN_TOUCH", "ABS_" }, 14)
    if g == "" then g = _("(Gast-Diagnose aus; per adb: setprop debug.inputdiag 1; start inputdiag)") end
    return string.format(_("Plugin hat %d Zeigerereignisse gesendet (zuletzt %s)\n\nGast-Eingabe (Konsole):\n"),
        stats.sent, stats.last) .. g
end

-- ===================== Vollbild-Widget =====================
local AndroidView = InputContainer:extend{ covers_fullscreen = true }

function AndroidView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local r = self.dimen
    self.ges_events = {
        Tap         = { GestureRange:new{ ges = "tap", range = r } },
        Hold        = { GestureRange:new{ ges = "hold", range = r } },
        HoldRelease = { GestureRange:new{ ges = "hold_release", range = r } },
        Pan         = { GestureRange:new{ ges = "pan", range = r } },
        PanRelease  = { GestureRange:new{ ges = "pan_release", range = r } },
    }
    self.key_events = {
        AndroidBack = { { Device.input.group.PgBack }, event = "AndroidKey", args = KEY_ESCAPE },
        AndroidHome = { { Device.input.group.PgFwd }, event = "AndroidKey", args = KEY_HOME },
    }
    self.idle_count = 0
    self:initScaled()
    self.pollf = function() self:poll() end
    self.idlef = function() self:idleRefresh() end
    UIManager:scheduleIn(0.1, self.pollf)
end

function AndroidView:toGuest(pos)
    return math.floor((pos.x - self.dimen.x) * self.rfb.w / self.dimen.w),
           math.floor((pos.y - self.dimen.y) * self.rfb.h / self.dimen.h)
end

function AndroidView:ptr(mask, x, y)
    stats.sent = stats.sent + 1; stats.last = string.format("%d,%d m=%d", x, y, mask)
    self.rfb:pointer(mask, x, y)
end

-- Persistenter, bereits skalierter Puffer (Bildschirmgroesse). Es wird nur noch das geaenderte Rechteck
-- neu skaliert (Nearest-Neighbor per Lookup-Tabelle, bei 2x exakt Pixelverdopplung) statt bei JEDEM Update
-- das ganze Bild per RenderImage zu skalieren (das blockierte die KOReader-Hauptschleife und damit Touch).
function AndroidView:initScaled()
    local dw, dh, sw, sh = self.dimen.w, self.dimen.h, self.rfb.w, self.rfb.h
    self.xmap = ffi.new("int32_t[?]", dw)
    for x = 0, dw - 1 do self.xmap[x] = math.min(sw - 1, math.floor((x + 0.5) * sw / dw)) end
    self.ymap = ffi.new("int32_t[?]", dh)
    for y = 0, dh - 1 do self.ymap[y] = math.min(sh - 1, math.floor((y + 0.5) * sh / dh)) end
    self.sbb = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BBRGB32)
    self.sbb:fill(Blitbuffer.COLOR_BLACK)
end

-- rect = Gast-Koordinaten {x,y,w,h}; liefert das betroffene Bildschirmrechteck dx,dy,dw,dh
function AndroidView:updateScaled(rect)
    local dw, dh, sw, sh = self.dimen.w, self.dimen.h, self.rfb.w, self.rfb.h
    local dx0 = math.max(0, math.floor(rect[1] * dw / sw) - 1)
    local dy0 = math.max(0, math.floor(rect[2] * dh / sh) - 1)
    local dx1 = math.min(dw, math.ceil((rect[1] + rect[3]) * dw / sw) + 1)
    local dy1 = math.min(dh, math.ceil((rect[2] + rect[4]) * dh / sh) + 1)
    local src = ffi.cast("uint32_t*", self.rfb.bb.data)
    local sstride = self.rfb.bb.stride / 4
    local dst = ffi.cast("uint32_t*", self.sbb.data)
    local dstride = self.sbb.stride / 4
    local xmap, ymap = self.xmap, self.ymap
    local bor = bit.bor
    for y = dy0, dy1 - 1 do
        local srow = src + ymap[y] * sstride
        local drow = dst + y * dstride
        for x = dx0, dx1 - 1 do
            drow[x] = bor(srow[xmap[x]], 0xFF000000) -- Alpha = 255
        end
    end
    return dx0, dy0, dx1 - dx0, dy1 - dy0
end

function AndroidView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:blitFrom(self.sbb, x, y, 0, 0, self.dimen.w, self.dimen.h)
end

function AndroidView:poll()
    if self.closed then return end
    local ok, rect = pcall(self.rfb.poll, self.rfb)
    if not ok then return self:fail(tostring(rect)) end
    if rect then
        local dx, dy, dw, dh = self:updateScaled(rect)
        local region = Geom:new{ x = self.dimen.x + dx, y = self.dimen.y + dy, w = dw, h = dh }
        UIManager:setDirty(self, "fast", region)
        UIManager:unschedule(self.idlef)
        UIManager:scheduleIn(1.2, self.idlef) -- nach Ruhe: sauberer Farb-Refresh
    end
    -- Nach einem Update mind. 0.2 s Pause: E-Ink schafft nicht mehr, und die Hauptschleife bleibt fuer Touch frei
    UIManager:scheduleIn(rect and 0.2 or 0.12, self.pollf)
end

function AndroidView:idleRefresh()
    self.idle_count = self.idle_count + 1
    UIManager:setDirty(self, (self.idle_count % 30 == 0) and "full" or "partial")
end

function AndroidView:fail(msg)
    logger.warn("android: " .. msg)
    self:close()
    UIManager:show(InfoMessage:new{ text = _("Verbindung zu Android verloren:\n") .. msg .. "\n\n" ..
        tail(BASE .. "/run/start.log", 8) })
end

function AndroidView:close()
    self.closed = true
    UIManager:unschedule(self.pollf); UIManager:unschedule(self.idlef)
    pcall(self.rfb.close, self.rfb)
    if self.sbb then self.sbb:free(); self.sbb = nil end
    os.execute(SH .. " stop")
    UIManager:close(self, "full")
end

function AndroidView:onTap(_, ges)
    local x, y = self:toGuest(ges.pos)
    self:ptr(1, x, y)
    UIManager:scheduleIn(0.08, function() if not self.closed then self:ptr(0, x, y) end end)
    return true
end

function AndroidView:onHold(_, ges)
    if ges.pos.x < 100 and ges.pos.y < 100 then -- lange drücken oben links = beenden
        UIManager:show(ConfirmBox:new{
            text = _("Android beenden? (Zustand wird verworfen)"),
            ok_callback = function() self:close() end })
        return true
    end
    if ges.pos.x > self.dimen.w - 100 and ges.pos.y < 100 then -- lange drücken oben rechts = Eingabe-Diagnose
        UIManager:show(InfoMessage:new{ text = diag_text() }); return true
    end
    self:ptr(1, self:toGuest(ges.pos)); return true
end
function AndroidView:onHoldRelease(_, ges) self:ptr(0, self:toGuest(ges.pos)); return true end

function AndroidView:onPan(_, ges)
    if not self.panning then
        self.panning = true
        local sx, sy = ges.pos.x - (ges.relative and ges.relative.x or 0), ges.pos.y - (ges.relative and ges.relative.y or 0)
        self:ptr(1, self:toGuest({ x = sx, y = sy }))
    end
    -- Bewegungsereignisse drosseln (max. ~16/s): sonst staut sich im langsamen Gast eine Ereigniswarteschlange
    local now = gettime()
    if now - (self.last_pan or 0) >= 0.06 then
        self.last_pan = now
        self:ptr(1, self:toGuest(ges.pos))
    end
    return true
end
function AndroidView:onPanRelease(_, ges)
    self.panning = false
    self:ptr(0, self:toGuest(ges.pos)); return true
end

function AndroidView:onAndroidKey(keysym)
    self.rfb:key(keysym, true); self.rfb:key(keysym, false); return true
end

-- ===================== Plugin =====================
local Android = WidgetContainer:extend{ name = "android", is_doc_only = false }

function Android:init() self.ui.menu:registerToMainMenu(self) end

function Android:addToMainMenu(items)
    items.android = {
        text = _("Android"), sorting_hint = "tools",
        sub_item_table = {
            { text = _("Starten"), callback = function() self:start() end },
            { text = _("Zurücksetzen (Originalzustand)"), callback = function()
                UIManager:show(ConfirmBox:new{ text = _("Alle Android-Daten löschen?"), ok_callback = function()
                    os.execute(SH .. " stop"); os.execute(SH .. " reset")
                    UIManager:show(InfoMessage:new{ text = _("Zurückgesetzt.") })
                end })
            end },
            { text = _("Eingabe-Diagnose"), callback = function() UIManager:show(InfoMessage:new{ text = diag_text() }) end },
            { text = _("Log anzeigen"), callback = function()
                UIManager:show(InfoMessage:new{ text = tail(BASE .. "/run/start.log", 15) }) end },
        },
    }
end

function Android:start()
    os.execute("mkdir -p " .. BASE .. "/run")
    if os.execute(SH .. " check > " .. BASE .. "/run/check.log 2>&1") ~= 0 then
        return UIManager:show(InfoMessage:new{ text = _("Start nicht möglich:\n") .. tail(BASE .. "/run/check.log", 5) })
    end
    os.execute(SH .. " start > " .. BASE .. "/run/start.log 2>&1 &")
    local msg = InfoMessage:new{ text = _("Android startet …"), timeout = 0 }
    UIManager:show(msg)
    local t0 = os.time()
    local function try()
        local rfb = RFB:new()
        local ok = rfb:connect("127.0.0.1", 5900, 0.5)
        if ok then
            UIManager:close(msg)
            local view = AndroidView:new{ rfb = rfb }
            UIManager:show(view, "full")
        else
            rfb:close()
            if os.time() - t0 > 180 then
                UIManager:close(msg)
                os.execute(SH .. " stop")
                UIManager:show(InfoMessage:new{ text = _("Android startet nicht:\n") .. tail(BASE .. "/run/start.log", 10) })
            else
                UIManager:scheduleIn(1.5, try)
            end
        end
    end
    UIManager:scheduleIn(2, try)
end

return Android
