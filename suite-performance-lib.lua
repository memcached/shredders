--
-- PERFORMANCE RUNNERS --
--

local PERFRUN_HIST <const> = 1
local PERFRUN_MSHIST <const> = 2
local PERFRUN_OOB <const> = 3
perfrun_stats = {}

-- run one of these on each thread issuing performance tests. gathers the time
-- history once per second and ships it for summarization.
function perfrun_stats_out()
    local t = {"===start==="}

    for cmd, stats in pairs(perfrun_stats) do
        table.insert(t, cmd)
        local hist = stats[PERFRUN_HIST]
        table.insert(t, table.concat(hist, ","))
        local mshist = stats[PERFRUN_MSHIST]
        table.insert(t, table.concat(mshist, ","))
        table.insert(t, stats[PERFRUN_OOB])
    end
    if #t == 1 then
        return -- nothing to send right now.
    end

    table.insert(t, "===end===")
    mcs.out(t)

    -- TODO: zero out the stats instead of wipe them to cut memory churn
    -- slightly.
    perfrun_stats = {}
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

            -- the next line is us histogram
            -- the line after that is ms chart
            -- final line os OOB count

            rline = mcs.out_readline()
            local i = 1
            for num in string.gmatch(rline, '([^,]+)') do
                s[PERFRUN_HIST][i] = s[PERFRUN_HIST][i] + tonumber(num)
                i = i + 1
            end

            rline = mcs.out_readline()
            i = 1
            for num in string.gmatch(rline, '([^,]+)') do
                s[PERFRUN_MSHIST][i] = s[PERFRUN_MSHIST][i] + tonumber(num)
                i = i + 1
            end

            rline = mcs.out_readline()
            s[PERFRUN_OOB] = s[PERFRUN_OOB] + tonumber(rline)
        end

        tcount = tcount + 1

        if tcount == a.threads then
            -- seen all threads, dump data.
            tcount = 0
            for cmd, s in pairs(lstats) do
                local timer_hist = s[PERFRUN_HIST]
                local timer_mshist = s[PERFRUN_MSHIST]
                plog("TIMER", cmd)
                plog("TIME", "1us", timer_hist[1])
                plog("TIME", "10us", timer_hist[2])
                plog("TIME", "100us", timer_hist[3])
                for i=1,100 do
                    if timer_mshist[i] > 0 then
                        plog("TIME", i .. "ms", timer_mshist[i])
                    end
                end
                if s[PERFRUN_OOB] ~= 0 then
                    plog("TIME", "100ms+:", s[PERFRUN_OOB])
                end
                plog("ENDTIMER")
            end

            -- reset local stats cache.
            lstats = {}
        end
    end
end

-- TODO: maybe use an add_custom to clear the bucket once, so runners can
-- cache the global reference for a tiny speedup?
function perfrun_init()
    perfrun_stats = {}
end

function perfrun_init_bucket_cmd()
    local stats = { {}, {}, 0}
    -- seed this command bucket.
    for i=1,3 do
        table.insert(stats[PERFRUN_HIST], 0)
    end

    for i=1,100 do
        table.insert(stats[PERFRUN_MSHIST], 0)
    end
    return stats
end

function perfrun_bucket(cmd, time)
    local stats = perfrun_stats[cmd]
    if stats == nil then
        stats = perfrun_init_bucket_cmd()
        perfrun_stats[cmd] = stats
    end

    local bucket = math.floor(math.log(time, 10) + 1)

    if bucket > 5 then
        stats[PERFRUN_OOB] = stats[PERFRUN_OOB] + 1
    elseif bucket > 3 then
        -- per ms granulairty
        bucket = math.floor(time / 1000)
        stats[PERFRUN_MSHIST][bucket] = stats[PERFRUN_MSHIST][bucket] + 1
    else
        -- histogram for sub-ms
        stats[PERFRUN_HIST][bucket] = stats[PERFRUN_HIST][bucket] + 1
    end
end

function perfrun_metaget(a)
    local total_keys = a.limit
    local pfx = "perf"
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
    for i=1,pipes do
        table.insert(results, mcs.res_new())
        table.insert(reqfacs, mcs.mg_factory("perf", "v"))
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
                print("mismatched response: " .. num .. " GOT: " .. mcs.resline(res))
            end

            perfrun_bucket("mg", elapsed)
        end
    end
end

function perfrun_metaset(a)
    local total_keys = a.limit
    local size = a.vsize
    local res = mcs.res_new()
    local req = mcs.ms_factory("perf", "")
    perfrun_init()

    return function()
        local num = math.random(total_keys)
        mcs.write_factory(req, num, vsize)
        mcs.flush()

        mcs.read(res)
        local status, elapsed = mcs.match(req, res)
        if not status then
            print("mismatched response: " .. num .. " GOT: " .. mcs.resline(res))
        end

        perfrun_bucket("ms", elapsed)
    end
end

--
-- END PERFORMANCE RUNNERS
--

