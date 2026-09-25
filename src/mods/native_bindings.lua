-- Single declarative translation boundary between planner semantics and native
-- Hades II identities. This table contains names and carrier descriptions only;
-- hook behavior, eligibility, planner owners, and runtime state stay with their
-- feature modules.
return {
    navigation = {
        logicalRoomAcquisitions = {
            InfernalContractBoon = true,
        },
        -- HealthFountainN in RoomDataN N_Hub ObstacleData.
        hubFountainObjectIds = { N_Hub = 664734 },
    },
    timeline = {
        encounterTraitOfferCarriers = {
            NPC_Artemis_01 = "Artemis",
            NPC_Artemis_Field_01 = "Artemis",
            NPC_Athena_01 = "Athena",
            NPC_Dionysus_01 = "Dionysus",
            NPC_Hades_Field_01 = "Hades",
        },
    },
    roomFeatures = {
        resolvedShopOptionNames = {
            WeaponUpgradeDropEarly = { WeaponUpgradeDrop = "WeaponUpgradeDrop" },
            WeaponUpgradeDropLate = { WeaponUpgradeDrop = "WeaponUpgradeDrop" },
            SpellDrop = { TalentDrop = "TalentDrop" },
        },
        shopOptionCarriers = {
            BoostedRandomLoot = {
                name = "RandomLoot",
                argsMarkers = { "AddBoostedAnimation", "BoonRaritiesOverride" },
            },
        },
        resourceFamilies = {
            Pickaxe = {
                successField = "PickaxePointSuccess",
                choicesField = "PickaxePointChoices",
                toolName = "ToolPickaxe2",
                exitFunction = "UsePickaxePointOnExit",
            },
            Exorcism = {
                successField = "ExorcismPointSuccess",
                choicesField = "ExorcismPointChoices",
                toolName = "ToolExorcismBook2",
                exitFunction = "UseExorcismPointOnExit",
            },
            Shovel = {
                successField = "ShovelPointSuccess",
                choicesField = "ShovelPointChoices",
                toolName = "ToolShovel2",
                exitFunction = "UseShovelPointOnExit",
            },
            Fishing = {
                successField = "FishingPointSuccess",
                choicesField = "FishingPointChoices",
                toolName = "ToolFishingRod2",
                exitFunction = "UseFishingPointOnExit",
            },
        },
        features = {
            stygianWell = { carrier = "roomField", key = "WellShop" },
            purgingPool = { carrier = "roomField", key = "SellTraitShop" },
            hermesShrine = { carrier = "roomField", key = "SurfaceShop" },
            keepsakeRack = { carrier = "obstacleUseFunction", key = "UseKeepsakeRack" },
            fountain = { carrier = "obstacleUseFunction", key = "UseHealthFountain" },
            shop = { carrier = "roomField", key = "StoreDataName" },
        },
    },
    conformance = {
        -- Armor depletion is outside the planner's state model. These NPC
        -- traits can disappear natively without invalidating modeled outcomes.
        disposableArmorTraits = {
            AgilityCostume = true,
            ManaCostume = true,
            VitalityCostume = true,
            HighArmorCostume = true,
            CastDamageCostume = true,
            IncomeCostume = true,
            SpellCostume = true,
            EscalatingCostume = true,
            BreakInvincibleArmorBoon = true,
            BreakExplosiveArmorBoon = true,
        },
        shrineUpgrades = {
            forfeit = "BoonSkipShrineUpgrade",
        },
        stygianWellTraits = {
            sparkUses = "TemporaryForcedSecretDoorTrait",
            yarnUses = "TemporaryBoonRarityTrait",
            hymnUses = "LimitedSwapBonusTrait",
            discountUses = "TemporaryDiscountTrait",
            emptySlotUses = "TemporaryEmptySlotDamageTrait",
            extendedUses = "ExtendedShopTrait",
        },
        keepsakeTraits = {
            timePiece = "GoldifyKeepsake",
            callingCard = "RarifyKeepsake",
            jeweledPom = "HadesAndPersephoneKeepsake",
            phial = "FountainRarityKeepsake",
            stone = "UnpickedBoonKeepsake",
            transcendentEmbryo = "RandomBlessingKeepsake",
            figurine = "BossMetaUpgradeKeepsake",
            figLeaf = "PersistentDionysusSkipKeepsake",
        },
    },
    keepsakeEffects = {
        equipContacts = {
            experimentalHammer = "GiveDurationHammer",
            jeweledPom = "GiveRandomHadesBoonAndBoostBoons",
            transcendentEmbryo = "ChaosBlessingBonus",
        },
    },
}
