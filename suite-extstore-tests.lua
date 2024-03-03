local KByte <const> = 1000
local MByte <const> = KByte * 1000
local GByte <const> = MByte * 1000

-- 124 megabytes per second is roughly one gigabit
local gbit_per_sec <const> = 124 * MByte
-- arbitrary "n gigabits per second" warm rate to avoid eviction issues with
-- extstore.
-- requires that we also set sleep rate to 100ms
local warm_write_rate = (gbit_per_sec * 4) / 10

local base_extarg = "-o ext_threads=8,ext_wbuf_size=32"
-- presize the hash table for 2^28 * 1.5 items of "ideal" performance
-- otherwise we will have substandard start performance from jamming in tons
-- of items then waiting for hash expansion to catch up.
-- TODO: need to fix the algo more and remove freeratio adjustment.
local base_arg = "-m 5000 -o no_hashexpand,hashpower=26,slab_automove_freeratio=0.02 " .. base_extarg

local basic_fill_size = 26 * GByte
local basic_item_size = 15 * KByte
local basic_item_count = math.floor(basic_fill_size / basic_item_size)

-- 'a' gets passed back into the function t
-- because the perf tests were structured in a ramp structure that edits a
-- between runs. not used for extstore right now but I might enable it again
-- so leaving it in this format.
local tests = {
    -- basic prefill then random overwrite + reads load pattern
    basic = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        a = { cli = 50, rate = 50000, prefix = "extstore", limit = basic_item_count, vsize = basic_item_size },
        w = { { limit = basic_item_count, vsize = basic_item_size, prefix = "extstore", shuffle = true, flush_after = warm_write_rate, sleep = 100 } },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate * 0.9, init = true }, o)
            mcs.add(thr, { func = "perfrun_metaset", clients = o.cli, rate_limit = o.rate * 0.1, init = true }, o)
        end,
    },
}

local test_list = {
    "basic",
}

return {
    tests = tests,
    testset = test_list,
}
