--[[
	AffixDex - Project Ebonhold affix tracker
	Author:  Noturpalguy <kwillia@gmail.com>
	Source:  https://github.com/kwilliams312/AffixDex

	Affixes are learned spells that live in a tab of the player's spellbook. This
	addon scans the spellbook, records which affixes (and ranks) you have learned
	- cumulatively, in per-character SavedVariables - and shows them in a grid:
	known affixes are lit, unknown ones are greyed out, with a check mark for each
	learned rank.

	Slash commands:
		/adex                toggle the window (and rescan)
		/adex scan           rescan the spellbook now
		/adex tabs           (debug) list spellbook tabs
		/adex tab N          (debug) dump the spell names in tab N
		(/affixtracker is an alias; /affixdex is reserved by the Ebonhold client)

	Self-contained: the affix lists and ranked/weapon classification are bundled
	below, so this addon has NO dependency on Auctioneer or any other addon.

	Party sharing: members running AffixDex exchange their learned affixes over the
	addon channel. Interop is gated on a wire PROTOCOL version (separate from the
	semver display Version), so cosmetic/UI releases don't break sharing - only a
	change to the message format bumps PROTOCOL. A peer on a different protocol is
	flagged (not trusted).
]]

local ADDON = "AffixDex"

-- Addon version (semver) - read from the .toc so it's a single source of truth.
-- Bump this freely for any release (features, fixes, cosmetics).
local VERSION = (GetAddOnMetadata and GetAddOnMetadata("AffixDex", "Version")) or "1.6.0"

-- Wire-protocol version for party sharing - SEPARATE from the display version.
-- Only bump this when the addon-message FORMAT or SEMANTICS change. Clients
-- interoperate as long as their PROTOCOL matches, regardless of display version,
-- so cosmetic/UI releases don't break sharing between party members.
local PROTOCOL = 1

-- ---------------------------------------------------------------------------
-- Constants / helpers
-- ---------------------------------------------------------------------------

local NUM_TO_ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local ROMAN_INDEX = {}
for i, r in ipairs(NUM_TO_ROMAN) do ROMAN_INDEX[r] = i end

local BOOKTYPE = BOOKTYPE_SPELL or "spell"

local ROW_HEIGHT = 18
local NUM_ROWS = 17
local MIN_RANK_COLS = 5

-- ---------------------------------------------------------------------------
-- Affix data (self-contained - no dependency on Auctioneer/any other addon)
-- ---------------------------------------------------------------------------

-- Fallback affix lists, used when ProjectEbonhold's runtime catalog isn't
-- available yet (no PE loaded, no persisted catalog from a prior session).
-- Mirrors the server catalog from the live ExtractionService data; alphabetised
-- so it's easy to diff against `/adex catalog` output.

-- Ranked affixes (25): a Roman-numeral rank I..V is appended to the name.
local RANKED_AFFIXES = {
	"Arcane Mind", "Armor Rend", "Bulwark", "Cold", "Feral Grace", "Fortified by Pain",
	"Frost Breath", "Frozen Pulse", "Infinite Star", "Iron Will", "Ironhide", "Keen Strikes",
	"Living Tide", "Mender's Surge", "Overwhelming Force", "Pet Power", "Quick Instincts",
	"Relentless Crits", "Shield Block", "Spell Mastery", "Spirit Surge", "Stalwart",
	"Temporal Flux", "Thick Hide", "Wellspring",
}

-- Weapon affixes (41): rankless.
local WEAPON_AFFIXES = {
	"Affliction", "Azzinoth", "Bladestorm", "Bloodlust", "Clarity", "Concussion", "Decay",
	"Devastation", "Dissolution", "Execution", "Ferocity", "Fire Blast", "Flame Wrath",
	"Flurry", "Fortification", "Frailty", "Frost Arrow", "Fury", "Glaciation", "Hemorrhage",
	"Incineration", "Judgement", "Julie's Blessing", "Keeper's Sting", "Maiming", "Permafrost",
	"Pyromancy", "Rending", "Resurgence", "Shackling", "Shahram", "Speed", "Sulfuras",
	"Thunderfury", "Twin Shot", "Undead", "Val'anyr", "Vampirism", "Venom", "Vulnerability",
	"Wilds",
}

-- affixCanonical/affixWeapon are the runtime affix catalog. They start seeded
-- from the bundled fallback lists and are REPLACED by the authoritative server
-- catalog (ProjectEbonhold's ExtractionService.learnedAffixes) as soon as it's
-- available - see refreshAffixCatalog() below.
local affixCanonical = {}   -- lower(name) -> properly-capitalised display name
local affixWeapon = {}      -- lower(name) -> true if it's a rankless weapon affix
local function seedFallbackAffixes()
	for _, n in ipairs(RANKED_AFFIXES) do affixCanonical[n:lower()] = n end
	for _, n in ipairs(WEAPON_AFFIXES) do affixCanonical[n:lower()] = n; affixWeapon[n:lower()] = true end
	-- applyAliases() is defined later; called from the PLAYER_LOGIN path.
end
seedFallbackAffixes()

-- Canonical display name for a known affix (case-insensitive), else nil.
local function Canonical(name)
	return type(name) == "string" and affixCanonical[name:lower()] or nil
end

-- True if the affix is a known rankless (weapon) affix.
local function IsRankless(name)
	return type(name) == "string" and affixWeapon[name:lower()] == true
end

-- ---------------------------------------------------------------------------
-- ProjectEbonhold integration: read the server's authoritative affix list
-- (ExtractionService.learnedAffixes) so we never miss an affix and never
-- mis-identify one. Each entry has { id, name, icon, weaponOnly, learned }.
-- Spell names include the rank suffix for ranked affixes ("Keen Strikes V");
-- we collapse those down to their base name in the catalog.
-- ---------------------------------------------------------------------------

local serverCatalogLoaded = false
local applyAliases  -- forward declaration (defined further down with ITEM_ALIASES)

-- Forward declarations: these are *referenced* by the refresh helpers below but
-- *defined* further down the file (alongside the saved-data and icon code).
-- We declare the upvalues here so the helpers see the eventual real functions.
local setAffixIcon
local recordLearned
local DB
local ADB
local affixProcDescriptionsStale = true  -- forward upvalue: invalidated by refresh helpers, rebuilt lazily in parseItemAffix
local affixDescriptionsStale     = true  -- forward upvalue: raw spell-tooltip text cache for the affix hover tooltip

-- Write the current runtime catalog to AffixDexDB so it survives logout. The
-- persisted catalog is the source of truth for the display next session even if
-- ProjectEbonhold isn't loaded that time; this is what makes the fallback list
-- self-heal (no more stale hand-maintained guesses).
local function persistCatalog()
	if type(ADB) ~= "function" then return end
	local d = ADB()
	d.serverCatalog = { ranked = {}, weapon = {} }
	for key, display in pairs(affixCanonical) do
		-- Skip alias keys (where the key isn't this entry's own lowercase'd display
		-- name). applyAliases() re-adds them on every load from the ITEM_ALIASES
		-- map, so we don't need to persist them.
		if key == display:lower() then
			if affixWeapon[key] then d.serverCatalog.weapon[key] = display
			else d.serverCatalog.ranked[key] = display end
		end
	end
end

-- Load a previously-persisted catalog (if any) over the bundled fallback seed.
-- Called once at startup before any PE data arrives, so the displayed list is
-- already accurate even before the server response lands.
local function loadPersistedCatalog()
	if type(AffixDexDB) ~= "table" or type(AffixDexDB.serverCatalog) ~= "table" then return false end
	local sc = AffixDexDB.serverCatalog
	if (not sc.ranked or not next(sc.ranked)) and (not sc.weapon or not next(sc.weapon)) then return false end
	for k in pairs(affixCanonical) do affixCanonical[k] = nil end
	for k in pairs(affixWeapon)    do affixWeapon[k]    = nil end
	if sc.ranked then for k, v in pairs(sc.ranked) do affixCanonical[k] = v end end
	if sc.weapon then for k, v in pairs(sc.weapon) do affixCanonical[k] = v; affixWeapon[k] = true end end
	applyAliases()
	return true
end

-- Rebuild affixCanonical / affixWeapon from ProjectEbonhold's data when present.
-- Returns true if the rebuild happened (server data was available). Also writes
-- the result to AffixDexDB so the next session starts with this catalog.
local function refreshAffixCatalog()
	local svc = _G.ExtractionService
	if not (svc and svc.learnedAffixes) or #svc.learnedAffixes == 0 then return false end

	local canon, weapon = {}, {}
	for _, a in ipairs(svc.learnedAffixes) do
		if type(a.name) == "string" and a.name ~= "" then
			-- Spell names like "Keen Strikes V" -> base name "Keen Strikes".
			local base = a.name:match("^(.-)%s+[IVXLCivxlc]+$") or a.name
			local key = base:lower()
			canon[key] = base
			if a.weaponOnly then weapon[key] = true end
			if a.icon then setAffixIcon(base, a.icon) end
		end
	end
	-- Replace tables in-place so other code keeping references stays valid.
	for k in pairs(affixCanonical) do affixCanonical[k] = nil end
	for k, v in pairs(canon) do affixCanonical[k] = v end
	for k in pairs(affixWeapon) do affixWeapon[k] = nil end
	for k, v in pairs(weapon) do affixWeapon[k] = v end
	serverCatalogLoaded = true
	applyAliases()
	persistCatalog()
	affixProcDescriptionsStale = true   -- rebuild proc-text cache on next item parse
	affixDescriptionsStale     = true   -- rebuild raw-description cache on next hover
	return true
end

-- Mark the player as having learned every entry the server says they have.
-- Adds to the existing learned set rather than wiping, so spellbook-derived
-- entries from earlier sessions stick around even if PE hasn't sent data yet.
local function refreshLearnedFromServer()
	local svc = _G.ExtractionService
	if not (svc and svc.learnedAffixes) or #svc.learnedAffixes == 0 then return false end
	for _, a in ipairs(svc.learnedAffixes) do
		if a.learned and type(a.name) == "string" and a.name ~= "" then
			local base, roman = a.name:match("^(.-)%s+([IVXLCivxlc]+)$")
			if base and roman then
				recordLearned(base, roman:upper(), false)
			else
				recordLearned(a.name, nil, a.weaponOnly or false)
			end
		end
	end
	return true
end

-- Server rule (corrected after seeing real gear): ranked affixes appear on
-- ANY equippable non-weapon - armor, shirt, tabard, shield, AND jewelry (neck,
-- rings, trinkets). Weapon affixes go on weapons. These sets let us reject
-- ineligible items before the tooltip scan and constrain which family can match.
local EQUIP_RANKED = {
	INVTYPE_HEAD = true, INVTYPE_NECK = true, INVTYPE_SHOULDER = true,
	INVTYPE_CHEST = true, INVTYPE_ROBE = true,
	INVTYPE_WAIST = true, INVTYPE_LEGS = true, INVTYPE_FEET = true,
	INVTYPE_WRIST = true, INVTYPE_HAND = true,
	INVTYPE_FINGER = true, INVTYPE_TRINKET = true,
	INVTYPE_CLOAK = true,
	INVTYPE_BODY = true, INVTYPE_TABARD = true,
	INVTYPE_SHIELD = true,
}
local EQUIP_WEAPON = {
	INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
	INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
	INVTYPE_HOLDABLE = true,
	INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true,
}

-- Some affixes appear in item tooltips under a *different* name than their
-- underlying spell. PE's own FindItemAffix uses this map; we mirror it here.
-- Keys are the tooltip word that appears on items ("Block" in "of Block V");
-- values are the canonical spell name as registered in our catalog.
-- Mirrors all 6 entries from PE's AFFIX_ALIASES table (in extraction.lua).
local ITEM_ALIASES = {
	["precision"]      = "Cold",
	["swift footwork"] = "Feral Grace",
	["keen strike"]    = "Keen Strikes",   -- singular tooltip text vs plural spell
	["block"]          = "Shield Block",
	["inner light"]    = "Spirit Surge",
	["enduring flesh"] = "Ironhide",       -- legacy: spell was renamed Enduring Flesh -> Ironhide
}

-- After the catalog is loaded/refreshed, add alias keys to affixCanonical that
-- point at the canonical display name. This lets the tooltip scanner match
-- either spelling and report the canonical one.
function applyAliases()  -- assigns to the upvalue forward-declared near the top
	for tooltipText, spellName in pairs(ITEM_ALIASES) do
		local spellKey = spellName:lower()
		local canonical = affixCanonical[spellKey]
		if canonical then
			affixCanonical[tooltipText] = canonical
			if affixWeapon[spellKey] then affixWeapon[tooltipText] = true end
		end
	end
end

-- One-time migration: legacy data that stored the tooltip-text spelling as a
-- standalone learned/discovered entry (e.g. "Block" instead of "Shield Block")
-- gets merged into the canonical name. Also strips stale entries from the
-- persisted catalog.
local function migrateAliases()
	if type(AffixDexCharDB) == "table" and type(AffixDexCharDB.learned) == "table" then
		local learned = AffixDexCharDB.learned
		for tooltipText, spellName in pairs(ITEM_ALIASES) do
			-- Match any key whose lowercase form == the alias.
			for key in pairs(learned) do
				if type(key) == "string" and key:lower() == tooltipText and key ~= spellName then
					local stale = learned[key]
					local target = learned[spellName] or {}
					learned[spellName] = target
					if stale.rankless then target.rankless = true end
					if stale.any then target.any = true end
					if stale.ranks then
						target.ranks = target.ranks or {}
						for r in pairs(stale.ranks) do target.ranks[r] = true end
					end
					learned[key] = nil
				end
			end
		end
	end
	-- Strip alias-spelled entries from the persisted catalog so they stop
	-- showing up in the display.
	if type(AffixDexDB) == "table" and type(AffixDexDB.serverCatalog) == "table" then
		for _, bucket in ipairs({ AffixDexDB.serverCatalog.ranked, AffixDexDB.serverCatalog.weapon }) do
			if type(bucket) == "table" then
				for tooltipText in pairs(ITEM_ALIASES) do bucket[tooltipText] = nil end
			end
		end
	end
	-- Same for the discovered table (legacy auto-discovery).
	if type(AffixDexDB) == "table" and type(AffixDexDB.discovered) == "table" then
		for tooltipText, spellName in pairs(ITEM_ALIASES) do
			for key in pairs(AffixDexDB.discovered) do
				if type(key) == "string" and key:lower() == tooltipText then
					AffixDexDB.discovered[key] = nil
				end
			end
		end
	end
end

-- True if the item link's random-property field is non-zero. This is the
-- server-level signal that the item carries a random suffix/affix; without it
-- there's nothing to detect. (Borrowed from PE's own FindItemAffix.)
local function HasRandomProperty(link)
	if type(link) ~= "string" then return false end
	local rp = select(8, strsplit(":", link))
	rp = rp and tonumber(rp)
	return rp ~= nil and rp ~= 0
end

-- Hidden scanner tooltip + cached line lookup. Used to read the item's actual
-- tooltip lines so we detect affixes by the tooltip text the server renders,
-- not by guessing from the item name.
local scanTooltip
local function ensureScanTooltip()
	if scanTooltip or not CreateFrame then return scanTooltip end
	scanTooltip = CreateFrame("GameTooltip", "AffixDexScanTooltip", nil, "GameTooltipTemplate")
	scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	return scanTooltip
end

-- A SECOND hidden tooltip used only for fetching spell descriptions (so building
-- the proc-text cache doesn't clobber the item-scan tooltip mid-parse).
local spellScanTooltip
local function ensureSpellScanTooltip()
	if spellScanTooltip or not CreateFrame then return spellScanTooltip end
	spellScanTooltip = CreateFrame("GameTooltip", "AffixDexSpellScanTooltip", nil, "GameTooltipTemplate")
	spellScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	return spellScanTooltip
end

-- ---------------------------------------------------------------------------
-- Fixed-affix weapon detection via proc-text matching.
--
-- Some weapons (legendary or named items like "The Judge's Gavel") carry an
-- inherent affix that never has its name in the item's tooltip - only the
-- proc-effect text ("Chance on hit: Stuns target for 3 sec."). They also have
-- no random-property suffix, so the normal random-suffix scan misses them.
--
-- Approach: for each WEAPON affix in ExtractionService.learnedAffixes, fetch
-- its spell description via GetSpellDescription (same approach as PE's own
-- helper), normalise it (strip numbers, color codes, "Chance on hit:" prefix,
-- etc.), and cache it. When we scan an item that has no random suffix, look
-- for any of those cached descriptions inside its tooltip lines.
-- ---------------------------------------------------------------------------

-- [affixName] = { raw = "...", normalized = "...", spellId = N }
-- affixProcDescriptionsStale is forward-declared near the top of the file so the
-- refresh helpers above can invalidate it.
local affixProcDescriptions

-- Lowercase + strip everything that varies between items / between spell and
-- item wording (color codes, numbers, "Chance on hit:" prefix, var refs).
local function normalizeProcText(s)
	if type(s) ~= "string" then return "" end
	s = s:lower()
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")  -- WoW color escapes
	s = s:gsub("^chance on hit%s*:?%s*", "")             -- items prefix this
	s = s:gsub("^chance on hit%s*", "")
	s = s:gsub("^chance to strike[^:]-:?%s*", "")        -- ranged variant
	s = s:gsub("%$[%a]+", "")                            -- $a, $d, $s placeholders
	s = s:gsub("%d+%.?%d*", "")                          -- numbers (durations, damage)
	s = s:gsub("[%s%.,;:!?]+", " ")                      -- normalise punctuation/spaces
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function getSpellDescription(spellId)
	if not spellId then return nil end
	local tip = ensureSpellScanTooltip()
	if not tip then return nil end
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	tip:ClearLines()
	local ok = pcall(function() tip:SetHyperlink("spell:" .. spellId) end)
	if not ok then return nil end
	local n = tip:NumLines() or 0
	if n < 2 then return nil end
	local lines = {}
	for i = 2, n do
		local lineObj = _G["AffixDexSpellScanTooltipTextLeft" .. i]
		local text = lineObj and lineObj.GetText and lineObj:GetText()
		if text and text ~= "" then lines[#lines + 1] = text end
	end
	return table.concat(lines, "\n")
end

-- Build the proc cache from ExtractionService.learnedAffixes. Called lazily.
local function buildProcDescriptionCache()
	affixProcDescriptions = {}
	affixProcDescriptionsStale = false
	local svc = _G.ExtractionService
	if not svc or not svc.learnedAffixes or #svc.learnedAffixes == 0 then return end
	-- Dedup by canonical affix name so we only have one entry per weapon affix.
	local seenName = {}
	for _, affix in ipairs(svc.learnedAffixes) do
		if affix.weaponOnly and type(affix.name) == "string" and affix.id and not seenName[affix.name] then
			seenName[affix.name] = true
			local desc = getSpellDescription(affix.id)
			if desc and desc ~= "" then
				local norm = normalizeProcText(desc)
				if norm ~= "" then
					affixProcDescriptions[affix.name] = {
						raw = desc, normalized = norm, spellId = affix.id,
					}
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Affix description cache (for the hover tooltip on each grid row).
--
-- Like the proc cache above, but stores RAW spell-tooltip text for ALL affixes
-- (both ranked and weapon), keyed by canonical base name (not the full spell
-- name with a rank suffix). For ranked affixes we pick the "best" rank to show
-- - highest learned tier first, falling back to highest tier seen - so the
-- tooltip describes the affix at the strongest version you know.
-- ---------------------------------------------------------------------------

-- [baseName] = { raw = "Stuns target for 3 sec.", spellId = N }
local affixDescriptions

local TIER_TO_NUM = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6, VII = 7, VIII = 8, IX = 9, X = 10 }

local function buildAffixDescriptionCache()
	affixDescriptions = {}
	affixDescriptionsStale = false
	local svc = _G.ExtractionService
	if not svc or not svc.learnedAffixes or #svc.learnedAffixes == 0 then return end

	-- Group affixes by base name; remember each tier's entry.
	-- groups[baseName] = { tiers = { [tierNum] = affix }, weaponOnly = bool }
	local groups = {}
	for _, affix in ipairs(svc.learnedAffixes) do
		if type(affix.name) == "string" and affix.id then
			local base, tier = affix.name:match("^(.-)%s+([IVXLCivxlc]+)$")
			if not base then base = affix.name end
			local tierNum = (tier and TIER_TO_NUM[tier:upper()]) or 0
			local g = groups[base]
			if not g then g = { tiers = {}, weaponOnly = affix.weaponOnly }; groups[base] = g end
			g.tiers[tierNum] = affix
		end
	end

	-- For each group, pick the best representative and fetch its spell tooltip.
	for baseName, group in pairs(groups) do
		local best
		-- Prefer the highest LEARNED tier.
		for tierNum = 10, 0, -1 do
			local a = group.tiers[tierNum]
			if a and a.learned then best = a; break end
		end
		-- Otherwise fall back to the highest tier we know about.
		if not best then
			for tierNum = 10, 0, -1 do
				local a = group.tiers[tierNum]
				if a then best = a; break end
			end
		end
		if best then
			local desc = getSpellDescription(best.id)
			if desc and desc ~= "" then
				affixDescriptions[baseName] = { raw = desc, spellId = best.id }
			end
		end
	end
end

-- Walk the item's tooltip lines (already populated into scanTooltip by the
-- caller) and return the canonical affix name whose proc description best
-- matches. "Best" = longest normalized description matched, so a more specific
-- affix beats a more generic one. nil if no match.
-- Minimum normalized-description length to consider a match - guards against
-- a single-word affix description ("Stuns") matching everything in sight.
local PROC_MIN_DESC_LEN = 12

local function detectFixedAffixByProc(numLines)
	if affixProcDescriptionsStale then buildProcDescriptionCache() end
	if not affixProcDescriptions or not next(affixProcDescriptions) then return nil end

	local bestName, bestLen
	for j = 1, numLines do
		local lineObj = _G["AffixDexScanTooltipTextLeft" .. j]
		local text = lineObj and lineObj.GetText and lineObj:GetText()
		if text and text ~= "" then
			local normLine = normalizeProcText(text)
			if normLine ~= "" then
				for affixName, descData in pairs(affixProcDescriptions) do
					local descNorm = descData.normalized
					-- Only match when the affix description appears at the
					-- START of the item line (after normalisation strips the
					-- "Chance on hit:" prefix). Proc text is always the start
					-- of its line - substring-matching anywhere in the line
					-- (e.g. "ranged target" being found mid-tooltip) is what
					-- caused false positives like wands being attributed to
					-- Keeper's Sting.
					if descNorm ~= "" and #descNorm >= PROC_MIN_DESC_LEN
							and normLine:find(descNorm, 1, true) == 1 then
						local matchLen = #descNorm
						if not bestLen or matchLen > bestLen then
							bestName, bestLen = affixName, matchLen
						end
					end
				end
			end
		end
	end
	return bestName
end

-- Register a newly-discovered RANKED affix (found on a spell or item but not in
-- the built-in list). Persisted account-wide so it sticks. Returns the canonical
-- name, or nil if it doesn't look like a valid affix name. (Weapon affixes can't
-- be auto-discovered - they have no rank marker to tell them from normal suffixes.)
local function registerRanked(name)
	if type(name) ~= "string" or name == "" then return nil end
	local key = name:lower()
	if affixCanonical[key] then return affixCanonical[key] end       -- already known
	if not name:match("^%u[%a' ]*[%a]$") then return nil end          -- looks like "Some Affix"
	affixCanonical[key] = name                                       -- recognise it from now on
	if type(AffixDexDB) ~= "table" then AffixDexDB = {} end
	AffixDexDB.discovered = AffixDexDB.discovered or {}
	AffixDexDB.discovered[name] = true
	return name
end

-- Fold previously-discovered affixes (from saved data) back into the recogniser.
local function loadDiscovered()
	if type(AffixDexDB) == "table" and type(AffixDexDB.discovered) == "table" then
		for name in pairs(AffixDexDB.discovered) do affixCanonical[name:lower()] = name end
	end
end

local function trim(s)
	if not s then return "" end
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function msg(text)
	DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[AffixDex]|r " .. text)
end

local function isRoman(tok)
	return tok and ROMAN_INDEX[tok:upper()] ~= nil
end

-- Parse a rank token out of a spell's sub-text. Deliberately strict so that
-- ordinary sub-texts like "Passive" are not mistaken for a Roman numeral.
local function rankFromSubText(s)
	if not s or s == "" then return nil end
	local token = s:match("[Rr]ank%s+([%w]+)")
	if not token then
		token = s:match("^%s*([IVXLCivxlc]+)%s*$") or s:match("^%s*(%d+)%s*$")
	end
	if not token then return nil end
	local up = token:upper()
	if ROMAN_INDEX[up] then return up end
	local num = tonumber(token)
	if num and NUM_TO_ROMAN[num] then return NUM_TO_ROMAN[num] end
	return nil
end

-- Interpret a spellbook spell as an affix.
-- Returns: affixName (canonical), rank (Roman or nil), isRankless (bool)
--          or nil if the spell isn't a recognised affix.
local function ParseSpellAsAffix(name, subText)
	name = trim(name)
	if name == "" then return nil end

	-- 1) Rank in the name, e.g. "Keen Strikes V" - only accept when the base is
	--    a known *ranked* affix and the trailing token is a real Roman numeral.
	local base, rom = name:match("^(.-)%s+([IVXLCivxlc]+)$")
	if base and rom and isRoman(rom) then
		local canon = Canonical(base)
		if canon then
			if not IsRankless(canon) then return canon, rom:upper(), false end
		else
			local reg = registerRanked(base)            -- new ranked affix discovered
			if reg then return reg, rom:upper(), false end
		end
	end

	-- 2) The whole name is a known affix.
	local canon = Canonical(name)
	if canon then
		if IsRankless(canon) then
			return canon, nil, true          -- weapon affix (no rank)
		end
		return canon, rankFromSubText(subText), false  -- ranked; rank may be unknown
	end

	return nil
end

-- ---------------------------------------------------------------------------
-- Saved data
-- ---------------------------------------------------------------------------
-- AffixDexCharDB.learned[affixName] = { ranks = {[roman]=true}, rankless=bool, any=bool }

function DB()
	if type(AffixDexCharDB) ~= "table" then AffixDexCharDB = {} end
	if type(AffixDexCharDB.learned) ~= "table" then AffixDexCharDB.learned = {} end
	return AffixDexCharDB
end

-- Account-wide store: persistent snapshots of party members' affixes.
-- AffixDexDB.snapshots[playerName] = { learned = {...}, t = epochSeconds }
function ADB()
	if type(AffixDexDB) ~= "table" then AffixDexDB = {} end
	if type(AffixDexDB.snapshots) ~= "table" then AffixDexDB.snapshots = {} end
	if type(AffixDexDB.closedTabs) ~= "table" then AffixDexDB.closedTabs = {} end  -- tabs the user hid (data kept)
	return AffixDexDB
end

-- Persist (or refresh) a snapshot of a party member's affixes.
local function saveSnapshot(name, learned)
	if not name or name == "" then return end
	local when = (time and time()) or 0
	ADB().snapshots[name] = { learned = learned, t = when }
end

function recordLearned(affix, rank, rankless)
	local learned = DB().learned
	local e = learned[affix]
	if not e then e = {}; learned[affix] = e end
	if rankless then
		e.rankless = true
	elseif rank then
		e.ranks = e.ranks or {}
		e.ranks[rank] = true
	else
		e.any = true
	end
end

local function entryFor(affix)
	return DB().learned[affix]
end

-- Party-shared data (runtime only): [senderName] = { learned = {...}, t = time }
local partyAffixes = {}
local currentView = "You"   -- "You", a live party member, or a saved snapshot name
local mismatch = {}         -- [sender] = peerVersion  (peers on a different version)
local mismatchWarned = {}   -- [sender] = version we last warned about
local equipped = {}         -- affixes on your currently-worn gear: [affix] = {ranks={}, rankless}
local equippedCount = {}    -- [affix] = number of equipped items carrying it (for dup detection)
local equippedItems = {}    -- [affix@rank] = { itemLink, ... } equipped items carrying it
local bagItems = {}         -- [affix@rank] = { itemLink, ... } bag items carrying it
local bagAffixes = {}       -- affixes on items in your bags: [affix] = {ranks={}, rankless}
local notified = {}         -- session set of affix@rank keys already announced from bags
local searchText = ""       -- backlog search filter (lowercased)
local scanBags, updateBagHighlights -- forward declarations (defined after the UI)

-- Source-aware learned checks - work on any learned-table (mine or a party member's).
local function isLearnedIn(src, affix)
	local e = src and src[affix]
	return e and (e.rankless or e.any or (e.ranks and next(e.ranks) ~= nil)) or false
end

local function hasRankIn(src, affix, roman)
	local e = src and src[affix]
	return e and e.ranks and e.ranks[roman] or false
end

-- The learned-table currently being displayed: mine, a live party member, or a
-- saved snapshot (live data preferred when both exist).
local function viewSource()
	if not currentView or currentView == "You" then return DB().learned end
	local p = partyAffixes[currentView]
	if p then return p.learned end
	local snap = ADB().snapshots[currentView]
	return snap and snap.learned or {}
end

-- Do we have any data (live or saved) for this name?
local function haveData(name)
	return name == "You" or partyAffixes[name] ~= nil or ADB().snapshots[name] ~= nil
end

-- Search match: the query matches the player's name or any affix they have.
local function matchesSearch(name, learned, q)
	if q == "" then return true end
	if name:lower():find(q, 1, true) then return true end
	if learned then
		for affix in pairs(learned) do
			if affix:lower():find(q, 1, true) then return true end
		end
	end
	return false
end

local function isLearned(affix) return isLearnedIn(DB().learned, affix) end
local function hasRank(affix, roman) return hasRankIn(DB().learned, affix, roman) end

-- ---- Equipped affixes (highlighted in the grid) ----

-- Parse the affix off an ITEM name: "<Base> of <Affix> <Rank>" (ranked) or
-- "<Base> of <Affix>" (weapon). Returns affix, rank, isRankless  (or nil).
-- Detect an affix on an item link (or bare item name).
-- Returns affix, rank, rankless  (or nil if not a real affixed item).
--
-- Anti-false-positive rules (learned the hard way):
--   1. The item must be EQUIPPABLE - rejects quest items ("Fragment of Val'anyr"),
--      scrolls ("Scroll of Stamina IV"), consumables, etc. We need a link to do
--      this check via GetItemInfo; a bare name skips it (and may over-detect).
--   2. Rankless weapon affixes require AT LEAST TWO " of " segments. A real
--      affix is APPENDED to an already-named base (e.g. "Sword of Triumph of
--      Fury"), so the trailing " of <Affix>" sits after another earlier " of ".
--      This rejects "Gloves of Ferocity" (single "of" - that's a vanilla random
--      suffix, not the Ferocity weapon affix).
--   3. Ranked affixes are still gated on the trailing Roman numeral + a known
--      affix name (no auto-discovery from items, else scrolls leak through).
-- Detect an affix on an item link via tooltip scan (same approach as
-- ProjectEbonhold's own FindItemAffix - much more reliable than name parsing).
--   1. Skip items with no random-property suffix (server flag = no affix).
--   2. Read the item's actual tooltip into a hidden scanner GameTooltip and
--      look for a known affix name on any line, with word boundaries.
--   3. Pull a trailing Roman numeral off the matched line for ranked affixes.
-- Replaces the earlier name-parsing approach that misfired on vanilla random
-- suffixes ("Gloves of Ferocity") and quest items ("Fragment of Val'anyr").
local function parseItemAffix(link)
	if type(link) ~= "string" or link == "" then return nil end
	if not link:find("|H", 1, true) then return nil end           -- need a real link

	-- Slot-based gate: ranked affixes only on armor/shirt/tabard/shield/jewelry,
	-- weapon affixes only on weapons. Items in any other slot (non-equippable
	-- things) are rejected outright. GetItemInfo cache misses (nil) fall through
	-- and allow both families.
	local allowRanked, allowWeapon = true, true
	if GetItemInfo then
		local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
		if equipLoc then
			if EQUIP_RANKED[equipLoc] then
				allowWeapon = false
			elseif EQUIP_WEAPON[equipLoc] then
				allowRanked = false
			else
				return nil  -- ineligible slot (or non-equippable "")
			end
		end
	end

	-- If the item has no random-property suffix AND isn't a weapon slot, there's
	-- nothing to detect (random-suffix scan needs the suffix; fixed-affix scan
	-- only applies to weapons).
	local hasRP = HasRandomProperty(link)
	if not hasRP and not allowWeapon then return nil end

	local tip = ensureScanTooltip()
	if not tip then return nil end
	tip:SetOwner(WorldFrame, "ANCHOR_NONE")
	tip:ClearLines()
	tip:SetHyperlink(link)
	local n = tip:NumLines() or 0
	if n == 0 then return nil end

	-- Fixed-affix weapon detection runs ONLY for weapons WITHOUT a random
	-- suffix. Items like "Wand of Allistarj of Glaciation" go through the
	-- name-scan path below — running the proc matcher on them would risk a
	-- false match (e.g. a "Ranged" tooltip line getting attributed to some
	-- unrelated affix's description that mentions "ranged"). For real
	-- fixed-affix legendary weapons (Judge's Gavel, etc.) there's no random
	-- suffix and name-scan can't help anyway.
	if allowWeapon and not hasRP then
		local matchedAffix = detectFixedAffixByProc(n)
		if matchedAffix then
			local key = matchedAffix:lower()
			if affixCanonical[key] then
				return affixCanonical[key], nil, true
			end
		end
	end

	-- Random-suffix path: items without a random property can't match below
	-- (the name-based scan needs the suffix to be appended to the item name).
	if not hasRP then return nil end

	for j = 1, n do
		local lineObj = _G["AffixDexScanTooltipTextLeft" .. j]
		local text = lineObj and lineObj.GetText and lineObj:GetText()
		if text and text ~= "" then
			local lower = text:lower()
			for affixLower, canonical in pairs(affixCanonical) do
				local isWeapon = affixWeapon[affixLower]
				if (isWeapon and allowWeapon) or (not isWeapon and allowRanked) then
					-- Keep scanning all occurrences of the affix word in this line,
					-- not just the first. Otherwise an item whose base name contains
					-- the affix word (e.g. "Pauldrons of Stalwart Defense of Stalwart V")
					-- would match the first "stalwart" - which has no rank after it -
					-- and miss the real "Stalwart V" later in the same line.
					local searchStart = 1
					while true do
						local s, e = lower:find(affixLower, searchStart, true)
						if not s then break end
						-- word-boundary: don't match "Cold" inside "Coldsteel"
						local before = (s > 1) and lower:sub(s - 1, s - 1) or ""
						local after  = lower:sub(e + 1, e + 1)
						if (before == "" or not before:match("%w")) and (after == "" or not after:match("%w")) then
							if isWeapon then
								return canonical, nil, true
							end
							-- Ranked: trailing Roman numeral on the same line.
							local rom = lower:sub(e + 1):match("^%s+([ivxlc]+)")
							if rom and isRoman(rom) then
								return canonical, rom:upper(), false
							end
							-- This occurrence had no Roman - try the next.
						end
						searchStart = e + 1
					end
				end
			end
		end
	end
	return nil
end

-- Scan equipped gear (slots 1-19) and rebuild the `equipped`/`equippedCount` tables.
local function scanEquipped()
	local eq, count, items = {}, {}, {}
	for slot = 1, 19 do
		local link = GetInventoryItemLink("player", slot)
		if link then
			local affix, rank, rankless = parseItemAffix(link)
			if affix then
				local e = eq[affix]
				if not e then e = {}; eq[affix] = e end
				if rankless then
					e.rankless = true
				elseif rank then
					e.ranks = e.ranks or {}
					e.ranks[rank] = true
				end
				-- count + item link per affix+rank (different ranks stack)
				local ckey = affix .. "@" .. (rank or "W")
				count[ckey] = (count[ckey] or 0) + 1
				items[ckey] = items[ckey] or {}
				items[ckey][#items[ckey] + 1] = link
			end
		end
	end
	equipped = eq
	equippedCount = count
	equippedItems = items
end

local function isEquipped(affix)
	local e = equipped[affix]
	return e and (e.rankless or (e.ranks and next(e.ranks) ~= nil)) or false
end

local function rankEquipped(affix, roman)
	local e = equipped[affix]
	return e and e.ranks and e.ranks[roman] or false
end

-- How many equipped items carry this exact affix+rank (roman = nil for weapon
-- affixes). >1 means a duplicate; different ranks stack so they count separately.
local function equipCountAt(affix, roman)
	return equippedCount[affix .. "@" .. (roman or "W")] or 0
end

local function bagHasAffix(affix)
	local e = bagAffixes[affix]
	return e and (e.rankless or (e.ranks and next(e.ranks) ~= nil)) or false
end

local function bagHasRank(affix, roman)
	local e = bagAffixes[affix]
	return e and e.ranks and e.ranks[roman] or false
end

-- True if a bag item's affix is one you haven't learned yet.
local function itemHasUnlearnedAffix(link)
	if not link then return false end
	local affix, rank, rankless = parseItemAffix(link)
	if not affix then return false end
	if rankless then return not isLearnedIn(DB().learned, affix) end
	return not hasRankIn(DB().learned, affix, rank)
end

-- ---------------------------------------------------------------------------
-- Item tooltips: show the affix + whether you've learned it
-- ---------------------------------------------------------------------------

local function affixTooltipLine(tip)
	if tip.affixDexDone then return end
	local _, link = tip:GetItem()
	if not link then return end
	local affix, rank, rankless = parseItemAffix(link)
	if not affix then return end
	tip.affixDexDone = true

	local learned = DB().learned
	local known
	if rankless then known = isLearnedIn(learned, affix) else known = hasRankIn(learned, affix, rank) end

	tip:AddLine(("|cff66ccffAffixDex|r  %s%s  %s"):format(
		affix, rank and (" " .. rank) or "",
		known and "|cff40ff40learned|r" or "|cffff5555not learned|r"))

	-- for a ranked affix you don't have at this rank, note any ranks you DO have
	if not rankless and not known then
		local have = {}
		for c = 1, #NUM_TO_ROMAN do
			if hasRankIn(learned, affix, NUM_TO_ROMAN[c]) then have[#have + 1] = NUM_TO_ROMAN[c] end
		end
		if #have > 0 then
			tip:AddLine("|cff888888you have rank " .. table.concat(have, ", ") .. "|r")
		end
	end
	tip:Show()
end

local function hookTooltips()
	for _, tip in ipairs({ GameTooltip, ItemRefTooltip, ShoppingTooltip1, ShoppingTooltip2 }) do
		if tip and tip.HookScript then
			tip:HookScript("OnTooltipSetItem", affixTooltipLine)
			tip:HookScript("OnTooltipCleared", function(self) self.affixDexDone = nil end)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Spellbook scan
-- ---------------------------------------------------------------------------

local function forEachSpell(fn)
	local numTabs = GetNumSpellTabs() or 0
	local maxIndex = 0
	for t = 1, numTabs do
		local _, _, offset, numSpells = GetSpellTabInfo(t)
		if offset and numSpells then
			if offset + numSpells > maxIndex then maxIndex = offset + numSpells end
		end
	end
	for i = 1, maxIndex do
		local name, sub = GetSpellName(i, BOOKTYPE)
		if name then fn(i, name, sub) end
	end
end

local Scan -- forward declaration (defined after UI so it can refresh)

-- ---------------------------------------------------------------------------
-- Display list
-- ---------------------------------------------------------------------------

local function computeMaxRankCols()
	local m = MIN_RANK_COLS
	local function scan(learned)
		for _, e in pairs(learned) do
			if e.ranks then
				for r in pairs(e.ranks) do
					local idx = ROMAN_INDEX[r]
					if idx and idx > m then m = idx end
				end
			end
		end
	end
	scan(DB().learned)
	for _, p in pairs(partyAffixes) do if p.learned then scan(p.learned) end end
	if m > #NUM_TO_ROMAN then m = #NUM_TO_ROMAN end
	return m
end

-- Builds the flat list of display rows: section headers + affix rows.
local function buildDisplayList()
	local ranked, weapon, seen = {}, {}, {}

	local function classify(name)
		if seen[name] then return end
		seen[name] = true
		if IsRankless(name) then
			weapon[#weapon + 1] = name
		else
			ranked[#ranked + 1] = name
		end
	end

	-- Source the display from the RUNTIME catalog (affixCanonical), which is
	-- either the persisted server-side list or the bundled fallback seed.
	-- This way fake/legacy entries that aren't in the server's catalog never
	-- appear in the grid.
	for _, display in pairs(affixCanonical) do classify(display) end
	-- Anything the player has learned that somehow isn't in the catalog still shows.
	for name in pairs(DB().learned) do classify(name) end

	table.sort(ranked)
	table.sort(weapon)

	local rows = {}
	rows[#rows + 1] = { header = true, text = "Armor Affixes" }
	for _, n in ipairs(ranked) do rows[#rows + 1] = { affix = n, ranked = true } end
	rows[#rows + 1] = { header = true, text = "Weapon Affixes  (no ranks)" }
	for _, n in ipairs(weapon) do rows[#rows + 1] = { affix = n, ranked = false } end
	return rows
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

local frame, scroll, rowFrames, headerCells, statusFS
local displayList = {}

local CHECK_TEXTURE = "Interface\\RaidFrame\\ReadyCheck-Ready"    -- check glyph
local X_TEXTURE     = "Interface\\RaidFrame\\ReadyCheck-NotReady" -- red X (compare "neither")
local WHITE_TEX     = "Interface\\Buttons\\WHITE8X8"
local PLACEHOLDER_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- layout
local ROW_X      = 14    -- left x (frame-relative) for rows + column header
local ICON_SIZE  = 16
local NAME_X     = 22    -- name x within a row (after the icon)
local COL_START  = 168   -- where rank columns begin (within a row)
local COL_WIDTH  = 26
local CHECK_SIZE = 16

-- flat dark palette (teal / purple accents)
local PAL = {
	bg      = { 0.05, 0.06, 0.08, 0.95 },
	border  = { 0.18, 0.42, 0.46, 0.9 },
	header  = { 0.09, 0.11, 0.15, 1 },
	teal    = { 0.22, 0.82, 0.80 },
	purple  = { 0.64, 0.45, 0.95 },
	stripe  = { 1, 1, 1, 0.03 },
	rowHi   = { 0.22, 0.82, 0.80, 0.12 },
	section = { 0.20, 0.52, 0.58, 0.22 },
	text    = { 0.86, 0.88, 0.92 },
	dim     = { 0.45, 0.47, 0.53 },
	blue    = { 0.36, 0.62, 1.0 },   -- in bag
	amber   = { 1.00, 0.85, 0.12 },  -- equipped (bright gold so it doesn't look brown when blended)
	red     = { 0.86, 0.20, 0.20 },  -- dup
}

-- compare-mode check colours
-- Compare-mode check colours. The cells are now FontStrings (not the green
-- ReadyCheck texture), so we can use truly distinct hues - cyan vs green vs
-- white reads instantly, unlike the old two-shades-of-green scheme.
local C_BOTH = { 1, 1, 1 }            -- both parties have it (white)
local C_THEM = { 0.30, 0.85, 1.00 }   -- only the other person has it (cyan)
local C_ME   = { 0.40, 1.00, 0.40 }   -- only I have it (green)

-- flat 1px backdrop helper
local function flat(f, bg, border)
	f:SetBackdrop({ bgFile = WHITE_TEX, edgeFile = WHITE_TEX, edgeSize = 1 })
	if bg then f:SetBackdropColor(unpack(bg)) end
	if border then f:SetBackdropBorderColor(unpack(border)) end
end

-- affix icon cache (persisted in AffixDexDB.icons; learned spells supply the icon)
local iconCache = {}
function setAffixIcon(affix, tex)  -- assigns to the upvalue forward-declared near the top
	if affix and tex and tex ~= "" then
		iconCache[affix] = tex
		local d = ADB(); d.icons = d.icons or {}; d.icons[affix] = tex
	end
end
local function getAffixIcon(affix)
	if iconCache[affix] then return iconCache[affix] end
	local d = ADB()
	if d.icons and d.icons[affix] then iconCache[affix] = d.icons[affix]; return d.icons[affix] end
	return PLACEHOLDER_ICON
end

local function Refresh()
  if not frame then return end
  displayList = buildDisplayList()
  local maxCols = computeMaxRankCols()

  for c = 1, #headerCells do
    local cell = headerCells[c]
    if c <= maxCols then cell:SetText(NUM_TO_ROMAN[c]); cell:Show() else cell:Hide() end
  end

  local total = #displayList
  local offset = FauxScrollFrame_GetOffset(scroll)
  FauxScrollFrame_Update(scroll, total, NUM_ROWS, ROW_HEIGHT)

  local src = viewSource()
  local my = DB().learned
  local comparing = (src ~= my)

  local learnedCount, affixCount = 0, 0
  for _, entry in ipairs(displayList) do
    if entry.affix then
      affixCount = affixCount + 1
      if isLearnedIn(src, entry.affix) then learnedCount = learnedCount + 1 end
    end
  end

  for i = 1, NUM_ROWS do
    local row = rowFrames[i]
    local entry = displayList[i + offset]
    if not entry then
      row:Hide()
    else
      row:Show()
      row.hi:Hide()
      if entry.header then
        row.affix = nil
        row.stripe:Hide(); row.section:Show(); row.icon:Hide()
        row.name:ClearAllPoints(); row.name:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.name:SetText(entry.text)
        row.name:SetTextColor(unpack(PAL.teal))
        for c = 1, #row.cells do row.cells[c]:Hide(); row.equip[c]:Hide(); row.dupNum[c]:Hide(); row.bagBox[c]:Hide() end
      else
        row.affix = entry.affix
        row.ranked = entry.ranked
        row.section:Hide()
        if ((i + offset) % 2) == 0 then row.stripe:Show() else row.stripe:Hide() end

        local theyHave = isLearnedIn(src, entry.affix)
        local iHave = isLearnedIn(my, entry.affix)
        local neither = comparing and not theyHave and not iHave
        local present = theyHave or (not comparing and (isEquipped(entry.affix) or bagHasAffix(entry.affix)))

        row.icon:Show()
        row.icon:SetTexture(getAffixIcon(entry.affix))
        row.icon:SetDesaturated(not present)

        row.name:ClearAllPoints(); row.name:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
        row.name:SetText(entry.affix)
        if theyHave or iHave then row.name:SetTextColor(unpack(PAL.text)) else row.name:SetTextColor(unpack(PAL.dim)) end

        for c = 1, #row.cells do
          local cell = row.cells[c]
          local slot, they, mine
          if entry.ranked then
            slot = (c <= maxCols)
            local roman = NUM_TO_ROMAN[c]
            they = slot and hasRankIn(src, entry.affix, roman)
            mine = slot and hasRankIn(my, entry.affix, roman)
          else
            slot = (c == 1)
            they = slot and theyHave
            mine = slot and iHave
          end

          local eqp, inBag
          if entry.ranked then
            eqp = slot and rankEquipped(entry.affix, NUM_TO_ROMAN[c])
            inBag = slot and bagHasRank(entry.affix, NUM_TO_ROMAN[c])
          else
            eqp = (c == 1) and isEquipped(entry.affix)
            inBag = (c == 1) and bagHasAffix(entry.affix)
          end
          if eqp then
            local nn = equipCountAt(entry.affix, entry.ranked and NUM_TO_ROMAN[c] or nil)
            row.equip[c]:Show()
            if nn > 1 then
              row.equip[c]:SetTexture(unpack(PAL.red)); row.equip[c]:SetAlpha(0.5)
              row.dupNum[c]:SetText(nn); row.dupNum[c]:Show()
            else
              row.equip[c]:SetTexture(unpack(PAL.amber)); row.equip[c]:SetAlpha(0.5)
              row.dupNum[c]:Hide()
            end
          else
            row.equip[c]:Hide(); row.dupNum[c]:Hide()
          end
          -- The blue box always reflects "in your bags right now", regardless
          -- of whether the affix is learned. The check on top conveys learned
          -- state independently.
          if inBag then row.bagBox[c]:Show() else row.bagBox[c]:Hide() end

          if not slot then
            cell:Hide()
          elseif not comparing then
            if they then
              cell:Show(); cell:SetText("\226\136\154"); cell:SetTextColor(unpack(C_BOTH))
            elseif inBag then
              cell:Show(); cell:SetText("\226\136\154"); cell:SetTextColor(unpack(C_ME))
            else
              cell:Hide()
            end
          elseif neither then
            if c == 1 then cell:Show(); cell:SetText("\195\151"); cell:SetTextColor(1, 0.3, 0.3) else cell:Hide() end
          elseif they and mine then
            cell:Show(); cell:SetText("\226\136\154"); cell:SetTextColor(unpack(C_BOTH))
          elseif they then
            cell:Show(); cell:SetText("\226\136\154"); cell:SetTextColor(unpack(C_THEM))
          elseif mine then
            cell:Show(); cell:SetText("\226\136\154"); cell:SetTextColor(unpack(C_ME))
          else
            cell:Hide()
          end
        end
      end
    end
  end

  if frame.statusBar then
    -- Title line: who we're viewing + count summary (+ snapshot age if offline).
    if comparing then
      local snapNote = ""
      if not partyAffixes[currentView] then
        local snap = ADB().snapshots[currentView]
        if snap and snap.t and snap.t > 0 and date then
          snapNote = "  |cff888888(saved " .. date("%m/%d %H:%M", snap.t) .. ")|r"
        end
      end
      frame.statusBar.title:SetText(("vs |cffffd200%s|r  %d / %d affixes%s"):format(currentView, learnedCount, affixCount, snapNote))
    else
      frame.statusBar.title:SetText(("You  %d / %d affixes"):format(learnedCount, affixCount))
    end

    -- Legend row: actual colored swatches with name-aware labels (no pronouns).
    -- Glyph entries (g="\226\136\154" √ / "\195\151" ×) match the grid's check
    -- and X cells; box entries (b=true) match the highlight boxes (equip/bag/dup).
    local CHECK, NEITHER_X = "\226\136\154", "\195\151"
    local legends
    if comparing then
      legends = {
        { g = CHECK,     color = C_BOTH,        label = "Both have it" },
        { g = CHECK,     color = C_THEM,        label = currentView .. " only" },
        { g = CHECK,     color = C_ME,          label = "You only" },
        { g = NEITHER_X, color = {1, 0.3, 0.3}, label = "Neither" },
        { b = true,      color = PAL.amber,     label = "You equip" },
      }
    else
      legends = {
        { g = CHECK, color = C_BOTH,    label = "Learned" },
        { b = true,  color = PAL.blue,  label = "In bag" },
        { b = true,  color = PAL.amber, label = "Equipped" },
        { b = true,  color = PAL.red,   label = "Dup" },
      }
    end
    local x = 0
    for i, slot in ipairs(frame.statusBar.legend) do
      local entry = legends[i]
      if entry then
        if entry.g then
          slot.swatch:Hide()
          slot.glyph:Show()
          slot.glyph:SetText(entry.g)
          slot.glyph:SetTextColor(entry.color[1], entry.color[2], entry.color[3])
        else
          slot.glyph:Hide()
          slot.swatch:Show()
          slot.swatch:SetVertexColor(entry.color[1], entry.color[2], entry.color[3], 0.95)
        end
        slot.label:SetText(entry.label)
        slot:SetWidth(slot.label:GetStringWidth() + 20)
        slot:ClearAllPoints()
        slot:SetPoint("BOTTOMLEFT", frame.statusBar, "BOTTOMLEFT", x, 0)
        x = x + slot:GetWidth() + 8
        slot:Show()
      else
        slot:Hide()
      end
    end
  end
end

-- flat "pill" button styling for the View bar
local function pillSelected(b, on)
  if on then
    -- active: dark teal fill + teal border + white text (readable, clearly selected)
    b:SetBackdropColor(0.10, 0.26, 0.28, 1); b:SetBackdropBorderColor(unpack(PAL.teal)); b.text:SetTextColor(1, 1, 1)
  else
    b:SetBackdropColor(0.12, 0.13, 0.17, 1); b:SetBackdropBorderColor(0.20, 0.22, 0.28, 1); b.text:SetTextColor(unpack(PAL.text))
  end
end

local function makePill(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(18)
  flat(b, { 0.12, 0.13, 0.17, 1 }, { 0.20, 0.22, 0.28, 1 })
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("CENTER")
  b:SetFontString(b.text)
  b:SetScript("OnEnter", function(self) if self:IsEnabled() == 1 and self.viewName ~= currentView then self:SetBackdropBorderColor(unpack(PAL.teal)) end end)
  b:SetScript("OnLeave", function(self) if self.viewName ~= currentView then self:SetBackdropBorderColor(0.20, 0.22, 0.28, 1) end end)

  -- remove (x) badge, shown only for saved/offline players (set up in CreateUI)
  local rm = CreateFrame("Button", nil, b)
  rm:SetWidth(13); rm:SetHeight(13)
  rm:SetPoint("RIGHT", b, "RIGHT", -2, 0)
  rm.tex = rm:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  rm.tex:SetPoint("CENTER")
  rm.tex:SetText("x")
  rm.tex:SetTextColor(0.5, 0.5, 0.55)
  rm:SetScript("OnEnter", function(self) self.tex:SetTextColor(0.95, 0.3, 0.3) end)
  rm:SetScript("OnLeave", function(self) self.tex:SetTextColor(0.5, 0.5, 0.55) end)
  rm:Hide()
  b.removeBtn = rm
  return b
end

-- tooltip when hovering an affix row
local function RowTooltip(row)
  local affix = row.affix
  if not affix then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(affix, PAL.teal[1], PAL.teal[2], PAL.teal[3])
  local my = DB().learned
  if row.ranked then
    local L, E, B = {}, {}, {}
    for c = 1, #NUM_TO_ROMAN do
      local r = NUM_TO_ROMAN[c]
      if hasRankIn(my, affix, r) then L[#L + 1] = r end
      if rankEquipped(affix, r) then E[#E + 1] = r end
      if bagHasRank(affix, r) then B[#B + 1] = r end
    end
    GameTooltip:AddLine("Learned: " .. (#L > 0 and table.concat(L, ", ") or "none"), PAL.text[1], PAL.text[2], PAL.text[3])
    if #E > 0 then GameTooltip:AddLine("Equipped: " .. table.concat(E, ", "), PAL.amber[1], PAL.amber[2], PAL.amber[3]) end
    if #B > 0 then GameTooltip:AddLine("In bags: " .. table.concat(B, ", "), PAL.blue[1], PAL.blue[2], PAL.blue[3]) end
  else
    GameTooltip:AddLine(isLearned(affix) and "Learned" or "Not learned", PAL.text[1], PAL.text[2], PAL.text[3])
    if isEquipped(affix) then GameTooltip:AddLine("Equipped", PAL.amber[1], PAL.amber[2], PAL.amber[3]) end
    if bagHasAffix(affix) then GameTooltip:AddLine("In bags", PAL.blue[1], PAL.blue[2], PAL.blue[3]) end
  end
  if currentView ~= "You" then
    GameTooltip:AddLine(currentView .. ": " .. (isLearnedIn(viewSource(), affix) and "has it" or "does not have it"), 0.75, 0.75, 0.8)
  end
  -- Spell description from the server (cached lazily). For ranked affixes the
  -- cache picks the highest learned tier (or highest tier seen) so the text
  -- describes the strongest version of the affix you know.
  if affixDescriptionsStale then buildAffixDescriptionCache() end
  if affixDescriptions and affixDescriptions[affix] and affixDescriptions[affix].raw then
    GameTooltip:AddLine(" ")  -- spacer
    GameTooltip:AddLine(affixDescriptions[affix].raw, 0.85, 0.85, 0.95, true)  -- wrap=true
  end
  GameTooltip:Show()
end

-- tooltip for a specific rank cell: which item(s) carry this affix at this rank
local function CellTooltip(anchor, affix, roman)
  if not affix then return false end
  local key = affix .. "@" .. (roman or "W")
  local eqL, bagL = equippedItems[key], bagItems[key]
  local learnedThis = (roman and hasRankIn(DB().learned, affix, roman)) or (not roman and isLearnedIn(DB().learned, affix))
  if not (eqL or bagL or learnedThis) then return false end
  GameTooltip:SetOwner(anchor, "ANCHOR_RIGHT")
  GameTooltip:AddLine(affix .. (roman and (" " .. roman) or ""), PAL.teal[1], PAL.teal[2], PAL.teal[3])
  if eqL then
    GameTooltip:AddLine("Equipped:", PAL.amber[1], PAL.amber[2], PAL.amber[3])
    for _, l in ipairs(eqL) do GameTooltip:AddLine("  " .. l) end
  end
  if bagL then
    GameTooltip:AddLine("In bags:", PAL.blue[1], PAL.blue[2], PAL.blue[3])
    for _, l in ipairs(bagL) do GameTooltip:AddLine("  " .. l) end
  end
  if learnedThis and not eqL and not bagL then
    GameTooltip:AddLine("Learned (no item carried)", PAL.text[1], PAL.text[2], PAL.text[3])
  end
  GameTooltip:Show()
  return true
end

-- (Re)label the "View:" buttons: You + live party, then saved-snapshot players
-- matching the search box (most-recently-seen first), capped at the button count.
local function updateMembers()
  if not frame or not frame.memberButtons then return end
  local q = searchText or ""

  local names = { "You" }
  local inList = { ["You"] = true }
  local livePartySet = {}
  local n = (GetNumPartyMembers and GetNumPartyMembers()) or 0
  for i = 1, n do
    local nm = UnitName("party" .. i)
    if nm then
      livePartySet[nm] = true
      if not inList[nm] then names[#names + 1] = nm; inList[nm] = true end
    end
  end

  -- saved tabs: shown when they match the search; when not searching, hide any the
  -- user has closed (their snapshot stays in the backlog, findable via search).
  local closed = ADB().closedTabs
  local saved = {}
  for nm, snap in pairs(ADB().snapshots) do
    if not inList[nm] and matchesSearch(nm, snap.learned, q) and (q ~= "" or not closed[nm]) then
      saved[#saved + 1] = { nm = nm, t = snap.t or 0 }
    end
  end
  table.sort(saved, function(a, b) return a.t > b.t end)

  local cap = #frame.memberButtons
  for _, sv in ipairs(saved) do
    if #names >= cap then break end
    names[#names + 1] = sv.nm; inList[sv.nm] = true
  end

  if currentView ~= "You" and not haveData(currentView) then currentView = "You" end

  local x = 50
  for i, b in ipairs(frame.memberButtons) do
    local nm = names[i]
    if nm then
      b.viewName = nm
      -- removable = a saved/offline player (not You, not currently in your party)
      local removable = (nm ~= "You") and not livePartySet[nm] and ADB().snapshots[nm] ~= nil
      b:SetText((nm ~= "You" and mismatch[nm] and not haveData(nm)) and (nm .. "!") or nm)
      b:SetWidth(math.max(34, b:GetFontString():GetStringWidth() + 16 + (removable and 12 or 0)))
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -60)
      x = x + b:GetWidth() + 4
      pillSelected(b, nm == currentView)
      if haveData(nm) then b:Enable() else b:Disable(); b.text:SetTextColor(unpack(PAL.dim)) end
      if removable then b.removeBtn:Show() else b.removeBtn:Hide() end
      b:Show()
    else
      b:Hide()
    end
  end
end

-- Builds the saved-players dropdown (respects the search filter), most-recent first.
local SAVED_DD_CAP = 25
local function SavedDD_Init(self, level)
	local list = {}
	for nm, snap in pairs(ADB().snapshots) do
		if matchesSearch(nm, snap.learned, searchText or "") then
			list[#list + 1] = { nm = nm, t = snap.t or 0 }
		end
	end
	table.sort(list, function(a, b) return a.t > b.t end)

	if #list == 0 then
		local info = UIDropDownMenu_CreateInfo()
		info.text = (searchText ~= "" and "(no matches)") or "(no saved players)"
		info.disabled = true; info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)
		return
	end

	local shown = math.min(#list, SAVED_DD_CAP)
	for i = 1, shown do
		local s = list[i]
		local datestr = (s.t > 0 and date) and date("%m/%d", s.t) or ""
		local info = UIDropDownMenu_CreateInfo()
		info.text = s.nm .. (datestr ~= "" and ("  |cff888888" .. datestr .. "|r") or "")
		info.notCheckable = true
		info.func = function()
			currentView = s.nm
			ADB().closedTabs[s.nm] = nil   -- re-open as a tab
			if frame.savedBtn then frame.savedBtn.text:SetText(s.nm) end
			CloseDropDownMenus()
			Refresh()
			updateMembers()
		end
		UIDropDownMenu_AddButton(info, level)
	end
	if #list > shown then
		local info = UIDropDownMenu_CreateInfo()
		info.text = ("\226\128\166 +%d more (type to narrow)"):format(#list - shown)
		info.disabled = true; info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)
	end
end

local function CreateUI()
  if frame then return end

  frame = CreateFrame("Frame", "AffixDexFrame", UIParent)
  frame:SetWidth(470)
  frame:SetHeight(462)
  frame:SetPoint("CENTER")
  flat(frame, PAL.bg, PAL.border)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:SetFrameStrata("HIGH")
  frame:Hide()

  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
  header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
  header:SetHeight(26)
  flat(header, PAL.header, { 0, 0, 0, 0 })
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function() frame:StartMoving() end)
  header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

  local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", header, "LEFT", 12, 0)
  title:SetText("AffixDex")
  title:SetTextColor(unpack(PAL.teal))

  local accent = frame:CreateTexture(nil, "ARTWORK")
  accent:SetTexture(WHITE_TEX)
  accent:SetHeight(2)
  accent:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
  accent:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
  accent:SetGradientAlpha("HORIZONTAL", PAL.teal[1], PAL.teal[2], PAL.teal[3], 1, PAL.purple[1], PAL.purple[2], PAL.purple[3], 1)

  local close = CreateFrame("Button", nil, header)
  close:SetWidth(22); close:SetHeight(22)
  close:SetPoint("RIGHT", header, "RIGHT", -6, 0)
  close.text = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  close.text:SetPoint("CENTER")
  close.text:SetText("\195\151")  -- multiplication sign (x)
  close.text:SetTextColor(unpack(PAL.dim))
  close:SetScript("OnEnter", function(self) self.text:SetTextColor(0.95, 0.35, 0.35) end)
  close:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(PAL.dim)) end)
  close:SetScript("OnClick", function() frame:Hide() end)

  frame.searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.searchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -37)
  frame.searchLabel:SetText("Search")
  frame.searchLabel:SetTextColor(unpack(PAL.dim))

  frame.searchBox = CreateFrame("EditBox", "AffixDexSearchBox", frame, "InputBoxTemplate")
  frame.searchBox:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X + 50, -33)
  frame.searchBox:SetWidth(120)
  frame.searchBox:SetHeight(18)
  frame.searchBox:SetAutoFocus(false)
  for _, region in ipairs({ frame.searchBox:GetRegions() }) do
    if region.GetObjectType and region:GetObjectType() == "Texture" then region:SetTexture(nil) end
  end
  flat(frame.searchBox, { 0.10, 0.11, 0.14, 1 }, PAL.border)
  frame.searchBox:SetTextInsets(6, 6, 0, 0)
  frame.searchBox:SetTextColor(unpack(PAL.text))
  frame.searchBox:SetScript("OnTextChanged", function(self)
    searchText = (self:GetText() or ""):lower()
    updateMembers()
  end)
  frame.searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
  frame.searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  -- hidden dropdown engine (drives the menu); the visible control is a flat button
  frame.savedMenu = CreateFrame("Frame", "AffixDexSavedMenu", frame, "UIDropDownMenuTemplate")
  frame.savedMenu:Hide()
  UIDropDownMenu_Initialize(frame.savedMenu, SavedDD_Init)

  frame.savedBtn = CreateFrame("Button", nil, frame)
  frame.savedBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X + 198, -33)
  frame.savedBtn:SetWidth(116); frame.savedBtn:SetHeight(18)
  flat(frame.savedBtn, { 0.12, 0.13, 0.17, 1 }, { 0.20, 0.22, 0.28, 1 })
  frame.savedBtn.text = frame.savedBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.savedBtn.text:SetPoint("LEFT", frame.savedBtn, "LEFT", 6, 0)
  frame.savedBtn.text:SetPoint("RIGHT", frame.savedBtn, "RIGHT", -16, 0)
  frame.savedBtn.text:SetJustifyH("LEFT")
  frame.savedBtn.text:SetText("Saved")
  frame.savedBtn.text:SetTextColor(unpack(PAL.text))
  local ddArrow = frame.savedBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ddArrow:SetPoint("RIGHT", frame.savedBtn, "RIGHT", -5, -1)
  ddArrow:SetText("\226\150\188")
  ddArrow:SetTextColor(unpack(PAL.teal))
  frame.savedBtn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(PAL.teal)) end)
  frame.savedBtn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.20, 0.22, 0.28, 1) end)
  frame.savedBtn:SetScript("OnClick", function(self) ToggleDropDownMenu(1, nil, frame.savedMenu, self, 0, 0) end)

  frame.memberLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.memberLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -63)
  frame.memberLabel:SetText("View")
  frame.memberLabel:SetTextColor(unpack(PAL.dim))

  frame.memberButtons = {}
  for i = 1, 8 do
    local b = makePill(frame)
    b:SetScript("OnClick", function(self)
      if self.viewName and self:IsEnabled() == 1 then
        currentView = self.viewName
        ADB().closedTabs[self.viewName] = nil   -- clicking (re)opens it as a tab
        Refresh(); updateMembers()
      end
    end)
    b.removeBtn:SetScript("OnClick", function()
      local nm = b.viewName
      if nm and nm ~= "You" then
        ADB().closedTabs[nm] = true   -- hide the tab; snapshot stays searchable
        if currentView == nm then currentView = "You" end
        Refresh(); updateMembers()
      end
    end)
    frame.memberButtons[i] = b
  end

  local colHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  colHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X + 2, -89)
  colHeader:SetText("Affix")
  colHeader:SetTextColor(unpack(PAL.dim))

  headerCells = {}
  for c = 1, #NUM_TO_ROMAN do
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", frame, "TOPLEFT", ROW_X + COL_START + (c - 1) * COL_WIDTH + COL_WIDTH / 2, -91)
    fs:SetTextColor(unpack(PAL.dim))
    fs:Hide()
    headerCells[c] = fs
  end

  local underline = frame:CreateTexture(nil, "ARTWORK")
  underline:SetTexture(WHITE_TEX)
  underline:SetHeight(1)
  underline:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -103)
  underline:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -ROW_X, -103)
  underline:SetVertexColor(PAL.border[1], PAL.border[2], PAL.border[3], 0.45)

  scroll = CreateFrame("ScrollFrame", "AffixDexScroll", frame, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -107)
  scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 34)
  scroll:SetScript("OnVerticalScroll", function(self, off)
    FauxScrollFrame_OnVerticalScroll(self, off, ROW_HEIGHT, Refresh)
  end)

  -- flatten the scrollbar: hide the arrow buttons, teal thumb
  local sb = _G["AffixDexScrollScrollBar"]
  if sb then
    local up = _G["AffixDexScrollScrollBarScrollUpButton"]
    local down = _G["AffixDexScrollScrollBarScrollDownButton"]
    if up then up:Hide() end
    if down then down:Hide() end
    sb:SetWidth(6)
    sb:SetThumbTexture(WHITE_TEX)
    local th = sb:GetThumbTexture()
    if th then th:SetVertexColor(PAL.teal[1], PAL.teal[2], PAL.teal[3], 0.6); th:SetWidth(6); th:SetHeight(36) end
  end

  rowFrames = {}
  for i = 1, NUM_ROWS do
    local row = CreateFrame("Frame", nil, frame)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", ROW_X, -107 - (i - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", frame, "RIGHT", -28, 0)
    row:EnableMouse(true)

    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetTexture(WHITE_TEX); row.stripe:SetAllPoints(row); row.stripe:SetVertexColor(unpack(PAL.stripe)); row.stripe:Hide()

    row.section = row:CreateTexture(nil, "BACKGROUND")
    row.section:SetTexture(WHITE_TEX); row.section:SetAllPoints(row); row.section:SetVertexColor(unpack(PAL.section)); row.section:Hide()

    row.hi = row:CreateTexture(nil, "BACKGROUND")
    row.hi:SetTexture(WHITE_TEX); row.hi:SetAllPoints(row); row.hi:SetVertexColor(unpack(PAL.rowHi)); row.hi:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(ICON_SIZE); row.icon:SetHeight(ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:Hide()

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", NAME_X, 0)
    row.name:SetWidth(COL_START - NAME_X - 6)
    row.name:SetJustifyH("LEFT")

    row.equip = {}
    for c = 1, #NUM_TO_ROMAN do
      local hl = row:CreateTexture(nil, "ARTWORK")
      hl:SetTexture(unpack(PAL.amber)); hl:SetAlpha(0.5)
      hl:SetWidth(COL_WIDTH - 6); hl:SetHeight(ROW_HEIGHT - 4)
      hl:SetPoint("CENTER", row, "LEFT", COL_START + (c - 1) * COL_WIDTH + COL_WIDTH / 2, 0)
      hl:Hide()
      row.equip[c] = hl
    end

    -- blue box behind the check = item is in your bags but not learned
    row.bagBox = {}
    for c = 1, #NUM_TO_ROMAN do
      local bx = row:CreateTexture(nil, "ARTWORK")
      bx:SetTexture(unpack(PAL.blue)); bx:SetAlpha(0.35)
      bx:SetWidth(COL_WIDTH - 6); bx:SetHeight(ROW_HEIGHT - 4)
      bx:SetPoint("CENTER", row, "LEFT", COL_START + (c - 1) * COL_WIDTH + COL_WIDTH / 2, 0)
      bx:Hide()
      row.bagBox[c] = bx
    end

    -- Cells are FontStrings (not Textures) so we can tint them freely - the
    -- ReadyCheck-Ready texture is inherently green and vertex-coloring it can
    -- only make shades of green, making "them" and "you" hard to tell apart.
    row.cells = {}
    for c = 1, #NUM_TO_ROMAN do
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
      fs:SetPoint("CENTER", row, "LEFT", COL_START + (c - 1) * COL_WIDTH + COL_WIDTH / 2, 1)
      fs:Hide()
      row.cells[c] = fs
    end

    row.dupNum = {}
    for c = 1, #NUM_TO_ROMAN do
      local fs = row:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
      fs:SetPoint("BOTTOMRIGHT", row, "BOTTOMLEFT", COL_START + (c - 1) * COL_WIDTH + COL_WIDTH - 2, 1)
      fs:SetTextColor(unpack(PAL.red))
      fs:Hide()
      row.dupNum[c] = fs
    end

    -- per-cell hover regions: hovering a rank check shows the item(s) carrying it
    row.cellHover = {}
    for c = 1, #NUM_TO_ROMAN do
      local h = CreateFrame("Button", nil, row)
      h:SetWidth(COL_WIDTH); h:SetHeight(ROW_HEIGHT)
      h:SetPoint("CENTER", row, "LEFT", COL_START + (c - 1) * COL_WIDTH + COL_WIDTH / 2, 0)
      h.col = c
      h:SetScript("OnEnter", function(self)
        local r = self:GetParent()
        if not r.affix then return end
        local roman
        if r.ranked then roman = NUM_TO_ROMAN[self.col]
        elseif self.col == 1 then roman = nil
        else return end
        r.hi:Show()
        CellTooltip(self, r.affix, roman)
      end)
      h:SetScript("OnLeave", function(self) self:GetParent().hi:Hide(); GameTooltip:Hide() end)
      row.cellHover[c] = h
    end

    row:SetScript("OnEnter", function(self) if self.affix then self.hi:Show(); RowTooltip(self) end end)
    row:SetScript("OnLeave", function(self) self.hi:Hide(); GameTooltip:Hide() end)

    rowFrames[i] = row
  end

  -- Two-tier status area: title line on top, swatch+label legend underneath.
  -- The legend uses real colored swatches (not just colored text) and shows the
  -- actual player name in compare mode, so colors clearly map to people.
  frame.statusBar = CreateFrame("Frame", nil, frame)
  frame.statusBar:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  ROW_X, 8)
  frame.statusBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -90, 8)
  frame.statusBar:SetHeight(30)

  frame.statusBar.title = frame.statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.statusBar.title:SetPoint("TOPLEFT", frame.statusBar, "TOPLEFT", 0, 0)
  frame.statusBar.title:SetJustifyH("LEFT")

  -- Pool of legend slots (swatch + label pairs). Refresh fills them.
  -- Each legend slot has BOTH a box swatch AND a glyph FontString. Refresh
  -- shows whichever one matches the entry: glyphs for the check/X cell states
  -- (Both / Them only / You only / Neither) so they look exactly like the grid;
  -- box swatches for the highlight states (Equipped / In bag / Dup) since those
  -- ARE boxes in the grid.
  frame.statusBar.legend = {}
  for i = 1, 6 do
    local item = CreateFrame("Frame", nil, frame.statusBar)
    item:SetHeight(12)
    item.swatch = item:CreateTexture(nil, "ARTWORK")
    item.swatch:SetTexture(WHITE_TEX)
    item.swatch:SetPoint("CENTER", item, "LEFT", 5, 0)
    item.swatch:SetWidth(10); item.swatch:SetHeight(10)
    item.glyph = item:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    item.glyph:SetPoint("CENTER", item, "LEFT", 6, 1)
    item.label = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    item.label:SetPoint("LEFT", item, "LEFT", 14, 0)
    item.label:SetTextColor(unpack(PAL.text))
    item.swatch:Hide(); item.glyph:Hide()
    item:Hide()
    frame.statusBar.legend[i] = item
  end

  -- Kept as a back-compat alias for any code that referred to statusFS.
  statusFS = frame.statusBar.title

  local rescan = CreateFrame("Button", nil, frame)
  rescan:SetWidth(64); rescan:SetHeight(18)
  rescan:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -ROW_X, 9)
  flat(rescan, { 0.12, 0.13, 0.17, 1 }, PAL.border)
  rescan.text = rescan:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rescan.text:SetPoint("CENTER"); rescan.text:SetText("Rescan"); rescan.text:SetTextColor(unpack(PAL.text))
  rescan:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(unpack(PAL.teal)) end)
  rescan:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(unpack(PAL.border)) end)
  rescan:SetScript("OnClick", function() Scan(); scanEquipped(); scanBags(); Refresh() end)
end

-- ---------------------------------------------------------------------------
-- Bag scanning + bag-item highlighting
-- ---------------------------------------------------------------------------

-- Show/hide a blue glow on a bag button if its item carries an unlearned affix.
local function affixHLForButton(button, bag, slot)
	if not button then return end
	if not button.affixHL then
		local t = button:CreateTexture(nil, "OVERLAY")
		t:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		t:SetBlendMode("ADD")
		t:SetPoint("TOPLEFT", button, "TOPLEFT", -4, 4)
		t:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 4, -4)
		t:SetVertexColor(0.3, 0.6, 1.0)
		button.affixHL = t
	end
	local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
	if link and itemHasUnlearnedAffix(link) then button.affixHL:Show() else button.affixHL:Hide() end
end

-- (Re)apply highlights to one open container frame's buttons.
local function applyBagFrame(frameObj)
	if not frameObj or not frameObj.GetID then return end
	local bag = frameObj:GetID()
	local fname = frameObj:GetName()
	local size = frameObj.size or 0
	for i = 1, size do
		local slot = size - i + 1   -- Blizzard numbers item buttons in reverse
		affixHLForButton(_G[fname .. "Item" .. i], bag, slot)
	end
end

-- ElvUI replaces the default bags with its own buttons (frame.Bags[bagID][slotID]),
-- so hook its UpdateSlot too and refresh its open frames.
local elvB
local function setupElvUIBags()
	if elvB then return end
	local E = _G.ElvUI and _G.ElvUI[1]
	if not (E and E.GetModule) then return end
	local ok, mod = pcall(function() return E:GetModule("Bags", true) end)
	elvB = ok and mod or nil
	if elvB and elvB.UpdateSlot and hooksecurefunc then
		hooksecurefunc(elvB, "UpdateSlot", function(_, frame, bagID, slotID)
			local bag = frame and frame.Bags and frame.Bags[bagID]
			if bag and bag[slotID] then affixHLForButton(bag[slotID], bagID, slotID) end
		end)
	end
end

local function applyElvBags()
	if not elvB or not elvB.BagFrames then return end
	for _, bf in pairs(elvB.BagFrames) do
		if bf and bf.IsShown and bf:IsShown() and bf.Bags then
			for bagID, bag in pairs(bf.Bags) do
				if type(bag) == "table" and bag.numSlots then
					for slotID = 1, bag.numSlots do
						if bag[slotID] then affixHLForButton(bag[slotID], bagID, slotID) end
					end
				end
			end
		end
	end
end

function updateBagHighlights()
	for i = 1, (NUM_CONTAINER_FRAMES or 13) do
		local cf = _G["ContainerFrame" .. i]
		if cf and cf:IsShown() then applyBagFrame(cf) end
	end
	applyElvBags()
end

local bagsHooked = false
local function hookBags()
	if bagsHooked or not hooksecurefunc then return end
	bagsHooked = true
	-- re-apply highlights every time Blizzard repaints a bag frame
	hooksecurefunc("ContainerFrame_Update", applyBagFrame)
	setupElvUIBags()   -- and ElvUI's bags, if present
end

-- Scan bags: rebuild `bagAffixes`, announce unlearned affixes once, refresh UI.
function scanBags()
	local bags = {}
	local items = {}
	for bag = 0, 4 do
		local slots = (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
		for slot = 1, slots do
			local link = GetContainerItemLink and GetContainerItemLink(bag, slot)
			if link then
				local affix, rank, rankless = parseItemAffix(link)
				if affix then
					local e = bags[affix]
					if not e then e = {}; bags[affix] = e end
					local learnedThis
					if rankless then
						e.rankless = true
						learnedThis = isLearnedIn(DB().learned, affix)
					elseif rank then
						e.ranks = e.ranks or {}
						e.ranks[rank] = true
						learnedThis = hasRankIn(DB().learned, affix, rank)
					end
					local key = affix .. "@" .. (rank or "W")
					items[key] = items[key] or {}
					items[key][#items[key] + 1] = link
					if not learnedThis then
						if not notified[key] then
							notified[key] = true
							msg(("found |cff66ccffunlearned|r affix %s%s on %s"):format(
								affix, rank and (" " .. rank) or "", link))
						end
					end
				end
			end
		end
	end
	bagAffixes = bags
	bagItems = items
	updateBagHighlights()
	if frame and frame:IsShown() then Refresh() end
end

-- ---------------------------------------------------------------------------
-- Scan (defined here so it can call Refresh)
-- ---------------------------------------------------------------------------

function Scan()
	-- Pull the latest server-side affix list + learned state every scan, so any
	-- async updates from ProjectEbonhold are picked up immediately.
	refreshAffixCatalog()
	refreshLearnedFromServer()

	local found = 0
	forEachSpell(function(i, name, sub)
		local affix, rank, rankless = ParseSpellAsAffix(name, sub)
		if affix then
			recordLearned(affix, rank, rankless)
			if GetSpellTexture then setAffixIcon(affix, GetSpellTexture(i, BOOKTYPE)) end
			found = found + 1
		end
	end)
	return found
end

-- ---------------------------------------------------------------------------
-- Party sharing (addon comms)
-- ---------------------------------------------------------------------------

local PREFIX = "AffixDex"
local incoming = {}        -- reassembly buffers: [sender] = { total, parts, count }
local lastBroadcast = 0

-- Record a peer whose sharing protocol is incompatible with ours, and warn the
-- player once so they know to update.
local function noteMismatch(sender, ver)
	mismatch[sender] = ver
	if mismatchWarned[sender] ~= ver then
		mismatchWarned[sender] = ver
		local shown = (ver == "?") and "an incompatible version" or ("v" .. ver)
		msg(("|cffff8800%s|r is running %s of AffixDex, which can't share with yours (v%s). Update to the same release to share affixes."):format(sender, shown, VERSION))
	end
	if frame and frame:IsShown() then updateMembers() end
end

local function rankBitmask(e)
	local m = 0
	if e.ranks then
		for r in pairs(e.ranks) do
			local idx = ROMAN_INDEX[r]
			if idx then m = m + 2 ^ (idx - 1) end
		end
	end
	return m
end

-- Encode my learned affixes as "name=val;name=val;..."
--   val:  W = weapon (rankless),  A = ranked but rank unknown,  number = rank bitmask
local function buildPayload()
	local parts = {}
	for affix, e in pairs(DB().learned) do
		local val
		if e.rankless then
			val = "W"
		else
			local m = rankBitmask(e)
			if m > 0 then val = tostring(m)
			elseif e.any then val = "A" end
		end
		if val then parts[#parts + 1] = affix .. "=" .. val end
	end
	return table.concat(parts, ";")
end

local function parsePayload(s)
	local learned = {}
	for token in s:gmatch("[^;]+") do
		local name, val = token:match("^(.-)=(.+)$")
		if name and val and name ~= "" then
			if val == "W" then
				learned[name] = { rankless = true }
			elseif val == "A" then
				learned[name] = { any = true }
			else
				local m = tonumber(val)
				if m then
					local ranks = {}
					for idx = 1, #NUM_TO_ROMAN do
						if math.floor(m / (2 ^ (idx - 1))) % 2 == 1 then
							ranks[NUM_TO_ROMAN[idx]] = true
						end
					end
					learned[name] = { ranks = ranks }
				end
			end
		end
	end
	return learned
end

local function myChannel()
	if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
	if GetNumPartyMembers and GetNumPartyMembers() > 0 then return "PARTY" end
	return nil
end

local function SendMyData()
	local ch = myChannel()
	if not ch then return end
	local now = GetTime()
	if now - lastBroadcast < 1 then return end   -- throttle bursts
	lastBroadcast = now
	local payload = buildPayload()
	local CHUNK = 220
	local total = math.max(1, math.ceil(#payload / CHUNK))
	for i = 1, total do
		local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
		-- D|<protocol>|<version>|<seq>|<total>|<chunk>
		SendAddonMessage(PREFIX, "D|" .. PROTOCOL .. "|" .. VERSION .. "|" .. i .. "|" .. total .. "|" .. part, ch)
	end
end

local function RequestData()
	local ch = myChannel()
	-- REQ|<protocol>|<version>
	if ch then SendAddonMessage(PREFIX, "REQ|" .. PROTOCOL .. "|" .. VERSION, ch) end
end

local function OnAddonMessage(prefix, message, channel, sender)
	if prefix ~= PREFIX or not sender then return end
	if sender == UnitName("player") then return end

	-- All current messages are "<TYPE>|<protocol>|<version>|...". The protocol and
	-- version come first so they can always be read even if the rest of the format
	-- changes in a future protocol.
	local mtype, proto, ver, rest = message:match("^(%u+)|(%d+)|([^|]*)|?(.*)$")
	if not mtype then
		-- Doesn't fit the current format - if it looks like one of ours it's an
		-- older/incompatible protocol; flag the peer so the player knows to update.
		if message:match("^REQ") or message:match("^D|") then noteMismatch(sender, "?") end
		return
	end

	-- Interop is gated on PROTOCOL only - the display version may differ freely.
	if tonumber(proto) ~= PROTOCOL then
		return noteMismatch(sender, (ver ~= "" and ver) or "?")
	end

	if mtype == "REQ" then
		SendMyData()
		return
	elseif mtype ~= "D" then
		return
	end

	-- DATA payload: rest = "<seq>|<total>|<chunk>"
	local seq, total, chunk = rest:match("^(%d+)|(%d+)|(.*)$")
	if not seq then return end
	seq, total = tonumber(seq), tonumber(total)

	local inc = incoming[sender]
	if not inc or inc.total ~= total then
		inc = { total = total, parts = {}, count = 0 }
		incoming[sender] = inc
	end
	if not inc.parts[seq] then
		inc.parts[seq] = chunk
		inc.count = inc.count + 1
	end
	if inc.count >= total then
		local full = table.concat(inc.parts)
		incoming[sender] = nil
		local learned = parsePayload(full)
		partyAffixes[sender] = { learned = learned, t = GetTime() }
		saveSnapshot(sender, learned)   -- persist to the searchable backlog
		if frame and frame:IsShown() then
			updateMembers()
			Refresh()
		end
	end
end

local function Toggle()
	CreateUI()
	if frame:IsShown() then
		frame:Hide()
	else
		Scan()
		scanEquipped()
		scanBags()
		SendMyData()    -- share mine with the party
		RequestData()   -- ask the party for theirs
		updateMembers()
		Refresh()
		frame:Show()
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

-- NOTE: do NOT register "/affixdex" - on the Ebonhold client that command is
-- already taken (it opens the native affix book) and a client built-in cannot
-- be overridden by an addon, so it would never reach this handler.
SLASH_AFFIXDEX1 = "/adex"
SLASH_AFFIXDEX2 = "/affixtracker"
SlashCmdList["AFFIXDEX"] = function(arg)
	arg = trim(arg or ""):lower()
	local cmd, rest = arg:match("^(%S*)%s*(.*)$")

	if cmd == "scan" then
		local n = Scan()
		msg(("scanned spellbook, recognised %d affix spell(s)."):format(n))
		Refresh()
	elseif cmd == "tabs" then
		local numTabs = GetNumSpellTabs() or 0
		msg(("%d spellbook tab(s):"):format(numTabs))
		for t = 1, numTabs do
			local name, _, offset, num = GetSpellTabInfo(t)
			msg(("  tab %d: %s  (spells %d-%d)"):format(t, tostring(name), (offset or 0) + 1, (offset or 0) + (num or 0)))
		end
	elseif cmd == "tab" then
		local t = tonumber(rest)
		if not t then msg("usage: /affixdex tab <number>") return end
		local name, _, offset, num = GetSpellTabInfo(t)
		if not offset then msg("no such tab.") return end
		msg(("tab %d (%s):"):format(t, tostring(name)))
		for i = offset + 1, offset + num do
			local sn, ss = GetSpellName(i, BOOKTYPE)
			msg(("  [%d] %s%s"):format(i, tostring(sn), ss and ss ~= "" and ("  |cff888888(" .. ss .. ")|r") or ""))
		end
	elseif cmd == "gear" then
		msg("equipped affix scan (slot -> item -> detected affix):")
		local any = false
		for slot = 1, 19 do
			local link = GetInventoryItemLink("player", slot)
			if link then
				any = true
				local affix, rank, rankless = parseItemAffix(link)
				msg(("  [%d] %s  %s"):format(slot, link,
					affix and ("|cff40ff40" .. affix .. (rank and (" " .. rank) or "") .. (rankless and " (weapon)" or "") .. "|r")
						or "|cff888888(no affix detected)|r"))
			end
		end
		if not any then msg("  (nothing equipped read - GetInventoryItemLink returned nil for all slots)") end
	elseif cmd == "catalog" then
		-- Dump the current runtime affix catalog so you can verify what AffixDex sees.
		-- Dedupe by display name so alias keys (which point at the same canonical
		-- entry) don't show up as duplicates.
		local rk, wp, seenRk, seenWp = {}, {}, {}, {}
		for k, v in pairs(affixCanonical) do
			if affixWeapon[k] then
				if not seenWp[v] then seenWp[v] = true; wp[#wp + 1] = v end
			else
				if not seenRk[v] then seenRk[v] = true; rk[#rk + 1] = v end
			end
		end
		table.sort(rk); table.sort(wp)
		msg(("catalog source: |cff66ccff%s|r"):format(serverCatalogLoaded and "ProjectEbonhold (live)"
			or (AffixDexDB and AffixDexDB.serverCatalog and next(AffixDexDB.serverCatalog.ranked or {}) and "persisted")
			or "bundled fallback"))
		msg(("ranked (%d): |cffffffff%s|r"):format(#rk, table.concat(rk, ", ")))
		msg(("weapon (%d): |cffffffff%s|r"):format(#wp, table.concat(wp, ", ")))
	elseif cmd == "procs" then
		-- Dump the proc-text cache used for fixed-affix weapon detection.
		if affixProcDescriptionsStale then buildProcDescriptionCache() end
		if not affixProcDescriptions or not next(affixProcDescriptions) then
			msg("proc cache is empty (no ProjectEbonhold weapon-affix descriptions cached)")
		else
			local names = {}
			for k in pairs(affixProcDescriptions) do names[#names + 1] = k end
			table.sort(names)
			msg(("proc cache (%d entries):"):format(#names))
			for _, name in ipairs(names) do
				local d = affixProcDescriptions[name]
				msg(("  |cff66ccff%s|r  -> |cffaaaaaa%s|r"):format(name, d.normalized))
			end
		end
	elseif cmd == "resetcatalog" then
		-- Wipe the persisted catalog. Next refresh from ProjectEbonhold will
		-- rewrite it cleanly from the server.
		if AffixDexDB then AffixDexDB.serverCatalog = nil end
		for k in pairs(affixCanonical) do affixCanonical[k] = nil end
		for k in pairs(affixWeapon)    do affixWeapon[k]    = nil end
		seedFallbackAffixes()
		refreshAffixCatalog()
		msg("persisted catalog cleared; reseeded.")
		if frame and frame:IsShown() then Refresh() end
	elseif cmd == "cleardiscovered" or cmd == "clean" then
		-- purge auto-discovered affixes (e.g. old "Scroll of Stamina IV" false matches),
		-- then re-derive legit ones from the spellbook.
		local n = 0
		if type(AffixDexDB) == "table" and type(AffixDexDB.discovered) == "table" then
			for name in pairs(AffixDexDB.discovered) do affixCanonical[name:lower()] = nil; n = n + 1 end
			AffixDexDB.discovered = {}
		end
		for _, nm in ipairs(RANKED_AFFIXES) do affixCanonical[nm:lower()] = nm end
		for _, nm in ipairs(WEAPON_AFFIXES) do affixCanonical[nm:lower()] = nm end
		Scan()
		msg(("cleared %d discovered affix(es); re-scanned spellbook."):format(n))
		if frame and frame:IsShown() then Refresh() end
	elseif cmd == "" or cmd == "show" or cmd == "toggle" then
		Toggle()
	else
		msg("commands: /adex (toggle), scan, gear, catalog, procs, resetcatalog, cleardiscovered, tabs, tab <n>")
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("LEARNED_SPELL_IN_TAB")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("BAG_UPDATE")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
	if event == "PLAYER_LOGIN" then
		msg(("v%s loaded. Type |cffffff00/adex|r (or |cffffff00/affixtracker|r) to open."):format(VERSION))
		loadDiscovered()
		hookBags()
		hookTooltips()
		-- Migrate any legacy alias-spelled entries (e.g. "Block" -> "Shield Block")
		-- before we touch the displayed list.
		migrateAliases()
		-- Load the catalog we persisted from last session - this overrides the
		-- bundled fallback seed so the displayed list is already accurate even
		-- before the server response arrives.
		loadPersistedCatalog()
		applyAliases()  -- in case loadPersistedCatalog had nothing to load
		-- Ask ProjectEbonhold for its server-side affix catalog (when present).
		-- The response populates ExtractionService.learnedAffixes asynchronously,
		-- so we also refresh on every scan to pick it up once it arrives.
		if _G.ExtractionService and ExtractionService.RequestLearnedAffixes then
			pcall(ExtractionService.RequestLearnedAffixes)
		end
		refreshAffixCatalog()
		refreshLearnedFromServer()
		Scan()
		scanEquipped()
		scanBags()
	elseif event == "CHAT_MSG_ADDON" then
		OnAddonMessage(a1, a2, a3, a4)
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
		scanEquipped()
		if frame and frame:IsShown() then Refresh() end
	elseif event == "BAG_UPDATE" then
		scanBags()   -- rebuilds bag affixes, re-highlights bag items, refreshes UI
	elseif event == "PARTY_MEMBERS_CHANGED" then
		if frame and frame:IsShown() then updateMembers(); Refresh() end
		SendMyData()   -- let (new) members know what I have
	else
		-- SPELLS_CHANGED / LEARNED_SPELL_IN_TAB: pick up newly learned affixes
		Scan()
		scanBags()     -- learned-state changed -> refresh blue checks / bag highlights
		if frame and frame:IsShown() then Refresh() end
		SendMyData()   -- broadcast my updated affixes to the party
	end
end)
