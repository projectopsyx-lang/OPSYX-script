--[[
    OPSYX PLATOBOOST USERID KEY SYSTEM - FIXED

    Service ID: 31267
    Identifier: SHA-256(tostring(LocalPlayer.UserId))

    NO DEVICE/HWID/MAC/IP/PC IDENTIFIER IS USED.

    Platoboost public verification flow:
      GET https://api.platoboost.app/public/whitelist/{service}
      ?identifier=<hashed UserId>&key=<key>&nonce=<nonce>
      (api.platoboost.net is used as fallback)

    The returned integrity hash is verified as:
      SHA-256("true-" .. nonce .. "-" .. secret)

    IMPORTANT:
    - This is a CLIENT-SIDE Platoboost integration.
    - The secret is therefore visible to a capable client and should be
      rotated if it has been exposed.
    - The raw OPSYX1 URL is never fetched until authentication succeeds.
]]

repeat task.wait() until game:IsLoaded()

--// ============================================================
--// SERVICES
--// ============================================================

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--// ============================================================
--// CONFIG
--// ============================================================

local SERVICE_ID = 31267
local PLATOBOOST_API_SECRET = "b952215a-a2ca-43b4-9841-3c090c4d51eb"

--// Current Platoboost integrations use these public API hosts.
--// Prefer .app and fall back to .net when the primary host is unavailable.
local PLATOBOOST_HOSTS = {
    "https://api.platoboost.app",
    "https://api.platoboost.net",
}

local RAW_URL = "https://raw.githubusercontent.com/projectopsyx-lang/OPSYX-script/refs/heads/main/OPSYX1.lua"

local REQUEST_TIMEOUT = 15
local HOST_TIMEOUT = 7
local SAVE_KEY = true

--// Saved key is account-scoped by Roblox UserId.
--// This is NOT a device identifier.
local SAVE_FILE = "OPSYX_SavedKey_" .. tostring(LocalPlayer.UserId) .. ".txt"

--// ============================================================
--// STATE
--// ============================================================

local userId = tostring(LocalPlayer.UserId)
local username = LocalPlayer.Name

local alive = true
local verifying = false
local authenticated = false
local hasExecuted = false
local verificationToken = 0
local keyVisible = false
local activeHost = nil

-- Clear stale launch authorization from any previous run.
_G.__OPSYX_LICENSE_CONTEXT = nil

--// ============================================================
--// HTTP REQUEST RESOLVER
--// ============================================================

local function resolveRequestFunction()
    local candidates = {}

    --// syn.request
    pcall(function()
        if type(syn) == "table" and type(syn.request) == "function" then
            table.insert(candidates, syn.request)
        end
    end)

    --// Common executor request functions.
    if type(request) == "function" then
        table.insert(candidates, request)
    end

    if type(http_request) == "function" then
        table.insert(candidates, http_request)
    end

    if type(syn_request) == "function" then
        table.insert(candidates, syn_request)
    end

    --// Some environments expose http.request.
    pcall(function()
        if type(http) == "table" and type(http.request) == "function" then
            table.insert(candidates, http.request)
        end
    end)

    --// Some environments expose http.request through fluxus.
    pcall(function()
        if type(fluxus) == "table" and type(fluxus.request) == "function" then
            table.insert(candidates, fluxus.request)
        end
    end)

    return candidates[1]
end

--// ============================================================
--// UTILITIES
--// ============================================================

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end

    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function urlEncode(value)
    value = tostring(value)

    return value:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function destroyIfExists(parent, name)
    pcall(function()
        local old = parent:FindFirstChild(name)
        if old then
            old:Destroy()
        end
    end)
end

local function new(className, props, parent)
    local object = Instance.new(className)

    for property, value in pairs(props or {}) do
        pcall(function()
            object[property] = value
        end)
    end

    if parent then
        object.Parent = parent
    end

    return object
end

local function warnOPSYX(message)
    warn("[OPSYX] " .. tostring(message))
end

--// ============================================================
--// SHA256
--// ============================================================

local function sha256(value)
    value = tostring(value)

    --// Preferred executor crypto API.
    local ok, result = pcall(function()
        if type(crypt) == "table" and type(crypt.hash) == "function" then
            return crypt.hash(value, "sha256")
        end

        if type(syn) == "table"
            and type(syn.crypt) == "table"
            and type(syn.crypt.hash) == "function" then
            return syn.crypt.hash(value, "sha256")
        end

        return nil
    end)

    if ok and type(result) == "string" and #result > 0 then
        return string.lower(result)
    end

    --// A few executors expose hash helpers differently.
    local globals = {
        "sha256",
        "sha256hex",
    }

    for _, name in ipairs(globals) do
        local fn

        pcall(function()
            fn = _G[name]
        end)

        if type(fn) == "function" and fn ~= sha256 then
            local callOk, callResult = pcall(fn, value)

            if callOk and type(callResult) == "string" and #callResult > 0 then
                return string.lower(callResult)
            end
        end
    end

    return nil
end

local function generateNonce()
    local alphabet = "abcdefghijklmnopqrstuvwxyz"
    local result = table.create(16)

    for i = 1, 16 do
        local index = math.random(1, #alphabet)
        result[i] = alphabet:sub(index, index)
    end

    return table.concat(result)
end

local function getIdentifier()
    --// ONLY Roblox UserId is used.
    local digest = sha256(userId)

    if not digest then
        return nil, "INTEGRITY_UNAVAILABLE"
    end

    return digest, nil
end

--// ============================================================
--// REQUEST WITH TIMEOUT
--// ============================================================

local function requestWithTimeout(options, timeout)
    local requester = resolveRequestFunction()

    if type(requester) ~= "function" then
        return false, nil, "HTTP_UNAVAILABLE"
    end

    local finished = false
    local requestOK = false
    local response = nil
    local requestError = nil

    task.spawn(function()
        local ok, result = pcall(function()
            return requester(options)
        end)

        requestOK = ok
        response = result

        if not ok then
            requestError = tostring(result)
        end

        finished = true
    end)

    local deadline = os.clock() + (timeout or REQUEST_TIMEOUT)

    while not finished and os.clock() < deadline do
        task.wait()
    end

    if not finished then
        return false, nil, "TIMEOUT"
    end

    if not requestOK then
        return false, nil, requestError or "REQUEST_FAILED"
    end

    if type(response) ~= "table" then
        return false, nil, "MALFORMED_HTTP_RESPONSE"
    end

    return true, response, nil
end

--// ============================================================
--// SAVE / LOAD
--// ============================================================

local function loadSavedKey()
    if not SAVE_KEY then
        return nil
    end

    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return nil
    end

    local exists = false

    pcall(function()
        exists = isfile(SAVE_FILE)
    end)

    if not exists then
        return nil
    end

    local ok, value = pcall(function()
        return readfile(SAVE_FILE)
    end)

    if not ok or type(value) ~= "string" then
        return nil
    end

    value = trim(value)

    if value == "" then
        return nil
    end

    return value
end

local function saveKey(key)
    if not SAVE_KEY or type(writefile) ~= "function" then
        return
    end

    pcall(function()
        writefile(SAVE_FILE, key)
    end)
end

local function clearSavedKey()
    if type(delfile) ~= "function" then
        return
    end

    pcall(function()
        if type(isfile) ~= "function" or isfile(SAVE_FILE) then
            delfile(SAVE_FILE)
        end
    end)
end

--// ============================================================
--// GUI SETUP
--// ============================================================

destroyIfExists(CoreGui, "OPSYXKeySystem")
destroyIfExists(PlayerGui, "OPSYXKeySystem")

local GuiParent = PlayerGui

local canUseCoreGui = false

pcall(function()
    local testGui = Instance.new("ScreenGui")
    testGui.Parent = CoreGui
    testGui:Destroy()
    canUseCoreGui = true
end)

if canUseCoreGui then
    GuiParent = CoreGui
end

local ScreenGui = new("ScreenGui", {
    Name = "OPSYXKeySystem",
    IgnoreGuiInset = true,
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 999999,
}, GuiParent)

local Background = new("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
}, ScreenGui)

new("UIGradient", {
    Rotation = 35,
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(7, 8, 13)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(22, 15, 34)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(7, 8, 12)),
    }),
}, Background)

local Panel = new("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.52),
    Size = UDim2.fromOffset(460, 398),
    BackgroundColor3 = Color3.fromRGB(14, 16, 24),
    BorderSizePixel = 0,
}, ScreenGui)

new("UICorner", {
    CornerRadius = UDim.new(0, 20),
}, Panel)

new("UIStroke", {
    Color = Color3.fromRGB(88, 70, 132),
    Thickness = 1.2,
    Transparency = 0.18,
}, Panel)

local PanelScale = new("UIScale", {}, Panel)

local function updateScale()
    local camera = workspace.CurrentCamera

    if not camera then
        return
    end

    local viewport = camera.ViewportSize

    PanelScale.Scale = math.clamp(
        math.min(viewport.X / 540, viewport.Y / 470),
        0.72,
        1
    )
end

updateScale()

pcall(function()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
    end
end)

local Accent = new("Frame", {
    Position = UDim2.fromOffset(28, 27),
    Size = UDim2.fromOffset(5, 50),
    BackgroundColor3 = Color3.fromRGB(139, 91, 245),
    BorderSizePixel = 0,
}, Panel)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, Accent)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(48, 22),
    Size = UDim2.new(1, -70, 0, 32),
    Font = Enum.Font.GothamBold,
    Text = "OPSYX KEY SYSTEM",
    TextColor3 = Color3.fromRGB(246, 243, 255),
    TextSize = 23,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Panel)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(50, 51),
    Size = UDim2.new(1, -70, 0, 18),
    Font = Enum.Font.Gotham,
    Text = "Platoboost account authentication",
    TextColor3 = Color3.fromRGB(139, 134, 159),
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Panel)

local UserCard = new("Frame", {
    Position = UDim2.fromOffset(28, 88),
    Size = UDim2.new(1, -56, 0, 66),
    BackgroundColor3 = Color3.fromRGB(19, 21, 30),
    BorderSizePixel = 0,
}, Panel)

new("UICorner", {
    CornerRadius = UDim.new(0, 13),
}, UserCard)

new("UIStroke", {
    Color = Color3.fromRGB(46, 48, 62),
    Thickness = 1,
}, UserCard)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(15, 8),
    Size = UDim2.new(1, -30, 0, 22),
    Font = Enum.Font.GothamMedium,
    Text = "Welcome, " .. username,
    TextColor3 = Color3.fromRGB(231, 228, 241),
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
}, UserCard)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(15, 32),
    Size = UDim2.new(1, -30, 0, 20),
    Font = Enum.Font.Code,
    Text = "User ID: " .. userId,
    TextColor3 = Color3.fromRGB(140, 136, 159),
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
}, UserCard)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(30, 168),
    Size = UDim2.new(1, -60, 0, 18),
    Font = Enum.Font.GothamMedium,
    Text = "Enter your key",
    TextColor3 = Color3.fromRGB(220, 217, 232),
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
}, Panel)

local KeyFrame = new("Frame", {
    Position = UDim2.fromOffset(28, 192),
    Size = UDim2.new(1, -56, 0, 54),
    BackgroundColor3 = Color3.fromRGB(18, 20, 29),
    BorderSizePixel = 0,
}, Panel)

new("UICorner", {
    CornerRadius = UDim.new(0, 12),
}, KeyFrame)

new("UIStroke", {
    Color = Color3.fromRGB(53, 55, 72),
    Thickness = 1,
}, KeyFrame)

local KeyBox = new("TextBox", {
    BackgroundTransparency = 1,
    ClearTextOnFocus = false,
    MultiLine = false,
    Position = UDim2.fromOffset(15, 0),
    Size = UDim2.new(1, -70, 1, 0),
    Font = Enum.Font.Code,
    PlaceholderText = "Enter Platoboost key...",
    PlaceholderColor3 = Color3.fromRGB(91, 88, 105),
    Text = "",
    TextColor3 = Color3.fromRGB(238, 235, 246),
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
}, KeyFrame)

local Mask = new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(15, 0),
    Size = UDim2.new(1, -70, 1, 0),
    Font = Enum.Font.Code,
    Text = "",
    TextColor3 = Color3.fromRGB(238, 235, 246),
    TextSize = 17,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    Visible = false,
}, KeyFrame)

local Eye = new("TextButton", {
    AutoButtonColor = false,
    BackgroundTransparency = 1,
    Position = UDim2.new(1, -54, 0, 0),
    Size = UDim2.fromOffset(54, 54),
    Font = Enum.Font.GothamBold,
    Text = "👁",
    TextColor3 = Color3.fromRGB(173, 167, 193),
    TextSize = 18,
}, KeyFrame)

local Status = new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(30, 258),
    Size = UDim2.new(1, -60, 0, 47),
    Font = Enum.Font.Gotham,
    Text = "Status: Waiting for key...",
    TextColor3 = Color3.fromRGB(166, 162, 180),
    TextSize = 12,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
}, Panel)

local StatusDot = new("Frame", {
    Position = UDim2.fromOffset(30, 310),
    Size = UDim2.fromOffset(8, 8),
    BackgroundColor3 = Color3.fromRGB(116, 110, 135),
    BorderSizePixel = 0,
}, Panel)

new("UICorner", {
    CornerRadius = UDim.new(1, 0),
}, StatusDot)

local Verify = new("TextButton", {
    AutoButtonColor = false,
    Position = UDim2.fromOffset(28, 332),
    Size = UDim2.new(1, -56, 0, 50),
    BackgroundColor3 = Color3.fromRGB(117, 77, 225),
    BorderSizePixel = 0,
    Font = Enum.Font.GothamBold,
    Text = "VERIFY KEY",
    TextColor3 = Color3.fromRGB(255, 255, 255),
    TextSize = 13,
}, Panel)

new("UICorner", {
    CornerRadius = UDim.new(0, 12),
}, Verify)

new("UIStroke", {
    Color = Color3.fromRGB(168, 132, 255),
    Thickness = 1,
    Transparency = 0.25,
}, Verify)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(28, 374),
    Size = UDim2.new(1, -56, 0, 16),
    Font = Enum.Font.Gotham,
    Text = "OPSYX • UserId locked",
    TextColor3 = Color3.fromRGB(88, 84, 104),
    TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Center,
}, Panel)

--// ============================================================
--// STATUS / TOAST
--// ============================================================

local function setStatus(message, kind)
    Status.Text = "Status: " .. tostring(message)

    if kind == "success" then
        Status.TextColor3 = Color3.fromRGB(169, 222, 184)
        StatusDot.BackgroundColor3 = Color3.fromRGB(72, 189, 113)
    elseif kind == "error" then
        Status.TextColor3 = Color3.fromRGB(234, 156, 165)
        StatusDot.BackgroundColor3 = Color3.fromRGB(213, 73, 88)
    elseif kind == "loading" then
        Status.TextColor3 = Color3.fromRGB(189, 175, 221)
        StatusDot.BackgroundColor3 = Color3.fromRGB(151, 106, 245)
    else
        Status.TextColor3 = Color3.fromRGB(166, 162, 180)
        StatusDot.BackgroundColor3 = Color3.fromRGB(116, 110, 135)
    end
end

local ToastContainer = new("Frame", {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -18),
    Size = UDim2.fromOffset(320, 220),
    BackgroundTransparency = 1,
}, ScreenGui)

new("UIListLayout", {
    FillDirection = Enum.FillDirection.Vertical,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Bottom,
    Padding = UDim.new(0, 8),
}, ToastContainer)

local function toast(titleText, messageText, good)
    local card = new("Frame", {
        Size = UDim2.fromOffset(300, 64),
        BackgroundColor3 = Color3.fromRGB(18, 20, 29),
        BorderSizePixel = 0,
    }, ToastContainer)

    new("UICorner", {
        CornerRadius = UDim.new(0, 12),
    }, card)

    new("UIStroke", {
        Color = good and Color3.fromRGB(70, 145, 96) or Color3.fromRGB(85, 77, 111),
        Thickness = 1,
    }, card)

    new("Frame", {
        Size = UDim2.fromOffset(4, 64),
        BackgroundColor3 = good and Color3.fromRGB(79, 190, 116) or Color3.fromRGB(131, 89, 235),
        BorderSizePixel = 0,
    }, card)

    new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(16, 7),
        Size = UDim2.new(1, -25, 0, 18),
        Font = Enum.Font.GothamBold,
        Text = tostring(titleText),
        TextColor3 = Color3.fromRGB(238, 235, 245),
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)

    new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(16, 27),
        Size = UDim2.new(1, -25, 0, 29),
        Font = Enum.Font.Gotham,
        Text = tostring(messageText),
        TextColor3 = Color3.fromRGB(155, 151, 171),
        TextSize = 10,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
    }, card)

    task.spawn(function()
        task.wait(3)

        if not card.Parent then
            return
        end

        local tween = TweenService:Create(
            card,
            TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            {BackgroundTransparency = 1}
        )

        tween:Play()
        tween.Completed:Wait()

        pcall(function()
            card:Destroy()
        end)
    end)
end

--// ============================================================
--// KEY MASKING
--// ============================================================

local function updateMask()
    if keyVisible then
        Mask.Visible = false
        KeyBox.TextTransparency = 0
        return
    end

    local length = #KeyBox.Text

    Mask.Text = string.rep("•", math.min(length, 80))
    Mask.Visible = length > 0

    --// Hide actual characters only while masked.
    KeyBox.TextTransparency = length > 0 and 1 or 0
end

KeyBox:GetPropertyChangedSignal("Text"):Connect(updateMask)

Eye.MouseButton1Click:Connect(function()
    keyVisible = not keyVisible
    Eye.Text = keyVisible and "🙈" or "👁"
    updateMask()
end)

--// ============================================================
--// PLATOBOOST VERIFICATION
--// ============================================================

local function classifyMessage(message)
    message = string.lower(tostring(message or ""))

    if message:find("expire") then
        return "EXPIRED"
    end

    if message:find("revok") then
        return "REVOKED"
    end

    if message:find("identifier")
        or message:find("different")
        or message:find("another account")
        or message:find("already assigned")
        or message:find("already bound") then
        return "WRONG_USER"
    end

    if message:find("invalid")
        or message:find("incorrect")
        or message:find("not found")
        or message:find("does not exist") then
        return "INVALID"
    end

    return nil
end

local function parseJSON(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)

    if not ok or type(decoded) ~= "table" then
        return nil
    end

    return decoded
end

local function verifyIntegrity(validValue, nonce, secret, returnedHash)
    if type(returnedHash) ~= "string" or returnedHash == "" then
        return false
    end

    local expectedHash = sha256(
        tostring(validValue)
            .. "-"
            .. tostring(nonce)
            .. "-"
            .. tostring(secret)
    )

    if not expectedHash then
        return false
    end

    return string.lower(returnedHash) == string.lower(expectedHash)
end

local function verifyKeyOnHost(host, identifier, key)
    --// --------------------------------------------------------
    --// 1. WHITELIST CHECK
    --// --------------------------------------------------------

    local whitelistNonce = generateNonce()

    local whitelistURL = host
        .. "/public/whitelist/"
        .. tostring(SERVICE_ID)
        .. "?identifier="
        .. urlEncode(identifier)
        .. "&key="
        .. urlEncode(key)
        .. "&nonce="
        .. urlEncode(whitelistNonce)

    local requestOK, response, requestError = requestWithTimeout({
        Url = whitelistURL,
        Method = "GET",
        Headers = {
            ["Accept"] = "application/json",
        },
    }, REQUEST_TIMEOUT)

    if not requestOK then
        return false, requestError or "NETWORK", true
    end

    local statusCode = tonumber(
        response.StatusCode
            or response.status_code
    )

    local responseBody = response.Body or response.body

    if statusCode == 429 then
        return false, "RATE_LIMITED", false
    end

    if statusCode ~= 200 then
        if statusCode and statusCode >= 500 then
            return false, "SERVICE_ERROR", true
        end

        return false, "HTTP_" .. tostring(statusCode or "UNKNOWN"), true
    end

    local decoded = parseJSON(responseBody)

    if not decoded then
        return false, "MALFORMED", false
    end

    if decoded.success == true
        and type(decoded.data) == "table"
        and decoded.data.valid == true then

        --// Platoboost's nonce integrity check.
        if not verifyIntegrity(
            true,
            whitelistNonce,
            PLATOBOOST_API_SECRET,
            decoded.data.hash
        ) then
            return false, "INTEGRITY", false
        end

        return true, "SUCCESS", false
    end

    local message = tostring(
        decoded.message
            or decoded.error
            or decoded.reason
            or ""
    )

    local classification = classifyMessage(message)

    --// --------------------------------------------------------
    --// 2. KEY_ REDEMPTION / ACCOUNT BINDING
    --// --------------------------------------------------------
    --// A fresh KEY_ can be redeemed against the current identifier.
    --// This is what establishes the key -> UserId relationship.

    if key:sub(1, 4) == "KEY_" then
        local redeemNonce = generateNonce()

        local redeemURL = host
            .. "/public/redeem/"
            .. tostring(SERVICE_ID)

        local bodyOK, encodedBody = pcall(function()
            return HttpService:JSONEncode({
                identifier = identifier,
                key = key,
                nonce = redeemNonce,
            })
        end)

        if not bodyOK or type(encodedBody) ~= "string" then
            return false, "MALFORMED", false
        end

        local redeemOK, redeemResponse, redeemError = requestWithTimeout({
            Url = redeemURL,
            Method = "POST",
            Headers = {
                ["Accept"] = "application/json",
                ["Content-Type"] = "application/json",
            },
            Body = encodedBody,
        }, REQUEST_TIMEOUT)

        if not redeemOK then
            return false, redeemError or "NETWORK", true
        end

        local redeemStatus = tonumber(
            redeemResponse.StatusCode
                or redeemResponse.status_code
        )

        local redeemBody = redeemResponse.Body or redeemResponse.body

        if redeemStatus == 429 then
            return false, "RATE_LIMITED", false
        end

        if redeemStatus ~= 200 then
            if redeemStatus and redeemStatus >= 500 then
                return false, "SERVICE_ERROR", true
            end

            return false, "HTTP_" .. tostring(redeemStatus or "UNKNOWN"), true
        end

        local redeemDecoded = parseJSON(redeemBody)

        if not redeemDecoded then
            return false, "MALFORMED", false
        end

        if redeemDecoded.success == true
            and type(redeemDecoded.data) == "table"
            and redeemDecoded.data.valid == true then

            if not verifyIntegrity(
                true,
                redeemNonce,
                PLATOBOOST_API_SECRET,
                redeemDecoded.data.hash
            ) then
                return false, "INTEGRITY", false
            end

            return true, "SUCCESS", false
        end

        local redeemMessage = tostring(
            redeemDecoded.message
                or redeemDecoded.error
                or redeemDecoded.reason
                or ""
        )

        return false,
            classifyMessage(redeemMessage) or "INVALID",
            false
    end

    return false, classification or "INVALID", false
end

local function verifyPlatoboost(key)
    key = trim(key)

    if key == "" then
        return false, "EMPTY"
    end

    local identifier, identifierError = getIdentifier()

    if not identifier then
        return false, identifierError
    end

    local lastReason = "NETWORK"
    local sawNetworkFailure = false

    --// Try the current primary host and the current fallback host.
    --// This avoids the old api-gateway host entirely.
    for _, host in ipairs(PLATOBOOST_HOSTS) do
        local success, reason, retryable = verifyKeyOnHost(
            host,
            identifier,
            key
        )

        if success then
            activeHost = host
            return true, "SUCCESS"
        end

        lastReason = reason

        if reason == "NETWORK"
            or reason == "TIMEOUT"
            or reason == "HTTP_403"
            or reason == "SERVICE_ERROR" then
            sawNetworkFailure = true
        else
            --// A genuine API answer such as INVALID/EXPIRED/WRONG_USER
            --// should not be hidden by another host's result.
            activeHost = host
            return false, reason
        end
    end

    if sawNetworkFailure then
        return false, lastReason
    end

    return false, lastReason
end

--// ============================================================
--// RAW OPSYX1 EXECUTION
--// ============================================================

local function executeOPSYXOnce()
    --// Absolute once-only execution guard.
    if hasExecuted then
        return false, "ALREADY_EXECUTED"
    end

    --// Authentication must already be true.
    if not authenticated then
        return false, "NOT_AUTHENTICATED"
    end

    if not alive or not LocalPlayer.Parent then
        return false, "PLAYER_LEFT"
    end

    --// Set BEFORE download/execution so a failure cannot accidentally
    --// cause duplicate launches on a subsequent callback.
    hasExecuted = true

    setStatus(
        "Key verified successfully.\nLaunching OPSYX...",
        "success"
    )

    toast(
        "Key verified",
        "Launching OPSYX...",
        true
    )

    local success, err = pcall(function()
        --// This is the FIRST point in the file where RAW_URL is called.
        local httpOK, source = pcall(function()
            return game:HttpGet(RAW_URL)
        end)

        if not httpOK then
            error("Raw script download failed: " .. tostring(source))
        end

        if type(source) ~= "string" or source == "" then
            error("Raw script returned an empty response.")
        end

        if type(loadstring) ~= "function" then
            error("loadstring is unavailable in this executor.")
        end

        local chunk, compileError = loadstring(source)

        if type(chunk) ~= "function" then
            error("Raw script compilation failed: " .. tostring(compileError))
        end

        --// Execute exactly once.
        chunk()
    end)

    if not success then
        setStatus(
            "Authentication succeeded, but OPSYX failed to launch.",
            "error"
        )

        toast(
            "Launch failed",
            "Authentication succeeded, but OPSYX failed to launch.",
            false
        )

        warnOPSYX(err)

        return false, tostring(err)
    end

    setStatus("OPSYX launched successfully.", "success")

    toast(
        "OPSYX launched",
        "Authentication and execution completed.",
        true
    )

    task.delay(0.8, function()
        pcall(function()
            ScreenGui:Destroy()
        end)
    end)

    return true
end

--// ============================================================
--// AUTHENTICATION
--// ============================================================

local function authenticate(key)
    if verifying then
        toast(
            "Verification busy",
            "A verification request is already running.",
            false
        )

        return
    end

    if not alive or not LocalPlayer.Parent then
        return
    end

    key = trim(key)

    if key == "" then
        setStatus("Please enter your key.", "error")

        toast(
            "Missing key",
            "Enter a Platoboost key first.",
            false
        )

        return
    end

    if hasExecuted then
        return
    end

    verifying = true
    authenticated = false
    _G.__OPSYX_LICENSE_CONTEXT = nil
    verificationToken += 1

    local token = verificationToken

    Verify.Text = "VERIFYING..."
    KeyBox.TextEditable = false
    Eye.Active = false

    setStatus("Verifying key...", "loading")

    task.spawn(function()
        local success, reason = verifyPlatoboost(key)

        if token ~= verificationToken or not alive then
            return
        end

        verifying = false
        KeyBox.TextEditable = true
        Eye.Active = true
        Verify.Text = "VERIFY KEY"

        if not success then
            authenticated = false
            _G.__OPSYX_LICENSE_CONTEXT = nil

            if reason == "WRONG_USER" then
                setStatus(
                    "Access denied.\nThis key is assigned to another Roblox account.",
                    "error"
                )

                toast(
                    "Access denied",
                    "This key is assigned to another Roblox account.",
                    false
                )

            elseif reason == "INVALID" or reason == "REVOKED" then
                setStatus("Invalid or revoked key.", "error")

                toast(
                    "Invalid key",
                    "This key is invalid or has been revoked.",
                    false
                )

                clearSavedKey()

            elseif reason == "EXPIRED" then
                setStatus("This key has expired.", "error")

                toast(
                    "Expired key",
                    "Your Platoboost key has expired.",
                    false
                )

                clearSavedKey()

            elseif reason == "HTTP_403" then
                setStatus(
                    "Unable to verify key.\nPlatoboost returned HTTP 403.",
                    "error"
                )

                toast(
                    "Platoboost access denied",
                    "Both current Platoboost API hosts rejected the request.",
                    false
                )

            elseif reason == "SERVICE_ERROR" then
                setStatus(
                    "Unable to verify key.\nPlatoboost service error.",
                    "error"
                )

                toast(
                    "Platoboost error",
                    "The Platoboost service returned a server error.",
                    false
                )

            elseif reason == "RATE_LIMITED" then
                setStatus(
                    "Unable to verify key.\nPlatoboost rate limit reached.",
                    "error"
                )

                toast(
                    "Rate limited",
                    "Please wait and try again.",
                    false
                )

            elseif reason == "TIMEOUT" then
                setStatus(
                    "Unable to verify key.\nRequest timed out.",
                    "error"
                )

                toast(
                    "Verification timeout",
                    "Platoboost did not respond in time.",
                    false
                )

            elseif reason == "HTTP_UNAVAILABLE" then
                setStatus(
                    "Unable to verify key.\nNo supported HTTP function found.",
                    "error"
                )

                toast(
                    "HTTP unavailable",
                    "Your executor does not expose a supported request function.",
                    false
                )

            elseif reason == "INTEGRITY_UNAVAILABLE" then
                setStatus(
                    "Unable to verify key.\nSHA-256 is unavailable.",
                    "error"
                )

                toast(
                    "Integrity unavailable",
                    "Your executor does not expose SHA-256 hashing.",
                    false
                )

            elseif reason == "INTEGRITY" then
                setStatus(
                    "Unable to verify key.\nIntegrity validation failed.",
                    "error"
                )

                toast(
                    "Integrity failed",
                    "Platoboost response integrity could not be verified.",
                    false
                )

            elseif reason == "MALFORMED" then
                setStatus(
                    "Unable to verify key.\nInvalid Platoboost response.",
                    "error"
                )

                toast(
                    "Malformed response",
                    "Platoboost returned unexpected data.",
                    false
                )

            elseif type(reason) == "string" and reason:sub(1, 5) == "HTTP_" then
                setStatus(
                    "Unable to verify key.\nServer returned " .. reason:sub(6) .. ".",
                    "error"
                )

                toast(
                    "Platoboost HTTP error",
                    "Server returned HTTP " .. reason:sub(6) .. ".",
                    false
                )

            else
                setStatus(
                    "Unable to verify key.\nPlease try again.",
                    "error"
                )

                toast(
                    "Verification failed",
                    "Platoboost verification could not be completed.",
                    false
                )
            end

            warnOPSYX("Verification error: " .. tostring(reason))
            return
        end

        --// ========================================================
        --// AUTHENTICATION SUCCESS
        --// No raw URL request occurs before this point.
        --// ========================================================

        authenticated = true

        -- Issue a short-lived launch context for the protected raw script.
        -- The raw script will compare UserId, age, proof, and independently
        -- re-check the key with Platoboost before it starts.
        local launchNonce = generateNonce()
        local launchProof = sha256(
            userId .. "|" .. key .. "|" .. launchNonce .. "|OPSYX-LAUNCH"
        )

        if not launchProof then
            authenticated = false
            setStatus("Unable to launch.
SHA-256 is unavailable.", "error")
            toast(
                "Launch protection unavailable",
                "Your executor does not provide SHA-256.",
                false
            )
            return
        end

        _G.__OPSYX_LICENSE_CONTEXT = {
            userId = userId,
            key = key,
            nonce = launchNonce,
            proof = launchProof,
            issuedAt = os.time(),
            secret = PLATOBOOST_API_SECRET,
        }

        saveKey(key)

        if not authenticated or hasExecuted then
            return
        end

        executeOPSYXOnce()
    end)
end

--// ============================================================
--// UI EVENTS
--// ============================================================

Verify.MouseButton1Click:Connect(function()
    authenticate(KeyBox.Text)
end)

KeyBox.FocusLost:Connect(function(enterPressed)
    if enterPressed and not verifying then
        authenticate(KeyBox.Text)
    end
end)

--// ============================================================
--// PLAYER LEAVE PROTECTION
--// ============================================================

Players.PlayerRemoving:Connect(function(player)
    if player == LocalPlayer then
        alive = false
        authenticated = false
        verificationToken += 1

        pcall(function()
            ScreenGui:Destroy()
        end)
    end
end)

--// ============================================================
--// STARTUP ANIMATION
--// ============================================================

Panel.Position = UDim2.fromScale(0.5, 0.57)
Panel.BackgroundTransparency = 0.2

TweenService:Create(
    Panel,
    TweenInfo.new(0.42, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    {
        Position = UDim2.fromScale(0.5, 0.52),
        BackgroundTransparency = 0,
    }
):Play()

--// ============================================================
--// INITIALIZE SAVED KEY
--// ============================================================

task.spawn(function()
    local savedKey = loadSavedKey()

    if not savedKey or not alive then
        return
    end

    KeyBox.Text = savedKey
    updateMask()

    setStatus("Checking saved key...", "loading")

    toast(
        "Saved key detected",
        "Re-validating your saved key...",
        true
    )

    --// A saved key is NEVER trusted locally.
    authenticate(savedKey)
end)
