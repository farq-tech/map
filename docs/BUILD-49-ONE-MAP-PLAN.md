# Build 49: one-map steps EM4..EM9 (state at 2026-11-13 ~03:30)

Source: docs/EXPLORE-MERGE.md §6 and §9. The flag `sary.oneMap` stays OFF by default until EM7.

| Step | State | PR / branch | Gate before merge |
|---|---|---|---|
| EM4 capabilities as a rule | rebased on main (clean; only a dropped `qiblaOrigin` line and a regenerated pbxproj) | #236 `em4-capabilities` | build + `MapCapabilityTests` + Layers*/HiRes UITests; shots flag on/off |
| EM5 part 1: permanent coordinate card + crosshair (P12/P13) | written, parse-checked, NOT built | `em5-readout` (stacked on #236) | build + `MapCapabilityTests` + `OutingCapabilitiesUITests`; SE/Pro Max overlap shots (LiveTopStack alert lane) |
| EM5 part 2: layer shortcut (P09) + side column (P16: places/drone/realistic) | NOT started: needs the owner's decision (the two-button rule in `LiveCalmRules` cannot hold layers+locate+places+drone+realistic; proposal: layers+locate always, the rest while stopped inside «المزيد»/the layers sheet) | – | owner written OK, then `LiveCalmTests`, `ReachabilityUITests` |
| EM6 unified «البر» sheet | NOT started: replaces `HomeTool.menu` and the explore row in «أدوات»; start from `DesertToolsHost` (DesertRouteSheet.swift) | – | CampSites/DesertGazetteer/Reachability UITests |
| EM7 flip default on (internal only) | blocked by EM4-EM6 and the parity list (§4) 100% | – | full suite nightly + owner on TestFlight internal |
| EM8 remove exploration | blocked by EM7 | – | separate PR, no feature mixing |
| EM9 delete PlanMapView/old MapHomeScreen | blocked by two stable builds after EM7 | – | full suite nightly |

Why not wire EM5 part 2 / EM6 blind: both change what the stopped outing's side column and «أدوات» offer (features must not be lost) and need simulator shots on SE and Pro Max.
