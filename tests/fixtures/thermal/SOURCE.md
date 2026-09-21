# Thermal generator test fixtures

These JSON files are historical repository fixtures recovered from
commit `214db6a03adbdfedd22f1ad76684413c22398580`, the parent of the change
that removed packaged stock. They are used only to regression-test
threshold ordering, unchanged safety slots, and hysteresis limits.

They are **not** a current-device stock baseline, install input or release
payload. The runtime package excludes `tests/`. Installation must capture and
validate the current device/build through `thermal_policy_lib.sh`.
