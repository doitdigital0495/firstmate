# Pi Codex account indicator verification

Audience: maintainer verification.

This record supports [`pi-account-indicator.md`](../pi-account-indicator.md) and the extension at `.pi/extensions/fm-codex-account.ts`.
It records only the vendor facts that must be re-established when Pi changes.

## Surfaces and APIs the indicator depends on

Verified 2026-09-08 on Pi 0.84.4.

```sh
pi --version
```

```text
0.84.4
```

Three package-level facts carry the implementation, each read from the installed package's own declarations:

- `getAgentDir()` is re-exported from the package root (`dist/index.d.ts`) and resolves `PI_CODING_AGENT_DIR`, falling back to `~/.pi/agent` (`dist/config.js`).
  `getAuthPath()` is `join(getAgentDir(), "auth.json")` in the same module, so the resolved agent directory is the credential store, not a directory that merely sits beside one.
- `ExtensionUIContext.setStatus(key, text)` is declared as footer/status-bar text (`dist/core/extensions/types.d.ts`), and `FooterComponent` renders every extension status on one footer line, sorted by key and joined with a space, below the token, cost, context, and model row (`dist/modes/interactive/components/footer.js`).
  Pi's own footer sanitizer only collapses whitespace, so escape sequences in status text survive; the extension therefore refuses any store label that is not plainly path-shaped rather than passing it through.
- `ModelRegistry.getProviderAuthStatus(provider)` returns `{ configured, source?, label? }` (`dist/core/model-registry.d.ts`, `dist/core/provider-composer.d.ts`), where `source` is one of `stored`, `runtime`, `environment`, `fallback`, `models_json_key`, or `models_json_command`.
  It reports that a credential exists and which surface it came from, and never which account it belongs to.

A `belowEditor` widget was rejected as the surface: Pi orders widgets by extension load order, which is unsorted directory order (`dist/core/extensions/loader.js`), and caps the widget area at ten lines, so a second widget could render above or below an existing quota widget from one run to the next.

Pi exposes no login, logout, or auth-changed event in `ExtensionAPI`, which is why the indicator refreshes on `session_start`, `model_select`, and `turn_start` instead.

## Non-secret readiness evidence

Verified 2026-09-08 on Pi 0.84.4, against the personal agent directory.

```sh
pi auth check --provider openai-codex --json --no-refresh
```

```json
{"status":"ready","provider":"openai-codex","authType":"oauth"}
```

This confirms `openai-codex` as Pi's provider id for the ChatGPT/Codex subscription family and confirms that a store-backed OAuth credential is what the personal home holds.
The indicator does not call this command; the fact is recorded because it is the supported way to re-establish provider readiness by hand without emitting a credential, which `--credentials` would.

## Live rendering evidence

Verified 2026-09-08 on Pi 0.84.4 under tmux at 200 columns, with the extension loaded through `-e` and `--no-session` so no session file was written.

Personal store, against the real agent directory:

```sh
pi --no-session -e .pi/extensions/fm-codex-account.ts
```

The captured footer tail, with the quota display above it unchanged:

```text
/tmp/claude-1000
$0.000 (sub) 0.0%/272k (auto)                          (openai-codex) gpt-5.6-sol • medium
codex@.pi
```

Second store, against a scratch home holding a synthetic API-key credential, so the real Geris home was neither read nor written:

```sh
HOME=<scratch> PI_CODING_AGENT_DIR=<scratch>/.pi-geris/agent pi --offline --no-session -e .pi/extensions/fm-codex-account.ts
```

```text
/tmp/claude-1000
0.0%/0 (auto)                                                                    unknown
codex@.pi-geris
```

The two homes render as distinct labels, and the second run also shows that the label follows the credential store rather than the model: Pi reported no model at all under `--offline` with an empty catalog cache, and the store was still named correctly.

An agent directory holding no credential cannot be shown this way, because Pi exits rather than starting an interactive session with no provider available.
`tests/fm-codex-account-pi-extension.test.sh` covers that state, along with the foreign-source, unrecognized-source, unavailable-status, and unnameable-store states.

## Regression coverage

`tests/fm-codex-account-pi-extension.test.sh` loads the tracked extension against the installed Pi package, so `PI_CODING_AGENT_DIR` is resolved by Pi's own `getAgentDir()` rather than by a copy of that logic in the test.
It pins the two distinct store labels and asserts the divergence itself, the four unverified states, the unnameable-store refusal, the refresh events, footer silence without a UI, and secret safety.
Secret safety is asserted two ways that fail for different reasons: the fake registry raises from every credential-bearing Pi API, and the resolved store holds an unreadable credential file, so a run that reached for either would fail rather than pass quietly.

`tests/fm-pi-primary-types.test.sh` type-checks the extension against the installed Pi declarations under `strict`.
