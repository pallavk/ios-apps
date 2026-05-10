# Branch Strategy

NutriScan uses `main` as the stable integration branch.

Development should happen in short-lived feature branches named by scope:

- `backend/<short-topic>` for API/parser work.
- `ios/<short-topic>` for iOS app work.
- `docs/<short-topic>` for planning-only changes.

Each branch should keep changes small enough to review with focused tests and
should merge only after the relevant backend tests, Swift parse/build checks, or
manual device checks pass.
