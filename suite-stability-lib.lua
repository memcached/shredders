--
-- WARMERS --
--

local FLUSH_AFTER <const> = 50000000
function stability_warm(a)
    local count = a.limit
    local size = a.vsize
    local prefix = a.prefix
    local written = 0
    local c = mcs.client_new({})
    if c == nil then
        print("ERROR: warmer failed to connect to host")
        return
    end
    if mcs.client_connect(c) == false then
        print("ERROR: warmer failed to connect")
        return
    end

    for i=1,count do
        local req = mcs.ms(prefix, i, size, "q")
        mcs.client_write(c, req)
        written = written + size
        if written > FLUSH_AFTER then
            plog("WARMER", written)
            mcs.client_flush(c)
            written = 0
        end
    end

    mcs.client_write(c, "mn\r\n")
    mcs.client_flush(c)
    local res = mcs.res_new()
    -- TODO: bother validating MN? this doesn't fail here.
    mcs.client_read(c, res)
end

--
-- RUNNERS --
--

-- TODO: pipelined versions of get and set?
-- flags as arg?
function runner_metaget(a)
    local prefix = a.prefix
    local total_keys = a.total_keys
    local req = mcs.mg_factory(a.prefix, "v k")
    local res = mcs.res_new()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(req, num)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(req, res)
        if not status then
            local key = a["prefix"] .. num
            print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
        end
    end
end

function runner_metaset(a)
    local num = math.random(a["total_keys"])
    local req = mcs.ms(a["prefix"], num, a["vsize"], "T" .. a["ttl"])
    mcs.write(req)
    mcs.flush()

    local res = mcs.res_new()
    mcs.read(res)
    local status, elapsed = mcs.match(req, res)
    if not status then
        local key = a["prefix"] .. num
        print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
    end
end

function runner_metadelete(a)
    local prefix = a.prefix
    local total_keys = a.total_keys
    local req = mcs.md_factory(a.prefix)
    local res = mcs.res_new()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(req, num)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(req, res)
        if not status then
            local key = a["prefix"] .. num
            print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
        end
    end
end

function runner_metaset_variable(a)
    local num = math.random(a["total_keys"])
    local size = math.random(a["sizemin"], a["sizemax"])
    local req = mcs.ms(a["prefix"], num, size, "T" .. a["ttl"])
    mcs.write(req)
    mcs.flush()

    local res = mcs.res_new()
    mcs.read(res)
    local status, elapsed = mcs.match(req, res)
    if not status then
        local key = a["prefix"] .. num
        print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
    end
end

function runner_metabasic_variable(a)
    local num = math.random(a["total_keys"])
    local req = mcs.mg(a["prefix"], num, "v")
    mcs.write(req)
    mcs.flush()

    local res = mcs.res_new()
    mcs.read(res)
    if mcs.res_startswith(res, "EN") then
        local size = math.random(a["sizemin"], a["sizemax"])
        local set = mcs.ms(a["prefix"], num, size, "T" .. a["ttl"])
        mcs.write(set)
        mcs.flush()
        mcs.read(res)
        -- TODO: match res
    else
        local status, elapsed = mcs.match(req, res)
        if not status then
            local key = a["prefix"] .. num
            print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
        end
    end
end

-- TODO: if we get back SERVER_ERROR this will continue to mcs.read() and
-- hang.
-- mcs.match should probably throw a false on SERVER_ERROR.
function runner_basic(a)
    local num = math.random(a["total_keys"])
    local req = mcs.get(a["prefix"], num)
    mcs.write(req)
    mcs.flush()

    local res = mcs.res_new()
    mcs.read(res)
    if mcs.res_startswith(res, "END") then
        local set = mcs.set(a["prefix"], num, 0, a["ttl"], a["vsize"])
        mcs.write(set)
        mcs.flush()
        mcs.read(res)
    else
        local status, elapsed = mcs.match(req, res)
        if not status then
            local key = prefix .. num
            print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
        end
        -- pull the END
        mcs.read(res)
        if not mcs.res_startswith(res, "END") then
            print("EXPECTED END, GOT: " .. mcs.resline(res))
        end
    end
end

function runner_basicpipe(a)
    local keys = {}
    local nums = {}
    local prefix = a["prefix"]
    for i=1,a["pipelines"] do
        local num = math.random(a["total_keys"])
        local req = mcs.get(prefix, num)
        table.insert(keys, req)
        table.insert(nums, num)
        mcs.write(req)
    end
    mcs.flush()

    local misses = {}
    local res = mcs.res_new()
    -- FIXME: need to get the num/key back out of a req to convert it to a set?
    -- just make a lib function to turn get-req into a set?
    for i=1,a["pipelines"] do
        mcs.read(res)
        local req = keys[i]
        if mcs.res_startswith(res, "END") then
            local set = mcs.set(prefix, nums[i], 0, a["ttl"], a["vsize"])
            table.insert(misses, set)
        else
            local status, elapsed = mcs.match(req, res)
            if not status then
                local key = prefix .. nums[i]
                print("mismatched response: " .. key .. " GOT: " .. mcs.resline(res))
            end
            -- pull the END
            mcs.read(res)
            if not mcs.res_startswith(res, "END") then
                print("EXPECTED END, GOT: " .. mcs.resline(res))
            end
        end

    end

    -- write out misses table.
    for _, set in ipairs(misses) do
        mcs.write(set)
        mcs.flush()
        mcs.read(res)
        -- TODO: match validation.
    end
end

function runner_batchmetadelete(a)
    for i=1,a["pipelines"] do
        local num = math.random(a["total_keys"])
        -- FIXME: there's a func now I think?
        mcs.write("md " .. a["prefix"] .. num .. " q O" .. i .. "\r\n")
    end
    mcs.write("mn\r\n")
    mcs.flush()

    local res = mcs.res_new()
    while true do
        mcs.read(res)
        -- TODO: mcs.match
        --print("del res: " .. mcs.resline(res))
        if mcs.res_startswith(res, "MN") then
            -- got all of the responses
            return
        end
    end
end

-- TODO: check keys returned match the inputs
-- note there can be gaps for misses
function runner_multiget(a)
    mcs.write("get")
    for i=1,a["pipelines"] do
        local num = math.random(a["total_keys"])
        mcs.write(" " .. a["prefix"] .. num)
    end
    mcs.write("\r\n")
    mcs.flush()

    local res = mcs.res_new()
    while true do
        mcs.read(res)
        if mcs.res_startswith(res, "END") then
            -- got all of the responses
            return
        end
    end
end

--
-- LOGS
--

-- TODO: validate how this is force-stopped.
function runner_watcher(a)
    -- defaults to global client host/port
    local c = mcs.client_new({})
    if c == nil then
        -- TODO: use real lua errors? need to test for aborts/etc.
        print("ERROR: runner_watcher failed to connect to host")
        return
    end
    if mcs.client_connect(c) == false then
        print("ERROR: runner_watcher failed to connect")
    end

    mcs.client_write(c, "watch " .. a.watchers .. "\r\n")
    mcs.client_flush(c)

    while true do
        local line = mcs.client_readline(c)
        if line == false or line == nil then
            print("watcher disconnected")
            return
        else
            plog("WATCHER", line)
        end
    end
end

--
-- MISC
--

-- TODO: bother checking for errors.
function node_flush_all(a)
    local c = mcs.client_new(a)
    mcs.client_connect(c)

    mcs.client_write(c, "flush_all\r\n")
    mcs.client_flush(c)
    local rline = mcs.client_readline(c)
    if rline ~= "OK" then
        error("Bad response to flush_all: " .. rline)
    end

    while true do
        mcs.client_write(c, "lru_crawler crawl all\r\n")
        mcs.client_flush(c)
        local rline = mcs.client_readline(c)
        if rline == "OK" then
            break
        end
        mcs.sleep_millis(250)
    end
    -- TODO: check stats for lru_crawler_running 0
    -- should normally complete sub-second.
    mcs.sleep_millis(2000)
end

function runner_reload(a)
    nodectrl("reload mc-proxy")
end

function runner_delay(a)
    local node = a.node
    print("delay:", a._c)
    if a._c == 0 then
        nodectrl("delay " .. a.node .. " " .. a.delay)
        a._c = 1
    else
        nodectrl("clear " .. a.node)
        a._c = 0
    end
end

function runner_ploss(a)
    local node = a.node
    print("ploss:", a._c)
    if a._c == 0 then
        nodectrl("ploss " .. a.node .. " " .. a.ploss)
        a._c = 1
    else
        nodectrl("clear " .. a.node)
        a._c = 0
    end
end

function runner_block(a)
    local node = a.node
    print("block:", a._c)
    if a._c == 0 then
        nodectrl("block " .. a.node)
        a._c = 1
    else
        nodectrl("unblock " .. a.node)
        a._c = 0
    end
end
