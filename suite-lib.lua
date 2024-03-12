--
-- WARMERS --
--

local FLUSH_AFTER <const> = 50000000
function perf_warm(a)
    local count = a.limit
    local size = a.vsize
    local prefix = a.prefix
    local written = 0
    local shuffle = a.shuffle
    local sleep = a.sleep
    local flush_after = FLUSH_AFTER
    if a.flush_after then
        flush_after = a.flush_after
    end

    local c = mcs.client_new({})
    if c == nil then
        plog("LOG", "ERROR", "warmer failed to connect to host")
        return
    end
    if mcs.client_connect(c) == false then
        plog("LOG", "ERROR", "warmer failed to connect")
        return
    end

    local numbers = {}
    if shuffle then
        for i=1,count do
            table.insert(numbers, i)
        end
        -- shuffle
        for i=#numbers, 2, -1 do
            local j = math.random(i)
            numbers[i], numbers[j] = numbers[j], numbers[i]
        end
    end

    for i=1,count do
        local num = i
        if shuffle then
            num = numbers[i]
        end
        local req = mcs.ms(prefix, num, size, "q")
        mcs.client_write(c, req)
        written = written + size
        if written > flush_after then
            mcs.client_flush(c)
            written = 0
            if sleep then
                mcs.sleep_millis(sleep)
            end
        end
        if math.floor(i % (count / 10)) == 0 then
            plog("LOG", "INFO", "warming pct", tostring(math.floor(i / count * 100)))
        end
    end

    mcs.client_write(c, "mn\r\n")
    mcs.client_flush(c)
    local res = mcs.res_new()
    -- TODO: bother validating MN? this doesn't fail here.
    mcs.client_read(c, res)
end

--
-- STATS DISPLAY
--

function _stat_sample(a)
    local stats = {}
    local res = mcs.res_new()

    if a.previous_stats == nil then
        a.previous_stats = {}
    end
    local previous_stats = a.previous_stats
    while true do
        mcs.read(res)
        if mcs.res_startswith(res, "END") then
            break
        end
        stats[mcs.res_statname(res)] = mcs.res_stat(res)
    end

    plog("NEWSTATS", "COUNT")
    for _, s in pairs(a["stats"]) do
        if previous_stats[s] ~= nil then
            local count = stats[s] - previous_stats[s]
            plog("STAT", s, count)
        end
    end
    plog("ENDSTATS")
    plog("NEWSTATS", "TRACK")
    for _, s in pairs(a["track"]) do
        if stats[s] ~= nil then
            plog("STAT", s, stats[s])
        end
    end
    plog("ENDSTATS")

    a.previous_stats = stats
end

function _stat_full(a)
    local stats = {}
    local res = mcs.res_new()
    plog("NEWSTATS", "TRACK")
    while true do
        mcs.read(res)
        if mcs.res_startswith(res, "END") then
            break
        end

        plog("STAT", mcs.res_statname(res), mcs.res_stat(res))
    end
    plog("END")
end

function proxy_stat_sample(a)
    mcs.write("stats proxy\r\n")
    mcs.flush()
    _stat_sample(a)
end

function proxyfuncs_stat_sample(a)
    mcs.write("stats proxyfuncs\r\n")
    mcs.flush()
    _stat_full(a)
end

function stat_sample(a)
    mcs.write("stats\r\n")
    mcs.flush()
    _stat_sample(a)
end

-- uses client mode so we can exit a shredder run when complete.
function full_stats(a)
    local subcmd = a.sub
    local c = mcs.client_new({})
    if c == nil then
        plog("LOG", "ERROR", "stats dumper failed to connect")
        return
    end
    if mcs.client_connect(c) == false then
        plog("LOG", "ERROR", "stats dumper failed to connect")
        return
    end

    if subcmd ~= nil then
        mcs.client_write(c, "stats " .. subcmd .. "\r\n")
    else
        mcs.client_write(c, "stats\r\n")
    end
    mcs.client_flush(c)

    local res = mcs.res_new()
    plog("FULLSTATS")
    while true do
        mcs.client_read(c, res)
        if mcs.res_startswith(res, "END") then
            break
        end
        plog("STAT", mcs.res_statname(res), mcs.res_stat(res))
    end
    plog("ENDSTATS")
end

--
-- STATISTICS --
--

-- we create some small canary values for this timer to fetch so tests with
-- bandwidth limits, large values, etc, aren't as skewed.
-- this latency sampler isn't meant to be for super detailed performance, but
-- to help characterize some performance and failures.
function timer_metaget(a)
    local prefix = a.prefix .. "canary"
    local req = mcs.mg_factory(prefix, "v")
    local res = mcs.res_new()

    return function()
        local num = math.random(50)
        mcs.write_factory(req, num)
        mcs.flush()

        mcs.read(res)

        local status, elapsed = mcs.match(req, res)
        -- TODO: split hit vs miss timing?
        local bucket = math.floor(math.log(elapsed, 10) + 1)
        -- sub-ms are bucketed logarithmically
        if bucket > 5 then
            timer_bounds = timer_bounds + 1
        elseif bucket > 3 then
            -- TODO: kill granularity but still bucket above 10ms
            bucket = math.floor(elapsed / 1000)
            timer_mshist[bucket] = timer_mshist[bucket] + 1
        else
            timer_hist[bucket] = timer_hist[bucket] + 1
        end
        --print("timer sample:", elapsed, bucket)

        if mcs.res_startswith(res, "EN") then
            local set = mcs.ms(prefix, num, 10)
            mcs.write(set)
            mcs.flush()
            mcs.read(res)
            -- TODO: this shouldn't fail, but we can still check the response.
        end
    end
end

-- uses globals to share data with timer funcs.
function timer_display(a)
    timer_hist = {}
    timer_mshist = {}
    timer_bounds = 0

    for i=1,3 do
        table.insert(timer_hist, 0)
    end

    for i=1,100 do
        table.insert(timer_mshist, 0)
    end

    -- TODO: use out func to print all at once.
    return function()
        plog("TIMER")
        plog("TIME", "1us", timer_hist[1])
        plog("TIME", "10us", timer_hist[2])
        plog("TIME", "100us", timer_hist[3])
        for i=1,100 do
            if timer_mshist[i] > 0 then
                plog("TIME", i .. "ms", timer_mshist[i])
            end
        end
        if timer_bounds ~= 0 then
            plog("TIME", "100ms+:", timer_bounds)
        end
        plog("ENDTIMER")

        for i=1,3 do
            timer_hist[i] = 0
        end

        for i=1,100 do
            timer_mshist[i] = 0
        end
        timer_bounds = 0
    end
end


