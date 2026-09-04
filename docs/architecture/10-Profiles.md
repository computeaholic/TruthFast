# Profiles

Profiles are metadata-only specifications that declare which providers and capability bindings realize the constitution on a target platform.

What belongs in a profile

- Discovery metadata (profile id, author, supported platform types)
- Capability Bindings
- Provider descriptors and compatibility ranges
- Limitations and caveats
- Supported claims and coverage matrix
- Validation checks (profile-level smoke tests)

What must not be in a profile

- Implementation scripts or product-specific logic
- New claims or capabilities

Validation

- Profiles must pass a profile validation process (static checks against constitutional schemas) before use in a migration.
