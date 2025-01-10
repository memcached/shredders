
-- backends per zone.
local perzone = 10
local S_NEAR_TIMEOUT <const> = 1
local S_ALL_TIMEOUT <const> = 2

function mcp_config_pools()
    local srv = mcp.backend

    mcp.add_stat(S_NEAR_TIMEOUT, "read_timeout")
    mcp.add_stat(S_ALL_TIMEOUT, "write_timeout")

    mcp.backend_use_iothread(true)
    mcp.backend_read_timeout(0.3)
    mcp.backend_connect_timeout(0.5)
    mcp.backend_depth_limit(8000)
    --mcp.active_req_limit(5000);
    mcp.buffer_memory_limit(3000000);
    
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
        wz1r = mcp.pool({b1c}, { beprefix = "wior", iothread = false }),
        wz2r = mcp.pool({b2c}, { beprefix = "wior", iothread = false }),
        wz3r = mcp.pool({b3c}, { beprefix = "wior", iothread = false }),
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

function near_timeout_gen(rctx, arg)
    -- we first attempt to fetch from a "local" zone.
    local near = arg.t[1]
    local far = { table.unpack(arg.t, 2) }
    local all = arg.t
    local wait = 0.05
    local s = mcp.stat

    return function(r)
        local res, timeout = rctx:enqueue_and_wait(r, near, wait)

        if timeout then
            s(S_NEAR_TIMEOUT, 1)
        end

        if res and res:ok() then
            return res
        end

        rctx:enqueue(r, far)

        rctx:wait_cond(#far, mcp.WAIT_OK, wait)

        for _, h in ipairs(all) do
            local res, mode = rctx:result(h)
            if res and res:ok() then
                return res
            end
        end

        -- couldn't find anything better than what we already had.
        return res
    end
end

function all_timeout_gen(rctx, arg)
    local near = arg.t[1]
    local far = { table.unpack(arg.t, 2) }
    local all = arg.t
    local wait = 0.05
    local s = mcp.stat

    return function(r)
        rctx:enqueue(r, all)

        local res, timeout = rctx:wait_handle(near, wait)
        --local res, timeout = rctx:wait_handle(near)
        if timeout then
            s(S_ALL_TIMEOUT, 1)
        end

        if res and res:ok() then
            return res
        end

        done, timeout = rctx:wait_cond(1, mcp.WAIT_GOOD, wait)
        --done, timeout = rctx:wait_cond(1, mcp.WAIT_GOOD)
        done = rctx:wait_cond(1, mcp.WAIT_GOOD)
        for _, h in ipairs(all) do
            local res, mode = rctx:result(h)
            if res and res:ok() then
                return res
            end
        end

        return res
    end
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
        return rctx:res_any(t[1])
    end
end

function fastgood_gen(rctx, arg)
    local t = arg.t
    local count = arg.c

    return function(r)
        rctx:enqueue(r, t)
        rctx:wait_cond(1, mcp.WAIT_FASTGOOD)
        for x=1,#t do
            local res = rctx:result(t[x])
            if res ~= nil then
                return res
            end
        end
        return "SERVER_ERROR no results found\r\n"
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

-- must pass 2 args
function onewait_gen(rctx, arg)
    local t = arg.t
    if arg.c ~= 2 then
        error("must pass two items to onewait_gen")
    end

    return function(r)
        rctx:enqueue(r, t)
        -- only actually wait on the first handle
        return rctx:wait_handle(t[1])
    end
end

function gc_gen(rctx, arg)
    return function(r)
        local k = r:key()
        if k == "/gc/collect" then
            collectgarbage("collect")
        end
        return "SERVER_ERROR garbage: " .. tostring(collectgarbage("count")) .. "\r\n"
    end
end

function mcp_config_routes(conf)
    local f_cluster = new_basic_factory({ list = { conf.cluster }, name = "cluster" }, direct_gen)
    local f_wcluster = new_basic_factory({ list = { conf.wcluster }, name = "wcluster" }, direct_gen)
    local f_ccluster = new_basic_factory({ list = { conf.ccluster }, name = "ccluster" }, direct_gen)
    local f_wccluster = new_basic_factory({ list = { conf.wccluster }, name = "wccluster" }, direct_gen)
    local f_zone = new_basic_factory({ list = { conf.z1, conf.z2, conf.z3 }, name = "zone" }, wait_all_gen)
    local f_wzone = new_basic_factory({ list = { conf.wz1, conf.wz2, conf.wz3 }, name = "wzone" }, wait_all_gen)
    local f_zonegood = new_basic_factory({ list = { conf.z1, conf.z2, conf.z3 }, name = "zonegood" }, fastgood_gen)
    local f_wzonegood = new_basic_factory({ list = { conf.wz1, conf.wz2, conf.wz3 }, name = "wzonegood" }, fastgood_gen)

    local f_neartimeout = new_basic_factory({ list = { conf.wz1r, conf.wz2r, conf.wz3r }, name = "neartimeout" }, near_timeout_gen)
    local f_alltimeout = new_basic_factory({ list = { conf.wz1, conf.wz2, conf.wz3 }, name = "alltimeout" }, all_timeout_gen)

    -- subrctx focused tests
    local f_subcluster = new_basic_factory({ list = { f_cluster }, name = "subcluster" }, direct_gen)
    local f_subwcluster = new_basic_factory({ list = { f_wcluster }, name = "subwcluster" }, direct_gen)
    -- split into both worker and io thread
    -- FIXME: this causes the IO thread to get behind, which causes infinite
    -- memory usage.
    --local f_onewaitwc = new_basic_factory({ list = { f_wcluster, f_cluster }, name = "onewaitwc" }, onewait_gen)
    local f_onewaitwc = new_basic_factory({ list = { f_wcluster, f_wcluster }, name = "onewaitwc" }, onewait_gen)
    local f_onewait = new_basic_factory({ list = { f_cluster, f_cluster }, name = "onewait" }, onewait_gen)
    -- get a subrctx that itself has an early return + late returns
    local f_onewaitfg = new_basic_factory({ list = { f_cluster, f_zonegood }, name = "onewait" }, onewait_gen)

    local map = {
        ["gc"] = new_basic_factory({ name = "gc" }, gc_gen),
        ["cluster"] = f_cluster,
        ["wcluster"] = f_wcluster,
        ["ccluster"] = f_ccluster,
        ["wccluster"] = f_wccluster,
        ["zone"] = f_zone,
        ["wzone"] = f_wzone,
        ["zonegood"] = f_zonegood,
        ["wzonegood"] = f_wzonegood,
        neartimeout = {
            [mcp.CMD_MG] = f_neartimeout,
            [mcp.CMD_MS] = f_alltimeout, -- wait_all for writes
        },
        ["subcluster"] = f_subcluster,
        ["subwcluster"] = f_subwcluster,
        ["onewaitwc"] = f_onewaitwc,
        ["onewait"] = f_onewait,
        ["onewaitfg"] = f_onewaitfg,
        ["internal"] = new_basic_factory({ name = "internal" }, internal_gen),
    }

    local default = new_basic_factory({ msg = "SERVER_ERROR no route\r\n" }, string_gen)

    mcp.attach(mcp.CMD_ANY_STORAGE, 
        mcp.router_new({ map = map, mode = "anchor", start = "/", stop = "/", default = default }))

end
