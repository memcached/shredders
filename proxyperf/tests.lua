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
    r:stats({ func = "perfrun_stats_clear", custom = true }, {})
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

local rate_cli_variant = function(a)
    a.rate = a.rate + a.raise
    a.cli = a.cli + 80
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
        },
    }
}

local test_lowpipe = {
    n = "lowpipe",
    vn = "rate",
    a = { rate = 50000, raise = 50000, cli = 20, pipes = 8, cap = 500000, limit = KEY_LIMIT },
    v = rate_variant,
    t = {
        { n = "load", f = function(r)
            local o = r:variant()
            r:work({ func = "perfrun_metaget_pipe", clients = o.cli, rate_limit = o.rate, init = true}, o)
            go(r)
        end
        },
    }
}

local test_highclients = {
    n = "highclients",
    vn = "rate",
    a = { rate = 10000, raise = 50000, cli = 40, cap = 800000, limit = KEY_LIMIT },
    v = rate_cli_variant,
    t = {
        { n = "load", f = function(r)
            local o = r:variant()
            r:work({ func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true}, o)
            go(r)
        end
        },
    }
}

local test_lowgetset = {
    n = "lowgetset",
    vn = "rate",
    a = { rate = 5000, raise = 25000, cli = 20, cap = 500000, limit = KEY_LIMIT },
    v = rate_variant,
    t = {
        { n = "load", f = function(r)
            local o = r:variant()
            r:work({ func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate * 0.9, init = true}, o)
            r:work({ func = "perfrun_metaset", clients = o.cli, rate_limit = o.rate * 0.1, init = true}, o)
            go(r)
        end
        },
    }
}

local w = {}

local bare_tests = {
    n = "bare",
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
    v = { "lowbe", "highbe", "beconn", "repl", "replsplit", "router" },
    t = {
        test_lowclients,
        test_lowpipe,
        test_highclients,
        test_lowgetset,
    }
}

local function pfx(r)
    return string.format("%s/", r:key("prefix"))
end

local rlib_arg = {
    get_rate = 100000,
    set_rate = 20000,
    cli = 50,
    limit = KEY_LIMIT,
    vsize = 50,
    prefix = "placeholder"
}

local rlib_basic = {
    n = "basic",
    f = function(r)
        local o = r:key("arg")
        o.prefix = pfx(r)
        r:work({ func = "perfrun_metaget", clients = o.cli, rate_limit = o.get_rate, init = true}, o)
        r:work({ func = "perfrun_metaset", clients = o.cli, rate_limit = o.set_rate, init = true}, o)
        go(r)
    end
}

-- test routelib specifically since larger configurations cause lua to do
-- weird things, plus this is the supported public interface anyway.
-- NOTE: scalability tests aren't as interesting as perf deltas between
-- different features, I think?
-- capacity tests might be nice or rate climbers but only for specific
-- scenarios.
local routelib_tests = {
    n = "routelib",
    arg = rlib_arg,
    s = function(r)
        local mc_args = " -m 6000 -t 2 -I 4m"
        for i=1,3 do
            nodestart("mc-node" .. i, mc_args)
        end
        nodestart("mc-proxy", "-m 2000 -t 6 -o proxy_config=routelib,proxy_arg=/home/ubuntu/conf/proxyperf/proxy-performance-routelib.lua", 1)
    end,
    w = function(r)
        return { {
            func = "perf_warm",
            limit = KEY_LIMIT,
            vsize = 50,
            prefix = pfx(r)
        } }
    end,
    vn = "prefix",
    v = { "basic", "highbeconn", "allfastest", "allsync", "zfailover", "fallback" },
    t = {
        rlib_basic,
    }
}

return {
    e = function()
        for i=1,3 do
            nodestop("mc-node" .. i)
        end
        nodestop("mc-proxy", 2)
    end,
    t = {
        bare_tests,
        routelib_tests,
    }
}
