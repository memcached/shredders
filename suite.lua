require("suite-util")
require("suite-lib")
require("suite-performance-lib")
require("suite-stability-lib")
local test_s = require("suite-stability-tests")
local test_p = require("suite-performance-tests")
local test_ext = require("suite-extstore-tests")

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
    if a["extset"] ~= nil then
        -- hope I can refactor these into a shared pattern soon...
        print("[init] overriding extstore test list")
        o.extset = _split_arg(a["extset"])
    end

    local threads = {}
    for i=1,o.threads do
        table.insert(threads, mcs.thread())
    end
    o["testthr"] = threads
    o["warmthr"] = mcs.thread()
    o["statsthr"] = mcs.thread()
    o["maintthr"] = mcs.thread()

    if a.suite == nil then
        error("must specify a suite to run")
    end
    test_run_suite(a.suite, o)
end

--
-- GENERIC TEST RUNNER
--

local function ts_advance_test(tstack)
    local top = tstack[#tstack]
    if not top then
        -- stack empty: processed everything.
        return false
    end

    -- iterate the variant if we're not currently looping the test.
    plog("DEBUG", "ts:advance() -> before top.v")
    if not top.__ti and top.v then
        if top.__vi then
            top.__vi = top.__vi + 1
        else
            top.__vi = 1
        end

        local nv = top.v[top.__vi]
        if nv then
            -- accessory name for the variant
            if top.vn then
                -- FIXME: add a prefix?
                top[top.vn] = nv
            end
        else
            -- no more variants, pop and recurse.
            top.__vi = nil
            table.remove(tstack)
            return tstack:advance()
        end
    end
    plog("DEBUG", "ts:advance() -> after top.v")

    plog("DEBUG", "ts:advance() -> before top.t")
    if top.t then
        if top.__ti then
            top.__ti = top.__ti + 1
        else
            top.__ti = 1
        end
        plog("DEBUG", "top ti", top.__ti)

        local nt = top.t[top.__ti]
        if nt then
            -- we have another test to run, recurse into it.
            table.insert(tstack, nt)
            return tstack:advance()
        else
            -- out of things to iterate.
            top.__ti = nil -- reset the test iterator
            if top.v then
                -- we might be running a variant: leave the tstack alone and
                -- call self to check the variant.
                return tstack:advance()
            else
                -- nothing to iterate. pop and advance.
                table.remove(tstack)
                return tstack:advance()
            end
        end
    end
    plog("DEBUG", "ts:advance() -> past top.t")

    -- test has a function to execute, return true.
    if top.f then
        return true
    else
        -- we've possibly walked back upwards to a point where there's no test
        -- function, so we still stop processin ghere.
        return false
    end
end

local function ts_pop(tstack)
    table.remove(tstack)
end

local function ts_find(tstack, key)
    for i=#tstack, 0, -1 do
        local v = rawget(tstack[i], key)
        if v then
            return v
        end
    end
end

-- TODO: mcshredder methods for testing when ports become alive/etc.
local function test_daemon_startup(start, stop)
    if stop ~= nil then
        plog("LOG", "INFO", "stopping previous test daemon")
        if type(stop) == "string" then
            nodectrl(stop)
            os.execute("sleep 8")
        else
            stop()
        end
    end

    plog("LOG", "INFO", "starting next test daemon")
    if type(start) == "string" then
        nodectrl(start)
        os.execute("sleep 2")
    else
        start()
    end
end

local function ts_name(tstack)
    local n = {}
    for _, t in ipairs(tstack) do
        if t.n then
            table.insert(n, t.n)
        end
        if t.vn then
            table.insert(n, t[t.vn])
        end
    end
    return table.concat(n, "_")
end

-- TODO: allow dynamic path prefix via name?
local function test_warm(thread, c)
    if c == nil or #c == 0 then
        plog("LOG", "INFO", "warming skipped")
        return
    end
    plog("LOG", "INFO", "warming")
    for _, conf in ipairs(c) do
        mcs.add_custom(thread, { func = conf[1] }, conf[2])
    end
    mcs.shredder({thread})
    plog("LOG", "INFO", "warming end")
end

local function test_wrapper_new(o, tstack)
    local d = {
        stats = {},
        maint = {},
        warm  = {},
        work  = {}
    }

    local setup = function(all, thr, confs)
        if #confs then
            for _, a in ipairs(confs) do
                mcs.add(thr, a[1], a[2])
            end
            if type(thr) == "userdata" then
                table.insert(all, thr)
            else
                for _, v in pairs(thr) do
                    table.insert(all, v)
                end
            end
        end
    end

    local w = {
        stats = function(self, conf, args)
            table.insert(d.stats, {conf, args})
        end,
        maint = function(self, conf, args)
            table.insert(d.maint, {conf, args})
        end,
        warm = function(self, conf, args)
            table.insert(d.warm, {conf, args})
        end,
        work = function(self, conf, args)
            table.insert(d.work, {conf, args})
        end,
        shred = function(self, time)
            if time == nil then
                time = o.time
            end
            local all = {}
            -- gather any activated threads together.
            -- needed to actually execute a shred.
            setup(all, o.statsthr, d.stats)
            setup(all, o.maintthr, d.maint)
            setup(all, o.warmthr, d.warm)
            setup(all, o.testthr, d.work)
            mcs.shredder(all, time)
            -- always wipe config stack for main test threads.
            d.work = {}
        end,
        pending = function(self)
            if #d.work > 0 then
                return true
            end
            return false
        end,
        key = function(self, k)
            return tstack:find(k)
        end,
    }

    w.__index = w
    return setmetatable({}, w)
end

function test_run_suite(suite, o)
    -- TODO: some smarts for where to look
    -- expect users to have symlinks for external tests
    local top = dofile("./" .. suite .. "/tests.lua")

    local tstack = {top}
    local mt = {advance = ts_advance_test,
        find = ts_find,
        name = ts_name,
        pop = ts_pop,
    }
    mt.__index = mt
    setmetatable(tstack, mt)

    local start = nil
    local stop = nil
    local warm = nil
    -- loop while tests exist to run.
    while tstack:advance() do
        local next_start = tstack:find("s")
        if next_start ~= start then
            local next_stop = tstack:find("e")
            if next_stop == nil then
                error("test must specify .e for ending a test")
            end
            test_daemon_startup(next_start, stop)
            start = next_start
            stop = next_stop
        end

        local runner = test_wrapper_new(o, tstack)
        local warmers = tstack:find("w")
        if type(warmers) == "function" then
            test_warm(o.warmthr, warmers(runner))
        elseif warm ~= warmers then
            test_warm(o.warmthr, warmers)
        else
            plog("LOG", "INFO", "pre-warmed")
        end

        local f = tstack:find("f")
        plog("START", tstack:name())
        f(runner)
        if runner:pending() then
            plog("DEBUG", "running shred from pending work")
            runner:shred()
        end
        tstack:pop()
    end

    if not o.keep and stop then
        if type(stop) == "string" then
            nodectrl(stop)
            os.execute("sleep 8")
        else
            stop()
        end
    end
end

--
-- extstore test runner
--

-- most code inherited/modified from the performance runner.
function test_ext_start(config)
    -- let the config define all of the arguments.
    -- for some extstore tests we want to try less/more RAM, threads, etc.
    nodectrl("start mc-extstore " .. config.s)
    os.execute("sleep 2")
end

function test_ext_stop()
    nodectrl("stop mc-extstore")
    os.execute("sleep 8")
end

function test_ext_warm(thread, client)
    local c = client
    if c == nil or #c == 0 then
        -- allow empty lists to skip any warming.
        plog("LOG", "INFO", "warming skipped")
        return
    end
    plog("LOG", "INFO", "warming")
    for _, conf in ipairs(c) do
        mcs.add_custom(thread, { func = "perf_warm" }, conf)
    end
    mcs.shredder({thread})
    plog("LOG", "INFO", "warming end")
end

-- for extstore tests we pass the warm thread back into the main workload
-- so we can make single threaded "writer" threads to emulate certain load
-- patterns and to allow repeatable data loading in general.
function test_ext_run_test(o, test)
    local testthr = o.testthr
    local statthr = o.statsthr
    local warmthr = o.warmthr

    -- TODO: really need to make add auto-track threads.
    local allthr = {statthr, warmthr}
    for _, t in ipairs(testthr) do
        table.insert(allthr, t)
    end

    local stats_arg = { stats = { "cmd_get", "cmd_set", "extstore_bytes_read", "extstore_objects_read", "extstore_objects_written" }, track = { "extstore_bytes_written", "extstore_bytes_fragmented", "extstore_bytes_used", "extstore_io_queue", "extstore_page_allocs", "extstore_page_reclaims", "extstore_page_evictions", "extstore_pages_free", "evictions" } }

    -- copy the argument table since we modify it at runtime.
    -- want to do this better but it does complicate the code a lot...
    local a = shallow_copy(test.a)

    test.t(testthr, warmthr, a)
    -- one set of funcs on each test thread that ships history
    -- one func that reads the history and summarizes every second.
    mcs.add(testthr, { func = "perfrun_stats_out", rate_limit = 1, clients = 1 })
    mcs.add_custom(statthr, { func = "perfrun_stats_gather" }, { threads = o.threads })
    -- specifically for tracking 'stats' counters
    mcs.add(statthr, { func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
    -- TODO: give the ctx a true/false return via a command.
    mcs.shredder(allthr, o.time)

    -- grab stats snapshot before the server is stopped
    mcs.add_custom(statthr, { func = "full_stats" }, {})
    mcs.shredder({statthr})
end

function test_extstore(o)
    if o.extset then
        test_ext.testset = o.extset
    end

    for _, tconfig in ipairs(test_ext.testset) do
        local t = test_ext.tests[tconfig]
        test_ext_start(t)
        -- run test
        plog("START", tconfig)
        test_ext_warm(o.warmthr, t.w)
        test_ext_run_test(o, t)
        plog("END")
        test_ext_stop()
    end
end

--
-- performance test runner
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
    plog("LOG", "INFO", "warming")
    local c = test_p.tests[client].w
    if c == nil or #c == 0 then
        -- allow empty lists to skip any warming.
        return
    end
    for _, conf in ipairs(c) do
        mcs.add_custom(thread, { func = "perf_warm" }, conf)
    end
    mcs.shredder({thread})
    plog("LOG", "INFO", "warming end")
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

    local pstats_arg = { stats = { "cmd_mg", "cmd_ms", "cmd_md", "cmd_get", "cmd_set" }, track = {} }
    local stats_arg = { stats = { "proxy_conn_requests" }, track = { "rusage_user", "rusage_system", "proxy_req_active", "proxy_await_active" } }

    local test = test_p.tests[client]
    -- copy the argument table since we modify it at runtime.
    -- want to do this better but it does complicate the code a lot...
    local a = shallow_copy(test.a)

    while true do
        plog("START", "subtest", a.rate, a.cli)
        test.t(testthr, a)
        -- one set of funcs on each test thread that ships history
        -- one func that reads the history and summarizes every second.
        mcs.add(testthr, { func = "perfrun_stats_out", rate_limit = 1, clients = 1 })
        mcs.add_custom(statthr, { func = "perfrun_stats_gather" }, { threads = o.threads })
        mcs.add(statthr, { func = "proxy_stat_sample", clients = 1, rate_limit = 1 }, pstats_arg)
        mcs.add(statthr, { func = "stat_sample", clients = 1, rate_limit = 1 }, stats_arg)
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
            plog("START", tbackend .. "_" .. tclient)
            test_p_warm(o.warmthr, tclient)
            test_p_run_test(o, tclient)
            test_p_flush_datanodes(o.maintthr)
        end
        test_p_stop_proxy()
    end
end

--
-- stability test runner
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
        track = { "active_req_limit", "buffer_memory_limit", "buffer_memory_used", "vm_memory_kb", "vm_gc_runs" } }
    local statm_conf = { func = "stat_sample", clients = 1, rate_limit = 1 }
    local statm_arg = { stats = { "proxy_conn_requests", "total_connections" },
        track = { "proxy_req_active", "proxy_await_active", "read_buf_count", "read_buf_bytes", "read_buf_bytes_free", "response_obj_count", "curr_connections" } }
    local statpf_conf = { func = "proxyfuncs_stat_sample", clients = 1, rate_limit = 1 }

    local go_test = function(args)
        mcs.add(stats, timer_display)
        mcs.add(stats, timer_conf, args)
        mcs.add(stats, stat_conf, stat_arg)
        mcs.add(stats, statm_conf, statm_arg)
        mcs.add(stats, statpf_conf)
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
    -- FIXME: method to wait until proxy responds to 'version'
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

                    plog("START", suite .. "_" .. pfx .. "_" .. n)
                    local args = test.a
                    args["prefix"] = prefix
                    if test["s"] then
                        test["f"](test.a, threads, go_test)
                    else
                        test["f"](test.a, threads)
                        go_test(args)
                    end -- if test
                    plog("END")
                end -- if p == suite
            end -- for tests

        end
    end
end
