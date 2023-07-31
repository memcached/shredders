require("nodes")

function mcp_config_pools()
    local nodes = nodes_flat()
    local pools = {}
    for _, n in pairs(nodes) do
        table.insert(pools, mcp.pool({n}, { iothread = false }))
    end
    return pools
end

function mcp_config_routes(p)
    mcp.attach(mcp.CMD_MG, function(r)
        local res = mcp.await(r, p, mcp.AWAIT_FASTGOOD)
        return res[1]
    end)
    mcp.attach(mcp.CMD_MS, function(r)
        local res = mcp.await(r, p)
        return res[1]
    end)
end
