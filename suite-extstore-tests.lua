local KByte <const> = 1000
local MByte <const> = KByte * 1000
local GByte <const> = MByte * 1000

local gbit_per_sec <const> = 124 * MByte

-- TODO: calculate
local KEY_LIMIT <const> = 5000

local test_list = {
    "example",
}

-- 'a' gets passed back into the function t
-- because the perf tests were structured in a ramp structure that edits a
-- between runs. not used for extstore right now but I might enable it again
-- so leaving it in this format.
local tests = {
    example = {
        s = "-m 16000 -o ext_path=/extstore/extstore:30G,ext_threads=8,ext_wbuf_size=32",
        a = { cli = 50, rate = 50000, prefix = "extstore", limit = KEY_LIMIT },
        w = { },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate * 0.9, init = true }, o)
            mcs.add(thr, { func = "perfrun_metaset", clients = o.cli, rate_limit = o.rate * 0.1, init = true }, o)
        end,
    },
}

return {
    tests = tests,
    testset = test_list,
}
