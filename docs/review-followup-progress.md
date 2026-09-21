# Review follow-up

Completed regression tests first, compatibility improvements second, and remaining bug fixes third.
AF-R2 is excluded: host applications register extensions during boot or Rails preparation, not while requests execute.
AF-R4 rejects invalid projections. AF-R7 returns empty/error metadata for unsupported models. Previously implemented fixes were retained.

| Work | Result |
|---|---|
| AF-R1 scalar association IDs | Normalize scalar set-filter IDs consistently; missing IDs no longer become an empty requested set. Preserve direct Arel scalar rejection. |
| AF-R3 integer aggregate operands | Reject fractional numeric operands and range bounds instead of truncating them. |
| AF-R4 projection guards | Reject missing primary keys in DISTINCT candidates, raw Arel candidates, derived sources, and grouped membership projections before execution. |
| AF-R5 Arel collisions | Detect private and protected helper collisions before installing extensions. |
| AF-R6 diagnostic paths | Preserve full paths through malformed children, nested scoping, and projection failures. |
| AF-R7 unsupported discovery | Return empty/error metadata for models without Filterable. |
| AF-R8 diagnostic robustness | Logging, serialization, and enrichment failures cannot replace the original filter error; invalid model labels are handled. |
| Invalid-tree policy | Add opt-in reject and match_none policies; retain skip as the default. Validation still collects diagnostics. |
| Extension contracts | Validate custom metadata and expose immutable registry mapping snapshots. Preserve callback programming errors and the existing nil-definition error. |
| Boot/preparation lifecycle | Use warm! terminology and warm both registries, with reloadable extension classes refreshed through a Rails preparation callback. |
| Compatibility gates | Make default rake run specs plus focused correctness/security lint; retain optional broad RuboCop. Configure minimum-Ruby adapter CI pairs. |
| Performance and support | Retain portable SQL after bounded tenant-scoped measurements; document support boundaries and lifecycle requirements. |

## Test-first evidence

The prior PostgreSQL baseline was 843 examples passing. Initial follow-up batches exposed 43 failing cases before implementation, with additional projection edge cases reproduced before their fixes. Existing passing controls were retained. The final suite contains 907 examples.

## Final validation

- `bundle exec rake`: 907 examples, 0 failures; 144 Ruby files linted, no offenses.
- Standalone SQLite shared contracts: 92 examples, 0 failures each on Rails 7.1, 8.0, and 8.1.
- `bundle exec rbs -I sig validate`: passed.
- `git diff --check`: passed.
- A bounded tenant-scoped candidate-query benchmark was run; no speculative SQL rewrite was introduced.

MySQL, the minimum Ruby versions, and the remaining Rails matrix cells were configured for CI but not executed locally. These checks do not establish compatibility with every third-party gem. No commits or staging operations were performed.
