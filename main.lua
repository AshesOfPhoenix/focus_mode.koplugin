local Dispatcher = require("dispatcher") -- luacheck:ignore
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local DateTimeWidget = require("ui/widget/datetimewidget")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local ButtonDialog = require("ui/widget/buttondialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local InputDialog = require("ui/widget/inputdialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Device = require("device")
local GestureRange = require("ui/gesturerange")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonTable = require("ui/widget/buttontable")
local Font = require("ui/font")
local Size = require("ui/size")

local _ = require("gettext")
local T = require("ffi/util").template
local Utils = require("utils")

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

FocusMode.readSettings = Utils.readSettings
FocusMode.readSubSetting = Utils.readSubSetting
FocusMode.saveSubSetting = Utils.saveSubSetting

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

    self.focus_mode_settings = self:readSettings()

    self.is_blocking = false

    -- Register actions with dispatcher for gesture assignment
    self:onDispatcherRegisterActions()

    -- Register menu to main menu (under "tools") - for both reader and filemanager
    self.ui.menu:registerToMainMenu(self)
end

function FocusMode:isWithinFocusBlockWindow(now)
    local from_time = self:readSubSetting("from_time") or { hour = 6, min = 0 }
    local to_time = self:readSubSetting("to_time") or { hour = 19, min = 0 }

    -- Convert to minutes since midnight for proper comparison
    local current_mins = now.hour * 60 + now.min
    local from_mins = from_time.hour * 60 + from_time.min
    local to_mins = to_time.hour * 60 + to_time.min

    return current_mins >= from_mins and current_mins < to_mins
end

-- Check if blocking is currently active (enabled + within block window)
function FocusMode:isBlockingActive()
    local now = os.date("*t")
    local enabled = self:readSubSetting("enabled")
    return enabled and self:isWithinFocusBlockWindow(now)
end

-- this method is called when the document is fully loaded
function FocusMode:onReaderReady()
    logger.info("FocusMode: onReaderReady")
    self:checkAndShowBlockingDialog()
    return true
end

-- this method is called when koreader is woken up from suspend
function FocusMode:onResume()
    logger.info("FocusMode: onResume")
    -- Only check if we're in ReaderUI (document is open)
    if self.ui.document then
        self:checkAndShowBlockingDialog()
    end
    return true
end

-- this method is called when koreader is suspended
function FocusMode:onSuspend()
    logger.info("FocusMode: onSuspend")
    -- Cancel countdown timer when suspending to save battery
    self:cancelCountdownTimer()
    return true
end

-- Check if blocking should be active and show dialog if needed
function FocusMode:checkAndShowBlockingDialog()
    -- Check if Focus Mode is enabled
    if not self:readSubSetting("enabled") then
        logger.info("FocusMode: Plugin is disabled, not blocking")
        return
    end

    -- Check if we're within the blocking window
    local now = os.date("*t")
    if self:isWithinFocusBlockWindow(now) then
        logger.info("FocusMode: Within block window, showing dialog")
        self:showBlockingDialog()
    else
        logger.info("FocusMode: Outside block window, not blocking")
        -- Make sure any existing dialog is closed
        if self.is_blocking then
            self:closeBlockingDialog()
        end
    end
end

function FocusMode:addToMainMenu(menu_items)
    menu_items.focus_mode = {
        text = _("Focus Mode"),
        -- in which menu this should be appended
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self:isBlockingActive() then
                        return "⛔ FOCUS MODE ACTIVE"
                    else
                        return _("Set enabled")
                    end
                end,
                keep_menu_open = true,
                checked_func = function()
                    return self:readSubSetting("enabled")
                end,
                enabled_func = function()
                    -- Cannot toggle while actively blocking
                    return not self:isBlockingActive()
                end,
                callback = function(touchmenu_instance)
                    local currently_enabled = self:readSubSetting("enabled")
                    local now = os.date("*t")
                    local within_block_window = self:isWithinFocusBlockWindow(now)

                    if currently_enabled then
                        -- Trying to DISABLE (only possible outside block window)
                        self:saveSubSetting("enabled", false)
                    else
                        -- Trying to ENABLE
                        self:saveSubSetting("enabled", true)
                        -- If we're in the block window and in ReaderUI, show block immediately
                        if within_block_window and self.ui.document then
                            touchmenu_instance:closeMenu()
                            self:showBlockingDialog()
                            return
                        end
                    end
                    touchmenu_instance:updateItems()
                end,
                help_text = _(
                    "When enabled, reading is blocked during the set hours. Can only be disabled outside blocking hours."
                ),
            },
            {
                text = _("Set from time"),
                keep_menu_open = true,
                enabled_func = function()
                    return not self:isBlockingActive()
                end,
                callback = function(touchmenu_instance)
                    self:onShowFromTime(touchmenu_instance)
                end,
            },
            {
                text = _("Set to time"),
                keep_menu_open = true,
                enabled_func = function()
                    return not self:isBlockingActive()
                end,
                callback = function(touchmenu_instance)
                    self:onShowToTime(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    local pin = self:readSubSetting("bypass_pin")
                    if pin and #pin > 0 then
                        return _("Set bypass PIN") .. " ✓"
                    else
                        return _("Set bypass PIN")
                    end
                end,
                keep_menu_open = true,
                enabled_func = function()
                    -- Allow setting PIN during block only if no PIN exists yet
                    local pin = self:readSubSetting("bypass_pin")
                    if self:isBlockingActive() then
                        return not (pin and #pin > 0)
                    end
                    return true
                end,
                callback = function(touchmenu_instance)
                    self:onShowSetBypassPin(touchmenu_instance)
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
            -- Revalidate block state after time change
            if self:readSubSetting("enabled") and self.ui.document then
                self:checkAndShowBlockingDialog()
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
            -- Revalidate block state after time change
            if self:readSubSetting("enabled") and self.ui.document then
                self:checkAndShowBlockingDialog()
            end
        end,
    })
    UIManager:show(to_time_widget)
    return true
end

function FocusMode:onShowSetBypassPin(touchmenu_instance)
    local current_pin = self:readSubSetting("bypass_pin") or ""
    local pin_dialog
    pin_dialog = InputDialog:new({
        title = _("Set Bypass PIN"),
        input = current_pin,
        input_type = "number",
        input_hint = _("Enter a numeric PIN"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(pin_dialog)
                    end,
                },
                {
                    text = _("Clear"),
                    callback = function()
                        self:saveSubSetting("bypass_pin", nil)
                        UIManager:close(pin_dialog)
                        UIManager:show(InfoMessage:new({
                            text = _("Bypass PIN has been cleared."),
                            timeout = 2,
                        }))
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_pin = pin_dialog:getInputText()
                        if new_pin and #new_pin >= 4 then
                            self:saveSubSetting("bypass_pin", new_pin)
                            UIManager:close(pin_dialog)
                            UIManager:show(InfoMessage:new({
                                text = _("Bypass PIN saved."),
                                timeout = 2,
                            }))
                        else
                            UIManager:show(InfoMessage:new({
                                text = _("PIN must be at least 4 digits."),
                                timeout = 2,
                            }))
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(pin_dialog)
    pin_dialog:onShowKeyboard()
    return true
end

-- Calculate time remaining until block ends
function FocusMode:getTimeRemaining()
    local now = os.date("*t")
    local to_time = self:readSubSetting("to_time") or { hour = 19, min = 0 }

    local current_mins = now.hour * 60 + now.min
    local to_mins = to_time.hour * 60 + to_time.min

    local remaining_mins = to_mins - current_mins
    if remaining_mins <= 0 then
        return 0, 0
    end

    local hours = math.floor(remaining_mins / 60)
    local mins = remaining_mins % 60
    return hours, mins
end

-- Format end time for display
function FocusMode:getEndTimeString()
    local to_time = self:readSubSetting("to_time") or { hour = 19, min = 0 }
    return string.format("%02d:%02d", to_time.hour, to_time.min)
end

-- Build the dialog text with countdown
function FocusMode:buildBlockingDialogText()
    local hours, mins = self:getTimeRemaining()
    local end_time = self:getEndTimeString()

    local remaining_text
    if hours > 0 then
        remaining_text = T(_("%1 hour(s) %2 minute(s) remaining"), hours, mins)
    else
        remaining_text = T(_("%1 minute(s) remaining"), mins)
    end

    return T(_("Block ends at %1\n%2"), end_time, remaining_text)
end

-- Show the blocking dialog
function FocusMode:showBlockingDialog()
    -- Close existing dialog if open
    if self.focus_mode_dialog then
        UIManager:close(self.focus_mode_dialog)
        self.focus_mode_dialog = nil
        self.countdown_text_widget = nil
    end

    -- Cancel any existing countdown timer
    self:cancelCountdownTimer()

    -- Check if block should still be active
    local now = os.date("*t")
    if not self:isWithinFocusBlockWindow(now) then
        logger.info("FocusMode: Block window has ended, not showing dialog")
        return
    end

    logger.info("FocusMode: Showing blocking dialog")

    -- Calculate dialog width
    local screen_width = Device.screen:getWidth()
    local dialog_width = math.min(screen_width * 0.8, Size.item.height_default * 10)

    -- Create title widget
    local title_widget = TextWidget:new({
        text = _("Focus Mode Active"),
        face = Font:getFace("tfont"),
        bold = true,
    })

    -- Create countdown text widget (store reference for dynamic updates)
    self.countdown_text_widget = TextBoxWidget:new({
        text = self:buildBlockingDialogText(),
        face = Font:getFace("cfont"),
        width = dialog_width - Size.padding.large * 2,
        alignment = "center",
    })

    -- Build buttons based on whether PIN is set
    local bypass_pin = self:readSubSetting("bypass_pin")
    local button_table_buttons = {}

    if bypass_pin and #bypass_pin > 0 then
        -- PIN is set - show bypass option
        button_table_buttons = {
            {
                {
                    text = _("Bypass (PIN)"),
                    callback = function()
                        self:showPinBypassDialog()
                    end,
                },
                {
                    text = _("Go to Library"),
                    callback = function()
                        self:closeBlockingDialog()
                        Dispatcher:execute({ filemanager = true })
                    end,
                },
            },
        }
    else
        -- No PIN set - only show go to library
        button_table_buttons = {
            {
                {
                    text = _("Go to Library"),
                    callback = function()
                        self:closeBlockingDialog()
                        Dispatcher:execute({ filemanager = true })
                    end,
                },
            },
        }
    end

    -- Create button table
    local button_table = ButtonTable:new({
        width = dialog_width - Size.padding.large * 2,
        buttons = button_table_buttons,
        zero_sep = true,
        show_parent = self,
    })

    -- Create vertical group with all elements
    local vertical_group = VerticalGroup:new({
        align = "center",
        title_widget,
        VerticalSpan:new({ width = Size.padding.large }),
        self.countdown_text_widget,
        VerticalSpan:new({ width = Size.padding.large }),
        button_table,
    })

    -- Wrap in frame container
    local frame = FrameContainer:new({
        bordersize = Size.border.window,
        padding = Size.padding.large + 10,
        background = Blitbuffer.COLOR_WHITE,
        vertical_group,
        radius = Size.radius.window,
    })

    -- Wrap in center container
    local dialog_content = CenterContainer:new({
        dimen = Geom:new({
            w = Device.screen:getWidth(),
            h = Device.screen:getHeight(),
        }),
        frame,
    })

    -- Create InputContainer to handle input events (make it non-dismissable)
    local ges_events = {}
    local key_events = {}

    -- Don't register any close gestures - dialog is not dismissable
    -- But we still need an InputContainer to capture and block input

    self.focus_mode_dialog = InputContainer:new({
        dimen = Geom:new({
            w = Device.screen:getWidth(),
            h = Device.screen:getHeight(),
        }),
        ges_events = ges_events,
        key_events = key_events,
        modal = true,
        dialog_content,
    })

    -- Block tap/swipe gestures from dismissing
    function self.focus_mode_dialog:onTap()
        return true -- Consume the event
    end
    function self.focus_mode_dialog:onSwipe()
        return true -- Consume the event
    end

    UIManager:show(self.focus_mode_dialog)
    self.is_blocking = true

    -- Schedule countdown updates
    self:scheduleCountdownUpdate()
end

-- Close the blocking dialog
function FocusMode:closeBlockingDialog()
    self:cancelCountdownTimer()
    if self.focus_mode_dialog then
        UIManager:close(self.focus_mode_dialog)
        self.focus_mode_dialog = nil
        self.countdown_text_widget = nil
    end
    self.is_blocking = false
end

-- Schedule countdown timer update
function FocusMode:scheduleCountdownUpdate()
    -- Store the callback reference so we can cancel it later
    if not self.countdown_callback then
        self.countdown_callback = function()
            self:updateCountdown()
        end
    end
    -- Update every 60 seconds
    UIManager:scheduleIn(60, self.countdown_callback)
end

-- Cancel the countdown timer
function FocusMode:cancelCountdownTimer()
    if self.countdown_callback then
        UIManager:unschedule(self.countdown_callback)
    end
end

-- Update countdown and refresh dialog
function FocusMode:updateCountdown()
    local now = os.date("*t")

    -- Check if block window has ended
    if not self:isWithinFocusBlockWindow(now) then
        logger.info("FocusMode: Block window ended, dismissing dialog")
        self:closeBlockingDialog()
        UIManager:scheduleIn(1, function()
            UIManager:show(InfoMessage:new({
                text = _("Focus Mode block has ended. Happy reading!"),
                timeout = 3,
            }))
        end)
        return
    end

    -- Update countdown text widget directly (no need to recreate dialog)
    if self.countdown_text_widget and self.focus_mode_dialog then
        self.countdown_text_widget:setText(self:buildBlockingDialogText())
        UIManager:setDirty(self.focus_mode_dialog, "ui")
    end

    -- Schedule next countdown update
    self:scheduleCountdownUpdate()
end

-- Show PIN bypass dialog
function FocusMode:showPinBypassDialog()
    -- Hide the blocking dialog while PIN dialog is open (keep is_blocking true)
    if self.focus_mode_dialog then
        -- Use "full" refresh to force complete e-ink screen clear
        UIManager:close(self.focus_mode_dialog, "full")
        self.focus_mode_dialog = nil
        self.countdown_text_widget = nil
    end
    -- Cancel countdown timer while PIN dialog is shown
    self:cancelCountdownTimer()

    -- Schedule PIN dialog to appear after e-ink display has completed full refresh
    local pin_dialog
    pin_dialog = InputDialog:new({
        title = _("Enter Bypass PIN"),
        input = "",
        input_type = "number",
        input_hint = _("Enter your PIN to bypass"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(pin_dialog, "full")
                        -- Reshow blocking dialog since user cancelled
                        UIManager:scheduleIn(1, function()
                            self:showBlockingDialog()
                        end)
                    end,
                },
                {
                    text = _("Confirm"),
                    is_enter_default = true,
                    callback = function()
                        local entered_pin = pin_dialog:getInputText()
                        local stored_pin = self:readSubSetting("bypass_pin")

                        if entered_pin == stored_pin then
                            UIManager:close(pin_dialog, "full")
                            -- Fully close and clear blocking state
                            self.is_blocking = false
                            UIManager:scheduleIn(0.5, function()
                                UIManager:show(InfoMessage:new({
                                    text = _("PIN accepted. Focus Mode bypassed."),
                                    timeout = 2,
                                }))
                            end)
                        else
                            UIManager:close(pin_dialog, "full")
                            UIManager:scheduleIn(0.5, function()
                                UIManager:show(InfoMessage:new({
                                    text = _("Incorrect PIN. Try again."),
                                    timeout = 2,
                                }))
                            end)
                            -- Reshow blocking dialog after wrong PIN
                            UIManager:scheduleIn(3.5, function()
                                self:showBlockingDialog()
                            end)
                        end
                    end,
                },
            },
        },
    })
    UIManager:show(pin_dialog)
    pin_dialog:onShowKeyboard()
end

function FocusMode:onShowFocusModePopup(touchmenu_instance)
    -- Close menu if provided
    if touchmenu_instance then
        touchmenu_instance:closeMenu()
    end

    -- Close existing debug dialog if open
    if self.debug_html_dialog then
        UIManager:close(self.debug_html_dialog)
        self.debug_html_dialog = nil
    end

    self.debug_html_dialog = ButtonDialog:new({
        title = _("Focus Mode is active."),
        title_align = "center",
        dismissable = false,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.debug_html_dialog)
                        self.debug_html_dialog = nil
                    end,
                },
                {
                    text = _("Ok... :("),
                    callback = function()
                        UIManager:close(self.debug_html_dialog)
                        self.debug_html_dialog = nil
                        Dispatcher:execute({ filemanager = true })
                    end,
                },
            },
        },
    })

    UIManager:show(self.debug_html_dialog)
    return true
end

function FocusMode:onShowFocusModePopupWithImage(touchmenu_instance)
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
    local image_bb = RenderImage:renderImageFile(
        image_path,
        false,
        Device.screen:getWidth() * 0.15,
        Device.screen:getHeight() * 0.15
    )

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
