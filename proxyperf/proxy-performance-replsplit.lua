require("nodes")

-- use worker IO for get path
-- background IO for set path
function mcp_config_pools()
    local nodes = nodes_flat()
    local getpools = {}
    local setpools = {}
    for _, n in pairs(nodes) do
        table.insert(getpools, mcp.pool({n}, { beprefix = "get" }))
    end
    for _, n in pairs(nodes) do
        table.insert(setpools, mcp.pool({n}, { beprefix = "set", iothread = true }))
    end

    return { getpools, setpools }
end

function mcp_config_routes(p)
    local getpools = p[1]
    local setpools = p[2]

    local mgfg = mcp.funcgen_new()
    local mgfg_p = {}
    for _, v in pairs(getpools) do
        table.insert(mgfg_p, mgfg:new_handle(v))
    end

    mgfg:ready({ n = "mg", f = function(rctx)
        return function(r)
            rctx:enqueue(r, mgfg_p)
            rctx:wait_cond(1, mcp.WAIT_FASTGOOD)

            local res, mode
            for _, h in ipairs(mgfg_p) do
                res, mode = rctx:result(h)
                if mode == mcp.WAIT_GOOD then
                    return res
                end
            end
            return res
        end
    end})

    local msfg = mcp.funcgen_new()
    local msfg_p = {}
    for _, v in pairs(setpools) do
        table.insert(msfg_p, msfg:new_handle(v))
    end

    msfg:ready({ n = "ms", f = function(rctx)
        return function(r)
            rctx:enqueue(r, msfg_p)
            rctx:wait_cond(#msfg_p, mcp.WAIT_ANY)

            local res, mode
            for _, h in ipairs(msfg_p) do
                res, mode = rctx:result(h)
                if mode == mcp.WAIT_OK then
                    return res
                end
            end
            return res
        end
    end})

    mcp.attach(mcp.CMD_MG, mgfg)
    mcp.attach(mcp.CMD_MG, msfg)

end
