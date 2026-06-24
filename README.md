# AffixDex

> A Project Ebonhold affix tracker for WoW 3.3.5a

AffixDex shows you, at a glance, every affix on the server and which ranks you have learned — like a personal Pokédex for the affix system. Browse your own collection, compare with party members, see which affixes are sitting in your bag waiting to be learned, and never wonder again "did I already wear this rank somewhere?"

![Interface: 30300](https://img.shields.io/badge/Interface-30300-blue) ![Server: Ebonhold](https://img.shields.io/badge/Server-Project%20Ebonhold-purple)

## Features

- **Full affix grid** — every affix on the server, ranked or weapon, with its real icon. Greyed out if unlearned, lit with a check for each rank you've learned.
- **Item tooltips** — hover any item carrying an affix and AffixDex adds a line: `Wellspring V — learned` or `not learned (you have III)`.
- **Currently equipped highlight** — gold box shows which exact affix+rank is on your gear right now; a red box with a count appears if you've doubled up the same affix+rank.
- **Bag awareness** — items in your bags carrying an affix get a blue glow in the bag UI, the matching grid cell gets a blue box, and you get a chat ping the first time you see an unlearned one.
- **Party comparison** — group members running AffixDex automatically share their data over the addon channel. Switch the "View" pill to a partymate to compare: cyan = "only they have," green = "only you have," white = "both," red × = "neither."
- **Snapshot backlog** — every party member you meet is saved permanently. Find them later by name or by affix in the search box, even months later.
- **Closeable tabs** — `×` on any saved tab hides it. Their data stays in the backlog and re-appears when you search for them.
- **Standalone** — no other addons required. ProjectEbonhold's runtime affix catalog is used automatically when present, and the bundled fallback list keeps things working otherwise.

## Install

1. Drop the **AffixDex** folder into `World of Warcraft\Interface\AddOns\`
2. Full client restart (newly-added folders aren't picked up by `/reload`)
3. Type `/adex` in-game

## Slash commands

| Command | What it does |
|---|---|
| `/adex` | Toggle the main window |
| `/adex scan` | Rescan the spellbook for newly-learned affixes |
| `/adex gear` | Dump every equipped slot + what AffixDex detects on it (handy for bug reports) |
| `/adex catalog` | Show the current affix catalog and where it came from |
| `/adex resetcatalog` | Wipe the persisted catalog (next sync rewrites it from the server) |
| `/adex cleardiscovered` | Purge legacy auto-discovered affix names from saved data |
| `/adex tabs` / `/adex tab N` | Spellbook-tab debug helpers |
| `/affixtracker` | Alias for `/adex`. `/affixdex` is reserved by the Ebonhold client. |

## Sharing & versioning

Party sharing is gated on a separate **wire protocol version** so cosmetic releases (UI tweaks, color fixes, etc.) don't break sharing between guildmates. Two clients can be on different display versions and still share affix data, as long as the protocol matches. A peer on a different protocol shows up with `!` next to their name and is flagged but not trusted.

## Credits

- Built by **Noturpalguy** — feedback and bug reports welcome.
- Mirrors the affix data, alias map, and detection approach from Project Ebonhold's own `ExtractionService` / `FindItemAffix` so behavior stays consistent with the server.

## License

MIT — see source.
