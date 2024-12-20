local KEY_LIMIT <const> = 1000000

local pstats_arg = {
    stats = { "cmd_mg", "cmd_ms", "cmd_md", "cmd_get", "cmd_set",
              "vm_gc_runs" },
    track = { "vm_memory_kb", "buffer_memory_used" }
}
local stats_arg = {
    stats = { "proxy_conn_requests" },
    track = { "rusage_user", "rusage_system", "proxy_req_active" }
}

local function go(r, p)
    r:work({ func = "perfrun_stats_out", rate_limit = 1, clients = 1 })
    r:stats({ func = "perfrun_stats_gather", custom = true }, { threads = r:thread_count() })
    r:stats({ func = "proxy_stat_sample", clients = 1, rate_limit = 1 }, pstats_arg)
    r:stats({ func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    r:shred()

    -- grab stats snapshot before the server is stopped
    r:stats({ func = "full_stats", custom = true }, {})
    r:shred()
end

local rate_variant = function(a)
    a.rate = a.rate + a.raise
    if a.rate > a.cap then
        return nil
    end
    -- name for the test name, and the arg struct
    return tostring(a.rate), a
end

-- MAYBE:
-- v = function()
-- a = arg cluster
-- r:args() -> shallow cluster a
-- v func -> grab args copy, return args or nil to stop
-- upper level code needs to know to call a function version of v
-- r:key("rate") returns that whole ass struct
local test_lowclients = {
    n = "lowclients",
    vn = "rate",
    a = { rate = 50000, raise = 50000, cli = 20, cap = 500000, limit = KEY_LIMIT },
    v = rate_variant,
    t = {
        { n = "load", f = function(r)
            local o = r:variant()
            r:work({ func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true}, o)
            go(r)
        end
        }
    }
}

local w = {}
local s = {}

return {
    -- to ensure the start is run once per "backend"
    -- we have to override how often the start code is run
    s = function(r)
        local mc_args = " -m 6000 -t 2 -I 4m"
        for i=1,3 do
            nodestart("mc-node" .. i, mc_args)
        end
        nodestart("mc-proxy", "-m 2000 -t 6 -o proxy_config=/home/ubuntu/conf/proxyperf/proxy-performance-" .. r:key("backend") .. ".lua", 1)

        -- tell caller to track for this key changing
        return "backend"
    end,
    e = function()
        for i=1,3 do
            nodestop("mc-node" .. i)
        end
        nodestop("mc-proxy", 2)
    end,
    w = function(r)
        -- run warmer once per backend
        local be = r:key("backend")
        if w[be] then return nil end
        w[be] = true
        return { {
            func = "perf_warm",
            limit = KEY_LIMIT,
            vsize = 50,
            prefix = "perf/",
        } }
    end,
    vn = "backend",
    v = { "lowbe", "highbe", "beconn", "repl", "replsplit" },
    t = {
        test_lowclients,
    }
}
