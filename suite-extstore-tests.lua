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

local basic_fill_size = 28 * GByte
local basic_item_size = 15 * KByte
local basic_item_count = math.floor(basic_fill_size / basic_item_size)

-- the actual amounts are fudged higher because items take residence in both
-- RAM + disk.
-- So to target "90% of disk" we need slightly more data overall.
local reload50_item_count = math.floor(basic_item_count * 0.56)
local reload75_item_count = math.floor(basic_item_count * 0.82)
local reload90_item_count = math.floor(basic_item_count * 0.96)

-- 'a' gets passed back into the function t
-- because the perf tests were structured in a ramp structure that edits a
-- between runs. not used for extstore right now but I might enable it again
-- so leaving it in this format.
local tests = {
    -- basic prefill then random overwrite + random reads load pattern
    -- this is a semi-worst case scenario
    basic = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        w = { { limit = basic_item_count, vsize = basic_item_size, prefix = "extstore", shuffle = true, flush_after = warm_write_rate, sleep = 100 } },

        a = { cli = 40, rate = 40000, prefix = "extstore", limit = basic_item_count, vsize = basic_item_size },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate * 0.9, init = true }, o)
            mcs.add(thr, { func = "perfrun_metaset", clients = o.cli, rate_limit = o.rate * 0.1, init = true }, o)
        end,
    },
    -- overwrite the data but total disk usage is close to 50%
    reload50 = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        w = { {
            limit = reload50_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload50_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload50_item_count,
                vsize = basic_item_size,
                prefix = "extstore",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },
    -- overwrite the data but total disk usage is close to 75%
    reload75 = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        w = { {
            limit = reload75_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload75_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload75_item_count,
                vsize = basic_item_size,
                prefix = "extstore",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },
    -- overwrite the data but total disk usage is close to 90%
    reload90 = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        w = { {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload90_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload90_item_count,
                vsize = basic_item_size,
                prefix = "extstore",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },
    -- fill past eviction slowly
    eviction = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g",
        w = { {
            limit = basic_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = basic_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = basic_item_count,
                vsize = basic_item_size,
                prefix = "extstore_eviction",
                shuffle = false,
                -- even slower, but we're trying to fill the disk all the way.
                flush_after = math.floor(warm_write_rate / 10),
                sleep = 50,
            })
        end,
    },
    -- 90% reload, but we have the OLD bucket and plenty of extra space there
    reloadold = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g,ext_path=/extstore/extold:25g:old",
        w = { {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload90_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload90_item_count,
                vsize = basic_item_size,
                prefix = "extstore_old",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },
    evictionold = {
        s = base_arg .. " -o ext_path=/extstore/extstore:15g,ext_path=/extstore/extold:15g:old",
        w = { {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload90_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload90_item_count,
                vsize = basic_item_size,
                prefix = "extstore_old",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },
    reloadcold = {
        s = base_arg .. " -o ext_path=/extstore/extstore:25g,ext_path=/extstore/extcold:25g:coldcompact",
        w = { {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100,
        } },
        a = {
            cli = 25,
            rate = 25000,
            prefix = "extstore",
            limit = reload90_item_count,
            vsize = basic_item_size,
        },
        t = function(thr, wthr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true }, o)
            mcs.add_custom(wthr, { func = "perf_warm" }, {
                limit = reload90_item_count,
                vsize = basic_item_size,
                prefix = "extstore_old",
                shuffle = true,
                -- half the speed + smaller chunks.
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
            })
        end,
    },

}

local test_list = {
    "basic",
    "reload50",
    "reload75",
    "reload90",
    "eviction",
    "reloadold",
    "evictionold",
    "reloadcold",
}

return {
    tests = tests,
    testset = test_list,
}
