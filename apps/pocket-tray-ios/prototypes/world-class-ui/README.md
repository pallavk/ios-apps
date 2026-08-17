# Pocket Tray world-class UI prototype

> THROWAWAY PROTOTYPE — issue #18. This is not production UI.

Question: which content density best balances calm visual quality and rapid scanning?

- `airy`: larger previews and more breathing room
- `compact`: more visible objects and tighter scanning

Run from the repository root:

```sh
python3 -m http.server 4173 --directory apps/pocket-tray-ios/prototypes/world-class-ui
```

Then open:

- <http://localhost:4173/?variant=airy>
- <http://localhost:4173/?variant=compact>

The prototype switcher also changes screen state, light/dark appearance, and standard/accessibility text size. All content is deterministic and synthetic.
