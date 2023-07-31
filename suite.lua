require("suite-util")
local test_s = require("suite-stability-tests")
local test_p = require("suite-performance-tests")

function help()
    local msg =[[
        time (30) (how long to run each sub test)
        threads (5) (number of mcshredder threads for test load)
        suite (nil) (override the test suite to run)
        keep (false) (whether ot leave memcached's running after stability test)
        backends (list) ('-' separated list of perf. test proxy configs to run)
        clients (list) ('-' separated list of perf. test client configs to run)
        set (list) ('-' separated list of stability test sets to run)
        pfx (list) ('-' separated list of stability proxy backend prefixes to run)
        test (list) ('-' separated list of stability sub-tests to run)

        see suite-*-.lua files for the various default lists.
    ]]
    print(msg)
end

function _split_arg(a)
    local t = {}
    for name in string.gmatch(a, '([^-]+)') do
        table.insert(t, name)
    end
    return t
end

function _split_arghash(a)
    local t = {}
    for name in string.gmatch(a, '([^-]+)') do
        t[name] = true
    end
    return t
end

function config(a)
    local o = {
        threads = 5,
        time = 30,
        keep = false, -- whether or not to leave mc running post-test.
    }
    if a["threads"] ~= nil then
        print("[init] overriding: test threadcount")
        o.threads = a.threads
    end
    if a["time"] ~= nil then
        print("[init] overriding: test time")
        o.time = tonumber(a.time)
    end
    if a["set"] ~= nil then
        print("[init] overriding: test set")
        o.set = _split_arghash(a["set"])
    end
    if a["pfx"] ~= nil then
        print("[init] overriding: test prefix")
        o.pfx = _split_arg(a["pfx"])
    end
    if a["test"] ~= nil then
        print("[init] overriding: test")
        o.test = _split_arghash(a["test"])
    end
    if a["keep"] ~= nil then
        print("[init] keeping memcached running post-test")
        o.keep = true
    end
    if a["backends"] ~= nil then
        print("[init] overriding performance backend list")
        o.backends = _split_arg(a["backends"])
    end
    if a["clients"] ~= nil then
        print("[init] overriding performance clients list")
        o.clients = _split_arg(a["clients"])
    end

    local threads = {}
    for i=1,o.threads do
        table.insert(threads, mcs.thread())
    end
    o["testthr"] = threads
    o["warmthr"] = mcs.thread()
    o["statsthr"] = mcs.thread()
    o["maintthr"] = mcs.thread()

    local suites = { suite_stability }

    if a["suite"] ~= nil then
        print("[init] overriding test suite: " .. a["suite"])
        _G["test_" .. a["suite"]](o)
    else
        test_stability(o)
        test_performance(o)
    end
end

--
-- TEST PLANS --
--

function test_p_start_datanodes()
    for i=1,3 do
        nodectrl("start mc-node" .. i .. " -m 6000 -t 3")
    end
end

function test_p_start_proxy(config)
    nodectrl("start mc-proxy -m 2000 -t 6 -o proxy_config=/home/ubuntu/conf/proxy-performance-" .. config .. ".lua")
    -- TODO: run a custom function that waits until the proxy is up, throws
    -- error if > 2 seconds.
    os.execute("sleep 2")
end

function test_p_stop_proxy()
    nodectrl("stop mc-proxy")
    os.execute("sleep 8")
end

function test_p_flush_datanodes(thread)
    local nodes = nodeips()
    for i=1,3 do
        -- FIXME: the original blank arg / non-existent func caused a segfault.
        mcs.add_custom(thread, { func = "node_flush_all" }, { host = nodes[i], port = 11211 })
    end
    mcs.shredder({thread})
end

function test_p_warm(thread, client)
    print("=== warming ===")
    local c = test_p.tests[client].w
    if c == nil or #c == 0 then
        -- allow empty lists to skip any warming.
        return
    end
    for _, conf in ipairs(c) do
        mcs.add_custom(thread, { func = "warm" }, conf)
    end
    mcs.shredder({thread})
end

-- TODO: method for overriding ramp
function test_p_run_test(o, client)
    local testthr = o.testthr
    local statthr = o.statsthr

    -- TODO: really need to make add auto-track threads.
    local allthr = {statthr}
    for _, t in ipairs(testthr) do
        table.insert(allthr, t)
    end

    local stats_arg = { stats = { "cmd_mg", "cmd_ms", "cmd_md", "cmd_get", "cmd_set" }, track = {} }

    local test = test_p.tests[client]
    -- copy the argument table since we modify it at runtime.
    -- want to do this better but it does complicate the code a lot...
    local a = shallow_copy(test.a)

    while true do
        print("+++ rate, clients:", a.rate, a.cli, "+++")
        test.t(testthr, a)
        -- one set of funcs on each test thread that ships history
        -- one func that reads the history and summarizes every second.
        mcs.add(testthr, { func = "perfrun_stats_out", rate_limit = 1, clients = 1 })
        mcs.add_custom(statthr, { func = "perfrun_stats_gather" }, { threads = o.threads })
        mcs.add(statthr, { func = "proxy_stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
        -- TODO: give the ctx a true/false return via a command.
        mcs.shredder(allthr, o.time)

        local rate = test.r(a)
        if rate > a.cap then
            break
        end
    end
end

function test_performance(o)
    if o.backends then
        test_p.backends = o.backends
    end
    if o.clients then
        test_p.clients = o.clients
    end

    test_p_start_datanodes()
    for _, tbackend in ipairs(test_p.backends) do
        test_p_start_proxy(tbackend)
        for _, tclient in ipairs(test_p.clients) do
            -- run test
            print("+++ test " .. tbackend .. "_" .. tclient .. " +++")
            test_p_warm(o.warmthr, tclient)
            test_p_run_test(o, tclient)
            test_p_flush_datanodes(o.maintthr)
        end
        test_p_stop_proxy()
    end
end

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
                print("=== timer " .. cmd .. " ===")
                print("1us", timer_hist[1])
                print("10us", timer_hist[2])
                print("100us", timer_hist[3])
                for i=1,100 do
                    if timer_mshist[i] > 0 then
                        print(i .. "ms", timer_mshist[i])
                    end
                end
                if s[PERFRUN_OOB] ~= 0 then
                    print("100ms+:", s[PERFRUN_OOB])
                end
                print("=== end ===")
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
    local res = mcs.res_new()
    local req = mcs.mg_factory("perf", "v")
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

-- run through a series of full-load test scenarios
function test_stability(o)
    local warm = o["warmthr"]
    local test = o["testthr"]
    local stats = o["statsthr"]
    local maint = o["maintthr"]
    local pfx = "main"
    local time = o["time"]

    -- FIXME: should mcs.shredder just implicitly run all threads seen with
    -- mcs.add()?
    -- following block is awkward.
    local thr = {stats, maint}
    for _, t in ipairs(test) do
        table.insert(thr, t)
    end

    local timer_conf = { func = "timer_metaget", clients = 8, rate_limit = 500, init = true }
    local timer_display = { func = "timer_display", clients = 1, rate_limit = 1, init = true }
    local stat_conf = { func = "proxy_stat_sample", clients = 1, rate_limit = 1 }
    local stat_arg = { stats = { "cmd_mg", "cmd_ms", "cmd_md", "cmd_get", "cmd_set" },
        track = { "active_req_limit", "buffer_memory_limit", "buffer_memory_used" } }

    local go_test = function(args)
        mcs.add(stats, timer_display)
        mcs.add(stats, timer_conf, args)
        mcs.add(stats, stat_conf, stat_arg)
        mcs.shredder(thr, time)
    end

    -- run the suite set once for each listed prefix.
    local suite_sets = test_s.sets

    -- override test sets.
    if o.set then
        -- copy the prefix lists from the original sets.
        local ns = {}
        for i, v in ipairs(suite_sets) do
            if o.set[v[1]] then
                print("override test set:", v[1])
                table.insert(ns, v)
            end
        end
        suite_sets = ns
    end

    if o.pfx then
        -- force prefix list onto all test suites
        for _, v in ipairs(suite_sets) do
            v[2] = o.pfx
        end
    end

    if o.test then
        -- filter the test list.
        -- yes this mutates the structure.. but we run through once and exit
        -- I like this better than adding another filter argument and
        -- complicating the main loop.
        local nt = {}
        for k, v in pairs(o.test) do
            print("K/V:", k, v)
        end
        for _, v in ipairs(test_s.tests) do
            if o.test[v["n"]] then
                print("override test:", v["n"])
                table.insert(nt, v)
            end
        end
        test_s.tests = nt
    end

    -- Start mc on all nodes
    local mc_args = " -m 6000 -t 2"
    for i=1,3 do
        nodectrl("startdbg mc-node" .. i .. mc_args)
    end
    -- start proxy node with config
    nodectrl("startdbg mc-proxy -m 2000 -t 6 -o proxy_config=/home/ubuntu/conf/proxy-stability.lua")
    os.execute("sleep 1") -- let the daemon start and listen.

    -- NOTE: don't like this.
    local threads = { t = test, s = stats, m = maint, w = warm }
    run_stability_tests(test_s.tests, suite_sets, threads, go_test)
    if not o.keep then
        for i=1,3 do
            nodectrl("stop mc-node" .. i)
        end
        nodectrl("stop mc-proxy")
    end
end

function run_stability_tests(tests, sets, threads, go_test)
    for _, suiteset in ipairs(sets) do
        local suite = suiteset[1]
        local pfxlist = suiteset[2]

        for _, pfx in ipairs(pfxlist) do
            local prefix = string.format("/%s/", pfx)
            local warmers_run = {} -- track which warmers have been run already

            for _, test in ipairs(tests) do
                local n = test["n"]
                local p = test["p"]
                if p == suite then
                    if warmers_run[p] == nil then
                        print("warming: " .. p .. "_" .. pfx)
                        test["w"](prefix, threads)
                        print("...warm complete")
                        warmers_run[p] = true
                    end

                    print("=== test ===", suite .. "_" .. pfx .. "_" .. n)
                    local args = test.a
                    args["prefix"] = prefix
                    if test["s"] then
                        test["f"](test.a, threads, go_test)
                    else
                        test["f"](test.a, threads)
                        go_test(args)
                    end -- if test
                end -- if p == suite
            end -- for tests

        end
    end
end

--
-- WARMERS --
--

local FLUSH_AFTER <const> = 50000000
function warm(a)
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
        print("=== timer ===")
        print("1us", timer_hist[1])
        print("10us", timer_hist[2])
        print("100us", timer_hist[3])
        for i=1,100 do
            if timer_mshist[i] > 0 then
                print(i .. "ms", timer_mshist[i])
            end
        end
        if timer_bounds ~= 0 then
            print("100ms+:", timer_bounds)
        end
        print("=== end ===")

        for i=1,3 do
            timer_hist[i] = 0
        end

        for i=1,100 do
            timer_mshist[i] = 0
        end
        timer_bounds = 0
    end
end

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

    for _, s in pairs(a["stats"]) do
        if previous_stats[s] ~= nil then
            local count = stats[s] - previous_stats[s]
            print("stat:", s, ": ", count)
        end
    end
    for _, s in pairs(a["track"]) do
        if stats[s] ~= nil then
            print("stat:", s, ": ", stats[s])
        end
    end

    a.previous_stats = stats
end

function proxy_stat_sample(a)
    mcs.write("stats proxy\r\n")
    mcs.flush()
    _stat_sample(a)
end

function stat_sample(a)
    mcs.write("stats\r\n")
    mcs.flush()
    _stat_sample(a)
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
        if line == false then
            print("watcher disconnected")
            return
        else
            print("watcher:", line)
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

function shallow_copy(a)
    local c = {}
    for key, val in pairs(a) do
        c[key] = val
    end
    return c
end
