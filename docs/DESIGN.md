# Design system: BoardKit

The PRD asks for BoardUI ([boardui.com](https://www.boardui.com)) as the design reference. (The PRD's `boardyui.com` domain doesn't resolve; `boardui.com` is the BoardUI site.)

## What BoardUI is

BoardUI is a **React 19 + Tailwind CSS v4 + React Aria** component library for dashboards and agentic interfaces. Its components include agent thinking, agent progress, composer, sidebar and data table, and it has light and dark tokens. Its free tier is MIT-licensed. Pro components need a paid license.

## Compatibility with SwiftUI

None of BoardUI's components can be used directly in a native SwiftUI app: they are React DOM components styled with Tailwind classes. Embedding them would mean a WKWebView or Electron runtime, which the PRD rules out ("Do not introduce a full web runtime merely to reuse UI components").

## What we did

`Sources/NotchBuddyApp/BoardKit` re-creates BoardUI's *visual language and interaction patterns* natively. **No BoardUI source code, Figma assets or Pro components were copied.**

| BoardUI pattern | BoardKit native component |
|---|---|
| Buttons (primary gradient / secondary / ghost / tinted / destructive) | `BKButtonStyle` |
| Switch | `BKSwitchStyle` (`.toggleStyle(.bk)`), `BKSwitch` |
| Segmented control | `BKSegmented` |
| Select / dropdown | `BKMenu` |
| Chips | `BKBadge` (pastel status colors) |
| Status dot with halo | `BKStatusDot` |
| Avatar / app tiles (MCP list rows) | `BKTile` (logo, symbol or initials, optional status dot) |
| Settings modal (sidebar + grouped rows) | `SettingsPageFrame`, `SettingsSidebar`, `BKGroup`, `BKGroupHeader`, `BKFormRow` |
| Notification | `BKCallout` |
| Pill tabs, quick search | `BKPill`, `BKSearchField` |
| Agent thinking / iridescent light | `BKAgentOrb`, `BKShimmerText` |
| Composer loader (light travelling round the rim) | `.bkIridescentRim(_:cornerRadius:)` |
| Agent progress | `BKPlanProgress` with `BKProgressRing` |
| Activity feed | `BKTimeline` |
| Cards, empty states | `BKCard`, `BKEmptyState` |
| Inputs | `BKTextField`, `BKSecretField` (masked, paste, show/hide), `BKTextEditor`, `BKStepper` |
| Keyboard hints | `BKKeyCap` |

## Tokens

Values follow BoardUI's published design tokens (its Tailwind theme), re-created as Swift constants in `BK` and `BKTheme`.

- **Neutrals:** BoardUI's neutral scale, including its extra steps (100 `#F7F7F7`, 200 `#EBEBEB`, 925 `#121212`).
- **Surfaces:** light uses a white canvas, `#F7F7F7` sidebars and row groups, and white controls with `#EBEBEB` hairlines. Dark uses a `#121212` canvas, `#171717` groups and `#262626` controls. `BKTheme` picks the set from the color scheme. The notch is always pure black so it merges with the hardware cutout.
- **Accent:** BoardUI's blue (`#2673FE` → `#144BE9`). Primary buttons and switches use it as a top-to-bottom gradient with an inner highlight.
- **Chips:** pastel backgrounds with dark text, e.g. lime-200 / lime-800 for success, yellow-200 / yellow-800 for warning, rose-200 / rose-800 for danger, blue-100 / blue-800 for info. Dark mode uses tinted backgrounds with light text.
- **Agent light:** the iridescent gradient (violet, blue, teal, pink) marks agent activity: the orb, and the band that circles the notch's status bar while a task is planning or running.
- **Radius:** 6 / 8 / 10 / 12 / 16 / 20. **Spacing:** 4 / 8 / 12 / 16 / 24 / 32.
- **Shadows:** BoardUI's `shadow-card` (one soft pixel) on cards and controls, and a hairline-plus-lift float shadow on selected sidebar items and segments.
- **Type:** SF Pro at macOS sizes. Pages use 18 pt semibold titles, 13 pt body text and 11.5 pt captions.

## Snapshots

`NotchBuddy --snapshot <dir>` renders every notch state, and `NotchBuddy --snapshot-settings <dir>` renders the settings window, onboarding and the Composio key sheet in light and dark mode. Both use demo data in memory: they don't read the Keychain, your settings or your task history, launch MCP servers, or use the network.

## Notch behavior

- The panel is anchored to the real notch rectangle, computed from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. It never draws content under the cutout itself; status sits in the "wings" on either side.
- On displays without a notch, a 180 pt pill sits in the empty center of the menu bar. The menu-bar icon is always available as a fallback.
- The panel is a non-activating `NSPanel`. It becomes key only while you type a task, so the app you were using keeps focus, and the agent's keystrokes go to that app.
- It repositions when displays change (`didChangeScreenParametersNotification`).
