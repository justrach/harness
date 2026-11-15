# UI SDK patterns in the native desktop UI

This is a behavioral adaptation, not an installation of `@ui-sdk/core`.
Harness packages the Zig/NanoUI desktop frontend. Vercel's beta SDK and its
framework adapters operate on browser elements; introducing a webview just for
focus handling would duplicate the existing native input and accessibility tree.

## Guidance reviewed

- [Focus and keys](https://ui-sdk.dev/docs/core/behaviors/focus): distinguish
  focus from selection; use roving focus for composite groups; support typeahead;
  recover focus after removal without taking it from a newer interaction.
- [Popups](https://ui-sdk.dev/docs/core/behaviors/popups): choose interaction
  behavior, not just a visual role. A modal task contains keyboard focus;
  Escape/Close return focus to its trigger. Nested dismissal belongs to the
  topmost layer. Outside-press dismissal is a policy, not a universal requirement.
- [Selection](https://ui-sdk.dev/docs/core/behaviors/selection): choosing an
  item or range is separate from moving keyboard focus.

The upstream source is [vercel-labs/ui](https://github.com/vercel-labs/ui),
particularly `apps/docs/content/docs/core/behaviors/`.

## First native adaptation: image inspectors

Both chat and GitHub previews now share `apps/nano/src/preview_focus.zig`:

- Opening a preview focuses Close, a safe first action.
- Tab and Shift+Tab cycle through Close, Zoom out, Zoom in and Fit, without
  transferring keyboard focus into background controls.
- Enter and Space activate controls through NanoUI's existing interaction path,
  also used for pointer and assistive activation.
- A keyboard-only focus ring identifies the current control.
- Native accessibility button labels describe preview controls and image triggers.
- Escape and Close return focus to the opening image if it is still mounted;
  recovery does not overwrite focus already owned by another control.
- Existing pane ownership decides whether a preview may handle keys. Hidden
  previews do not capture another pane's Escape.

The preview remains pane-local; other panes can still be selected with the
pointer. This does not establish application-wide modal isolation or full
screen-reader dialog parity. No browser ARIA attributes are added to native UI.

## Shared controls and GitHub navigation

`control_behavior.zig` centralizes activation and keyboard-only focus indication.
It is used by the shared icon-button component (toolbar/sidebar/composer callers),
preview controls, account/checkout/branch menu rows, GitHub action buttons,
repository item cards and file disclosures. Native accessibility descriptions
include labels, enabled state and selection. Disabled controls are not Tab stops
and reject pointer, keyboard and assistive activation.

GitHub item-type tabs, detail sections and state filters use
`control_group.zig`: one Tab stop per group, Left/Right wrapping and Home/End.
Focus is separate from selection: only Enter/Space or a click commits a change,
so arrow navigation does not trigger host requests. Focus can recover after
loading temporarily disables a group, but not from a newer focused control.

The GitHub regression also addresses a concrete failure: the old focus-ring
helper consumed keyboard activation before a second pointer-only interaction
checked it. Each migrated control now uses exactly one activation interaction.
These menu-row changes do not add a global popup focus trap or dismissal stack.

## Deliberately not bundled

Roving focus/typeahead in pickers, hierarchical navigation, list-range selection,
and a global nested-popup dismissal stack need separate surface-specific work.
Project/model-picker Enter fixes and text-selection work already have existing
PRs, so they are not reimplemented here. Existing reduced-motion support is
retained rather than replaced by an animation dependency.

## Verification

Synthetic offscreen tests exercise Tab/Shift+Tab boundaries, Enter/Space,
keyboard focus indication, return-to-trigger/reopening, GitHub description and
activity previews, and hidden-preview ownership. Run the `reply images` and
`github` test filters with `zig build test`, including the portable renderer.
The `shared icon controls`, `native choices`, and `native checkout menu` filters
cover common controls, disabled states, roving focus and real menu activation.
OS screen-reader navigation is not covered by these offscreen checks.
