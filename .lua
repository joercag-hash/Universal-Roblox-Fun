--[[
	Universal Fun
	Fly, phase through walls, and tune your speed from one polished panel.

	SETUP
		Put this LocalScript in StarterPlayer > StarterPlayerScripts.

	CONTROLS (rebind them in CONFIG below)
		F ............ toggle Fly
		G ............ toggle Phase
		RightShift ... show / hide the panel (the round UF button does the same)

		While flying, move as usual and you travel wherever the camera looks.
		Space or E rises, Q or LeftCtrl sinks. On mobile the jump button rises.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

local CONFIG = {
	AllowedUserIds = {}, -- empty = every player gets the panel; or list UserIds, e.g. { 12345678 }
	DefaultSpeed = 16, -- where the slider starts (16 is Roblox's normal walk speed)
	StartOpen = true, -- show the panel as soon as the player joins

	FlyKey = Enum.KeyCode.F,
	PhaseKey = Enum.KeyCode.G,
	PanelKey = Enum.KeyCode.RightShift,
	AscendKeys = { Enum.KeyCode.Space, Enum.KeyCode.E, Enum.KeyCode.ButtonR2 },
	DescendKeys = { Enum.KeyCode.Q, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonL2 },

	AccentA = Color3.fromRGB(139, 92, 246), -- violet
	AccentB = Color3.fromRGB(34, 211, 238), -- cyan
}

local MIN_SPEED, MAX_SPEED = 1, 100

local THEME = {
	Panel = Color3.fromRGB(17, 17, 26),
	Card = Color3.fromRGB(26, 26, 38),
	Inset = Color3.fromRGB(40, 40, 58),
	Text = Color3.fromRGB(240, 240, 250),
	Muted = Color3.fromRGB(142, 144, 170),
	White = Color3.new(1, 1, 1),
}

local DOT = "\u{00B7}" -- small centred dot used as a separator in labels

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local player = Players.LocalPlayer
if #CONFIG.AllowedUserIds > 0 and not table.find(CONFIG.AllowedUserIds, player.UserId) then
	return
end
local playerGui = player:WaitForChild("PlayerGui")

local state = {
	fly = false,
	phase = false,
	speed = math.clamp(math.round(CONFIG.DefaultSpeed), MIN_SPEED, MAX_SPEED),
	open = false,
}

local character, humanoid, rootPart

-- Defined further down; the panel's buttons call them.
local setFly, setPhase, setSpeed, setOpen

--------------------------------------------------------------------------------
-- UI helpers
--------------------------------------------------------------------------------

local function create(className, properties)
	local instance = Instance.new(className)
	if instance:IsA("GuiObject") then
		instance.BorderSizePixel = 0
	end
	for property, value in pairs(properties) do
		if property ~= "Parent" then
			instance[property] = value
		end
	end
	instance.Parent = properties.Parent -- parented last, once it is fully set up
	return instance
end

local function createText(properties)
	properties.BackgroundTransparency = 1
	properties.Font = properties.Font or Enum.Font.Gotham
	return create("TextLabel", properties)
end

local function corner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(parent, transparency, thickness)
	return create("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = THEME.White,
		Thickness = thickness or 1,
		Transparency = transparency,
		Parent = parent,
	})
end

local function accentGradient(parent, rotation)
	return create("UIGradient", {
		Color = ColorSequence.new(CONFIG.AccentA, CONFIG.AccentB),
		Rotation = rotation or 0,
		Parent = parent,
	})
end

local function tween(instance, duration, goal, style, direction)
	local info = TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local animation = TweenService:Create(instance, info, goal)
	animation:Play()
	return animation
end

local function textWidth(text, size, font)
	return TextService:GetTextSize(text, size, font, Vector2.new(2000, 100)).X + 2
end

local KEY_NAMES = {
	[Enum.KeyCode.LeftControl] = "Ctrl",
	[Enum.KeyCode.RightControl] = "Ctrl",
	[Enum.KeyCode.LeftShift] = "Shift",
	[Enum.KeyCode.LeftAlt] = "Alt",
	[Enum.KeyCode.RightAlt] = "Alt",
}

local function keyName(keyCode)
	return KEY_NAMES[keyCode] or keyCode.Name
end

-- Reports a press-and-drag that starts on `target`, for both mouse and touch.
local function trackDrag(target, onBegin, onMove, onEnd)
	local active = false

	target.InputBegan:Connect(function(input)
		local isMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		local isTouch = input.UserInputType == Enum.UserInputType.Touch
		if active or not (isMouse or isTouch) then
			return
		end
		active = true
		onBegin(input.Position)

		local moved, ended
		local function finish()
			active = false
			moved:Disconnect()
			ended:Disconnect()
			if onEnd then
				onEnd()
			end
		end

		moved = UserInputService.InputChanged:Connect(function(changed)
			if isMouse and changed.UserInputType == Enum.UserInputType.MouseMovement then
				-- The release can be missed if the window loses focus mid-drag.
				if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
					onMove(changed.Position)
				else
					finish()
				end
			elseif changed == input then
				onMove(changed.Position)
			end
		end)
		ended = UserInputService.InputEnded:Connect(function(released)
			if released == input or (isMouse and released.UserInputType == Enum.UserInputType.MouseButton1) then
				finish()
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local WIDTH = 300
local PADDING = 14
local HEADER_HEIGHT = 62
local CARD_HEIGHT = 60
local SPEED_CARD_HEIGHT = 98
local GAP = 10

local previous = playerGui:FindFirstChild("UniversalFun")
if previous and not script:IsDescendantOf(previous) then
	previous:Destroy()
end

local gui = create("ScreenGui", {
	Name = "UniversalFun",
	DisplayOrder = 50,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

-- Invisible holder for the shadow and the panel. Its UIScale drives the open / close pop.
local window = create("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundTransparency = 1,
	Position = UDim2.new(1, -(WIDTH / 2 + 28), 0.5, 0),
	Visible = false,
	Parent = gui,
})
local windowScale = create("UIScale", { Scale = 0, Parent = window })

-- Soft drop shadow built from stacked translucent layers, so no image asset is needed.
for layer = 1, 6 do
	local spread = layer * 4
	local shadow = create("Frame", {
		Name = "Shadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.92,
		Position = UDim2.new(0.5, 0, 0.5, 6),
		Size = UDim2.new(1, spread * 2, 1, spread * 2),
		ZIndex = 0,
		Parent = window,
	})
	corner(shadow, 16 + spread)
end

local panel = create("Frame", {
	Name = "Panel",
	Active = true, -- stops clicks on the panel from reaching the game world
	BackgroundColor3 = THEME.Panel,
	Size = UDim2.fromScale(1, 1),
	Parent = window,
})
corner(panel, 16)
create("UIGradient", {
	Color = ColorSequence.new(THEME.White, Color3.fromRGB(200, 200, 222)),
	Rotation = 90,
	Parent = panel,
})

-- Accent border that slowly rotates around the panel.
local borderGradient = accentGradient(stroke(panel, 0.3, 1.5))
TweenService:Create(
	borderGradient,
	TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1),
	{ Rotation = 360 }
):Play()

-- Header ----------------------------------------------------------------------

local header = create("Frame", {
	Name = "Header",
	Active = true,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
	Parent = panel,
})

local logo = create("Frame", {
	Name = "Logo",
	AnchorPoint = Vector2.new(0, 0.5),
	BackgroundColor3 = THEME.White,
	Position = UDim2.new(0, PADDING, 0.5, 0),
	Size = UDim2.fromOffset(36, 36),
	Parent = header,
})
corner(logo, 10)
accentGradient(logo, 45)
createText({
	Font = Enum.Font.GothamBlack,
	Size = UDim2.fromScale(1, 1),
	Text = "UF",
	TextColor3 = THEME.White,
	TextSize = 14,
	Parent = logo,
})

-- Sized to its text so the gradient runs across the whole title.
local title = createText({
	Name = "Title",
	Font = Enum.Font.GothamBold,
	Position = UDim2.fromOffset(PADDING + 48, 13),
	Size = UDim2.fromOffset(textWidth("Universal Fun", 18, Enum.Font.GothamBold), 20),
	Text = "Universal Fun",
	TextColor3 = THEME.White,
	TextSize = 18,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = header,
})
accentGradient(title)

createText({
	Name = "Subtitle",
	Position = UDim2.fromOffset(PADDING + 48, 36),
	Size = UDim2.new(1, -(PADDING + 48 + 50), 0, 13),
	Text = string.format("Fly %s Phase %s Speed", DOT, DOT),
	TextColor3 = THEME.Muted,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = header,
})

local hideButton = create("TextButton", {
	Name = "Hide",
	AnchorPoint = Vector2.new(1, 0.5),
	AutoButtonColor = false,
	BackgroundColor3 = THEME.White,
	BackgroundTransparency = 0.94,
	Position = UDim2.new(1, -PADDING, 0.5, 0),
	Size = UDim2.fromOffset(28, 28),
	Text = "",
	Parent = header,
})
corner(hideButton, 8)
create("Frame", { -- the "minimise" dash
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = THEME.Text,
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(10, 2),
	Parent = hideButton,
})
hideButton.MouseEnter:Connect(function()
	tween(hideButton, 0.15, { BackgroundTransparency = 0.85 })
end)
hideButton.MouseLeave:Connect(function()
	tween(hideButton, 0.15, { BackgroundTransparency = 0.94 })
end)
hideButton.Activated:Connect(function()
	setOpen(false)
end)

create("Frame", {
	Name = "Divider",
	AnchorPoint = Vector2.new(0.5, 1),
	BackgroundColor3 = THEME.White,
	BackgroundTransparency = 0.92,
	Position = UDim2.new(0.5, 0, 1, 0),
	Size = UDim2.new(1, -PADDING * 2, 0, 1),
	Parent = header,
})

-- Toggle cards ----------------------------------------------------------------

local CARD_ACTIVE = THEME.Card:Lerp(CONFIG.AccentA, 0.14)

-- Builds one on / off card and returns a function that animates it into either look.
local function createToggleCard(options)
	local card = create("TextButton", {
		Name = options.Title .. "Card",
		AutoButtonColor = false,
		BackgroundColor3 = THEME.Card,
		Position = UDim2.fromOffset(PADDING, options.Y),
		Size = UDim2.new(1, -PADDING * 2, 0, CARD_HEIGHT),
		Text = "",
		Parent = panel,
	})
	corner(card, 12)
	local outline = stroke(card, 0.93)

	-- Keycap showing the hotkey; it lights up while the feature is on.
	local keycap = create("Frame", {
		Name = "Keycap",
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = THEME.Inset,
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(36, 36),
		Parent = card,
	})
	corner(keycap, 9)
	local keycapGlow = create("Frame", {
		Name = "Glow",
		BackgroundColor3 = THEME.White,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = keycap,
	})
	corner(keycapGlow, 9)
	accentGradient(keycapGlow, 45)
	local keyText = keyName(options.Key)
	local keycapLabel = createText({
		Name = "Key",
		Font = Enum.Font.GothamBold,
		Size = UDim2.fromScale(1, 1),
		Text = keyText,
		TextColor3 = THEME.Muted,
		TextSize = #keyText > 1 and 9 or 15,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = keycap,
	})

	createText({
		Name = "Title",
		Font = Enum.Font.GothamBold,
		Position = UDim2.fromOffset(60, 12),
		Size = UDim2.new(1, -124, 0, 18),
		Text = options.Title,
		TextColor3 = THEME.Text,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	local description = createText({
		Name = "Description",
		Position = UDim2.fromOffset(60, 32),
		Size = UDim2.new(1, -124, 0, 14),
		Text = options.Description,
		TextColor3 = THEME.Muted,
		TextSize = 12,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	local switch = create("Frame", {
		Name = "Switch",
		AnchorPoint = Vector2.new(1, 0.5),
		BackgroundColor3 = THEME.Inset,
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(44, 24),
		Parent = card,
	})
	corner(switch, 12)
	local switchFill = create("Frame", {
		Name = "Fill",
		BackgroundColor3 = THEME.White,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = switch,
	})
	corner(switchFill, 12)
	accentGradient(switchFill)
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = THEME.Muted,
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(18, 18),
		ZIndex = 2,
		Parent = switch,
	})
	corner(knob, 9)

	local enabled, hovered = false, false

	local function refreshBackground()
		local color = enabled and CARD_ACTIVE or THEME.Card
		if hovered then
			color = color:Lerp(THEME.White, 0.05)
		end
		tween(card, 0.15, { BackgroundColor3 = color })
	end

	card.MouseEnter:Connect(function()
		hovered = true
		refreshBackground()
	end)
	card.MouseLeave:Connect(function()
		hovered = false
		refreshBackground()
	end)
	card.Activated:Connect(options.OnClick)

	return function(isEnabled)
		enabled = isEnabled
		refreshBackground()
		description.Text = enabled and options.ActiveDescription or options.Description
		tween(outline, 0.2, {
			Color = enabled and CONFIG.AccentA or THEME.White,
			Transparency = enabled and 0.35 or 0.93,
		})
		tween(keycapGlow, 0.2, { BackgroundTransparency = enabled and 0 or 1 })
		tween(keycapLabel, 0.2, { TextColor3 = enabled and THEME.White or THEME.Muted })
		tween(switchFill, 0.2, { BackgroundTransparency = enabled and 0 or 1 })
		tween(knob, 0.2, {
			BackgroundColor3 = enabled and THEME.White or THEME.Muted,
			Position = enabled and UDim2.new(1, -21, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
		})
	end
end

-- Speed card ------------------------------------------------------------------

-- Builds the slider card and returns a function that shows a given speed on it.
local function createSpeedCard(y)
	local card = create("Frame", {
		Name = "SpeedCard",
		BackgroundColor3 = THEME.Card,
		Position = UDim2.fromOffset(PADDING, y),
		Size = UDim2.new(1, -PADDING * 2, 0, SPEED_CARD_HEIGHT),
		Parent = panel,
	})
	corner(card, 12)
	stroke(card, 0.93)

	createText({
		Name = "Title",
		Font = Enum.Font.GothamBold,
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.new(1, -90, 0, 18),
		Text = "Speed",
		TextColor3 = THEME.Text,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	createText({
		Name = "Description",
		Position = UDim2.fromOffset(14, 32),
		Size = UDim2.new(1, -90, 0, 14),
		Text = "Walking and flying",
		TextColor3 = THEME.Muted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	local readout = create("Frame", {
		Name = "Readout",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundColor3 = THEME.Inset,
		Position = UDim2.new(1, -12, 0, 12),
		Size = UDim2.fromOffset(54, 34),
		Parent = card,
	})
	corner(readout, 10)
	local valueLabel = createText({
		Name = "Value",
		Font = Enum.Font.GothamBold,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		TextColor3 = THEME.White,
		TextSize = 18,
		Parent = readout,
	})
	accentGradient(valueLabel)

	local track = create("Frame", {
		Name = "Track",
		BackgroundColor3 = THEME.Inset,
		Position = UDim2.fromOffset(16, 64),
		Size = UDim2.new(1, -32, 0, 6),
		Parent = card,
	})
	corner(track, 3)
	local fill = create("Frame", {
		Name = "Fill",
		BackgroundColor3 = THEME.White,
		Size = UDim2.fromScale(0, 1),
		Parent = track,
	})
	corner(fill, 3)
	accentGradient(fill)
	local thumb = create("Frame", {
		Name = "Thumb",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = THEME.White,
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		ZIndex = 2,
		Parent = track,
	})
	corner(thumb, 7)
	accentGradient(stroke(thumb, 0, 3), 45)
	local thumbScale = create("UIScale", { Parent = thumb })

	-- Invisible, generously sized grab area so the slider is easy to catch, especially on touch.
	local hitbox = create("TextButton", {
		Name = "Hitbox",
		AnchorPoint = Vector2.new(0.5, 0.5),
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 28, 0, 34),
		Text = "",
		ZIndex = 3,
		Parent = track,
	})

	createText({
		Name = "Min",
		Font = Enum.Font.GothamMedium,
		Position = UDim2.fromOffset(16, 77),
		Size = UDim2.fromOffset(40, 12),
		Text = tostring(MIN_SPEED),
		TextColor3 = THEME.Muted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})
	createText({
		Name = "Max",
		AnchorPoint = Vector2.new(1, 0),
		Font = Enum.Font.GothamMedium,
		Position = UDim2.new(1, -16, 0, 77),
		Size = UDim2.fromOffset(40, 12),
		Text = tostring(MAX_SPEED),
		TextColor3 = THEME.Muted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = card,
	})

	local dragging, hovering = false, false

	local function refreshThumb()
		tween(thumbScale, 0.15, { Scale = (dragging or hovering) and 1.2 or 1 })
	end

	local function pickSpeed(pointer)
		local offset = pointer.X - track.AbsolutePosition.X
		local alpha = math.clamp(offset / math.max(track.AbsoluteSize.X, 1), 0, 1)
		setSpeed(MIN_SPEED + alpha * (MAX_SPEED - MIN_SPEED))
	end

	hitbox.MouseEnter:Connect(function()
		hovering = true
		refreshThumb()
	end)
	hitbox.MouseLeave:Connect(function()
		hovering = false
		refreshThumb()
	end)
	trackDrag(hitbox, function(pointer)
		dragging = true
		refreshThumb()
		pickSpeed(pointer)
	end, pickSpeed, function()
		dragging = false
		refreshThumb()
	end)

	return function(speed, instant)
		local alpha = (speed - MIN_SPEED) / (MAX_SPEED - MIN_SPEED)
		valueLabel.Text = tostring(speed)
		if instant then
			fill.Size = UDim2.fromScale(alpha, 1)
			thumb.Position = UDim2.fromScale(alpha, 0.5)
		else
			tween(fill, 0.1, { Size = UDim2.fromScale(alpha, 1) })
			tween(thumb, 0.1, { Position = UDim2.fromScale(alpha, 0.5) })
		end
	end
end

-- Body layout -----------------------------------------------------------------

local cursorY = HEADER_HEIGHT + 12

local flyHint = "Steer with the camera"
if UserInputService.KeyboardEnabled then
	flyHint = string.format("%s up %s %s down", keyName(CONFIG.AscendKeys[1]), DOT, keyName(CONFIG.DescendKeys[1]))
end

local renderFly = createToggleCard({
	Title = "Fly",
	Description = "Take to the skies",
	ActiveDescription = flyHint,
	Key = CONFIG.FlyKey,
	Y = cursorY,
	OnClick = function()
		setFly(not state.fly)
	end,
})
cursorY += CARD_HEIGHT + GAP

local renderPhase = createToggleCard({
	Title = "Phase",
	Description = "Walk through walls",
	ActiveDescription = "Walls can't stop you",
	Key = CONFIG.PhaseKey,
	Y = cursorY,
	OnClick = function()
		setPhase(not state.phase)
	end,
})
cursorY += CARD_HEIGHT + GAP

local renderSpeed = createSpeedCard(cursorY)
cursorY += SPEED_CARD_HEIGHT + GAP

local footerText = "Tap UF to hide"
if UserInputService.KeyboardEnabled then
	footerText = keyName(CONFIG.PanelKey) .. " hides"
end
createText({
	Name = "Footer",
	Position = UDim2.fromOffset(PADDING, cursorY),
	Size = UDim2.new(1, -PADDING * 2, 0, 14),
	Text = string.format("%s  %s  drag header to move", footerText, DOT),
	TextColor3 = THEME.Muted,
	TextSize = 11,
	TextTransparency = 0.25,
	Parent = panel,
})
cursorY += 14 + 12

local windowHeight = cursorY
window.Size = UDim2.fromOffset(WIDTH, windowHeight)

-- Launcher: the round button that opens and closes the panel -------------------

local launcher = create("TextButton", {
	Name = "Launcher",
	AnchorPoint = Vector2.new(0, 0.5),
	AutoButtonColor = false,
	BackgroundColor3 = THEME.White,
	Position = UDim2.new(0, 14, 0.5, 0),
	Size = UDim2.fromOffset(46, 46),
	Text = "",
	Parent = gui,
})
corner(launcher, 23)
accentGradient(launcher, 45)
stroke(launcher, 0.7, 1.5)
createText({
	Font = Enum.Font.GothamBlack,
	Size = UDim2.fromScale(1, 1),
	Text = "UF",
	TextColor3 = THEME.White,
	TextSize = 15,
	Parent = launcher,
})
local launcherScale = create("UIScale", { Parent = launcher })
launcher.MouseEnter:Connect(function()
	tween(launcherScale, 0.15, { Scale = 1.08 })
end)
launcher.MouseLeave:Connect(function()
	tween(launcherScale, 0.15, { Scale = 1 })
end)
launcher.Activated:Connect(function()
	setOpen(not state.open)
end)

-- Toast: confirms a hotkey press while the panel is hidden ---------------------

local toast = create("Frame", {
	Name = "Toast",
	AnchorPoint = Vector2.new(0.5, 0),
	BackgroundColor3 = THEME.Panel,
	BackgroundTransparency = 1,
	Position = UDim2.new(0.5, 0, 0, 0),
	Size = UDim2.fromOffset(160, 34),
	Visible = false,
	ZIndex = 10,
	Parent = gui,
})
corner(toast, 17)
local toastBorder = stroke(toast, 1, 1.5)
accentGradient(toastBorder)
local toastLabel = createText({
	Font = Enum.Font.GothamMedium,
	Size = UDim2.fromScale(1, 1),
	Text = "",
	TextColor3 = THEME.Text,
	TextSize = 13,
	TextTransparency = 1,
	Parent = toast,
})

local toastId = 0

local function showToast(message)
	toastId += 1
	local id = toastId

	toastLabel.Text = message
	toast.Size = UDim2.fromOffset(textWidth(message, 13, Enum.Font.GothamMedium) + 36, 34)
	toast.Visible = true
	tween(toast, 0.25, { BackgroundTransparency = 0.05, Position = UDim2.new(0.5, 0, 0, 12) })
	tween(toastBorder, 0.25, { Transparency = 0.4 })
	tween(toastLabel, 0.25, { TextTransparency = 0 })

	task.delay(1.6, function()
		if id ~= toastId then
			return -- a newer toast has replaced this one
		end
		tween(toast, 0.3, { BackgroundTransparency = 1, Position = UDim2.new(0.5, 0, 0, 0) })
		tween(toastBorder, 0.3, { Transparency = 1 })
		tween(toastLabel, 0.3, { TextTransparency = 1 }).Completed:Connect(function()
			if id == toastId then
				toast.Visible = false
			end
		end)
	end)
end

-- Opening, closing, dragging and fitting the window ---------------------------

local openScale = 1
local windowMoved = false -- true once the player has dragged the window somewhere

-- Shrinks the window on small screens so it always fits.
local function fitScale()
	local screen = gui.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return 1 -- not laid out yet
	end
	return math.clamp(math.min(screen.X / (WIDTH + 32), screen.Y / (windowHeight + 32)), 0.5, 1)
end

local function windowCenter()
	return window.AbsolutePosition - gui.AbsolutePosition + window.AbsoluteSize / 2
end

local function clampToScreen(center)
	local screen = gui.AbsoluteSize
	local half = window.AbsoluteSize / 2
	return UDim2.fromOffset(
		math.clamp(center.X, half.X, math.max(half.X, screen.X - half.X)),
		math.clamp(center.Y, half.Y, math.max(half.Y, screen.Y - half.Y))
	)
end

function setOpen(open)
	state.open = open
	if open then
		openScale = fitScale()
		window.Visible = true
		tween(windowScale, 0.35, { Scale = openScale }, Enum.EasingStyle.Back)
	else
		local closing = tween(windowScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		closing.Completed:Connect(function(playbackState)
			if playbackState == Enum.PlaybackState.Completed and not state.open then
				window.Visible = false
			end
		end)
	end
end

local dragPointer, dragCenter
trackDrag(header, function(pointer)
	dragPointer, dragCenter = pointer, windowCenter()
end, function(pointer)
	windowMoved = true
	local moved = Vector2.new(pointer.X - dragPointer.X, pointer.Y - dragPointer.Y)
	window.Position = clampToScreen(dragCenter + moved)
end)

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	local scale = fitScale()
	if state.open and scale ~= openScale then
		openScale = scale
		tween(windowScale, 0.15, { Scale = scale })
	end
	if windowMoved then
		-- Wait for the rescale to settle, then pull the window back inside the screen.
		task.delay(0.2, function()
			window.Position = clampToScreen(windowCenter())
		end)
	end
end)

--------------------------------------------------------------------------------
-- Movement: fly
--------------------------------------------------------------------------------

local FLY_TILT = math.rad(18) -- how far the character leans into its movement
local FLY_SMOOTHING = 10 -- higher = snappier starts and stops

local heldKeys = {}
local flyRig -- the constraints carrying the character while flying; nil otherwise

-- Roblox's control module reports keyboard, gamepad and touch movement as one vector.
local controls
task.spawn(function()
	local ok, result = pcall(function()
		local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		return require(playerModule):GetControls()
	end)
	if ok then
		controls = result
	end
end)

local function anyHeld(keys)
	for _, key in ipairs(keys) do
		if heldKeys[key] then
			return true
		end
	end
	return false
end

-- Movement input in camera space: X is right, Z is backwards.
local function getMoveVector()
	if controls then
		return controls:GetMoveVector()
	end
	-- Only reached in games that replace Roblox's control scripts.
	local x = (heldKeys[Enum.KeyCode.D] and 1 or 0) - (heldKeys[Enum.KeyCode.A] and 1 or 0)
	local z = (heldKeys[Enum.KeyCode.S] and 1 or 0) - (heldKeys[Enum.KeyCode.W] and 1 or 0)
	return Vector3.new(x, 0, z)
end

local function startFlying()
	if flyRig or not (humanoid and rootPart) or humanoid.Health <= 0 then
		return
	end

	-- A velocity constraint moves the character and an orientation constraint keeps it upright.
	-- Both respect collisions, so walls still stop you unless Phase is on.
	local attachment = create("Attachment", { Name = "UniversalFunFly", Parent = rootPart })
	local mover = create("LinearVelocity", {
		Attachment0 = attachment,
		MaxForce = math.huge,
		RelativeTo = Enum.ActuatorRelativeTo.World,
		VectorVelocity = rootPart.AssemblyLinearVelocity,
		VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
		Parent = attachment,
	})
	local gyro = create("AlignOrientation", {
		Attachment0 = attachment,
		CFrame = rootPart.CFrame.Rotation,
		MaxTorque = math.huge,
		Mode = Enum.OrientationAlignmentMode.OneAttachment,
		Responsiveness = 30,
		Parent = attachment,
	})

	humanoid.Sit = false
	humanoid.PlatformStand = true -- stops the humanoid's own walking physics fighting the flight
	flyRig = {
		attachment = attachment,
		mover = mover,
		gyro = gyro,
		humanoid = humanoid,
		velocity = rootPart.AssemblyLinearVelocity, -- start from the current motion so there is no jolt
	}
end

local function stopFlying()
	local rig = flyRig
	if not rig then
		return
	end
	flyRig = nil
	rig.attachment:Destroy()
	rig.humanoid.PlatformStand = false
end

local function updateFlight(deltaTime)
	local rig = flyRig
	local camera = workspace.CurrentCamera
	if not (rig and camera) then
		return
	end

	-- Humanoid.Jump is true while jump is held on any device, including the mobile jump button.
	local rise = (rig.humanoid.Jump or anyHeld(CONFIG.AscendKeys)) and 1 or 0
	local sink = anyHeld(CONFIG.DescendKeys) and 1 or 0
	local move = getMoveVector()

	local direction = camera.CFrame:VectorToWorldSpace(move) + Vector3.yAxis * (rise - sink)
	if direction.Magnitude > 1 then
		direction = direction.Unit
	end

	-- Ease towards the target velocity so starts and stops feel smooth.
	rig.velocity = rig.velocity:Lerp(direction * state.speed, 1 - math.exp(-FLY_SMOOTHING * deltaTime))
	rig.mover.VectorVelocity = rig.velocity

	-- Face where the camera faces, leaning into the movement.
	local look = camera.CFrame.LookVector
	local heading = Vector3.new(look.X, 0, look.Z)
	if heading.Magnitude > 0.01 then
		local lean = CFrame.Angles(move.Z * FLY_TILT, 0, -move.X * FLY_TILT)
		rig.gyro.CFrame = CFrame.lookAt(Vector3.zero, heading) * lean
	end

	if not rig.humanoid.PlatformStand then
		rig.humanoid.PlatformStand = true -- something else switched it off mid-flight
	end
end

--------------------------------------------------------------------------------
-- Movement: phase
--------------------------------------------------------------------------------

local characterParts = {} -- cached list of the character's parts
local partsChanged = true -- rebuild the cache before it is next used
local solidParts = {} -- parts made non-solid by Phase, so they can be made solid again

local function updatePhase()
	if not (state.phase and character) then
		return
	end

	if partsChanged then
		partsChanged = false
		table.clear(characterParts)
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(characterParts, descendant)
			end
		end
	end

	-- The humanoid turns collisions back on every frame, so this runs before every physics step.
	for _, part in ipairs(characterParts) do
		if part.CanCollide then
			solidParts[part] = true
			part.CanCollide = false
		end
	end
end

local function restoreCollisions()
	for part in pairs(solidParts) do
		part.CanCollide = true
	end
	table.clear(solidParts)
end

--------------------------------------------------------------------------------
-- Switching features on and off
--------------------------------------------------------------------------------

-- The panel shows the change itself, so the toast is only needed while it is hidden.
local function announce(feature, enabled)
	if not state.open then
		showToast(feature .. (enabled and " enabled" or " disabled"))
	end
end

function setFly(enabled)
	state.fly = enabled
	if enabled then
		startFlying()
	else
		stopFlying()
	end
	renderFly(enabled)
	announce("Fly", enabled)
end

function setPhase(enabled)
	state.phase = enabled
	if not enabled then
		restoreCollisions()
	end
	renderPhase(enabled)
	announce("Phase", enabled)
end

function setSpeed(speed)
	speed = math.clamp(math.round(speed), MIN_SPEED, MAX_SPEED)
	if speed == state.speed then
		return
	end
	state.speed = speed
	renderSpeed(speed)
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- gameProcessed is true while typing in chat or a text box, so hotkeys never fire there.
	if gameProcessed or input.KeyCode == Enum.KeyCode.Unknown then
		return
	end
	heldKeys[input.KeyCode] = true

	if input.KeyCode == CONFIG.FlyKey then
		setFly(not state.fly)
	elseif input.KeyCode == CONFIG.PhaseKey then
		setPhase(not state.phase)
	elseif input.KeyCode == CONFIG.PanelKey then
		setOpen(not state.open)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	heldKeys[input.KeyCode] = nil
end)

-- Key releases are not reported while the window is unfocused, so forget held keys.
UserInputService.WindowFocusReleased:Connect(function()
	table.clear(heldKeys)
end)

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(newCharacter)
	local newHumanoid = newCharacter:WaitForChild("Humanoid", 10)
	local newRoot = newCharacter:WaitForChild("HumanoidRootPart", 10)
	if not (newHumanoid and newRoot) or player.Character ~= newCharacter then
		return
	end

	stopFlying() -- drop anything left over from the previous character
	table.clear(solidParts)
	character, humanoid, rootPart = newCharacter, newHumanoid, newRoot
	partsChanged = true

	humanoid.WalkSpeed = state.speed

	newCharacter.DescendantAdded:Connect(function()
		partsChanged = true
	end)
	newCharacter.DescendantRemoving:Connect(function(descendant)
		partsChanged = true
		-- Something leaving the character (a dropped tool, say) gets its collisions back.
		if solidParts[descendant] then
			solidParts[descendant] = nil
			descendant.CanCollide = true
		end
	end)
	newHumanoid.Died:Connect(function()
		if humanoid == newHumanoid then
			stopFlying() -- let the body fall; flight resumes on respawn if Fly is still on
		end
	end)

	if state.fly then
		startFlying()
	end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

renderSpeed(state.speed, true)
gui.Parent = playerGui

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end

-- PreSimulation runs right before each physics step, which is when both features must apply.
RunService.PreSimulation:Connect(function(deltaTime)
	updatePhase()
	updateFlight(deltaTime)
end)

if CONFIG.StartOpen then
	setOpen(true)
end
