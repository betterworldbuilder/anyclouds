# R6 iOS Light UI Template

Version: 2026-07-13  
Scope: `#s2r6ace-pane` only  
Implementation: `/workflow_dashboard/static/r6-ios-light.css`

## Intent

Use an iOS Settings-inspired light presentation for every R6 stage: quiet grouped backgrounds, white elevated cards, compact controls, rounded geometry, SF-system typography and semantic Apple colors. This template changes presentation only and must never change workflow state, scan evidence or approval behavior.

## Color tokens

| Purpose | Token | Value |
|---|---|---|
| Primary action/accent | `--ios-blue` | `#007AFF` |
| Accessible blue text/button | `--ios-blue-accessible` | `#0066CC` |
| Success | `--ios-green` | `#34C759` |
| Accessible success | `--ios-green-accessible` | `#248A3D` |
| Destructive/blocker | `--ios-red` | `#FF3B30` |
| Accessible blocker | `--ios-red-accessible` | `#D70015` |
| Warning | `--ios-orange` | `#FF9500` |
| Accessible warning | `--ios-orange-accessible` | `#C93400` |
| Caution | `--ios-yellow` | `#FFCC00` |
| Primary label | `--ios-label` | `#1C1C1E` |
| Secondary label | `--ios-secondary` | `#636366` |
| Grouped background | `--ios-grouped` | `#F2F2F7` |
| Surface | `--ios-surface` | `#FFFFFF` |
| Separator | `--ios-separator` | `#C6C6C8` |

## Component rules

- Use the system font stack: `-apple-system`, `BlinkMacSystemFont`, `SF Pro Display`, `SF Pro Text`, `Helvetica Neue`, Arial.
- Main stage and appraisal surfaces use white, 16px corners and restrained elevation.
- Inputs use 9px corners and a visible blue focus ring.
- Actions use 10px corners; primary actions use accessible Apple blue.
- Status cannot rely on color alone; retain text labels, icons and borders.
- Tables use grouped headers, subtle separators and hover feedback.
- Warning, blocker and success surfaces use light semantic fills with accessible text colors.
- Terminals stay dark for operational legibility and use Apple green console text.
- Drawer overlays use blur and must preserve keyboard focus behavior.
- Mobile layouts retain full-width controls and readable stage padding.

## Safety boundary

Do not use this stylesheet to hide blockers, warnings, disabled controls, scan logs, failed checks or approval gates. Do not introduce behavioral JavaScript into this design template.
