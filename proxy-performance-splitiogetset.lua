require("nodes")

function mcp_config_pools()
    local c = {}
    c["mg"] = mcp.pool(nodes_args({}), { beprefix = "get", iothread = false })
    c["ms"] = mcp.pool(nodes_args({}), { beprefix = "set" })
    return c
end

function mcp_config_routes(c)
    local mg = c.mg
    local ms = c.ms
    mcp.attach(mcp.CMD_MG, function(r) return mg(r) end)
    mcp.attach(mcp.CMD_MS, function(r) return ms(r) end)
end
