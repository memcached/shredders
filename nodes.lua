local NODE_IPS = { '10.191.24.56', '10.191.24.4', '10.191.24.178' }
local PORT = 11211

-- return nodes in a routelib format
function nodes_rlib()
    local b = {}
    for i=1,3 do
        local ip = NODE_IPS[i]
        table.insert(b, {
            host = ip,
            port = PORT,
        })
    end
    return b
end

function node_rlib(i)
    local b = {}
    local ip = NODE_IPS[i]
    b.host = ip
    b.port = PORT
    return b
end

function nodes_flat()
    local srv = mcp.backend
    local b = {}
    for i=1,3 do
        table.insert(b, srv('b' .. i, NODE_IPS[i], PORT))
    end
    return b
end

-- generate the list of backends N times.
function nodes_n(copies)
    local srv = mcp.backend
    local b = {}
    for x=1,copies do
        for i=1,3 do
            table.insert(b, srv('b' .. x .. '-' .. i, NODE_IPS[i], PORT))
        end
    end
    return b
end

function nodes_args(a)
    local srv = mcp.backend
    local b = {}
    for i=1,3 do
        a.label = 'b' .. i
        a.host = NODE_IPS[i]
        a.port = PORT
        table.insert(b, srv(a))
    end
    return b
end
