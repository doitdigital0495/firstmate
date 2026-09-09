# Pi Codex account indicator

Firstmate's Pi interface names the Codex credential store the running session authenticates from, so the quota figures on screen can be read against the account that actually supplies them.
The indicator is always on, needs no configuration, and adds nothing to the quota display's own numbers or layout.

Pi renders it on the footer's extension-status line, directly beneath the token, cost, context, and model row, for as long as the footer itself is on screen.

It reads one of three forms:

- `codex@<store>` names the credential store in use, written the way the captain reads it: `codex@.pi` for the personal Pi home and `codex@.pi-geris` for the Geris one.
  A store outside the home directory is named by its absolute path instead.
- `codex@unverified(<reason>)` states that no account can be named.
  `no-login` means the store holds no Codex credential, and a source name such as `environment` or `runtime` means the credential in use came from somewhere other than the store, so naming that store would describe the wrong account.
- `codex@unknown` means the store's own path cannot be stated safely, so it is reported as unknown rather than cleaned up into something that reads like a real store.

The store is whichever agent directory this Pi process authenticates from, which is `PI_CODING_AGENT_DIR` when set and `~/.pi/agent` otherwise.
That is the same directory Pi reads its credential from, so the label is the account bucket itself rather than an inference from the model, the provider, or the shell.

The indicator names a store, never a person and never an account address.
It reads no access token, no refresh token, no stored credential, and no account id, and it displays none of those, so a store that holds an unexpected login is reported as that store rather than as the account behind it.

Pi emits no login or logout event, so the indicator refreshes when a session starts or reloads, when the model or provider changes, and at the start of each turn.
A `/login` performed mid-turn is therefore reflected from the next turn onward.

`.pi/extensions/fm-codex-account.ts` owns the behavior, and [`verification/pi-account-indicator.md`](verification/pi-account-indicator.md) owns the dated Pi evidence it rests on.

Regression entry points:

```sh
tests/fm-codex-account-pi-extension.test.sh
tests/fm-pi-primary-types.test.sh
```
