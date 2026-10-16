local N=require("wtop.native")
local J=require("wtop.format.json")
local cache=assert(os.getenv("WTOP_LEVELZERO_CACHE_IMAGE"))
local expected=assert(os.getenv("WTOP_LEVELZERO_EXPECT_IMAGE"))
local function read(path)local f=assert(io.open(path,"rb"));local b=f:read("a");f:close();return b end
local original=read(expected)
local first,second=assert(N.gpu_worker_open("levelzero")),assert(N.gpu_worker_open("levelzero"))
assert(N.gpu_worker_query(first,true)==nil);assert(N.gpu_worker_query(second,true)==nil)
local function wait(session)
    local deadline=N.monotonic_ns()+5e9
    repeat
        local data,reason=N.gpu_worker_query(session,true)
        if data then return data end
        assert(reason=="levelzero_query_pending" or reason=="levelzero_worker_busy",reason)
        N.sleep_ms(5)
    until N.monotonic_ns()>deadline
    error("reader did not return")
end
local a,b=wait(first),wait(second)
assert(a.worker_pid~=b.worker_pid and a.worker_pid~=N.pid() and b.worker_pid~=N.pid())
assert(read(cache)==original,"cached image differs from embedded reader")
local writable=io.open(cache,"r+b")
if writable then writable:close();error("running reader image permits writes") end
local third=assert(N.gpu_worker_open("levelzero"))
local value,reason=N.gpu_worker_query(third,true)
assert(value==nil and reason=="levelzero_worker_busy")
N.gpu_worker_close(third,0);N.gpu_worker_close(first,0);N.gpu_worker_close(second,0)
local file;local deadline=N.monotonic_ns()+3e9
repeat
    file=io.open(cache,"r+b")
    if file then break end
    N.sleep_ms(5)
until N.monotonic_ns()>deadline
assert(file,"reader image remained pinned after close")
-- Change the DOS stub while leaving a valid PE header and image. Rejection
-- must come from the byte guard, not the OS rejecting an invalid executable.
assert(file:seek("set",64));file:write(string.char((original:byte(65)+1)%256));file:close()
local bad=assert(N.gpu_worker_open("levelzero"));deadline=N.monotonic_ns()+3e9
repeat
    value,reason=N.gpu_worker_query(bad,true)
    assert(value==nil,"a modified cached reader executed")
    if reason~="levelzero_query_pending" then break end
    N.sleep_ms(5)
until N.monotonic_ns()>deadline
assert(reason=="levelzero_worker_unavailable",reason)
N.gpu_worker_close(bad,0)
file=assert(io.open(cache,"wb"));file:write(original);file:close()
local restored=assert(N.gpu_worker_open("levelzero"));local recovered=wait(restored)
assert(recovered.devices[1].power_limit_watts==40)
N.gpu_worker_close(restored,0)
print(J.encode({concurrent_readers=2,distinct_pids=true,image_bytes=#original,
    image_exact=true,pinned_against_writes=true,quota_enforced=true,corruption_rejected=true,restoration_succeeded=true}))
