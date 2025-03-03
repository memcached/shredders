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
local small_item_size = 250
local small_item_size_max = 600
local basic_item_count = math.floor(basic_fill_size / basic_item_size)
local small_item_count = math.floor(basic_fill_size / small_item_size_max)

-- the actual amounts are fudged higher because items take residence in both
-- RAM + disk.
-- So to target "90% of disk" we need slightly more data overall.
local reload50_item_count = math.floor(basic_item_count * 0.56)
local reload75_item_count = math.floor(basic_item_count * 0.82)
local reload90_item_count = math.floor(basic_item_count * 0.96)

local function go(r, time)
    local stats_arg = {
        stats = { "cmd_get", "cmd_set", "extstore_bytes_read", "extstore_objects_read", "extstore_objects_written", "miss_from_extstore", "slabs_moved" },
        track = { "extstore_bytes_written", "extstore_bytes_fragmented", "extstore_bytes_used", "extstore_io_queue", "extstore_page_allocs", "extstore_page_reclaims", "extstore_page_evictions", "extstore_pages_free", "evictions", "extstore_memory_pressure", "slab_global_page_pool" }
    }

    -- one set of funcs on each test thread that ships history
    -- one func that reads the history and summarizes every second.
    r:work({ func = "perfrun_stats_out", rate_limit = 1, clients = 1 })
    r:stats({ func = "perfrun_stats_gather", custom = true }, { threads = r:thread_count() })

    r:stats({ func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    r:shred(time)

    -- grab stats snapshot before the server is stopped
    r:stats({ func = "full_stats", custom = true }, {})
    r:shred()
end

local function start(a, b)
    if b == nil then
        b = base_arg
    end
    return function()
        nodestart("mc-extstore", base_arg .. a, 2)
    end
end

local function stop()
    return function()
        nodestop("mc-extstore", 8)
    end
end

-- ensure mc-extstore is stopped
-- TODO: nodectrl to check-if-pid-running-then-etc
nodestop("mc-extstore", 2)

local test_basic = {
    n = "basic",
    s = start(" -o ext_path=/extstore/extstore:25g"),
    w = function(r)
        return { {
            func = "perf_warm",
            limit = basic_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    f = function(r)
        local a = { cli = 40, rate = 40000, prefix = "extstore", limit = basic_item_count, vsize = basic_item_size }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate * 0.9, init = true }, a)
        r:work({ func = "perfrun_metaset", clients = a.cli, rate_limit = a.rate * 0.1, init = true }, a)
        go(r)
    end
}

-- fill with small items for a while
local test_small = {
    n = "small",
    s = start(" -f 1.06 -o ext_path=/extstore/extstore:25g,ext_item_size=350,slab_chunk_max=2"),
    f = function(r)
        local p = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        local a = { cli = 40, rate = 300000, prefix = "extstore" .. p, limit = small_item_count, vsize_min = small_item_size, vsize_max = small_item_size_max }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate * 0.2, init = true }, a)
        r:work({ func = "perfrun_metaset", clients = a.cli, rate_limit = a.rate * 0.8, init = true }, a)
        go(r, 180)
    end
}

-- Using an indirection for the item counts so we get nicer test names.
local item_counts = {
    ["50pct"] = reload50_item_count,
    ["75pct"] = reload75_item_count,
    ["90pct"] = reload90_item_count
}

-- TODO: maybe some extra syntactic sugar for a variant test with a single
-- subtest?
local test_reload = {
    n = "reload",
    s = start(" -o ext_path=/extstore/extstore:25g"),
    vn = "itemcount",
    v = { "50pct", "75pct", "90pct" },
    w = function(r)
        return { {
            func = "perf_warm",
            limit = item_counts[r:key("itemcount")],
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    -- have to organize the test as sub-tests since we're using a variant
    t = {
        { n = "load", f = function(r)
            local a = { cli = 25, rate = 25000, prefix = "extstore", limit = item_counts[r:key("itemcount")], vsize = basic_item_size }
            r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate, init = true }, a)

            r:warm({ func = "perf_warm", custom = true }, {
                limit = item_counts[r:key("itemcount")],
                vsize = basic_item_size,
                prefix = "extstore",
                shuffle = true,
                -- halve the speed + smaller chunks
                flush_after = math.floor(warm_write_rate / 4),
                sleep = 50,
                stop_after = true
            })
            -- run until the warmer finishes
            go(r, 9999)
        end
        }
    }
}

-- fill past eviction slowly
local test_eviction = {
    n = "eviction",
    s = start(" -o ext_path=/extstore/extstore:25g"),
    w = function(r)
        return { {
            func = "perf_warm",
            limit = basic_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    f = function(r)
        local a = { cli = 25, rate = 25000, prefix = "extstore", limit = basic_item_count, vsize = basic_item_size }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate, init = true }, a)

        r:warm({ func = "perf_warm", custom = true }, {
            limit = basic_item_count,
            vsize = basic_item_size,
            prefix = "extstore_eviction",
            shuffle = false,
            -- even slower, but we're trying to fill the disk all the way.
            flush_after = math.floor(warm_write_rate / 10),
            sleep = 50,
            stop_after = true
        })
        -- run until the warmer finishes
        go(r, 9999)
    end
}

-- 90% reload, but we have the OLD bucket and plenty of extra space there
local test_reloadold = {
    n = "reloadold",
    s = start(" -o ext_path=/extstore/extstore:25g,ext_path=/extstore/extold:25g:old"),
    w = function(r)
        return { {
            func = "perf_warm",
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    f = function(r)
        local a = { cli = 25, rate = 25000, prefix = "extstore", limit = reload90_item_count, vsize = basic_item_size }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate, init = true }, a)

        r:warm({ func = "perf_warm", custom = true }, {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore_old",
            shuffle = true,
            -- half the speed + smaller chunks.
            flush_after = math.floor(warm_write_rate / 4),
            sleep = 50,
            stop_after = true
        })
        -- run until the warmer finishes
        go(r, 9999)
    end
}

local test_evictionold = {
    n = "evictionold",
    s = start(" -o ext_path=/extstore/extstore:15g,ext_path=/extstore/extold:15g:old"),
    w = function(r)
        return { {
            func = "perf_warm",
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    f = function(r)
        local a = { cli = 25, rate = 25000, prefix = "extstore", limit = reload90_item_count, vsize = basic_item_size }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate, init = true }, a)

        r:warm({ func = "perf_warm", custom = true }, {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore_old",
            shuffle = true,
            -- half the speed + smaller chunks.
            flush_after = math.floor(warm_write_rate / 4),
            sleep = 50,
            stop_after = true
        })
        -- run until the warmer finishes
        go(r, 9999)
    end
}

local test_reloadcold = {
    n = "reloadcold",
    s = start(" -o ext_path=/extstore/extstore:25g,ext_path=/extstore/extold:25g:coldcompact"),
    w = function(r)
        return { {
            func = "perf_warm",
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore",
            shuffle = true,
            flush_after = warm_write_rate,
            sleep = 100
        } }
    end,
    f = function(r)
        local a = { cli = 25, rate = 25000, prefix = "extstore", limit = reload90_item_count, vsize = basic_item_size }
        r:work({ func = "perfrun_metaget", clients = a.cli, rate_limit = a.rate, init = true }, a)

        r:warm({ func = "perf_warm", custom = true }, {
            limit = reload90_item_count,
            vsize = basic_item_size,
            prefix = "extstore_old",
            shuffle = true,
            -- half the speed + smaller chunks.
            flush_after = math.floor(warm_write_rate / 4),
            sleep = 50,
            stop_after = true
        })
        -- run until the warmer finishes
        go(r, 9999)
    end
}

return {
    e = stop(),
    t = {
        test_basic,
        test_small,
        test_reload,
        test_eviction,
        test_reloadold,
        test_evictionold,
        test_reloadcold,
    }
}
