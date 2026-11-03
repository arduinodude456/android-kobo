local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
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
    self.pollf = function() self:poll() end
    self.idlef = function() self:idleRefresh() end
    UIManager:scheduleIn(0.1, self.pollf)
end

function AndroidView:toGuest(pos)
    return math.floor((pos.x - self.dimen.x) * self.rfb.w / self.dimen.w),
           math.floor((pos.y - self.dimen.y) * self.rfb.h / self.dimen.h)
end

function AndroidView:scaled()
    if not self._scaled and self.rfb.bb then
        local ok, s = pcall(RenderImage.scaleBlitBuffer, RenderImage, self.rfb.bb, self.dimen.w, self.dimen.h, false)
        self._scaled = ok and s or self.rfb.bb
    end
    return self._scaled
end

function AndroidView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s = self:scaled()
    if s then bb:blitFrom(s, x, y, 0, 0, math.min(s:getWidth(), self.dimen.w), math.min(s:getHeight(), self.dimen.h)) end
end

function AndroidView:poll()
    if self.closed then return end
    local ok, rect = pcall(self.rfb.poll, self.rfb)
    if not ok then return self:fail(tostring(rect)) end
    if rect then
        if self._scaled and self._scaled ~= self.rfb.bb then self._scaled:free() end
        self._scaled = nil
        local sx, sy = self.dimen.w / self.rfb.w, self.dimen.h / self.rfb.h
        local region = Geom:new{ x = rect[1] * sx, y = rect[2] * sy, w = rect[3] * sx + 1, h = rect[4] * sy + 1 }
        UIManager:setDirty(self, "fast", region)
        UIManager:unschedule(self.idlef)
        UIManager:scheduleIn(1.2, self.idlef) -- nach Ruhe: sauberer Farb-Refresh
    end
    UIManager:scheduleIn(rect and 0.05 or 0.15, self.pollf)
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
    if self._scaled and self._scaled ~= self.rfb.bb then self._scaled:free() end
    self._scaled = nil
    pcall(self.rfb.close, self.rfb)
    os.execute(SH .. " stop")
    UIManager:close(self, "full")
end

function AndroidView:onTap(_, ges)
    local x, y = self:toGuest(ges.pos)
    self.rfb:pointer(1, x, y)
    UIManager:scheduleIn(0.08, function() if not self.closed then self.rfb:pointer(0, x, y) end end)
    return true
end

function AndroidView:onHold(_, ges)
    if ges.pos.x < 100 and ges.pos.y < 100 then -- lange drücken oben links = beenden
        UIManager:show(ConfirmBox:new{
            text = _("Android beenden? (Zustand wird verworfen)"),
            ok_callback = function() self:close() end })
        return true
    end
    self.rfb:pointer(1, self:toGuest(ges.pos)); return true
end
function AndroidView:onHoldRelease(_, ges) self.rfb:pointer(0, self:toGuest(ges.pos)); return true end

function AndroidView:onPan(_, ges)
    if not self.panning then
        self.panning = true
        local sx, sy = ges.pos.x - (ges.relative and ges.relative.x or 0), ges.pos.y - (ges.relative and ges.relative.y or 0)
        self.rfb:pointer(1, self:toGuest({ x = sx, y = sy }))
    end
    self.rfb:pointer(1, self:toGuest(ges.pos)); return true
end
function AndroidView:onPanRelease(_, ges)
    self.panning = false
    self.rfb:pointer(0, self:toGuest(ges.pos)); return true
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
