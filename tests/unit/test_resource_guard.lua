local ok, kind, status = os.execute("sh tests/test_resource_guard.sh")
assert(ok == true and kind == "exit" and status == 0,
    string.format("resource guard fixture failed: %s/%s/%s",
        tostring(ok), tostring(kind), tostring(status)))

return true
