--AlvaroBajceps 2026
local version = "2.2.0"

local _lap = require("lapotron_ab")
local _kfc = require("kalman_ab")
local _component = require("component")
local _term = require("term")
local _ev = require("event")
local _io = require("io")
local _serialization = require("serialization")
local _shell = require("shell")
local _th = require("thread")
local _os = require("os")
local _sides = require("sides")

local RES_LAPTOP = {34,12}

local REDSHOW_STATE_PRE = 1
local REDSHOW_STATE_RUN = 2

local config = {
    ---@type string
    dev_laproton = "",
    ---@type string
    dev_redstone = "",
}

local redshow_th = nil
local shared = {
    lbat_notok = false,
    ---@type LapotronReader
    lbat = nil,
    ---@type ComponentRedstone
    reddev = nil,
    ---@type KalmanFilter
    lbat_kf = nil,
}

local function th_redshow()
    
end


---@param resolution table?
local function setResolution(resolution)
    if resolution ~= nil then
        _component.gpu.setResolution( table.unpack(resolution) )
        return
    end
    _component.gpu.setResolution(_component.gpu.maxResolution())
end

local function onDevAdd(self, _, uuid, type)
    if type ~= "screen" then
        return
    end
    _component.gpu.bind(uuid, true)
    setResolution(RES_LAPTOP)
end

---seconds to full or empty
---@param lbat LapotronReader
---@param bat_kf KalmanFilter
local function secondToEdge(lbat, bat_kf)
    local eu_filled = lbat.cache.stored
    local eu_empty = lbat.cache.capacityTotal - eu_filled
    local net_instant = (lbat.cache.powerAvgIn_5s - lbat.cache.powerAvgOut_5s)

    local net_kf = bat_kf:update(net_instant) *20

    local readout
    if net_instant > 8 then
        readout = eu_empty / net_kf
    elseif net_instant < -8 then
        readout = eu_filled / net_kf
    else
        readout = 0
    end

    return readout
end

local function statusFromSeconds(sec, percent)
    local preText
    if (sec > 1) then
        preText = "Filled in: "
    elseif (sec < -1) then
        preText = "Empty in: "
    elseif percent < 5 or percent > 95 then
        return "Too cringed to say"
    else
        return "I don't care so you can too"
    end

    sec = math.abs(sec)

    if(sec < 180) then
        return string.format(preText .. "%.2f seconds", sec)
    elseif sec < 3600 then
        return string.format(preText .. "%.0f:%02.0f minutes", math.floor(sec/60), sec%60)
    elseif sec < 86400 then
        return string.format(preText .. "%.0f:%02.0f hours", math.floor(sec/3600), math.floor((sec%3600)/60))
    elseif sec < 8553600 then
        return string.format(preText .. "%.2f days", sec/86400)
    else
        return "Too long to show"
    end
end

---@param validator fun(uuid: string): boolean function that validates device
---@return string? uuid of selected device or nil
local function selectDevice(validator)
    local possibleDevices = {}
    for k in _component.list() do
        if (validator(k)) then
            table.insert(possibleDevices, k)
        end
    end

    if #possibleDevices == 0 then
        return nil
    end

    if #possibleDevices == 1 then
        return possibleDevices[1]
    end

    ---@type number?
    local input

    while true do
        _term.clear()
        for k,v in ipairs(possibleDevices) do
            print(k .. ". " .. v)
        end
        print("\nSelect device (0 to quit):")
        input = tonumber(_io.read())

        if (input ~= nil and input > 0 and input <= #possibleDevices) then break end
    end

    if input == 0 then return nil end

    return possibleDevices[input]
end

---@param config any
---@param path string
local function save_config(config, path)
    local f, msg = _io.open(path, "w")
    if not f then
        print("Error while saving config: " .. msg) return
    end
    f:write(_serialization.serialize(config, true))
    f:close()
end

local function read_config(config, path)
    local f,msg = _io.open(path, "r")
    if not f then
        print("Error while reading config: " .. msg)
        return
    end
    local new_config = _serialization.unserialize( f:read("a") )
    f:close()

    for k,_ in pairs(config) do
        if new_config[k] then
            config[k] = new_config[k]
        end
    end
end


local function init_lbat(dev_uuid)
    if not _lap.isDeviceValid(dev_uuid) then
        dev_uuid = selectDevice(_lap.isDeviceValid)
    end

    if not dev_uuid then
        print("No valid lapotron capacitor selected!")
        return nil
    end

    return dev_uuid
end

local function init_reddev(dev_uuid, force_red)
    local function isDeviceValid(dev_uuid)
        checkArg(1, dev_uuid, "string")

        local dev_uuid_full = _component.get(dev_uuid)
    
        if not dev_uuid_full or dev_uuid_full == "" then
            return false, ("No device found with UUID '" .. dev_uuid .. "'")
        end
    
        local dev_proxy = _component.proxy(dev_uuid_full)
        ---@diagnostic disable-next-line: cast-type-mismatch
        ---@cast dev_proxy ComponentRedstone
    
        if not dev_proxy.setOutput then
            return false, ("Device '" .. dev_uuid_full .. "' does not have `setOutput()` Probably not redstone component...")
        end
    
        return true
    end

    if not isDeviceValid(dev_uuid) and force_red then
        dev_uuid = selectDevice(isDeviceValid)
    end

    if not dev_uuid or dev_uuid == "" then
        if force_red then
            print("No valid redstone component!")
        end
        return nil
    end

    return dev_uuid
end

local function init_shared_from_config(redstone_required)
    if not config.dev_laproton then
        _os.exit(-1)
    end

    local msg
    shared.lbat, msg = _lap.new(config.dev_laproton)
    if not shared.lbat then
        print(msg)
        _os.exit(-1)
    end

    if not config.dev_redstone then
        if redstone_required then
            print("Redstone not set but required.")
            _os.exit(-1)
        end
        print("No redstone component in use.")
        return
    end

    ---@diagnostic disable-next-line: param-type-mismatch
    shared.reddev = _component.proxy(_component.get(config.dev_redstone))
    if not shared.reddev then
        print("No redstone component in use.")
    end
end

local function redthread() 
    local bat_side = _sides.east
    local load_side = _sides.up

    local load_prog = 0

    while true do
        local bat_bars = shared.lbat.cache.capacityUsed // 11

        local in_out =  shared.lbat.cache.powerAvgIn_5s - shared.lbat.cache.powerAvgOut_5s

        local iv_voltage_bars =  math.min( math.ceil( in_out / 8*(4^5) ), 4 )
        local luv_voltage_bars = math.min( math.ceil( in_out / 8*(4^6) ), 4 )
        local zpm_voltage_bars = math.min( math.ceil( in_out / 8*(4^7) ), 3 )
        local load_bars = iv_voltage_bars + luv_voltage_bars + zpm_voltage_bars

        if load_bars > 0 then
            if load_prog > bat_bars then
                load_prog = 0
            else
                load_prog = load_prog + 1
            end
        else
            if load_prog < 0 then
                load_prog = bat_bars
            else
                load_prog = load_prog - 1
            end
        end

        shared.reddev.setOutput(load_side, math.abs(sum))
        shared.reddev.setOutput(bat_bars, load_prog)

        os.sleep(1)
    end
end

--
-- MAIN
--
local function main(...)
    local args, opts = _shell.parse(...)

    if opts.h or opts.help then
        print("Laptop v." .. version)
        print("-h, --help\tshow help")
        print("-r, --redstone\tforce redstone output")
        print("-R, --no-redstone\tforce redstone output")
        print("-S, --reset-cfg\tcreate fresh config")
        print("-s, --save-cfg\tsave config from runtime")
        print("-c, --config=[path]\tuse config at path")
        print("-V, --virtual\tvirtual lapotron device for testing")
        return
    end

    if opts["virtual"] then opts.V = true end
    if opts["reset-cfg"] then opts.S = true end
    if opts["save-cfg"] then opts.s = true end
    if opts["redstone"] then opts.r = true end
    if opts["no-redstone"] then opts.R = true end

    if opts.S and opts.s then
        print("Cannot reset and save from runtime at same time!")
        return
    end

    if opts.c and opts.config then
        print("Duplicate config path option.")
        return
    end

    opts.config = opts.config or args.c or "/home/laptop.cfg"

    if opts.S then
        print("Reset config...")
        save_config(config, opts.config)
        return
    end

    ---init settings

    if opts.config and not opts.s then
        print("Read config...")
        read_config(config, opts.config)
    end

    if opts.V then
        config.dev_laproton = "v_laporton"
    end

    config.dev_laproton = init_lbat(config.dev_laproton)
    config.dev_redstone = init_reddev(config.dev_redstone, opts.r)

    if opts.R then
        print("Redstone is disabled")
        config.dev_redstone = nil
    end

    init_shared_from_config(opts.r)
    shared.lbat_kf = _kfc.new(1, 1000, 0)

    if opts.s then
        print("Save config (from runtime)...")
        save_config(config, opts.config)
        return
    end

    os.sleep(0.2)

    local fg_color = _component.gpu.getForeground()
    setResolution(RES_LAPTOP)

    _ev.listen("component_added", onDevAdd)

    if not shared.lbat then return -1 end

    local status_avg = 0

    local lbat_refresh = function ()
        shared.lbat:pull(true)
    end
    local lbat_refresh_handle = _ev.timer(1.0, lbat_refresh, math.huge)
    redshow_th = _th.create(redthread)

    while not _ev.pull(1, "interrupt") do

        status_avg = secondToEdge(shared.lbat, shared.lbat_kf)
        local status_avg_str = statusFromSeconds(status_avg, shared.lbat.cache.capacityUsed)

        _term.clear()

        print("###   LAPTOP   ###")

        if not shared.lbat_notok then
            print("\nCharge: " .. shared.lbat.cache.capacityUsed .. "%")
            print("In: " .. shared.lbat.cache.powerAvgIn_5s .. "EU/t")
            print("Out: " .. shared.lbat.cache.powerAvgOut_5s .. "EU/t")
            print("Net: " .. shared.lbat.cache.powerAvgIn_5s - shared.lbat.cache.powerAvgOut_5s .. "EU/t")
            print("\nINST " .. shared.lbat.cache.energyStatusText)
            print("AVG  " .. status_avg_str)

            if shared.lbat.cache.maintenanceStatus then
                _component.gpu.setForeground(0xFF0000)
                print("\nMaintenance: fix my ass!")
                _component.gpu.setForeground(fg_color)
            else
                print("\nMaintenance: no problemo!")
            end
        else
            print("\nLapotron offline")
        end
    end

    _ev.ignore("component_added", onDevAdd)
    _ev.cancel(lbat_refresh_handle)
    _term.clear()
    setResolution()
    shared.lbat:dispose()

end

main(...)