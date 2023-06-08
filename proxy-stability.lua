
-- backends per zone.
local perzone = 10

function mcp_config_pools()
    local srv = mcp.backend

    mcp.backend_read_timeout(0.25)
    mcp.backend_connect_timeout(0.5)
    --mcp.active_req_limit(5000);
    --mcp.buffer_memory_limit(100000);
    
    -- TODO: local node1ip = getip("mc-node1")
    local node1ip = '10.191.24.56'
    local node2ip = '10.191.24.4'
    local node3ip = '10.191.24.178'

    local b1 = srv('b1', node1ip, 11211)
    local b2 = srv('b2', node2ip, 11211)
    local b3 = srv('b3', node3ip, 11211)

    local cluster = mcp.pool({b1, b2, b3})

    local b1c = srv({ label = "b1c", host = node1ip, port = 11211,
                      connections = 3})
    local b2c = srv({ label = "b2c", host = node2ip, port = 11211,
                      connections = 3})
    local b3c = srv({ label = "b3c", host = node3ip, port = 11211,
                      connections = 3})

    local ccluster = mcp.pool({b1c, b2c, b3c})

    local b1z = {}
    for x=1, perzone, 1 do
        table.insert(b1z, srv("z1:" .. x, node1ip, 11211))
    end
    local b2z = {}
    for x=1, perzone, 1 do
        table.insert(b2z, srv("z2:" .. x, node2ip, 11211))
    end
    local b3z = {}
    for x=1, perzone, 1 do
        table.insert(b3z, srv("z3:" .. x, node3ip, 11211))
    end

    local conf = {
        cluster = cluster, -- all backends as a single local cluster
        z1 = mcp.pool({b1}), -- 3 zones with a single backend in each
        z2 = mcp.pool({b2}),
        z3 = mcp.pool({b3}),
        mz1 = mcp.pool(b1z), -- 3 zones with 'perzone' sockets per backend
        mz2 = mcp.pool(b2z),
        mz3 = mcp.pool(b3z),
        -- per-worker-thread single cluster
        wcluster = mcp.pool({b1, b2, b3}, { beprefix = "wc", iothread = false }),
        -- multi-connection per backend
        ccluster = ccluster,
        wccluster = mcp.pool({b1c, b2c, b3c}, { beprefix = "wcc", iothread = false }),
        -- per-worker-thread node per zone
        wz1 = mcp.pool({b1}, { beprefix = "wio", iothread = false }),
        wz2 = mcp.pool({b2}, { beprefix = "wio", iothread = false }),
        wz3 = mcp.pool({b3}, { beprefix = "wio", iothread = false }),
    }

    return conf
end

-- WORKER CODE:

function prefix_factory(pattern, list, default)
    local p = pattern
    local l = list
    local d = default
    return function(r)
        local route = l[string.match(r:key(), p)]
        if route == nil then
            return d(r)
        end
        return route(r)
    end
end

function mcp_config_routes(conf)
    local pfx_get = {}
    local pfx_set = {}
    local pfx_mg = {}
    local pfx_ms = {}
    local pfx_md = {}
    local prefixes = {}

    local cluster = conf["cluster"]
    local wcluster = conf["wcluster"]
    local ccluster = conf["ccluster"]
    local wccluster = conf["wccluster"]
    pfx_get["gc"] = function(r)
        print("garbage: " .. collectgarbage("count"))
        return "END\r\n"
    end

    -- Directly proxy to set of local pool nodes.
    pfx_mg["cluster"] = function(r)
        return cluster(r)
    end
    pfx_ms["cluster"] = pfx_mg["cluster"]
    pfx_md["cluster"] = pfx_mg["cluster"]

    pfx_get["cluster"] = pfx_mg["cluster"]
    pfx_set["cluster"] = pfx_mg["cluster"]

    pfx_mg["wcluster"] = function(r)
        return wcluster(r)
    end
    pfx_ms["wcluster"] = pfx_mg["wcluster"]
    pfx_md["wcluster"] = pfx_mg["wcluster"]

    pfx_get["wcluster"] = pfx_mg["wcluster"]
    pfx_set["wcluster"] = pfx_mg["wcluster"]

    pfx_mg["ccluster"] = function(r)
        return ccluster(r)
    end
    pfx_ms["ccluster"] = pfx_mg["ccluster"]
    pfx_md["ccluster"] = pfx_mg["ccluster"]

    pfx_get["ccluster"] = pfx_mg["ccluster"]
    pfx_set["ccluster"] = pfx_mg["ccluster"]

    pfx_mg["wccluster"] = function(r)
        return wccluster(r)
    end
    pfx_ms["wccluster"] = pfx_mg["wccluster"]
    pfx_md["wccluster"] = pfx_mg["wccluster"]

    pfx_get["wccluster"] = pfx_mg["wccluster"]
    pfx_set["wccluster"] = pfx_mg["wccluster"]

    local z1 = conf["z1"]
    local z2 = conf["z2"]
    local z3 = conf["z3"]
    pfx_mg["zone"] = function(r)
        -- mcp.await basics
        local res = mcp.await(r, { z1, z2, z3 })
        return res[1]
    end

    pfx_ms["zone"] = pfx_mg["zone"]
    pfx_md["zone"] = pfx_mg["zone"]

    pfx_get["zone"] = pfx_mg["zone"]
    pfx_set["zone"] = pfx_mg["zone"]

    local wz1 = conf["wz1"]
    local wz2 = conf["wz2"]
    local wz3 = conf["wz3"]
    pfx_mg["wzone"] = function(r)
        -- same await but per-worker-thread
        local res = mcp.await(r, { wz1, wz2, wz3 })
        return res[1]
    end

    pfx_ms["wzone"] = pfx_mg["wzone"]
    pfx_md["wzone"] = pfx_mg["wzone"]

    pfx_get["wzone"] = pfx_mg["wzone"]
    pfx_set["wzone"] = pfx_mg["wzone"]

    pfx_mg["internal"] = function(r)
        return mcp.internal(r)
    end

    pfx_ms["internal"] = pfx_mg["internal"]
    pfx_md["internal"] = pfx_mg["internal"]

    pfx_get["internal"] = pfx_mg["internal"]
    pfx_set["internal"] = pfx_mg["internal"]

    local routeget = prefix_factory("^/(%a+)/", pfx_get, function(r) return "SERVER_ERROR no get route\r\n" end)
    local routeset = prefix_factory("^/(%a+)/", pfx_set, function(r) return "SERVER_ERROR no set route\r\n" end)
    local routemg = prefix_factory("^/(%a+)/", pfx_mg, function(r) return "SERVER_ERROR no mg route\r\n" end)
    local routems = prefix_factory("^/(%a+)/", pfx_ms, function(r) return "SERVER_ERROR no ms route\r\n" end)
    local routemd = prefix_factory("^/(%a+)/", pfx_md, function(r) return "SERVER_ERROR no md route\r\n" end)

    mcp.attach(mcp.CMD_GET, routeget)
    mcp.attach(mcp.CMD_SET, routeset)
    mcp.attach(mcp.CMD_MG, routemg)
    mcp.attach(mcp.CMD_MS, routems)
    mcp.attach(mcp.CMD_MD, routemd)

end
