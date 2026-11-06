-- RFB 3.8 client for QEMU: None security, Raw RGBX. All socket I/O is nonblocking,
-- including the handshake. poll() has soft wall-clock and hard byte/operation budgets.
local socket = require("socket")
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
ffi.cdef[[int memcmp(const void *s1, const void *s2, size_t n);]]

local RFB = {}
RFB.__index = RFB
local function be16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end
local function be32(s, i) local a, b, c, d = s:byte(i, i + 3); return ((a * 256 + b) * 256 + c) * 256 + d end
local function p16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function p32(n) return p16(math.floor(n / 65536)) .. p16(n % 65536) end
local EXT_KEY_ENCODING = 4294967038 -- -258, QEMU extended key events
local MAX_QUEUE = 65536
local MAX_PIXELS = 4096 * 4096
local MAX_STRING = 1024 * 1024
local CHUNK = 16384

function RFB:new()
    return setmetatable({ tx = {}, txhead = 1, txbytes = 0, input = "", state = "new" }, RFB)
end

function RFB:enqueue(data, kind, mask)
    -- Only replace an entirely unsent move at the tail. Never replace a press,
    -- release, key, handshake message, or any partially sent message.
    local tail = self.tx[#self.tx]
    if kind == "move" and tail and tail.kind == "move" and tail.mask == mask and tail.pos == 1 then
        self.txbytes = self.txbytes - #tail.data + #data
        tail.data = data
        return
    end
    if self.txbytes + #data > MAX_QUEUE then error("RFB-Ausgangswarteschlange voll") end
    self.tx[#self.tx + 1] = { data = data, pos = 1, kind = kind, mask = mask }
    self.txbytes = self.txbytes + #data
end

function RFB:flush(deadline, maxbytes)
    local sent, ops = 0, 0
    while self.txhead <= #self.tx and sent < maxbytes and ops < 32 and socket.gettime() < deadline do
        local msg = self.tx[self.txhead]
        local last = math.min(#msg.data, msg.pos + maxbytes - sent - 1)
        local n, err, partial = self.sock:send(msg.data, msg.pos, last)
        local upto = n or partial or (msg.pos - 1)
        if upto < msg.pos - 1 or upto > last then error("ungueltiger RFB-send-Offset") end
        local count = upto - msg.pos + 1
        msg.pos = upto + 1
        self.txbytes = self.txbytes - count
        sent, ops = sent + count, ops + 1
        if msg.pos > #msg.data then
            self.tx[self.txhead] = false
            self.txhead = self.txhead + 1
        end
        if err and err ~= "timeout" then error("RFB-Senden: " .. tostring(err)) end
        if err == "timeout" or count == 0 then break end
    end
    if self.txhead > #self.tx then self.tx, self.txhead = {}, 1 end
end

function RFB:connect(host, port)
    local s, err = socket.tcp()
    if not s then return nil, err end
    s:settimeout(0)
    self.sock = s
    local ok
    ok, err = s:connect(host, port)
    if not ok and err ~= "timeout" and err ~= "Operation already in progress" then
        self:close(); return nil, err
    end
    self.state = ok and "version" or "connecting"
    pcall(function() s:setoption("tcp-nodelay", true) end)
    return true
end

function RFB:request(incremental)
    self:enqueue("\3" .. (incremental and "\1" or "\0") .. p16(0) .. p16(0) .. p16(self.w) .. p16(self.h))
end

function RFB:pointer(mask, x, y)
    x = math.max(0, math.min(self.w - 1, math.floor(x)))
    y = math.max(0, math.min(self.h - 1, math.floor(y)))
    local kind = mask == self.last_mask and mask ~= 0 and "move" or "pointer"
    self.last_mask = mask
    self:enqueue("\5" .. string.char(mask) .. p16(x) .. p16(y), kind, mask)
    self:flush(socket.gettime() + 0.002, 4096)
end

function RFB:key(keysym, down)
    -- QEMU's standard RFB KeyEvent truncates keysyms to 16 bits, so XF86Back
    -- and XF86HomePage cannot reach the guest that way. QEMU's extended event
    -- carries the PC/QEMU keycode directly (AC_BACK 0xea, AC_HOME 0xb2).
    local qcode = keysym == 0x1008ff26 and 0xea or keysym == 0x1008ff18 and 0xb2
    if qcode then
        self:enqueue("\255\0" .. p16(down and 1 or 0) .. p32(keysym) .. p32(qcode), "key")
    else
        self:enqueue("\4" .. string.char(down and 1 or 0) .. "\0\0" .. p32(keysym), "key")
    end
    self:flush(socket.gettime() + 0.002, 4096)
end

local function union(a, x, y, w, h)
    if not a then return { x, y, w, h } end
    local x2, y2 = math.max(a[1] + a[3], x + w), math.max(a[2] + a[4], y + h)
    a[1], a[2] = math.min(a[1], x), math.min(a[2], y)
    a[3], a[4] = x2 - a[1], y2 - a[2]
    return a
end

function RFB:take(n)
    if #self.input < n then return nil end
    local result = self.input:sub(1, n)
    self.input = self.input:sub(n + 1)
    return result
end

-- Copy arbitrary TCP fragments directly into the framebuffer, including fragments
-- ending in the middle of a pixel or a scanline. No rectangle-sized Lua string.
function RFB:raw(data)
    local r = self.rect
    local source = ffi.cast("const uint8_t*", data)
    local base = ffi.cast("uint8_t*", self.bb.data)
    local rowbytes, i = r.w * 4, 0
    while i < #data do
        local y = math.floor(r.offset / rowbytes)
        local col = r.offset % rowbytes
        local count = math.min(#data - i, rowbytes - col)
        local dest = base + (r.y + y) * self.bb.stride + r.x * 4 + col
        if ffi.C.memcmp(dest, source + i, count) ~= 0 then
            r.changed = true
            ffi.copy(dest, source + i, count)
        end
        r.offset, i = r.offset + count, i + count
    end
end

function RFB:finish_rect()
    local r = self.rect
    if r.changed then self.dirty = union(self.dirty, r.x, r.y, r.w, r.h) end
    self.rect = nil
    self.rects = self.rects - 1
    if self.rects == 0 then
        self:request(true)
        self.state = "message"
    else
        self.state = "rect_header"
    end
end

-- One parser transition. Handshake and messages can split at every byte boundary.
function RFB:parse()
    local state, d = self.state
    if state == "version" then
        d = self:take(12); if not d then return false end
        if d ~= "RFB 003.008\n" then error("Nur RFB 3.8 wird unterstuetzt: " .. tostring(d)) end
        self:enqueue(d); self.state = "security_count"
    elseif state == "security_count" then
        d = self:take(1); if not d then return false end
        self.security_count = d:byte()
        if self.security_count == 0 then error("RFB-Server lehnt Verbindung ab") end
        self.state = "security_types"
    elseif state == "security_types" then
        d = self:take(self.security_count); if not d then return false end
        if not d:find("\1", 1, true) then error("RFB-Sicherheitstyp None fehlt") end
        self:enqueue("\1"); self.state = "security_result"
    elseif state == "security_result" then
        d = self:take(4); if not d then return false end
        if be32(d, 1) ~= 0 then error("RFB-Authentifizierung fehlgeschlagen") end
        self:enqueue("\1"); self.state = "server_init"
    elseif state == "server_init" then
        d = self:take(24); if not d then return false end
        self.w, self.h = be16(d, 1), be16(d, 3)
        self.skip = be32(d, 21)
        if self.w == 0 or self.h == 0 or self.w * self.h > MAX_PIXELS or self.skip > MAX_STRING then
            error("Ungueltige RFB-Desktopgroesse oder Desktopname")
        end
        self.state = "server_name"
    elseif state == "server_name" then
        if self.skip > 0 then
            local n = math.min(self.skip, #self.input)
            if n == 0 then return false end
            self:take(n); self.skip = self.skip - n
        else
            self:enqueue("\0\0\0\0" .. string.char(32, 24, 0, 1) .. p16(255) .. p16(255) .. p16(255)
                .. string.char(0, 8, 16) .. "\0\0\0")
            self:enqueue("\2\0" .. p16(2) .. p32(0) .. p32(EXT_KEY_ENCODING))
            self.bb = Blitbuffer.new(self.w, self.h, Blitbuffer.TYPE_BBRGB32)
            self.bb:fill(Blitbuffer.COLOR_BLACK)
            self:request(false)
            self.ready, self.state = true, "message"
        end
    elseif state == "message" then
        d = self:take(1); if not d then return false end
        local t = d:byte()
        if t == 0 then self.state = "update_header"
        elseif t == 1 then self.state = "colormap_header"
        elseif t == 2 then self.state = "message"
        elseif t == 3 then self.state = "cut_header"
        else error("Unbekannte RFB-Servernachricht " .. t) end
    elseif state == "update_header" then
        d = self:take(3); if not d then return false end
        self.rects = be16(d, 2)
        if self.rects == 0 then self:request(true); self.state = "message"
        else self.state = "rect_header" end
    elseif state == "rect_header" then
        d = self:take(12); if not d then return false end
        local x, y, w, h, enc = be16(d, 1), be16(d, 3), be16(d, 5), be16(d, 7), be32(d, 9)
        if x + w > self.w or y + h > self.h then error("RFB-Rechteck ausserhalb des Puffers") end
        self.rect = { x = x, y = y, w = w, h = h, offset = 0, size = w * h * 4 }
        if enc == EXT_KEY_ENCODING then
            self.ext_key = true -- QEMU's acknowledgement has no pixel payload.
            self:finish_rect()
        elseif enc ~= 0 then
            error("RFB-Encoding " .. enc .. " nicht unterstuetzt")
        elseif w == 0 or h == 0 then self:finish_rect() else self.state = "raw" end
    elseif state == "raw" then
        local n = math.min(#self.input, self.rect.size - self.rect.offset, CHUNK)
        if n == 0 then return false end
        self:raw(self:take(n))
        if self.rect.offset == self.rect.size then self:finish_rect() end
    elseif state == "colormap_header" then
        d = self:take(5); if not d then return false end
        self.skip = be16(d, 4) * 6; self.state = "skip"
    elseif state == "cut_header" then
        d = self:take(7); if not d then return false end
        self.skip = be32(d, 4)
        if self.skip > MAX_STRING then error("RFB-Zwischenablage zu gross") end
        self.state = "skip"
    elseif state == "skip" then
        if self.skip == 0 then self.state = "message"
        else
            local n = math.min(self.skip, #self.input)
            if n == 0 then return false end
            self:take(n); self.skip = self.skip - n
        end
    else error("Ungueltiger RFB-Zustand " .. tostring(state)) end
    return true
end

function RFB:poll()
    if not self.sock then error("RFB nicht verbunden") end
    local deadline, budget, ops = socket.gettime() + 0.006, 128 * 1024, 0
    if self.state == "connecting" then
        local _, writable = socket.select(nil, { self.sock }, 0)
        if not writable or #writable == 0 then return nil end
        local peer, err = self.sock:getpeername()
        if not peer then error("RFB-Verbindung: " .. tostring(err)) end
        self.state = "version"
    end
    self:flush(deadline, 4096)
    while budget > 0 and ops < 128 and socket.gettime() < deadline do
        ops = ops + 1
        if not self:parse() then
            if self.read_error then error("RFB-Empfang: " .. tostring(self.read_error)) end
            local d, err, partial = self.sock:receive(math.min(CHUNK, budget))
            local chunk = d or partial or ""
            if #chunk > 0 then
                self.input = self.input .. chunk
                budget = budget - #chunk
            end
            if err and err ~= "timeout" then self.read_error = err end
            if #chunk == 0 then
                if self.read_error then error("RFB-Empfang: " .. tostring(self.read_error)) end
                break
            end
        end
    end
    self:flush(deadline, 4096)
    -- Expose only complete updates; incomplete rectangles cannot trigger a repaint.
    if self.state == "message" and self.dirty then
        local dirty = self.dirty; self.dirty = nil; return dirty
    end
    return nil
end

function RFB:busy()
    return self.txhead <= #self.tx or #self.input > 0 or self.state == "raw" or self.state == "connecting"
end

function RFB:close()
    if self.sock then self.sock:close(); self.sock = nil end
    if self.bb then self.bb:free(); self.bb = nil end
    self.ready = false
end

return RFB
