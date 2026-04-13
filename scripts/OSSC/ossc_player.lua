local core    = require('openmw.core')
local types   = require('openmw.types')
local input   = require('openmw.input')
local anim    = require('openmw.animation')
local self    = require('openmw.self')
local async   = require('openmw.async')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local ui      = require('openmw.ui')
local ambient = require('openmw.ambient')
local storage = require('openmw.storage')
local I       = require('openmw.interfaces')
local debug   = require('openmw.debug')
local nearby  = require('openmw.nearby')

local function debugLog(msg)
    local debugOn = storage.playerSection('SettingsOSSC_General'):get('DebugMode')
    if debugOn then
        print("[OSSC] " .. tostring(msg))
    end
end

-- some spell vfx --
local function get_spell_or_enchanted_item()
    local spell_or_item = types.Actor.getSelectedSpell(omwself);
    if not spell_or_item then
        local item = types.Actor.getSelectedEnchantedItem(omwself)
        if item and item.type then
            local rec = item.type.record(item)
            if rec and rec.enchant then
                spell_or_item = core.magic.enchantments.records[rec.enchant]
            end
        end
    end
    return spell_or_item
end

local isCasting    = false
local hasQueuedLaunch = false
local currentSpell = nil
local pendingLaunches = {}

local OSSC_PowerCooldowns = {}

local function getSpeed(spell)
    local settings = storage.playerSection('SettingsOSSC_Speeds')
    local firstEff = (spell.effects and spell.effects[1])
    if not firstEff then return 1500 end

    local id = firstEff.id:lower()
    local mgefRec = core.magic.effects.records[firstEff.id]
    local school = mgefRec and tostring(mgefRec.school):lower() or ""

    local key = "SpeedDefault"

    -- Effect-ID-based matches (most reliable, covers Destruction sub-types)
    if id:find("fire") then
        key = "SpeedFire"
    elseif id:find("frost") or id:find("cold") then
        key = "SpeedFrost"
    elseif id:find("shock") or id:find("lightn") then
        key = "SpeedShock"
    elseif id:find("poison") then
        key = "SpeedPoison"
    elseif id:find("restor") or id:find("heal") then
        key = "SpeedHeal"
    -- School-string matches (mgefRec.school is always a lowercase string in OpenMW Lua)
    elseif school == "illusion" then
        key = "SpeedIllusion"
    elseif school == "alteration" then
        key = "SpeedAlteration"
    elseif school == "conjuration" then
        key = "SpeedConjuration"
    elseif school == "mysticism" then
        key = "SpeedMysticism"
    elseif school == "restoration" then
        key = "SpeedHeal"
    elseif school == "destruction" then
        key = "SpeedFire"   -- generic destruction fallback
    end

    local spd = settings:get(key)
    return tonumber(spd) or 1500
end



local INCAPACITATED_GROUPS = {
    "knockdown", "knockout", "swimknockout", "swimknockdown", "spellcast",
}

local function getSpellElementType(spell)
    if not spell or not spell.effects then return 'default' end
    for _, eff in ipairs(spell.effects) do
        local mgef = core.magic.effects.records[eff.id]
        if mgef then
            local name = mgef.name:lower()
            if string.find(name, "fire")           then return "fire"   end
            if string.find(name, "frost")          then return "frost"  end
            if string.find(name, "shock")          then return "shock"  end
            if string.find(name, "poison")         then return "poison" end
            if string.find(name, "restore health")
            or string.find(name, "heal")           then return "heal"   end
        end
    end
    return 'default'
end

local function getCastChance(spell, caster)
    -- Scrolls and enchanted items always succeed if you have the charge/item
    if spell.item then return 100 end

    -- Powers always succeed (but handled by UI cooldowns)
    local spellRec = core.magic.spells.records[spell.id]
    if spellRec and spellRec.type == core.magic.SPELL_TYPE.Power then return 100 end

    if not spell.effects or #spell.effects == 0 then return 100 end
    local magicEffectRecord = core.magic.effects.records[spell.effects[1].id]
    local schoolId = magicEffectRecord.school

    local skillVal = 0
    if schoolId then
        local sk = types.NPC.stats.skills[schoolId]
        if sk then skillVal = sk(caster).modified end
    end

    local willpower    = types.Actor.stats.attributes.willpower(caster).modified
    local luck         = types.Actor.stats.attributes.luck(caster).modified
    local cost         = spell.cost or 0
    local fatigue      = types.Actor.stats.dynamic.fatigue(caster)
    local fatigueRatio = 1
    if fatigue.base > 0 then
        fatigueRatio = fatigue.current / fatigue.base
    end

    local chance = (skillVal * 2 + willpower / 5 + luck / 10 - cost) * (0.75 + 0.5 * fatigueRatio)
    if chance < 0   then chance = 0   end
    if chance > 100 then chance = 100 end
    return chance
end

local spellvfx = false

local function add_spell_vfx_one(left)
    local spell = currentSpell
    if not spell or not spell.effects or not spell.effects[1] then return end
    local mgef = core.magic.effects.records[spell.effects[1].id]
    if not mgef then return end

    local texture = "vfx_starglow.tga"
    if mgef.particle and mgef.particle ~= "" then
        texture = mgef.particle
    end

    if texture:find("blank") then
        texture = "vfx_starglow.tga"
    end
    local model = "meshes/magichand/spellvfx.nif"

    local bone = "Bip01 R Hand"
    local vfx_id = "OSSC_SpellVFXRight"

    if left then
        bone = "Bip01 L Hand"
        vfx_id = "OSSC_SpellVFXLeft"
    end

    anim.addVfx(
        self,
        model,
        {
            boneName=bone,
            loop=true,
            vfxId=vfx_id,
            particleTextureOverride=texture
        }
    )
end

local function add_spell_vfx()
    print("OSSC: Camera mode: " .. (camera and camera.getMode() or "nil"))
    -- Removed first person check to allow VFX in first person
    print("OSSC: Adding spell VFX")
    add_spell_vfx_one(true)
    add_spell_vfx_one(false)
    spellvfx = true
end

local function remove_spell_vfx()
    if spellvfx then
        print("OSSC: Removing spell VFX")
        anim.removeVfx(self, "OSSC_SpellVFXRight")
        anim.removeVfx(self, "OSSC_SpellVFXLeft")
        spellvfx = false
    end
end

local function onUpdate(dt)
    if #pendingLaunches > 0 then

        local currentTime = core.getSimulationTime()
        for i = #pendingLaunches, 1, -1 do
            local pl = pendingLaunches[i]
            
            if currentTime >= pl.timeToFire then
                local spell = pl.spell
                if spell then
                    local chance = getCastChance(spell, self)
                    local roll   = math.random(1, 100)
                    local cost   = spell.cost or 0
                    local godMode = debug.isGodMode()
                    
                    if godMode then 
                        cost = 0 
                        chance = 100
                    end
                    
                    local isItem = spell.item ~= nil
                    local canCast = true
                    local effectiveCost = cost

                    if isItem then
                        -- [ENCHANT COST] reduced by Enchant skill
                        local skill = types.Player.stats.skills.enchant(self).modified
                        effectiveCost = math.max(1, math.floor(0.01 * (110 - skill) * cost))

                        -- Handle Item Costs
                        if spell.enchantment and (spell.enchantment.type == 0 or spell.enchantment.type == 2) then
                            if spell.enchantment.type == 2 then -- Cast on Use
                                local data = types.Item.itemData(spell.item)
                                local currentCharge = data and data.enchantmentCharge or (spell.enchantment.charge or 0)
                                if currentCharge < effectiveCost then
                                    ui.showMessage("Item does not have enough charge.")
                                    core.sound.playSound3d("spell failure mysticism", self)
                                    canCast = false
                                end
                            else -- Cast Once (Scroll)
                                if spell.item.count <= 0 then
                                    ui.showMessage("You are out of items.")
                                    canCast = false
                                end
                            end
                        end
                    else
                        -- Handle Magicka Costs
                        local magicka = types.Actor.stats.dynamic.magicka(self)
                        if magicka.current < cost then
                            ui.showMessage("Not enough Magicka.")
                            core.sound.playSound3d("spell failure restoration", self)
                            canCast = false
                        else
                            magicka.current = magicka.current - cost
                        end
                    end

                    if canCast then
                        debugLog("OSSC: Casting " .. spell.id .. " (Chance: " .. chance .. " Roll: " .. roll .. ")")

                        print("OSSC: Casting " .. spell.id .. " (Chance: " .. chance .. " Roll: " .. roll .. ")")

                        if roll <= chance then
                            local pitch = -(camera.getPitch() + camera.getExtraPitch())
                            local yaw   =   camera.getYaw()   + camera.getExtraYaw()
                            local direction, startPos

                            if camera.getMode() == camera.MODE.FirstPerson then
                                local xzLen = math.cos(pitch)
                                direction   = util.vector3(xzLen * math.sin(yaw), xzLen * math.cos(yaw), math.sin(pitch))
                                local forwardDir = util.vector3(direction.x, direction.y, 0):normalize()
                                local rightDir   = util.vector3(forwardDir.y, -forwardDir.x, 0)
                                -- Back to Left Hand (-) and keeping forward depth
                                startPos    = camera.getPosition() + (forwardDir * 20) - util.vector3(0, 0, 10) - (rightDir * 45)
                            else
                                -- Default to Third Person logic
                                local bodyDir    = self.rotation * util.vector3(0, 1, 0)
                                local bodyYaw    = math.atan2(bodyDir.x, bodyDir.y)
                                local xzLen      = math.cos(pitch)
                                direction        = util.vector3(xzLen * math.sin(bodyYaw), xzLen * math.cos(bodyYaw), math.sin(pitch))
                                local forwardDir = util.vector3(direction.x, direction.y, 0):normalize()
                                local rightDir   = util.vector3(forwardDir.y, -forwardDir.x, 0)
                                -- Back to Left Hand (-)
                                startPos         = self.position + (forwardDir * 20) + util.vector3(0, 0, 110) - (rightDir * 30)
                            end

                            -- [PRECISION AIMING] Custom Engine Raycast (10000 units)
                            local cameraPos = camera.getPosition()
                            
                            -- Calculate camera vector manually since getViewDirection() is nil
                            local cp = -camera.getPitch()
                            local cy = camera.getYaw()
                            local cameraDir = util.vector3(math.cos(cp) * math.sin(cy), math.cos(cp) * math.cos(cy), math.sin(cp))
                            local endPos    = cameraPos + (cameraDir * 10000)
                            local ray       = nearby.castRay(cameraPos, endPos, { ignore = self })
                            
                            local aimPoint   = ray.hit and ray.hitPos or endPos
                            local hitObject  = ray.hit and ray.hitObject or nil

                            -- [CENTER-MASS MAGNETISM] If target is point-blank, aim for the heart, not the impact pixel
                            local distanceToTarget = (aimPoint - cameraPos):length()
                            if hitObject and distanceToTarget < 250 then
                                if hitObject.type == types.NPC or hitObject.type == types.Creature or hitObject.type == types.Player then
                                    local zOffset = 95
                                    pcall(function()
                                        local bbox = hitObject:getBoundingBox()
                                        if bbox and bbox.min and bbox.max then
                                            zOffset = (bbox.max.z - bbox.min.z) * 0.5
                                        end
                                    end)
                                    aimPoint = hitObject.position + util.vector3(0, 0, zOffset)
                                end
                            end

                            local skewedDirection = (aimPoint - startPos):normalize()

                            -- [RANGE RESOLUTION]
                            local range = core.magic.RANGE.Target
                            local spellRec = core.magic.spells.records[spell.id] or spell.enchantment
                            if spellRec and spellRec.effects and spellRec.effects[1] then
                                range = spellRec.effects[1].range
                            end

                            -- [TOUCH CHECK] Verify distance for melee magic
                            if range == core.magic.RANGE.Touch then
                                if hitObject then
                                    if distanceToTarget > 300 then 
                                        debugLog("Touch Target Too Far: " .. tostring(distanceToTarget))
                                        hitObject = nil 
                                    end
                                else
                                    debugLog("OSSC: No valid Touch target found in ray.")
                                end
                            end

                            -- [DYNAMIC SPAWN BUFFER] 
                            -- Prevent spawning "inside" actors at point-blank range
                            local spawnOffset = 80 
                            if hitObject and distanceToTarget < 200 then
                                spawnOffset = 10 -- Start at hand to ensure we don't skip the front surface
                            end

                            core.sendGlobalEvent('MagExp_CastRequest', {
                                attacker      = self,
                                spellId       = spell.id,
                                startPos      = startPos,
                                direction     = skewedDirection,
                                area          = spell.area,
                                isFree        = true,
                                item          = spell.item, 
                                hitObject     = hitObject,
                                spawnOffset   = spawnOffset
                            })

                            -- Authoritative Item Consumption
                            if isItem then
                                if spell.enchantment and spell.enchantment.type == 0 then
                                    core.sendGlobalEvent('OSSC_ConsumeScroll', { actor = self, item = spell.item })
                                elseif spell.enchantment and spell.enchantment.type == 2 then
                                    core.sendGlobalEvent('OSSC_ConsumeCharge', { 
                                        actor = self, 
                                        item  = spell.item, 
                                        cost  = tonumber(spell.cost) or 0 
                                    })
                                end
                            end

                            -- [SKILL PROGRESS] 
                            local xpGain = storage.playerSection('SettingsOSSC_General'):get('SkillExperience')
                            if isItem then
                                I.SkillProgression.skillUsed('enchant', { 
                                    skillGain = xpGain,
                                    useType   = 1 -- EnchantUse
                                })
                            elseif spell.effects and spell.effects[1] then
                                -- Normal spells grant School-specific experience
                                local mgef = core.magic.effects.records[spell.effects[1].id]
                                if mgef and mgef.school then
                                    I.SkillProgression.skillUsed(mgef.school, { 
                                        skillGain = xpGain,
                                        useType   = 0 -- SpellCast
                                    })
                                end
                            end
                        else
                             ui.showMessage("Your spell failed to cast.")
                             core.sound.playSound3d("spell failure illusion", self)
                        end
                    end
                end
                table.remove(pendingLaunches, i)
            end
        end
    end

    if isCasting
    and not anim.isPlaying(self, 'quickthrow')
    and not anim.isPlaying(self, 'quickbuff')
    and not anim.isPlaying(self, 'spellcast') then
        isCasting = false
        if I.Controls then I.Controls.overrideCombatControls(false) end
    end
end

local function onTextKey(groupname, key)
    if not isCasting then return end

    local lowerKey = key:lower()
    debugLog("Text Key Fired -> group=" .. tostring(groupname) .. "  key=" .. tostring(key))

    -- [START] Wind-up sound
    if string.find(lowerKey, 'start') or lowerKey == 'equip start' then
        if hasQueuedLaunch then return end
        hasQueuedLaunch = true
        
        local spell = currentSpell
        if spell and spell.effects and spell.effects[1] then
            local mgef = core.magic.effects.records[spell.effects[1].id]
            if mgef then
                local sStr = "destruction"
                local school = mgef.school
                local SCHOOL = core.magic.SCHOOL or { Alteration=0, Conjuration=1, Destruction=2, Illusion=3, Mysticism=4, Restoration=5 }
                
                if type(school) == "string" then
                    sStr = school:lower()
                else
                    if school == SCHOOL.Restoration then sStr = "restoration"
                    elseif school == SCHOOL.Illusion then sStr = "illusion"
                    elseif school == SCHOOL.Conjuration then sStr = "conjuration"
                    elseif school == SCHOOL.Alteration then sStr = "alteration"
                    elseif school == SCHOOL.Mysticism then sStr = "mysticism" end
                end
                
                local sndId = sStr .. " cast"
                if mgef.castSound and mgef.castSound ~= "" then
                    sndId = mgef.castSound
                end
                
                -- [CASTING VISUALS] Hand Glows
                pcall(function()
                    if mgef.castStatic then
                        local static = types.Static.records[mgef.castStatic]
                        if static and static.model then
                            anim.addVfx(self, static.model, { loop = true, vfxId = "OSSC_HandGlow" })
                        end
                    end
                end)
                
                debugLog("Windup Sound evaluating to: " .. tostring(sndId))
                pcall(function() core.sound.playSound3d(sndId, self, { volume = 1.0 }) end)
                
                -- Queue the spell application for the appropriate delay
                local delay = 0.62 
                if spell.effects and spell.effects[1] then
                    local r = spell.effects[1].range
                    if r == core.magic.RANGE.Self then
                        delay = 1.00 
                    elseif r == core.magic.RANGE.Touch then
                        delay = 0.62
                    end
                end

                debugLog("Queueing Launch for " .. tostring(spell.id))
                table.insert(pendingLaunches, {
                    spell      = spell,
                    timeToFire = core.getSimulationTime() + delay
                })
            end
            add_spell_vfx()
        end

    -- [RELEASE] Launch spell
    elseif string.find(lowerKey, 'release') or string.find(lowerKey, 'shoot release') then
        anim.removeVfx(self, "OSSC_HandGlow")
        -- Logic handled by pendingLaunches queue

    elseif string.find(lowerKey, 'stop') then
        anim.removeVfx(self, "OSSC_HandGlow")
        remove_spell_vfx()
        isCasting = false
        if I.Controls then I.Controls.overrideCombatControls(false) end
    end
end

input.registerActionHandler('OSSC_QuickCast', async:callback(function(pressed)
    -- Robust UI mode check
    local uiMode = (ui and ui.activeMode)
    if not uiMode and I.UI and I.UI.getMode then uiMode = I.UI.getMode() end
    
    if not pressed or uiMode ~= nil or core.isWorldPaused() then return end
    if isCasting then return end

    debugLog("Quick Cast Action Triggered")

    for _, groupName in ipairs(INCAPACITATED_GROUPS) do
        if anim.isPlaying(self, groupName) then return end
    end

    local activeSpellResult = nil
    
    debugLog("Magic Search: Stance=" .. tostring(types.Actor.getStance(self)))

    -- TRY 1: Local Magic API
    local ok, err = pcall(function() activeSpellResult = core.magic.getSelectedSpell() end)
    
    -- TRY 2: Player Specific Spell API
    if not activeSpellResult then
        pcall(function() activeSpellResult = types.Player.getSelectedSpell(self) end)
    end

    -- TRY 3: Enchanted Item API (Scrolls/Items)
    if not activeSpellResult then
        pcall(function() activeSpellResult = types.Player.getSelectedEnchantedItem(self) end)
    end

    -- TRY 4: Actor General API
    if not activeSpellResult then
        pcall(function() activeSpellResult = types.Actor.getSelectedSpell(self) end)
    end
    
    if activeSpellResult then
        local displayId = "unknown"
        pcall(function() displayId = activeSpellResult.id or activeSpellResult.recordId or tostring(activeSpellResult) end)
        debugLog("Magic Search: Final Result ID=" .. tostring(displayId) .. " type=" .. type(activeSpellResult))
    end

    local activeSpell = nil
    if not activeSpellResult or activeSpellResult == "" then 
        debugLog("Magic Search: Nothing selected in magic slot.")
        return 
    end

    if type(activeSpellResult) == "table" then
        activeSpell = activeSpellResult
        debugLog("Magic Search: Found Table. ID=" .. tostring(activeSpell.id))
    elseif type(activeSpellResult) == "userdata" then
        local isObject = false
        pcall(function() if activeSpellResult.recordId then isObject = true end end)

        if isObject then
            -- [ITEM CONVERSION]
            local item = activeSpellResult
            debugLog("Magic Search: Found Item Object " .. tostring(item.recordId))
            local rec = nil
            pcall(function()
                if item.type == types.Weapon then rec = types.Weapon.record(item)
                elseif item.type == types.Armor then rec = types.Armor.record(item)
                elseif item.type == types.Clothing then rec = types.Clothing.record(item)
                elseif item.type == types.Book then rec = types.Book.record(item)
                elseif item.type == types.MiscItem then rec = types.MiscItem.record(item) end
            end)
            
            if rec and rec.enchant then
                local enchRec = core.magic.enchantments.records[rec.enchant]
                local baseCost = 1
                if enchRec then
                    if enchRec.cost then baseCost = enchRec.cost end
                end
                
                activeSpell = {
                    id          = rec.enchant,
                    item        = item,
                    enchantment = enchRec,
                    effects     = enchRec and enchRec.effects or {},
                    cost        = baseCost -- EXPLICITLY SETTING THIS
                }
                debugLog(string.format("Magic Search: Converted Item %s (Enchant: %s, Cost: %d)", 
                    tostring(item.recordId), tostring(rec.enchant), baseCost))
            end
        else
            -- [SPELL RECORD CONVERSION]
            local spellRec = activeSpellResult
            activeSpell = {
                id      = spellRec.id,
                effects = spellRec.effects,
                cost    = spellRec.cost or 0,
                type    = spellRec.type -- might be nil for items
            }
            debugLog("Magic Search: Converted Spell Record to Table. ID=" .. tostring(activeSpell.id))
        end
    else
        -- [ID FALLBACK]
        activeSpell = { id = activeSpellResult }
        debugLog("Magic Search: Found ID String '" .. tostring(activeSpellResult) .. "'. Searching equipment...")
        -- (Inventory scan logic preserved)
        local equipment = types.Actor.getEquipment(self)
        for _, slot in pairs(types.Actor.EQUIPMENT_SLOT) do
            local item = equipment[slot]
            if item then
                local rec = nil
                -- Use pcall for record access safety across types
                pcall(function()
                    if item.type == types.Weapon then rec = types.Weapon.record(item)
                    elseif item.type == types.Armor then rec = types.Armor.record(item)
                    elseif item.type == types.Clothing then rec = types.Clothing.record(item)
                    elseif item.type == types.Book then rec = types.Book.record(item)
                    elseif item.type == types.MiscItem then rec = types.MiscItem.record(item) end
                end)
                
                -- Check if item enchantment ID matches the selected spell ID
                if rec and rec.enchant and rec.enchant == activeSpellResult then
                    activeSpell.item = item
                    activeSpell.enchantment = core.magic.enchantments.records[rec.enchant]
                    activeSpell.cost = activeSpell.enchantment and activeSpell.enchantment.cost or 1
                    debugLog("Magic Search: Linked to item " .. tostring(item.recordId))
                    break
                end
            end
        end
    end

    if activeSpell and activeSpell.id then
        local spellId = activeSpell.id
        local spellRec = core.magic.spells.records[spellId]
        
        -- Fallback to enchantment effects if it's an item (for Power check)
        if not spellRec and activeSpell.enchantment then
            spellRec = activeSpell.enchantment
        end
        
        if not spellRec then
             debugLog("Magic Search: No spell/enchantment record found for " .. tostring(spellId))
             return
        end

        if spellRec and spellRec.type == core.magic.SPELL_TYPE.Power then
            ui.showMessage("You need bigger focus to cast powers. Use spell stance.")
            return
        end
        
        currentSpell    = activeSpell
        isCasting       = true
        hasQueuedLaunch = false
        debugLog("Magic Search: SUCCESS. Prepared " .. tostring(spellId))

        if I.Controls then I.Controls.overrideCombatControls(true) end
        core.sendGlobalEvent('MagExp_BreakInvisibility', { actor = self })

        local range = (activeSpell.effects and activeSpell.effects[1]) and activeSpell.effects[1].range or core.magic.RANGE.Target
        local animGroup = (range == core.magic.RANGE.Self) and 'quickbuff' or 'quickthrow'

        if animGroup == 'quickbuff' then
            I.AnimationController.playBlendedAnimation(animGroup, {
                priority = anim.PRIORITY.Scripted + 100,
                startkey = 'start',
                stopkey  = 'stop',
                speed    = 1.5,
                blendMask = 14
            })
        else
            I.AnimationController.playBlendedAnimation(animGroup, {
                priority = anim.PRIORITY.Scripted + 100,
                startkey = 'start',
                stopkey  = 'stop',
                speed    = 0.65,
                blendMask = 14
            })
            anim.setSpeed(self, animGroup, 0.55)
            async:newUnsavableSimulationTimer(0.65, function()
                if isCasting and anim.isPlaying(self, animGroup) then
                    pcall(function() anim.setSpeed(self, animGroup, 0.85) end)
                end
            end)
        end
    end
end))


if I.AnimationController then
    I.AnimationController.addTextKeyHandler('quickthrow', onTextKey)
    I.AnimationController.addTextKeyHandler('quickbuff',  onTextKey)
else
    print("OSSC: AnimationController interface not available.")
end

debugLog("--- OSSC PLAYER SCRIPT INITIALIZED SUCCESSFULLY ---")


local function onSave()
    return {
        powerCooldowns = OSSC_PowerCooldowns,
    }
end

local function onLoad(data)
    if data and data.powerCooldowns then
        OSSC_PowerCooldowns = data.powerCooldowns
    end
end

return {
    engineHandlers = {
        onUpdate      = onUpdate,
        onSave        = onSave,
        onLoad        = onLoad,
    },
    eventHandlers = {
        AddVfx      = function(data) pcall(function() anim.addVfx(self, data.model, data.options) end) end,
        RemoveVfx   = function(vId)  pcall(function() anim.removeVfx(self, vId) end) end,
        PlaySound3d = function(data) pcall(function() core.sound.playSound3d(data.sound, self) end) end,
        
        -- Authoritative Hit Dispatch (Regressed previously)
        MagExp_Local_MagicHit = function(data)
            -- Local logic for impact particles can go here
        end
    }
}