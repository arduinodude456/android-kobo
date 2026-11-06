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
-- QEMU en-us: XF86Back -> Linux KEY_BACK (158), XF86HomePage -> KEY_HOMEPAGE (172).
-- KitKat Generic.kl mappt diese auf Android BACK bzw. HOME. Die normalen
-- X11-Escape/Home-Keysyms waeren dagegen ESCAPE bzw. MOVE_HOME.
local KEY_BACK, KEY_HOME = 0x1008ff26, 0x1008ff18

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
        HoldPan     = { GestureRange:new{ ges = "hold_pan", range = r } },
        PanRelease  = { GestureRange:new{ ges = "pan_release", range = r } },
    }
    self.key_events = {
        AndroidBack = { { Device.input.group.PgBack }, event = "AndroidKey", args = KEY_BACK },
        AndroidHome = { { Device.input.group.PgFwd }, event = "AndroidKey", args = KEY_HOME },
    }
    self.idle_count = 0
    self:initScaled()
    self.pollf = function() self:poll() end
    self.idlef = function() self:idleRefresh() end
    self.pending_rect = self.initial_rect
    UIManager:scheduleIn(0.02, self.pollf)
end

function AndroidView:toGuest(pos)
    return math.floor((pos.x - self.dimen.x) * self.rfb.w / self.dimen.w),
           math.floor((pos.y - self.dimen.y) * self.rfb.h / self.dimen.h)
end

function AndroidView:ptr(mask, x, y)
    if self.closed then return end
    local ok, err = pcall(self.rfb.pointer, self.rfb, mask, x, y)
    if not ok then self:fail(tostring(err)); return end
    stats.sent = stats.sent + 1; stats.last = string.format("%d,%d m=%d", x, y, mask)
    self.pointer_down = mask ~= 0
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

local function merge_rect(a, b)
    if not a then return { b[1], b[2], b[3], b[4] } end
    local x2, y2 = math.max(a[1] + a[3], b[1] + b[3]), math.max(a[2] + a[4], b[2] + b[4])
    a[1], a[2] = math.min(a[1], b[1]), math.min(a[2], b[2])
    a[3], a[4] = x2 - a[1], y2 - a[2]
    return a
end

-- Gastrechteck auf Bildschirmkoordinaten abbilden. Der rechenintensive Teil
-- wird anschliessend ueber mehrere UI-Ticks verteilt.
function AndroidView:beginScaled(rect)
    local dw, dh, sw, sh = self.dimen.w, self.dimen.h, self.rfb.w, self.rfb.h
    local dx0 = math.max(0, math.floor(rect[1] * dw / sw) - 1)
    local dy0 = math.max(0, math.floor(rect[2] * dh / sh) - 1)
    local dx1 = math.min(dw, math.ceil((rect[1] + rect[3]) * dw / sw) + 1)
    local dy1 = math.min(dh, math.ceil((rect[2] + rect[4]) * dh / sh) + 1)
    self.scaling = { x0 = dx0, x1 = dx1, y0 = dy0, y1 = dy1, y = dy0 }
end

function AndroidView:scaleSlice()
    local r = self.scaling
    local endy = math.min(r.y1, r.y + 64)
    local deadline = gettime() + 0.005
    local src = ffi.cast("uint32_t*", self.rfb.bb.data)
    local sstride = self.rfb.bb.stride / 4
    local dst = ffi.cast("uint32_t*", self.sbb.data)
    local dstride = self.sbb.stride / 4
    local xmap, ymap = self.xmap, self.ymap
    local bor = bit.bor
    local y = r.y
    while y < endy do
        local srow = src + ymap[y] * sstride
        local drow = dst + y * dstride
        for x = r.x0, r.x1 - 1 do
            drow[x] = bor(srow[xmap[x]], 0xFF000000) -- Alpha = 255
        end
        y = y + 1
        if y % 8 == 0 and gettime() >= deadline then break end
    end
    r.y = y
    if r.y == r.y1 then
        self.scaling = nil
        return { r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0 }
    end
end

function AndroidView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:blitFrom(self.sbb, x, y, 0, 0, self.dimen.w, self.dimen.h)
end

function AndroidView:poll()
    if self.closed then return end
    local ok, rect = pcall(self.rfb.poll, self.rfb)
    if not ok then return self:fail(tostring(rect)) end
    if rect then self.pending_rect = merge_rect(self.pending_rect, rect) end
    if not self.scaling and self.pending_rect then
        self:beginScaled(self.pending_rect)
        self.pending_rect = nil
    end
    if self.scaling then
        local scaled = self:scaleSlice()
        if scaled then self.screen_dirty = merge_rect(self.screen_dirty, scaled) end
    end
    if self.screen_dirty and gettime() - (self.last_refresh or 0) >= 0.2 then
        local r = self.screen_dirty
        self.screen_dirty = nil
        self.last_refresh = gettime()
        local region = Geom:new{ x = self.dimen.x + r[1], y = self.dimen.y + r[2], w = r[3], h = r[4] }
        UIManager:setDirty(self, "fast", region)
        self.idle_dirty = merge_rect(self.idle_dirty, r)
        UIManager:unschedule(self.idlef)
        UIManager:scheduleIn(1.2, self.idlef)
    end
    UIManager:scheduleIn((self.scaling or self.pending_rect or self.screen_dirty or self.rfb:busy()) and 0.01 or 0.06, self.pollf)
end

function AndroidView:idleRefresh()
    if self.closed or not self.idle_dirty then return end
    local r = self.idle_dirty
    self.idle_dirty = nil
    self.idle_count = self.idle_count + 1
    if self.idle_count % 30 == 0 then
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(nil, "partial", Geom:new{ x = self.dimen.x + r[1], y = self.dimen.y + r[2], w = r[3], h = r[4] })
    end
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
    if self.tap_release then UIManager:unschedule(self.tap_release); self.tap_release = nil end
    pcall(self.rfb.close, self.rfb)
    if self.sbb then self.sbb:free(); self.sbb = nil end
    os.execute(SH .. " stop")
    UIManager:close(self, "full")
end

function AndroidView:onTap(_, ges)
    if self.tap_release then
        UIManager:unschedule(self.tap_release)
        self.tap_release()
    end
    local x, y = self:toGuest(ges.pos)
    self:ptr(1, x, y)
    if self.closed then return true end
    local function release()
        self.tap_release = nil
        if not self.closed then self:ptr(0, x, y) end
    end
    self.tap_release = release
    UIManager:scheduleIn(0.08, release)
    return true
end

function AndroidView:onHold(_, ges)
    if self.tap_release then UIManager:unschedule(self.tap_release); self.tap_release() end
    if ges.pos.x < 100 and ges.pos.y < 100 then -- lange drücken oben links = beenden
        UIManager:show(ConfirmBox:new{
            text = _("Android beenden? Noch nicht geschriebene Daten können verloren gehen."),
            ok_callback = function() self:close() end })
        return true
    end
    if ges.pos.x > self.dimen.w - 100 and ges.pos.y < 100 then -- lange drücken oben rechts = Eingabe-Diagnose
        UIManager:show(InfoMessage:new{ text = diag_text() }); return true
    end
    self:ptr(1, self:toGuest(ges.pos)); return true
end
function AndroidView:onHoldRelease(_, ges)
    self.panning = false
    if self.pointer_down then self:ptr(0, self:toGuest(ges.pos)) end
    return true
end

function AndroidView:onPan(_, ges)
    if not self.panning then
        self.panning = true
        if self.tap_release then UIManager:unschedule(self.tap_release); self.tap_release() end
        if not self.pointer_down then
            local sx, sy = ges.pos.x - (ges.relative and ges.relative.x or 0), ges.pos.y - (ges.relative and ges.relative.y or 0)
            self:ptr(1, self:toGuest({ x = sx, y = sy }))
        end
    end
    -- Bewegungsereignisse drosseln (max. ~16/s): sonst staut sich im langsamen Gast eine Ereigniswarteschlange
    local now = gettime()
    if now - (self.last_pan or 0) >= 0.06 then
        self.last_pan = now
        self:ptr(1, self:toGuest(ges.pos))
    end
    return true
end
function AndroidView:onHoldPan(a, ges) return self:onPan(a, ges) end
function AndroidView:onPanRelease(_, ges)
    self.panning = false
    self:ptr(0, self:toGuest(ges.pos)); return true
end

function AndroidView:onAndroidKey(keysym)
    local ok, err = pcall(function() self.rfb:key(keysym, true); self.rfb:key(keysym, false) end)
    if not ok then self:fail(tostring(err)) end
    return true
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
                    if os.execute(SH .. " stop") ~= 0 then
                        return UIManager:show(InfoMessage:new{ text = _("Android konnte nicht beendet werden. Nichts wurde zurückgesetzt.") })
                    end
                    if os.execute(SH .. " reset") == 0 then
                        UIManager:show(InfoMessage:new{ text = _("Zurückgesetzt.") })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Zurücksetzen fehlgeschlagen. Bitte das Log prüfen.") })
                    end
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
    local ready_path = BASE .. "/run/launch-ready"
    -- Ein eigenes Ergebnis pro Aufruf: ein noch auslaufender alter Starter
    -- darf nicht das Ergebnis des neuen Starts ueberschreiben.
    local exit_path = BASE .. "/run/launch-" .. string.format("%.0f", gettime() * 1000000) .. ".exit"
    os.remove(ready_path); os.remove(exit_path)
    -- check kopiert bei der Ersteinrichtung unter Umstaenden ein sehr grosses
    -- Image. Niemals in der KOReader-Hauptschleife synchron darauf warten.
    -- Das Startskript schreibt launch-ready erst NACH Kopie, Hash-Pruefung und
    -- Beenden einer alten Instanz. Bei aelteren Startskripten erledigt dieser
    -- Wrapper das Stoppen und Freigeben vor dem Start selbst.
    local legacy = true
    local starter = io.open(BASE .. "/android-start.sh", "r")
    if starter then
        local content = starter:read("*a") or ""
        starter:close()
        legacy = not content:find("run/launch-ready", 1, true)
    end
    local legacy_ready = legacy and (SH .. " stop >> " .. BASE .. "/run/start.log 2>&1; : > " .. ready_path .. "; ") or ""
    local cmd = "( " .. SH .. " check > " .. BASE .. "/run/check.log 2>&1; rc=$?; " ..
        "if [ \"$rc\" -eq 0 ]; then " .. legacy_ready .. SH .. " start > " .. BASE .. "/run/start.log 2>&1; rc=$?; " ..
        "else cp " .. BASE .. "/run/check.log " .. BASE .. "/run/start.log; fi; " ..
        "echo \"$rc\" > " .. exit_path .. ".tmp; mv " .. exit_path .. ".tmp " .. exit_path .. " ) >/dev/null 2>&1 &"
    os.execute(cmd)
    local msg = InfoMessage:new{ text = _("Android startet …"), timeout = 0 }
    UIManager:show(msg)
    local t0
    local rfb, attempt_at
    local function exists(path)
        local f = io.open(path, "r")
        if not f then return false end
        f:close(); return true
    end
    local function try()
        if exists(exit_path) then
            if rfb then rfb:close() end
            UIManager:close(msg)
            return UIManager:show(InfoMessage:new{ text = _("Android startet nicht:\n") .. tail(BASE .. "/run/start.log", 10) })
        end
        if not t0 then
            if not exists(ready_path) then return UIManager:scheduleIn(0.5, try) end
            t0 = gettime() -- Die erste Kopie darf laenger als das VNC-Timeout dauern.
        end
        if gettime() - t0 > 180 then
            if rfb then rfb:close() end
            UIManager:close(msg)
            os.execute(SH .. " stop")
            return UIManager:show(InfoMessage:new{ text = _("Android startet nicht:\n") .. tail(BASE .. "/run/start.log", 10) })
        end
        if not rfb then
            rfb = RFB:new()
            attempt_at = gettime()
            local ok = rfb:connect("127.0.0.1", 5900)
            if not ok then rfb:close(); rfb = nil; return UIManager:scheduleIn(1.5, try) end
        end
        local ok, rect = pcall(rfb.poll, rfb)
        if not ok or gettime() - attempt_at > 10 then
            rfb:close(); rfb = nil
            return UIManager:scheduleIn(1.5, try)
        end
        if rfb.ready then
            UIManager:close(msg)
            local view = AndroidView:new{ rfb = rfb, initial_rect = rect }
            return UIManager:show(view, "full")
        end
        UIManager:scheduleIn(0.03, try)
    end
    UIManager:scheduleIn(2, try)
end

return Android
