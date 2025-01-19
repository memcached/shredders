require("nodes")

-- TODO: do quick tests with/without connections override
function mcp_config_pools()
    return mcp.pool(nodes_args({ connections = 4 }), { iothread = true })
end

function mcp_config_routes(c)
    local fg = mcp.funcgen_new()
    local ch = fg:new_handle(c)

    fg:ready({ n = "main", f = function(rctx)
        return function(r)
            return rctx:enqueue_and_wait(r, ch)
        end
    end})

    mcp.attach(mcp.CMD_ANY_STORAGE, fg)
end
