local root,control,entered,fdinfo=assert(arg[1]),assert(arg[2]),assert(arg[3]),assert(arg[4])
package.path=root.."/src/?.lua;"..root.."/src/?/init.lua;"..package.path
local Native=require("wtop.native")
local GPU=require("wtop.collectors.gpu")
local Worker=require("wtop.collectors.gpu_drm_worker")
local context={clock={now_ns=Native.monotonic_ns,wall_ns=Native.realtime_ns},scan_gpu_processes=false}
local collector=GPU.new({nvml=false,amdsmi=false,levelzero=function()
    return {sample_started_ns=Native.monotonic_ns(),devices={{index=0,pci_bdf="0000:02:00.0",
        name="Independent SDK",power_watts=30,power_limit_watts=60,graphics_clock_hz=300000000}}}
end})
collector._drm_worker=Worker.new()
local function write(path,text) local f=assert(io.open(path,"wb"));assert(f:write(text));assert(f:close()) end
local function settle(seconds,condition)
    local deadline=Native.monotonic_ns()+seconds*1e9
    repeat
        local started=Native.monotonic_ns();local result=collector:sample(context)
        assert(Native.monotonic_ns()-started<250000000,"DRM read blocked foreground")
        if condition(result) then return result end
        assert(Native.monotonic_ns()<deadline,"DRM never settled: "..tostring(result.reason))
        Native.sleep_ms(10)
    until false
end
local fresh=settle(3,function(r) return r.data.providers.drm.status=="ok" end)
local old=fresh.data.by_id["0000:01:00.0"]
assert(old.metrics.utilization_percent==73 and old.metric_observations.utilization_percent.source=="drm")
assert(not fresh.data.process_scan.enabled and fresh.data.process_scan.scanned_processes==0)
local observed=old.observations.drm.observed_at_ns
context.scan_gpu_processes=true
local deep=settle(3,function(r) return r.data.providers.drm.status=="ok" and r.data.process_scan.enabled end)
local card=deep.data.by_id[old.id]
assert(#card.processes.list==1 and card.processes.list[1].pid==100)
assert(card.processes.clients[1].engines.gfx.utilization_percent==nil,"first fdinfo sample invented a rate")
local function counters(ns)
    return "drm-driver: amdgpu\ndrm-client-id: 7\ndrm-pdev: 0000:01:00.0\ndrm-engine-gfx: "..ns.." ns\n"
end
Native.sleep_ms(50);write(fdinfo,counters(150000000))
local measured=settle(3,function(r)
    local d=r.data.by_id[old.id]
    return r.data.providers.drm.status=="ok" and d and d.processes.clients[1]
        and d.processes.clients[1].engines.gfx.utilization_percent~=nil
end)
local client=measured.data.by_id[old.id].processes.clients[1]
local initial=deep.data.by_id[old.id].processes.clients[1]
assert(client.engines.gfx.busy_ns==150000000)
assert(math.abs(client.engines.gfx.utilization_percent-
    math.min(100,50000000*100/(client.observed_at_ns-initial.observed_at_ns)))<1e-9,
    "fdinfo rate used foreground receive/poll time instead of child observation time")
-- Toggle the policy across live IPC without restarting the child or losing
-- the last successful deep counter baseline.
context.scan_gpu_processes=false
settle(3,function(r) return r.data.providers.drm.status=="ok" and not r.data.process_scan.enabled end)
context.scan_gpu_processes=true;Native.sleep_ms(30);write(fdinfo,counters(160000000))
local resumed=settle(3,function(r) return r.data.providers.drm.status=="ok" and r.data.process_scan.enabled end)
assert(resumed.data.by_id[old.id].processes.clients[1].engines.gfx.utilization_percent~=nil)
write(control,"1\n")
local stale=settle(3,function(r) return r.data.providers.drm.retained and not r.defer_publish end)
local retained=stale.data.by_id[old.id]
assert(retained.quality.utilization=="stale" and retained.metrics.utilization_percent==73)
assert(#retained.processes.list==0 and not retained.capabilities.processes)
assert(retained.observations.drm.observed_at_ns>=observed)
local stale_observed=retained.observations.drm.observed_at_ns
local failed=settle(3,function(r) return r.data.providers.drm.reason=="hardware_query_timeout" end)
assert(failed.data.by_id[old.id].observations.drm.observed_at_ns==stale_observed)
assert(failed.data.by_id["0000:02:00.0"].quality.power=="fresh" and failed.capability.available)
local f=assert(io.open(entered,"rb"));local pid=assert(tonumber(f:read("a")));f:close()
local deadline=Native.monotonic_ns()+1e9
while Native.access("/proc/"..pid,"f") do assert(Native.monotonic_ns()<deadline,"DRM child not reaped");Native.sleep_ms(10) end
write(control,"0\n")
local recovered=settle(9,function(r) return r.data.providers.drm.status=="ok" end)
assert(recovered.data.by_id[old.id].observations.drm.observed_at_ns>stale_observed)
assert(recovered.data.by_id[old.id].processes.clients[1].engines.gfx.utilization_percent==nil,
    "new child inherited an old fdinfo baseline")
collector:stop()
print("ok: DRM worker actual IPC, shallow/deep policy, fdinfo baseline, stale timestamp/process invalidation, independent SDK, timeout/reap and recovery")
