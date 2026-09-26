-- OPSYX PLATOBOOST KEY SYSTEM
-- Improved reliability / saved-key handling / request handling.
-- No client-side expiry, countdown, timestamp, or duration system is used.
-- Key validity remains controlled by the PlatoBoost service.

local SERVICE_ID = 31267

-- Optional compatibility check from the existing integration.
-- Keep empty if your PlatoBoost setup does not use the integrity hash.
local PLATO_INTEGRITY_SECRET = "b952215a-a2ca-43b4-9841-3c090c4d51eb"

local MAIN_SCRIPT_URL =
    "https://raw.githubusercontent.com/projectopsyx-lang/OPSYX-script/refs/heads/main/OPSYX1"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")

local Player = Players.LocalPlayer
if not Player then
    Player = Players.PlayerAdded:Wait()
end

local REQUEST_RETRIES = 2
local REQUEST_RETRY_DELAY = 0.35
local KEY_STORE_FILE = "OPSYX_SavedKeys.json"

local gui
local busy = false
local launched = false
local host = nil

local function trim(value)
    value = tostring(value or "")
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    return value
end

local function getRequest()
    if type(request) == "function" then
        return request
    end

    if type(http_request) == "function" then
        return http_request
    end

    if type(syn_request) == "function" then
        return syn_request
    end

    if type(http) == "table" and type(http.request) == "function" then
        return http.request
    end

    return nil
end

local function normalizeResponse(response)
    if type(response) ~= "table" then
        return nil
    end

    local statusCode = response.StatusCode or response.status_code or response.Status
    local body = response.Body

    if body == nil then
        body = response.body
    end

    return {
        StatusCode = tonumber(statusCode),
        Body = tostring(body or ""),
        Headers = response.Headers or response.headers
    }
end

local function shouldRetry(statusCode)
    statusCode = tonumber(statusCode)

    if not statusCode then
        return true
    end

    return statusCode == 408
        or statusCode == 429
        or statusCode >= 500
end

local function send(options)
    local req = getRequest()
    if not req then
        return nil, "HTTP requests are not supported by this executor."
    end

    local lastError = "Request failed."

    for attempt = 1, REQUEST_RETRIES + 1 do
        local ok, rawResponse = pcall(function()
            return req(options)
        end)

        if ok then
            local response = normalizeResponse(rawResponse)

            if response then
                if not shouldRetry(response.StatusCode) or attempt > REQUEST_RETRIES then
                    return response
                end

                lastError = "HTTP " .. tostring(response.StatusCode)
            else
                lastError = "Invalid HTTP response."
            end
        else
            lastError = tostring(rawResponse or "Request failed.")
        end

        if attempt <= REQUEST_RETRIES then
            task.wait(REQUEST_RETRY_DELAY * attempt)
        end
    end

    return nil, lastError
end

local function jsonEncode(value)
    local ok, result = pcall(function()
        return HttpService:JSONEncode(value)
    end)

    if ok and type(result) == "string" then
        return result
    end

    return nil
end

local function jsonDecode(value)
    local ok, result = pcall(function()
        return HttpService:JSONDecode(value)
    end)

    if ok and type(result) == "table" then
        return result
    end

    return nil
end

local function getIdentifier()
    if type(gethwid) == "function" then
        local ok, value = pcall(gethwid)
        if ok and value ~= nil and tostring(value) ~= "" then
            return tostring(value)
        end
    end

    local ok, value = pcall(function()
        return game:GetService("RbxAnalyticsService"):GetClientId()
    end)

    if ok and value ~= nil and tostring(value) ~= "" then
        return tostring(value)
    end

    return tostring(Player.UserId)
end

local function digest(value)
    if crypt and type(crypt.hash) == "function" then
        local ok, result = pcall(crypt.hash, value)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end

    if syn and syn.crypt and type(syn.crypt.hash) == "function" then
        local ok, result = pcall(syn.crypt.hash, value)
        if ok and type(result) == "string" and result ~= "" then
            return result
        end
    end

    return tostring(value)
end

local function nonce()
    local pool = "abcdefghijklmnopqrstuvwxyz0123456789"
    local result = {}

    for i = 1, 24 do
        local index = math.random(1, #pool)
        result[i] = pool:sub(index, index)
    end

    return table.concat(result)
end

local HOSTS = {
    "https://api.platoboost.com",
    "https://api.platoboost.net"
}

local function selectHost(forceRefresh)
    if host and not forceRefresh then
        return host
    end

    host = nil

    for i = 1, #HOSTS do
        local response = send({
            Url = HOSTS[i] .. "/public/connectivity",
            Method = "GET"
        })

        if response then
            local code = tonumber(response.StatusCode)

            if code == 200 or code == 429 then
                host = HOSTS[i]
                return host
            end
        end
    end

    return nil
end

local function getUsernameKey()
    return tostring(Player.Name or Player.UserId)
end

local function getUserIdKey()
    return tostring(Player.UserId)
end

local function readSavedKeys()
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return {}
    end

    local exists = false
    local okExists = pcall(function()
        exists = isfile(KEY_STORE_FILE)
    end)

    if not okExists or not exists then
        return {}
    end

    local okRead, raw = pcall(readfile, KEY_STORE_FILE)
    if not okRead or type(raw) ~= "string" or trim(raw) == "" then
        return {}
    end

    local data = jsonDecode(raw)
    if type(data) == "table" then
        return data
    end

    return {}
end

local function writeSavedKeys(data)
    if type(writefile) ~= "function" then
        return false, "File writing is not supported by this executor."
    end

    local encoded = jsonEncode(data)
    if not encoded then
        return false, "Unable to encode saved key data."
    end

    local ok, err = pcall(function()
        writefile(KEY_STORE_FILE, encoded)
    end)

    if not ok then
        return false, tostring(err or "Unable to save key.")
    end

    return true
end

local function saveKeyForUser(key)
    key = trim(key)

    if key == "" then
        return false, "Key is empty."
    end

    local data = readSavedKeys()

    -- Stable UserId storage prevents a username rename from losing the key.
    data["user_" .. getUserIdKey()] = key

    -- Preserve the original username-based entry for backward compatibility.
    data[getUsernameKey()] = key

    return writeSavedKeys(data)
end

local function getSavedKeyForUser()
    local data = readSavedKeys()

    local stableValue = data["user_" .. getUserIdKey()]
    if type(stableValue) == "string" then
        stableValue = trim(stableValue)

        if stableValue ~= "" then
            return stableValue
        end
    end

    -- Backward compatibility with the original format.
    local legacyValue = data[getUsernameKey()]
    if type(legacyValue) == "string" then
        legacyValue = trim(legacyValue)

        if legacyValue ~= "" then
            data["user_" .. getUserIdKey()] = legacyValue
            writeSavedKeys(data)
            return legacyValue
        end
    end

    return nil
end

local function clearSavedKeyForUser()
    local data = readSavedKeys()
    local changed = false

    if data["user_" .. getUserIdKey()] ~= nil then
        data["user_" .. getUserIdKey()] = nil
        changed = true
    end

    if data[getUsernameKey()] ~= nil then
        data[getUsernameKey()] = nil
        changed = true
    end

    if changed then
        writeSavedKeys(data)
    end
end

local function parsePlatoResponse(response, fallbackMessage)
    if not response then
        return false, fallbackMessage or "No response from PlatoBoost."
    end

    local statusCode = tonumber(response.StatusCode)
    if not statusCode then
        return false, "PlatoBoost returned an invalid HTTP status."
    end

    if statusCode ~= 200 then
        if statusCode == 401 or statusCode == 403 then
            return false, "PlatoBoost rejected the request."
        end

        if statusCode == 429 then
            return false, "PlatoBoost rate limit reached. Please try again."
        end

        return false, "PlatoBoost HTTP " .. tostring(statusCode)
    end

    local data = jsonDecode(response.Body)
    if type(data) ~= "table" then
        return false, "Invalid PlatoBoost response."
    end

    return true, nil, data
end

local function buildRedeemBody(key, n)
    return jsonEncode({
        identifier = digest(getIdentifier()),
        key = key,
        nonce = n
    }) or "{}"
end

local function redeemKey(key)
    key = trim(key)

    if key == "" then
        return false, "Enter a key first."
    end

    local h = selectHost()

    if not h then
        return false, "PlatoBoost is unreachable."
    end

    local n = nonce()

    local response, err = send({
        Url = h .. "/public/redeem/" .. tostring(SERVICE_ID),
        Method = "POST",
        Body = buildRedeemBody(key, n),
        Headers = {
            ["Content-Type"] = "application/json"
        }
    })

    if not response then
        h = selectHost(true)

        if h then
            response, err = send({
                Url = h .. "/public/redeem/" .. tostring(SERVICE_ID),
                Method = "POST",
                Body = buildRedeemBody(key, n),
                Headers = {
                    ["Content-Type"] = "application/json"
                }
            })
        end
    end

    if not response then
        return false, err or "Connection error."
    end

    local parsed, parseMessage, data = parsePlatoResponse(response)
    if not parsed then
        return false, parseMessage
    end

    if not data.success or type(data.data) ~= "table" or not data.data.valid then
        return false, tostring(data.message or "Key was rejected by PlatoBoost.")
    end

    -- Optional existing integrity check. It adds no expiry or duration logic.
    if PLATO_INTEGRITY_SECRET ~= ""
        and type(data.data.hash) == "string"
        and crypt
        and type(crypt.hash) == "function" then

        local okHash, expected = pcall(
            crypt.hash,
            "true-" .. n .. "-" .. PLATO_INTEGRITY_SECRET
        )

        if okHash and type(expected) == "string"
            and expected ~= data.data.hash then
            return false, "Integrity check failed."
        end
    end

    return true, "Valid key.", data.data
end

local function buildWhitelistUrl(hostValue, identifier, key)
    return hostValue .. "/public/whitelist/" .. tostring(SERVICE_ID)
        .. "?identifier=" .. HttpService:UrlEncode(tostring(identifier))
        .. "&key=" .. HttpService:UrlEncode(tostring(key))
end

local function verifySavedKey(key)
    key = trim(key)

    if key == "" then
        return false, "Saved key is empty."
    end

    local h = selectHost()

    if not h then
        return false, "PlatoBoost is unreachable."
    end

    local identifier = digest(getIdentifier())
    local endpoint = buildWhitelistUrl(h, identifier, key)

    local response, err = send({
        Url = endpoint,
        Method = "GET"
    })

    if not response then
        h = selectHost(true)

        if h then
            endpoint = buildWhitelistUrl(h, identifier, key)

            response, err = send({
                Url = endpoint,
                Method = "GET"
            })
        end
    end

    if not response then
        return false, err or "Connection error."
    end

    local parsed, parseMessage, data = parsePlatoResponse(response)
    if not parsed then
        return false, parseMessage
    end

    if data.success and type(data.data) == "table" and data.data.valid then
        return true, "Valid key.", data.data
    end

    return false, tostring(data.message or "Saved key was rejected by PlatoBoost.")
end

local function fetchMainScript()
    -- Prefer executor HTTP first, then fall back to game:HttpGet.
    local response, err = send({
        Url = MAIN_SCRIPT_URL,
        Method = "GET"
    })

    if response
        and tonumber(response.StatusCode) == 200
        and type(response.Body) == "string"
        and response.Body ~= "" then
        return true, response.Body
    end

    local ok, source = pcall(function()
        return game:HttpGet(MAIN_SCRIPT_URL)
    end)

    if ok and type(source) == "string" and source ~= "" then
        return true, source
    end

    return false, err or "Unable to download OPSYX."
end

local function executeMain()
    if launched then
        return false, "OPSYX is already running."
    end

    launched = true

    local ok, source = fetchMainScript()

    if not ok then
        launched = false
        Player:Kick(tostring(source))
        return false
    end

    local fn = loadstring(source)

    if type(fn) ~= "function" then
        launched = false
        Player:Kick("OPSYX failed to compile.")
        return false
    end

    local ran = pcall(fn)

    if not ran then
        launched = false
        Player:Kick("OPSYX failed to start.")
        return false
    end

    return true
end

local function destroyExistingGui()
    local old = CoreGui:FindFirstChild("OPSYX_SimpleKey")

    if old then
        old:Destroy()
    end
end

destroyExistingGui()

gui = Instance.new("ScreenGui")
gui.Name = "OPSYX_SimpleKey"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

pcall(function()
    gui.IgnoreGuiInset = true
end)

gui.Parent = CoreGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 340, 0, 312)
frame.Position = UDim2.new(0.5, -170, 0.5, -146)
frame.BackgroundColor3 = Color3.fromRGB(17, 20, 29)
frame.BorderSizePixel = 0
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -30, 0, 35)
title.Position = UDim2.new(0, 15, 0, 12)
title.BackgroundTransparency = 1
title.Text = "OPSYX PAID KEY SYSTEM"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 18
title.Parent = frame

local input = Instance.new("TextBox")
input.Size = UDim2.new(1, -30, 0, 42)
input.Position = UDim2.new(0, 15, 0, 55)
input.BackgroundColor3 = Color3.fromRGB(28, 33, 45)
input.BorderSizePixel = 0
input.PlaceholderText = "Enter Paid PlatoBoost key"
input.Text = ""
input.TextColor3 = Color3.new(1, 1, 1)
input.PlaceholderColor3 = Color3.fromRGB(130, 140, 155)
input.ClearTextOnFocus = false
input.Font = Enum.Font.Gotham
input.TextSize = 14
input.Parent = frame

local inputCorner = Instance.new("UICorner")
inputCorner.CornerRadius = UDim.new(0, 8)
inputCorner.Parent = input

local verifyButton = Instance.new("TextButton")
verifyButton.Size = UDim2.new(1, -30, 0, 38)
verifyButton.Position = UDim2.new(0, 15, 0, 107)
verifyButton.BackgroundColor3 = Color3.fromRGB(0, 120, 255)
verifyButton.BorderSizePixel = 0
verifyButton.Text = "VERIFY & SAVE"
verifyButton.TextColor3 = Color3.new(1, 1, 1)
verifyButton.Font = Enum.Font.GothamBold
verifyButton.TextSize = 13
verifyButton.AutoButtonColor = true
verifyButton.Parent = frame

local verifyCorner = Instance.new("UICorner")
verifyCorner.CornerRadius = UDim.new(0, 8)
verifyCorner.Parent = verifyButton

local ratesButton = Instance.new("TextButton")
ratesButton.Size = UDim2.new(1, -30, 0, 34)
ratesButton.Position = UDim2.new(0, 15, 0, 151)
ratesButton.BackgroundColor3 = Color3.fromRGB(28, 33, 45)
ratesButton.BorderSizePixel = 0
ratesButton.Text = "KEY RATES"
ratesButton.TextColor3 = Color3.new(1, 1, 1)
ratesButton.Font = Enum.Font.GothamBold
ratesButton.TextSize = 12
ratesButton.AutoButtonColor = true
ratesButton.Parent = frame

local ratesCorner = Instance.new("UICorner")
ratesCorner.CornerRadius = UDim.new(0, 8)
ratesCorner.Parent = ratesButton

local buyMessage = Instance.new("TextLabel")
buyMessage.Size = UDim2.new(1, -30, 0, 28)
buyMessage.Position = UDim2.new(0, 15, 0, 188)
buyMessage.BackgroundTransparency = 1
buyMessage.Text = "TO BUY A KEY, DM ME ON DISCORD"
buyMessage.TextColor3 = Color3.fromRGB(255, 255, 255)
buyMessage.Font = Enum.Font.GothamBold
buyMessage.TextSize = 11
buyMessage.TextWrapped = true
buyMessage.Parent = frame

local discordLink = Instance.new("TextButton")
discordLink.Size = UDim2.new(1, -30, 0, 30)
discordLink.Position = UDim2.new(0, 15, 0, 214)
discordLink.BackgroundColor3 = Color3.fromRGB(28, 33, 45)
discordLink.BorderSizePixel = 0
discordLink.Text = "BUY KEY ON DISCORD"
discordLink.TextColor3 = Color3.new(1, 1, 1)
discordLink.Font = Enum.Font.GothamBold
discordLink.TextSize = 11
discordLink.AutoButtonColor = true
discordLink.Parent = frame

local discordCorner = Instance.new("UICorner")
discordCorner.CornerRadius = UDim.new(0, 8)
discordCorner.Parent = discordLink

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -30, 0, 30)
status.Position = UDim2.new(0, 15, 0, 250)
status.BackgroundTransparency = 1
status.Text = "Checking saved key for " .. getUsernameKey() .. "..."
status.TextColor3 = Color3.fromRGB(0, 200, 255)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextWrapped = true
status.Parent = frame

local warning = Instance.new("TextLabel")
warning.Size = UDim2.new(1, -30, 0, 18)
warning.Position = UDim2.new(0, 15, 0, 270)
warning.BackgroundTransparency = 1
warning.Text = "⚠ Never share your key with anyone."
warning.TextColor3 = Color3.fromRGB(255, 170, 70)
warning.Font = Enum.Font.GothamBold
warning.TextSize = 11
warning.TextWrapped = true
warning.Parent = frame

discordLink.MouseButton1Click:Connect(function()
    local url = "https://discord.com/users/1529328825685508209"
    local copied = false

    if type(setclipboard) == "function" then
        copied = pcall(setclipboard, url)
    elseif type(toclipboard) == "function" then
        copied = pcall(toclipboard, url)
    end

    if copied then
        status.Text = "Discord profile link copied to clipboard."
        status.TextColor3 = Color3.fromRGB(70, 220, 150)
    else
        status.Text = "Discord: " .. url
        status.TextColor3 = Color3.fromRGB(0, 200, 255)
    end
end)

local function addCorner(object, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = object
    return c
end

local function createRateCell(parent, textValue, position, size, header)
    local cell = Instance.new("TextLabel")
    cell.Size = size
    cell.Position = position
    cell.BackgroundTransparency = header and 0 or 0.15
    cell.BackgroundColor3 = header and Color3.fromRGB(37, 43, 56) or Color3.fromRGB(24, 29, 40)
    cell.BorderSizePixel = 1
    cell.BorderColor3 = Color3.fromRGB(115, 125, 140)
    cell.Text = textValue
    cell.TextColor3 = Color3.new(1, 1, 1)
    cell.Font = header and Enum.Font.GothamBold or Enum.Font.Gotham
    cell.TextSize = header and 12 or 13
    cell.TextXAlignment = Enum.TextXAlignment.Center
    cell.TextYAlignment = Enum.TextYAlignment.Center
    cell.Parent = parent
    return cell
end

local function showKeyRates()
    if gui:FindFirstChild("OPSYX_KeyRates") then
        return
    end

    local overlay = Instance.new("Frame")
    overlay.Name = "OPSYX_KeyRates"
    overlay.Size = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.38
    overlay.BorderSizePixel = 0
    overlay.ZIndex = 20
    overlay.Parent = gui

    local panel = Instance.new("Frame")
    panel.Size = UDim2.new(0, 330, 0, 292)
    panel.Position = UDim2.new(0.5, -165, 0.5, -146)
    panel.BackgroundColor3 = Color3.fromRGB(17, 20, 29)
    panel.BorderSizePixel = 0
    panel.ZIndex = 21
    panel.Parent = overlay
    addCorner(panel, 12)

    local panelTitle = Instance.new("TextLabel")
    panelTitle.Size = UDim2.new(1, -60, 0, 36)
    panelTitle.Position = UDim2.new(0, 15, 0, 12)
    panelTitle.BackgroundTransparency = 1
    panelTitle.Text = "KEY RATES"
    panelTitle.TextColor3 = Color3.fromRGB(0, 200, 255)
    panelTitle.Font = Enum.Font.GothamBold
    panelTitle.TextSize = 18
    panelTitle.TextXAlignment = Enum.TextXAlignment.Left
    panelTitle.ZIndex = 22
    panelTitle.Parent = panel

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 34, 0, 34)
    close.Position = UDim2.new(1, -46, 0, 10)
    close.BackgroundTransparency = 1
    close.Text = "×"
    close.TextColor3 = Color3.fromRGB(150, 160, 175)
    close.Font = Enum.Font.GothamBold
    close.TextSize = 24
    close.ZIndex = 22
    close.Parent = panel
    close.MouseButton1Click:Connect(function()
        overlay:Destroy()
    end)

    local tableFrame = Instance.new("Frame")
    tableFrame.Size = UDim2.new(1, -30, 0, 180)
    tableFrame.Position = UDim2.new(0, 15, 0, 56)
    tableFrame.BackgroundTransparency = 1
    tableFrame.BorderSizePixel = 0
    tableFrame.ZIndex = 22
    tableFrame.Parent = panel

    local colW = {0.34, 0.28, 0.38}
    local x1 = 0
    local x2 = colW[1]
    local x3 = colW[1] + colW[2]

    local headers = {"Amount", "Time", "Validity"}
    local values = {
        {"₱5",  "2h", "4h"},
        {"₱10", "4h", "6h"},
        {"₱15", "6h", "8h"},
        {"₱20", "9h", "1d"}
    }

    for i, header in ipairs(headers) do
        local x = ({x1, x2, x3})[i]
        local w = ({colW[1], colW[2], colW[3]})[i]
        createRateCell(
            tableFrame,
            header,
            UDim2.new(x, 0, 0, 0),
            UDim2.new(w, 0, 0, 35),
            true
        )
    end

    for rowIndex, row in ipairs(values) do
        local y = 35 + ((rowIndex - 1) * 29)
        local rowValues = {row[1], row[2], row[3]}

        for colIndex, value in ipairs(rowValues) do
            local x = ({x1, x2, x3})[colIndex]
            local w = ({colW[1], colW[2], colW[3]})[colIndex]
            createRateCell(
                tableFrame,
                value,
                UDim2.new(x, 0, 0, y),
                UDim2.new(w, 0, 0, 29),
                false
            )
        end
    end

    local note = Instance.new("TextLabel")
    note.Size = UDim2.new(1, -30, 0, 34)
    note.Position = UDim2.new(0, 15, 0, 244)
    note.BackgroundTransparency = 1
    note.Text = "Rates are display-only. Key validation remains handled by PlatoBoost."
    note.TextColor3 = Color3.fromRGB(155, 165, 180)
    note.Font = Enum.Font.Gotham
    note.TextSize = 10
    note.TextWrapped = true
    note.ZIndex = 22
    note.Parent = panel
end

local function setStatus(message, color)
    status.Text = tostring(message or "")
    status.TextColor3 = color
end

ratesButton.MouseButton1Click:Connect(showKeyRates)

local function launch()
    if launched then
        return
    end

    if gui and gui.Parent then
        gui:Destroy()
    end

    executeMain()
end

local function showManualEntry(message)
    input.Visible = true
    verifyButton.Visible = true
    verifyButton.Text = "VERIFY & SAVE"
    setStatus(message, Color3.fromRGB(160, 170, 185))
end

verifyButton.MouseButton1Click:Connect(function()
    if busy or launched then
        return
    end

    local key = trim(input.Text)

    if key == "" then
        setStatus("Enter a key first.", Color3.fromRGB(255, 170, 70))
        return
    end

    busy = true
    verifyButton.Text = "CHECKING..."
    setStatus("Checking PlatoBoost...", Color3.fromRGB(0, 200, 255))

    task.spawn(function()
        local ok, message = redeemKey(key)

        if not ok then
            verifyButton.Text = "VERIFY & SAVE"
            setStatus(message, Color3.fromRGB(255, 90, 100))
            busy = false
            return
        end

        local saved, saveMessage = saveKeyForUser(key)

        if not saved then
            verifyButton.Text = "VERIFY & SAVE"
            setStatus(
                "Key is valid, but could not be saved: " .. tostring(saveMessage),
                Color3.fromRGB(255, 170, 70)
            )
            busy = false
            return
        end

        setStatus(
            "Key verified and saved for " .. getUsernameKey() .. ". Loading OPSYX...",
            Color3.fromRGB(70, 220, 150)
        )

        task.wait(0.25)
        busy = false
        launch()
    end)
end)

task.spawn(function()
    local savedKey = getSavedKeyForUser()

    if not savedKey then
        showManualEntry(
            "No saved key for " .. getUsernameKey() .. ". Enter it once to save it."
        )
        return
    end

    input.Visible = false
    verifyButton.Visible = false
    setStatus("Validating saved key...", Color3.fromRGB(0, 200, 255))

    local ok, message = verifySavedKey(savedKey)

    if ok then
        setStatus("Key valid. Loading OPSYX...", Color3.fromRGB(70, 220, 150))
        task.wait(0.25)
        launch()
        return
    end

    -- Remove the rejected saved key so the user can enter a replacement.
    clearSavedKeyForUser()
    showManualEntry(tostring(message) .. "\\nEnter a replacement key.")
end)
