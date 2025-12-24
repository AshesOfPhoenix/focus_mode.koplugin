local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local DateTimeWidget = require("ui/widget/datetimewidget")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Device = require("device")
local GestureRange = require("ui/gesturerange")

local _ = require("gettext")
local T = require("ffi/util").template

local FocusMode = InputContainer:new({
    name = "focus_mode",
    meta = nil, -- reference to the _meta module
    is_doc_only = false, -- available in both doc and filemanager models
    settings_file = DataStorage:getSettingsDir() .. "/focus_mode.lua",
    settings = nil, -- loaded only when needed
    updated = false, -- flag to track if settings were updated
    focus_mode_dialog = nil, -- reference to the main dialog instance
    debug_html_dialog = nil, -- reference to the debug HTML dialog instance
})

local FocusModeHtml = [[
    <html>
  <body>
    <div
      style="position: relative"
    >
      <img
        src="focus_mode.png"
        style="max-width: 100%; height: auto; display: block; margin: 0 auto;"
      />
      <div style="position: absolute; top: 10%; left: 50%; transform: translate(-50%, -50%); display: flex; flex-direction: column; justify-content: center; align-items: center;">
          <h2 style="text-align: center; font-size: 4em; margin-bottom: 1rem;">Focus Mode is active.</h2>
          <p style="text-align: center; font-size: 2em; margin-top: 0rem;">
            Focus Mode is active. You are not allowed to use the device.
          </p>
      </div>
    </div>
  </body>
</html>
]]

local FOCUS_MODE_DIR = T("%1/plugins/%2.koplugin/", DataStorage:getDataDir(), FocusMode.name)
local META_FILE_PATH = FOCUS_MODE_DIR .. "_meta.lua"

function FocusMode:onDispatcherRegisterActions()
    Dispatcher:registerAction(
        "focus_mode_action",
        { category = "none", event = "FocusMode", title = _("Focus Mode"), general = true }
    )
end

function FocusMode:init()
    -- loading our own _meta.lua
    self.meta = dofile(META_FILE_PATH)

    -- init settings
    self.settings = LuaSettings:open(self.settings_file)

    self.focus_mode_settings = self:readFocusModeSettings()

    self.last_check_time = os.time()
    self.is_blocking = false

    -- Register actions with dispatcher for gesture assignment
    self:onDispatcherRegisterActions()

    -- Register menu to main menu (under "tools") - for both reader and filemanager
    self.ui.menu:registerToMainMenu(self)

    -- Schedule check for focus mode
    self:scheduleCheck()
end

function FocusMode:readFocusModeSettings()
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
function FocusMode:readSubSetting(key)
    logger.info("FocusMode: Reading %1", key)
    local settings = self:readFocusModeSettings()
    return settings[key]
end

-- Helper to save a specific key into the focus_mode sub-dictionary
function FocusMode:saveSubSetting(key, value)
    logger.info("FocusMode: Saving %1: %2", key, value)
    local settings = self:readFocusModeSettings()
    settings[key] = value
    self.settings:saveSetting("focus_mode", settings)
    self.settings:flush()
end

function FocusMode:scheduleCheck()
    UIManager:scheduleIn(60, function()
        self:checkFocusMode()
    end)
end

function FocusMode:checkFocusMode()
    local now = os.date("*t")
    logger.info("FocusMode: Checking focus mode at %1:%2", now.hour, now.min)
    local current_timestamp = os.time()
    logger.info("FocusMode: Current timestamp: %1", current_timestamp)

    -- Calculate actual elapsed time since last check
    -- This handles the case where you read for 1 minute, but the timer took 61 seconds
    local elapsed = current_timestamp - self.last_check_time
    self.last_check_time = current_timestamp
    logger.info("FocusMode: Last check time: %1", self.last_check_time)
    -- Sanity check: If elapsed is huge (device slept and `resume`ed), ignore it
    if elapsed > 300 then
        logger.info("FocusMode: Detected time jump (resume?), ignoring interval")
        elapsed = 0
    end
    logger.info("FocusMode: Elapsed: %1", elapsed)
    -- Check Limits
    if self:isWithinFocusBlockWindow(now) then
        logger.info("FocusMode: Within focus block window.")
        self:activateBlocker()
    else
        -- If we were blocking but time passed (e.g. next day), release
        if self.is_blocking then
            logger.info("FocusMode: Outside focus block window, deactivating blocker.")
            self:deactivateBlocker()
        end
    end

    -- Queue next check
    self:scheduleCheck()
end

function FocusMode:activateBlocker()
    if self.is_blocking or not self:readSubSetting("enabled") then
        logger.info("FocusMode: Blocker already active or disabled, skipping.")
        return
    end

    logger.info("FocusMode: Activating blocker.")

    self.blocker_widget = InfoMessage:new({
        text = "Focus Mode is active. You are not allowed to use the device.",
        fullscreen = true,
        z_index = 9999,
        image = "focus_mode.png",
    })

    -- OVERRIDE input handling to trap the user
    -- This prevents tapping 'close' or gesturing
    self.focus_mode_dialog.onClose = function()
        return
    end -- Disable close
    self.focus_mode_dialog.handleInput = function()
        return true
    end -- Consume all clicks
    self.focus_mode_dialog.onGesture = function()
        return true
    end -- Consume all swipes

    UIManager:show(self.focus_mode_dialog)
    self.is_blocking = true
end

function FocusMode:deactivateBlocker()
    if not self.is_blocking then
        return
    end

    logger.info("FocusMode: Deactivating blocker.")

    if self.focus_mode_dialog then
        UIManager:close(self.focus_mode_dialog)
        self.focus_mode_dialog = nil
    end
    self.is_blocking = false
end

function FocusMode:isWithinFocusBlockWindow(now)
    local from_time = self:readSubSetting("from_time") or { hour = 6, min = 0 }
    local to_time = self:readSubSetting("to_time") or { hour = 19, min = 0 }

    return now.hour >= from_time.hour
        and now.hour <= to_time.hour
        and now.min >= from_time.min
        and now.min <= to_time.min
end

function FocusMode:addToMainMenu(menu_items)
    menu_items.focus_mode = {
        text = _("Focus Mode"),
        -- in which menu this should be appended
        sorting_hint = "tools",
        -- a callback when tapping

        callback = function()
            FocusMode.onFocusMode(self)
            -- self:_help_dialog()
        end,

        sub_item_table = {
            {
                text = _("Set enabled"),
                keep_menu_open = true,
                checked_func = function()
                    return self:readSubSetting("enabled")
                end,
                callback = function(touchmenu_instance)
                    self:saveSubSetting("enabled", not self:readSubSetting("enabled"))
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text = _("Set from time"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onShowFromTime(touchmenu_instance)
                end,
            },
            {
                text = _("Set to time"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onShowToTime(touchmenu_instance)
                end,
            },
            {
                text = _("Open focus mode HTML (debug)"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:onShowFocusModeHtml(touchmenu_instance)
                end,
            },
        },
    }
end

function FocusMode:onShowFromTime(touchmenu_instance)
    local from_time = self:readSubSetting("from_time") or { hour = 6, min = 0 }
    local from_time_widget = DateTimeWidget:new({
        hour = from_time.hour,
        min = from_time.min,
        title_text = _("From time"),
        info_text = _("Enter a time in hours and minutes."),
        callback = function(widget)
            local new_time = {
                hour = widget.hour,
                min = widget.min,
            }
            self:saveSubSetting("from_time", new_time)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
            end
        end,
    })
    UIManager:show(from_time_widget)
    return true
end

function FocusMode:onShowToTime(touchmenu_instance)
    local to_time = self:readSubSetting("to_time") or { hour = 19, min = 0 }
    local to_time_widget = DateTimeWidget:new({
        hour = to_time.hour,
        min = to_time.min,
        title_text = _("To time"),
        info_text = _("Enter a time in hours and minutes."),
        callback = function(widget)
            local new_time = {
                hour = widget.hour,
                min = widget.min,
            }
            self:saveSubSetting("to_time", new_time)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
            end
        end,
    })
    UIManager:show(to_time_widget)
    return true
end

function FocusMode:onShowFocusModeHtml(touchmenu_instance)
    -- Close menu if provided
    if touchmenu_instance then
        touchmenu_instance:closeMenu()
    end

    -- Close existing debug dialog if open
    if self.debug_html_dialog then
        UIManager:close(self.debug_html_dialog)
        self.debug_html_dialog = nil
    end

    local image_path = self.path .. "/images/focus_mode.png"
    logger.info("FocusMode: Image path: %1", image_path)

    -- Note: InfoMessage's 'image' parameter expects a BlitBuffer, not a file path.
    -- We need to load the image first.
    local RenderImage = require("ui/renderimage")
    local image_bb = RenderImage:renderImageFile(image_path, false, Device.screen:getWidth() * 0.15, Device.screen:getHeight() * 0.15)

    if not image_bb then
        logger.warn("FocusMode: Failed to load image from:", image_path)
    end

    local debug_dialog = InfoMessage:new({
        text = "Focus Mode is active. You are not allowed to use the device.",
        fullscreen = true,
        z_index = 9999,
        -- image = image_bb,  -- Can be nil if image failed to load; InfoMessage will use default icon
    })

    -- Handle tap close event
    function debug_dialog:onTapClose()
        UIManager:close(self)
        FocusMode.debug_html_dialog = nil
        return true
    end

    -- Handle back button/keyboard close
    function debug_dialog:onClose()
        UIManager:close(self)
        FocusMode.debug_html_dialog = nil
        return true
    end

    self.debug_html_dialog = debug_dialog
    UIManager:show(self.debug_html_dialog)
    return true
end

function FocusMode:onShowFocusModeHtmlOld(touchmenu_instance)
    -- Close menu if provided
    if touchmenu_instance then
        touchmenu_instance:closeMenu()
    end

    -- Close existing debug dialog if open
    if self.debug_html_dialog then
        UIManager:close(self.debug_html_dialog)
        self.debug_html_dialog = nil
    end

    logger.info("FocusMode: Showing debug HTML dialog")

    local lfs = require("libs/libkoreader-lfs")
    local image_dir = lfs.currentdir() .. "/" .. FOCUS_MODE_DIR .. "images"
    logger.info("FocusMode: Image directory: %1", image_dir)

    local w = math.floor(Device.screen:getWidth() * 0.80)
    local h = math.floor(Device.screen:getHeight() * 0.80)

    -- Create HTML widget
    local html_widget = HtmlBoxWidget:new({
        dimen = Geom:new({ w = w, h = h }),
    })

    local html_body = [[
        <div class="container">
            <div class="image-wrapper">
                <img src="focus_mode.png" />
            </div>
            <div class="text-overlay">
                <h2>Focus Mode is active.</h2>
                <p>You are not allowed to use the device.</p>
            </div>
        </div>
    ]]

    local css = [[
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            margin: 0;
            padding: 0;
            width: 100%;
            height: 100%;
        }
        .container {
            position: relative;
            width: 100%;
            height: 100%;
            margin: 0;
            padding: 0;
        }
        .image-wrapper {
            width: 100%;
            height: 100%;
            overflow: hidden;
            border-radius: 20px;
            display: block;
            position: relative;
            margin: 0;
            padding: 0;
        }
        .image-wrapper img {
            width: 100%;
            height: 100%;
            display: block;
            object-fit: cover;
            border-radius: 20px;
            -webkit-border-radius: 20px;
            -moz-border-radius: 20px;
            margin: 0;
            padding: 0;
        }
        .text-overlay {
            position: absolute;
            top: 15%;
            left: 0;
            width: 100%;
            text-align: center;
            z-index: 10;
        }
        .text-overlay h2 {
            color: black;
            font-size: 2em;
            margin: 0;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.8);
        }
        .text-overlay p {
            color: black;
            font-size: 1.5em;
            margin: 10px 0 0 0;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.8);
        }
    ]]

    html_widget:setContent(
        html_body,
        css, -- css
        20, -- default font size
        false, -- is_xhtml
        false, -- no_css_fixes
        image_dir -- resource_directory
    )

    -- Create dialog container wrapped in InputContainer to handle gestures
    local dialog_content = CenterContainer:new({
        dimen = Geom:new({ w = Device.screen:getWidth(), h = Device.screen:getHeight() }),
        FrameContainer:new({
            bordersize = 0,
            padding = 0,
            radius = 10,
            background = Blitbuffer.COLOR_WHITE,
            html_widget,
        }),
    })

    -- Create InputContainer with gesture events and key events set up
    local ges_events = {}
    local key_events = {}

    if Device:isTouchDevice() then
        ges_events.TapClose = {
            GestureRange:new({
                ges = "tap",
                range = Geom:new({
                    x = 0,
                    y = 0,
                    w = Device.screen:getWidth(),
                    h = Device.screen:getHeight(),
                }),
            }),
        }
    end

    if Device:hasKeys() then
        key_events.Close = { { Device.input.group.Back } }
    end

    local debug_dialog = InputContainer:new({
        dimen = Geom:new({ w = Device.screen:getWidth(), h = Device.screen:getHeight() }),
        ges_events = ges_events,
        key_events = key_events,
        [1] = dialog_content,
    })

    -- Handle tap close event
    function debug_dialog:onTapClose()
        UIManager:close(self)
        FocusMode.debug_html_dialog = nil
        return true
    end

    -- Handle back button/keyboard close
    function debug_dialog:onClose()
        UIManager:close(self)
        FocusMode.debug_html_dialog = nil
        return true
    end

    self.debug_html_dialog = debug_dialog
    UIManager:show(self.debug_html_dialog)
    return true
end

return FocusMode
