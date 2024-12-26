local KByte <const> = 1000
local MByte <const> = KByte * 1000
local GByte <const> = MByte * 1000

local basic_fill_size = 40 * GByte
local small_item_size = 100
local small_item_count = math.floor(basic_fill_size / small_item_size)

local stats_arg = {
    stats = {
        "total_connections",
        "rejected_connections",
        "cmd_get",
        "cmd_set",
        "cmd_touch",
        "get_hits",
        "get_misses",
        "get_expired",
        "get_flushed",
        "delete_hits",
        "delete_misses",
        "incr_hits",
        "incr_misses",
        "decr_hits",
        "decr_misses",
        "touch_hits",
        "touch_misses",
        "auth_cmds",
        "auth_errors",
        "conn_yields",
        "slabs_moved",
        "lru_maintainer_juggles",
        "total_items",
        "evictions",
        "moves_to_cold",
        "moves_to_warm",
        "moves_within_lru",
        "direct_reclaims",
        "lru_bumps_dropped"
    },
    track = {
        "rusage_user",
        "rusage_system",
        "curr_connections",
        "connection_structures",
        "response_obj_oom",
        "response_obj_count",
        "read_buf_count",
        "read_buf_bytes",
        "read_buf_oom",
        "hash_power_level",
        "curr_items",
        "slab_global_page_pool"
    }
}
-- TODO: 5-10/s per server thread?
local timer_conf = { func = "timer_metaget", clients = 6, rate_limit = 30, init = true }

local function pfx(r)
    return string.format("/%s/", r:key("prefix"))
end

local function go(r, time)
    -- do light time sampling to spot instability during test run
    r:stats({ func = "timer_display", clients = 1, rate_limit = 1, init = true })
    r:stats(timer_conf, { prefix = "timer/" })
    r:stats({ func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    r:shred(time)

    -- grab stats snapshot before the server is stopped
    -- TODO: restore once we're gathering stats from every func.
    --r:work({ func = "perfrun_stats_out", rate_limit = 1, clients = 1, custom = true })
    --r:stats({ func = "perfrun_stats_gather", custom = true }, { threads = r:thread_count(), once = true })
    r:stats({ func = "full_stats", custom = true }, {})
    r:stats({ func = "full_stats", custom = true }, { sub = "items" })
    r:stats({ func = "full_stats", custom = true }, { sub = "slabs" })
    r:shred()
    plog("COMPLETE")
end

-- Per test: decide fill rate and calculate item count
local test_get = {
    n = "get",
    f = function(r)
        r:work({ func = "runner_basic", clients = 20, rate_limit = 0 },
            { prefix = "test", vsize = small_item_size, total_keys = small_item_count })
        go(r)
    end
}

return {
    s = function()
        nodestartdbg("mc-memory", "-c 250000 -t 6 -m 40000", 1)
    end,
    e = function()
        nodestop("mc-memory", 2)
    end,
    t = {
        test_get
    }
}
