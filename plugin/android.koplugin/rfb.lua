-- Minimaler RFB-(VNC)-Client: Security "None", Raw-Encoding, 32bpp RGBX.
local socket = require("socket")
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")

local RFB = {}
RFB.__index = RFB

local function be16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function be32(s, i) local a, b, c, d = s:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
local function p16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

function RFB:new() return setmetatable({}, RFB) end

-- Liest exakt n Bytes (Timeout am Socket ist klein, wir versuchen mehrfach).
function RFB:read(n)
    if n == 0 then return "" end
    local parts, got, idle = {}, 0, 0
    while got < n do
        local d, err, part = self.sock:receive(n - got)
        local chunk = d or part
        if chunk and #chunk > 0 then
            parts[#parts + 1] = chunk; got = got + #chunk; idle = 0
        elseif err == "timeout" then
            idle = idle + 1
            if idle > 8 then return nil, "timeout" end
        else
            return nil, err or "closed"
        end
        if not d and err ~= "timeout" then return nil, err end
    end
    return table.concat(parts)
end

function RFB:connect(host, port, timeout)
    local s = socket.tcp()
    s:settimeout(timeout or 0.5)
    local ok, err = s:connect(host, port)
    if not ok then s:close(); return nil, err end
    self.sock = s
    local function fail(e) self:close(); return nil, e end

    if not self:read(12) then return fail("keine RFB-Version") end
    s:send("RFB 003.008\n")
    local n = self:read(1); if not n then return fail("sec") end
    n = n:byte()
    if n == 0 then return fail("Server lehnt ab") end
    local types = self:read(n)
    if not types or not types:find("\1", 1, true) then return fail("kein Auth 'None'") end
    s:send("\1")
    local res = self:read(4)
    if not res or be32(res, 1) ~= 0 then return fail("Auth fehlgeschlagen") end
    s:send("\1") -- ClientInit: shared
    local init = self:read(24); if not init then return fail("ServerInit") end
    self.w, self.h = be16(init, 1), be16(init, 3)
    self:read(be32(init, 21)) -- Desktop-Name

    -- 32bpp, little endian, Bytereihenfolge im Speicher: R G B X
    s:send("\0\0\0\0" .. string.char(32, 24, 0, 1) .. p16(255) .. p16(255) .. p16(255)
        .. string.char(0, 8, 16) .. "\0\0\0")
    s:send("\2\0" .. p16(1) .. "\0\0\0\0") -- SetEncodings: nur Raw

    self.bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BBRGB32)
    self.bb:fill(Blitbuffer.COLOR_BLACK)
    self:request(false)
    return true
end

function RFB:request(incremental)
    self.sock:send("\3" .. (incremental and "\1" or "\0") .. p16(0) .. p16(0) .. p16(self.w) .. p16(self.h))
end

function RFB:pointer(mask, x, y)
    x = math.max(0, math.min(self.w - 1, x)); y = math.max(0, math.min(self.h - 1, y))
    self.sock:send("\5" .. string.char(mask) .. p16(x) .. p16(y))
end

function RFB:key(keysym, down)
    self.sock:send("\4" .. string.char(down and 1 or 0) .. "\0\0" ..
        p16(math.floor(keysym / 65536)) .. p16(keysym % 65536))
end

-- Kopiert das Rechteck 1:1 in den Gast-Puffer. Kein Alpha-Loop mehr (das setzt main.lua beim Skalieren),
-- bei Vollbreite genuegt ein einziges ffi.copy.
local function blit_raw(self, x, y, w, h, data)
    if x + w > self.w or y + h > self.h or #data < w * h * 4 then error("Rechteck ausserhalb des Puffers") end
    local base = ffi.cast("uint8_t*", self.bb.data)
    local stride = self.bb.stride
    local src = ffi.cast("const uint8_t*", data)
    if x == 0 and w == self.w and stride == w * 4 then
        ffi.copy(base + y * stride, src, w * h * 4)
    else
        for r = 0, h - 1 do ffi.copy(base + (y + r) * stride + x * 4, src + r * w * 4, w * 4) end
    end
end

-- Verarbeitet eine anstehende Servernachricht. Liefert dirty-Rechteck {x,y,w,h} oder nil.
function RFB:poll()
    local r = socket.select({ self.sock }, nil, 0)
    if not r or #r == 0 then return nil end
    local t = self:read(1)
    if not t then error("Verbindung verloren") end
    t = t:byte()
    local dirty
    if t == 0 then
        local hdr = self:read(3); local nrects = be16(hdr, 2)
        for _ = 1, nrects do
            local rh = self:read(12)
            local x, y, w, h, enc = be16(rh, 1), be16(rh, 3), be16(rh, 5), be16(rh, 7), be32(rh, 9)
            if enc ~= 0 then error("Encoding " .. enc .. " nicht unterstützt") end
            local data = self:read(w * h * 4)
            if not data then error("Rechteck unvollständig") end
            blit_raw(self, x, y, w, h, data)
            if dirty then
                local x2 = math.max(dirty[1] + dirty[3], x + w)
                local y2 = math.max(dirty[2] + dirty[4], y + h)
                dirty[1], dirty[2] = math.min(dirty[1], x), math.min(dirty[2], y)
                dirty[3], dirty[4] = x2 - dirty[1], y2 - dirty[2]
            else
                dirty = { x, y, w, h }
            end
        end
        self:request(true)
    elseif t == 1 then
        local h = self:read(5); self:read(be16(h, 4) * 6)
    elseif t == 3 then
        local h = self:read(7); self:read(be32(h, 4))
    end
    return dirty
end

function RFB:close()
    if self.sock then self.sock:close(); self.sock = nil end
    if self.bb then self.bb:free(); self.bb = nil end
end

return RFB
