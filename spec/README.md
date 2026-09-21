# Test contracts

Run `bundle exec rspec` for the PostgreSQL suite. The dummy database is `scry_test`.

| Area | Location |
|---|---|
| Permission specificity and hard adapter constraints | `scry/interoperability/policy_specificity_spec.rb` |
| Inherited named callbacks | `scry/interoperability/policy_inheritance_spec.rb` |
| Discovery and permission invalidation | `scry/interoperability/discovery_consistency_spec.rb` |
| Association set identities and explicit candidate IDs | `scry/interoperability/association_sets_spec.rb` |
| DISTINCT and raw Arel candidate projection requirements | `support/candidate_projection_contracts.rb` |
| Aggregate operand types and SQLite execution | `scry/interoperability/aggregate_operands_spec.rb` |
| JSON and serialized operand shapes | `scry/interoperability/operand_shapes_spec.rb` |
| Custom property expansion | `scry/interoperability/custom_expansion_spec.rb` |
| Root permission failure diagnostics | `scry/interoperability/permission_diagnostics_spec.rb` |
| Temporal execution without application time zones | `scry/interoperability/temporal_runtime_spec.rb` |
| Tenant, soft-delete, and limited association scopes | `scry/interoperability/application_scopes_spec.rb` |
| Standalone adapter and dependency workflow | `scry/interoperability/adapter_runtime_spec.rb`, `compatibility_workflow_spec.rb` |
| Scalar set IDs, fractional aggregates, derived and grouped projections | `support/review_query_contracts.rb` |
| Invalid-tree policies, diagnostic paths, and logging failures | `scry/interoperability/review_diagnostics_contracts_spec.rb` |
| Private/protected Arel collisions | `scry/interoperability/review_arel_collision_spec.rb` |
| Extension metadata, registry snapshots, and real Rails reload | `scry/interoperability/review_extension_contracts_spec.rb` |
| CTEs, qualified grouping, Boolean composition, and diagnostic policies | `support/composition_contracts.rb` |
| Complete aggregate discovery, contexts, types, and locales | `support/discovery_contracts.rb` |
| Scalar, zero-operand, set, and relation association callbacks | `support/association_operand_contracts.rb` |
| Earlier regression contracts, organized by behavior | `scry/regressions/` |

Historical round coverage is organized under `scry/behavior/` by behavior name. Each former top-level
round section is now an isolated spec file with its own RSpec lifecycle, so one failing behavior does not hide later
examples. The original round-to-behavior mapping is recorded in `/tmp/rails-scry-round-manifest.txt` during the
reorganization. The five registry `freeze!` examples and the ScopeEvaluator spec were removed with those confirmed
legacy APIs; the remaining 223 round examples were retained.
The relation-composition and permission-resolution batches now live in `regressions/relation_composition_spec.rb` and `regressions/permission_resolution_spec.rb`. Their fixtures and assertions are preserved, with the error metadata expectation extended for the new discovery fields. The remaining `round*_coverage_spec.rb` files stay in place for gradual migration as their contracts change.

The standalone runner exercises adapter behavior without a Rails application. See the main README for its isolated bundle commands.
PostgreSQL-specific tests use temporary tables inside fixture transactions. Subprocess adapter tests use separate in-memory SQLite databases.

The shared review regressions live in `support/interoperability_boundaries.rb`, which includes `support/candidate_projection_contracts.rb`. The PostgreSQL suite includes them through `scry/interoperability/review_boundaries_spec.rb`. Run them without Rails using `RAILS_VERSION=8.1 SCRY_ADAPTER=sqlite3 ruby script/adapter_regressions.rb`; the adapter bundle commands are documented in the main README. Select `mysql2` or `postgresql` for the other adapters. MySQL requires an isolated test database and uses ordinary fixture tables with cleanup.

The original 21 review regression examples produced 20 failures before fixes (the missing valid ID control already passed). Later regressions cover extension validation, composed application scopes, serializers, and issues found during final review.

The follow-up implementation and final validation results are recorded in `docs/review-followup-progress.md`. Run `bundle exec rake` for specs plus the focused lint gate; `bundle exec rubocop` remains the optional broader style audit.

The current follow-up is recorded in `docs/council-followup-progress.md`. Supported dependency lines start at ActiveRecord 7.1.
