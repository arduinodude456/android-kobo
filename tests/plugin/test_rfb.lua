local ffi = require('ffi')
local real_socket = require('socket')
local real_time = real_socket.gettime
local fake = {}
local current
fake.gettime = real_time
fake.tcp = function() return current end
fake.select = function() return {}, {current} end
package.loaded.socket = fake
package.preload['ffi/blitbuffer'] = function()
    return {
        TYPE_BBRGB32 = 1, COLOR_BLACK = 0,
        new = function(w, h)
            local stride = w * 4 + 8 -- catches incorrect contiguous-row assumptions
            local buf = ffi.new('uint8_t[?]', stride * h)
            return {data = buf, stride = stride, storage = buf,
                fill = function(self) ffi.fill(self.data, stride * h, 0) end,
                free = function() end}
        end,
    }
end
local RFB = dofile('plugin/android.koplugin/rfb.lua')
local function p16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function p32(n) return p16(math.floor(n / 65536)) .. p16(n % 65536) end
local function eq(a, b, what) assert(a == b, (what or 'mismatch') .. ': ' .. tostring(a) .. ' ~= ' .. tostring(b)) end
local function new_socket()
    return { rx = '', out = '', fragment = 7, maxsend = 100000, reads = 0, rxbytes = 0,
        settimeout = function(self, v) eq(v, 0, 'nonblocking') end,
        setoption = function() return true end,
        connect = function() return 1 end,
        close = function(self) self.closed = true end,
        receive = function(self, n)
            self.reads = self.reads + 1
            if self.failread then return nil, self.failread, '' end
            local count = math.min(n, #self.rx, self.fragment)
            local s = self.rx:sub(1, count)
            self.rx = self.rx:sub(count + 1)
            self.rxbytes = self.rxbytes + count
            if count == n then return s end
            return nil, 'timeout', s
        end,
        send = function(self, data, i, j)
            if self.failwrite then return nil, self.failwrite, i - 1 end
            local count = math.min(j - i + 1, self.maxsend)
            self.out = self.out .. data:sub(i, i + count - 1)
            if count == j - i + 1 then return i + count - 1 end
            return nil, 'timeout', i + count - 1
        end,
    }
end
local function init(w, h, frag)
    current = new_socket(); current.fragment = frag or 7
    local r = RFB:new(); assert(r:connect('127.0.0.1', 5900))
    current.rx = 'RFB 003.008\n' .. '\1\1' .. p32(0) .. p16(w) .. p16(h) .. string.rep('\0', 16) .. p32(4) .. 'test'
    for i = 1, 500 do r:poll(); if r.ready then break end end
    assert(r.ready, 'handshake failed')
    eq(r.w, w); eq(r.h, h)
    for _ = 1, 20 do r:poll() end
    eq(current.out:sub(1, 12), 'RFB 003.008\n', 'version response')
    assert(current.out:find('\3\0' .. p16(0) .. p16(0) .. p16(w) .. p16(h), 1, true), 'initial full request')
    current.out = ''
    return r, current
end
local function rectangle(x, y, w, h, data, enc)
    return p16(x) .. p16(y) .. p16(w) .. p16(h) .. p32(enc or 0) .. (data or '')
end
local function update(rects) return '\0\0' .. p16(#rects) .. table.concat(rects) end
local function poll_until(r, fn, n)
    for i = 1, n or 10000 do local d = r:poll(); if fn(d) then return d, i end end
    error('poll deadline')
end

-- One-byte TCP fragments across handshake, server messages, rectangles and pixels.
do
    local r, s = init(5, 4, 1)
    local a = string.char(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16)
    s.rx = '\2' .. '\1\0' .. p16(0) .. p16(1) .. string.rep('\0', 6) ..
        '\3\0\0\0' .. p32(3) .. 'abc' .. update({rectangle(1, 1, 2, 2, a), rectangle(4, 3, 1, 1, 'ABCD')})
    local d = poll_until(r, function(d) return d ~= nil end)
    eq(table.concat(d, ','), '1,1,4,3', 'dirty union')
    eq(ffi.string(r.bb.data + r.bb.stride + 4, 8), a:sub(1,8), 'first row')
    eq(ffi.string(r.bb.data + 2*r.bb.stride + 4, 8), a:sub(9,16), 'second row')
    eq(ffi.string(r.bb.data + 3*r.bb.stride + 16, 4), 'ABCD', 'second rectangle')
    s.rx = update({rectangle(1, 1, 2, 2, a), rectangle(4, 3, 1, 1, 'ABCD')})
    for _ = 1, 150 do assert(r:poll() == nil, 'unchanged pixels must not repaint') end
    r:close()
end

-- Large frames are processed in multiple bounded polls. Input is transmitted
-- while an update is still incomplete, even with repeated partial sends/timeouts.
do
    local w, h = 632, 840
    local r, s = init(w, h, 16384)
    local payload = string.rep('\x22\x33\x44\x55', w*h)
    s.rx = update({rectangle(0, 0, w, h, payload)})
    local before = s.rxbytes
    local start = real_time(); local d = r:poll(); local elapsed = real_time() - start
    assert(not d and #s.rx > 0, 'large frame must not complete in first poll')
    assert(s.rxbytes - before <= 128*1024, 'read budget exceeded')
    assert(elapsed < 0.1, 'poll blocked in fake socket')
    s.maxsend = 2
    r:pointer(1, 100, 200); r:pointer(0, 100, 200); r:key(0xff1b, true); r:key(0xff1b, false)
    for _ = 1, 40 do local rect = r:poll(); if rect then d = rect end end
    local expected = '\5\1' .. p16(100) .. p16(200) .. '\5\0' .. p16(100) .. p16(200) ..
        '\4\1\0\0' .. p32(0xff1b) .. '\4\0\0\0' .. p32(0xff1b)
    assert(s.out:find(expected, 1, true), 'partial sends lost/reordered down/up')
    if not d then d = poll_until(r, function(rect) return rect ~= nil end, 1000) end
    eq(table.concat(d, ','), '0,0,632,840', 'full dirty region')
    eq(ffi.string(r.bb.data + (h-1)*r.bb.stride + (w-1)*4, 4), '\x22\x33\x44\x55', 'last pixel')
    r:close()
end

-- Coalesce only unsent movements, preserving the original press and release.
do
    local r, s = init(20, 20)
    s.maxsend = 0
    r:pointer(1, 1, 1); r:pointer(1, 2, 2); r:pointer(1, 3, 3); r:pointer(0, 4, 4)
    s.maxsend = 2
    for _ = 1, 100 do r:poll() end
    local expected = '\5\1' .. p16(1) .. p16(1) .. '\5\1' .. p16(3) .. p16(3) .. '\5\0' .. p16(4) .. p16(4)
    eq(s.out, expected, 'movement coalescing')
    r:close()
end

-- QEMU acknowledges the -258 pseudo-encoding without a pixel payload.
-- Back/Home use the extended-key event so their full keycodes reach Android.
do
    local r, s = init(20, 20, 1)
    s.rx = update({rectangle(0, 0, 20, 20, '', 4294967038)})
    for _ = 1, 100 do assert(r:poll() == nil, 'key ack must not repaint') end
    assert(r.ext_key, 'QEMU extended-key ack not parsed')
    s.out, s.maxsend = '', 2
    r:key(0x1008ff26, true); r:key(0x1008ff26, false)
    r:key(0x1008ff18, true); r:key(0x1008ff18, false)
    for _ = 1, 100 do r:poll() end
    local expected = '\255\0'..p16(1)..p32(0x1008ff26)..p32(0xea) ..
        '\255\0'..p16(0)..p32(0x1008ff26)..p32(0xea) ..
        '\255\0'..p16(1)..p32(0x1008ff18)..p32(0xb2) ..
        '\255\0'..p16(0)..p32(0x1008ff18)..p32(0xb2)
    eq(s.out, expected, 'QEMU key event ordering')
    r:close()
end

-- Invalid rectangles, unsupported encodings and closed sockets fail explicitly.
do
    local r, s = init(5, 4)
    s.rx = update({rectangle(4, 3, 2, 2)})
    local ok, err = pcall(function() for _ = 1, 30 do r:poll() end end)
    assert(not ok and tostring(err):find('ausserhalb'), 'out of bounds accepted'); r:close()
    r, s = init(5,4); s.rx = update({rectangle(0, 0, 1, 1, '', 42)})
    ok, err = pcall(function() for _ = 1, 30 do r:poll() end end)
    assert(not ok and tostring(err):find('Encoding'), 'bad encoding accepted'); r:close()
    r, s = init(5,4); s.failread = 'closed'; ok = pcall(r.poll, r)
    assert(not ok, 'closed read accepted'); r:close()
    r, s = init(5,4); s.failwrite = 'closed'; ok = pcall(r.pointer, r, 1, 1, 1)
    assert(not ok, 'closed write accepted'); r:close()
end
print('PASS: nonblocking fragmented RFB handshake/updates, budgets, input ordering, errors')
