--[[
    Fly Anywhere
    ใช้ได้ทั้งมือถือ (Delta) และ PC

    การควบคุม
      มือถือ : ใช้ปุ่มบน GUI + จอยสติ๊กเดินปกติ (บินไปทางที่กล้องหัน)
      PC     : F = เปิด/ปิดบิน, N = เปิด/ปิด Noclip, G = เปิด/ปิดล่องหน, E หรือ Space = ขึ้น, Q หรือ LeftCtrl = ลง, WASD = เคลื่อนที่
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui       = game:GetService("StarterGui")

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- กันรันซ้ำ: ถ้ารันสคริปต์ใหม่ ให้ลบตัวเก่าทิ้งก่อน
------------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.FlyAnywhere and env.FlyAnywhere.Destroy then
    pcall(env.FlyAnywhere.Destroy)
end

------------------------------------------------------------------------
-- ค่าตั้งต้น
------------------------------------------------------------------------
local SPEED_DEFAULT = 50
local SPEED_STEP    = 10
local SPEED_MIN     = 10
local SPEED_MAX     = 500

local Fly = {
    enabled = false,
    noclip    = false,
    invisible = false,
    speed     = SPEED_DEFAULT,
    up      = false,
    down    = false,
}
env.FlyAnywhere = Fly

local connections = {}
local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(connections, c)
    return c
end

local function notify(text)
    pcall(function()
        StarterGui:SetCore("SendNotification", { Title = "Fly Anywhere", Text = text, Duration = 3 })
    end)
end

------------------------------------------------------------------------
-- ตัวละคร / ฟิสิกส์
------------------------------------------------------------------------
local humanoid, root
local attachment, linearVel, alignOri

local function refreshCharacter()
    local character = player.Character
    humanoid = character and character:FindFirstChildOfClass("Humanoid")
    root     = character and character:FindFirstChild("HumanoidRootPart")
    return humanoid ~= nil and root ~= nil
end

local function cleanupMovers()
    for _, obj in ipairs({ linearVel, alignOri, attachment }) do
        if obj then obj:Destroy() end
    end
    linearVel, alignOri, attachment = nil, nil, nil
end

local function startFly()
    if not refreshCharacter() then return false end
    cleanupMovers()

    attachment        = Instance.new("Attachment")
    attachment.Name   = "FlyAttachment"
    attachment.Parent = root

    linearVel                        = Instance.new("LinearVelocity")
    linearVel.Attachment0            = attachment
    linearVel.RelativeTo             = Enum.ActuatorRelativeTo.World
    linearVel.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
    linearVel.MaxForce               = 1e9
    linearVel.VectorVelocity         = Vector3.zero
    linearVel.Parent                 = root

    alignOri                 = Instance.new("AlignOrientation")
    alignOri.Mode            = Enum.OrientationAlignmentMode.OneAttachment
    alignOri.Attachment0     = attachment
    alignOri.RigidityEnabled = true
    alignOri.CFrame          = root.CFrame
    alignOri.Parent          = root

    humanoid.PlatformStand = true
    return true
end

local function stopFly()
    cleanupMovers()
    if humanoid and humanoid.Parent then
        humanoid.PlatformStand = false
        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
    if root and root.Parent then
        root.AssemblyLinearVelocity = Vector3.zero
    end
end

------------------------------------------------------------------------
-- Noclip: ปิดการชนของทุกชิ้นส่วนตัวละคร แล้วจำค่าเดิมไว้คืนตอนปิด
------------------------------------------------------------------------
local originalCollide = setmetatable({}, { __mode = "k" })

local function applyNoclip()
    local character = player.Character
    if not character then return end
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            originalCollide[part] = true
            part.CanCollide = false
        end
    end
end

local function restoreCollide()
    for part in pairs(originalCollide) do
        if part.Parent then part.CanCollide = true end
    end
    table.clear(originalCollide)
end

------------------------------------------------------------------------
-- Invisible (ทดลอง)
-- 1) ย้ายตัวละครไปจอดไกลๆ ให้เซิร์ฟเวอร์เห็นตำแหน่งนั้น
-- 2) เชื่อม (Weld) ตัวละครเข้ากับ part ที่สร้างฝั่ง client แล้วตั้ง RootPriority สูงสุด
--    ให้ part นี้เป็น "ตัวหลัก" ของ assembly แทน HumanoidRootPart
-- 3) เซิร์ฟเวอร์ไม่รู้จัก part นี้ จึงรับตำแหน่งที่ client ส่งไม่ได้
--    คนอื่นจะเห็นตัวเราค้างอยู่ที่จุดจอด ส่วนเราย้ายกลับมาเดินที่เดิมได้
------------------------------------------------------------------------
local INVIS_PARK_OFFSET = Vector3.new(0, 2000, 0) -- จุดจอดตัวละคร (สูงขึ้นไปบนฟ้า)
local INVIS_GHOST_ALPHA = 0.6                     -- ความโปร่งใสที่เราเห็นตัวเอง (เห็นแค่เรา)

local invisPart
local invisBusy = false
local originalTransparency = setmetatable({}, { __mode = "k" })

local function setLocalGhost(on)
    if on then
        local character = player.Character
        if not character then return end
        for _, obj in ipairs(character:GetDescendants()) do
            if (obj:IsA("BasePart") or obj:IsA("Decal")) and obj.Transparency < 1 then
                originalTransparency[obj] = obj.Transparency
                obj.Transparency = math.max(obj.Transparency, INVIS_GHOST_ALPHA)
            end
        end
    else
        for obj, t in pairs(originalTransparency) do
            if obj.Parent then obj.Transparency = t end
        end
        table.clear(originalTransparency)
    end
end

local function startInvisible()
    if not refreshCharacter() then return false end
    local character = player.Character
    local saved = root.CFrame

    -- 1) ไปจอดไว้ แล้วรอให้ตำแหน่งส่งถึงเซิร์ฟเวอร์
    character:PivotTo(saved + INVIS_PARK_OFFSET)
    task.wait(0.3)
    if not (root and root.Parent) then return false end

    -- 2) part ฝั่ง client ที่จะเป็นตัวหลักของ assembly
    invisPart = Instance.new("Part")
    invisPart.Name                     = "InvisAnchor"
    invisPart.Size                     = Vector3.new(1, 1, 1)
    invisPart.Transparency             = 1
    invisPart.CanCollide               = false
    invisPart.CanTouch                 = false
    invisPart.CanQuery                 = false
    invisPart.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0, 0)
    invisPart.RootPriority             = 127
    invisPart.CFrame                   = root.CFrame
    invisPart.Parent                   = workspace

    local weld = Instance.new("Weld")
    weld.Part0  = invisPart
    weld.Part1  = root
    weld.Parent = invisPart

    -- 3) ย้ายตัวเรากลับที่เดิม (เฉพาะฝั่งเรา)
    task.wait()
    invisPart.CFrame = saved
    root.AssemblyLinearVelocity = Vector3.zero

    setLocalGhost(true)
    return true
end

local function stopInvisible()
    local cf = root and root.Parent and root.CFrame
    if invisPart then
        invisPart:Destroy()
        invisPart = nil
    end
    setLocalGhost(false)
    -- HumanoidRootPart กลับมาเป็นตัวหลัก เซิร์ฟเวอร์จะเห็นเราที่ตำแหน่งปัจจุบันอีกครั้ง
    if cf and player.Character then
        player.Character:PivotTo(cf)
    end
end

------------------------------------------------------------------------
-- GUI
------------------------------------------------------------------------
local function getGuiParent()
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    local ok, core = pcall(function()
        local cg = game:GetService("CoreGui")
        local _ = cg.Name -- ทดสอบว่าเข้าถึงได้
        return cg
    end)
    if ok and core then return core end
    return player:WaitForChild("PlayerGui")
end

local COLOR_BG     = Color3.fromRGB(25, 25, 30)
local COLOR_BTN    = Color3.fromRGB(45, 45, 55)
local COLOR_ON     = Color3.fromRGB(40, 170, 90)
local COLOR_OFF    = Color3.fromRGB(190, 60, 60)
local COLOR_TEXT   = Color3.fromRGB(240, 240, 240)

local function corner(obj, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = obj
end

local function makeButton(parent, text, pos, size)
    local b = Instance.new("TextButton")
    b.Text             = text
    b.Position         = pos
    b.Size             = size
    b.BackgroundColor3 = COLOR_BTN
    b.TextColor3       = COLOR_TEXT
    b.Font             = Enum.Font.GothamBold
    b.TextSize         = 18
    b.AutoButtonColor  = true
    b.BorderSizePixel  = 0
    b.Parent           = parent
    corner(b)
    return b
end

local gui = Instance.new("ScreenGui")
gui.Name           = "FlyAnywhereGui"
gui.ResetOnSpawn   = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent         = getGuiParent()

local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(190, 258)
frame.Position         = UDim2.new(0, 20, 0.35, 0)
frame.BackgroundColor3 = COLOR_BG
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = gui
corner(frame, 10)

local title = Instance.new("TextLabel")
title.Size                   = UDim2.new(1, -36, 0, 30)
title.Position               = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text                   = "✈ Fly Anywhere"
title.TextColor3             = COLOR_TEXT
title.Font                   = Enum.Font.GothamBold
title.TextSize               = 15
title.TextXAlignment         = Enum.TextXAlignment.Left
title.Active                 = true
title.Parent                 = frame

local closeBtn = makeButton(frame, "X", UDim2.new(1, -30, 0, 4), UDim2.fromOffset(26, 22))
closeBtn.TextSize = 14
closeBtn.BackgroundColor3 = COLOR_OFF

local toggleBtn = makeButton(frame, "FLY: OFF", UDim2.fromOffset(10, 36), UDim2.new(1, -20, 0, 38))
toggleBtn.BackgroundColor3 = COLOR_OFF

local upBtn   = makeButton(frame, "▲ ขึ้น", UDim2.fromOffset(10, 80), UDim2.new(0.5, -14, 0, 38))
local downBtn = makeButton(frame, "▼ ลง",  UDim2.new(0.5, 4, 0, 80), UDim2.new(0.5, -14, 0, 38))

local noclipBtn = makeButton(frame, "NOCLIP: OFF", UDim2.fromOffset(10, 124), UDim2.new(1, -20, 0, 38))
noclipBtn.BackgroundColor3 = COLOR_OFF

local invisBtn = makeButton(frame, "INVIS: OFF", UDim2.fromOffset(10, 168), UDim2.new(1, -20, 0, 38))
invisBtn.BackgroundColor3 = COLOR_OFF

local minusBtn = makeButton(frame, "−", UDim2.fromOffset(10, 212), UDim2.fromOffset(38, 36))
local plusBtn  = makeButton(frame, "+", UDim2.new(1, -48, 0, 212), UDim2.fromOffset(38, 36))

local speedLabel = Instance.new("TextLabel")
speedLabel.Size                   = UDim2.new(1, -116, 0, 36)
speedLabel.Position               = UDim2.fromOffset(58, 212)
speedLabel.BackgroundTransparency = 1
speedLabel.TextColor3             = COLOR_TEXT
speedLabel.Font                   = Enum.Font.Gotham
speedLabel.TextSize               = 15
speedLabel.Parent                 = frame

local function updateUI()
    toggleBtn.Text             = Fly.enabled and "FLY: ON" or "FLY: OFF"
    toggleBtn.BackgroundColor3 = Fly.enabled and COLOR_ON or COLOR_OFF
    noclipBtn.Text             = Fly.noclip and "NOCLIP: ON" or "NOCLIP: OFF"
    noclipBtn.BackgroundColor3 = Fly.noclip and COLOR_ON or COLOR_OFF
    invisBtn.Text              = invisBusy and "INVIS: ..." or (Fly.invisible and "INVIS: ON" or "INVIS: OFF")
    invisBtn.BackgroundColor3  = Fly.invisible and COLOR_ON or COLOR_OFF
    speedLabel.Text            = "Speed: " .. Fly.speed
end

------------------------------------------------------------------------
-- การทำงานของปุ่ม
------------------------------------------------------------------------
local function setFly(state)
    if state == Fly.enabled then return end
    if state then
        if not startFly() then
            notify("ยังไม่พบตัวละคร")
            return
        end
    else
        stopFly()
    end
    Fly.enabled = state
    updateUI()
end

local function setNoclip(state)
    if state == Fly.noclip then return end
    Fly.noclip = state
    if not state then restoreCollide() end
    updateUI()
end

local function setInvisible(state)
    if invisBusy or state == Fly.invisible then return end
    invisBusy = true
    updateUI()

    local ok = true
    if state then
        local success, result = pcall(startInvisible)
        ok = success and result
        if not ok then
            if invisPart then invisPart:Destroy(); invisPart = nil end
            setLocalGhost(false)
            notify("ล่องหนไม่สำเร็จ")
        end
    else
        stopInvisible()
    end

    if ok then Fly.invisible = state end
    invisBusy = false
    updateUI()
end

local function changeSpeed(delta)
    Fly.speed = math.clamp(Fly.speed + delta, SPEED_MIN, SPEED_MAX)
    updateUI()
end

local function isPress(input)
    return input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch
end

-- ปุ่มแบบกดค้าง (ขึ้น/ลง)
local function bindHold(btn, key)
    connect(btn.InputBegan, function(input)
        if isPress(input) then Fly[key] = true end
    end)
    connect(btn.InputEnded, function(input)
        if isPress(input) then Fly[key] = false end
    end)
    connect(btn.MouseLeave, function()
        Fly[key] = false
    end)
end

bindHold(upBtn, "up")
bindHold(downBtn, "down")

connect(toggleBtn.Activated, function() setFly(not Fly.enabled) end)
connect(noclipBtn.Activated, function() setNoclip(not Fly.noclip) end)
connect(invisBtn.Activated,  function() setInvisible(not Fly.invisible) end)
connect(minusBtn.Activated,  function() changeSpeed(-SPEED_STEP) end)
connect(plusBtn.Activated,   function() changeSpeed(SPEED_STEP) end)
connect(closeBtn.Activated,  function() Fly.Destroy() end)

-- ลาก GUI ได้จากแถบชื่อ
do
    local dragging, dragStart, startPos
    connect(title.InputBegan, function(input)
        if isPress(input) then
            dragging, dragStart, startPos = true, input.Position, frame.Position
            local endConn
            endConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    endConn:Disconnect()
                end
            end)
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                       startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

------------------------------------------------------------------------
-- คีย์บอร์ด (PC)
------------------------------------------------------------------------
connect(UserInputService.InputBegan, function(input, processed)
    if processed then return end
    local k = input.KeyCode
    if k == Enum.KeyCode.F then
        setFly(not Fly.enabled)
    elseif k == Enum.KeyCode.N then
        setNoclip(not Fly.noclip)
    elseif k == Enum.KeyCode.G then
        setInvisible(not Fly.invisible)
    elseif k == Enum.KeyCode.E or k == Enum.KeyCode.Space then
        Fly.up = true
    elseif k == Enum.KeyCode.Q or k == Enum.KeyCode.LeftControl then
        Fly.down = true
    end
end)

connect(UserInputService.InputEnded, function(input)
    local k = input.KeyCode
    if k == Enum.KeyCode.E or k == Enum.KeyCode.Space then
        Fly.up = false
    elseif k == Enum.KeyCode.Q or k == Enum.KeyCode.LeftControl then
        Fly.down = false
    end
end)

------------------------------------------------------------------------
-- ลูปหลัก: คำนวณทิศทางบินทุกเฟรม
------------------------------------------------------------------------
connect(RunService.RenderStepped, function()
    if not Fly.enabled then return end
    if not (linearVel and root and root.Parent and humanoid and humanoid.Parent) then
        setFly(false)
        return
    end

    local camCF = workspace.CurrentCamera.CFrame
    local look  = camCF.LookVector
    local right = camCF.RightVector

    local flatLook  = Vector3.new(look.X, 0, look.Z)
    local flatRight = Vector3.new(right.X, 0, right.Z)
    if flatLook.Magnitude < 1e-3 then
        flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
    end
    flatLook  = flatLook.Unit
    flatRight = flatRight.Magnitude > 1e-3 and flatRight.Unit or Vector3.zero

    -- MoveDirection มาจากจอยสติ๊ก/WASD (เป็นทิศแนวราบ) -> แปลงเป็นทิศตามกล้อง 3 มิติ
    local md  = humanoid.MoveDirection
    local dir = Vector3.zero
    if md.Magnitude > 0 then
        dir = look * md:Dot(flatLook) + right * md:Dot(flatRight)
    end

    local vertical = (Fly.up and 1 or 0) - (Fly.down and 1 or 0)
    dir = dir + Vector3.new(0, vertical, 0)
    if dir.Magnitude > 1 then dir = dir.Unit end

    linearVel.VectorVelocity = dir * Fly.speed
    alignOri.CFrame = CFrame.lookAt(Vector3.zero, flatLook)
end)

-- Noclip ต้องทำใน Stepped (ก่อนคำนวณฟิสิกส์) เพราะ Humanoid จะตั้ง CanCollide กลับทุกเฟรม
connect(RunService.Stepped, function()
    if Fly.noclip then applyNoclip() end
    -- ถ้า part ล่องหนหายไป (เช่นเกมลบทิ้ง) ให้กลับสถานะปกติ
    if Fly.invisible and not invisBusy and not (invisPart and invisPart.Parent) then
        invisPart = nil
        setLocalGhost(false)
        Fly.invisible = false
        updateUI()
    end
end)

------------------------------------------------------------------------
-- ตายแล้วเกิดใหม่: ปิดบินอัตโนมัติ (Noclip ยังเปิดค้างไว้ตามเดิม)
------------------------------------------------------------------------
connect(player.CharacterAdded, function()
    Fly.enabled, Fly.up, Fly.down = false, false, false
    table.clear(originalCollide)
    if invisPart then invisPart:Destroy(); invisPart = nil end
    table.clear(originalTransparency)
    Fly.invisible = false
    cleanupMovers()
    updateUI()
end)

------------------------------------------------------------------------
-- ลบสคริปต์ทั้งหมด
------------------------------------------------------------------------
function Fly.Destroy()
    if Fly.enabled then stopFly() end
    Fly.enabled = false
    Fly.noclip = false
    restoreCollide()
    if Fly.invisible or invisPart then stopInvisible() end
    Fly.invisible = false
    for _, c in ipairs(connections) do c:Disconnect() end
    table.clear(connections)
    if gui then gui:Destroy() end
    if env.FlyAnywhere == Fly then env.FlyAnywhere = nil end
end

updateUI()
notify("โหลดสำเร็จ! กด FLY เพื่อเริ่มบิน")
