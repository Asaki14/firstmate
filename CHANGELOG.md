# Changelog

## Unreleased

- Added the experimental `tern` runtime backend, ported from danielkuykendall23-boop/firstmate: ship and scout workers can run as Tern tabs, one Tern session per home ([`docs/tern-backend.md`](docs/tern-backend.md)).
- Secondmate spawns on Tern are still refused.
- Tern workers can be placed as panes in the launching agent's own tab instead of one tab per task, like Herdr's pane placement: set `config/tern-crew-placement` to `pane` ([`docs/tern-backend.md`](docs/tern-backend.md#crew-placement)).
