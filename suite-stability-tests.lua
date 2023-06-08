local bwlimit_keys = 500
local main_keys = 1000000
local clients = 20
local client_high = clients * 20

local suite_sets = {
    { "main", { "cluster", "ccluster", "wcluster", "wccluster", "wzone", "zone", "internal" } },
    { "bwlimit", { "cluster", "ccluster", "wcluster", "zone", "wzone" } },
    { "fault", { "cluster", "ccluster", "wcluster", "zone" } },
}

local test_args = {
    bwlimit = { prefix = "/main/", total_keys = bwlimit_keys, vsize = 800000,
               ttl = 0, pipelines = 10 },
    main = { prefix = "/main/", total_keys = main_keys, vsize = 100,
               ttl = 0, pipelines = 60 },
    fault = { prefix = "/main/", total_keys = main_keys, vsize = 100,
               ttl = 0, pipelines = 20 },
}

local warmers = {
    main = function(pfx, t)
        mcs.add_custom(t.w, { func = "warm" }, { limit = main_keys, prefix = pfx, vsize = 100 })
        mcs.shredder({t.w})
    end,
    bwlimit = function(pfx, t)
        mcs.add_custom(t.w, { func = "warm" }, { limit = bwlimit_keys, prefix = pfx, vsize = 800000 })
        mcs.shredder({t.w})
    end,
    fault = function(pfx)
        -- no-op?
    end,
}

local tests_s = {
    {p = "main", n = "getters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 0, init = true}, a)
    end},
    {p = "main", n = "setters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 0}, a)
    end},
    {p = "main", n = "multiget", f = function(a, t)
        mcs.add(t.t, { func = "runner_multiget", clients = clients, rate_limit = 0}, a)
    end},
    {p = "main", n = "highgetters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaget", clients = clients_high, rate_limit = 0, init = true}, a)
    end},
    {p = "main", n = "highsetters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaset", clients = clients_high, rate_limit = 0}, a)
    end},
    {p = "main", n = "highmultiget", f = function(a, t)
        mcs.add(t.t, { func = "runner_multiget", clients = clients_high, rate_limit = 0}, a)
    end},
    {p = "main", n = "highreconngetters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaget", clients = clients_high, rate_limit = 0, init = true, reconn_every = 3}, a)
    end},
    {p = "main", n = "highreconnsetters", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaset", clients = clients_high, rate_limit = 0, reconn_every = 3}, a)
    end},
    {p = "main", n = "highreconnmultiget", f = function(a, t)
        mcs.add(t.t, { func = "runner_multiget", clients = clients_high, rate_limit = 0, reconn_every = 3}, a)
    end},
    -- the next few tests can remove items.
    {p = "main", n = "setdel", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 0}, a)
        mcs.add(t.t, { func = "runner_metadelete", clients = clients, rate_limit = 0, init = true}, a)
    end},
    {p = "main", n = "setpipedel", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 0}, a)
        mcs.add(t.t, { func = "runner_batchmetadelete", clients = 1, rate_limit = 0}, a)
    end},
    {p = "main", n = "getsetdel", f = function(a, t)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 0, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 0}, a)
        mcs.add(t.t, { func = "runner_metadelete", clients = clients, rate_limit = 0, init = true}, a)
    end},
    {p = "main", n = "basicgetset", f = function(a, t)
        -- use a different prefix so we can test natural loading.
        mcs.add(t.t, { func = "runner_basic", clients = clients, rate_limit = 0},
            { prefix = a.prefix .. "basicgetset", total_keys = a.total_keys, vsize = 100, ttl = 90 })
    end},
    {p = "main", n = "basicpipe", f = function(a, t)
        -- use a different prefix to test natural loading.
        mcs.add(t.t, { func = "runner_basicpipe", clients = clients, rate_limit = 0},
            { prefix = a.prefix .. "basicpipe", total_keys = a.total_keys, vsize = 100, ttl = 90, pipelines = 60 })
    end},
    {p = "main", n = "metavariable", f = function(a, t)
        -- use a different prefix to test natural loading.
        mcs.add(t.t, { func = "runner_metabasic_variable", clients = clients, rate_limit = 0},
            { prefix = a.prefix .. "mbvar", total_keys = a.total_keys, sizemin = 10, sizemax = 9000, ttl = 90 })
    end},
    {p = "bwlimit", n = "getters", s = true, f = function(a, t, go)
        nodectrl("bwlimit mc-proxy");
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 0, init = true}, a)
        go(a)
        nodectrl("nobwlimit mc-proxy");
    end},
    {p = "bwlimit", n = "setters", s = true, f = function(a, t, go)
        nodectrl("bwlimit mc-proxy");
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 0}, a)
        go(a)
        nodectrl("nobwlimit mc-proxy");
    end},
    {p = "bwlimit", n = "multiget", s = true, f = function(a, t, go)
        nodectrl("bwlimit mc-proxy");
        mcs.add(t.t, { func = "runner_multiget", clients = clients, rate_limit = 0}, a)
        go(a)
        nodectrl("nobwlimit mc-proxy");
        -- throw a small value test immediately after the bandwidth
        -- limiter to confirm if memory usage clears.
        local second_args = { total_keys = a.total_keys, vsize = 100, ttl = 0 }
        second_args.prefix = a.prefix .. 'extra'

        mcs.add(t.t, { func = "runner_basic", clients = clients, rate_limit = 5000}, second_args)
        go(second_args)
    end},
    {p = "fault", n = "reload", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_reload", clients = 1, rate_limit = 1}, a)
        go(a)
    end},
    {p = "fault", n = "reloadmultiget", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_multiget", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_reload", clients = 1, rate_limit = 1}, a)
        go(a)
    end},
    {p = "fault", n = "lag", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_delay", clients = 1, rate_limit = 1},
            { node = "mc-node1", delay = "500ms", _c = 0 })
        go(a)
        nodectrl("clear mc-node1")
    end},
    {p = "fault", n = "reloadlag", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_delay", clients = 1, rate_limit = 1},
            { node = "mc-node1", delay = "500ms", _c = 0 })
        mcs.add(t.m, { func = "runner_reload", clients = 1, rate_limit = 5}, a)
        go(a)
        nodectrl("clear mc-node1")
    end},
    {p = "fault", n = "ploss", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_ploss", clients = 1, rate_limit = 1, period = 2000 },
            { node = "mc-node1", ploss = "10%", _c = 0 })
        go(a)
        nodectrl("clear mc-node1")
    end},
    {p = "fault", n = "block", s = true, f = function(a, t, go)
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        mcs.add(t.m, { func = "runner_block", clients = 1, rate_limit = 1, period = 2000 },
            { node = "mc-node1", _c = 0 })
        go(a)
        nodectrl("unblock mc-node1")
    end},
    {p = "fault", n = "blocked", s = true, f = function(a, t, go)
        -- we leave the node blocked for the entire duration of the test.
        -- request rate should be stable.
        nodectrl("block mc-node1")
        mcs.add(t.t, { func = "runner_metaget", clients = clients, rate_limit = 50000, init = true}, a)
        mcs.add(t.t, { func = "runner_metaset", clients = clients, rate_limit = 5000}, a)
        mcs.add_custom(t.s, { func = "runner_watcher" }, { watchers = "proxyevents" })
        go(a)
        nodectrl("unblock mc-node1")
    end},
}

-- color the tests with common data and functions.
for _, test in pairs(tests_s) do
    test.a = test_args[test.p]
    test.w = warmers[test.p]
end

local r = {
    tests = tests_s,
    sets = suite_sets
}

return r
