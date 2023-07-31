local KEY_LIMIT <const> = 1000000

-- the list of tests to run in what order.
local test_p_backends = { "lowbe", "highbe", "beconn", "repl", "replwio", "replsplit", "wio", "splitgetset", "splitiogetset" }
local test_p_clients = { "lowclients", "lowpipe", "highclients", "lowgetset" }

-- there's some data redundancy in the test definitions: accepting this to
-- keep the system simpler. Was having to add up and pass around data to find
-- counter limits, size data, etc. Better to keep all data relevant to a test
-- physically closer together.
-- Also, a lot of these tests don't make sense for all value variations.
local test_p_tests = {
    lowclients = { a = { rate = 5000, cli = 20, cap = 500000, limit = KEY_LIMIT },
        w = { { limit = KEY_LIMIT, vsize = 50, prefix = "perf" } },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true}, o)
    end, r = function(o)
        o.rate = o.rate + 10000
        return o.rate
    end},
    lowpipe = { a = { rate = 5000, cli = 20, pipes = 8, cap = 125000, limit = KEY_LIMIT },
        w = { { limit = KEY_LIMIT, vsize = 50, prefix = "perf" } },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget_pipe", clients = o.cli, rate_limit = o.rate, init = true}, o)
    end, r = function(o)
        o.rate = o.rate + 5000
        return o.rate
    end},
    highclients = { a = { rate = 10000, cli = 40, cap = 800000, limit = KEY_LIMIT },
        w = { { limit = KEY_LIMIT, vsize = 50, prefix = "perf" } },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate, init = true}, o)
    end, r = function(o)
        o.rate = o.rate + 20000
        o.cli = o.cli + 80
        return o.rate
    end},
    lowgetset = { a = { rate = 5000, cli = 20, cap = 500000, limit = KEY_LIMIT },
        w = { { limit = KEY_LIMIT, vsize = 50, prefix = "perf" } },
        t = function(thr, o)
            mcs.add(thr, { func = "perfrun_metaget", clients = o.cli, rate_limit = o.rate * 0.9, init = true}, o)
            mcs.add(thr, { func = "perfrun_metaset", clients = o.cli, rate_limit = o.rate * 0.1, init = true}, o)
        end, r = function(o)
            o.rate = o.rate + 10000
            return o.rate
        end},
}

local r = {
    tests = test_p_tests,
    backends = test_p_backends,
    clients = test_p_clients
}

return r
