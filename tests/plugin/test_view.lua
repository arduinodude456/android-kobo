local ffi, bit = require('ffi'), require('bit')
local now = 100
local function class()
    local base = {}
    function base:extend(t) return setmetatable(t, {__index=self}) end
    function base:new(t) t=t or {}; setmetatable(t,{__index=self}); if t.init then t:init() end; return t end
    return base
end
local scheduled, dirty = {}, {}
local ui = {
    scheduleIn=function(_,delay,fn) scheduled[fn]=delay end,
    unschedule=function(_,fn) scheduled[fn]=nil end,
    setDirty=function(_,widget,mode,region) dirty[#dirty+1]={widget=widget,mode=mode,region=region} end,
    show=function() end, close=function() end,
}
function ui:show(widget) self.shown=widget end
local bb = {TYPE_BBRGB32=1,COLOR_BLACK=0}
function bb.new(w,h)
    local data=ffi.new('uint32_t[?]',w*h)
    return {data=data,stride=w*4,storage=data,fill=function() end,free=function() end}
end
package.loaded.socket = {gettime=function() return now end}
package.loaded['ffi/blitbuffer']=bb
package.loaded['device']={screen={getWidth=function() return 400 end,getHeight=function() return 256 end},input={group={PgBack=1,PgFwd=2}}}
package.loaded['ui/widget/container/inputcontainer']=class()
package.loaded['ui/widget/container/widgetcontainer']=class()
for _,mod in ipairs({'ui/widget/confirmbox','ui/widget/infomessage','ui/geometry','ui/gesturerange'}) do package.loaded[mod]=class() end
package.loaded['ui/uimanager']=ui
package.loaded.logger={warn=function() end}
package.loaded.gettext=function(x) return x end
package.loaded.rfb={}
local Android = dofile('plugin/android.koplugin/main.lua')
local View
for i=1,30 do local n,v=debug.getupvalue(Android.start,i); if n=='AndroidView' then View=v; break end end
assert(View, 'AndroidView upvalue unavailable')
local src=bb.new(200,128)
for i=0,200*128-1 do src.data[i]=0x11223344 end
local events, sent_rect = {}, false
local rfb={w=200,h=128,bb=src, busy=function() return false end,
    poll=function() if not sent_rect then sent_rect=true; return {0,0,200,128} end end,
    pointer=function(_,mask,x,y) events[#events+1]={mask,x,y} end,
    key=function(_,k,d) events[#events+1]={'key',k,d} end,
    close=function() end}
local view=View:new{rfb=rfb}
assert(view.ges_events.HoldPan, 'hold pan not registered')
assert(view.key_events.AndroidBack.args == 0x1008ff26, 'Back must use XF86Back')
assert(view.key_events.AndroidHome.args == 0x1008ff18, 'Home must use XF86HomePage')
view:poll(); assert(view.scaling and view.scaling.y==64, 'scale was not sliced')
view:onTap(nil,{pos={x=180,y=150}})
view:onTap(nil,{pos={x=182,y=150}})
assert(#events==3 and events[1][1]==1 and events[2][1]==0 and events[3][1]==1,'overlapping tap sequence')
local release=view.tap_release; release()
assert(#events==4 and events[4][1]==0,'missing tap release')
for _=1,10 do now=now+0.03; view:poll() end
assert(not view.scaling and #dirty>0 and dirty[1].mode=='fast', 'scale/fast refresh')
assert(tonumber(view.sbb.data[0]) == bit.bor(0x11223344,0xFF000000)%2^32, 'scaled pixel')
view:idleRefresh()
assert(dirty[#dirty].mode=='partial' and dirty[#dirty].region ~= nil, 'idle refresh not regional')
events={}
view:onHold(nil,{pos={x=200,y=150}})
now=now+0.1
view:onHoldPan(nil,{pos={x=210,y=160},relative={x=10,y=10}})
view:onHoldRelease(nil,{pos={x=210,y=160}})
assert(#events==3 and events[1][1]==1 and events[2][1]==1 and events[3][1]==0,'hold-pan input sequence')
assert(events[1][2]==100 and events[1][3]==75,'coordinates')
local original_execute=os.execute
local stop_rc, reset_rc=0, 1
os.execute=function(cmd) return cmd:match(' stop$') and stop_rc or reset_rc end
local items={}; Android:addToMainMenu(items)
local reset=items.android.sub_item_table[2].callback
reset(); ui.shown.ok_callback()
assert(ui.shown.text:find('fehlgeschlagen'), 'failed reset reported success')
reset_rc=0; reset(); ui.shown.ok_callback()
assert(ui.shown.text=='Zurückgesetzt.', 'successful reset not reported')
stop_rc=1; reset(); ui.shown.ok_callback()
assert(ui.shown.text:find('Nichts wurde zurückgesetzt'), 'failed stop ignored')
local commands = {}
os.execute=function(cmd) commands[#commands+1]=cmd; return 0 end
Android:start()
assert(#commands==2 and commands[2]:find(' check ', 1, true) and commands[2]:find(' start ', 1, true)
    and commands[2]:match('&$'), 'start/check must run in background')
assert(commands[2]:find(' stop ',1,true) and commands[2]:find('launch-ready',1,true), 'legacy starter not adapted')
assert(ui.shown.text=='Android startet …', 'startup indicator missing')
local original_open=io.open
io.open=function(path)
    if path:find('/android%-start%.sh$') then
        return {read=function() return ': > run/launch-ready' end,close=function() end}
    end
    return nil
end
commands={}; Android:start()
assert(#commands==2 and not commands[2]:find(' stop ',1,true), 'modern starter incorrectly treated as legacy')
io.open=original_open
local startup_poll
for fn,delay in pairs(scheduled) do if delay==2 then startup_poll=fn end end
assert(startup_poll, 'startup poll not scheduled')
io.open=function(path)
    if path:match('/launch%-%d+%.exit$') then return {close=function() end} end
    return nil
end
startup_poll()
assert(ui.shown.text:find('Android startet nicht',1,true), 'background start failure not shown')
io.open=original_open
os.execute=original_execute
print('PASS: sliced scaling, regional refresh, ordered gestures and asynchronous startup')
