-- Run with a local QEMU VNC server: luajit tests/plugin/test_qemu.lua [port]
local socket, ffi = require('socket'), require('ffi')
package.preload['ffi/blitbuffer'] = function()
    return {TYPE_BBRGB32=1, COLOR_BLACK=0, new=function(w,h)
        local buf=ffi.new('uint8_t[?]',w*h*4)
        -- Mark the mock buffer non-black so an initial black QEMU frame is
        -- observable as a change too; the real Blitbuffer handles black itself.
        return {data=buf, stride=w*4, storage=buf,
            fill=function(self) ffi.fill(self.data, w*h*4, 0xff) end, free=function() end}
    end}
end
local RFB = dofile('plugin/android.koplugin/rfb.lua')
local r = RFB:new(); assert(r:connect('127.0.0.1', tonumber(arg[1]) or 5949))
local start, dirty, input, maxpoll = socket.gettime(), nil, false, 0
while socket.gettime()-start < 10 do
    local t = socket.gettime(); local rect = r:poll()
    maxpoll = math.max(maxpoll, socket.gettime()-t)
    if rect then dirty=rect end
    if r.ready and not input then
        r:pointer(1, 0, 0); r:pointer(0, 0, 0); r:key(0xff1b, true); r:key(0xff1b, false)
        input=true
    end
    if dirty and input and r.txbytes == 0 then break end
    socket.sleep(0.001)
end
assert(r.ready, 'QEMU RFB handshake timed out')
assert(dirty, 'QEMU produced no initial framebuffer')
print(string.format('PASS: QEMU RFB %dx%d, dirty %s, max poll %.3f ms', r.w, r.h, table.concat(dirty,','), maxpoll*1000))
r:close()
