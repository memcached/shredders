local KByte <const> = 1000
local MByte <const> = KByte * 1000
local GByte <const> = MByte * 1000

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
    local prefix
    if p then
        prefix = p
    else
        prefix = pfx(r)
    end

    -- do light time sampling to spot instability during test run
    r:stats(timer_display)
    r:stats(timer_conf, { prefix = prefix })
    r:stats({ func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    r:shred(time)

    -- grab stats snapshot before the server is stopped
    r:work({ func = "perfrun_stats_out", rate_limit = 1, clients = 1, custom = true })
    r:stats({ func = "perfrun_stats_gather", custom = true }, { threads = r:thread_count(), once = true })
    r:stats({ func = "full_stats", custom = true }, {})
    r:stats({ func = "full_stats", custom = true }, { sub = "items" })
    r:stats({ func = "full_stats", custom = true }, { sub = "slabs" })
    r:shred()
end

-- Per test: decide fill rate and calculate item count

return {
    s = function()
        nodestartdbg("mc-memory", "-c 250000 -m 40000", 1)
    end,
    e = function()
        nodestop("mc-node1", 2)
    end,
    t = {

    }
}
