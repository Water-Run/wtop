assert(not package.path:find("/tmp/wtop-runner-poison", 1, true))
assert(not package.cpath:find("/tmp/wtop-runner-poison", 1, true))
assert(package.loaded["wtop.runner_isolation_probe"] == nil)
assert(package.preload["wtop.runner_isolation_probe"] == nil)
assert(package.loaded.math == math,
    "the runner must restore baseline modules replaced by a prior fixture")

return true
