require("nodes")

-- use worker IO for get path
-- background IO for set path
function mcp_config_pools()
    local nodes = nodes_flat()
    local getpools = {}
    local setpools = {}
    for _, n in pairs(nodes) do
        table.insert(getpools, mcp.pool({n}, { beprefix = "get", iothread = false }))
    end
    for _, n in pairs(nodes) do
        table.insert(setpools, mcp.pool({n}, { beprefix = "set" }))
    end

    return { getpools, setpools }
end

function mcp_config_routes(p)
    local getpools = p[1]
    local setpools = p[2]

    mcp.attach(mcp.CMD_MG, function(r)
        local res = mcp.await(r, getpools, mcp.AWAIT_FASTGOOD)
        return res[1]
    end)
    mcp.attach(mcp.CMD_MS, function(r)
        local res = mcp.await(r, setpools)
        return res[1]
    end)
end
