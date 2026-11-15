--[[
    Fly Anywhere
    ใช้ได้ทั้งมือถือ (Delta) และ PC

    การควบคุม
      มือถือ : ใช้ปุ่มบน GUI + จอยสติ๊กเดินปกติ (บินไปทางที่กล้องหัน)
      PC     : F = เปิด/ปิดบิน, N = เปิด/ปิด Noclip, G = เปิด/ปิดล่องหน, T = สลับแท็บ ควบคุม/วาร์ป, H = เปิด/ปิด God mode, J = เปิด/ปิด Anti-AFK, E หรือ Space = ขึ้น, Q หรือ LeftCtrl = ลง, WASD = เคลื่อนที่
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

local WALK_STEP     = 4
local WALK_MIN      = 4
local WALK_MAX      = 200

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
-- Invisible (ทดลอง) - วิธี desync
-- ลำดับในแต่ละเฟรมของ Roblox:  RenderStepped -> วาดภาพ -> ฟิสิกส์ -> Heartbeat -> ส่งตำแหน่งไปเซิร์ฟเวอร์
-- 1) ตอน Heartbeat ย้ายตัวไปซ่อนใต้พื้น  => เซิร์ฟเวอร์/คนอื่นได้ตำแหน่งที่ซ่อน
-- 2) ตอนเริ่ม RenderStepped ย้ายกลับที่จริง => จอเราและฟิสิกส์ใช้ตำแหน่งจริงตามปกติ
------------------------------------------------------------------------
local INVIS_HIDE_OFFSET = Vector3.new(0, -60, 0) -- ตำแหน่งที่คนอื่นเห็น (ใต้ตัวเรา 60 studs)
local INVIS_GHOST_ALPHA = 0.6                    -- ความโปร่งใสที่เราเห็นตัวเอง (0 = เห็นชัด, 1 = หายทั้งตัว, เห็นแค่เรา)
local INVIS_BIND        = "FlyAnywhereInvisRestore"

local invisRealCF
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

-- คืนตำแหน่งจริงก่อนกล้อง/การวาดภาพทำงาน
local function restoreRealCF()
    if invisRealCF and root and root.Parent then
        root.CFrame = invisRealCF
    end
    invisRealCF = nil
end

local function startInvisible()
    if not refreshCharacter() then return false end
    invisRealCF = nil
    RunService:BindToRenderStep(INVIS_BIND, Enum.RenderPriority.First.Value, restoreRealCF)
    setLocalGhost(true)
    return true
end

local function stopInvisible()
    pcall(function() RunService:UnbindFromRenderStep(INVIS_BIND) end)
    restoreRealCF() -- เผื่อกดปิดตอนตัวยังอยู่ที่ตำแหน่งซ่อน
    setLocalGhost(false)
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

local FRAME_WIDTH  = 190
local FRAME_HEIGHT = 304
local TITLE_HEIGHT = 30
local TAB_HEIGHT   = 26
local PAGE_TOP     = TITLE_HEIGHT + TAB_HEIGHT + 6 -- เนื้อหาแต่ละแท็บเริ่มที่ y นี้
local ROW          = 34                            -- ความสูงปุ่มแต่ละแถว
local GAP          = 6

local COLOR_TAB_ACTIVE = Color3.fromRGB(70, 100, 190)

local frame = Instance.new("Frame")
frame.Size             = UDim2.fromOffset(FRAME_WIDTH, FRAME_HEIGHT)
frame.Position         = UDim2.new(0, 20, 0, 8) -- มุมบนซ้าย ใต้แถบเมนู Roblox ให้พอดีจอมือถือแนวนอน
frame.BackgroundColor3 = COLOR_BG
frame.BorderSizePixel  = 0
frame.Active           = true
frame.Parent           = gui
corner(frame, 10)

local title = Instance.new("TextLabel")
title.Size                   = UDim2.new(1, -70, 0, TITLE_HEIGHT)
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

local minBtn = makeButton(frame, "—", UDim2.new(1, -60, 0, 4), UDim2.fromOffset(26, 22))
minBtn.TextSize = 14

------------------------------------------------------------------------
-- แท็บ: ควบคุม | วาร์ป
------------------------------------------------------------------------
local tabControlBtn = makeButton(frame, "ควบคุม", UDim2.fromOffset(10, TITLE_HEIGHT), UDim2.new(0.5, -12, 0, TAB_HEIGHT))
local tabWarpBtn    = makeButton(frame, "วาร์ป",  UDim2.new(0.5, 2, 0, TITLE_HEIGHT), UDim2.new(0.5, -12, 0, TAB_HEIGHT))
tabControlBtn.TextSize = 14
tabWarpBtn.TextSize    = 14

local function makePage()
    local page = Instance.new("Frame")
    page.BackgroundTransparency = 1
    page.Position               = UDim2.fromOffset(0, PAGE_TOP)
    page.Size                   = UDim2.new(1, 0, 1, -PAGE_TOP)
    page.Parent                 = frame
    return page
end

local controlPage = makePage()
local warpPage    = makePage()
warpPage.Visible  = false

-- y ของแถวที่ n (เริ่มที่ 0) ในหน้าแท็บ
local function rowY(n) return n * (ROW + GAP) end

------------------------------------------------------------------------
-- แท็บ "ควบคุม"
------------------------------------------------------------------------
local toggleBtn = makeButton(controlPage, "FLY: OFF", UDim2.fromOffset(10, rowY(0)), UDim2.new(1, -20, 0, ROW))
toggleBtn.BackgroundColor3 = COLOR_OFF

local upBtn   = makeButton(controlPage, "▲ ขึ้น", UDim2.fromOffset(10, rowY(1)), UDim2.new(0.5, -14, 0, ROW))
local downBtn = makeButton(controlPage, "▼ ลง",  UDim2.new(0.5, 4, 0, rowY(1)), UDim2.new(0.5, -14, 0, ROW))

local noclipBtn = makeButton(controlPage, "NOCLIP OFF", UDim2.fromOffset(10, rowY(2)), UDim2.new(0.5, -14, 0, ROW))
noclipBtn.BackgroundColor3 = COLOR_OFF
noclipBtn.TextSize = 13

local invisBtn = makeButton(controlPage, "INVIS OFF", UDim2.new(0.5, 4, 0, rowY(2)), UDim2.new(0.5, -14, 0, ROW))
invisBtn.BackgroundColor3 = COLOR_OFF
invisBtn.TextSize = 13

local godBtn = makeButton(controlPage, "GOD OFF", UDim2.fromOffset(10, rowY(3)), UDim2.new(0.5, -14, 0, ROW))
godBtn.BackgroundColor3 = COLOR_OFF
godBtn.TextSize = 13

local afkBtn = makeButton(controlPage, "AFK OFF", UDim2.new(0.5, 4, 0, rowY(3)), UDim2.new(0.5, -14, 0, ROW))
afkBtn.BackgroundColor3 = COLOR_OFF
afkBtn.TextSize = 13

local function makeValueLabel(class, y)
    local l = Instance.new(class)
    l.Size                   = UDim2.new(1, -116, 0, ROW)
    l.Position               = UDim2.fromOffset(58, y)
    l.BackgroundTransparency = 1
    l.TextColor3             = COLOR_TEXT
    l.Font                   = Enum.Font.Gotham
    l.TextSize               = 15
    l.Parent                 = controlPage
    return l
end

-- แถวความเร็วบิน
local minusBtn   = makeButton(controlPage, "−", UDim2.fromOffset(10, rowY(4)), UDim2.fromOffset(38, ROW))
local plusBtn    = makeButton(controlPage, "+", UDim2.new(1, -48, 0, rowY(4)), UDim2.fromOffset(38, ROW))
local speedLabel = makeValueLabel("TextLabel", rowY(4))

-- แถวความเร็ววิ่ง (กดที่ตัวเลขเพื่อรีเซ็ตกลับค่าเดิมของเกม)
local walkMinusBtn = makeButton(controlPage, "−", UDim2.fromOffset(10, rowY(5)), UDim2.fromOffset(38, ROW))
local walkPlusBtn  = makeButton(controlPage, "+", UDim2.new(1, -48, 0, rowY(5)), UDim2.fromOffset(38, ROW))
local walkLabel    = makeValueLabel("TextButton", rowY(5))

local function getHumanoid()
    local character = player.Character
    return character and character:FindFirstChildOfClass("Humanoid")
end

------------------------------------------------------------------------
-- แท็บ "วาร์ป": Checkpoint + รายชื่อผู้เล่น (เลื่อนดูได้)
------------------------------------------------------------------------
local tpList = Instance.new("ScrollingFrame")
tpList.Position               = UDim2.fromOffset(8, 0)
tpList.Size                   = UDim2.new(1, -12, 1, -8)
tpList.BackgroundTransparency = 1
tpList.BorderSizePixel        = 0
tpList.ScrollBarThickness     = 4
tpList.CanvasSize             = UDim2.new()
tpList.AutomaticCanvasSize    = Enum.AutomaticSize.Y
tpList.Parent                 = warpPage

local tpLayout = Instance.new("UIListLayout")
tpLayout.Padding   = UDim.new(0, 6)
tpLayout.SortOrder = Enum.SortOrder.LayoutOrder
tpLayout.Parent    = tpList

-- วาร์ปตัวเราไปที่ CFrame ที่กำหนด (รองรับตอนล่องหน)
local function teleportToCF(dest)
    if not refreshCharacter() then
        notify("ยังไม่พบตัวละคร")
        return false
    end
    root.AssemblyLinearVelocity = Vector3.zero
    -- ถ้ากำลังล่องหน ตำแหน่งจริงจะถูกคืนตอน RenderStepped จึงต้องแก้ตำแหน่งจริงด้วย
    if Fly.invisible and invisRealCF then
        invisRealCF = dest
    end
    root.CFrame = dest
    return true
end

local function teleportTo(target)
    local tChar = target.Character
    local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
    if not tRoot then
        notify("ไม่พบตัว " .. target.DisplayName .. " (อาจอยู่ไกลเกินไป)")
        return
    end
    -- ไปยืนข้างหลังเป้าหมาย 3 studs
    if teleportToCF(tRoot.CFrame * CFrame.new(0, 0, 3)) then
        notify("วาร์ปไปหา " .. target.DisplayName)
    end
end

------------------------------------------------------------------------
-- Checkpoint: บันทึกตำแหน่งไว้หลายจุด แล้ววาร์ปกลับได้
-- เก็บไว้ใน getgenv() จุดที่บันทึกจึงยังอยู่แม้รันสคริปต์ซ้ำ (จนกว่าจะออกจากเกม)
------------------------------------------------------------------------
local CHECKPOINT_MAX = 10
env.FlyAnywhereCheckpoints = env.FlyAnywhereCheckpoints or {}
local checkpoints = env.FlyAnywhereCheckpoints
local refreshTpList -- ประกาศไว้ก่อน เพราะ saveCheckpoint ต้องเรียก

local function currentRealCF()
    if not refreshCharacter() then return nil end
    -- ตอนล่องหน root อาจอยู่ที่ตำแหน่งซ่อน ให้ใช้ตำแหน่งจริงแทน
    return (Fly.invisible and invisRealCF) or root.CFrame
end

local function saveCheckpoint()
    local cf = currentRealCF()
    if not cf then
        notify("ยังไม่พบตัวละคร")
        return
    end
    if #checkpoints >= CHECKPOINT_MAX then
        notify("บันทึกได้สูงสุด " .. CHECKPOINT_MAX .. " จุด ลบจุดเก่าก่อน")
        return
    end
    env.FlyAnywhereCheckpointCount = (env.FlyAnywhereCheckpointCount or 0) + 1
    table.insert(checkpoints, { name = "จุด " .. env.FlyAnywhereCheckpointCount, cf = cf })
    notify("บันทึก จุด " .. env.FlyAnywhereCheckpointCount .. " แล้ว")
    refreshTpList()
end

local function makeSectionLabel(text, order)
    local l = Instance.new("TextLabel")
    l.Size                   = UDim2.new(1, -6, 0, 20)
    l.BackgroundTransparency = 1
    l.Text                   = text
    l.TextColor3             = Color3.fromRGB(160, 160, 175)
    l.Font                   = Enum.Font.GothamBold
    l.TextSize               = 12
    l.TextXAlignment         = Enum.TextXAlignment.Left
    l.LayoutOrder            = order
    l.Parent                 = tpList
    return l
end

refreshTpList = function()
    for _, child in ipairs(tpList:GetChildren()) do
        if child:IsA("GuiObject") then child:Destroy() end
    end
    local order = 0
    local function nextOrder() order += 1; return order end

    -- ส่วนที่ 1: Checkpoint
    makeSectionLabel("CHECKPOINT", nextOrder())

    local saveBtn = makeButton(tpList, "＋ บันทึกจุดนี้", UDim2.new(), UDim2.new(1, -6, 0, 36))
    saveBtn.TextSize         = 14
    saveBtn.BackgroundColor3 = COLOR_ON
    saveBtn.LayoutOrder      = nextOrder()
    saveBtn.Activated:Connect(saveCheckpoint)

    for index, cp in ipairs(checkpoints) do
        local row = Instance.new("Frame")
        row.Size                   = UDim2.new(1, -6, 0, 40)
        row.BackgroundTransparency = 1
        row.LayoutOrder            = nextOrder()
        row.Parent                 = tpList

        local p = cp.cf.Position
        local go = makeButton(row, string.format("%s\n%d, %d, %d", cp.name, p.X, p.Y, p.Z),
            UDim2.new(), UDim2.new(1, -40, 1, 0))
        go.TextSize = 13
        go.Activated:Connect(function()
            if teleportToCF(cp.cf) then notify("วาร์ปไป " .. cp.name) end
        end)

        local del = makeButton(row, "×", UDim2.new(1, -34, 0, 0), UDim2.new(0, 34, 1, 0))
        del.BackgroundColor3 = COLOR_OFF
        del.Activated:Connect(function()
            table.remove(checkpoints, index)
            refreshTpList()
        end)
    end

    -- ส่วนที่ 2: ผู้เล่น
    makeSectionLabel("ผู้เล่น", nextOrder())

    local others = {}
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= player then table.insert(others, pl) end
    end
    table.sort(others, function(a, b) return a.DisplayName:lower() < b.DisplayName:lower() end)

    if #others == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size                   = UDim2.new(1, -6, 0, 30)
        empty.BackgroundTransparency = 1
        empty.Text                   = "ไม่มีผู้เล่นอื่นในเซิร์ฟ"
        empty.TextColor3             = COLOR_TEXT
        empty.Font                   = Enum.Font.Gotham
        empty.TextSize               = 13
        empty.LayoutOrder            = nextOrder()
        empty.Parent                 = tpList
        return
    end

    for _, pl in ipairs(others) do
        local b = makeButton(tpList, pl.DisplayName .. "\n@" .. pl.Name, UDim2.new(), UDim2.new(1, -6, 0, 40))
        b.TextSize     = 13
        b.TextTruncate = Enum.TextTruncate.AtEnd
        b.LayoutOrder  = nextOrder()
        b.Activated:Connect(function() teleportTo(pl) end) -- ปุ่มถูกลบเมื่อรีเฟรช connection หายไปด้วย
    end
end

-- สลับแท็บ: "control" หรือ "warp"
Fly.tab = "control"
local function setTab(name)
    Fly.tab = name
    local isWarp = name == "warp"
    if isWarp then refreshTpList() end
    controlPage.Visible = not isWarp and not Fly.minimized
    warpPage.Visible    = isWarp and not Fly.minimized
    tabControlBtn.BackgroundColor3 = isWarp and COLOR_BTN or COLOR_TAB_ACTIVE
    tabWarpBtn.BackgroundColor3    = isWarp and COLOR_TAB_ACTIVE or COLOR_BTN
end

local function updateUI()
    toggleBtn.Text             = Fly.enabled and "FLY: ON" or "FLY: OFF"
    toggleBtn.BackgroundColor3 = Fly.enabled and COLOR_ON or COLOR_OFF
    noclipBtn.Text             = Fly.noclip and "NOCLIP ON" or "NOCLIP OFF"
    noclipBtn.BackgroundColor3 = Fly.noclip and COLOR_ON or COLOR_OFF
    invisBtn.Text              = invisBusy and "INVIS ..." or (Fly.invisible and "INVIS ON" or "INVIS OFF")
    invisBtn.BackgroundColor3  = Fly.invisible and COLOR_ON or COLOR_OFF
    godBtn.Text                = Fly.god and "GOD ON" or "GOD OFF"
    godBtn.BackgroundColor3    = Fly.god and COLOR_ON or COLOR_OFF
    afkBtn.Text                = Fly.antiAfk and "AFK ON" or "AFK OFF"
    afkBtn.BackgroundColor3    = Fly.antiAfk and COLOR_ON or COLOR_OFF
    speedLabel.Text            = "Fly: " .. Fly.speed

    local hum  = getHumanoid()
    local walk = Fly.walkSpeed or (hum and hum.WalkSpeed) or 16
    walkLabel.Text = "Walk: " .. math.floor(walk + 0.5)
end

-- ย่อ/ขยายหน้าต่าง: ซ่อนทุกอย่างยกเว้นแถบชื่อ
local keepVisible = { [title] = true, [closeBtn] = true, [minBtn] = true }
local function setMinimized(state)
    Fly.minimized = state
    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("GuiObject") and not keepVisible[child] then
            child.Visible = not state
        end
    end
    setTab(Fly.tab) -- ให้เห็นเฉพาะหน้าของแท็บที่เลือกไว้
    frame.Size  = UDim2.fromOffset(FRAME_WIDTH, state and TITLE_HEIGHT or FRAME_HEIGHT)
    minBtn.Text = state and "+" or "—"
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
            stopInvisible()
            notify("ล่องหนไม่สำเร็จ")
        end
    else
        stopInvisible()
    end

    if ok then Fly.invisible = state end
    invisBusy = false
    updateUI()
end

------------------------------------------------------------------------
-- God mode (ทดลอง)
-- เกมส่วนใหญ่ลดเลือดจากฝั่งเซิร์ฟเวอร์ แล้วส่งค่าเลือด 0 มาที่เครื่องเรา ทำให้ตัวละครตาย
-- วิธีแก้: สร้าง Humanoid ตัวใหม่ในเครื่องเราแทนตัวเดิม ตัวใหม่ไม่ได้ผูกกับเซิร์ฟเวอร์
-- จึงไม่รับค่าเลือดที่เซิร์ฟเวอร์ลด และเครื่องเราเป็นคนตัดสินว่าตัวละครตายหรือไม่
-- เสริม: กันตกเหว ถ้าตกลงไปใกล้ระดับที่เกมลบตัวละคร จะวาร์ปกลับจุดล่าสุดที่ยืนบนพื้น
------------------------------------------------------------------------
local godHumanoid      -- Humanoid ที่ใช้อยู่ตอนเปิด God (ตัวใหม่ในเครื่องเรา)
local godOriginal      -- Humanoid ตัวจริงที่ถอดออก เก็บไว้ใส่คืนตอนปิด God
local godLastSafeCF    -- จุดล่าสุดที่ยืนบนพื้น
local GOD_VOID_MARGIN = 30

local function lockHumanoid(hum)
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false) end)
    pcall(function()
        hum.RequiresNeck       = false -- หัวหลุดก็ไม่ตาย
        hum.BreakJointsOnDeath = false
    end)
    hum.Health = hum.MaxHealth
end

-- ให้กล้อง ระบบควบคุม (จอยสติ๊ก/กระโดด) และท่าเดิน ใช้ Humanoid ตัวที่กำหนด
local function retargetHumanoid(character, hum)
    workspace.CurrentCamera.CameraSubject = hum
    pcall(function()
        local playerModule = player.PlayerScripts:FindFirstChild("PlayerModule")
        local controls = require(playerModule):GetControls()
        controls.humanoid = hum
    end)
    local animate = character:FindFirstChild("Animate")
    if animate and animate:IsA("BaseScript") then
        animate.Disabled = true
        animate.Disabled = false
    end
    refreshCharacter()
    if Fly.enabled and humanoid then humanoid.PlatformStand = true end
end

local function swapHumanoid(character, old)
    old.Archivable = true
    local new = old:Clone()
    if not new then return nil end
    new.Parent = character
    old.Parent = nil
    lockHumanoid(new)
    retargetHumanoid(character, new)
    return new
end

local function applyGod()
    local character = player.Character
    local hum = character and character:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 or hum == godHumanoid then return end
    local ok, new = pcall(swapHumanoid, character, hum)
    if ok and new then
        godOriginal, godHumanoid = hum, new
    else
        -- สลับไม่ได้: ใช้วิธีปิดสถานะตายแทน (กันได้น้อยกว่า)
        godOriginal, godHumanoid = nil, hum
        lockHumanoid(hum)
    end
end

local function removeGod()
    local character = player.Character
    if godOriginal and character and godHumanoid and godHumanoid.Parent == character then
        godOriginal.Parent = character
        godHumanoid:Destroy()
        retargetHumanoid(character, godOriginal)
    elseif godHumanoid and godHumanoid.Parent then
        pcall(function() godHumanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true) end)
    end
    godHumanoid, godOriginal, godLastSafeCF = nil, nil, nil
end

local function setGod(state)
    if state == Fly.god then return end
    Fly.god = state
    if not state then removeGod() end -- ตอนเปิด Heartbeat จะ apply ให้เอง
    updateUI()
end

------------------------------------------------------------------------
-- Anti-AFK: Roblox จะเตะออกถ้าไม่ขยับ 20 นาที
-- เมื่อ Roblox แจ้งว่าเราว่าง (player.Idled) ให้จำลองการคลิกขวา 1 ครั้ง ตัวนับเวลาจะรีเซ็ต
------------------------------------------------------------------------
local VirtualUser = game:GetService("VirtualUser")

local function setAntiAfk(state)
    if state == Fly.antiAfk then return end
    Fly.antiAfk = state
    notify(state and "Anti-AFK เปิด: ไม่โดนเตะออกเพราะไม่ขยับ" or "Anti-AFK ปิด")
    updateUI()
end

connect(player.Idled, function()
    if not Fly.antiAfk then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

local function changeSpeed(delta)
    Fly.speed = math.clamp(Fly.speed + delta, SPEED_MIN, SPEED_MAX)
    updateUI()
end

-- ความเร็ววิ่ง: Fly.walkSpeed = nil แปลว่าใช้ค่าของเกมตามปกติ
local originalWalkSpeed
local function changeWalkSpeed(delta)
    local hum = getHumanoid()
    if not hum then return end
    if Fly.walkSpeed == nil then
        originalWalkSpeed = hum.WalkSpeed
    end
    local current = Fly.walkSpeed or hum.WalkSpeed
    Fly.walkSpeed = math.clamp(current + delta, WALK_MIN, WALK_MAX)
    hum.WalkSpeed = Fly.walkSpeed
    updateUI()
end

local function resetWalkSpeed()
    local hum = getHumanoid()
    if hum and originalWalkSpeed then hum.WalkSpeed = originalWalkSpeed end
    Fly.walkSpeed = nil
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
connect(minBtn.Activated,       function() setMinimized(not Fly.minimized) end)
connect(tabControlBtn.Activated, function() setTab("control") end)
connect(tabWarpBtn.Activated,    function() setTab("warp") end)
connect(godBtn.Activated,       function() setGod(not Fly.god) end)
connect(afkBtn.Activated,       function() setAntiAfk(not Fly.antiAfk) end)

-- มีคนเข้า/ออกเซิร์ฟ: รีเฟรชรายชื่อถ้าแผงเปิดอยู่
connect(Players.PlayerAdded, function()
    if Fly.tab == "warp" then refreshTpList() end
end)
connect(Players.PlayerRemoving, function()
    if Fly.tab == "warp" then task.defer(refreshTpList) end
end)
connect(walkMinusBtn.Activated, function() changeWalkSpeed(-WALK_STEP) end)
connect(walkPlusBtn.Activated,  function() changeWalkSpeed(WALK_STEP) end)
connect(walkLabel.Activated,    resetWalkSpeed)
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
    elseif k == Enum.KeyCode.T then
        setTab(Fly.tab == "warp" and "control" or "warp")
    elseif k == Enum.KeyCode.H then
        setGod(not Fly.god)
    elseif k == Enum.KeyCode.J then
        setAntiAfk(not Fly.antiAfk)
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

    -- บางเกมรีเซ็ต WalkSpeed เอง ให้ตั้งกลับเป็นค่าที่เราเลือกไว้
    if Fly.walkSpeed then
        local hum = getHumanoid()
        if hum and hum.WalkSpeed ~= Fly.walkSpeed then
            hum.WalkSpeed = Fly.walkSpeed
        end
    end
end)

-- God mode: สลับ Humanoid (รวมตัวใหม่หลังเกิด) เติมเลือด และกันตกเหว
connect(RunService.Heartbeat, function()
    if not Fly.god then return end
    local hum = getHumanoid()
    if not hum then return end
    if hum ~= godHumanoid then
        applyGod()
        hum = godHumanoid
        if not hum then return end
    end
    if hum.Health < hum.MaxHealth then
        hum.Health = hum.MaxHealth
    end

    local cf = currentRealCF()
    if not cf then return end
    if cf.Position.Y < workspace.FallenPartsDestroyHeight + GOD_VOID_MARGIN then
        if godLastSafeCF and teleportToCF(godLastSafeCF + Vector3.new(0, 3, 0)) then
            notify("กันตกเหว: วาร์ปกลับจุดล่าสุด")
        end
    elseif hum.FloorMaterial ~= Enum.Material.Air and not Fly.enabled then
        godLastSafeCF = cf
    end
end)

-- ล่องหน: หลังฟิสิกส์คำนวณเสร็จ ย้ายตัวไปที่ซ่อนก่อน Roblox ส่งตำแหน่งให้เซิร์ฟเวอร์
connect(RunService.Heartbeat, function()
    if not Fly.invisible or not (root and root.Parent) then return end
    invisRealCF = root.CFrame
    root.CFrame = invisRealCF + INVIS_HIDE_OFFSET
end)

------------------------------------------------------------------------
-- ตายแล้วเกิดใหม่: ปิดบินอัตโนมัติ (Noclip ยังเปิดค้างไว้ตามเดิม)
------------------------------------------------------------------------
connect(player.CharacterAdded, function()
    Fly.enabled, Fly.up, Fly.down = false, false, false
    table.clear(originalCollide)
    pcall(function() RunService:UnbindFromRenderStep(INVIS_BIND) end)
    invisRealCF = nil
    godHumanoid, godOriginal, godLastSafeCF = nil, nil, nil -- God ยังเปิดค้างไว้ Heartbeat จะ apply กับตัวใหม่
    table.clear(originalTransparency)
    Fly.invisible = false
    cleanupMovers()
    updateUI()
end)

------------------------------------------------------------------------
-- ลบสคริปต์ทั้งหมด
------------------------------------------------------------------------
function Fly.Destroy()
    if Fly.walkSpeed then resetWalkSpeed() end
    if Fly.god then Fly.god = false; removeGod() end
    if Fly.enabled then stopFly() end
    Fly.enabled = false
    Fly.noclip = false
    restoreCollide()
    if Fly.invisible then stopInvisible() end
    Fly.invisible = false
    for _, c in ipairs(connections) do c:Disconnect() end
    table.clear(connections)
    if gui then gui:Destroy() end
    if env.FlyAnywhere == Fly then env.FlyAnywhere = nil end
end

updateUI()
setTab("control")
notify("โหลดสำเร็จ! กด FLY เพื่อเริ่มบิน")
