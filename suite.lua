require("suite-util")
require("suite-lib")
require("suite-performance-lib")
require("suite-stability-lib")
local test_p = require("suite-performance-tests")
local test_ext = require("suite-extstore-tests")

function help()
    local msg =[[
        time (30) (how long to run each sub test)
        threads (5) (number of mcshredder threads for test load)
        suite (nil) (base test suite to run)
        filter (nil) (filter which tests to run)
        debug (false) (extra debug output from test suite)
        external (false) (user manually manages memcached daemons)
        debugbin (false) (always use memcached debug binary)

        filter examples:
        Test name ex: routelib_fallback_basic
        Filter: routelib (runs all routelib_* tests)
                routelib_fallback (runs all routelib_fallback_* tests)
                routelib_fallback-allsync_basic (runs basic subtest from just two prior subtests)
                routelib_any_basic (run the basic subtest from any middle tests)
    ]]
    print(msg)
end

function _split_arg(a)
    local t = {}
    for name in string.gmatch(a, '([^_]+)') do
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

_TESTENV = {

}
-- query the test environment?
function TESTENV(a)
    -- simple wrapper so I can add some logic as needed.
    return _TESTENV[a]
end

function config(a)
    local o = {
        threads = 6,
        time = 30,
    }
    if a["threads"] ~= nil then
        print("[init] overriding: test threadcount")
        o.threads = a.threads
    end
    if a["time"] ~= nil then
        print("[init] overriding: test time")
        o.time = tonumber(a.time)
    end
    if a["external"] ~= nil then
        _TESTENV["external"] = true
    end
    if a["debugbin"] ~= nil then
        _TESTENV["debugbin"] = true
    end
    if a["debug"] ~= nil then
        _TESTENV["debug"] = true
    end

    if a["filter"] ~= nil then
        local list = _split_arg(a["filter"])
        for i, name in ipairs(list) do
            if string.find(name, "-", 1, true) then
                list[i] = _split_arghash(name)
            end
        end
        _TESTENV["filter"] = list
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
        if type(top.v) == "table" then
            if top.__vi then
                top.__vi = top.__vi + 1
            else
                top.__vi = 1
            end
            plog("DEBUG", "ts:advance() -> top.v as table", type(top.__vi))

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
        elseif type(top.v) == "function" then
            if top.__vi == nil then
                -- TODO: some way of combining stack args might be nice
                top.__vi = shallow_copy(top.a)
            end
            local name, nv = top.v(top.__vi)
            plog("DEBUG", "ts:advance() -> top.v as func", type(top.__vi), type(nv))

            if nv == nil then
                top.__vi = nil
                table.remove(tstack)
                return tstack:advance()
            else
                if top.vn then
                    -- unpack the name from the variant return.
                    top[top.vn] = name
                    top.__vi = nv
                end
            end
        else
            error("variant of unknown type")
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
        -- function, so we still stop processing here.
        return false
    end
end

local function ts_pop(tstack)
    table.remove(tstack)
end

local function ts_find(tstack, key)
    plog("DEBUG", "ts_find", type(tstack), key)
    for i=#tstack, 1, -1 do
        plog("DEBUG", "ts_find loop", type(tstack), i, key)
        local v = rawget(tstack[i], key)
        if v then
            plog("DEBUG", "ts_find found", type(tstack), i, key)
            return v
        end
    end
end

-- TODO: mcshredder methods for testing when ports become alive/etc.
local function test_daemon_startup(r, start, stop)
    if stop ~= nil then
        plog("LOG", "INFO", "stopping previous test daemon")
        if type(stop) == "string" then
            nodectrl(stop)
            os.execute("sleep 8")
        else
            stop(r)
        end
    end

    plog("LOG", "INFO", "starting next test daemon")
    if type(start) == "string" then
        nodectrl(start)
        os.execute("sleep 2")
    else
        return start(r)
    end
end

local function ts_name_build(tstack)
    local n = {}
    for _, t in ipairs(tstack) do
        if t.n then
            table.insert(n, t.n)
        end
        if t.vn then
            table.insert(n, t[t.vn])
        end
    end
    return n
end

local function ts_name(tstack)
    local n = ts_name_build(tstack)
    return table.concat(n, "_")
end

local function ts_filter(tstack, filter)
    if filter == nil then
        return true
    end
    local full = ts_name_build(tstack)
    local matches = 0

    for i, f in ipairs(filter) do
        local t = full[i]
        plog("DEBUG", "ts_filter: comparing", t, f)
        if type(f) == "string" then
            if f == "any" then
                plog("DEBUG", "ts_filter: matched from 'any' wildcard", i, t, f)
                matches = matches + 1
            elseif t == f then
                plog("DEBUG", "ts_filter: matched from string", i, t, f)
                matches = matches + 1
            end
        elseif type(f) == "table" then
            if f[t] ~= nil then
                plog("DEBUG", "ts_filter: matched from table", i, t, f)
                matches = matches + 1
            end
        else
            plog("ERROR", "ts_filter: unhanled filter subtype", type(f), i, t, f)
        end
    end

    -- ensure we get one match at each filter level
    if matches == #filter then
        return true
    else
        return false
    end
end

-- TODO: allow dynamic path prefix via name?
local function test_warm(thread, c)
    if c == nil or #c == 0 then
        plog("LOG", "INFO", "warming skipped")
        return
    end
    plog("LOG", "INFO", "warming")
    for _, conf in ipairs(c) do
        mcs.add_custom(thread, { func = conf.func }, conf)
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
                if a[1].custom then
                    if type(thr) == "userdata" then
                        mcs.add_custom(thr, a[1], a[2])
                    else
                        for _, v in pairs(thr) do
                            mcs.add_custom(v, a[1], a[2])
                        end
                    end
                else
                    mcs.add(thr, a[1], a[2])
                end
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
            local duration = o.time
            if time ~= nil then
                duration = time
            end
            local all = {}
            -- gather any activated threads together.
            -- needed to actually execute a shred.
            setup(all, o.statsthr, d.stats)
            setup(all, o.maintthr, d.maint)
            setup(all, o.warmthr, d.warm)
            setup(all, o.testthr, d.work)
            mcs.shredder(all, duration)
            -- always wipe config stack for main test threads.
            d.work = {}
            d.warm = {}
            d.maint = {}
            d.stats = {}
        end,
        pending = function(self)
            if #d.work > 0 then
                return true
            end
            return false
        end,
        thread_count = function(self)
            return o.threads
        end,
        key = function(self, k)
            return tstack:find(k)
        end,
        variant = function(self)
            return tstack:find('__vi')
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
    local mt = {
        advance = ts_advance_test,
        find = ts_find,
        name = ts_name,
        pop = ts_pop,
        filter = ts_filter,
    }
    mt.__index = mt
    setmetatable(tstack, mt)

    plog("LOG", "INFO", "running node stops before beginning test run")
    local pre_stop = tstack:find("e")
    if pre_stop == nil then
        error("test must specify .e for ending a test")
    end
    if type(pre_stop) == "string" then
        nodectrl(pre_stop)
        os.execute("sleep 8")
    else
        pre_stop()
    end

    local start = nil
    local start_key = nil
    local start_cur = nil
    local stop = nil
    local warm = nil
    -- loop while tests exist to run.
    while tstack:advance() do
        if tstack:filter(_TESTENV["filter"]) then
            local runner = test_wrapper_new(o, tstack)
            local next_start = tstack:find("s")
            local next_stop = tstack:find("e")
            if next_stop == nil then
                error("test must specify .e for ending a test")
            end
            if next_start ~= start then
                -- if the start function changes, issue a stop/start
                local res = test_daemon_startup(runner, next_start, stop)
                if res then
                    start_key = res
                    start_cur = tstack:find(start_key)
                else
                    start_key = nil
                    start_cur = nil
                end

                stop = next_stop
                start = next_start
            elseif start_key then
                -- else our start function is tracking a key change and
                -- restarting then.
                local k = tstack:find(start_key)
                plog("DEBUG", "checking start key", start_key, k)
                if k ~= start_cur then
                    local res = test_daemon_startup(runner, next_start, stop)
                    if res then
                        start_key = res
                        start_cur = tstack:find(start_key)
                    end
                    stop = next_stop
                end
            end

            local warmers = tstack:find("w")
            if type(warmers) == "function" then
                test_warm(o.warmthr, warmers(runner))
            elseif warm ~= warmers then
                test_warm(o.warmthr, warmers)
            else
                plog("LOG", "INFO", "pre-warmed")
            end

            local f = tstack:find("f")
            local t_name = tstack:name()
            plog("START", tstack:name())
            f(runner)
            if runner:pending() then
                plog("DEBUG", "running shred from pending work")
                runner:shred()
            end
            tstack:pop()
        else
            plog("LOG", "INFO", "skipping", tstack:name())
            tstack:pop()
        end
    end

    if not _TESTENV["external"] and stop then
        if type(stop) == "string" then
            nodectrl(stop)
            os.execute("sleep 8")
        else
            stop()
        end
    end
end
