local socket = require('socket')
local ffi = require('ffi')
package.preload['ffi/blitbuffer'] = function()
    return { TYPE_BBRGB32 = 1, COLOR_BLACK = 0, new = function(w,h)
        local data = ffi.new('uint8_t[?]', w*h*4)
        return {data=data, stride=w*4, storage=data, fill=function() end, free=function() end}
    end }
end
local RFB = dofile('plugin/android.koplugin/rfb.lua')
local function p16(x) return string.char(math.floor(x/256)%256,x%256) end
local function p32(x) return p16(math.floor(x/65536))..p16(x%65536) end
local listener = assert(socket.bind('127.0.0.1', 0)); listener:settimeout(0)
local _, port = listener:getsockname()
local r = RFB:new(); assert(r:connect('127.0.0.1', port))
local peer, incoming, phase, pending = nil, '', 0, ''
local body = string.char(1,2,3,4, 5,6,7,8, 9,10,11,12, 13,14,15,16)
local update = '\0\0'..p16(1)..p16(0)..p16(0)..p16(2)..p16(2)..p32(0)..body
local input = '\5\1'..p16(1)..p16(1)..'\5\0'..p16(1)..p16(1)
local start = socket.gettime()
local pressed, dirty, withheld = false, nil, false
while socket.gettime() - start < 4 do
    if not peer then
        peer = listener:accept()
        if peer then peer:settimeout(0); pending = 'RFB 003.008\n' end
    end
    local ok, result = pcall(r.poll, r); assert(ok, tostring(result))
    if result then dirty = result end
    if peer then
        if #pending > 0 then
            -- Force fragmentation even for handshake headers.
            local n, err, last = peer:send(pending, 1, math.min(#pending, 3))
            assert(n or err == 'timeout', err)
            pending = pending:sub((n or last or 0) + 1)
        end
        local d, err, partial = peer:receive(4096)
        assert(d or err == 'timeout' or err == 'closed', err)
        incoming = incoming .. (d or partial or '')
        if phase == 0 and #incoming >= 12 then
            assert(incoming:sub(1,12) == 'RFB 003.008\n'); incoming = incoming:sub(13)
            pending = pending .. '\1\1'; phase = 1
        elseif phase == 1 and #incoming >= 1 then
            assert(incoming:sub(1,1) == '\1'); incoming = incoming:sub(2)
            pending = pending .. p32(0); phase = 2
        elseif phase == 2 and #incoming >= 1 then
            assert(incoming:sub(1,1) == '\1'); incoming = incoming:sub(2)
            pending = pending .. p16(2)..p16(2)..string.rep('\0',16)..p32(4)..'test'; phase = 3
        elseif phase == 3 and #incoming >= 42 then
            assert(incoming:byte(1) == 0 and incoming:byte(21) == 2 and incoming:byte(33) == 3)
            assert(incoming:sub(29,32) == p32(4294967038), 'QEMU extended key encoding absent')
            incoming = incoming:sub(43)
            -- Header + half a rectangle; withhold the rest until both input events arrive.
            pending = pending .. update:sub(1, 24); phase = 4
        elseif phase == 4 and #pending == 0 and r.ready and not pressed then
            r:pointer(1,1,1); r:pointer(0,1,1); pressed = true
        elseif phase == 4 and pressed and incoming:find(input, 1, true) then
            assert(not dirty, 'frame completed before intentionally withheld bytes')
            withheld = true; pending = update:sub(25); phase = 5
        elseif phase == 5 and dirty then break end
    end
    socket.sleep(0.0005)
end
assert(withheld, 'input did not traverse the real socket while the frame stalled')
assert(dirty and table.concat(dirty, ',') == '0,0,2,2', 'incomplete frame')
assert(ffi.string(r.bb.data, 16) == body, 'incorrect decoded bytes')
r:close(); if peer then peer:close() end; listener:close()
print('PASS: real TCP handshake, fragmented update and input during stalled frame')
