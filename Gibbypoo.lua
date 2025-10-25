-- TotemSwap.lua (Turtle WoW 1.12)
-- Minimal Shaman relic swapper, mirroring your LibramSwap flow.
-- One toggle: /totemswap
-- Mapping is hard-coded:
--   • Earth/Frost/Flame Shock  → Totem of the Stonebreaker
--   • Lightning Bolt/Strike    → Totem of Crackling Thunder
-- Single global throttle: 1.45s

-- =====================
-- Locals / Aliases
-- =====================
local GetContainerNumSlots  = GetContainerNumSlots
local GetContainerItemLink  = GetContainerItemLink
local UseContainerItem      = UseContainerItem
local GetInventoryItemLink  = GetInventoryItemLink
local GetSpellName          = GetSpellName
local GetSpellCooldown      = GetSpellCooldown
local GetTime               = GetTime
local CursorHasItem         = CursorHasItem
local string_find           = string.find
local string_match          = string.match
local BOOKTYPE_SPELL        = BOOKTYPE_SPELL or "spell"

-- =====================
-- Config (hard-coded per request)
-- =====================
local TOTEM_SHOCK     = "Totem of the Stonebreaker"
local TOTEM_LIGHTNING = "Totem of Crackling Thunder"

-- Map spell base name → totem name
local TotemMap = {
  ["Earth Shock"]     = TOTEM_SHOCK,
  ["Frost Shock"]     = TOTEM_SHOCK,
  ["Flame Shock"]     = TOTEM_SHOCK,
  ["Lightning Bolt"]  = TOTEM_LIGHTNING,
  ["Lightning Strike"] = TOTEM_LIGHTNING,
}

-- Build watched names from the two hard-coded items
local WatchedNames = { [TOTEM_SHOCK] = true, [TOTEM_LIGHTNING] = true }

-- =====================
-- Internal State
-- =====================
local TotemSwapEnabled = false
local lastSwapTime     = 0
local SWAP_THROTTLE    = 1.45

-- Fast bag index for watched item names
local NameIndex   = {}  -- [itemName] = {bag=#, slot=#, link=...}

-- Safety: block swaps when vendor/bank/auction/trade/mail/quest/gossip is open
local function IsInteractionBusy()
  return (MerchantFrame and MerchantFrame:IsVisible())
      or (BankFrame and BankFrame:IsVisible())
      or (AuctionFrame and AuctionFrame:IsVisible())
      or (TradeFrame and TradeFrame:IsVisible())
      or (MailFrame and MailFrame:IsVisible())
      or (QuestFrame and QuestFrame:IsVisible())
      or (GossipFrame and GossipFrame:IsVisible())
end

-- =====================
-- Bag Index
-- =====================
local function BuildBagIndex()
  for k in pairs(NameIndex) do NameIndex[k] = nil end
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = 1, slots do
        local link = GetContainerItemLink(bag, slot)
        if link then
          local _, _, bracketName = string_find(link, "%[(.-)%]")
          if bracketName and WatchedNames[bracketName] then
            NameIndex[bracketName] = { bag = bag, slot = slot, link = link }
          end
        end
      end
    end
  end
end

local function HasItemEquipped(itemName)
  local link = GetInventoryItemLink("player", 18) -- relic slot
  return link and string_find(link, itemName, 1, true)
end

-- Returns bag,slot if found; nil otherwise. Uses cache & auto-rebuild if moved.
local function HasItemInBags(itemName)
  local ref = NameIndex[itemName]
  if ref then
    local current = GetContainerItemLink(ref.bag, ref.slot)
    if current and string_find(current, itemName, 1, true) then
      return ref.bag, ref.slot
    end
    -- moved; rebuild & try once more
    BuildBagIndex()
    ref = NameIndex[itemName]
    if ref then
      local verify = GetContainerItemLink(ref.bag, ref.slot)
      if verify and string_find(verify, itemName, 1, true) then
        return ref.bag, ref.slot
      end
    end
    return nil
  end
  -- slow path first encounter
  for bag = 0, 4 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = 1, slots do
        local link = GetContainerItemLink(bag, slot)
        if link then
          local _, _, bracketName = string_find(link, "%[(.-)%]")
          if bracketName and bracketName == itemName then
            NameIndex[itemName] = { bag = bag, slot = slot, link = link }
            return bag, slot
          end
        end
      end
    end
  end
  return nil
end

-- =====================
-- Rank-aware spell parsing & readiness (1.12 safe)
-- =====================
-- Split "Name(Rank X)" → base, "Rank X"; otherwise returns spec, nil
local function SplitNameAndRank(spec)
  if not spec then return nil, nil end
  local base, rnum = string_match(spec, "^(.-)%s*%(%s*[Rr][Aa][Nn][Kk]%s*(%d+)%s*%)%s*$")
  if base and rnum then
    return (string.gsub(base, "%s+$", "")), ("Rank " .. rnum)
  end
  return spec, nil
end

-- Accepts "Name" or "Name(Rank X)"; requires exact rank if provided
local function IsSpellReady(spec)
  local base, reqRank = SplitNameAndRank(spec)
  for i = 1, 300 do
    local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    if name == base and (not reqRank or (rank and rank == reqRank)) then
      local start, duration, enabled = GetSpellCooldown(i, BOOKTYPE_SPELL)
      if not start or not duration or enabled == 0 then return false end
      if start == 0 or duration == 0 then return true, 0, 0 end
      local remaining = (start + duration) - GetTime()
      return remaining <= 0, start, duration
    end
  end
  return false
end

-- =====================
-- Core equip with simple global throttle
-- =====================
local function EquipTotemForSpell(spellBase, itemName)
  -- Already wearing it?
  local equipped = GetInventoryItemLink("player", 18)
  if equipped and string_find(equipped, itemName, 1, true) then
    return false
  end

  -- Respect interaction windows to avoid mishaps
  if IsInteractionBusy() then
    return false
  end

  -- Global throttle
  local now = GetTime()
  if (now - lastSwapTime) < SWAP_THROTTLE then
    return false
  end

  local bag, slot = HasItemInBags(itemName)
  if bag and slot then
    if CursorHasItem and CursorHasItem() then return false end
    UseContainerItem(bag, slot)
    lastSwapTime = now
    return true
  end
  return false
end

local function ResolveTotemForSpell(spellBase)
  return TotemMap[spellBase]
end

-- =====================
-- Hooks (CastSpellByName / CastSpell)
-- =====================
local Original_CastSpellByName = CastSpellByName
function CastSpellByName(spec, bookType)
  if TotemSwapEnabled and spec then
    local base = SplitNameAndRank(spec)
    local totem = ResolveTotemForSpell(base)
    if totem and IsSpellReady(spec) then
      EquipTotemForSpell(base, totem)
    end
  end
  return Original_CastSpellByName(spec, bookType)
end

local Original_CastSpell = CastSpell
function CastSpell(spellIndex, bookType)
  if TotemSwapEnabled and bookType == BOOKTYPE_SPELL then
    local name, rank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
    if name then
      local totem = ResolveTotemForSpell(name)
      if totem then
        local spec = (rank and rank ~= "") and (name .. "(" .. rank .. ")") or name
        if IsSpellReady(spec) then
          EquipTotemForSpell(name, totem)
        end
      end
    end
  end
  return Original_CastSpell(spellIndex, bookType)
end

-- =====================
-- Events
-- =====================
local TotemSwapFrame = CreateFrame("Frame")
TotemSwapFrame:RegisterEvent("PLAYER_LOGIN")
TotemSwapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
TotemSwapFrame:RegisterEvent("BAG_UPDATE")

TotemSwapFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    BuildBagIndex()
  elseif event == "BAG_UPDATE" then
    BuildBagIndex()
  end
end)

-- =====================
-- Slash Command (single toggle)
-- =====================
SLASH_TOTEMSWAP1 = "/totemswap"
SlashCmdList["TOTEMSWAP"] = function()
  TotemSwapEnabled = not TotemSwapEnabled
  if TotemSwapEnabled then
    DEFAULT_CHAT_FRAME:AddMessage("TotemSwap ENABLED", 0, 1, 0)
  else
    DEFAULT_CHAT_FRAME:AddMessage("TotemSwap DISABLED", 1, 0, 0)
  end
end
