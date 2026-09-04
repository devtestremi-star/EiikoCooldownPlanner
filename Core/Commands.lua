-- HealPlanner - Commands.lua
-- Commandes slash : /ecp (et alias /hp)
local addonName, HR = ...

SLASH_ECP1 = "/ecp"
SLASH_ECP2 = "/hp"

local function PrintHelp()
    HR:Print("Available commands:")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp config" .. HR.COLORS.RESET .. "  - opens the planning window")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp help" .. HR.COLORS.RESET .. "    - shows this help")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp toggle" .. HR.COLORS.RESET .. "  - enables/disables the addon")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp handshake" .. HR.COLORS.RESET .. " - asks the group who runs ECP, and in which version")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp stats" .. HR.COLORS.RESET .. "   - asks each group member for their own stats (armor, hp, versatility...)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp audit" .. HR.COLORS.RESET .. "   - lists spells still missing a damage / effects entry")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp macros" .. HR.COLORS.RESET .. "  - (re)creates the EHP_ macros (/yell for external CDs)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp devlog" .. HR.COLORS.RESET .. "  - dev log for debugging (show/on/off/clear)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp scan" .. HR.COLORS.RESET .. "    - capture zone + encounterID on each pull")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp gather" .. HR.COLORS.RESET .. "  - print each server timeline event live (on/off/status)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp devscan" .. HR.COLORS.RESET .. " - capture live boss timeline for data authoring (on/off/show/clear/copy/status)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp journal" .. HR.COLORS.RESET .. " - scans the OPEN Adventure Guide boss -> spellID/name list (no pull)")
    HR:Print("  " .. HR.COLORS.YELLOW .. "/ecp comms" .. HR.COLORS.RESET .. "   - probes YOUR OWN casts: which cooldown fields stay readable (on/off/all/status)")
end

local dispatch = {
    help = PrintHelp,
    [""] = function() HR.UI.Toggle() end,

    config = function() HR.UI.Toggle() end,
    show   = function() HR.UI.Toggle() end,

    toggle = function()
        HR.db.enabled = not HR.db.enabled
        HR:Print("Addon " .. (HR.db.enabled
            and (HR.COLORS.GREEN .. "enabled")
            or (HR.COLORS.RED .. "disabled")) .. HR.COLORS.RESET .. ".")
    end,

    -- Handshake du canal de synchro : qui, dans le groupe, fait tourner l'addon.
    -- Le code metier ne fait QUE publier l'evenement ; Core/Sync/Listeners.lua prend le relais.
    handshake = function()
        HR.EmitEvent(HR.EV.HANDSHAKE_REQUEST, { reason = "slash" })
    end,

    -- Collecte des stats du groupe. Meme discipline que handshake : le code metier ne fait
    -- QUE publier l'evenement, Core/Sync/Listeners.lua prend le relais.
    stats = function()
        HR.EmitEvent(HR.EV.STATS_REQUEST, { reason = "slash" })
    end,

    -- Etat de la saisie du modele de degats : quels sorts n'ont pas encore de chiffres.
    -- Les deux tables (Data/SpellDamage.lua, Data/SpellEffects.lua) vivent a cote de
    -- l'existant sans y etre reliees -- sans cette commande, un manque serait silencieux.
    audit = function()
        HR.PrintSpellDataAudit()
    end,

    whatsnew = function()
        if HR.UI and HR.UI.ShowWhatsNew then HR.UI.ShowWhatsNew() end
    end,

    macros = function()
        local n = HR.SetupMacros()
        if n == nil then
            HR:Print("Macros not possible in combat. Retry out of combat.")
        else
            HR:Print(("%d EHP_ macro(s) (re)created: /yell for external CDs."):format(n))
        end
    end,

    -- Journal de dev persistant (SavedVariable ECPDevLog). Workflow : /ecp devlog (ON),
    -- reproduire le bug, /reload, puis lecture du fichier SavedVariables. `show` = apercu chat.
    devlog = function(rest)
        rest = rest and rest:lower() or ""
        if rest == "show" then
            HR.DevLogShow(40)
        elseif rest == "clear" then
            HR.DevLogClear(); HR:Print("Dev log cleared.")
        elseif rest == "off" then
            HR.SetDevLog(false); HR:Print("Dev log " .. HR.COLORS.RED .. "OFF" .. HR.COLORS.RESET .. ".")
        elseif rest == "on" then
            HR.SetDevLog(true); HR:Print("Dev log " .. HR.COLORS.GREEN .. "ON" .. HR.COLORS.RESET .. " (buffer reset).")
        else
            local on = HR.SetDevLog(not HR.DevLogEnabled())
            if on then
                HR:Print("Dev log " .. HR.COLORS.GREEN .. "ON" .. HR.COLORS.RESET
                    .. " (buffer reset). Reproduce, then /reload; log stored in SavedVariables (ECPDevLog). '/ecp devlog show' to preview.")
            else
                HR:Print("Dev log " .. HR.COLORS.RED .. "OFF" .. HR.COLORS.RESET .. ".")
            end
        end
    end,

    -- Scan du Guide de l'aventurier : dump nom + spellID des capacites du boss OUVERT dans le
    -- Guide (ou /ecp journal <journalEncounterID>). Resout les spellID sans pull. cf. Capture.lua.
    journal = function(rest)
        local jeid = rest and tonumber(rest:match("%d+"))
        jeid = jeid or (EncounterJournal and EncounterJournal.encounterID)
        if not jeid then
            HR:Print("Open the Adventure Guide on a boss (or /ecp journal <journalEncounterID>).")
            return
        end
        local text = HR.JournalScanExport(jeid)
        if HR.UI and HR.UI.ShowCopyText then
            HR.UI.ShowCopyText("Journal scan " .. tostring(jeid), text)
        else
            HR:Print(text)
        end
    end,

    -- Capture zone + encounterID a chaque pull (ENCOUNTER_START). Sert a renseigner zoneID / id.
    scan = function()
        HR.capture = not HR.capture
        HR:Print("Capture (zone + encounterID on pull) "
            .. (HR.capture and (HR.COLORS.GREEN .. "ON") or (HR.COLORS.RED .. "OFF")) .. HR.COLORS.RESET .. ".")
        if HR.PrintZoneInfo then HR.PrintZoneInfo() end
    end,

    -- Journalise EN DIRECT chaque event de timeline serveur : test rapide "les events arrivent-ils ?".
    -- 'status' = etat de C_EncounterTimeline sans activer. cf. Core/Capture.lua.
    gather = function(rest)
        rest = rest and rest:lower() or ""
        if rest == "status" then
            if HR.PrintTimelineStatus then HR.PrintTimelineStatus() end
            return
        end
        local on
        if rest == "on" then on = HR.SetGather(true)
        elseif rest == "off" then on = HR.SetGather(false)
        else on = HR.SetGather(not HR.gather) end
        HR:Print("Gather " .. (on and (HR.COLORS.GREEN .. "ON") or (HR.COLORS.RED .. "OFF")) .. HR.COLORS.RESET
            .. (on and " : pull the boss, each timeline event is printed live ('gather status' for feature state)." or "."))
    end,

    -- Sonde de LISIBILITE des cooldowns du JOUEUR (lui seul) : a chaque cast perso, logge
    -- champ par champ ce qui reste lisible vs Secret Value. Repond a « peut-on connaitre son
    -- propre CD restant en combat / en M+ ? » -- prealable a tout partage coopératif de CD.
    -- `all` = ne pas filtrer les fillers. cf. Core/Capture.lua.
    comms = function(rest)
        rest = rest and rest:lower() or ""
        if rest == "status" then
            HR.PrintCommsStatus()
            return
        end
        local on
        if rest == "on" then on = HR.SetComms(true, false)
        elseif rest == "all" then on = HR.SetComms(true, true)
        elseif rest == "off" then on = HR.SetComms(false)
        else on = HR.SetComms(not HR.CommsEnabled(), false) end
        HR:Print("Comms probe " .. (on and (HR.COLORS.GREEN .. "ON") or (HR.COLORS.RED .. "OFF")) .. HR.COLORS.RESET
            .. (on and " : cast your own spells; each cast prints which cooldown fields are readable ('comms all' = no filter)." or "."))
        if on then HR.PrintCommsStatus() end
    end,

    -- Capture live de la timeline serveur pour AUTORING de Data/Content.lua (PTR : boss inconnus).
    -- Workflow : /ecp devscan (ON), pull le boss (idealement en Normal/Hero pour les spellID reels),
    -- puis /ecp devscan copy pour recuperer le Lua a coller. cf. Core/Capture.lua.
    devscan = function(rest)
        rest = rest and rest:lower() or ""
        if rest == "show" then
            HR.DevScanShow(40)
        elseif rest == "clear" then
            HR.DevScanClear(); HR:Print("DevScan cleared.")
        elseif rest == "copy" then
            if HR.UI and HR.UI.ShowCopyText then
                HR.UI.ShowCopyText("DevScan export", HR.DevScanExportString())
            else
                HR.DevScanShow(200)   -- repli : dump au chat si l'UI n'est pas dispo
            end
        elseif rest == "off" then
            HR.SetDevScan(false); HR:Print("DevScan " .. HR.COLORS.RED .. "OFF" .. HR.COLORS.RESET .. ".")
        elseif rest == "on" then
            HR.SetDevScan(true);  HR:Print("DevScan " .. HR.COLORS.GREEN .. "ON" .. HR.COLORS.RESET .. " (records kept; 'clear' to reset).")
        elseif rest == "status" then
            -- Diagnostic : etat devscan + disponibilite de C_EncounterTimeline (les events arrivent-ils ?).
            local S = (type(ECPDevScan) == "table") and ECPDevScan or nil
            local nRec = (S and S.records) and #S.records or 0
            local last = (S and S.records) and S.records[nRec]
            HR:Print(("DevScan: %s | records=%d | last record events=%d")
                :format(HR.DevScanEnabled() and "ON" or "OFF", nRec, (last and #last.events) or 0))
            if HR.PrintTimelineStatus then HR.PrintTimelineStatus() end
        else
            local on = HR.SetDevScan(not HR.DevScanEnabled())
            if on then
                HR:Print("DevScan " .. HR.COLORS.GREEN .. "ON" .. HR.COLORS.RESET
                    .. ". Pull the boss; each pull opens a record. '/ecp devscan copy' to export, 'show' to preview, 'clear' to reset.")
            else
                HR:Print("DevScan " .. HR.COLORS.RED .. "OFF" .. HR.COLORS.RESET .. ".")
            end
        end
    end,
}

SlashCmdList["ECP"] = function(msg)
    local cmd, rest = msg:lower():match("^(%S*)%s*(.-)$")
    local fn = dispatch[cmd or ""]
    if fn then
        fn(rest)
    else
        HR:Print("Unknown command: " .. tostring(cmd) .. ". Type /ecp help.")
    end
end
