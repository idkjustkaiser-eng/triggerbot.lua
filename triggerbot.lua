-- Made by Crucial

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local CONFIG_FILE = "C_UI_config.json"
local MAX_TRIGGER_DISTANCE = 5000
local MAX_SHOOT_DELAY = 5
local SAVE_DEBOUNCE_TIME = 0.4
local SAVE_STATUS_RESET_TIME = 1.5
local GUI_CORNER = 10
local CIRCLE_CORNER = 999
local SIDEBAR_BUTTON_HEIGHT = 34
local WINDOW_SIZE = UDim2.new(0, 760, 0, 500)
local WINDOW_POSITION = UDim2.new(0.5, -380, 0.5, -250)

local connections = {}
local accentCallbacks = {}
local keybindRows = {}

local function trackConnection(conn)
    connections[#connections + 1] = conn
end

local function createInstance(class, props, parent, corner)
    local inst = Instance.new(class)
    if inst:IsA("GuiObject") then inst.BorderSizePixel = 0 end
    for key, value in props do inst[key] = value end
    inst.Parent = parent
    if corner then
        local cornerInstance = Instance.new("UICorner")
        cornerInstance.CornerRadius = corner >= CIRCLE_CORNER
            and UDim.new(1, 0)
            or UDim.new(0, corner)
        cornerInstance.Parent = inst
    end
    return inst
end

local function gray(value)
    return Color3.fromRGB(value, value, value)
end

local palette = {
    Blue = Color3.fromRGB(0, 140, 255),
    Purple = Color3.fromRGB(160, 100, 255),
    Pink = Color3.fromRGB(255, 80, 180),
    Red = Color3.fromRGB(230, 60, 60),
    Orange = Color3.fromRGB(255, 140, 50),
    Green = Color3.fromRGB(80, 210, 120),
    Cyan = Color3.fromRGB(60, 220, 220),
    White = Color3.fromRGB(230, 230, 230),
}

local accent = palette.Blue
local bg = gray(5)
local bgPanel = gray(8)
local bgSide = gray(10)
local bgItem = gray(18)
local txtWhite = gray(240)
local txtGray = Color3.fromRGB(140, 140, 145)
local txtHead = Color3.fromRGB(100, 100, 105)
local green = Color3.fromRGB(80, 200, 120)
local red = Color3.fromRGB(220, 80, 80)

local function onAccent(fn)
    accentCallbacks[#accentCallbacks + 1] = fn
end

local function bindAccent(element, property)
    onAccent(function()
        if element and element.Parent then element[property] = accent end
    end)
    if element and element.Parent then element[property] = accent end
end

local function setAccent(color)
    accent = color
    for _, callback in ipairs(accentCallbacks) do pcall(callback) end
end

local function serializeKey(key)
    if typeof(key) == "EnumItem" then return key.Name end
    return tostring(key)
end

local function saveConfig()
    if not writefile then return false end
    local data = {
        enabled = enabled,
        distance = distance,
        shootDelay = shootDelay,
        ignoreWalls = ignoreWalls,
        triggerKey = serializeKey(triggerKey),
        menuKey = serializeKey(menuKey),
        accentColorName = accentColorName,
        globalTeamCheck = globalTeamCheck,
        globalDeathCheck = globalDeathCheck,
    }
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if not ok then return false end
    return pcall(writefile, CONFIG_FILE, encoded)
end

local function loadConfig()
    if not (isfile and readfile) then return nil end
    local ok, exists = pcall(isfile, CONFIG_FILE)
    if not ok or not exists then return nil end
    local ok2, content = pcall(readfile, CONFIG_FILE)
    if not ok2 then return nil end
    local ok3, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not ok3 or type(data) ~= "table" then return nil end
    return data
end

local cfg = loadConfig() or {}

local enabled = true
local distance = math.clamp(tonumber(cfg.distance) or 1000, 1, MAX_TRIGGER_DISTANCE)
local shootDelay = math.clamp(tonumber(cfg.shootDelay) or 0.1, 0, MAX_SHOOT_DELAY)
local ignoreWalls = cfg.ignoreWalls == true
local triggerKey = Enum.KeyCode.Q
local menuKey = Enum.KeyCode.LeftBracket
local accentColorName = cfg.accentColorName or "Blue"
local globalTeamCheck = cfg.globalTeamCheck ~= false
local globalDeathCheck = cfg.globalDeathCheck ~= false

if palette[accentColorName] then accent = palette[accentColorName] end

local mouseClicked = false
local delayCheck = os.clock()
local lastWeaponSlot = 0
local unloadScript
local unloaded = false
local currentSection = "Combat"
local saveDebounce = false
local scheduleSave
local statusLabel

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function isTeammate(player)
    if not globalTeamCheck then return false end
    if not player or player == LocalPlayer then return false end
    if not player.Team or not LocalPlayer.Team then return false end
    return player.Team == LocalPlayer.Team
end

local function isLocalDead()
    local character = LocalPlayer.Character
    if not character or not character.Parent then return true end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or not humanoid.Parent then return true end
    return humanoid.Health <= 0
end

local function isTargetValid(player)
    if not player or player == LocalPlayer then return false end
    if isTeammate(player) then return false end
    local character = player.Character
    if not character or not character.Parent then return false end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or not humanoid.Parent then return false end
    return humanoid.Health > 0
end

local function isHoldingWeapon()
    return lastWeaponSlot == 2
end

local function updateRaycastFilter()
    local filterList = { Camera }
    local character = LocalPlayer.Character
    if character and character.Parent then
        filterList[#filterList + 1] = character
    end
    if ignoreWalls then
        local activeMaps = Workspace:FindFirstChild("ActiveMaps")
        if activeMaps then filterList[#filterList + 1] = activeMaps end
    end
    rayParams.FilterDescendantsInstances = filterList
end

local function getPlayerFromModel(model)
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character == model then return player end
    end
end

local function getRayFromCamera()
    if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return Camera.CFrame.Position, Camera.CFrame.LookVector
    end
    local mousePosition = UserInputService:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)
    return ray.Origin, ray.Direction
end

local function getTriggerTarget()
    local localCharacter = LocalPlayer.Character
    if not localCharacter or not localCharacter.Parent then return nil end
    updateRaycastFilter()
    local origin, direction = getRayFromCamera()
    local result = Workspace:Raycast(origin, direction * distance, rayParams)
    if not result or not result.Instance then return nil end
    local model = result.Instance:FindFirstAncestorOfClass("Model")
    while model do
        local player = getPlayerFromModel(model)
        if player then
            if player ~= LocalPlayer and isTargetValid(player) then return player end
            return nil
        end
        model = model:FindFirstAncestorOfClass("Model")
    end
end

local function isWindowFocused()
    if isrbxactive then
        local ok, active = pcall(isrbxactive)
        if ok and active ~= nil then return active end
    end
    return UserInputService.WindowFocused
end

local function canSendInput()
    return UserInputService:GetFocusedTextBox() == nil
end

local function simulateMousePress()
    if mouse1press then
        pcall(mouse1press)
        return
    end
    local position = UserInputService:GetMouseLocation()
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, true, game, 1)
    end)
end

local function simulateMouseRelease()
    if mouse1release then
        pcall(mouse1release)
        return
    end
    local position = UserInputService:GetMouseLocation()
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, false, game, 1)
    end)
end

local function releaseMouseIfClicked()
    if not mouseClicked then return end
    if isWindowFocused() then pcall(simulateMouseRelease) end
    mouseClicked = false
end

trackConnection(RunService.Heartbeat:Connect(function()
    local currentTime = os.clock()

    if globalDeathCheck and isLocalDead() then
        lastWeaponSlot = 0
        releaseMouseIfClicked()
        return
    end

    if not enabled then
        releaseMouseIfClicked()
        return
    end

    if not isWindowFocused() then
        releaseMouseIfClicked()
        return
    end

    if isHoldingWeapon() and getTriggerTarget() and canSendInput() then
        if delayCheck < currentTime then
            if mouseClicked then
                pcall(simulateMouseRelease)
                delayCheck = os.clock() + shootDelay
            else
                pcall(simulateMousePress)
            end
            mouseClicked = not mouseClicked
        end
    else
        releaseMouseIfClicked()
    end
end))

local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
local gui = createInstance("ScreenGui", {
    Name = "C_UI",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
}, guiParent)

local window = createInstance("Frame", {
    Size = WINDOW_SIZE,
    Position = WINDOW_POSITION,
    BackgroundColor3 = bg,
    Active = true,
}, gui, GUI_CORNER)

createInstance("UIStroke", { Color = gray(25), Thickness = 1 }, window)

local topbar = createInstance("Frame", {
    Size = UDim2.new(1, 0, 0, 45),
    BackgroundColor3 = bgPanel,
}, window, GUI_CORNER)

local logo = createInstance("TextLabel", {
    Size = UDim2.new(0, 45, 0, 45),
    Position = UDim2.new(0, 10, 0, 0),
    BackgroundTransparency = 1,
    Text = "C",
    TextScaled = true,
    Font = Enum.Font.GothamBlack,
}, window)
bindAccent(logo, "TextColor3")

local titleLabel = createInstance("TextLabel", {
    Size = UDim2.new(0, 200, 0, 45),
    Position = UDim2.new(0, 70, 0, 0),
    BackgroundTransparency = 1,
    Text = "Combat",
    TextColor3 = txtWhite,
    Font = Enum.Font.GothamBold,
    TextSize = 15,
    TextXAlignment = Enum.TextXAlignment.Left,
}, window)

local closeButton = createInstance("TextButton", {
    Size = UDim2.new(0, 28, 0, 28),
    Position = UDim2.new(1, -38, 0, 8),
    BackgroundColor3 = bgItem,
    Text = "x",
    TextColor3 = txtGray,
    TextSize = 18,
    Font = Enum.Font.GothamBold,
    AutoButtonColor = false,
}, window, CIRCLE_CORNER)

trackConnection(closeButton.MouseButton1Click:Connect(function()
    gui.Enabled = false
end))

local sidebar = createInstance("Frame", {
    Size = UDim2.new(0, 140, 1, -55),
    Position = UDim2.new(0, 10, 0, 50),
    BackgroundTransparency = 1,
}, window)

local sectionNames = { "Combat", "Settings" }
local sectionButtons = {}

for index, name in sectionNames do
    local button = createInstance("TextButton", {
        Size = UDim2.new(1, -5, 0, 30),
        Position = UDim2.new(0, 0, 0, (index - 1) * SIDEBAR_BUTTON_HEIGHT),
        BackgroundColor3 = bgSide,
        Text = "",
        AutoButtonColor = false,
    }, sidebar, 6)
    local label = createInstance("TextLabel", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.new(0, 14, 0, 0),
        BackgroundTransparency = 1,
        Text = name,
        TextColor3 = txtGray,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, button)
    sectionButtons[name] = { button = button, label = label }
end

local function applySectionStyles()
    for name, data in sectionButtons do
        local isActive = (name == currentSection)
        data.button.BackgroundColor3 = isActive and Color3.fromRGB(25, 35, 55) or bgSide
        data.label.TextColor3 = isActive and accent or txtGray
    end
end
onAccent(applySectionStyles)

local panelHost = createInstance("Frame", {
    Size = UDim2.new(1, -160, 1, -60),
    Position = UDim2.new(0, 155, 0, 55),
    BackgroundTransparency = 1,
}, window)

local panels = {}
for _, name in sectionNames do
    panels[name] = createInstance("Frame", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Visible = false,
    }, panelHost)
end

local panelCombat = panels.Combat
local panelSettings = panels.Settings

local function createHeader(panel, text)
    createInstance("TextLabel", {
        Size = UDim2.new(0, 260, 0, 18),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = txtHead,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, panel)
end

local function cancelPendingKeybinds()
    for _, entry in keybindRows do
        if entry.waiting then
            entry.waiting = false
            entry.textLabel.Text = entry.initial.Name
            entry.stroke.Color = gray(30)
        end
    end
end

local function createToggle(panel, text, yPosition, defaultValue, callback, xOffset)
    xOffset = xOffset or 0
    local container = createInstance("Frame", {
        Size = UDim2.new(0, 280, 0, 26),
        Position = UDim2.new(0, xOffset, 0, yPosition),
        BackgroundTransparency = 1,
    }, panel)
    local box = createInstance("Frame", {
        Size = UDim2.new(0, 16, 0, 16),
        Position = UDim2.new(0, 0, 0.5, -8),
    }, container, 4)
    local checkMark = createInstance("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "v",
        TextColor3 = Color3.new(1, 1, 1),
        TextSize = 12,
        Font = Enum.Font.GothamBold,
    }, box)
    createInstance("TextLabel", {
        Size = UDim2.new(1, -22, 1, 0),
        Position = UDim2.new(0, 22, 0, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = txtWhite,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, container)
    local clickArea = createInstance("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, container)

    local state = defaultValue
    local function applyVisual(value)
        box.BackgroundColor3 = value and accent or gray(30)
        checkMark.Visible = value
    end
    applyVisual(state)
    onAccent(function() applyVisual(state) end)

    trackConnection(clickArea.MouseButton1Click:Connect(function()
        state = not state
        applyVisual(state)
        if callback then callback(state) end
        if scheduleSave then scheduleSave() end
    end))
end

local function createSlider(panel, text, yPosition, minValue, maxValue, defaultValue, suffix, callback, isDecimal, xOffset)
    xOffset = xOffset or 0
    local container = createInstance("Frame", {
        Size = UDim2.new(0, 280, 0, 42),
        Position = UDim2.new(0, xOffset, 0, yPosition),
        BackgroundTransparency = 1,
    }, panel)
    createInstance("TextLabel", {
        Size = UDim2.new(0.65, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = txtWhite,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, container)
    local valueLabel = createInstance("TextLabel", {
        Size = UDim2.new(0.35, 0, 0, 16),
        Position = UDim2.new(0.65, 0, 0, 0),
        BackgroundTransparency = 1,
        TextColor3 = txtGray,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, container)
    local bar = createInstance("Frame", {
        Size = UDim2.new(1, 0, 0, 4),
        Position = UDim2.new(0, 0, 0, 28),
        BackgroundColor3 = gray(30),
    }, container, CIRCLE_CORNER)
    local fill = createInstance("Frame", {}, bar, CIRCLE_CORNER)
    bindAccent(fill, "BackgroundColor3")
    local knob = createInstance("Frame", {
        Size = UDim2.new(0, 12, 0, 12),
        Position = UDim2.new(0, -6, 0.5, -6),
        ZIndex = 2,
    }, bar, CIRCLE_CORNER)
    bindAccent(knob, "BackgroundColor3")

    local value = defaultValue
    local dragging = false

    local function applyValue(newValue)
        value = math.clamp(newValue, minValue, maxValue)
        local alpha = (value - minValue) / (maxValue - minValue)
        fill.Size = UDim2.new(alpha, 0, 1, 0)
        knob.Position = UDim2.new(alpha, -6, 0.5, -6)
        if isDecimal then
            valueLabel.Text = string.format("%.2f%s", value, suffix)
        else
            valueLabel.Text = tostring(math.floor(value + 0.5)) .. suffix
        end
        if callback then callback(value) end
    end
    applyValue(defaultValue)

    local function updateFromMouseX(mouseX)
        if not bar.Parent or not bar.Parent.Parent then return end
        local barWidth = bar.AbsoluteSize.X
        if barWidth <= 0 then return end
        local ratio = math.clamp((mouseX - bar.AbsolutePosition.X) / barWidth, 0, 1)
        applyValue(minValue + ratio * (maxValue - minValue))
    end

    local hitArea = createInstance("TextButton", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, container)

    trackConnection(hitArea.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = true
        updateFromMouseX(UserInputService:GetMouseLocation().X)
    end))

    trackConnection(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        updateFromMouseX(UserInputService:GetMouseLocation().X)
    end))

    trackConnection(UserInputService.InputEnded:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        dragging = false
        if scheduleSave then scheduleSave() end
    end))

    trackConnection((function()
        local connection
        connection = RunService.Heartbeat:Connect(function()
            if bar.Parent then return end
            dragging = false
            if connection then connection:Disconnect() end
        end)
        return connection
    end)())
end

local function createKeybind(panel, text, yPosition, initialKey, xOffset, onChanged)
    xOffset = xOffset or 0
    local row = createInstance("Frame", {
        Size = UDim2.new(0, 280, 0, 30),
        Position = UDim2.new(0, xOffset, 0, yPosition),
        BackgroundTransparency = 1,
    }, panel)
    createInstance("TextLabel", {
        Size = UDim2.new(0.5, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = txtWhite,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local button = createInstance("TextButton", {
        Size = UDim2.new(0.5, 0, 0, 24),
        Position = UDim2.new(0.5, 0, 0.5, -12),
        BackgroundColor3 = bgItem,
        Text = "",
        AutoButtonColor = false,
    }, row, 5)
    local stroke = createInstance("UIStroke", { Color = gray(30), Thickness = 1 }, button)
    local textLabel = createInstance("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text = initialKey.Name,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
    }, button)
    bindAccent(textLabel, "TextColor3")

    local entry = {
        button = button,
        stroke = stroke,
        textLabel = textLabel,
        initial = initialKey,
        waiting = false,
        onChanged = onChanged,
    }
    keybindRows[#keybindRows + 1] = entry

    trackConnection(button.MouseButton1Click:Connect(function()
        for _, other in keybindRows do
            if other ~= entry and other.waiting then
                other.waiting = false
                other.textLabel.Text = other.initial.Name
                other.stroke.Color = gray(30)
            end
        end
        entry.waiting = true
        textLabel.Text = "..."
        textLabel.TextColor3 = txtGray
        stroke.Color = accent
    end))
end

scheduleSave = function()
    if saveDebounce or unloaded then return end
    saveDebounce = true
    task.delay(SAVE_DEBOUNCE_TIME, function()
        saveDebounce = false
        if unloaded then return end
        local saved = saveConfig()
        if not statusLabel or not statusLabel.Parent then return end
        statusLabel.Text = saved and "Config saved" or "Save failed"
        statusLabel.TextColor3 = saved and green or red
        task.delay(SAVE_STATUS_RESET_TIME, function()
            if statusLabel and statusLabel.Parent then
                statusLabel.Text = "Auto-save active"
                statusLabel.TextColor3 = txtGray
            end
        end)
    end)
end

createHeader(panelCombat, "TriggerBot")

createToggle(panelCombat, "TriggerBot", 24, enabled, function(value) enabled = value end, 0)
createToggle(panelCombat, "Ignore Walls", 52, ignoreWalls, function(value) ignoreWalls = value end, 0)

createKeybind(panelCombat, "Trigger Keybind", 82, triggerKey, 0, function(key)
    triggerKey = key
end)

createSlider(panelCombat, "Next Shot Delay", 116, 0, 1, shootDelay, "s", function(value)
    shootDelay = value
end, true, 0)

createSlider(panelCombat, "Trigger Distance", 164, 0, 1000, distance, " studs", function(value)
    distance = value
end, false, 0)

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 14),
    Position = UDim2.new(0, 0, 0, 216),
    BackgroundTransparency = 1,
    Text = "Press 2 to arm, press 1 to disarm",
    TextColor3 = txtGray,
    Font = Enum.Font.GothamMedium,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelCombat)

createHeader(panelSettings, "Appearance")

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 16),
    Position = UDim2.new(0, 0, 0, 24),
    BackgroundTransparency = 1,
    Text = "Accent Color",
    TextColor3 = txtWhite,
    Font = Enum.Font.GothamMedium,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelSettings)

local accentRow = createInstance("Frame", {
    Size = UDim2.new(0, 280, 0, 30),
    Position = UDim2.new(0, 0, 0, 44),
    BackgroundTransparency = 1,
}, panelSettings)

local accentButtons = {}

local function refreshAccentButtons()
    for name, button in accentButtons do
        if button.UIStroke then
            button.UIStroke.Transparency = (name == accentColorName) and 0 or 0.7
        end
    end
end

for index, name in ipairs({ "Blue", "Purple", "Pink", "Red", "Orange", "Green", "Cyan", "White" }) do
    local button = createInstance("TextButton", {
        Size = UDim2.new(0, 28, 0, 28),
        Position = UDim2.new(0, (index - 1) * 34, 0, 0),
        BackgroundColor3 = palette[name],
        Text = "",
        AutoButtonColor = false,
    }, accentRow, 4)
    createInstance("UIStroke", {
        Color = Color3.new(1, 1, 1),
        Thickness = 2,
        Transparency = (name == accentColorName) and 0 or 0.7,
    }, button)
    accentButtons[name] = button

    trackConnection(button.MouseButton1Click:Connect(function()
        accentColorName = name
        setAccent(palette[name])
        refreshAccentButtons()
        scheduleSave()
    end))
end

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 16),
    Position = UDim2.new(0, 0, 0, 90),
    BackgroundTransparency = 1,
    Text = "Keybinds",
    TextColor3 = txtHead,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelSettings)

createKeybind(panelSettings, "Menu Keybind", 112, menuKey, 0, function(key)
    menuKey = key
end)

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 18),
    Position = UDim2.new(0, 320, 0, 0),
    BackgroundTransparency = 1,
    Text = "Filters",
    TextColor3 = txtHead,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelSettings)

createToggle(panelSettings, "Global Team Check", 44, globalTeamCheck, function(value)
    globalTeamCheck = value
end, 320)

createToggle(panelSettings, "Global Death Check", 72, globalDeathCheck, function(value)
    globalDeathCheck = value
end, 320)

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 16),
    Position = UDim2.new(0, 320, 0, 112),
    BackgroundTransparency = 1,
    Text = "Auto-save",
    TextColor3 = txtHead,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelSettings)

local statusRow = createInstance("Frame", {
    Size = UDim2.new(0, 280, 0, 22),
    Position = UDim2.new(0, 320, 0, 134),
    BackgroundTransparency = 1,
}, panelSettings)

createInstance("Frame", {
    Size = UDim2.new(0, 8, 0, 8),
    Position = UDim2.new(0, 0, 0.5, -4),
    BackgroundColor3 = green,
}, statusRow, CIRCLE_CORNER)

statusLabel = createInstance("TextLabel", {
    Size = UDim2.new(1, -16, 1, 0),
    Position = UDim2.new(0, 16, 0, 0),
    BackgroundTransparency = 1,
    Text = "Auto-save active",
    TextColor3 = txtGray,
    Font = Enum.Font.GothamMedium,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, statusRow)

local resetButton = createInstance("TextButton", {
    Size = UDim2.new(0, 130, 0, 28),
    Position = UDim2.new(0, 320, 0, 166),
    BackgroundColor3 = bgItem,
    Text = "",
    AutoButtonColor = false,
}, panelSettings, 5)

createInstance("UIStroke", { Color = gray(40), Thickness = 1 }, resetButton)

createInstance("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "Reset Config",
    TextColor3 = txtWhite,
    Font = Enum.Font.GothamBold,
    TextSize = 12,
}, resetButton)

trackConnection(resetButton.MouseButton1Click:Connect(function()
    if delfile then pcall(delfile, CONFIG_FILE) end
    if statusLabel and statusLabel.Parent then
        statusLabel.Text = "Config deleted, reopen script"
        statusLabel.TextColor3 = Color3.fromRGB(220, 180, 80)
    end
end))

createInstance("TextLabel", {
    Size = UDim2.new(0, 280, 0, 16),
    Position = UDim2.new(0, 320, 0, 210),
    BackgroundTransparency = 1,
    Text = "Danger Zone",
    TextColor3 = txtHead,
    Font = Enum.Font.GothamBold,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, panelSettings)

local unloadButton = createInstance("TextButton", {
    Size = UDim2.new(0, 160, 0, 30),
    Position = UDim2.new(0, 320, 0, 232),
    BackgroundColor3 = Color3.fromRGB(45, 15, 15),
    Text = "",
    AutoButtonColor = false,
}, panelSettings, 5)

createInstance("UIStroke", { Color = Color3.fromRGB(90, 30, 30), Thickness = 1 }, unloadButton)

createInstance("TextLabel", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1,
    Text = "Unload Script",
    TextColor3 = Color3.fromRGB(240, 140, 140),
    Font = Enum.Font.GothamBold,
    TextSize = 12,
}, unloadButton)

trackConnection(unloadButton.MouseButton1Click:Connect(function()
    if unloadScript then unloadScript() end
end))

local function activateSection(name)
    currentSection = name
    cancelPendingKeybinds()
    applySectionStyles()
    for sectionName, panel in panels do
        panel.Visible = (sectionName == name)
    end
    titleLabel.Text = name
end

for name, data in sectionButtons do
    trackConnection(data.button.MouseButton1Click:Connect(function()
        activateSection(name)
    end))
end

activateSection("Combat")

local draggingWindow = false
local dragStart
local windowStartPosition

trackConnection(topbar.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    draggingWindow = true
    dragStart = input.Position
    windowStartPosition = window.Position
end))

trackConnection(topbar.InputChanged:Connect(function(input)
    if not draggingWindow then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local delta = input.Position - dragStart
    window.Position = UDim2.new(
        windowStartPosition.X.Scale, windowStartPosition.X.Offset + delta.X,
        windowStartPosition.Y.Scale, windowStartPosition.Y.Offset + delta.Y
    )
end))

trackConnection(topbar.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    draggingWindow = false
end))

trackConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
    for _, entry in keybindRows do
        if not entry.waiting then continue end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        if input.KeyCode == Enum.KeyCode.Escape then
            entry.waiting = false
            entry.textLabel.Text = entry.initial.Name
            entry.stroke.Color = gray(30)
        else
            entry.initial = input.KeyCode
            entry.textLabel.Text = input.KeyCode.Name
            entry.stroke.Color = gray(30)
            entry.waiting = false
            if entry.onChanged then entry.onChanged(input.KeyCode) end
            scheduleSave()
        end
        return
    end

    if gameProcessed then return end

    if input.KeyCode == menuKey then
        gui.Enabled = not gui.Enabled
    end

    if triggerKey ~= Enum.KeyCode.None and input.KeyCode == triggerKey then
        enabled = not enabled
        scheduleSave()
    end

    if input.KeyCode == Enum.KeyCode.One then
        lastWeaponSlot = 1
    elseif input.KeyCode == Enum.KeyCode.Two then
        lastWeaponSlot = 2
    end
end))

trackConnection(UserInputService.WindowFocusReleased:Connect(function()
    releaseMouseIfClicked()
end))

unloadScript = function()
    if unloaded then return end
    unloaded = true
    enabled = false
    releaseMouseIfClicked()
    for _, connection in connections do pcall(connection.Disconnect, connection) end
    table.clear(connections)
    if gui and gui.Parent then pcall(function() gui:Destroy() end) end
    statusLabel = nil
    print("unloaded")
end

print("loaded | menu: " .. menuKey.Name .. " | trigger: " .. triggerKey.Name)
