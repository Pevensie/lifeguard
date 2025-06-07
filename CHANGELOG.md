# Changelog

## v2.0.0 - 2025-06-01

- Fix a critical bug where the Lifeguard process would crash if a worker crashed.
  Due to the fix required for this, some information on why workers fail to start
  is currently lost, thus the `lifeguard.StartError` type no longer has the
  `lifeguard.WorkerStartError(actor.StartError)` constructor. Instead, Lifeguard
  will now mimic the bahvaiour or `supervisor:start_link` and
  `gleam/otp/supervisor.start_link` and crash if actor initialisation fails.

## v1.0.1 - 2025-01-03

- Add `broadcast` function to send a message to all workers in the pool

## v1.0.0 - 2024-12-30

- Initial release
