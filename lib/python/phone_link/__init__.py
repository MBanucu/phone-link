"""Shared core of phone-link: the action registry and one runner.

`phone-link` (CLI) and `phone_link_gui` (GTK) both read the same table, so an
action can never exist in one and not the other.
"""
