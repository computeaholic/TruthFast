# Capability Bindings

Capability Bindings are permanent architectural objects that map a capability to a concrete set of provider roles and evidence contracts for a given profile.

Purpose

- Provide a clear, canonical mapping between constitutional capabilities and profile/provider implementations.

Ownership

- Bindings are owned by the profile author and must reference constitutional capabilities and EC ids.

Schema (conceptual)

- `binding_id`
- `profile_id`
- `capability_id`
- `providers`: list of provider descriptors or provider roles
- `required_ecs`: list of EC ids
- `notes`

Lifecycle

- Created as part of profile design
- Versioned with profile
- Updated via ADR if constitutional capability semantics change

Relationship to profiles and providers

- Profiles include Capability Bindings. Providers implement the roles referenced by the binding.
