require("nodes")

function mcp_config_pools()
    return mcp.pool(nodes_args({ connections = 4 }))
end

function mcp_config_routes(c)
    mcp.attach(mcp.CMD_ANY_STORAGE, function(r) return c(r) end)
end
