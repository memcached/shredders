local bwlimit_keys = 500
local main_keys = 1000000
local clients = 20
local client_high = clients * 20

local timer_conf = { func = "timer_metaget", clients = 8, rate_limit = 500, init = true }
local timer_display = { func = "timer_display", clients = 1, rate_limit = 1, init = true }
local stat_conf = { func = "proxy_stat_sample", clients = 1, rate_limit = 1 }
local stat_arg = {
    stats = { "cmd_mg", "cmd_ms", "cmd_md", "cmd_get", "cmd_set" },
    track = { "active_req_limit", "buffer_memory_limit", "buffer_memory_used", "vm_memory_kb", "vm_gc_runs" }
}
local statm_conf = { func = "stat_sample", clients = 1, rate_limit = 1 }
local statm_arg = {
    stats = { "proxy_conn_requests", "total_connections" },
    track = { "proxy_req_active", "proxy_await_active", "read_buf_count", "read_buf_bytes", "read_buf_bytes_free", "response_obj_count", "curr_connections" }
}
local statpf_conf = { func = "proxyfuncs_stat_sample", clients = 1, rate_limit = 1 }

local function pfx(r)
    return string.format("/%s/", r:key("prefix"))
end

local function go(r, p)
    r:stats(timer_display)
    local prefix
    if p then
        prefix = p
    else
        prefix = pfx(r)
    end
    r:stats(timer_conf, { prefix = prefix })
    r:stats(stat_conf, stat_arg)
    r:stats(statm_conf, statm_arg)
    r:stats(statpf_conf)
    r:shred()
end

local main = { prefix = "/main/", total_keys = main_keys, vsize = 100,
               ttl = 0, pipelines = 60 }
local bwlimit = { prefix = "/main/", total_keys = bwlimit_keys, vsize = 800000,
               ttl = 0, pipelines = 10 }
local fault = { prefix = "/main/", total_keys = main_keys, vsize = 100,
               ttl = 0, pipelines = 20 }

-- place to track if we've run a particular warmer prefix yet.
local w = {
    main = {},
    bwlimit = {},
    fault = {}
}

-- TODO:
-- ploss on mc-node1/2/3
-- wccluster vs wcluster (n backends)

-- TODO: convert this to specific wait tests
-- unused right now.
local test_basic = {
    n = "basic",
    t = {
        { n = "largegetset",
          f = function(r)
            --nodectrl("bwlimit mc-node1");
            local a = { prefix = "/neartimeout/", total_keys = 1000, vsize = 3100500, ttl = 0, reconn_chance = 10 }
            --r:work({ func = "runner_metaget", clients = 50, rate_limit = 1000, init = true }, a)
            r:work({ func = "runner_metaset", clients = 500, rate_limit = 0 }, a)
            r:warm({ func = "stability_warm", custom = true }, { limit = 5000000, prefix = "/neartimeout/", vsize = 3100500 })
            --r:work({ func = "runner_metaset_reconn", clients = 50, rate_limit = 0, init = true }, a)
            --r:maint({ func = "runner_ploss", clients = 1, rate_limit = 1, period = 2000 },
            --    { node = "mc-node1", ploss = "10%", _c = 0 })

            go(r, "/neartimeout/")
            --nodectrl("nobwlimit mc-node1");
          end
        },
        { n = "largereconn",
          f = function(r)
            --nodectrl("bwlimit mc-proxy");
            r:work({ func = "runner_metaset_reconn", clients = 250, rate_limit = 0, init = true },
                { prefix = "/nearwait/", total_keys = 5000, vsize = 3000000, reconn_chance = 100 })
            go(r, "/nearwait/")
            --nodectrl("nobwlimit mc-proxy");
          end
        }
    }
}

local test_main = {
    n = "main",
    -- PROBLEM: we want to pass in prefix to the warmer.
    -- we also want to only run the warmer once per variant.
    w = function(r)
        local p = pfx(r)
        if w.main[p] then return nil end
        w.main[p] = true
        return { { func = "stability_warm", limit = main_keys, prefix = p, vsize = 100 } }
    end,
    vn = "prefix",
    v = { "cluster", "ccluster", "wcluster", "wccluster", "wzone", "zone", "zonegood", "wzonegood", "subcluster", "subwcluster", "onewaitwc", "onewait", "onewaitfg", "internal" },
    t = {
        { n = "getters",
          f = function(r)
                main.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 0, init = true }, main)
                go(r)
          end
        },
        { n = "setters",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaset", clients = clients, rate_limit = 0 }, main)
            go(r)
          end
        },
        { n = "multiget",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_multiget", clients = clients, rate_limit = 0 }, main)
            go(r)
          end
        },
        { n = "highgetters",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaget", clients = clients_high, rate_limit = 0, init = true }, main)
            go(r)
          end
        },
        { n = "highsetters",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaset", clients = clients_high, rate_limit = 0 }, main)
            go(r)
          end
        },
        { n = "highmultiget",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_multiget", clients = clients_high, rate_limit = 0 }, main)
            go(r)
          end
        },
        { n = "highreconngetters",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaget", clients = clients_high, rate_limit = 0, init = true, reconn_every = 3 }, main)
            go(r)
          end
        },
        { n = "highreconnsetters",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaset", clients = clients_high, rate_limit = 0, reconn_every = 3 }, main)
            go(r)
          end
        },
        { n = "highreconnmultiget",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_multiget", clients = clients_high, rate_limit = 0, reconn_every = 3 }, main)
            go(r)
          end
        },
        -- the next few tests can remove items.
        { n = "setdel",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaset", clients = clients, rate_limit = 0 }, main)
            r:work({ func = "runner_metadelete", clients = clients, rate_limit = 0, init = true }, main)
            go(r)
          end
        },
        { n = "setpipedel",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metaset", clients = clients, rate_limit = 0 }, main)
            r:work({ func = "runner_batchmetadelete", clients = 1, rate_limit = 0 }, main)
            go(r)
          end
        },
        { n = "highmgpipe",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metagetpipe", clients = clients, rate_limit = 0, init = true },
                { prefix = main.prefix, total_keys = main.total_keys, pipelines = 250 })
            go(r)
          end
        },
        { n = "basicgetset",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_basic", clients = clients, rate_limit = 0 },
                { prefix = main.prefix .. "basicgetset", total_keys = main.total_keys, vsize = 100, ttl = 90 })
            go(r)
          end
        },
        { n = "basicpipe",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_basicpipe", clients = clients, rate_limit = 0 },
                { prefix = main.prefix .. "basicpipe", total_keys = main.total_keys, vsize = 100, ttl = 90, pipelines = 60 })
            go(r)
          end
        },
        { n = "metavariable",
          f = function(r)
            main.prefix = pfx(r)
            r:work({ func = "runner_metabasic_variable", clients = clients, rate_limit = 0 },
                { prefix = main.prefix .. "mbvar", total_keys = main.total_keys, sizemin = 10, sizemax = 9000, ttl = 90 })
            go(r)
          end
        },
    }
}

local test_bwlimit = {
    n = "bwlimit",
    w = function(r)
        local p = pfx(r)
        if w.bwlimit[p] then return nil end
        w.bwlimit[p] = true
        return { { func = "stability_warm", limit = bwlimit_keys, prefix = p, vsize = 800000 } }
    end,
    vn = "prefix",
    v = { "cluster", "ccluster", "wcluster", "zone", "wzone", "zonegood", "wzonegood", "subcluster", "subwcluster", "onewaitwc", "onewait", "onewaitfg" },
    t = {
        {
            n = "getters",
            f = function(r)
                nodectrl("bwlimit mc-proxy");
                bwlimit.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 0, init = true}, bwlimit)
                go(r)
                nodectrl("nobwlimit mc-proxy");
            end
        },
        {
            n = "setters",
            f = function(r)
                nodectrl("bwlimit mc-proxy");
                bwlimit.prefix = pfx(r)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 0}, bwlimit)
                go(a)
                nodectrl("nobwlimit mc-proxy");
            end
        },
        {
            n = "multiget",
            f = function(r)
                nodectrl("bwlimit mc-proxy");
                bwlimit.prefix = pfx(r)
                r:work({ func = "runner_multiget", clients = clients, rate_limit = 0 }, bwlimit)
                go(r)
                nodectrl("nobwlimit mc-proxy");
                -- throw a small value test immediately after the bandwidth
                -- limiter to confirm if memory usage clears.
                local second_args = { total_keys = bwlimit.total_keys, vsize = 100, ttl = 0 }
                second_args.prefix = bwlimit.prefix .. 'extra'

                r:work({ func = "runner_basic", clients = clients, rate_limit = 5000 }, second_args)
                go(r)
            end
        }
    } -- t
}

local test_fault = {
    n = "fault",
    w = function(r)
        return {}
    end,
    vn = "prefix",
    v = { "cluster", "ccluster", "wcluster", "zone", "zonegood", "wzonegood", "subcluster", "subwcluster", "onewaitwc", "onewaitfg" },
    t = {
        {
            n = "reload",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:work({ func = "runner_multiget", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_reload", clients = 1, rate_limit = 1 }, fault)
                go(r)
            end
        },
        {
            n = "lag",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_delay", clients = 1, rate_limit = 1 },
                    { node = "mc-node1", delay = "500ms", _c = 0 })
                go(r)
                nodectrl("clear mc-node1")
            end
        },
        {
            n = "reloadlag",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_delay", clients = 1, rate_limit = 1 },
                    { node = "mc-node1", delay = "500ms", _c = 0 })
                r:maint({ func = "runner_reload", clients = 1, rate_limit = 1 }, fault)
                go(r)
                nodectrl("clear mc-node1")
            end
        },
        {
            n = "ploss",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_ploss", clients = 1, rate_limit = 1, period = 2000 },
                    { node = "mc-node1", ploss = "10%", _c = 0 })
                go(r)
                nodectrl("clear mc-node1")
            end
        },
        {
            n = "block",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_block", clients = 1, rate_limit = 1, period = 2000 },
                    { node = "mc-node1", _c = 0 })
                go(r)
                nodectrl("unblock mc-node1")
            end
        },
        {
            n = "bigblock",
            f = function(r)
                fault.prefix = pfx(r)
                r:work({ func = "runner_metaget", clients = clients * 400, rate_limit = 200000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                r:maint({ func = "runner_block", clients = 1, rate_limit = 1, period = 4000 },
                    { node = "mc-node1", _c = 0 })
                go(r)
                nodectrl("unblock mc-node1")
            end
        },
        {
            n = "blocked",
            f = function(r)
                fault.prefix = pfx(r)
                nodectrl("block mc-node1")
                r:work({ func = "runner_metaget", clients = clients, rate_limit = 50000, init = true }, fault)
                r:work({ func = "runner_metaset", clients = clients, rate_limit = 5000 }, fault)
                r:stats({ func = "runner_watcher", custom = true }, { watchers = "proxyevents" })
                go(r)
                nodectrl("unblock mc-node1")
            end
        }
    } -- t
}

return {
    s = function()
        -- Start mc on all nodes
        local mc_args = " -m 6000 -t 2 -I 4m"
        for i=1,3 do
            nodestartdbg("mc-node" .. i .. mc_args)
        end
        -- start proxy node with config
        nodestartdbg("mc-proxy -m 2000 -t 6 -o proxy_config=/home/ubuntu/conf/proxy-stability.lua", 1)
    end,
    e = function()
        for i=1,3 do
            nodestop("mc-node" .. i)
        end
        nodestop("mc-proxy", 2)
    end,
    t = {
        test_main,
        test_bwlimit,
        test_fault,
    }
}
