# KOReader Plugin Development Guide

## Overview
KOReader is a document viewer application supporting multiple e-ink devices and platforms. Plugins extend KOReader's functionality using Lua scripting with a comprehensive framework of UI components, document APIs, and system integration hooks.

## Core Architecture

### Plugin Structure
```
myplugin/
├── _meta.lua           # Plugin metadata and 
├── main.lua            # Core plugin logic
├── settings.lua        # Configuration UI (optional)
└── README.md          # Documentation
```

### Essential Metadata (_meta.lua)
```lua
local _ = require("gettext")
return {
    name = "myplugin",
    fullname = _("My Plugin"),
    description = _("Brief description of functionality"),
}
```

## Lua Best Practices for KOReader

### Module Loading
```lua
-- Always use KOReader's require system
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")  -- For translations

-- Lazy loading for heavy dependencies
local MyHeavyModule
local function getHeavyModule()
    if not MyHeavyModule then
        MyHeavyModule = require("myheavymodule")
    end
    return MyHeavyModule
end
```

### Widget Inheritance Pattern
```lua
local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
    is_enabled = true,
}

function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    -- Register event handlers
    self:onDispatcherRegisterActions()
end

function MyPlugin:addToMainMenu(menu_items)
    menu_items.my_plugin = {
        text = _("My Plugin"),
        callback = function()
            self:showDialog()
        end,
    }
end

return MyPlugin
```

### Event Handling
```lua
-- Register events in init
function MyPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

-- Implement event handlers
function MyPlugin:onCloseDocument()
    self:saveSettings()
end

function MyPlugin:onSaveSettings()
    self:saveSettings()
end

-- Always return true to indicate event was handled
function MyPlugin:onMyCustomEvent(args)
    -- Handle event
    return true
end
```

### Settings Management
```lua
local LuaSettings = require("luasettings")

function MyPlugin:init()
    self.settings = LuaSettings:open(("%s/%s"):format(
        DataStorage:getDataDir(),
        "myplugin.lua"
    ))
    
    -- Load with defaults
    self.enabled = self.settings:readSetting("enabled", true)
    self.threshold = self.settings:readSetting("threshold", 50)
end

function MyPlugin:saveSettings()
    self.settings:saveSetting("enabled", self.enabled)
    self.settings:saveSetting("threshold", self.threshold)
    self.settings:flush()
end
```

## UI Development

### Creating Dialogs
```lua
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

function MyPlugin:showInputDialog()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter value"),
        input = tostring(self.current_value),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("OK"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(input_dialog:getInputText())
                        if value then
                            self:processValue(value)
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end
```

### Menu Configuration
```lua
function MyPlugin:getMenuItems()
    return {
        {
            text = _("Enable feature"),
            checked_func = function() return self.enabled end,
            callback = function()
                self.enabled = not self.enabled
                self:saveSettings()
            end,
        },
        {
            text = _("Configure threshold"),
            keep_menu_open = true,
            callback = function()
                self:showInputDialog()
            end,
        },
        {
            text_func = function()
                return _("Status: ") .. (self:isActive() and _("Active") or _("Inactive"))
            end,
            separator = true,
        },
    }
end
```

### Notifications
```lua
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

-- Temporary notification
UIManager:show(InfoMessage:new{
    text = _("Operation completed"),
    timeout = 2,
})

-- Persistent message requiring dismissal
local Notification = require("ui/widget/notification")
UIManager:show(Notification:new{
    text = _("Important information"),
})
```

## Document Interaction

### Accessing Document Content
```lua
function MyPlugin:getCurrentPageText()
    if not self.ui.document then return nil end
    
    local page_no = self.ui.document:getCurrentPage()
    local text = self.ui.document:getPageText(page_no)
    return text
end

function MyPlugin:getDocumentMetadata()
    if not self.ui.document then return nil end
    
    return {
        title = self.ui.document:getProps().title,
        author = self.ui.document:getProps().authors,
        pages = self.ui.document:getPageCount(),
        current_page = self.ui.document:getCurrentPage(),
    }
end
```

### Highlights and Bookmarks
```lua
function MyPlugin:addHighlight(text, pos0, pos1)
    self.ui.highlight:addHighlight(pos0, pos1)
    -- Access highlight after creation
    local highlights = self.ui.highlight:getHighlights()
end

function MyPlugin:getBookmarks()
    return self.ui.bookmark:getBookmarkedPages()
end
```

## Network Operations

### HTTP Requests
```lua
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")

function MyPlugin:makeAPICall(endpoint, params)
    local url = self.api_url .. endpoint
    local response_body = {}
    
    local request_body = json.encode(params)
    
    local result, status, headers = http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#request_body),
        },
        source = ltn12.source.string(request_body),
        sink = ltn12.sink.table(response_body),
    }
    
    if status == 200 then
        return json.decode(table.concat(response_body))
    else
        return nil, "HTTP error: " .. tostring(status)
    end
end
```

### Async Operations
```lua
local function asyncTask(callback)
    -- Run task in background
    return function()
        local result = performLongOperation()
        callback(result)
    end
end

-- Schedule async with UI update
UIManager:scheduleIn(0.1, function()
    local task = asyncTask(function(result)
        UIManager:show(InfoMessage:new{
            text = _("Task completed: ") .. result,
        })
    end)
    task()
end)
```

## File System Operations

### Path Management
```lua
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

function MyPlugin:ensureDataDir()
    local dir = DataStorage:getDataDir() .. "/myplugin"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

function MyPlugin:listFiles(directory, extension)
    local files = {}
    for entry in lfs.dir(directory) do
        if entry:match("%." .. extension .. "$") then
            table.insert(files, entry)
        end
    end
    return files
end
```

### Reading and Writing Files
```lua
local util = require("util")

function MyPlugin:saveData(filename, data)
    local path = self:ensureDataDir() .. "/" .. filename
    local file = io.open(path, "w")
    if not file then return false end
    file:write(data)
    file:close()
    return true
end

function MyPlugin:loadData(filename)
    local path = self:ensureDataDir() .. "/" .. filename
    local file = io.open(path, "r")
    if not file then return nil end
    local data = file:read("*all")
    file:close()
    return data
end
```

## Performance Optimization

### Caching Strategies
```lua
function MyPlugin:init()
    self.cache = {}
    self.cache_timeout = 300  -- 5 minutes
    self.cache_timestamps = {}
end

function MyPlugin:getCached(key, generator_func)
    local now = os.time()
    if self.cache[key] and 
       self.cache_timestamps[key] and
       (now - self.cache_timestamps[key]) < self.cache_timeout then
        return self.cache[key]
    end
    
    local value = generator_func()
    self.cache[key] = value
    self.cache_timestamps[key] = now
    return value
end
```

### Memory Management
```lua
-- Clear references when done
function MyPlugin:onCloseDocument()
    self.large_data = nil
    self.cache = {}
    collectgarbage("collect")
end

-- Use weak tables for caches
function MyPlugin:init()
    self.weak_cache = setmetatable({}, {__mode = "v"})
end
```

## Testing and Debugging

### Logging
```lua
local logger = require("logger")

logger.info("MyPlugin: Initialization started")
logger.warn("MyPlugin: Configuration issue detected")
logger.err("MyPlugin: Failed to load resource", error_msg)
logger.dbg("MyPlugin: Debug value:", complex_table)
```

### Error Handling
```lua
function MyPlugin:safeOperation()
    local ok, result = pcall(function()
        return self:riskyOperation()
    end)
    
    if not ok then
        logger.err("MyPlugin: Operation failed:", result)
        UIManager:show(InfoMessage:new{
            text = _("Error: ") .. tostring(result),
        })
        return nil
    end
    return result
end
```

## Dispatcher Integration

### Registering Actions
```lua
function MyPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("myplugin_toggle", {
        category = "none",
        event = "MyPluginToggle",
        title = _("Toggle My Plugin"),
        general = true,
    })
end

function MyPlugin:onMyPluginToggle()
    self.enabled = not self.enabled
    self:saveSettings()
    return true
end
```

## Localization

### Using Translations
```lua
local _ = require("gettext")

-- Simple translation
local text = _("Hello, world!")

-- Translation with context
local text = C_("Menu item", "Open")

-- Plurals
local text = T(N_("One item", "%1 items", count), count)

-- String formatting
local text = T(_("Page %1 of %2"), current, total)
```

## Common Patterns

### Singleton Pattern
```lua
local MyPlugin = WidgetContainer:extend{
    name = "myplugin",
}

local instance = nil

function MyPlugin:getInstance()
    if not instance then
        instance = MyPlugin:new{}
    end
    return instance
end
```

### State Management
```lua
function MyPlugin:init()
    self.state = {
        active = false,
        last_page = 0,
        counters = {},
    }
end

function MyPlugin:updateState(changes)
    for key, value in pairs(changes) do
        self.state[key] = value
    end
    self:saveSettings()
    self:refreshUI()
end
```

## Resources and Documentation

### Official Documentation
- **API Documentation**: https://koreader.rocks/doc/index.html
- **GitHub Repository**: https://github.com/koreader/koreader
- **DeepWiki Guide**: https://deepwiki.com/koreader/koreader
- **Community Plugins**: https://github.com/huynle/koreader-plugins

### Key Modules to Study
- `frontend/ui/uimanager.lua` - UI lifecycle management
- `frontend/ui/widget/` - Widget components
- `frontend/document/` - Document handling
- `frontend/dispatcher.lua` - Action system
- `frontend/apps/reader/readerui.lua` - Reader integration

### Learning from Examples
Study built-in plugins in `plugins/` directory:
- `statistics.plugin` - Data tracking and UI
- `readertimer.plugin` - Background operations
- `vocabbuilder.plugin` - Document interaction
- `autofrontlight.plugin` - System integration

## Checklist for Plugin Development

- [ ] Plugin follows standard directory structure
- [ ] Metadata includes name, fullname, description
- [ ] Proper inheritance from WidgetContainer
- [ ] Menu registration in init()
- [ ] Settings persistence implemented
- [ ] Event handlers return true
- [ ] All user-facing strings use gettext
- [ ] Error handling with pcall where appropriate
- [ ] Logging for debugging purposes
- [ ] Memory cleanup in onCloseDocument
- [ ] Documentation in README.md
- [ ] Compatible with e-ink refresh patterns
- [ ] Tested on target devices

## Performance Considerations

1. **Minimize UI refreshes**: E-ink displays are slow; batch updates
2. **Cache aggressively**: Disk I/O is expensive on embedded devices
3. **Lazy load modules**: Reduce startup time
4. **Profile with logger.dbg**: Identify bottlenecks
5. **Respect memory constraints**: Test on low-end devices
6. **Use incremental processing**: Break long operations into chunks

## Security Best Practices

- Validate all user input before processing
- Sanitize file paths to prevent directory traversal
- Use HTTPS for network requests when possible
- Don't store sensitive data in plain text
- Respect user privacy in data collection
- Handle authentication tokens securely

---

*This guide covers the essential patterns for KOReader plugin development. Always refer to the official documentation and existing plugins for the most up-to-date practices.*

[KOReader Documentation](https://koreader.rocks/doc/index.html)
[KOReader GitHub Repository](https://github.com/koreader/koreader)
[KOReader DeepWiki](https://deepwiki.com/koreader/koreader)
[KOReader Community Plugins](https://github.com/huynle/koreader-plugins)