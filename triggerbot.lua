--Uk4lex

local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local Mouse = LocalPlayer:GetMouse()

local CONFIG_FILE = "Uk4lex_config.json"
local MAX_DISTANCE = 5000
local MAX_DELAY = 5
local SAVE_WAIT = 0.4

local connections = {}
local function keep(conn)
    connections[#connections + 1] = conn
    return conn
end

local function keyFromName(name)
    if type(name) ~= "string" or name == "None" or name == "" then return nil end
    local ok, key = pcall(function() return Enum.KeyCode[name] end)
    return ok and key or nil
end

local function keyToName(key)
    if key == nil then return "None" end
    if typeof(key) == "EnumItem" then return key.Name end
    return tostring(key)
end

local function colorToTable(c)
    if not c then return nil end
    return { R = c.R, G = c.G, B = c.B }
end

local function tableToColor(t)
    if type(t) ~= "table" or not t.R then return nil end
    return Color3.new(t.R, t.G, t.B)
end

local function readConfig()
    if not (isfile and readfile) then return nil end
    local ok, exists = pcall(isfile, CONFIG_FILE)
    if not ok or not exists then return nil end
    local ok2, raw = pcall(readfile, CONFIG_FILE)
    if not ok2 then return nil end
    local ok3, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok3 or type(data) ~= "table" then return nil end
    return data
end

local cfg = readConfig() or {}

local triggerOn = cfg.triggerActive == true
local autoOn = cfg.autoShootActive == true
local silentOn = cfg.silentAimActive == true
local hitboxOn = cfg.hitboxActive == true

local triggerDist = math.clamp(tonumber(cfg.distance) or 1000, 1, MAX_DISTANCE)
local shotDelay = math.clamp(tonumber(cfg.shootDelay) or 0.06, 0, MAX_DELAY)

local triggerBind = keyFromName(cfg.triggerKey)
local autoBind = keyFromName(cfg.autoShootKey)
local silentBind = keyFromName(cfg.silentAimKey)
local hitboxBind = keyFromName(cfg.hitboxKey)
local menuBind = keyFromName(cfg.menuKey)

local autoChance = math.clamp(tonumber(cfg.autoShootHitChance) or 100, 0, 100)
local silentChance = math.clamp(tonumber(cfg.silentAimHitChance) or 100, 0, 100)

local hbSize = math.clamp(tonumber(cfg.hitboxSize) or 10, 3, 15)
local hbAlpha = math.clamp(tonumber(cfg.hitboxTransparency) or 0.7, 0, 1)
local hbColor = tableToColor(cfg.hitboxColor) or Color3.fromRGB(255, 255, 255)
local accentColor = tableToColor(cfg.accentColor) or Color3.fromRGB(134, 53, 255)

local lastShot = os.clock()
local weaponSlot = 0
local unloadScript
local stopped = false
local savePending = false
local queueSave

local silentKey = nil
local silentRoll = true
local autoKey = nil
local autoRoll = true

local function writeConfig()
    if not writefile then return false end
    local data = {
        triggerActive = triggerOn,
        autoShootActive = autoOn,
        silentAimActive = silentOn,
        hitboxActive = hitboxOn,
        distance = triggerDist,
        shootDelay = shotDelay,
        triggerKey = keyToName(triggerBind),
        autoShootKey = keyToName(autoBind),
        silentAimKey = keyToName(silentBind),
        hitboxKey = keyToName(hitboxBind),
        menuKey = keyToName(menuBind),
        autoShootHitChance = autoChance,
        silentAimHitChance = silentChance,
        hitboxSize = hbSize,
        hitboxTransparency = hbAlpha,
        hitboxColor = colorToTable(hbColor),
        accentColor = colorToTable(accentColor),
    }
    local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
    if not ok then return false end
    return pcall(writefile, CONFIG_FILE, encoded)
end

queueSave = function()
    if savePending or stopped then return end
    savePending = true
    task.delay(SAVE_WAIT, function()
        savePending = false
        if stopped then return end
        writeConfig()
    end)
end

local rayFilter = RaycastParams.new()
rayFilter.FilterType = Enum.RaycastFilterType.Exclude
rayFilter.IgnoreWater = true

local teamCache = {}
local teamCacheTime = 0

local function getTeams(force)
    local now = os.clock()
    if not force and now - teamCacheTime < 0.12 then return teamCache end
    teamCacheTime = now
    local map = {}
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    local score = pg and pg:FindFirstChild("IngameScore", true)
    if score then
        local red = score:FindFirstChild("TeamRed")
        local blue = score:FindFirstChild("TeamBlue")
        if red then for _, e in ipairs(red:GetChildren()) do map[string.lower(e.Name)] = "Red" end end
        if blue then for _, e in ipairs(blue:GetChildren()) do map[string.lower(e.Name)] = "Blue" end end
    end
    teamCache = map
    return map
end

local function teamOf(p)
    if not p then return nil end
    local map = getTeams(false)
    local t = map[string.lower(p.Name)] or (p.DisplayName and map[string.lower(p.DisplayName)])
    if t then return t end
    local attr = p:GetAttribute("Team") or p:GetAttribute("team")
    if attr ~= nil and tostring(attr) ~= "" then return tostring(attr) end
    if p.Team then return p.Team.Name end
    local tc = p.TeamColor
    if tc and tc.Name ~= "White" and tc.Name ~= "Medium stone grey" then return "Color:" .. tc.Name end
    return nil
end

local function enemies(a, b)
    if not a or not b or a == b then return false end
    local ta, tb = teamOf(a), teamOf(b)
    if ta and tb then return ta ~= tb end
    return true
end

local function isFoe(p)
    if not p or p == LocalPlayer then return false end
    return enemies(LocalPlayer, p)
end

local function dead()
    local char = LocalPlayer.Character
    if not char or not char.Parent then return true end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or not hum.Parent then return true end
    return hum.Health <= 0
end

local function isWeapon(t)
    if not t then return false end
    local beam = t:FindFirstChild("showBeam")
    return beam and beam:IsA("RemoteEvent")
end

local function heldTool()
    local char = LocalPlayer.Character
    return char and char:FindFirstChildOfClass("Tool")
end

local function hasWeapon() return isWeapon(heldTool()) end
local function armed() return weaponSlot == 2 end

local function refreshRay()
    local list = { Camera }
    local char = LocalPlayer.Character
    if char and char.Parent then list[#list + 1] = char end
    rayFilter.FilterDescendantsInstances = list
end

local function cameraRay()
    if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
        return Camera.CFrame.Position, Camera.CFrame.LookVector
    end
    local p = UserInputService:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(p.X, p.Y)
    return ray.Origin, ray.Direction
end

local function ownerOf(model)
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character == model then return plr end
    end
end

local function visible(target, point)
    local mine = LocalPlayer.Character
    if not mine or not target then return false end
    local originPart = mine:FindFirstChild("Head") or mine:FindFirstChild("HumanoidRootPart")
    local origin = originPart and originPart.Position or Camera.CFrame.Position
    local dir = point - origin
    if dir.Magnitude <= 0.001 then return true end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { mine, target }
    params.IgnoreWater = true
    return Workspace:Raycast(origin, dir, params) == nil
end

local function triggerTarget()
    local mine = LocalPlayer.Character
    if not mine or not mine.Parent then return nil end
    refreshRay()
    local origin, dir = cameraRay()
    local hit = Workspace:Raycast(origin, dir * triggerDist, rayFilter)
    if hit and hit.Instance then
        local model = hit.Instance:FindFirstAncestorOfClass("Model")
        while model do
            local plr = ownerOf(model)
            if plr then
                if plr ~= LocalPlayer and isFoe(plr) then
                    local hum = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then return plr, hit.Instance end
                end
                return nil
            end
            model = model:FindFirstAncestorOfClass("Model")
        end
    end
end

local function focused()
    if isrbxactive then
        local ok, active = pcall(isrbxactive)
        if ok and active ~= nil then return active end
    end
    return UserInputService.WindowFocused
end

local function typing()
    return UserInputService:GetFocusedTextBox() == nil
end

local function partsOf(char)
    local list = {}
    if not char then return list end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
            local node = part.Parent
            local skip = false
            while node and node ~= char do
                if node:IsA("Accessory") or node:IsA("Tool") then
                    skip = true
                    break
                end
                node = node.Parent
            end
            if not skip then list[#list + 1] = part end
        end
    end
    return list
end

local function pickClosestToCursor()
    local mine = LocalPlayer.Character
    if not mine then return nil, nil, nil end
    local hum = mine:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil, nil, nil end

    local best, bestPart, bestChar, bestDist = nil, nil, nil, math.huge
    local cursor = UserInputService:GetMouseLocation()

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isFoe(plr) and plr.Character then
            local ph = plr.Character:FindFirstChildOfClass("Humanoid")
            if ph and ph.Health > 0 then
                for _, part in ipairs(partsOf(plr.Character)) do
                    local p2, on = Camera:WorldToViewportPoint(part.Position)
                    if on and p2.Z > 0 then
                        local d = (Vector2.new(p2.X, p2.Y) - cursor).Magnitude
                        if d < bestDist and visible(plr.Character, part.Position) then
                            bestDist = d
                            best = plr
                            bestPart = part
                            bestChar = plr.Character
                        end
                    end
                end
            end
        end
    end
    return best, bestPart, bestChar
end

local function silentPick()
    return pickClosestToCursor()
end

local function autoPick()
    return pickClosestToCursor()
end

local hbParts = {}

local function dropHb(char)
    if not char then return end
    local hb = char:FindFirstChild("GhostHitbox")
    if hb then hb:Destroy() end
    for plr, part in pairs(hbParts) do
        if part and part.Parent == char then hbParts[plr] = nil end
    end
end

local function makeHb(plr)
    if not plr or plr == LocalPlayer then return end
    local char = plr.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not root or not hum or hum.Health <= 0 then return end

    local hb = char:FindFirstChild("GhostHitbox")
    if not hb then
        hb = Instance.new("Part")
        hb.Name = "GhostHitbox"
        hb.Size = Vector3.new(hbSize, hbSize, hbSize)
        hb.Transparency = hbAlpha
        hb.Color = hbColor
        hb.CanCollide = false
        hb.Massless = true
        hb.Anchored = false
        hb.CFrame = root.CFrame
        hb.Parent = char

        local weld = Instance.new("WeldConstraint")
        weld.Part0 = root
        weld.Part1 = hb
        weld.Parent = hb

        hbParts[plr] = hb
    else
        hb.Size = Vector3.new(hbSize, hbSize, hbSize)
        hb.Transparency = hbAlpha
        hb.Color = hbColor
    end
end

local function hbLoop()
    if not hitboxOn then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then dropHb(plr.Character) end
        end
        return
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isFoe(plr) and plr.Character then
            local hum = plr.Character:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                makeHb(plr)
            else
                dropHb(plr.Character)
            end
        else
            if plr.Character then dropHb(plr.Character) end
        end
    end
end

keep(RunService.Heartbeat:Connect(hbLoop))

local rawMeta = (typeof(getrawmetatable) == "function") and getrawmetatable or nil
local setRO = (typeof(setreadonly) == "function") and setreadonly or nil
local checkCaller = (typeof(checkcaller) == "function") and checkcaller or nil

local silentLast = nil
local autoLast = nil
local restoreHook = nil

if rawMeta and setRO and checkCaller then
    pcall(function()
        local mt = rawMeta(Mouse)
        if mt and mt.__index then
            local original = mt.__index
            restoreHook = function()
                pcall(function()
                    setRO(mt, false)
                    mt.__index = original
                    setRO(mt, true)
                end)
            end
            setRO(mt, false)
            mt.__index = function(self, key)
                if checkCaller() then return original(self, key) end
                if self == Mouse and key == "Hit" then
                    if silentOn then
                        local ok, target, part = pcall(silentPick)
                        if ok and target and part then
                            local tag = tostring(target.UserId) .. ":" .. part.Name
                            if tag ~= silentKey then
                                silentKey = tag
                                silentRoll = math.random(1, 100) <= silentChance
                            end
                            if silentRoll then
                                silentLast = target
                                return CFrame.new(part.Position)
                            end
                        end
                    end
                    if autoOn then
                        local ok, target, part = pcall(autoPick)
                        if ok and target and part then
                            autoLast = target
                            return CFrame.new(part.Position)
                        end
                    end
                end
                return original(self, key)
            end
            setRO(mt, true)
        end
    end)
end

keep(RunService.RenderStepped:Connect(function()
    if stopped then return end
    if dead() then weaponSlot = 0 return end

    if autoOn then
        local char = LocalPlayer.Character
        if char then
            local tool = char:FindFirstChildOfClass("Tool")
            if tool and tool:FindFirstChild("Handle") and isWeapon(tool) then
                if not focused() or not typing() then
                    autoLast = nil
                else
                    local ok, target, part = pcall(autoPick)
                    if ok and target and part then
                        local tag = tostring(target.UserId) .. ":" .. part.Name
                        if tag ~= autoKey then
                            autoKey = tag
                            autoRoll = math.random(1, 100) <= autoChance
                        end
                        if autoRoll then
                            autoLast = target
                            pcall(function()
                                tool:Activate()
                                task.delay(0.05, function()
                                    if tool and tool.Parent then tool:Deactivate() end
                                end)
                            end)
                        else
                            autoLast = nil
                        end
                    else
                        autoLast = nil
                    end
                end
            else
                autoLast = nil
            end
        end
    end

    if not triggerOn then return end
    if not armed() then return end
    if not hasWeapon() then return end

    local target = triggerTarget()
    if target then
        local now = os.clock()
        if now - lastShot >= shotDelay then
            lastShot = now
            local tool = heldTool()
            if tool then
                for _ = 1, 2 do
                    pcall(function() tool:Activate() end)
                end
                task.delay(0.04, function()
                    if tool and tool.Parent then pcall(function() tool:Deactivate() end) end
                end)
            end
        end
    end
end))

local UI = {}
do
    local THEMES = {
        grape = {
            Primary = Color3.fromRGB(134, 53, 255),
            Secondary = Color3.fromRGB(211, 53, 255),
            Window1 = Color3.fromRGB(20, 20, 20),
            Window2 = Color3.fromRGB(10, 10, 10),
            Window3 = Color3.fromRGB(15, 15, 15),
            Button1 = Color3.fromRGB(15, 15, 15),
            Button2 = Color3.fromRGB(20, 20, 20),
            Button3 = Color3.fromRGB(35, 35, 35),
            Stroke = Color3.fromRGB(34, 34, 34),
            TextPrimary = Color3.fromRGB(255, 255, 255),
            TextDim = Color3.fromRGB(164, 164, 164),
        }
    }

    local function make(class, props, parent)
        local inst = Instance.new(class)
        for k, v in pairs(props) do inst[k] = v end
        inst.Parent = parent
        return inst
    end

    local function round(parent, radius)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, radius or 3)
        c.Parent = parent
        return c
    end

    local function outline(parent, color, thickness)
        local s = Instance.new("UIStroke")
        s.Color = color
        s.Thickness = thickness or 1
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Parent = parent
        return s
    end

    local function pad(parent, l, r, t, b)
        local p = Instance.new("UIPadding")
        p.PaddingLeft = UDim.new(0, l or 0)
        p.PaddingRight = UDim.new(0, r or 0)
        p.PaddingTop = UDim.new(0, t or 0)
        p.PaddingBottom = UDim.new(0, b or 0)
        p.Parent = parent
        return p
    end

    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local screen = make("ScreenGui", {
        Name = "Uk4lex",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        IgnoreGuiInset = true,
        DisplayOrder = 99999,
    }, parent)

    local api = {}
    api.__index = api

    function api.new(config)
        local self = setmetatable({}, api)
        self.theme = THEMES[config.theme] or THEMES.grape
        self.rounding = config.rounding ~= false
        self.size = config.size or Vector2.new(650, 450)
        self.position = config.position or UDim2.new(0.5, -self.size.X / 2, 0.5, -self.size.Y / 2)
        self.binds = {}
        self.accentHooks = {}
        self.screen = screen
        self:_window()
        self:_bindListener()
        api.instance = self
        return self
    end

    function api:onAccent(fn)
        self.accentHooks[#self.accentHooks + 1] = fn
    end

    function api:setAccent(color)
        self.theme.Primary = color
        self.theme.Secondary = color
        for _, fn in ipairs(self.accentHooks) do pcall(fn, color) end
    end

    function api:_window()
        local t = self.theme
        local main = make("Frame", {
            Name = "Main",
            Size = UDim2.fromOffset(self.size.X, self.size.Y),
            Position = self.position,
            BackgroundColor3 = t.Window2,
            BorderSizePixel = 0,
            Active = true,
        }, screen)
        self.main = main
        self.visible = true
        outline(main, t.Stroke, 1)

        local top = make("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            Position = UDim2.fromOffset(0, -1),
            BackgroundColor3 = t.Primary,
            BorderSizePixel = 0,
            ZIndex = 5,
        }, main)
        local grad = Instance.new("UIGradient")
        grad.Color = ColorSequence.new(t.Primary, t.Secondary)
        grad.Parent = top
        self:onAccent(function(c)
            grad.Color = ColorSequence.new(c, c)
        end)

        local bar = make("Frame", {
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = t.Window1,
            BorderSizePixel = 0,
            Active = true,
            ZIndex = 5,
        }, main)
        round(bar, self.rounding and 3 or 0)
        outline(bar, t.Stroke, 1)

        make("TextLabel", {
            Size = UDim2.new(1, -80, 1, 0),
            Position = UDim2.fromOffset(12, 0),
            BackgroundTransparency = 1,
            Text = "Uk4lex",
            TextColor3 = t.TextPrimary,
            Font = Enum.Font.GothamBold,
            TextSize = 15,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 6,
        }, bar)

        local close = make("TextButton", {
            Size = UDim2.fromOffset(20, 20),
            Position = UDim2.new(1, -23, 0, 3),
            BackgroundColor3 = t.Button1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 6,
        }, bar)
        round(close, self.rounding and 3 or 0)
        outline(close, t.Stroke, 1)
        make("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "x",
            TextColor3 = t.TextPrimary,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            ZIndex = 7,
        }, close)
        close.MouseButton1Click:Connect(function() self:setVisible(false) end)

        local min = make("TextButton", {
            Size = UDim2.fromOffset(20, 20),
            Position = UDim2.new(1, -47, 0, 3),
            BackgroundColor3 = t.Button1,
            Text = "",
            AutoButtonColor = false,
            ZIndex = 6,
        }, bar)
        round(min, self.rounding and 3 or 0)
        outline(min, t.Stroke, 1)
        make("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = "-",
            TextColor3 = t.TextPrimary,
            Font = Enum.Font.GothamBold,
            TextSize = 16,
            ZIndex = 7,
        }, min)

        local side = make("Frame", {
            Size = UDim2.new(0, 125, 1, -26),
            Position = UDim2.fromOffset(0, 26),
            BackgroundColor3 = t.Window3,
            BorderSizePixel = 0,
            ZIndex = 3,
        }, main)
        outline(side, t.Stroke, 1)
        pad(side, 4, 4, 6, 6)
        make("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, side)
        self.side = side
        self.tabs = {}
        self.pages = {}

        local pageHost = make("Frame", {
            Size = UDim2.new(1, -125, 1, -26),
            Position = UDim2.fromOffset(125, 26),
            BackgroundColor3 = t.Window2,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            ZIndex = 2,
        }, main)
        self.pageHost = pageHost

        local drag, dragStart, startPos
        bar.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                drag = true
                dragStart = input.Position
                startPos = main.Position
            end
        end)
        bar.InputChanged:Connect(function(input)
            if drag and input.UserInputType == Enum.UserInputType.MouseMovement then
                local delta = input.Position - dragStart
                main.Position = UDim2.new(
                    startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y
                )
            end
        end)
        bar.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
        end)
    end

    function api:setVisible(v)
        self.visible = v
        self.main.Visible = v
    end

    function api:toggleVisible()
        self:setVisible(not self.visible)
    end

    function api:addMenu(name)
        local t = self.theme
        local idx = #self.tabs + 1

        local btn = make("TextButton", {
            Size = UDim2.new(1, 0, 0, 26),
            BackgroundColor3 = t.Button1,
            Text = "",
            AutoButtonColor = false,
            LayoutOrder = idx,
            ZIndex = 4,
        }, self.side)
        round(btn, self.rounding and 3 or 0)
        outline(btn, t.Stroke, 1)
        local label = make("TextLabel", {
            Size = UDim2.new(1, -16, 1, 0),
            Position = UDim2.fromOffset(10, 0),
            BackgroundTransparency = 1,
            Text = name,
            TextColor3 = t.TextDim,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 5,
        }, btn)

        local page = make("ScrollingFrame", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = t.Stroke,
            Visible = false,
            ZIndex = 3,
        }, self.pageHost)
        pad(page, 8, 8, 8, 8)
        make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, page)

        self.tabs[name] = { button = btn, label = label }
        self.pages[name] = page

        btn.MouseButton1Click:Connect(function() self:selectMenu(name) end)

        local menu = { name = name, _ui = self, _page = page }
        function menu:addSection(cfg)
            return self._ui:_section(self._page, cfg)
        end
        return menu
    end

    function api:selectMenu(name)
        local t = self.theme
        for n, data in pairs(self.tabs) do
            if n == name then
                data.button.BackgroundColor3 = t.Button3
                data.label.TextColor3 = t.Primary
            else
                data.button.BackgroundColor3 = t.Button1
                data.label.TextColor3 = t.TextDim
            end
        end
        for n, page in pairs(self.pages) do
            page.Visible = (n == name)
        end
    end

    function api:_section(parent, cfg)
        local t = self.theme
        local section = make("Frame", {
            Size = UDim2.new(1, 0, 0, 30),
            BackgroundColor3 = t.Window3,
            BorderSizePixel = 0,
            AutomaticSize = Enum.AutomaticSize.Y,
            ZIndex = 4,
        }, parent)
        round(section, self.rounding and 3 or 0)
        outline(section, t.Stroke, 1)
        pad(section, 8, 8, 6, 8)
        make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, section)

        make("TextLabel", {
            Size = UDim2.new(1, 0, 0, 16),
            BackgroundTransparency = 1,
            Text = cfg.text or "Section",
            TextColor3 = t.TextPrimary,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = 0,
            ZIndex = 5,
        }, section)

        local body = make("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            BackgroundTransparency = 1,
            AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = 1,
            ZIndex = 5,
        }, section)
        make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, body)

        local ui = self
        local sec = { _body = body, _ui = ui, order = 0, theme = t }

        function sec:addToggle(cfg2)
            sec.order = sec.order + 1
            local row = make("Frame", {
                Size = UDim2.new(1, 0, 0, 26),
                BackgroundTransparency = 1,
                LayoutOrder = sec.order,
                ZIndex = 5,
            }, body)

            local box = make("Frame", {
                Size = UDim2.fromOffset(16, 16),
                Position = UDim2.new(0, 0, 0.5, -8),
                BackgroundColor3 = cfg2.state and t.Primary or t.Button1,
                BorderSizePixel = 0,
                ZIndex = 6,
            }, row)
            round(box, ui.rounding and 3 or 0)
            outline(box, t.Stroke, 1)
            local tick = make("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "v",
                TextColor3 = Color3.new(1, 1, 1),
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                Visible = cfg2.state and true or false,
                ZIndex = 7,
            }, box)

            make("TextLabel", {
                Size = UDim2.new(1, -24, 1, 0),
                Position = UDim2.fromOffset(24, 0),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Toggle",
                TextColor3 = t.TextPrimary,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 6,
            }, row)

            local hit = make("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                ZIndex = 8,
            }, row)

            local on = cfg2.state and true or false
            local listeners = {}
            local handle = {}

            local function render(v)
                on = v
                box.BackgroundColor3 = v and t.Primary or t.Button1
                tick.Visible = v
            end
            render(on)
            ui:onAccent(function() render(on) end)

            hit.MouseButton1Click:Connect(function()
                render(not on)
                for _, fn in ipairs(listeners) do pcall(fn, on) end
            end)

            function handle:bindToEvent(name, fn)
                if name == "onToggle" then listeners[#listeners + 1] = fn end
                return handle
            end
            function handle:set(v)
                render(v)
                for _, fn in ipairs(listeners) do pcall(fn, on) end
            end
            function handle:get() return on end

            return handle
        end

        function sec:addSlider(cfg2, callback)
            sec.order = sec.order + 1
            local min = cfg2.min or 0
            local max = cfg2.max or 100
            local step = cfg2.step or 1
            local val = math.clamp(cfg2.val or min, min, max)

            local row = make("Frame", {
                Size = UDim2.new(1, 0, 0, 38),
                BackgroundTransparency = 1,
                LayoutOrder = sec.order,
                ZIndex = 5,
            }, body)

            make("TextLabel", {
                Size = UDim2.new(0.6, 0, 0, 14),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Slider",
                TextColor3 = t.TextPrimary,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 6,
            }, row)

            local readout = make("TextLabel", {
                Size = UDim2.new(0.4, 0, 0, 14),
                Position = UDim2.new(0.6, 0, 0, 0),
                BackgroundTransparency = 1,
                Text = tostring(val),
                TextColor3 = t.TextDim,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Right,
                ZIndex = 6,
            }, row)

            local bar = make("Frame", {
                Size = UDim2.new(1, 0, 0, 4),
                Position = UDim2.new(0, 0, 0, 26),
                BackgroundColor3 = t.Button1,
                BorderSizePixel = 0,
                ZIndex = 6,
            }, row)
            round(bar, 2)

            local fill = make("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = t.Primary,
                BorderSizePixel = 0,
                ZIndex = 7,
            }, bar)
            round(fill, 2)
            ui:onAccent(function(c) fill.BackgroundColor3 = c end)

            local hit = make("TextButton", {
                Size = UDim2.new(1, 0, 0, 20),
                Position = UDim2.new(0, 0, 0, 18),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
                ZIndex = 9,
            }, row)

            local function apply(v)
                val = math.clamp(v, min, max)
                local a = (max - min > 0) and ((val - min) / (max - min)) or 0
                fill.Size = UDim2.new(a, 0, 1, 0)
                readout.Text = (step < 1) and string.format("%.2f", val) or tostring(math.floor(val + 0.5))
                if callback then pcall(callback, val) end
            end
            apply(val)

            local dragging = false
            local function move(x)
                local ap = bar.AbsolutePosition.X
                local as = bar.AbsoluteSize.X
                if as <= 0 then return end
                local a = math.clamp((x - ap) / as, 0, 1)
                local raw = min + a * (max - min)
                apply(math.floor(raw / step + 0.5) * step)
            end

            hit.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragging = true
                    move(input.Position.X)
                end
            end)
            UserInputService.InputChanged:Connect(function(input)
                if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                    move(input.Position.X)
                end
            end)
            UserInputService.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
            end)

            return { set = apply, get = function() return val end }
        end

        function sec:addButton(cfg2, callback)
            sec.order = sec.order + 1
            local h = (cfg2.style == "large") and 30 or 24

            local btn = make("TextButton", {
                Size = UDim2.new(1, 0, 0, h),
                BackgroundColor3 = t.Button1,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = sec.order,
                ZIndex = 6,
            }, body)
            round(btn, ui.rounding and 3 or 0)
            outline(btn, t.Stroke, 1)

            local label = make("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Button",
                TextColor3 = t.TextPrimary,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                ZIndex = 7,
            }, btn)

            btn.MouseEnter:Connect(function() btn.BackgroundColor3 = t.Button2 end)
            btn.MouseLeave:Connect(function() btn.BackgroundColor3 = t.Button1 end)
            if callback then
                btn.MouseButton1Click:Connect(function() pcall(callback) end)
            end

            return { setText = function(s) label.Text = s end, button = btn }
        end

        function sec:addLabel(cfg2)
            sec.order = sec.order + 1
            local label = make("TextLabel", {
                Size = UDim2.new(1, 0, 0, 16),
                BackgroundTransparency = 1,
                Text = cfg2.text or "",
                TextColor3 = t.TextDim,
                Font = Enum.Font.GothamMedium,
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                LayoutOrder = sec.order,
                ZIndex = 6,
            }, body)
            return { setText = function(s) label.Text = s end }
        end

        function sec:addKeybind(cfg2, callback)
            sec.order = sec.order + 1
            local initial = cfg2.key

            local row = make("Frame", {
                Size = UDim2.new(1, 0, 0, 26),
                BackgroundTransparency = 1,
                LayoutOrder = sec.order,
                ZIndex = 5,
            }, body)

            make("TextLabel", {
                Size = UDim2.new(0.5, 0, 1, 0),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Keybind",
                TextColor3 = t.TextPrimary,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 6,
            }, row)

            local btn = make("TextButton", {
                Size = UDim2.new(0.5, 0, 0, 22),
                Position = UDim2.new(0.5, 0, 0.5, -11),
                BackgroundColor3 = t.Button1,
                Text = "",
                AutoButtonColor = false,
                ZIndex = 6,
            }, row)
            round(btn, ui.rounding and 3 or 0)
            local btnStroke = outline(btn, t.Stroke, 1)

            local text = make("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = initial and initial.Name or "[ ... ]",
                TextColor3 = t.Primary,
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                ZIndex = 7,
            }, btn)
            ui:onAccent(function(c) text.TextColor3 = c end)

            local entry = {
                button = btn,
                stroke = btnStroke,
                label = text,
                current = initial,
                waiting = false,
                onChanged = callback,
                theme = t,
            }
            ui.binds[#ui.binds + 1] = entry

            btn.MouseButton1Click:Connect(function()
                for _, other in ipairs(ui.binds) do
                    if other ~= entry and other.waiting then
                        other.waiting = false
                        other.label.Text = other.current and other.current.Name or "[ ... ]"
                        other.stroke.Color = other.theme.Stroke
                    end
                end
                entry.waiting = true
                text.Text = "[ ... ]"
                btnStroke.Color = t.Primary
            end)

            return {
                get = function() return entry.current end,
                set = function(k)
                    entry.current = k
                    text.Text = k and k.Name or "[ ... ]"
                end,
                entry = entry,
            }
        end

        function sec:addColorPicker(cfg2, callback)
            sec.order = sec.order + 1
            local start = cfg2.color or Color3.fromRGB(134, 53, 255)
            local hue, sat, val = Color3.toHSV(start)

            local row = make("Frame", {
                Size = UDim2.new(1, 0, 0, 26),
                BackgroundTransparency = 1,
                LayoutOrder = sec.order,
                ZIndex = 5,
            }, body)

            make("TextLabel", {
                Size = UDim2.new(0.5, 0, 1, 0),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Color",
                TextColor3 = t.TextPrimary,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 6,
            }, row)

            local preview = make("TextButton", {
                Size = UDim2.new(0.5, 0, 0, 22),
                Position = UDim2.new(0.5, 0, 0.5, -11),
                BackgroundColor3 = start,
                Text = "",
                AutoButtonColor = false,
                ZIndex = 6,
            }, row)
            round(preview, ui.rounding and 3 or 0)
            outline(preview, t.Stroke, 1)

            local popup = make("Frame", {
                Size = UDim2.fromOffset(210, 285),
                Position = UDim2.new(0, 0, 0, 0),
                BackgroundColor3 = Color3.fromRGB(18, 18, 18),
                BorderSizePixel = 0,
                Visible = false,
                ZIndex = 50,
            }, screen)
            round(popup, 6)
            outline(popup, t.Stroke, 1)

            local header = make("Frame", {
                Size = UDim2.new(1, 0, 0, 22),
                BackgroundColor3 = Color3.fromRGB(25, 25, 25),
                BorderSizePixel = 0,
                ZIndex = 51,
            }, popup)
            round(header, 6)
            make("TextLabel", {
                Size = UDim2.new(1, -20, 1, 0),
                Position = UDim2.fromOffset(8, 0),
                BackgroundTransparency = 1,
                Text = cfg2.text or "Color",
                TextColor3 = Color3.fromRGB(230, 230, 230),
                Font = Enum.Font.GothamBold,
                TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                ZIndex = 52,
            }, header)

            local wheel = make("Frame", {
                Size = UDim2.fromOffset(160, 160),
                Position = UDim2.fromOffset(25, 30),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 52,
            }, popup)
            round(wheel, 999)

            local hueLayer = make("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.fromHSV(hue, 1, 1),
                BorderSizePixel = 0,
                ZIndex = 53,
            }, wheel)
            round(hueLayer, 999)

            local whiteLayer = make("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 54,
            }, wheel)
            round(whiteLayer, 999)
            local whiteGrad = Instance.new("UIGradient")
            whiteGrad.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(1, 1),
            })
            whiteGrad.Parent = whiteLayer

            local blackLayer = make("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Color3.fromRGB(0, 0, 0),
                BorderSizePixel = 0,
                ZIndex = 55,
            }, wheel)
            round(blackLayer, 999)
            local blackGrad = Instance.new("UIGradient")
            blackGrad.Rotation = 90
            blackGrad.Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 1),
                NumberSequenceKeypoint.new(1, 0),
            })
            blackGrad.Parent = blackLayer

            local marker = make("Frame", {
                Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
                ZIndex = 57,
            }, wheel)
            round(marker, 999)
            outline(marker, Color3.fromRGB(255, 255, 255), 2)
            make("Frame", {
                Size = UDim2.fromOffset(4, 4),
                Position = UDim2.new(0.5, -2, 0.5, -2),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 58,
            }, marker)

            local hueBar = make("Frame", {
                Size = UDim2.new(1, -20, 0, 14),
                Position = UDim2.new(0, 10, 0, 200),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 52,
            }, popup)
            round(hueBar, 3)
            local hueGrad = Instance.new("UIGradient")
            hueGrad.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
                ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
                ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
                ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
                ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
                ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
                ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
            })
            hueGrad.Parent = hueBar
            local hueMarker = make("Frame", {
                Size = UDim2.fromOffset(4, 18),
                Position = UDim2.new(hue, -2, 0.5, -9),
                BackgroundColor3 = Color3.fromRGB(255, 255, 255),
                BorderSizePixel = 0,
                ZIndex = 53,
            }, hueBar)
            round(hueMarker, 2)

            local function rgbRow(y, name, color)
                make("TextLabel", {
                    Size = UDim2.new(0, 40, 0, 14),
                    Position = UDim2.fromOffset(10, y),
                    BackgroundTransparency = 1,
                    Text = name,
                    TextColor3 = color,
                    Font = Enum.Font.GothamMedium,
                    TextSize = 10,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ZIndex = 53,
                }, popup)
                local bar = make("Frame", {
                    Size = UDim2.new(1, -70, 0, 14),
                    Position = UDim2.fromOffset(50, y),
                    BackgroundColor3 = Color3.fromRGB(40, 20, 20),
                    BorderSizePixel = 0,
                    ZIndex = 52,
                }, popup)
                round(bar, 2)
                local fill = make("Frame", {
                    Size = UDim2.new(0, 0, 1, 0),
                    BackgroundColor3 = Color3.fromRGB(220, 80, 80),
                    BorderSizePixel = 0,
                    ZIndex = 53,
                }, bar)
                round(fill, 2)
                local readout = make("TextLabel", {
                    Size = UDim2.new(0, 20, 0, 14),
                    Position = UDim2.new(1, -20, 0, 0),
                    BackgroundTransparency = 1,
                    Text = "0",
                    TextColor3 = Color3.fromRGB(220, 80, 80),
                    Font = Enum.Font.GothamMedium,
                    TextSize = 10,
                    TextXAlignment = Enum.TextXAlignment.Right,
                    ZIndex = 53,
                }, bar)
                return fill, readout
            end

            local rFill, rTxt = rgbRow(230, "red", Color3.fromRGB(220, 80, 80))
            local gFill, gTxt = rgbRow(248, "green", Color3.fromRGB(120, 220, 120))
            local bFill, bTxt = rgbRow(266, "blue", Color3.fromRGB(120, 140, 255))

            local function syncRgb(c)
                local r = math.floor(c.R * 255)
                local g = math.floor(c.G * 255)
                local b = math.floor(c.B * 255)
                rFill.Size = UDim2.new(r / 255, 0, 1, 0)
                gFill.Size = UDim2.new(g / 255, 0, 1, 0)
                bFill.Size = UDim2.new(b / 255, 0, 1, 0)
                rTxt.Text = tostring(r)
                gTxt.Text = tostring(g)
                bTxt.Text = tostring(b)
            end

            local function apply()
                local c = Color3.fromHSV(hue, sat, val)
                preview.BackgroundColor3 = c
                hueLayer.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
                hueMarker.Position = UDim2.new(hue, -2, 0.5, -9)
                marker.Position = UDim2.new(sat, -6, 1 - val, -6)
                syncRgb(c)
                if callback then pcall(callback, c) end
            end
            apply()

            local dragWheel = false
            local function wheelMove(input)
                local rx = math.clamp((input.Position.X - wheel.AbsolutePosition.X) / wheel.AbsoluteSize.X, 0, 1)
                local ry = math.clamp((input.Position.Y - wheel.AbsolutePosition.Y) / wheel.AbsoluteSize.Y, 0, 1)
                sat = rx
                val = 1 - ry
                apply()
            end
            wheel.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragWheel = true
                    wheelMove(input)
                end
            end)
            UserInputService.InputChanged:Connect(function(input)
                if dragWheel and input.UserInputType == Enum.UserInputType.MouseMovement then
                    wheelMove(input)
                end
            end)
            UserInputService.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then dragWheel = false end
            end)

            local dragHue = false
            local function hueMove(input)
                local rx = math.clamp((input.Position.X - hueBar.AbsolutePosition.X) / hueBar.AbsoluteSize.X, 0, 1)
                hue = rx
                apply()
            end
            hueBar.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then
                    dragHue = true
                    hueMove(input)
                end
            end)
            UserInputService.InputChanged:Connect(function(input)
                if dragHue and input.UserInputType == Enum.UserInputType.MouseMovement then
                    hueMove(input)
                end
            end)
            UserInputService.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 then dragHue = false end
            end)

            preview.MouseButton1Click:Connect(function()
                popup.Visible = not popup.Visible
                if popup.Visible then
                    local p = UserInputService:GetMouseLocation()
                    popup.Position = UDim2.fromOffset(p.X + 10, p.Y + 10)
                end
            end)

            UserInputService.InputBegan:Connect(function(input, gp)
                if gp then return end
                if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
                if not popup.Visible then return end
                local p = UserInputService:GetMouseLocation()
                local ap = popup.AbsolutePosition
                local as = popup.AbsoluteSize
                local inside = p.X >= ap.X and p.X <= ap.X + as.X and p.Y >= ap.Y and p.Y <= ap.Y + as.Y
                local onPreview = p.X >= preview.AbsolutePosition.X and p.X <= preview.AbsolutePosition.X + preview.AbsoluteSize.X
                    and p.Y >= preview.AbsolutePosition.Y and p.Y <= preview.AbsolutePosition.Y + preview.AbsoluteSize.Y
                if not inside and not onPreview then popup.Visible = false end
            end)

            return {
                set = function(c)
                    hue, sat, val = Color3.toHSV(c)
                    apply()
                end,
                get = function() return Color3.fromHSV(hue, sat, val) end,
                popup = popup,
                previewButton = preview,
            }
        end

        return sec
    end

    function api:_bindListener()
        local ui = self
        UserInputService.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
            for _, entry in ipairs(ui.binds) do
                if entry.waiting then
                    if input.KeyCode == Enum.KeyCode.Escape then
                        entry.waiting = false
                        entry.label.Text = entry.current and entry.current.Name or "[ ... ]"
                        entry.stroke.Color = entry.theme.Stroke
                    else
                        entry.current = input.KeyCode
                        entry.label.Text = input.KeyCode.Name
                        entry.stroke.Color = entry.theme.Stroke
                        entry.waiting = false
                        if entry.onChanged then pcall(entry.onChanged, input.KeyCode) end
                    end
                    return
                end
            end
        end)
    end

    UI.Themes = THEMES
    UI.new = api.new
end

local ui = UI.new({
    theme = "grape",
    rounding = true,
    size = Vector2.new(650, 450),
})

local combat = ui:addMenu("Combat")
local config = ui:addMenu("Config")

local refs = {
    triggerToggle = nil, autoToggle = nil, silentToggle = nil, hitboxToggle = nil,
    triggerBind = nil, autoBind = nil, silentBind = nil, hitboxBind = nil, menuBind = nil,
    triggerDelay = nil, triggerDist = nil,
    autoChance = nil, silentChance = nil,
    hbSize = nil, hbAlpha = nil,
    hbColor = nil, accent = nil,
}

local triggerSec = combat:addSection({ text = "TriggerBot" })
refs.triggerToggle = triggerSec:addToggle({ text = "Enable TriggerBot", state = triggerOn })
refs.triggerToggle:bindToEvent("onToggle", function(v)
    triggerOn = v
    queueSave()
end)
refs.triggerBind = triggerSec:addKeybind({ text = "Trigger Key", key = triggerBind }, function(k)
    triggerBind = k
    queueSave()
end)
refs.triggerDelay = triggerSec:addSlider({ text = "Next Shot Delay", min = 0, max = 1, step = 0.01, val = shotDelay }, function(v)
    shotDelay = v
    queueSave()
end)
refs.triggerDist = triggerSec:addSlider({ text = "Trigger Distance", min = 0, max = 1000, step = 1, val = triggerDist }, function(v)
    triggerDist = v
    queueSave()
end)
triggerSec:addLabel({ text = "Press 2 to arm, press 1 to disarm" })

local autoSec = combat:addSection({ text = "Auto Shoot" })
refs.autoToggle = autoSec:addToggle({ text = "Enable Auto Shoot", state = autoOn })
refs.autoToggle:bindToEvent("onToggle", function(v)
    autoOn = v
    queueSave()
end)
refs.autoBind = autoSec:addKeybind({ text = "Auto Shoot Key", key = autoBind }, function(k)
    autoBind = k
    queueSave()
end)
refs.autoChance = autoSec:addSlider({ text = "Auto Hit Chance", min = 0, max = 100, step = 1, val = autoChance }, function(v)
    autoChance = v
    queueSave()
end)
autoSec:addLabel({ text = "Press 2 to arm, press 1 to disarm" })

local silentSec = combat:addSection({ text = "Silent Aim" })
refs.silentToggle = silentSec:addToggle({ text = "Enable Silent Aim", state = silentOn })
refs.silentToggle:bindToEvent("onToggle", function(v)
    silentOn = v
    queueSave()
end)
refs.silentBind = silentSec:addKeybind({ text = "Silent Aim Key", key = silentBind }, function(k)
    silentBind = k
    queueSave()
end)
refs.silentChance = silentSec:addSlider({ text = "Silent Hit Chance", min = 0, max = 100, step = 1, val = silentChance }, function(v)
    silentChance = v
    queueSave()
end)
silentSec:addLabel({ text = "Press 2 to arm, press 1 to disarm" })

local hbSec = combat:addSection({ text = "Hitbox" })
refs.hitboxToggle = hbSec:addToggle({ text = "Enable Hitbox", state = hitboxOn })
refs.hitboxToggle:bindToEvent("onToggle", function(v)
    hitboxOn = v
    if not v then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then dropHb(plr.Character) end
        end
    end
    queueSave()
end)
refs.hitboxBind = hbSec:addKeybind({ text = "Hitbox Key", key = hitboxBind }, function(k)
    hitboxBind = k
    queueSave()
end)
refs.hbSize = hbSec:addSlider({ text = "Hitbox Size", min = 3, max = 15, step = 1, val = hbSize }, function(v)
    hbSize = v
    queueSave()
end)
refs.hbAlpha = hbSec:addSlider({ text = "Hitbox Transparency", min = 0, max = 1, step = 0.01, val = hbAlpha }, function(v)
    hbAlpha = v
    queueSave()
end)
refs.hbColor = hbSec:addColorPicker({ text = "Hitbox Color", color = hbColor }, function(c)
    hbColor = c
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local part = plr.Character:FindFirstChild("GhostHitbox")
            if part then part.Color = c end
        end
    end
    queueSave()
end)
hbSec:addLabel({ text = "No arm needed" })

local bindSec = config:addSection({ text = "Keybinds" })
refs.menuBind = bindSec:addKeybind({ text = "Menu Key", key = menuBind }, function(k)
    menuBind = k
    queueSave()
end)

local lookSec = config:addSection({ text = "Appearance" })
refs.accent = lookSec:addColorPicker({ text = "Accent Color", color = accentColor }, function(c)
    accentColor = c
    ui:setAccent(c)
    queueSave()
end)

local dangerSec = config:addSection({ text = "Danger Zone" })

dangerSec:addButton({ text = "Reset Config", style = "small" }, function()
    if delfile then pcall(delfile, CONFIG_FILE) end
    triggerOn = false
    autoOn = false
    silentOn = false
    hitboxOn = false
    triggerBind = nil
    autoBind = nil
    silentBind = nil
    hitboxBind = nil
    menuBind = nil
    hbColor = Color3.fromRGB(255, 255, 255)
    accentColor = Color3.fromRGB(134, 53, 255)
    if refs.triggerToggle then refs.triggerToggle:set(false) end
    if refs.autoToggle then refs.autoToggle:set(false) end
    if refs.silentToggle then refs.silentToggle:set(false) end
    if refs.hitboxToggle then refs.hitboxToggle:set(false) end
    if refs.triggerBind then refs.triggerBind:set(nil) end
    if refs.autoBind then refs.autoBind:set(nil) end
    if refs.silentBind then refs.silentBind:set(nil) end
    if refs.hitboxBind then refs.hitboxBind:set(nil) end
    if refs.menuBind then refs.menuBind:set(nil) end
    if refs.hbColor then refs.hbColor:set(Color3.fromRGB(255, 255, 255)) end
    if refs.accent then
        refs.accent:set(Color3.fromRGB(134, 53, 255))
        ui:setAccent(Color3.fromRGB(134, 53, 255))
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then dropHb(plr.Character) end
    end
end)

dangerSec:addButton({ text = "Unload Script", style = "large" }, function()
    if unloadScript then unloadScript() end
end)

ui:selectMenu("Combat")

keep(UserInputService.InputBegan:Connect(function(input, gp)
    if stopped then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

    if menuBind and input.KeyCode == menuBind then
        if not gp then ui:toggleVisible() end
        return
    end

    if input.KeyCode == Enum.KeyCode.Two then
        weaponSlot = 2
        return
    end
    if input.KeyCode == Enum.KeyCode.One then
        weaponSlot = 1
        return
    end

    if triggerOn and triggerBind and input.KeyCode == triggerBind then
        triggerOn = false
        if refs.triggerToggle then refs.triggerToggle:set(false) end
        queueSave()
        return
    end

    if autoOn and autoBind and input.KeyCode == autoBind then
        autoOn = false
        if refs.autoToggle then refs.autoToggle:set(false) end
        queueSave()
        return
    end

    if silentOn and silentBind and input.KeyCode == silentBind then
        silentOn = false
        if refs.silentToggle then refs.silentToggle:set(false) end
        queueSave()
        return
    end

    if hitboxOn and hitboxBind and input.KeyCode == hitboxBind then
        hitboxOn = false
        if refs.hitboxToggle then refs.hitboxToggle:set(false) end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then dropHb(plr.Character) end
        end
        queueSave()
        return
    end
end))

unloadScript = function()
    if stopped then return end
    stopped = true

    triggerOn = false
    autoOn = false
    silentOn = false
    hitboxOn = false

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then dropHb(plr.Character) end
    end

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)

    if restoreHook then
        restoreHook()
        restoreHook = nil
    end

    if ui and ui.screen then
        pcall(function() ui.screen:Destroy() end)
    end

    local cg = game:GetService("CoreGui")
    local leftover = cg:FindFirstChild("Uk4lex")
    if leftover then pcall(function() leftover:Destroy() end) end

    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if pg then
        local old = pg:FindFirstChild("Uk4lex")
        if old then pcall(function() old:Destroy() end) end
    end
end
