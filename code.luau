--// Services

local replicated = game.ReplicatedStorage
local server_storage = game.ServerStorage

local http = game:GetService("HttpService")
local tween = game:GetService("TweenService")
local run_service = game:GetService("RunService")

--// Directories

local m_rng = require("@game/ReplicatedStorage/Modules/Shared/RNG")
local rng = m_rng.new(DateTime.fromUniversalTime(DateTime.fromUniversalTime():ToUniversalTime().Year - math.random(3, 6)).UnixTimestamp)

local plant_assets = server_storage.PlantAssets

local plants = plant_assets.Plants
local crops = plant_assets.Crops

local seed_data = require(plant_assets.SeedData)

local m_vfx = replicated.Assets.MutationVFX

--// Types

export type mutation = {
	id : string,
	multiplier : number
}

export type crop = {
	point : number,
	size : number,
	variant_id : number,
	growth_progress : number,
	max_progress : number,
	mutations : {mutation}
}

export type plant = {
	id : number,
	variant_id : number,
	size : number,
	growth_progress : number,
	max_progress : number,
	crops : {crop}?,
	cframe : string,
	mutations : {mutation}?,
}

--// load & save

function load_plants(data : {plant}, folder : Folder, plot : Model)
	for _, plant : plant in data do
		local success, output = pcall(function()
			local plant_variants = find_first_child_with_attribute_set_to(plants, "ID", plant.id)
			if not plant_variants then warn("Attempted to load a plant with id", plant.id, "which doesn't exist.") return end

			local plant_name = plant_variants.Name

			local variant = find_first_child_with_attribute_set_to(plant_variants, "ID", plant.variant_id)
			if not variant then
				warn(plant_name, "variant with id:", plant.variant_id, "doesn't exist.")

				local vars = plant_variants:GetChildren()
				variant = vars[math.random(1, #vars)]

				if not variant then
					error(plant_name ..  " has no variants!")
				end
			end

			local data = seed_data[plant_name]
			if not data then error("Seed data with name " .. plant_name .. " does not exist.") return end

			--

			local p_clone = variant:Clone()

			p_clone:SetAttribute("VariantID", variant:GetAttribute("ID"))
			p_clone:SetAttribute("VariantName", variant.Name)
			p_clone:SetAttribute("PlantID", plant.PlantID)

			p_clone:SetAttribute("GrowthProgress", plant.growth_progress)
			p_clone:SetAttribute("GrowthTime", plant.max_progress)

			local cf = stringtocframe(plant.cframe)
			if typeof(cf) ~= "CFrame" then
				p_clone:Destroy()
				warn("Invalid plant CFrame:", plant.cframe)
			end
			p_clone:PivotTo(plot:GetPivot():ToWorldSpace(cf))

			check_visible_phases(p_clone, p_clone.Phases)

			p_clone:SetAttribute("Size", plant.size)
			p_clone:ScaleTo(plant.size)

			p_clone.Name = plant_variants.Name
			p_clone:AddTag("Plant")
			p_clone.Parent = folder
			
			p_clone:SetAttribute("SoilName", find_plant_soil(p_clone))

			if plant.mutations then
				p_clone:SetAttribute("Mutations", http:JSONEncode(plant.mutations))
				apply_mutation_effects(p_clone, plant.mutations)
				
				local connection = p_clone:GetAttributeChangedSignal("Mutations"):Connect(function()
					apply_mutation_effects(p_clone, http:JSONDecode(p_clone:GetAttribute("Mutations")))
				end)

				p_clone.Destroying:Once(function()
					connection:Disconnect()
				end)

				return true --// no need to check if plant has crops
			end

			variant = nil

			if plant.crops then
				local crop_variants = crops[plant_name]
				if not crop_variants then 
					warn("No crop variants for: ", plant_name)
					return 
				end

				local cropfolder:Folder = nil

				if not p_clone:FindFirstChild("Crops") then
					cropfolder = Instance.new("Folder", p_clone)
					cropfolder.Name = "Crops"
				else
					cropfolder = p_clone:FindFirstChild("Crops")
				end

				for _, crop : crop in plant.crops do
					local variant = find_first_child_with_attribute_set_to(crop_variants, "ID", crop.variant_id)

					if not variant then
						warn(plant_name, "crop variant with id:", crop.variant_id, "doesn't exist.")

						local vars = crop_variants:GetChildren()
						variant = vars[math.random(1, #vars)]
					end

					local c_clone = variant:Clone()

					c_clone:SetAttribute("VariantID", variant:GetAttribute("ID"))
					c_clone:SetAttribute("VariantName", variant.Name)

					c_clone:SetAttribute("GrowthProgress", crop.growth_progress)
					c_clone:SetAttribute("GrowthTime", crop.max_progress)

					c_clone:SetAttribute("Size", crop.size)
					c_clone:ScaleTo(crop.size)

					local crop_point:Part = p_clone.CropPoints:FindFirstChild(crop.PosNo)

					c_clone:SetAttribute("Point", crop_point.Name)
					crop_point:SetAttribute("Occupied", true)

					c_clone:SetAttribute("Mutations", http:JSONEncode(crop.mutations))
					apply_mutation_effects(c_clone, crop.mutations)

					place_crop_at_point(c_clone, crop_point.CFrame)
					task.spawn(function()
						if c_clone.Parent and crop_point.Parent then
							local cropPos = c_clone:GetPivot().Position
							local pointPos = cropPos.Position

							if (cropPos - pointPos).Magnitude > 0.01 then
								place_crop_at_point(c_clone, crop_point.CFrame)
							end
						end
					end)

					check_visible_phases(crop, crop.Phases)

					c_clone.Name = plant_name
					c_clone.Parent = cropfolder
				end
			end
			
			return true
		end)
		
		if not success or not output then
			warn("Failed to load plant: ", output)
		end
	end
end

function export_plants(folder : Folder, plot : Model)
	local tbl = {}
	for _, plant : Model in folder:GetChildren() do
		local success, mutations = pcall(function()
			return http:JSONEncode(plant:GetAttribute("Mutations"))
		end)
		if not success then mutations = nil end
		
		local save : plant = {
			id = plant:GetAttribute("PlantID"),
			variant_id = plant:GetAttribute("VariantID"),
			size = plant:GetAttribute("Size"),
			max_progress = plant:GetAttribute("GrowthTime"),
			growth_progress = plant:GetAttribute("GrowthProgress"),
			mutations = mutations,
			cframe = cframetostring(plot:GetPivot():ToObjectSpace(plant:GetPivot()))
		}
		
		if plant:FindFirstChild("Crops") then
			local crops : {crop} = {}
			
			for _, crop : Model in plant.Crops:GetChildren() do
				table.insert(crops, {
					variant_id = plant:GetAttribute("VariantID"),
					size = plant:GetAttribute("Size"),
					max_progress = plant:GetAttribute("GrowthTime"),
					growth_progress = plant:GetAttribute("GrowthProgress"),
					mutations = mutations,
					point = crop:GetAttribute("Point")
				})
			end
			
			save.crops = crops	
		end
		
		table.insert(tbl, save)
 	end
	return tbl
end

function create_plant(name : string, c : CFrame, plot : Model) : boolean
	--// Check variables
	
	if type(name) ~= "string" then error("Argument #1 invalid: name is not string:" .. tostring(name)) end
	if typeof(c) ~= "CFrame" then error("Argument #2 is invalid: c is not a cframe " .. tostring(c)) end
	if not plot or not plot.Parent or plot.Parent ~= workspace.Map.Plots then
		error("Argument #3 is invalid: invalid plot")
	end
	
	local data : seed_data.seed_data  = seed_data[name]
	if not data then error("No seed data for: " .. name) end
	
	local variants = plants:FindFirstChild(name)
	if not variants then error("No variants folder found for: " .. name) end
	if #variants:GetChildren() < 1 then error("No models for plant: " .. name) end
	
	--// Get plant variant
	
	local weight_table = {}
	for _, var in variants:GetChildren() do
		if not var:IsA("Model") then continue end
		
		local w = var:GetAttribute("Weight")
		if type(w) ~= "number" then continue end
		
		table.insert(weight_table, {
			Chance = w,
			Value = var
		})
	end
	if #weight_table < 1 then error("No valid variants for plant: " .. name) end
	
	local model : Model = rng:PickWeighted(weight_table)
	if typeof(model) ~= "Instance" then error("Unable to get a valid plant model for plant name: " .. name) end
	
	local plant = model:Clone()
	
	--// Setup Plant
	
	local growth_time = rng:NextInteger(data.growthTime.Min, data.growthTime.Max)
	local sprout_time = rng:NextInteger(data.sproutTime.Min, data.sproutTime.Max)
	
	plant:SetAttribute("GrowthProgress", 0 - sprout_time)
	plant:SetAttribute("GrowthTime", growth_time)
	
	plant:SetAttribute("PlantID", variants:GetAttribute("ID"))
	plant:SetAttribute("VariantID", model:GetAttribute("ID"))
	plant:SetAttribute("ID", nil)
	
	plant:SetAttribute("SoilName", find_plant_soil(plant))
	
	if not data.crop_data then
		plant:SetAttribute("Mutations", http:JSONEncode({}))
		
		local connection = plant:GetAttributeChangedSignal("Mutations"):Connect(function()
			apply_mutation_effects(plant, http:JSONDecode(plant:GetAttribute("Mutations")))
		end)
		
		plant.Destroying:Once(function()
			connection:Disconnect()
		end)
	else
		plant:AddTag("Tree")
		local crops = Instance.new("Folder", plant)
		crops.Name = "Crops"
	end
	
	check_visible_phases(plant, plant.Phases)
	plant:PivotTo(c)
	
	plant.Name = name
	plant.Parent = plot.Plants
	
	--
	
	local sprout_part = Instance.new("Part")
	sprout_part.Shape = Enum.PartType.Cylinder
	sprout_part.Color = Color3.fromRGB(77,64,54)
	sprout_part.Size = Vector3.new(0,1.359,0)
	sprout_part.CFrame = c
	sprout_part.Parent = workspace.Runtime.Temporary
	
	game.TweenService:Create(sprout_part, TweenInfo.new(0.6, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.148, 1.359, 2)
	}):Play()
	
	grow_plant(plant, plot)
	
	task.spawn(function()
		repeat
			task.wait()
		until plant:GetAttribute("GrowthProgress") > 0 or not (plant and plant.Parent)
		
		if not plant.Parent or not plant then 
			sprout_part:Destroy()
			return 
		end
		
		local tween = game.TweenService:Create(sprout_part, TweenInfo.new(1), {
			Transparency = 1
		})
		
		tween:Play()
		tween.Completed:Wait()
		
		if sprout_part and sprout_part.Parent then sprout_part:Destroy() end
	end)
	
	return true
end


--// Mutations

function apply_mutation_effects(model : Model, mutations : {mutation})
	local mutations_part : Part = model:FindFirstChild("Mutations")
	
	if not mutations_part then
		mutations_part = Instance.new("Part", model)
		local weld = Instance.new("WeldConstraint", mutations_part)
		
		mutations_part.Name = "Mutations"
		mutations_part.Size = Vector3.new(3,3,3)
		mutations_part.Transparency = 1

		mutations_part.CanCollide = false
		mutations_part.CanQuery = false
		mutations_part.AudioCanCollide = false
		mutations_part.CanTouch = false
		
		--// Weld the mutation part to a random part of the model incase if the model is a tool
		local random_part : Part
		for _, idk in model:GetDescendants() do
			if idk:IsA("Part") or idk:IsA("UnionOperation") or idk:IsA("MeshPart") then
				random_part = idk
			end
		end
		
		mutations_part.CFrame = model:GetBoundingBox()
		weld.Part0 = random_part
		weld.Part1 = mutations_part
	end
	
	for _, m : mutation in mutations do
		local effect = m_vfx:FindFirstChild(m.id)
		if not effect then continue end
		
		if mutations_part:FindFirstChild(effect.Name) then continue end
		
		effect:Clone().Parent = mutations_part
	end
	
end

--// Important Functions

function check_visible_phases(plant : Model, phases : Folder)
	if not phases or phases.Parent then return end
	local phase_amount = plant:GetAttribute("GrowthTime") / #phases:GetChildren()
	
	for _, phase in phases:GetChildren() do
		local p_no = tonumber((string.gsub(phase.Name, "%D", "")))
		local i_reached_this_phase = plant:GetAttribute("GrowthProgress") >= (phase_amount * p_no)
		
		if i_reached_this_phase then
			if not plant:GetAttribute("Shown") then
				if not phase:GetAttribute("Shown") then
					phase:SetAttribute("Shown", true)

					for _, part in phase:GetDescendants() do
						if not part:IsA("Part") and not part:IsA("MeshPart") then continue end

						local originalSize = part.Size part.Size = originalSize + Vector3.new(0.5,0.5,0.5)
						game.TweenService:Create(part, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
							Size = originalSize
						}):Play()
					end
				end
			end
			
			for _, part in phase:GetDescendants() do
				if not part:IsA("Part") and not part:IsA("MeshPart") then continue end

				if part:HasTag("DissapearAfter") and plant:GetAttribute("GrowthProgress") >= (phase_amount * p_no + 1) then
					for _, part in phase:GetDescendants() do
						if not part:IsA("Part") and not part:IsA("MeshPart") then continue end

						part.Transparency = 1
						part.CanCollide = false

						if #part:GetChildren() > 0 then
							for _, maybedecal in part:GetChildren() do
								if maybedecal:IsA("Decal") then
									maybedecal.Transparency = 1
								end
							end
						end

					end

				else
					part.Transparency = 0
					part.CanCollide = true

					if #part:GetChildren() > 0 then
						for _, maybedecal in part:GetChildren() do
							if maybedecal:IsA("Decal") then
								maybedecal.Transparency = 0
							end
						end
					end
				end
			end
		else
			if phase:GetAttribute("Hidden") then continue end
			
			phases:SetAttribute("Hidden", true)
			for _, part in phase:GetDescendants() do
				if not part:IsA("Part") and not part:IsA("MeshPart") then continue end
				part.Transparency = 1
				part.CanCollide = false

				if #part:GetChildren() > 0 then
					for _, maybedecal in part:GetChildren() do
						if maybedecal:IsA("Decal") then
							maybedecal.Transparency = 1
						end
					end
				end
			end
 		end
	end
end

function grow_plant(plant : Model, plot : Model)
	local f_soils = plot.Soils
	local soil_name = plant:GetAttribute("SoilName")
	
	local growth_time = plant:GetAttribute("GrowthTime")
	
	local soil = f_soils:FindFirstChild(soil_name)
	if not soil then
		local plant_name = plant.Name
		plant:Destroy()
		error("No soil found for: " .. plant_name)
	end
	
	local next_tick = tick() + 1
	local working = false
	local connection ; connection = run_service.Stepped:Connect(function()
		if working then return end
		working = true
		
		local progress = plant:GetAttribute("GrowthProgress")
		
		if progress >= growth_time then
			connection:Disconnect()
			connection = nil
			
			if plant:HasTag("Tree") then
				
				return
			end
			
			local prox = script.HarvestProx:Clone()
			prox.CFrame = plant:GetBoundingBox()
			prox.Parent = plant
			
			return
		end
		
		if tick() >= next_tick then
			local soil_water_level = soil:GetAttribute("WaterLevel")
			
			local increment = 1 * soil_water_level
			
			plant:SetAttribute("GrowthProgress", progress + increment)
			next_tick = tick() + 1
			
			check_visible_phases(plant, plant.Phases)
		end
		
		working = false
	end)
	
	plant.Destroying:Once(function()
		if connection then
			connection:Disconnect()
		end
	end)
end


--// Other Functions

function cframetostring(cframevalue)
	if typeof(cframevalue) == "CFrame" then
		return "CF:" .. table.concat({cframevalue:GetComponents()}, ",")
	end
	return cframevalue
end

function stringtocframe(stringvalue:string)
	if type(stringvalue) == "string" then
		local values = string.split(stringvalue, ",")
		if values[1]:sub(1,3) == "CF:" then
			values[1] = values[1]:sub(4)
		else
			return stringvalue
		end
		for i = 1, #values do values[i] = tonumber(values[i]) end
		if #values == 12 then
			return CFrame.new(values[1], values[2], values[3], values[4], values[5], values[6], values[7], values[8], values[9], values[10], values[11], values[12])
		end
	end
	return stringvalue
end

function find_first_child_with_attribute_set_to(instance : Folder? | any?, attribute : string, set_to : any)
	for _, child in instance:GetChildren() do
		if child:GetAttribute(attribute) == set_to then
			return child
		end
	end
	
	return nil
end

function find_plant_soil(plant : Model)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {plant, plant.Parent}
	
	local position = plant:GetPivot().Position
	
	local parts = workspace:GetPartBoundsInBox(CFrame.new(position), Vector3.new(0.01,4,0.01), params)
	
	for _, part in parts do
		if part:HasTag("Soil") then
			return part.Name
		end
	end
	
	return nil
end

local function cropGeometryCentre(crop: Model): Vector3?
	local min, max

	for _, part in ipairs(crop:GetDescendants()) do
		if part:IsA("BasePart") then
			local cf, size = part.CFrame, part.Size
			local half = Vector3.new(
				math.abs(cf.RightVector.X) * size.X + math.abs(cf.UpVector.X) * size.Y + math.abs(cf.LookVector.X) * size.Z,
				math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z,
				math.abs(cf.RightVector.Z) * size.X + math.abs(cf.UpVector.Z) * size.Y + math.abs(cf.LookVector.Z) * size.Z) / 2

			local low, high = cf.Position - half, cf.Position + half

			min = min and Vector3.new(math.min(min.X, low.X), math.min(min.Y, low.Y), math.min(min.Z, low.Z)) or low
			max = max and Vector3.new(math.max(max.X, high.X), math.max(max.Y, high.Y), math.max(max.Z, high.Z)) or high
		end
	end

	return min and (min + max) / 2 or nil
end

function place_crop_at_point(crop: Model, pointCFrame: CFrame)
	local scale = crop:GetScale()
	local centre = cropGeometryCentre(crop)

	if not centre or scale <= 0 then
		crop:PivotTo(pointCFrame)

		return
	end

	local scaledOffset = crop:GetPivot():PointToObjectSpace(centre)
	local authoredOffset = scaledOffset / scale

	crop:PivotTo(pointCFrame * CFrame.new(authoredOffset * (1 - scale)))
end


----


return {
	load = load_plants,
	export = export_plants,
	create = create_plant
}
