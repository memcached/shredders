--
-- PERFORMANCE RUNNERS --
--

local PERFRUN_HIST <const> = 1
local PERFRUN_TUSHIST <const> = 2 -- tens of us
local PERFRUN_HUSHIST <const> = 13 -- hundreds of us
local PERFRUN_MSHIST <const> = 24
local PERFRUN_OOB <const> = 125
local PERFRUN_END <const> = 125
perfrun_stats = {}

-- used to avoid any leftover data from corrupting the next test.
function perfrun_stats_clear()
    plog("PERFRUN", "clearing stats counters")
    perfrun_stats = nil
end

-- run one of these on each thread issuing performance tests. gathers the time
-- history once per second and ships it for summarization.
function perfrun_stats_out()
    local t = {"===start==="}

    for cmd, stats in pairs(perfrun_stats) do
        table.insert(t, cmd)
        table.insert(t, table.concat(stats, ","))

        -- zero out the stats instead of throwing away the table to reduce GC
        -- pressure, since we need to init them regardless.
        for i=1,PERFRUN_END do
            stats[i] = 0
        end
    end
    if #t == 1 then
        return -- nothing to send right now.
    end

    table.insert(t, "===end===")
    mcs.out(t)
end

local function get_percentile(stats, total, percentile)
    local sum = 0
    local target = (percentile/100) * total
    for i=1,#stats do
        sum = sum + stats[i]
        if sum > target then
            return i
        end
    end
end

-- run on separate stats thread. waits for data from test runner threads,
-- summarizes and prints.
function perfrun_stats_gather(a)
    local tcount = 0
    local lstats = {}
    -- TODO: note thread count.
    while true do
        mcs.out_wait()

        local rline = mcs.out_readline()
        if rline ~= "===start===" then
            error("expecting startline, got: " .. rline)
        end

        while true do
            -- first line is the command bucket.
            rline = mcs.out_readline()
            if rline == "===end===" then
                break
            end

            if lstats[rline] == nil then
                lstats[rline] = perfrun_init_bucket_cmd()
            end
            local s = lstats[rline]

            -- the next line is the histogram.

            rline = mcs.out_readline()
            local i = 1
            for num in string.gmatch(rline, '([^,]+)') do
                s[i] = s[i] + tonumber(num)
                i = i + 1
            end
        end

        tcount = tcount + 1

        if tcount == a.threads then
            -- seen all threads, dump data.
            tcount = 0
            -- FIXME: precalc the labels or do it differently :)
            local labels = {}
            for cmd, s in pairs(lstats) do
                local total = 0
                for i=1,PERFRUN_END do
                    total = total + s[i]
                end
                local p99 = get_percentile(s, total, 99)
                local p95 = get_percentile(s, total, 95)
                local p90 = get_percentile(s, total, 90)
                local p50 = get_percentile(s, total, 50)

                plog("TIMER", cmd)
                plog("TIME", "1us", s[PERFRUN_HIST])
                labels[PERFRUN_HIST] = "1us"
                for i=1,10 do
                    local c = s[PERFRUN_TUSHIST+i]
                    if c > 0 then
                        labels[PERFRUN_TUSHIST+i] = i .. "0us"
                        plog("TIME", i .. "0us", c,
                            string.format("%.2f%%", (c / total)*100))
                    end
                end
                for i=1,10 do
                    local c = s[PERFRUN_HUSHIST+i]
                    if c > 0 then
                        labels[PERFRUN_HUSHIST+i] = i .. "00us"
                        plog("TIME", i .. "00us", c,
                            string.format("%.2f%%", (c / total)*100))
                    end
                end
                for i=1,100 do
                    local c = s[PERFRUN_MSHIST+i]
                    if c > 0 then
                        labels[PERFRUN_MSHIST+i] = i .. "ms"
                        plog("TIME", i .. "ms", c,
                            string.format("%.2f%%", (c / total)*100))
                    end
                end
                if s[PERFRUN_OOB] ~= 0 then
                    labels[PERFRUN_OOB] = "100ms+"
                    plog("TIME", "100ms+:", s[PERFRUN_OOB],
                            string.format("%.2f%%", (s[PERFRUN_OOB] / total)*100))
                end
                plog("PERCENTILE", "50th", labels[p50])
                plog("PERCENTILE", "90th", labels[p90])
                plog("PERCENTILE", "95th", labels[p95])
                plog("PERCENTILE", "99th", labels[p99])
                plog("ENDTIMER")
            end

            -- reset local stats cache.
            lstats = {}

            if a.once then
                return
            end
        end
    end
end

-- TODO: maybe use an add_custom to clear the bucket once, so runners can
-- cache the global reference for a tiny speedup?
function perfrun_init()
    perfrun_stats = {}
end

function perfrun_init_bucket_cmd()
    local stats = {}
    for i=1,PERFRUN_END do
        table.insert(stats, 0)
    end

    return stats
end

function perfrun_bucket(cmd, time)
    local stats = perfrun_stats[cmd]
    local m = math
    if stats == nil then
        stats = perfrun_init_bucket_cmd()
        perfrun_stats[cmd] = stats
    end

    local bucket = m.floor(m.log(time, 10) + 1)

    if bucket > 5 then
        stats[PERFRUN_OOB] = stats[PERFRUN_OOB] + 1
    elseif bucket > 3 then
        -- per ms granulairty
        bucket = m.floor(time / 1000)
        stats[PERFRUN_MSHIST + bucket] = stats[PERFRUN_MSHIST + bucket] + 1
    elseif bucket == 3 then
        bucket = m.floor(time / 100)
        stats[PERFRUN_HUSHIST + bucket] = stats[PERFRUN_HUSHIST + bucket] + 1
    elseif bucket == 2 then
        bucket = m.floor(time / 10)
        stats[PERFRUN_TUSHIST + bucket] = stats[PERFRUN_TUSHIST + bucket] + 1
    else
        -- histogram for sub-ms
        stats[PERFRUN_HIST + bucket] = stats[PERFRUN_HIST + bucket] + 1
    end
end

function perfrun_metaget(a)
    local total_keys = a.limit
    local pfx = "perf/"
    if a.prefix then
        pfx = a.prefix
    end
    local res = mcs.res_new()
    local req = mcs.mg_factory(pfx, "v")
    -- NOTE: this ends up resetting the global values a bunch of times, but we
    -- need to ensure we do it once to clear any data from a previous run.
    -- All of the inits run before any actual test code so this is fine.
    perfrun_init()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(req, num)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(req, res)
        if not status then
            print("mismatched response: " .. num .. " GOT: " .. mcs.resline(res))
        end

        perfrun_bucket("mg", elapsed)
    end
end

function perfrun_metaget_pipe(a)
    local total_keys = a.limit
    local pipes = a.pipes
    local reqfacs = {}
    local results = {}
    local pfx = "perf/"
    if a.prefix then
        pfx = a.prefix
    end

    for i=1,pipes do
        table.insert(results, mcs.res_new())
        table.insert(reqfacs, mcs.mg_factory(pfx, "v"))
    end
    perfrun_init()

    return function()
        for i=1,pipes do
            local num = math.random(total_keys)
            mcs.write_factory(reqfacs[i], num)
        end
        mcs.flush()

        for i=1,pipes do
            local res = results[i]
            mcs.read(res)
            local status, elapsed = mcs.match(reqfacs[i], res)
            if not status then
                print("mismatched response: " .. i .. " GOT: " .. mcs.resline(res))
            end

            perfrun_bucket("mg", elapsed)
        end
    end
end

function perfrun_metaset(a)
    local total_keys = a.limit
    local size = a.vsize
    local pfx = "perf/"
    if a.prefix then
        pfx = a.prefix
    end
    local flags = ""
    if a.flags then
        flags = a.flags
    end
    local res = mcs.res_new()
    local req = mcs.ms_factory(pfx, flags)
    perfrun_init()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(req, num, size)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(req, res)
        if not status then
            print("mismatched response: " .. num .. " GOT: " .. mcs.resline(res))
        end

        perfrun_bucket("ms", elapsed)
    end
end

function perfrun_metacasset(a)
    local total_keys = a.limit
    local size = a.vsize
    local pfx = "perf/"
    if a.prefix then
        pfx = a.prefix
    end
    local res = mcs.res_new()
    --local req = mcs.ms_factory(pfx, "")
    local get_req = mcs.mg_factory(pfx, "c N30")
    local get_res = mcs.res_new()
    perfrun_init()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(get_req, num)
        mcs.flush()
        mcs.read(get_res)
        local has_cas, cas = mcs.res_flagtoken(get_res, "c")
        -- TODO: pass c -> C to the factory?
        -- Factory too simple to do it, have to do the same code as warmer.

        local set_req = mcs.ms(pfx, num, size, "C" .. cas)
        --mcs.write_factory(req, num, size)
        mcs.write(set_req)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(set_req, res)
        if not status then
            print("mismatched response: " .. num .. " GOT: " .. mcs.resline(res))
        end

        perfrun_bucket("ms", elapsed)
    end
end

--
-- END PERFORMANCE RUNNERS
--

