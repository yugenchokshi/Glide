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
| Buttons (primary/secondary/ghost/destructive) | `BKButtonStyle` |
| Badges / pills | `BKBadge` |
| Status indicators | `BKStatusDot` (with pulse) |
| Agent thinking / iridescent light | `BKAgentOrb` (rotating iridescent gradient), `BKShimmerText` |
| Agent progress | `BKPlanProgress` |
| Activity feed | `BKTimeline` |
| Cards, form rows | `BKCard`, `BKFormRow`, `BKSectionHeader` |
| Inputs | `BKTextField`, `BKSecretField` (masked, show/hide) |
| Keyboard hints | `BKKeyCap` |

## Tokens

- **Radius:** 6 / 10 / 14 / 20.
- **Spacing:** 4 / 8 / 12 / 16 / 24.
- **Surfaces:** the notch is always pure black, so it merges with the hardware cutout, with white text at 94 / 58 / 36 % opacity and 8 % hairline borders. Settings windows use semantic AppKit colors, so they follow light and dark mode automatically.
- **Accent:** a violet → blue gradient for primary actions. The iridescent ring (violet, blue, teal, pink) marks agent activity.
- **Tones:** success `#33D499`, warning `#FABF24`, danger `#F77070`, info `#61A6FA`.
- **Type:** SF Pro, 11–15 pt in the notch, with semibold titles.

## Notch behavior

- The panel is anchored to the real notch rectangle, computed from `NSScreen.safeAreaInsets` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. It never draws content under the cutout itself; status sits in the "wings" on either side.
- On displays without a notch, a 180 pt pill sits in the empty center of the menu bar. The menu-bar icon is always available as a fallback.
- The panel is a non-activating `NSPanel`. It becomes key only while you type a task, so the app you were using keeps focus, and the agent's keystrokes go to that app.
- It repositions when displays change (`didChangeScreenParametersNotification`).
