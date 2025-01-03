--verbose(true)
--debug(true)

require("nodes")

local_zone("here")

settings{
    active_req_limit = 200000
}

-- TODO:
-- at least a couple tests with the bg thread
-- add cmap and test (basic get/set or ma?)
-- mcp.internal tests
pools{
    basic = {
        backends = nodes_rlib()
    },
    highbeconn = {
        backend_options = { connections = 8 },
        backends = nodes_rlib()
    },
    set_all = {
        { backends = { node_rlib(1) } },
        { backends = { node_rlib(2) } },
        { backends = { node_rlib(3) } }
    },
    set_zoned = {
        here = { backends = { node_rlib(1) } },
        there = { backends = { node_rlib(2) } },
        over = { backends = { node_rlib(3) } }
    }
}

routes{
    map = {
        basic = route_direct{ child = "basic" },
        highbeconn = route_direct{ child = "highbeconn" },
        allfastest = cmdmap{
            all = route_allfastest{
                children = "set_all"
            },
            mg = route_failover{
                children = "set_all",
                stats = true,
                miss = true,
                shuffle = true,
            },
        },
        allsync = cmdmap{
            all = route_allsync{
                children = "set_all",
            },
            mg = route_failover{
                children = "set_all",
                stats = true,
                miss = true,
                shuffle = true,
            },
        },
        zfailover = cmdmap{
            all = route_allsync{
                children = "set_zoned"
            },
            mg = route_zfailover{
                children = "set_zoned",
                stats = true,
                miss = true,
            }
        },
    },
    default = route_direct{ child = "basic" }
}
