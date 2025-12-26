local logger = require("logger")

local Utils = {}

function Utils.readSettings(self)
    local default_settings = {
        enabled = false,
        from_time = { hour = 6, min = 0 },
        to_time = { hour = 19, min = 0 },
    }

    local current_settings = self.settings:readSetting("focus_mode")

    if not current_settings then
        -- Settings don't exist, save the defaults
        self.settings:saveSetting("focus_mode", default_settings)
        self.settings:flush() -- write to disk immediately
        return default_settings
    end

    return current_settings
end

-- Helper to read a specific key from the focus_mode sub-dictionary
function Utils.readSubSetting(self, key)
    logger.info("FocusMode: Reading %1", key)
    local settings = self:readSettings()
    return settings[key]
end

-- Helper to save a specific key into the focus_mode sub-dictionary
function Utils.saveSubSetting(self, key, value)
    logger.info("FocusMode: Saving %1: %2", key, value)
    local settings = self:readSettings()
    settings[key] = value
    self.settings:saveSetting("focus_mode", settings)
    self.settings:flush()
end

return Utils
