
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

function new_basic_factory(arg, func)
    local fgen = mcp.funcgen_new()
    local o = { t = {}, c = 0 }

    o.wait = arg.wait
    o.msg = arg.msg
    if arg.list then
        for _, v in pairs(arg.list) do
            table.insert(o.t, fgen:new_handle(v))
            o.c = o.c + 1
        end
    end

    fgen:ready({ f = func, a = o, n = arg.name})
    return fgen
end

function direct_gen(rctx, arg)
    local h = arg.t[1]
    return function(r)
        return rctx:enqueue_and_wait(r, h)
    end
end

function wait_all_gen(rctx, arg)
    local t = arg.t
    local count = arg.c

    return function(r)
        rctx:enqueue(r, t)
        rctx:wait_cond(count, mcp.WAIT_ANY)
        return rctx:any(t[1])
    end
end

function internal_gen(rctx, arg)
    return function(r)
        return mcp.internal(r)
    end
end

function string_gen(rctx, arg)
    return function(r)
        return arg.msg
    end
end

function gc_gen(rctx, arg)
    return function(r)
        print("garbage: " .. collectgarbage("count"))
        return "END\r\n"
    end
end

function mcp_config_routes(conf)
    local map = {
        ["gc"] = new_basic_factory({ }, gc_gen),
        ["cluster"] = new_basic_factory({ list = { conf.cluster } }, direct_gen),
        ["wcluster"] = new_basic_factory({ list = { conf.wcluster } }, direct_gen),
        ["ccluster"] = new_basic_factory({ list = { conf.ccluster } }, direct_gen),
        ["wccluster"] = new_basic_factory({ list = { conf.wccluster } }, direct_gen),
        ["zone"] = new_basic_factory({ list = { conf.z1, conf.z2, conf.z3 } }, wait_all_gen),
        ["wzone"] = new_basic_factory({ list = { conf.wz1, conf.wz2, conf.wz3 } }, wait_all_gen),
        ["wzone"] = new_basic_factory({ list = { conf.wz1, conf.wz2, conf.wz3 } }, wait_all_gen),
        ["internal"] = new_basic_factory({ }, internal_gen),
    }

    local default = new_basic_factory({ msg = "SERVER_ERROR no route\r\n" }, string_gen)

    mcp.attach(mcp.CMD_ANY_STORAGE, 
        mcp.router_new({ map = map, mode = "anchor", start = "/", stop = "/", default = default }))

end
