"""The decisions a systemd unit runs, kept out of the unit's shell hook.

One module per helper under `lib/` that a unit starts. The unit still runs it;
the branching decision, the parsing and the state live here, where a hermetic
test can call them with plain strings and lists.
"""
