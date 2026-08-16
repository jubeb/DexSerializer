local Main, Serializer, API, Settings, DefaultSettings, env

local service = setmetatable({}, {
	__index = function(self, name)
		local serv = game:GetService(name)
		self[name] = serv
		return serv
	end,
})

DefaultSettings = {
	Serializer = {
		_Recurse = true,
		Decompile = false,
		NilInstances = false,
		RemovePlayerCharacters = true,
		SavePlayers = false,
		DecompileTimeout = 10,
		MaxThreads = 3,
		DecompileIgnore = { "Chat", "CoreGui", "CorePackages" },
		ShowStatus = true,
		IgnoreDefaultProps = true,
		IsolateStarterPlayer = true,
		Binary = true,
		Callback = false,
		Clipboard = false,
		Compression = true,
	},
}

Serializer = (function()
	local Serializer = {}

	local oldIndex
	local getnspval
	local getbspval
	local gethiddenprop
	local getnilinstances
	local encodeBase64
	local lz4compress
	local hashmd5

	local classes, saveProps, testInsts = {}, {}, {}

	local tostring = tostring
	local format = string.format
	local gsub = string.gsub
	local sub = string.sub
	local getChildren = game.GetChildren
	local isa = game.IsA
	local components = CFrame.new(0, 0, 0).GetComponents
	local httpService = service.HttpService
	local urlEncode = httpService.UrlEncode
	local concat = table.concat
	local s_pack = string.pack
	local s_unpack = string.unpack
	local lrotate = bit32.lrotate
	local tableCreate = table.create
	local select = select
	local unpack = unpack
	local split = string.split
	local s_rep = string.rep
	local bufferLib = type(buffer) == "table" and buffer or nil

	local nilSafe = {}
	local gameId

	----------------------------------------------------------------
	-- PROPERTY OVERRIDES / FILTERS
	----------------------------------------------------------------

	local propBypass = {
		["BasePart"] = {
			["Color"] = true,
		},
	}

	local propFilter = {
		["BaseScript"] = {
			["LinkedSource"] = true,
		},

		["Script"] = {
			["Source"] = true,
		},

		["ModuleScript"] = {
			["LinkedSource"] = true,
			["Source"] = true,
		},

		["Players"] = {
			["CharacterAutoLoads"] = true,
		},

		["BillboardGui"] = {
			["PlayerToHideFrom"] = true,
		},

		["Instance"] = {
			["SourceAssetId"] = true,
			["PropertyStatusStudio"] = true,
		},

		["Model"] = {
			["WorldPivotData"] = true,
		},

		["TerrainRegion"] = {
			["ExtentsMax"] = true,
			["ExtentsMin"] = true,
		},

		-- Color3uint8 is kept as a fallback filter for runtimes that
		-- expose the API metadata but cannot actually read the value.
		["BasePart"] = {
			["Color3uint8"] = true,
		},
	}

	local xmlReplacePattern = "['\"<>&\0]"

	local xmlReplace = {
		["'"] = "&apos;",
		['"'] = "&quot;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		["&"] = "&amp;",
		["\0"] = "",
	}

	----------------------------------------------------------------
	-- 2026 VALUE HELPERS
	----------------------------------------------------------------

	local function bufferString(size, writer)
		if not bufferLib then
			return nil
		end

		local b = bufferLib.create(size)

		writer(b)

		return bufferLib.tostring(b)
	end

	local function normalize16ByteHash(hash)
		if type(hash) ~= "string" then
			return nil
		end

		if #hash == 16 then
			return hash
		end

		if #hash == 32 and hash:match("^[0-9a-fA-F]+$") then
			local out = tableCreate(16)

			for i = 1, 32, 2 do
				out[#out + 1] = string.char(tonumber(hash:sub(i, i + 1), 16))
			end

			return concat(out)
		end

		return nil
	end

	local function i64ToString(value)
		if type(value) ~= "number" then
			return "0"
		end

		return format("%.0f", value)
	end

	local function getSecurityCapabilityMask(value)
		-- Matches the current UniversalSynSaveInstance capability layout.
		local bits = {
			Plugin = 2 ^ 0,
			LocalUser = 2 ^ 1,
			WritePlayer = 2 ^ 2,
			RobloxScript = 2 ^ 3,
			RobloxEngine = 2 ^ 4,
			NotAccessible = 2 ^ 5,
			RunClientScript = 2 ^ 8,
			RunServerScript = 2 ^ 9,
			Unknown = 2 ^ 10,
			AccessOutsideWrite = 2 ^ 11,
			Unassigned = 2 ^ 15,
			LoadUnownedAsset = 2 ^ 16,
			LoadString = 2 ^ 17,
			ScriptGlobals = 2 ^ 18,
			CreateInstances = 2 ^ 19,
			Basic = 2 ^ 20,
			Audio = 2 ^ 21,
			DataStore = 2 ^ 22,
			Network = 2 ^ 23,
			Physics = 2 ^ 24,
			UI = 2 ^ 25,
			CSG = 2 ^ 26,
			Chat = 2 ^ 27,
			Animation = 2 ^ 28,
			AvatarAppearance = 2 ^ 29,
			Input = 2 ^ 30,
			Environment = 2 ^ 31,
			RemoteEvent = 2 ^ 32,
			LegacySound = 2 ^ 33,
			Players = 2 ^ 34,
			CapabilityControl = 2 ^ 35,
			AssetRead = 2 ^ 36,
			AssetManagement = 2 ^ 37,
			DynamicGeneration = 2 ^ 38,
			PlatformAvatarEditing = 2 ^ 39,
			AssetCreateUpdate = 2 ^ 40,
			Capture = 2 ^ 41,
			SensitiveInput = 2 ^ 42,
			Monetization = 2 ^ 43,
			LoadOwnedAsset = 2 ^ 44,
			Social = 2 ^ 45,
			ServerCommunication = 2 ^ 46,
			Logging = 2 ^ 47,
			PromptExternalPurchase = 2 ^ 48,
			Groups = 2 ^ 49,
			Teleport = 2 ^ 50,
			Consequences = 2 ^ 51,
			Material = 2 ^ 52,
			AvatarBehavior = 2 ^ 53,
			RemoteCommand = 2 ^ 59,
			InternalTest = 2 ^ 60,
			PluginOrOpenCloud = 2 ^ 61,
			Assistant = 2 ^ 62,
			Restricted = 2 ^ 63,
		}

		local mask = 0

		for flag in tostring(value):gmatch("[^|]+") do
			flag = flag:gsub("^%s+", ""):gsub("%s+$", "")

			local bit = bits[flag]

			if bit then
				mask = mask + bit
			end
		end

		return mask
	end

	local function getHiddenValue(obj, prop)
		if not gethiddenprop then
			return nil
		end

		local ok, value = pcall(gethiddenprop, obj, prop)

		if ok then
			return value
		end

		return nil
	end

	local function readProperty(obj, prop)
		local indexName = prop.IndexName or prop.Name

		if prop.Special == "Func" and prop.Func then
			local ok, value = pcall(prop.Func, obj)

			return ok and value or nil
		end

		local typeName = prop.ValueType and prop.ValueType.Name

		if prop.Special == "Decompile" then
			return nil
		end

		if prop.Special == "BinaryString" then
			if getbspval then
				local ok, value = pcall(getbspval, obj, indexName, false)

				if ok then
					return value
				end
			end

			return getHiddenValue(obj, indexName)
		end

		if
			(prop.Tags and prop.Tags.NotScriptable)
			or typeName == "SharedString"
			or typeName == "Color3uint8"
			or typeName == "Vector3int16"
			or typeName == "SecurityCapabilities"
			or typeName == "Bytecode"
		then
			local value = getHiddenValue(obj, indexName)

			if value ~= nil then
				return value
			end
		end

		if oldIndex then
			local ok, value = pcall(oldIndex, obj, indexName)

			if ok then
				return value
			end
		end

		local ok, value = pcall(function()
			return obj[indexName]
		end)

		return ok and value or nil
	end

	local serviceBlacklist = {
		["CoreGui"] = true,
		["CorePackages"] = true,
	}

	local nilClassParents = {
		["Attachment"] = "Part",
		["Bone"] = "Part",
		["Animator"] = "Humanoid",
		["SurfaceAppearance"] = "MeshPart",
	}

	----------------------------------------------------------------
	-- VALUE CONVERTERS
	----------------------------------------------------------------

	local valueConverters = {
		["bool"] = function(name, val)
			return '\n<bool name="' .. name .. '">' .. (val and "true" or "false") .. "</bool>"
		end,

		["int"] = function(name, val)
			return format('\n<int name="%s">%d</int>', name, val)
		end,

		["int64"] = function(name, val)
			return format('\n<int64 name="%s">%d</int64>', name, val)
		end,

		["float"] = function(name, val)
			return format('\n<float name="%s">%.12f</float>', name, val)
		end,

		["double"] = function(name, val)
			return format('\n<double name="%s">%.12f</double>', name, val)
		end,

		["string"] = function(name, val)
			return '\n<string name="' .. name .. '">' .. gsub(val, xmlReplacePattern, xmlReplace) .. "</string>"
		end,

		["BrickColor"] = function(name, val)
			return format('\n<int name="%s">%d</int>', name, val.Number)
		end,

		["Vector2"] = function(name, val)
			return format('\n<Vector2 name="%s">\n<X>%.12f</X>\n<Y>%.12f</Y>\n</Vector2>', name, val.X, val.Y)
		end,

		["Vector3"] = function(name, val)
			return format(
				'\n<Vector3 name="%s">\n<X>%.12f</X>\n<Y>%.12f</Y>\n<Z>%.12f</Z>\n</Vector3>',
				name,
				val.X,
				val.Y,
				val.Z
			)
		end,

		["Vector3int16"] = function(name, val)
			return format(
				'\n<Vector3int16 name="%s">\n<X>%d</X>\n<Y>%d</Y>\n<Z>%d</Z>\n</Vector3int16>',
				name,
				val.X,
				val.Y,
				val.Z
			)
		end,

		["CFrame"] = function(name, val)
			return format(
				'\n<CoordinateFrame name="%s">\n<X>%.12f</X>\n<Y>%.12f</Y>\n<Z>%.12f</Z>\n<R00>%.12f</R00>\n<R01>%.12f</R01>\n<R02>%.12f</R02>\n<R10>%.12f</R10>\n<R11>%.12f</R11>\n<R12>%.12f</R12>\n<R20>%.12f</R20>\n<R21>%.12f</R21>\n<R22>%.12f</R22>\n</CoordinateFrame>',
				name,
				components(val)
			)
		end,

		["Content"] = function(name, val)
			if type(val) ~= "string" then
				return ""
			end

			if sub(val, 1, 15) == "rbxgameasset://" then
				val = format(
					"https://assetdelivery.roblox.com/v1/asset?universeId=%d&assetName=%s&skipSigningScripts=1",
					gameId,
					urlEncode(httpService, sub(val, 16))
				)
			end

			return '\n<Content name="'
				.. name
				.. '"><url>'
				.. gsub(val, xmlReplacePattern, xmlReplace)
				.. "</url></Content>"
		end,

		["UDim"] = function(name, val)
			return format('\n<UDim name="%s">\n<S>%.12f</S>\n<O>%d</O>\n</UDim>', name, val.Scale, val.Offset)
		end,

		["UDim2"] = function(name, val)
			local x = val.X
			local y = val.Y

			return format(
				'\n<UDim2 name="%s">\n<XS>%.12f</XS>\n<XO>%d</XO>\n<YS>%.12f</YS>\n<YO>%d</YO>\n</UDim2>',
				name,
				x.Scale,
				x.Offset,
				y.Scale,
				y.Offset
			)
		end,

		["Color3"] = function(name, val)
			return format(
				'\n<Color3 name="%s">\n<R>%.12f</R>\n<G>%.12f</G>\n<B>%.12f</B>\n</Color3>',
				name,
				val.R,
				val.G,
				val.B
			)
		end,

		["NumberRange"] = function(name, val)
			return '\n<NumberRange name="' .. name .. '">' .. tostring(val) .. "</NumberRange>"
		end,

		["NumberSequence"] = function(name, val)
			return '\n<NumberSequence name="' .. name .. '">' .. tostring(val) .. "</NumberSequence>"
		end,

		["ColorSequence"] = function(name, val)
			return '\n<ColorSequence name="' .. name .. '">' .. tostring(val) .. "</ColorSequence>"
		end,

		["Rect"] = function(name, val)
			local min, max = val.Min, val.Max

			return format(
				'\n<Rect2D name="%s">\n<min>\n<X>%.12f</X>\n<Y>%.12f</Y>\n</min>\n<max>\n<X>%.12f</X>\n<Y>%.12f</Y>\n</max>\n</Rect2D>',
				name,
				min.X,
				min.Y,
				max.X,
				max.Y
			)
		end,

		["PhysicalProperties"] = function(name, val)
			if val then
				local ok, absorption = pcall(function()
					return val.AcousticAbsorption
				end)

				if not ok or type(absorption) ~= "number" then
					absorption = 1
				end

				return format(
					'\n<PhysicalProperties name="%s">\n<CustomPhysics>true</CustomPhysics>\n<Density>%.12f</Density>\n<Friction>%.12f</Friction>\n<Elasticity>%.12f</Elasticity>\n<FrictionWeight>%.12f</FrictionWeight>\n<ElasticityWeight>%.12f</ElasticityWeight>\n<AcousticAbsorption>%.12f</AcousticAbsorption>\n</PhysicalProperties>',
					name,
					val.Density,
					val.Friction,
					val.Elasticity,
					val.FrictionWeight,
					val.ElasticityWeight,
					absorption
				)
			end

			return '\n<PhysicalProperties name="'
				.. name
				.. '">\n<CustomPhysics>false</CustomPhysics>\n</PhysicalProperties>'
		end,

		["Faces"] = function(name, val)
			local faceInt = (val.Front and 32 or 0)
				+ (val.Bottom and 16 or 0)
				+ (val.Left and 8 or 0)
				+ (val.Back and 4 or 0)
				+ (val.Top and 2 or 0)
				+ (val.Right and 1 or 0)

			return format('\n<Faces name="%s">\n<faces>%d</faces>\n</Faces>', name, faceInt)
		end,

		-- FIXED:
		-- old code accidentally emitted </Faces>
		["Axes"] = function(name, val)
			local axisInt = (val.Z and 4 or 0) + (val.Y and 2 or 0) + (val.X and 1 or 0)

			return format('\n<Axes name="%s">\n<axes>%d</axes>\n</Axes>', name, axisInt)
		end,

		["Ray"] = function(name, val)
			local origin = val.Origin
			local direction = val.Direction

			return format(
				'\n<Ray name="%s">\n<origin>\n<X>%.12f</X>\n<Y>%.12f</Y>\n<Z>%.12f</Z>\n</origin>\n<direction>\n<X>%.12f</X>\n<Y>%.12f</Y>\n<Z>%.12f</Z>\n</direction>\n</Ray>',
				name,
				origin.X,
				origin.Y,
				origin.Z,
				direction.X,
				direction.Y,
				direction.Z
			)
		end,

		["BinaryString"] = function(name, val)
			if type(val) ~= "string" then
				return ""
			end

			local encoded = encodeBase64 and encodeBase64(val) or val

			return '\n<BinaryString name="' .. name .. '">' .. encoded .. "</BinaryString>"
		end,

		["ProtectedString"] = function(name, val)
			if type(val) ~= "string" then
				return ""
			end

			return '\n<ProtectedString name="'
				.. name
				.. '">'
				.. gsub(val, xmlReplacePattern, xmlReplace)
				.. "</ProtectedString>"
		end,

		["SharedString"] = function(name, val)
			return '\n<SharedString name="' .. name .. '">' .. tostring(val or "") .. "</SharedString>"
		end,

		["UniqueId"] = function(name, val)
			local ok, index, timeValue, randomValue = pcall(function()
				return val.Index, val.Time, val.Random
			end)

			if not ok then
				return ""
			end

			local okBytes, bytes = pcall(function()
				return s_pack("<I4I4i8", index, timeValue, randomValue)
			end)

			if not okBytes then
				return ""
			end

			local hex = bytes:gsub(".", function(c)
				return format("%02x", string.byte(c))
			end)

			return format('\\n<UniqueId name="%s">%s</UniqueId>', name, hex)
		end,

		["SecurityCapabilities"] = function(name, val)
			return format(
				'\\n<SecurityCapabilities name="%s">%s</SecurityCapabilities>',
				name,
				i64ToString(getSecurityCapabilityMask(val))
			)
		end,

		["Content"] = function(name, val)
			local sourceType = val and val.SourceType

			if sourceType == Enum.ContentSourceType.None then
				return format('\\n<Content name="%s"><null></null></Content>', name)
			elseif sourceType == Enum.ContentSourceType.Uri then
				local uri = val.Uri or ""
				return format(
					'\\n<Content name="%s"><uri>%s</uri></Content>',
					name,
					gsub(tostring(uri), xmlReplacePattern, xmlReplace)
				)
			end

			return ""
		end,

		["Path2DControlPoint"] = function(name, val)
			if not val then
				return ""
			end

			local p = val.Position
			local l = val.LeftTangent
			local r = val.RightTangent

			return format(
				'\\n<Path2DControlPoint name="%s"><Position><XS>%.12f</XS><XO>%d</XO><YS>%.12f</YS><YO>%d</YO></Position><LeftTangent><XS>%.12f</XS><XO>%d</XO><YS>%.12f</YS><YO>%d</YO></LeftTangent><RightTangent><XS>%.12f</XS><XO>%d</XO><YS>%.12f</YS><YO>%d</YO></RightTangent></Path2DControlPoint>',
				name,
				p.X.Scale,
				p.X.Offset,
				p.Y.Scale,
				p.Y.Offset,
				l.X.Scale,
				l.X.Offset,
				l.Y.Scale,
				l.Y.Offset,
				r.X.Scale,
				r.X.Offset,
				r.Y.Scale,
				r.Y.Offset
			)
		end,

		["TweenInfo"] = function(name, val)
			if not val then
				return ""
			end

			return format(
				'\\n<TweenInfo name="%s"><Time>%.12f</Time><DelayTime>%.12f</DelayTime><RepeatCount>%d</RepeatCount><EasingStyle>%d</EasingStyle><EasingDirection>%d</EasingDirection><Reverses>%s</Reverses></TweenInfo>',
				name,
				val.Time,
				val.DelayTime,
				val.RepeatCount,
				val.EasingStyle.Value,
				val.EasingDirection.Value,
				val.Reverses and "true" or "false"
			)
		end,

		["Color3uint8"] = function(name, val)
			if not val then
				return ""
			end

			local ok, r, g, b = pcall(function()
				return val.R, val.G, val.B
			end)

			if not ok then
				return ""
			end

			return format(
				'\n<Color3uint8 name="%s">\n<R>%d</R>\n<G>%d</G>\n<B>%d</B>\n</Color3uint8>',
				name,
				math.clamp(math.floor(r + 0.5), 0, 255),
				math.clamp(math.floor(g + 0.5), 0, 255),
				math.clamp(math.floor(b + 0.5), 0, 255)
			)
		end,
	}

	----------------------------------------------------------------
	-- BINARY TYPE IDS
	----------------------------------------------------------------

	local binaryDataTypes = {
		["string"] = "\1",
		["ContentId"] = "\1",
		["BinaryString"] = "\1",
		["bool"] = "\2",
		["int"] = "\3",
		["float"] = "\4",
		["double"] = "\5",
		["UDim"] = "\6",
		["UDim2"] = "\7",
		["Ray"] = "\8",
		["Faces"] = "\9",
		["Axes"] = "\10",
		["BrickColor"] = "\11",
		["Color3"] = "\12",
		["Vector2"] = "\13",
		["Vector3"] = "\14",
		["CFrame"] = "\16",
		["Enum"] = "\18",
		["Referent"] = "\19",
		["Vector3int16"] = "\20",
		["NumberSequence"] = "\21",
		["ColorSequence"] = "\22",
		["NumberRange"] = "\23",
		["Rect"] = "\24",
		["PhysicalProperties"] = "\25",
		["Color3uint8"] = "\26",
		["int64"] = "\27",
		["SharedString"] = "\28",
		["NetAssetRef"] = "\28",
		["Bytecode"] = "\29",
		["OptionalCoordinateFrame"] = "\30",
		["UniqueId"] = "\31",
		["Font"] = "\32",
		["SecurityCapabilities"] = "\33",
		["Content"] = "\34",
	}

	local binaryCFrameMap = {
		["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63"] = "\2",
		["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0"] = "\3",
		["\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191"] = "\5",
		["\0\0\128\63\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\63\0\0\0\0\0\0\128\191\0\0\0\0"] = "\6",
		["\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191"] = "\7",
		["\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\63"] = "\9",
		["\0\0\0\0\0\0\128\191\0\0\0\0\0\0\128\63\0\0\0\0\0\0\0\128\0\0\0\0\0\0\0\0\0\0\128\63"] = "\10",
		["\0\0\0\0\0\0\128\191\0\0\128\63\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\128\191\0\0\0\0"] = "\12",
	}

	----------------------------------------------------------------
	-- BINARY PROPERTY HANDLERS
	----------------------------------------------------------------

	local binaryPropHandlers = {
		["string"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				if type(val) ~= "string" then
					val = ""
				end

				result[i] = s_pack("<I4", #val) .. val
			end

			return concat(result)
		end,

		["ContentId"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				if type(val) ~= "string" then
					val = ""
				end

				result[i] = s_pack("<I4", #val) .. val
			end

			return concat(result)
		end,

		["BinaryString"] = function(objs, name, func)
			if not getbspval then
				return
			end

			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val = getbspval(objs[i], name)

				if type(val) ~= "string" then
					val = ""
				end

				result[i] = s_pack("<I4", #val) .. val
			end

			return concat(result)
		end,

		["bool"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				result[i] = val and "\1" or "\0"
			end

			return concat(result)
		end,

		["int"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(4 * szObjs)
			local sep = szObjs - 1

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local bytes = s_pack(">I4", val < 0 and 2 * -val - 1 or 2 * val)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end,

		["float"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(4 * szObjs)
			local sep = szObjs - 1

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local bytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val)), 1))

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end,

		["double"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				result[i] = s_pack("<d", val)
			end

			return concat(result)
		end,

		["UDim"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(8 * szObjs)
			local sep = szObjs - 1
			local firstArrayEnd = 4 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local scaleBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.Scale)), 1))

				local offset = val.Offset

				local offsetBytes = s_pack(">I4", offset < 0 and 2 * -offset - 1 or 2 * offset)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(scaleBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(offsetBytes, b, b)
				end
			end

			return concat(result)
		end,

		["UDim2"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(16 * szObjs)
			local sep = szObjs - 1

			local firstArrayEnd = 4 * szObjs
			local secondArrayEnd = 8 * szObjs
			local thirdArrayEnd = 12 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local x = val.X
				local y = val.Y

				local xScaleBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", x.Scale)), 1))

				local xOffsetBytes = s_pack(">I4", x.Offset < 0 and 2 * -x.Offset - 1 or 2 * x.Offset)

				local yScaleBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", y.Scale)), 1))

				local yOffsetBytes = s_pack(">I4", y.Offset < 0 and 2 * -y.Offset - 1 or 2 * y.Offset)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(xScaleBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yScaleBytes, b, b)

					result[secondArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(xOffsetBytes, b, b)

					result[thirdArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yOffsetBytes, b, b)
				end
			end

			return concat(result)
		end,

		["Ray"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local origin = val.Origin
				local direction = val.Direction

				result[i] = s_pack("<ffffff", origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z)
			end

			return concat(result)
		end,

		["Faces"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local faceInt = (val.Front and 32 or 0)
					+ (val.Bottom and 16 or 0)
					+ (val.Left and 8 or 0)
					+ (val.Back and 4 or 0)
					+ (val.Top and 2 or 0)
					+ (val.Right and 1 or 0)

				result[i] = s_pack("b", faceInt)
			end

			return concat(result)
		end,

		["Axes"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local axisInt = (val.Z and 4 or 0) + (val.Y and 2 or 0) + (val.X and 1 or 0)

				result[i] = s_pack("b", axisInt)
			end

			return concat(result)
		end,

		["BrickColor"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(4 * szObjs)
			local sep = szObjs - 1

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local bytes = s_pack(">I4", val.Number)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end,

		["Color3"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(12 * szObjs)
			local sep = szObjs - 1

			local firstArrayEnd = 4 * szObjs
			local secondArrayEnd = 8 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local rBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.R)), 1))

				local gBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.G)), 1))

				local bBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.B)), 1))

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(rBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(gBytes, b, b)

					result[secondArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(bBytes, b, b)
				end
			end

			return concat(result)
		end,

		["Vector2"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(8 * szObjs)
			local sep = szObjs - 1
			local firstArrayEnd = 4 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local xBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.X)), 1))

				local yBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.Y)), 1))

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(xBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yBytes, b, b)
				end
			end

			return concat(result)
		end,

		["Vector3"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(12 * szObjs)
			local sep = szObjs - 1

			local firstArrayEnd = 4 * szObjs
			local secondArrayEnd = 8 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local xBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.X)), 1))

				local yBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.Y)), 1))

				local zBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", val.Z)), 1))

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(xBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yBytes, b, b)

					result[secondArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(zBytes, b, b)
				end
			end

			return concat(result)
		end,

		["CFrame"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(szObjs + 12 * szObjs)

			local sep = szObjs - 1
			local posStart = szObjs
			local firstArrayEnd = posStart + 4 * szObjs
			local secondArrayEnd = posStart + 8 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local componentStr = s_pack("<fffffffff", select(4, components(val)))

				result[i] = binaryCFrameMap[componentStr] or "\0" .. componentStr

				local pos = val.Position

				local xBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.X)), 1))

				local yBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.Y)), 1))

				local zBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.Z)), 1))

				for b = 1, 4 do
					result[posStart + (i - 1) + b + sep * (b - 1)] = sub(xBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yBytes, b, b)

					result[secondArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(zBytes, b, b)
				end
			end

			return concat(result)
		end,

		["Enum"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(4 * szObjs)
			local sep = szObjs - 1

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local bytes = s_pack(">I4", val.Value)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end,

		["Vector3int16"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				result[i] = s_pack("<i2i2i2", val.X, val.Y, val.Z)
			end

			return concat(result)
		end,

		["NumberSequence"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local numKeypoints = #val.Keypoints

				result[i] = s_pack("<I4" .. s_rep("fff", numKeypoints), numKeypoints, unpack(split(tostring(val), " ")))
			end

			return concat(result)
		end,

		["ColorSequence"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local numKeypoints = #val.Keypoints

				result[i] =
					s_pack("<I4" .. s_rep("fffff", numKeypoints), numKeypoints, unpack(split(tostring(val), " ")))
			end

			return concat(result)
		end,

		["NumberRange"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				result[i] = s_pack("<ff", val.Min, val.Max)
			end

			return concat(result)
		end,

		["Rect"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(16 * szObjs)
			local sep = szObjs - 1

			local firstArrayEnd = 4 * szObjs
			local secondArrayEnd = 8 * szObjs
			local thirdArrayEnd = 12 * szObjs

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local min = val.Min
				local max = val.Max

				local xMinBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", min.X)), 1))

				local yMinBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", min.Y)), 1))

				local xMaxBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", max.X)), 1))

				local yMaxBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", max.Y)), 1))

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(xMinBytes, b, b)

					result[firstArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yMinBytes, b, b)

					result[secondArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(xMaxBytes, b, b)

					result[thirdArrayEnd + (i - 1) + b + sep * (b - 1)] = sub(yMaxBytes, b, b)
				end
			end

			return concat(result)
		end,

		["PhysicalProperties"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				if val then
					local ok, absorption = pcall(function()
						return val.AcousticAbsorption
					end)

					if not ok or type(absorption) ~= "number" then
						absorption = 1
						result[i] = "\1"
							.. s_pack(
								"<fffff",
								val.Density,
								val.Friction,
								val.Elasticity,
								val.FrictionWeight,
								val.ElasticityWeight
							)
					else
						result[i] = "\3"
							.. s_pack(
								"<ffffff",
								val.Density,
								val.Friction,
								val.Elasticity,
								val.FrictionWeight,
								val.ElasticityWeight,
								absorption
							)
					end
				else
					result[i] = "\0"
				end
			end

			return concat(result)
		end,

		-- FIX:
		-- Validate Color3uint8 instead of assuming that gethiddenproperty
		-- returns exactly the old executor's expected representation.
		["Color3uint8"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				else
					val = getHiddenValue(objs[i], name)

					if val == nil and oldIndex then
						val = oldIndex(objs[i], name)
					end
				end

				if not val then
					return nil
				end

				local ok, r, g, b = pcall(function()
					return val.R, val.G, val.B
				end)

				if not ok then
					return nil
				end

				-- gethiddenproperty() exposes Color3uint8 as integer channels on
				-- runtimes that implement the hidden data type. Be permissive and
				-- also accept normal Color3-style 0..1 channels.
				local scale = (r <= 1 and g <= 1 and b <= 1) and 255 or 1

				result[i] = "\1"
					.. s_pack(
						"<BBB",
						math.clamp(math.floor(r * scale + 0.5), 0, 255),
						math.clamp(math.floor(g * scale + 0.5), 0, 255),
						math.clamp(math.floor(b * scale + 0.5), 0, 255)
					)
			end

			return concat(result)
		end,

		["int64"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(8 * szObjs)
			local sep = szObjs - 1

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local bytes = s_pack(">I8", val < 0 and 2 * -val - 1 or 2 * val)

				for b = 1, 8 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end,

		["OptionalCoordinateFrame"] = function(objs, name, func)
			local szObjs = #objs
			local result = tableCreate(1 + szObjs + 12 * szObjs + 1 + szObjs)

			local sep = szObjs - 1
			local posStart = szObjs
			local firstArrayEnd = posStart + 4 * szObjs
			local secondArrayEnd = posStart + 8 * szObjs
			local thirdArrayEnd = posStart + 12 * szObjs
			local startOffset = 1

			result[1] = "\16"
			result[startOffset + thirdArrayEnd + 1] = "\2"

			for i = 1, szObjs do
				local xStart = startOffset + posStart + i - 1

				local yStart = startOffset + firstArrayEnd + i - 1

				local zStart = startOffset + secondArrayEnd + i - 1

				local boolPos = startOffset + thirdArrayEnd + i + 1

				local val, exists

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				if not val then
					exists = false
					val = CFrame.new()
				else
					exists = true
				end

				local componentStr = s_pack("<fffffffff", select(4, components(val)))

				result[startOffset + i] = binaryCFrameMap[componentStr] or "\0" .. componentStr

				local pos = val.Position

				local xBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.X)), 1))

				local yBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.Y)), 1))

				local zBytes = s_pack(">I4", lrotate(s_unpack(">I4", s_pack(">f", pos.Z)), 1))

				for b = 1, 4 do
					result[xStart + b + sep * (b - 1)] = sub(xBytes, b, b)

					result[yStart + b + sep * (b - 1)] = sub(yBytes, b, b)

					result[zStart + b + sep * (b - 1)] = sub(zBytes, b, b)
				end

				result[boolPos] = exists and "\1" or "\0"
			end

			return concat(result)
		end,

		["Font"] = function(objs, name, func)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				if not val then
					result[i] = s_pack("<I2I1I4", 0, 0, 0)
				else
					local family = tostring(val.Family or "")
					local weightOk, weight = pcall(function()
						return val.Weight.Value
					end)
					local styleOk, style = pcall(function()
						return val.Style.Value
					end)

					local familyBytes = s_pack("<I4", #family) .. family
					local cached = s_pack("<I4", 0)

					result[i] = s_pack("<I2I1", weightOk and weight or 0, styleOk and style or 0)
						.. familyBytes
						.. cached
				end
			end

			return concat(result)
		end,
	}

	----------------------------------------------------------------
	-- SPECIAL PROPERTIES
	----------------------------------------------------------------

	local specialProps = {
		["Script"] = {
			{
				Name = "Source",
				ValueType = {
					Name = "ProtectedString",
					Category = "DataType",
				},
				Special = "Decompile",
			},
		},

		["ModuleScript"] = {
			{
				Name = "Source",
				ValueType = {
					Name = "ProtectedString",
					Category = "DataType",
				},
				Special = "Decompile",
			},
		},

		["TerrainRegion"] = {
			{
				Name = "ExtentsMin",
				ValueType = {
					Name = "Vector3int16",
					Category = "DataType",
				},
				Special = "Func",
				Func = function()
					return workspace.Terrain.MaxExtents.Min
				end,
			},

			{
				Name = "ExtentsMax",
				ValueType = {
					Name = "Vector3int16",
					Category = "DataType",
				},
				Special = "Func",
				Func = function()
					return workspace.Terrain.MaxExtents.Max
				end,
			},
		},

		["Model"] = {
			{
				Name = "WorldPivotData",
				ValueType = {
					Name = "OptionalCoordinateFrame",
					Category = "DataType",
				},
				IndexName = "WorldPivot",
			},
		},
	}

	----------------------------------------------------------------
	-- SAVE PROPERTY DISCOVERY
	----------------------------------------------------------------

	local function shouldSkipColor3uint8(obj, prop)
		if not prop.ValueType or prop.ValueType.Name ~= "Color3uint8" then
			return false
		end

		if not gethiddenprop then
			return true
		end

		local ok, value = pcall(gethiddenprop, obj, prop.Name)

		if not ok or value == nil then
			return true
		end

		local channelOk = pcall(function()
			local _r = value.R
			local _g = value.G
			local _b = value.B
		end)

		return not channelOk
	end

	local function getSaveProps(obj, class)
		local result = {}
		local count = 1

		local curClass = API.Classes[class]

		while curClass do
			local curClassName = curClass.Name
			local cacheProps = saveProps[curClassName]

			if cacheProps then
				table.move(cacheProps, 1, #cacheProps, #result + 1, result)

				break
			end

			local props = curClass.Properties

			for i = 1, #props do
				local prop = props[i]
				local propName = prop.Name

				if shouldSkipColor3uint8(obj, prop) then
					continue
				end

				if
					(prop.Serialization and prop.Serialization.CanSave)
					or (propBypass[curClassName] and propBypass[curClassName][propName])
				then
					if not propFilter[curClassName] or not propFilter[curClassName][propName] then
						if prop.Tags and prop.Tags.NotScriptable then
							-- IMPORTANT:
							-- Potassium gethiddenproperty() can legitimately
							-- return nil, so success is what matters here.
							local success = pcall(getnspval, obj, propName)

							if success then
								result[count] = prop
								count = count + 1
							end
						else
							local success = pcall(function()
								return obj[propName]
							end)

							if success then
								result[count] = prop
								count = count + 1
							end
						end
					end
				end
			end

			local extraProps = specialProps[curClassName]

			if extraProps then
				table.move(extraProps, 1, #extraProps, #result + 1, result)

				count = #result + 1
			end

			curClass = curClass.Superclass
		end

		table.sort(result, function(a, b)
			return a.Name < b.Name
		end)

		return result
	end

	local function getTestInst(class)
		local success, inst = pcall(Instance.new, class)

		if not success then
			return {}
		end

		local defaultProps = {}
		local props = saveProps[class] or {}

		for i = 1, #props do
			local prop = props[i]

			if not prop.Special and not (prop.Tags and prop.Tags.NotScriptable) then
				local propName = prop.IndexName or prop.Name

				local readSuccess, value = pcall(function()
					return inst[propName]
				end)

				if readSuccess then
					defaultProps[propName] = value
				end
			end
		end

		return defaultProps
	end

	----------------------------------------------------------------
	-- DECOMPILATION
	----------------------------------------------------------------

	local function getDecompiler()
		local globalEnv

		if type(getgenv) == "function" then
			local success, value = pcall(getgenv)

			if success and type(value) == "table" then
				globalEnv = value
			end
		end

		globalEnv = globalEnv or _G

		local decompiler = rawget(globalEnv, "decompile")

		if type(decompiler) ~= "function" then
			return nil
		end

		return decompiler
	end

	local function doDecompile(scr)
		local decompiler = getDecompiler()

		if not decompiler then
			return nil, "Potassium does not expose a compatible decompile API"
		end

		local success, source = pcall(decompiler, scr)

		if success and type(source) == "string" then
			return source
		end

		return nil, tostring(source)
	end

	----------------------------------------------------------------
	-- STATUS
	----------------------------------------------------------------

	local function createStatusText()
		if not Drawing or type(Drawing.new) ~= "function" then
			return nil
		end

		local statusText = Drawing.new("Text")

		statusText.Color = Color3.new(1, 1, 1)

		statusText.Outline = true

		statusText.OutlineColor = Color3.new(0, 0, 0)

		statusText.Size = 20
		statusText.Visible = true
		statusText.Center = false

		local function updateStatus(text)
			local camera = workspace.CurrentCamera

			if not camera then
				return
			end

			local viewport = camera.ViewportSize

			statusText.Text = text or ""

			statusText.Position = Vector2.new(viewport.X / 2 - statusText.TextBounds.X / 2, 50)
		end

		local function removeStatus()
			pcall(function()
				statusText:Destroy()
			end)
		end

		return {
			Update = updateStatus,
			Remove = removeStatus,
		}
	end

	----------------------------------------------------------------
	-- PRE-DECOMPILE
	----------------------------------------------------------------

	local function predecompile(root, statusText, saveSettings)
		if not saveSettings.Decompile then
			return {}
		end

		local scripts = {}
		local sources = {}
		local checked = {}

		local ignoredServices
		local scriptCount = 1
		local totalScripts

		if root == game and saveSettings.DecompileIgnore then
			ignoredServices = {}

			for i, v in pairs(saveSettings.DecompileIgnore) do
				ignoredServices[i] = game:GetService(v)
			end
		end

		local isTable = type(root) == "table"

		local objs = isTable and root or { root }

		local maxThreads = saveSettings.MaxThreads or 3

		for i = 1, #objs do
			local nextRoot = objs[i]
			local descs = nextRoot:GetDescendants()

			descs[0] = nextRoot

			for d = 0, #descs do
				local obj = descs[d]

				if (isa(obj, "LocalScript") or isa(obj, "ModuleScript")) and not checked[obj] then
					local ignored = false

					if ignoredServices then
						for j = 1, #ignoredServices do
							if obj:IsDescendantOf(ignoredServices[j]) then
								ignored = true
								break
							end
						end
					end

					if not ignored then
						scripts[scriptCount] = obj

						scriptCount = scriptCount + 1
					end

					checked[obj] = true
				end
			end
		end

		totalScripts = scriptCount - 1

		if totalScripts == 0 then
			return sources
		end

		local left = totalScripts

		for _ = 1, maxThreads do
			task.spawn(function()
				while #scripts > 0 do
					local nextScript = table.remove(scripts)

					local source, err = doDecompile(nextScript)

					if source then
						sources[nextScript] = source
					else
						sources[nextScript] = "-- This script could not be decompiled because:\n-- " .. (err or "N/A")
					end

					left = left - 1

					if statusText then
						statusText.Update(
							"Decompiling scripts... (" .. (totalScripts - left) .. "/" .. totalScripts .. ")"
						)
					end
				end
			end)
		end

		while left > 0 do
			task.wait()
		end

		return sources
	end

	----------------------------------------------------------------
	-- BINARY SERIALIZER
	----------------------------------------------------------------

	local function maybeCompress(data, enabled)
		if not enabled or not lz4compress or type(data) ~= "string" or #data < 64 then
			return 0, data
		end

		local ok, compressed = pcall(lz4compress, data)

		if ok and type(compressed) == "string" and #compressed > 0 and #compressed < #data then
			return #compressed, compressed
		end

		return 0, data
	end

	local function serializeBinary(root, filename, saveSettings)
		local header = {
			"\60\114\111\98\108\111\120\33\137\255\13\10\26\10\0\0",
			"",
			"",
			"\0\0\0\0\0\0\0\0",
		}

		local metaBuf = {
			"\77\69\84\65\36\0\0\0\34\0\0\0\0\0\0\0\240\19\1\0\0\0\18\0\0\0\69\120\112\108\105\99\105\116\65\117\116\111\74\111\105\110\116\115\4\0\0\0\116\114\117\101",
		}

		local sstrBuf = {}
		local instBuf, instBufCount = {}, 1
		local propBuf, propBufCount = {}, 1
		local prntBuf = {}

		local endBuf = {
			"\69\78\68\0\0\0\0\0\9\0\0\0\0\0\0\0\60\47\114\111\98\108\111\120\62",
		}

		local instTypeCount = 0
		local instCount = 0
		local refCount = 0
		local sharedStringCount = 0

		local isGame = root == game

		local isTable = type(root) == "table"

		local startB = tick()

		local classList = {}
		local hashs = {}
		local sharedStrings = {}
		local filter = {}
		local refs = {}
		local parents = {}
		local orderedInstList = {}

		local nilBlacklist = {
			[game] = true,
		}

		local folderClasses = {
			["Player"] = true,
			["PlayerScripts"] = true,
			["PlayerGui"] = true,
			["ScriptDebugger"] = true,
			["Breakpoints"] = true,
			["DebuggerWatch"] = true,
		}

		local savingDefaultProps = not saveSettings.IgnoreDefaultProps

		local decompileEnabled = saveSettings.Decompile

		if isTable and not root[1] then
			error("Empty Table")
		end

		if isGame then
			for _, v in pairs(service.Players:GetPlayers()) do
				if not saveSettings.SavePlayers then
					filter[v] = true
				end

				if saveSettings.RemovePlayerCharacters and v.Character then
					filter[v.Character] = true
				end
			end
		end

		if saveSettings.IsolateStarterPlayer then
			folderClasses["StarterPlayer"] = true
			folderClasses["StarterCharacterScripts"] = true
			folderClasses["StarterPlayerScripts"] = true
		end

		if not filename then
			filename = isGame and ("Place_" .. game.PlaceId)
				or ("Place_" .. game.PlaceId .. "_Inst_" .. (isTable and root[1] or root):GetDebugId())
		end

		if isGame then
			filename = filename:match("%.rbxlx?$") and filename or filename .. ".rbxl"
		else
			filename = filename:match("%.rbxmx?$") and filename or filename .. ".rbxm"
		end

		if not saveSettings.Clipboard and not saveSettings.Callback then
			env.writefile(filename, "")
		end

		local statusText = saveSettings.ShowStatus and createStatusText()

		local sources = predecompile(root, statusText, saveSettings)

		local function recur(obj)
			if filter[obj] then
				return
			end

			local class = oldIndex and oldIndex(obj, "ClassName") or obj.ClassName

			if folderClasses[class] then
				class = "Folder"

				if not saveProps["Folder"] then
					saveProps["Folder"] = getSaveProps(Instance.new("Folder"), "Folder")
				end
			end

			if not saveProps[class] then
				saveProps[class] = getSaveProps(obj, class)
			end

			if not testInsts[class] then
				testInsts[class] = (not savingDefaultProps and getTestInst(class)) or {}
			end

			local ch = getChildren(obj)

			for i = 1, #ch do
				local chObj = ch[i]

				parents[chObj] = obj

				recur(chObj)
			end

			if not refs[obj] then
				instCount = instCount + 1

				orderedInstList[instCount] = obj

				local cList = classList[class]

				if not cList then
					cList = {}
					classList[class] = cList

					instTypeCount = instTypeCount + 1
				end

				cList[#cList + 1] = obj

				refs[obj] = refCount

				refCount = refCount + 1
			end
		end

		if isGame then
			local gameCh = getChildren(root)

			for i = 1, #gameCh do
				local obj = gameCh[i]

				if not serviceBlacklist[obj.ClassName] then
					recur(obj)
				end
			end

			local message = [==[--[[
	Thank you for using Dex SaveInstance.

	This file was generated with the following settings:

]==]

			for i, v in next, saveSettings do
				if type(v) == "table" then
					local strings = {}

					for _, k in next, v do
						strings[#strings + 1] = type(k) == "string" and ('"' .. tostring(k) .. '"') or tostring(k)
					end

					message = message .. "\t" .. tostring(i) .. " = { " .. table.concat(strings, ", ") .. " }\n"
				elseif i ~= "_Recurse" then
					message = message .. "\t" .. tostring(i) .. " = " .. tostring(v) .. "\n"
				end
			end

			message = message .. "]]"

			local readmeScript = Instance.new("Script")

			readmeScript.Name = "README"

			nilBlacklist[readmeScript] = true

			sources[readmeScript] = message

			recur(readmeScript)
		elseif isTable then
			for i = 1, #root do
				recur(root[i])
			end
		else
			recur(root)
		end

		if saveSettings.NilInstances and root == game and getnilinstances then
			local nilFolder = Instance.new("Folder")

			nilFolder.Name = "Nil Instances"

			nilBlacklist[nilFolder] = true

			recur(nilFolder)

			for _, obj in ipairs(getnilinstances()) do
				local class = oldIndex and oldIndex(obj, "ClassName") or obj.ClassName

				local classData = API.Classes[class]

				if
					classData
					and not classData.Tags.Service
					and not classData.Tags.NotCreatable
					and not nilBlacklist[obj]
				then
					local parentClass = nilClassParents[class]

					if parentClass then
						local parentObj = Instance.new(parentClass)

						parentObj.Name = class .. " Class"

						recur(parentObj)
						parents[parentObj] = nilFolder

						recur(obj)
						parents[obj] = parentObj
					else
						local isNilSafe = nilSafe[class]

						if isNilSafe == nil then
							isNilSafe = true

							local folder = Instance.new("Folder")

							local success, inst = pcall(Instance.new, class)

							if success then
								if not pcall(function()
									inst.Parent = folder
								end) then
									isNilSafe = false
								end

								pcall(function()
									inst:Destroy()
								end)
							else
								isNilSafe = false
							end

							nilSafe[class] = isNilSafe
						end

						if isNilSafe then
							recur(obj)
							parents[obj] = nilFolder
						end
					end
				end
			end
		end

		local refPropHandler = function(objs, name, func)
			local szObjs = #objs

			local result = tableCreate(4 * szObjs)

			local sep = szObjs - 1

			local lastRef

			for i = 1, szObjs do
				local val

				if func then
					val = func(objs[i], name)
				elseif oldIndex then
					val = oldIndex(objs[i], name)
				else
					val = objs[i][name]
				end

				local ref = refs[val] or -1

				local accRef = lastRef and (ref - lastRef) or ref

				lastRef = ref

				local transformed = accRef < 0 and (2 * -accRef - 1) or (2 * accRef)

				local bytes = s_pack(">I4", transformed)

				for b = 1, 4 do
					result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			return concat(result)
		end

		local sharedStringHandler = function(objs, name)
			if not gethiddenprop and not getbspval then
				return
			end

			if sharedStringCount == 0 then
				sharedStringCount = 1

				sharedStrings[1] = {
					string.rep("\0", 16),
					"",
				}
			end

			local szObjs = #objs

			local result = tableCreate(4 * szObjs, "\0")

			local sep = szObjs - 1

			for i = 1, szObjs do
				local content = getHiddenValue(objs[i], name)

				if type(content) == "string" and #content > 0 then
					local cacheKey = content
					local index = hashs[cacheKey]

					if not index then
						local digest = normalize16ByteHash(hashmd5 and hashmd5(content))
						local hash = digest

						if not hash then
							-- The file format needs a stable 16-byte key. If the
							-- executor doesn't expose MD5, fall back to a unique
							-- binary key rather than writing the old bogus index
							-- encoded as a hash.
							hash = s_pack("<I4I4I4I4", sharedStringCount, #content, 0x53485354, 0x2026)
						end

						index = sharedStringCount + 1

						hashs[cacheKey] = index
						sharedStringCount = index

						sharedStrings[sharedStringCount] = {
							hash,
							content,
						}
					end

					local bytes = s_pack(">I4", index)

					for b = 1, 4 do
						result[(i - 1) + b + sep * (b - 1)] = sub(bytes, b, b)
					end
				end
			end

			return concat(result)
		end

		local protectedStringHandler = function(objs)
			local result = tableCreate(#objs)

			for i = 1, #objs do
				local val

				if sources[objs[i]] then
					val = sources[objs[i]]
				elseif not decompileEnabled then
					val = "-- Decompiling is disabled"
				else
					val = "-- Script failed to decompile or ignored"
				end

				result[i] = s_pack("<I4", #val) .. val
			end

			return concat(result)
		end

		local typeId = 0

		for class, objs in next, classList do
			local instHeader = {
				"INST",
				"\0\0\0\0",
				"",
				"\0\0\0\0",
			}

			local instChunkData = tableCreate(4 + 4 * #objs, "")

			local typeIdBytes = s_pack("<I4", typeId)

			local isService = API.Classes[class] and API.Classes[class].Tags.Service

			instChunkData[1] = typeIdBytes

			instChunkData[2] = s_pack("<I4", #class) .. class

			instChunkData[3] = isService and "\1" or "\0"

			instChunkData[4] = s_pack("<I4", #objs)

			local lastRef
			local sep = #objs - 1

			for i = 1, #objs do
				local obj = objs[i]

				local ref = refs[obj]

				local accRef = lastRef and (ref - lastRef) or ref

				lastRef = ref

				local transformed = accRef < 0 and (2 * -accRef - 1) or (2 * accRef)

				local bytes = s_pack(">I4", transformed)

				local start = 4 + (i - 1)

				for b = 1, 4 do
					instChunkData[start + b + sep * (b - 1)] = sub(bytes, b, b)
				end
			end

			if isService then
				instChunkData[#instChunkData + 1] = s_rep("\1", #objs)
			end

			instChunkData = concat(instChunkData)

			instHeader[3] = s_pack("<I4", #instChunkData)

			local compressedLength, compressedData = maybeCompress(instChunkData, saveSettings.Compression)

			instHeader[2] = s_pack("<I4", compressedLength)
			instChunkData = compressedData

			instBuf[instBufCount] = concat(instHeader)

			instBuf[instBufCount + 1] = instChunkData

			instBufCount = instBufCount + 2

			local props = saveProps[class]

			for propInd = 1, #props do
				local prop = props[propInd]

				local propTypeForFile = prop.ValueType and prop.ValueType.Name
				if propTypeForFile == "UniqueId" and not isGame then
					continue
				end

				local propName = prop.Name

				local indexName = prop.IndexName or propName

				local typeData = prop.ValueType

				local propTypeCategory = typeData.Category

				local propType = typeData.Name

				local propHeader = {
					"PROP",
					"\0\0\0\0",
					"",
					"\0\0\0\0",
				}

				local propChunkData = {
					typeIdBytes,
					s_pack("<I4", #propName) .. propName,
					nil,
					"",
				}

				local handler

				if propTypeCategory == "Primitive" or propTypeCategory == "DataType" then
					handler = binaryPropHandlers[propType]

					propChunkData[3] = binaryDataTypes[propType]

					if propType == "SharedString" or propType == "NetAssetRef" then
						handler = sharedStringHandler
						propChunkData[3] = binaryDataTypes.SharedString
					elseif propType == "ProtectedString" then
						handler = protectedStringHandler
						propChunkData[3] = binaryDataTypes.string
					elseif propType == "Content" then
						handler = binaryPropHandlers.Content
						propChunkData[3] = binaryDataTypes.Content
					elseif propType == "SecurityCapabilities" then
						handler = binaryPropHandlers.SecurityCapabilities
						propChunkData[3] = binaryDataTypes.SecurityCapabilities
					elseif propType == "UniqueId" then
						handler = binaryPropHandlers.UniqueId
						propChunkData[3] = binaryDataTypes.UniqueId
					elseif propType == "Bytecode" then
						handler = binaryPropHandlers.Bytecode
						propChunkData[3] = binaryDataTypes.Bytecode
					end
				elseif propTypeCategory == "Enum" then
					handler = binaryPropHandlers.Enum

					propChunkData[3] = binaryDataTypes.Enum
				else
					handler = refPropHandler

					propChunkData[3] = binaryDataTypes.Referent
				end

				if handler then
					local func
					local special = prop.Special

					if
						(prop.Tags and prop.Tags.NotScriptable)
						or propType == "SharedString"
						or propType == "Color3uint8"
						or propType == "Vector3int16"
						or propType == "SecurityCapabilities"
						or propType == "Bytecode"
					then
						if gethiddenprop then
							func = function(obj, propName)
								return getHiddenValue(obj, propName)
							end
						elseif prop.Tags and prop.Tags.NotScriptable then
							continue
						end
					end

					if special then
						if special == "NotScriptable" then
							if gethiddenprop then
								func = function(obj, propName)
									return getHiddenValue(obj, propName)
								end
							elseif getnspval then
								func = getnspval
							else
								continue
							end
						elseif special == "Func" then
							func = prop.Func
						end
					end

					local propData = handler(objs, indexName, func)

					if not propData then
						continue
					end

					propChunkData[4] = propData

					propChunkData = concat(propChunkData)

					propHeader[3] = s_pack("<I4", #propChunkData)

					local compressedLength, compressedData = maybeCompress(propChunkData, saveSettings.Compression)

					propHeader[2] = s_pack("<I4", compressedLength)
					propChunkData = compressedData

					propBuf[propBufCount] = concat(propHeader)

					propBuf[propBufCount + 1] = propChunkData

					propBufCount = propBufCount + 2
				end
			end

			typeId = typeId + 1
		end

		if sharedStringCount > 0 then
			local sstrHeader = {
				"SSTR",
				"\0\0\0\0",
				"",
				"\0\0\0\0",
			}

			local sstrChunkData = {
				"\0\0\0\0",
				s_pack("<I4", sharedStringCount),
			}

			local count = 3

			for i = 1, #sharedStrings do
				local data = sharedStrings[i]

				local hash, content = data[1], data[2]

				sstrChunkData[count] = hash .. s_pack("<I4", #content) .. content

				count = count + 1
			end

			sstrChunkData = concat(sstrChunkData)

			sstrHeader[3] = s_pack("<I4", #sstrChunkData)

			local compressedLength, compressedData = maybeCompress(sstrChunkData, saveSettings.Compression)

			sstrHeader[2] = s_pack("<I4", compressedLength)
			sstrChunkData = compressedData

			sstrBuf[1] = concat(sstrHeader)

			sstrBuf[2] = sstrChunkData
		end

		local prntHeader = {
			"PRNT",
			"\0\0\0\0",
			"",
			"\0\0\0\0",
		}

		local prntChunkData = tableCreate(2 + 8 * instCount)

		prntChunkData[1] = "\0"

		prntChunkData[2] = s_pack("<I4", instCount)

		local lastObjRef
		local lastParRef

		local sep = instCount - 1

		local prntRefCount = 1

		local lastObjIndex = 2 + 4 * instCount

		for i = 1, instCount do
			local obj = orderedInstList[i]

			local ref = refs[obj]

			local objStart = 2 + (prntRefCount - 1)

			local parStart = lastObjIndex + (prntRefCount - 1)

			local par = parents[obj]

			local parRef = refs[par] or -1

			local accObjRef = lastObjRef and (ref - lastObjRef) or ref

			lastObjRef = ref

			local accParRef = lastParRef and (parRef - lastParRef) or parRef

			lastParRef = parRef

			local objTransformed = accObjRef < 0 and (2 * -accObjRef - 1) or (2 * accObjRef)

			local parTransformed = accParRef < 0 and (2 * -accParRef - 1) or (2 * accParRef)

			local objBytes = s_pack(">I4", objTransformed)

			local parBytes = s_pack(">I4", parTransformed)

			for b = 1, 4 do
				prntChunkData[objStart + b + sep * (b - 1)] = sub(objBytes, b, b)

				prntChunkData[parStart + b + sep * (b - 1)] = sub(parBytes, b, b)
			end

			prntRefCount = prntRefCount + 1
		end

		prntChunkData = concat(prntChunkData)

		prntHeader[3] = s_pack("<I4", #prntChunkData)

		local compressedLength, compressedData = maybeCompress(prntChunkData, saveSettings.Compression)

		prntHeader[2] = s_pack("<I4", compressedLength)
		prntChunkData = compressedData

		prntBuf[1] = concat(prntHeader)

		prntBuf[2] = prntChunkData

		header[2] = s_pack("<i4", instTypeCount)

		header[3] = s_pack("<i4", instCount)

		local totalData = concat({
			concat(header),
			concat(metaBuf),
			concat(sstrBuf),
			concat(instBuf),
			concat(propBuf),
			concat(prntBuf),
			concat(endBuf),
		})

		if saveSettings.Clipboard then
			if env.setrbxclipboard and type(env.setrbxclipboard) == "function" then
				local ok = pcall(env.setrbxclipboard, totalData)

				if not ok then
					warn("Potassium: setrbxclipboard failed")
				end
			else
				warn("Potassium: setrbxclipboard unavailable")
			end
		elseif saveSettings.Callback and type(saveSettings.Callback) == "function" then
			task.spawn(saveSettings.Callback, totalData)
		else
			env.appendfile(filename, concat(header), true)

			env.appendfile(filename, concat(metaBuf), true)

			env.appendfile(filename, concat(sstrBuf), true)

			env.appendfile(filename, concat(instBuf), true)

			env.appendfile(filename, concat(propBuf), true)

			env.appendfile(filename, concat(prntBuf), true)

			env.appendfile(filename, concat(endBuf), true)

			if statusText then
				statusText.Update("Saved to the file " .. filename .. " in " .. (tick() - startB) .. " secs")

				task.delay(5, statusText.Remove)
			end
		end
	end

	----------------------------------------------------------------
	-- XML SERIALIZER
	----------------------------------------------------------------

	local function serializeXML(root, filename, saveSettings)
		local isGame = root == game

		local isTable = type(root) == "table"

		if isTable and not root[1] then
			error("Empty Table")
		end

		if not filename then
			filename = isGame and ("Place_" .. game.PlaceId)
				or ("Place_" .. game.PlaceId .. "_Inst_" .. (isTable and root[1] or root):GetDebugId())
		end

		if isGame then
			filename = filename:match("%.rbxlx?$") and filename or filename .. ".rbxlx"
		else
			filename = filename:match("%.rbxmx?$") and filename or filename .. ".rbxmx"
		end

		env.writefile(filename, "")

		local startB = tick()

		local folderClasses = {
			["Player"] = true,
			["PlayerScripts"] = true,
			["PlayerGui"] = true,
			["ScriptDebugger"] = true,
			["Breakpoints"] = true,
			["DebuggerWatch"] = true,
		}

		local refs = {}
		local refCount = 1
		local filter = {}
		local xmlSharedStrings = {}
		local xmlSharedStringKeys = {}

		local savingDefaultProps = not saveSettings.IgnoreDefaultProps

		local decompileEnabled = saveSettings.Decompile

		local statusText = saveSettings.ShowStatus and createStatusText()

		local sources = predecompile(root, statusText, saveSettings)

		local function registerXmlSharedString(content)
			if type(content) ~= "string" or content == "" then
				return ""
			end

			local existing = xmlSharedStringKeys[content]
			if existing then
				return existing
			end

			local digest = normalize16ByteHash(hashmd5 and hashmd5(content))

			if not digest then
				digest = s_pack("<I4I4I4I4", #xmlSharedStrings + 1, #content, 0x53535452, 0x2026)
			end

			local key = encodeBase64 and encodeBase64(digest) or digest

			xmlSharedStringKeys[content] = key
			xmlSharedStrings[key] = content

			return key
		end

		if isGame then
			for _, v in pairs(service.Players:GetPlayers()) do
				if not saveSettings.SavePlayers then
					filter[v] = true
				end

				if saveSettings.RemovePlayerCharacters and v.Character then
					filter[v.Character] = true
				end
			end
		end

		if saveSettings.IsolateStarterPlayer then
			folderClasses["StarterPlayer"] = true

			folderClasses["StarterCharacterScripts"] = true

			folderClasses["StarterPlayerScripts"] = true
		end

		local buffer = {
			'<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n<Meta name="ExplicitAutoJoints">true</Meta>\n<External>null</External>\n<External>nil</External>',
		}

		local bufferCount = 2

		local function recur(obj)
			if filter[obj] then
				return
			end

			local class = oldIndex and oldIndex(obj, "ClassName") or obj.ClassName

			if folderClasses[class] then
				class = "Folder"

				if not saveProps["Folder"] then
					saveProps["Folder"] = getSaveProps(Instance.new("Folder"), "Folder")
				end
			end

			local ref = refs[obj]

			if not ref then
				ref = refCount

				refs[obj] = ref

				refCount = refCount + 1
			end

			local props = saveProps[class]

			if not props then
				props = getSaveProps(obj, class)

				saveProps[class] = props
			end

			local testInst = testInsts[class]

			if not testInst then
				testInst = (not savingDefaultProps and getTestInst(class)) or {}

				testInsts[class] = testInst
			end

			buffer[bufferCount] = format('\n<Item class="%s" referent="RBX%d">\n<Properties>', class, ref)

			bufferCount = bufferCount + 1

			for i = 1, #props do
				local prop = props[i]

				local propTypeForFile = prop.ValueType and prop.ValueType.Name
				if propTypeForFile == "UniqueId" and not isGame then
					continue
				end

				local propName = prop.Name

				local indexName = prop.IndexName or propName

				local propVal
				local special = prop.Special

				------------------------------------------------
				-- FIX:
				-- Full API hidden properties go through
				-- Potassium gethiddenproperty().
				------------------------------------------------

				if special == "Decompile" then
					if sources[obj] then
						propVal = sources[obj]
					elseif not decompileEnabled then
						propVal = "-- Decompiling is disabled"
					else
						propVal = "-- Script failed to decompile or ignored"
					end
				elseif special == "Func" then
					propVal = prop.Func(obj)
				else
					propVal = readProperty(obj, prop)

					if propVal == nil and special == "NotScriptable" and getnspval then
						local ok, value = pcall(getnspval, obj, indexName)

						if ok then
							propVal = value
						end
					end
				end

				local saveProp = testInst[indexName] ~= propVal

				if savingDefaultProps and propVal ~= nil then
					saveProp = true
				end

				if saveProp then
					local typeData = prop.ValueType

					local propType = typeData.Name

					local convertFunc = valueConverters[propType]

					if propType == "SharedString" and type(propVal) == "string" then
						local key = registerXmlSharedString(propVal)
						buffer[bufferCount] = format('\n<SharedString name="%s">%s</SharedString>', propName, key)
					elseif propType == "Content" and propVal ~= nil then
						local sourceType = propVal.SourceType

						if sourceType == Enum.ContentSourceType.None then
							buffer[bufferCount] = format('\n<Content name="%s"><null></null></Content>', propName)
						elseif sourceType == Enum.ContentSourceType.Uri then
							buffer[bufferCount] = format(
								'\n<Content name="%s"><uri>%s</uri></Content>',
								propName,
								gsub(tostring(propVal.Uri or ""), xmlReplacePattern, xmlReplace)
							)
						elseif sourceType == Enum.ContentSourceType.Object and propVal.Object then
							local refValue = refs[propVal.Object]

							if not refValue then
								refValue = refCount
								refs[propVal.Object] = refValue
								refCount = refCount + 1
							end

							buffer[bufferCount] =
								format('\n<Content name="%s"><Ref>RBX%d</Ref></Content>', propName, refValue)
						else
							buffer[bufferCount] = ""
						end
					elseif convertFunc and propVal ~= nil then
						buffer[bufferCount] = convertFunc(propName, propVal)
					elseif typeData.Category == "Enum" and propVal then
						buffer[bufferCount] = format('\n<token name="%s">%d</token>', propName, propVal.Value)
					elseif classes[propType] and propVal then
						local refValue = refs[propVal]

						if not refValue then
							refValue = refCount

							refs[propVal] = refValue

							refCount = refCount + 1
						end

						buffer[bufferCount] = format('\n<Ref name="%s">RBX%d</Ref>', propName, refValue)
					else
						buffer[bufferCount] = ""
					end

					bufferCount = bufferCount + 1
				end
			end

			buffer[bufferCount] = "\n</Properties>"

			bufferCount = bufferCount + 1

			if bufferCount > 10000 then
				env.appendfile(filename, table.concat(buffer))

				table.clear(buffer)

				bufferCount = 1
			end

			local ch = getChildren(obj)

			for i = 1, #ch do
				recur(ch[i])
			end

			buffer[bufferCount] = "\n</Item>"

			bufferCount = bufferCount + 1
		end

		if isGame then
			local gameCh = getChildren(root)

			for i = 1, #gameCh do
				local obj = gameCh[i]

				if not serviceBlacklist[obj.ClassName] then
					recur(obj)
				end
			end

			buffer[bufferCount] = [==[

<Item class="Script" referent="RBX999999999">
<Properties>
<string name="Name">README</string>
<ProtectedString name="Source">This file was generated by the Potassium-compatible Dex SaveInstance serializer.</ProtectedString>
</Properties>
</Item>]==]

			bufferCount = bufferCount + 1
		elseif isTable then
			for i = 1, #root do
				recur(root[i])
			end
		else
			recur(root)
		end

		------------------------------------------------------------
		-- NIL INSTANCES
		------------------------------------------------------------

		if saveSettings.NilInstances and root == game and getnilinstances then
			local folderRef = refCount

			refCount = refCount + 1

			buffer[bufferCount] = '\n<Item class="Folder" referent="RBX'
				.. folderRef
				.. '">\n<Properties>\n<string name="Name">Nil Instances</string>\n</Properties>'

			bufferCount = bufferCount + 1

			for _, obj in ipairs(getnilinstances()) do
				local class = oldIndex and oldIndex(obj, "ClassName") or obj.ClassName

				local classInfo = API.Classes[class]

				if classInfo and not classInfo.Tags.Service and not classInfo.Tags.NotCreatable and obj ~= game then
					local parentClass = nilClassParents[class]

					if parentClass then
						local parentRef = refCount

						refCount = refCount + 1

						buffer[bufferCount] = format(
							'\n<Item class="%s" referent="RBX%d">\n<Properties>\n<string name="Name">%s Class</string>\n</Properties>',
							parentClass,
							parentRef,
							class
						)

						bufferCount = bufferCount + 1

						recur(obj)

						buffer[bufferCount] = "\n</Item>"

						bufferCount = bufferCount + 1
					else
						local isNilSafe = nilSafe[class]

						if isNilSafe == nil then
							isNilSafe = true

							local folder = Instance.new("Folder")

							local success, inst = pcall(Instance.new, class)

							if success and not pcall(function()
								inst.Parent = folder
							end) then
								isNilSafe = false
							end

							nilSafe[class] = isNilSafe
						end

						if isNilSafe then
							recur(obj)
						end
					end
				end
			end

			buffer[bufferCount] = "\n</Item>"

			bufferCount = bufferCount + 1
		end

		------------------------------------------------------------
		-- SHARED STRINGS
		------------------------------------------------------------

		buffer[bufferCount] = "\n<SharedStrings>"

		bufferCount = bufferCount + 1

		for key, content in next, xmlSharedStrings do
			local encodedContent = encodeBase64 and encodeBase64(content) or content

			buffer[bufferCount] = format('\n<SharedString md5="%s">%s</SharedString>', key, encodedContent)

			bufferCount = bufferCount + 1
		end

		buffer[bufferCount] = "\n</SharedStrings>\n</roblox>"

		env.appendfile(filename, table.concat(buffer))

		table.clear(buffer)

		if statusText then
			statusText.Update("Saved to the file " .. filename .. " in " .. (tick() - startB) .. " secs")

			task.delay(5, statusText.Remove)
		end
	end

	----------------------------------------------------------------
	-- PUBLIC API
	----------------------------------------------------------------

	Serializer.SaveInstance = function(root, filename, opts)
		if not gameId then
			gameId = game.GameId
		end

		local saveSettings = {}

		for set, val in pairs(Settings.Serializer) do
			if opts and opts[set] ~= nil then
				saveSettings[set] = opts[set]
			else
				saveSettings[set] = val
			end
		end

		if saveSettings.DecompileMode and saveSettings.DecompileMode > 0 then
			saveSettings.Decompile = true
		end

		if saveSettings.Binary then
			return serializeBinary(root, filename, saveSettings)
		end

		return serializeXML(root, filename, saveSettings)
	end

	Serializer.Init = function(oldInd)
		oldIndex = oldInd

		gethiddenprop = env.gethiddenprop

		getnspval = env.getnspval

		getbspval = env.getbspval

		getnilinstances = env.getnilinstances

		encodeBase64 = env.encodeBase64

		lz4compress = env.lz4compress

		hashmd5 = env.hashmd5

		classes = API.Classes
	end

	return Serializer
end)()

----------------------------------------------------------------
-- MAIN
----------------------------------------------------------------

Main = (function()
	local Main = {}

	Main.FetchAPI = function()
		local function buildApi(classesRaw, enumsRaw)
			local classes = {}
			local enums = {}

			for _, class in pairs(classesRaw or {}) do
				local className = class.Name
				if className then
					local newClass = {
						Name = className,
						Superclass = nil,
						Properties = {},
						Functions = {},
						Events = {},
						Callbacks = {},
						Tags = {},
					}

					if class.Tags then
						for _, tag in pairs(class.Tags) do
							newClass.Tags[tag] = true
						end
					end

					for _, member in pairs(class.Members or {}) do
						local newMember = {
							Name = member.Name,
							Class = className,
							Tags = {},
						}

						if member.Tags then
							for _, tag in pairs(member.Tags) do
								newMember.Tags[tag] = true
							end
						end

						local memberType = member.MemberType

						if memberType == "Property" then
							newMember.ValueType = member.ValueType or {}
							newMember.Category = member.Category
							newMember.Serialization = member.Serialization
							table.insert(newClass.Properties, newMember)
						elseif memberType == "Function" then
							newMember.Parameters = {}
							newMember.ReturnType = member.ReturnType and member.ReturnType.Name

							for _, param in pairs(member.Parameters or {}) do
								table.insert(newMember.Parameters, {
									Name = param.Name,
									Type = param.Type and param.Type.Name or tostring(param.Type),
								})
							end

							table.insert(newClass.Functions, newMember)
						elseif memberType == "Event" then
							newMember.Parameters = {}

							for _, param in pairs(member.Parameters or {}) do
								table.insert(newMember.Parameters, {
									Name = param.Name,
									Type = param.Type and param.Type.Name or tostring(param.Type),
								})
							end

							table.insert(newClass.Events, newMember)
						elseif memberType == "Callback" then
							newMember.Parameters = {}
							newMember.ReturnType = member.ReturnType and member.ReturnType.Name

							for _, param in pairs(member.Parameters or {}) do
								table.insert(newMember.Parameters, {
									Name = param.Name,
									Type = param.Type and param.Type.Name or tostring(param.Type),
								})
							end

							table.insert(newClass.Callbacks, newMember)
						end
					end

					newClass._SuperclassName = class.Superclass
					classes[className] = newClass
				end
			end

			for _, class in pairs(classes) do
				if class._SuperclassName then
					class.Superclass = classes[class._SuperclassName]
				end

				class._SuperclassName = nil
			end

			for _, enum in pairs(enumsRaw or {}) do
				if enum.Name then
					local newEnum = {
						Name = enum.Name,
						Items = {},
						Tags = {},
					}

					for _, tag in pairs(enum.Tags or {}) do
						newEnum.Tags[tag] = true
					end

					for _, item in pairs(enum.Items or {}) do
						table.insert(newEnum.Items, {
							Name = item.Name,
							Value = item.Value,
						})
					end

					enums[enum.Name] = newEnum
				end
			end

			local function getMember(className, memberName)
				local class = classes[className]

				if not class then
					return
				end

				local result = {}
				local seen = {}

				while class do
					for _, entry in pairs(class[memberName] or {}) do
						if not seen[entry.Name] then
							seen[entry.Name] = true
							result[#result + 1] = entry
						end
					end

					class = class.Superclass
				end

				table.sort(result, function(a, b)
					return a.Name < b.Name
				end)

				return result
			end

			return {
				Classes = classes,
				Enums = enums,
				GetMember = getMember,
			}
		end

		-- First choice in 2026: ReflectionService. It is engine-native and avoids
		-- transient Full-API dump issues.
		local reflectionOk, reflectionService = pcall(game.GetService, game, "ReflectionService")

		if reflectionOk and reflectionService then
			local ok, reflectedClasses = pcall(function()
				return reflectionService:GetClasses({})
			end)

			if ok and type(reflectedClasses) == "table" and #reflectedClasses > 0 then
				local rawClasses = {}

				for _, reflectedClass in pairs(reflectedClasses) do
					local className = reflectedClass.Name

					if className then
						local rawClass = {
							Name = className,
							Superclass = reflectedClass.Superclass
									and (reflectedClass.Superclass.Name or reflectedClass.Superclass)
								or nil,
							Tags = reflectedClass.Tags,
							Members = {},
						}

						local propOk, reflectedProps = pcall(function()
							return reflectionService:GetPropertiesOfClass(className, {})
						end)

						if propOk then
							for _, reflectedProp in pairs(reflectedProps or {}) do
								local member = {
									Name = reflectedProp.Name,
									MemberType = "Property",
									Category = reflectedProp.Category,
									ValueType = reflectedProp.ValueType,
									Serialization = reflectedProp.Serialization,
									Tags = reflectedProp.Tags,
								}

								table.insert(rawClass.Members, member)
							end
						end

						table.insert(rawClasses, rawClass)
					end
				end

				local built = buildApi(rawClasses, {})

				if next(built.Classes) then
					return built
				end
			end
		end

		local urls = {
			"https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/Full-API-Dump.json",
			"https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/refs/heads/roblox/API-Dump.json",
		}

		local lastError = "No API source succeeded"

		for _, url in ipairs(urls) do
			local okRequest, response = pcall(request, {
				Url = url,
				Method = "GET",
			})

			if okRequest and response then
				local rawAPI = response.Body or response.body or response

				if type(rawAPI) == "string" then
					local success, api = pcall(function()
						return service.HttpService:JSONDecode(rawAPI)
					end)

					if success and api and type(api.Classes) == "table" then
						return buildApi(api.Classes, api.Enums)
					end

					lastError = "API JSON decode failed: " .. url
				else
					lastError = "API HTTP response had no string body: " .. url
				end
			else
				lastError = "request() failed: " .. url
			end
		end

		return nil, lastError
	end

	Main.ResetSettings = function()
		local function recur(t)
			local result = {}

			for set, val in pairs(t) do
				if type(val) == "table" and val._Recurse then
					result[set] = recur(val)
				else
					result[set] = val
				end
			end

			return result
		end

		Settings = recur(DefaultSettings)
	end

	return Main
end)()

----------------------------------------------------------------
-- MODULE RETURN
----------------------------------------------------------------

return {
	Init = function(oldindex)
		local api, err = Main.FetchAPI()

		if not api then
			return nil, "FetchAPI failed (" .. tostring(err) .. ")"
		end

		API = api

		env = {}

		------------------------------------------------------------
		-- Potassium filesystem
		------------------------------------------------------------

		env.writefile = writefile

		env.appendfile = appendfile

		------------------------------------------------------------
		-- Potassium instance APIs
		------------------------------------------------------------

		env.getnilinstances = getnilinstances

		env.gethiddenprop = gethiddenproperty

		-- Compatibility aliases used internally by the Dex serializer.
		env.getnspval = gethiddenproperty

		env.getbspval = function(obj, prop, encode)
			local ok, value = pcall(gethiddenproperty, obj, prop)

			if not ok or value == nil then
				return nil
			end

			if encode and crypt and type(crypt.base64encode) == "function" then
				return crypt.base64encode(value)
			end

			return value
		end

		env.setrbxclipboard = setrbxclipboard

		------------------------------------------------------------
		-- Potassium crypto
		------------------------------------------------------------

		env.encodeBase64 = crypt.base64encode

		env.hashmd5 = function(data)
			return crypt.hash(data, "md5")
		end

		------------------------------------------------------------
		-- Potassium compression
		------------------------------------------------------------

		env.lz4compress = lz4compress

		------------------------------------------------------------
		-- Old executor-specific slot intentionally unused
		------------------------------------------------------------

		env.getpcd = nil

		------------------------------------------------------------
		-- Init
		------------------------------------------------------------

		Main.ResetSettings()

		Serializer.Init(oldindex)

		return true
	end,

	Save = function(object, filename, options)
		return Serializer.SaveInstance(object, filename, options)
	end,
}
