-- TODO: get homedir from os.getenv?
local BASEDIR <const> = "/home/buildbot/test/conf"

-- FIXME: should load these during config stage via callouts to dig.
-- they don't change in practice though, so low priority.
local NODE_IPS <const> = { '10.191.24.56', '10.191.24.4', '10.191.24.178' }

function nodectrl(a)
    local result, term, code = os.execute(BASEDIR .. "/node-ctrl.sh " .. a)
    if result == nil then
        print("node control error:", term, code)
    end
end

function nodeips()
    return NODE_IPS
end
