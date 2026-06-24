# AffixDex — Changelog

## 1.6.0

### Added
- `/adex version` (alias `/adex ver`) — prints the addon version and the party-sharing wire-protocol version.
- **Fixed-affix legendary weapons are now detected.** Items like *The Judge's Gavel*, *Stormherald*, or any named weapon whose tooltip shows only the proc effect ("Chance on hit: Stuns target for 3 sec.") instead of the affix name are now correctly identified. AffixDex caches each weapon affix's proc description (fetched from the server's spell tooltip via ProjectEbonhold's affix list) and matches item proc text against it dynamically — no hand-maintained item-ID table required.
- `/adex procs` — debug command that dumps the cached proc descriptions, so you can see what each weapon affix's normalized description looks like and which ones AffixDex has on file.
- **Affix descriptions in the row tooltip.** Hovering an affix's icon or name in the grid now shows the affix's actual in-game spell description. For ranked affixes the tooltip describes the strongest version you've learned (or the highest rank known if you haven't learned any). Pulled from ProjectEbonhold's affix list automatically — nothing hard-coded.

### Fixed (also in 1.6.0, pre-release iteration)
- The proc-text matcher no longer misattributes random-suffix weapons. `Wand of Allistarj of Glaciation` was being flagged as Keeper's Sting because "ranged target" in the wand tooltip happened to substring-match Keeper's Sting's spell description. The matcher now (a) only runs on weapons that have NO random-property suffix (real fixed-affix candidates), and (b) requires the matched line to start with "Chance on hit:"/"Chance to strike" AND the affix description to be the start of that line — set-bonus / stat / flavor text can't match anymore.
- **Ranked affixes on weapons are now detected.** Weapons like `Misery's End of Keen Strikes III`, `Symbol of Transgression of Arcane Mind IV`, or `Rod of Imprisoned Souls of Overwhelming Force II` came back as "(no affix detected)" because the slot filter was treating ranked affixes as armor-only. On Ebonhold the ranked affix families can appear on either a weapon OR a piece of armor, so the weapon slot now allows both weapon and ranked affixes (armor slots are still restricted to ranked — weapon procs don't apply to armor).
- The name-scan now strips embedded color escape codes before parsing. Items where Ebonhold renders the affix portion in a custom color (e.g. `Misery's End |cff800080of Keen Strikes III|r`) used to come back as "(no affix detected)" because the hex digits of the color code looked like word characters to the boundary check and broke the match.
- The name-scan no longer matches affix words **mid-line**. Items with set-bonus text like `Set: Increases Bladestorm damage by 10%` were being flagged as having the Bladestorm affix because the word appeared in the tooltip. Affix names are now only recognised when they appear at the **end of a line** (which is where the random suffix always sits), so set bonuses, flavor text, and class-ability mentions are ignored.

## 1.5.3

### Fixed
- Ranked affixes on **jewelry** (neck, rings, trinkets) are now detected. Previously these slots were rejected before the tooltip scan ran, so e.g. `Scarlet Signet of Stalwart V` or `Darkbane Amulet of Arcane Mind V` came back as "(no affix detected)" and never marked the cell as Equipped.
- The Equipped highlight box no longer looks brown — the gold color is brighter and more opaque, so it reads as gold against the dark cell background instead of blending into mud.
- An affix wouldn't be detected if its name happened to appear earlier in the item's tooltip (e.g. `Stalwart Pauldrons of Stalwart V` — the parser used to stop at the first "Stalwart", see no rank after it, and give up). The tooltip scan now keeps looking past false-match occurrences in the same line.

## 1.5.2

### Fixed
- Rank-cell check marks were rendering as `?` on default WoW 3.3.5 fonts because the codepoint I used wasn't in the font. Switched to a glyph that's universally supported, so checks now render correctly.

### Changed
- Window widened so the legend no longer overlaps the Rescan button.
- Legend now uses the **same check / × glyphs** as the grid cells for "Both / You only / Them only / Neither", and **colored boxes** for the highlight states (Equipped / In bag / Dup) — so the legend visually mirrors what you see in the grid.

## 1.5.1

### Fixed
- The blue "in bag" highlight now shows even when the affix is already learned. Previously it only appeared if you didn't have the affix learned, which made it look like the highlight wasn't working when you saw an item in your bags for an affix you already knew.

### Changed
- Compare-view check colors are now visually distinct. Previously "you only" and "them only" were two shades of green (the underlying check texture is green, so vertex coloring couldn't escape that). The cells now use a tintable check character, so **"them only" is cyan** and **"you only" is green** — instantly distinguishable at a glance.

## 1.5.0

### Changed
- Redesigned the bottom status/legend area. The legend is now a row of actual **colored swatches with labels** (instead of the previous tightly-packed colored words), so the colors visually map to the cells in the grid.
- In compare view the labels use the **actual player's name** — e.g. `Borg only` and `You only`, instead of the confusing `them` / `you` pronouns. The title line above the legend reads `vs Borg — 14 / 65 affixes` so it's clear who you're looking at.

## 1.4.2

### Fixed
- Affixes whose item-tooltip text differs from the underlying spell name are now correctly resolved. Items showing **"of Block"** are recognized as **Shield Block**, **"of Precision"** as **Cold**, **"of Swift Footwork"** as **Feral Grace**, **"of Keen Strike"** as **Keen Strikes**, **"of Inner Light"** as **Spirit Surge**, and **"of Enduring Flesh"** as **Ironhide**. (Mirrors all 6 entries from ProjectEbonhold's own affix-alias table.)
- One-time migration: any legacy "Block" / "Enduring Flesh" / etc. entry that ended up in your saved data from older parser logic is automatically merged into the canonical entry on next login, so the grid no longer shows phantom rows.
- `/adex catalog` now de-duplicates entries — aliases no longer cause "Shield Block" (etc.) to appear twice.

## 1.4.1

### Fixed
- Bundled fallback affix list now matches the live server catalog: added the four ranked affixes that were missing (**Armor Rend, Ironhide, Living Tide, Mender's Surge**), and removed **Enduring Flesh** (not on the server). The bundled list only matters before ProjectEbonhold has pushed its data, but it should now show the right things from the very first session.
- The bundled list is alphabetized so future drift is easy to spot via `/adex catalog`.

## 1.4.0

### Changed
- Affix detection now uses the **server's authoritative interface** via ProjectEbonhold. The full affix catalog (every affix the server knows about, with correct names, weapon-only flag, and icons) is pulled from `ExtractionService.learnedAffixes` — affixes that were missing from the bundled list now show up automatically, and "learned" state for ranked affixes is synced from the server.
- Items are now identified by **scanning the item's actual tooltip text** (same method ProjectEbonhold itself uses) instead of guessing from the item name. This eliminates a whole class of false positives:
  - Quest items like **Fragment of Val'anyr** are no longer mistaken for the Val'anyr affix.
  - Vanilla random-suffix items like **Gloves of Ferocity** are no longer mistaken for the Ferocity affix.
  - Any other item whose name happens to end with an affix word but doesn't actually carry that affix is correctly skipped.
- The bundled affix lists remain as a fallback when ProjectEbonhold isn't loaded.
- Slot-based filtering: ranked affixes are now only checked on armor/shirt/tabard/shield slots, and weapon affixes only on weapon slots. Items in any other slot (rings, necks, trinkets, etc.) are rejected outright.
- The displayed affix list now uses the **server's catalog** instead of the bundled hand-maintained list. The first time you log in with ProjectEbonhold loaded, the server-pushed catalog is saved to AffixDex's account-wide data; from then on, the grid shows what the server says exists. No more leftover/fake entries from the static fallback list.
- New slash commands: `/adex catalog` dumps the current runtime catalog (and its source) to chat. `/adex resetcatalog` wipes the persisted catalog and falls back to the bundled seed (use if you suspect the persisted data is stale).

## 1.3.0

### Added
- Item tooltips now show the affix and whether you've learned it. Hovering any item with an affix (bags, bank, Auction House, chat links, comparison tooltips) adds a line like `AffixDex  Wellspring V  learned` / `not learned`. For a rank you don't have, it also notes which ranks of that affix you do have.
- Hovering a rank check in the grid now shows a tooltip listing the item(s) you carry with that affix at that rank (equipped and/or in bags).
- Saved players in the View bar now have an **x** to close the tab. Their data is kept in the backlog — search for them (or use the Saved dropdown) and click to re-open the tab. "You" and current party members can't be closed.

### Fixed
- The bag glow for unlearned-affix items now also works with **ElvUI bags** (previously only the default Blizzard bags glowed).
- Items that aren't actually affixed are no longer flagged. Two checks were added:
  - Non-equippable items are ignored (fixes quest items like `Fragment of Val'anyr` being flagged as the Val'anyr affix).
  - Weapon affixes now require the affix to be appended after a base name that already has an "of" segment (fixes ordinary random-suffix items like `Gloves of Ferocity` being flagged as the Ferocity affix).

## 1.2.1

### UI overhaul (flat dark theme, teal/purple)
- Reskinned the whole window: flat dark panels, thin teal border, a proper header bar with a teal→purple accent line.
- Each affix now shows its icon (like the in-game Affix Book). Unlearned affixes are greyed/desaturated.
- Cleaner grid: alternating row striping, mouseover highlight, and styled "Ranked / Weapon" section headers.
- Hover any affix for a tooltip showing your learned / equipped / in-bag ranks.
- "View" selector is now flat pill buttons; reskinned the close button, the Saved dropdown, and the scrollbar to match.

### New markers
- In-bag (not yet learned) affixes show a light-green check in a blue box, both in the grid and as a blue glow on the item in your bags.
- Duplicate equipped affix+rank now shows a red box with a count (e.g. "2") instead of an X over the checkmark.

### Fixes
- Duplicate detection now correctly keys on **affix + rank** (different ranks of the same affix stack and are no longer flagged as duplicates).
- Enchant scrolls (`Scroll of Stamina IV`, etc.) are no longer mistaken for affixes. New affixes are now discovered only from your spellbook.
- Fixed the selected View button being hard to read.
- Fixed clicking a party/saved member not switching the view.

> **After updating:** run `/adex cleardiscovered` once to clear any scrolls that older versions wrongly picked up.

> Party sharing still works across all 1.x versions (wire protocol unchanged).

## Earlier (1.x)
- Spellbook affix tracker with a grid of learned affixes and ranks (`/adex`).
- Cumulative per-character tracking; auto-rescan on learning a spell.
- Party sharing over the addon channel with a compare view (who has which affix/rank), gated on a wire protocol version so cosmetic releases don't break sharing.
- Account-wide snapshot backlog of past party members, with a search box and a prepopulated "Saved" dropdown.
- Equipped-affix highlighting; new-affix bag notifications.
- Standalone — no dependency on Auctioneer or any other addon.
