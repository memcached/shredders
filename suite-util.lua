-- TODO: get homedir from os.getenv?
local BASEDIR <const> = "/home/buildbot/test/conf"

-- FIXME: should load these during config stage via callouts to dig.
-- they don't change in practice though, so low priority.
local NODE_IPS <const> = { '10.191.24.56', '10.191.24.4', '10.191.24.178' }

function nodectrl(a)
    local result, term, code = os.execute(BASEDIR .. "/node-ctrl.sh " .. a)
    if result == nil then
        plog("LOG", "ERROR", "node control:" .. term .. "_" .. code)
    end
end

function nodeips()
    return NODE_IPS
end

function plog(...)
    io.write(os.date("%a %b %e %H:%M:%S | "))
    io.write(table.concat({...}, " | "))
    io.write("\n")
    io.flush()
end

function shallow_copy(a)
    local c = {}
    for key, val in pairs(a) do
        c[key] = val
    end
    return c
end

-- https://stackoverflow.com/questions/9168058/how-to-dump-a-table-to-console
-- should probably get a really nice one of these for the library instead.
local function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end
