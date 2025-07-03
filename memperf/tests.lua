local KByte <const> = 1000
local MByte <const> = KByte * 1000
local GByte <const> = MByte * 1000

local basic_fill_size = 2 * GByte
local small_item_size = 100
local small_item_count = math.floor(basic_fill_size / small_item_size)
local client_count = 20

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

local function go(r, time)
    r:stats({ func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    r:shred()

    -- grab stats snapshot before the server is stopped
    r:stats({ func = "full_stats", custom = true }, {})
    r:work({ func = "perfrun_stats_out", rate_limit = 1, clients = 1, custom = true })
    r:stats({ func = "perfrun_stats_gather", custom = true }, { threads = r:thread_count(), once = true })
    -- TODO: mode switch for doing per-second histogram output
    --r:stats({ func = "perfrun_stats_clear", custom = true }, {})
    r:shred()
end

local function pfx(r)
    return string.format("%s/", r:key("prefix"))
end

local function rand_string(list, count)
    local st = {}
    for i = 1, count do
        local r = math.random(1, #list)
        table.insert(st, list:sub(r, r))
    end
    return table.concat(st)
end

-- hex for no particular reason.
local prefix_list = "ABCDEF0123456789"
local short_prefix = rand_string(prefix_list, 10) .. "/"
local long_prefix = rand_string(prefix_list, 200) .. "/"
local long_P_flags = "v P" .. rand_string(prefix_list, 200)

-- TODO:
-- pre-create short, long key prefix
-- pre-create long P argument
-- create warmers
-- get with short, long
-- mg with short, long
-- mg with short + many flags
-- mg with long + many flags
-- mg with long + many flags + long P
-- mg piped with long + many flags?
-- incr/decr with short/long
-- ma with short/long
-- RAMP:
-- for length checkers, fixed value
-- ramping speed is for scheduler testing
-- also need to test incr/decr on single/few keys.

local test_fetchers = {
    n = "fetchers",
    w = function(r)
        return { {
            func = "perf_warm",
            limit = small_item_count,
            vsize = small_item_size,
            prefix = r:key("prefix")
        } }
    end,
    t = {
        --[[{ n = "getshort",
          prefix = short_prefix,
          f = function(r)
                r:work({ func = "perfrun_get", clients = client_count, rate_limit = 0 },
                    { prefix = short_prefix, vsize = small_item_size, total_keys = small_item_count })
                go(r)
          end
        },--]]
        { n = "mgshort",
          prefix = short_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget", clients = client_count, rate_limit = 0, init = true },
                { prefix = short_prefix, limit = small_item_count })
            go(r)
          end
        },
        { n = "mgshortpiped",
          prefix = short_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget_pipe", clients = client_count, rate_limit = 0, init = true },
                { prefix = short_prefix, limit = small_item_count, pipes = 128 })
            go(r)
          end
        },
        { n = "mglongpiped",
          prefix = long_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget_pipe", clients = client_count, rate_limit = 0, init = true },
                { prefix = long_prefix, limit = small_item_count, pipes = 128 })
            go(r)
          end
        },
        { n = "mgshortmanyflags",
          prefix = short_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget", clients = client_count, rate_limit = 0, init = true },
                { prefix = short_prefix, limit = small_item_count, flags = "v t l h O123456 c Pasdf f s Lasdf" })
            go(r)
          end
        },
        { n = "mglong",
          prefix = long_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget", clients = client_count, rate_limit = 0, init = true },
                { prefix = long_prefix, limit = small_item_count })
            go(r)
          end
        },
        { n = "mglongmanyflags",
          prefix = long_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget", clients = client_count, rate_limit = 0, init = true },
                { prefix = long_prefix, limit = small_item_count, flags = "v t l h O123456 c Pasdf f s Lasdf" })
            go(r)
          end
        },
        { n = "mglongP",
          prefix = long_prefix,
          f = function(r)
            r:work({ func = "perfrun_metaget", clients = client_count, rate_limit = 0, init = true },
                { prefix = long_prefix, limit = small_item_count, flags = long_P_flags })
            go(r)
          end
        },

    },
}

return {
    s = function()
        -- TODO: remove dbg to test actual performance.
        nodestart("mc-memory", "-c 250000 -t 6 -m 40000", 1)
    end,
    e = function()
        nodestop("mc-memory", 2)
    end,
    t = {
        test_fetchers
    }
}
