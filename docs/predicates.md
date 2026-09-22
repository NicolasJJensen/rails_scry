# Built-in predicates

See the [README](../README.md#building-filters) for common examples, the [filter reference](filters.md) for payloads, and [extensions](extensions.md#custom-predicates) for registration.

## Contents

- [Global](#global)
- [Numerical](#numerical)
- [Temporal](#temporal)
- [Textual](#textual)
- [Boolean](#boolean)
- [JSON](#json)
- [PostgreSQL: Network](#postgresql-network)
- [PostgreSQL: Array](#postgresql-array)
- [PostgreSQL: Range](#postgresql-range)
- [Compound variants](#compound-variants)

## Global

Available on most column types.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `eq` | 1 | `= value` | `"Alice"` |
| `not_eq` | 1 | `!= value` | `"Alice"` |
| `eq_nil` | 0 | `IS NULL` | *(none)* |
| `not_eq_nil` | 0 | `IS NOT NULL` | *(none)* |

`eq` and `not_eq` auto-generate compound variants: `eq_any`, `eq_all`, `not_eq_any`, `not_eq_all`.

## Numerical

For integer, float, decimal, and temporal columns.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `gt` | 1 | `> value` | `100` |
| `lt` | 1 | `< value` | `100` |
| `gteq` | 1 | `>= value` | `100` |
| `lteq` | 1 | `<= value` | `100` |
| `between` | 2 | `BETWEEN low AND high` | `[18, 65]` |
| `not_between` | 2 | `NOT BETWEEN low AND high` | `[18, 65]` |

For `between` and `not_between`, pass a two-element array `[low, high]`. The gem auto-sorts if low > high.

## Temporal

For date, time, datetime, and timestamp columns. Values are [ISO 8601 duration](https://en.wikipedia.org/wiki/ISO_8601#Durations) strings.

| Predicate | Params | Description | Example value |
|-----------|--------|-------------|---------------|
| `within` | 1 | Between `duration.ago` and `duration.since` | `"P7D"` |
| `within_next` | 1 | Between now and `duration.since` | `"P30D"` |
| `within_previous` | 1 | Between `duration.ago` and now | `"PT12H"` |
| `not_within` | 1 | Outside `duration.ago` to `duration.since` | `"P1Y"` |
| `not_within_next` | 1 | Before now or after `duration.since` | `"P7D"` |
| `not_within_previous` | 1 | Before `duration.ago` or after now | `"P7D"` |

**Duration format examples:** `"P1D"` (1 day), `"P7D"` (7 days), `"PT2H"` (2 hours), `"P1M"` (1 month), `"P1Y"` (1 year), `"P1Y6M"` (1 year 6 months).

## Textual

For string, text, and enum columns. Values are automatically escaped for SQL LIKE.

| Predicate | Params | SQL | Example value |
|-----------|--------|-----|---------------|
| `matches` | 1 | `LIKE '%value%'` | `"alice"` |
| `starts_with` | 1 | `LIKE 'value%'` | `"ali"` |
| `ends_with` | 1 | `LIKE '%value'` | `"ice"` |
| `does_not_match` | 1 | `NOT LIKE '%value%'` | `"alice"` |
| `does_not_start_with` | 1 | `NOT LIKE 'value%'` | `"ali"` |
| `does_not_end_with` | 1 | `NOT LIKE '%value'` | `"ice"` |

All textual predicates auto-generate compound variants (`matches_any`, `matches_all`, etc.).

> **Note:** Regexp predicates (`matches_regexp`, `does_not_match_regexp`) are not registered by default for security. Register them manually if needed.

## Boolean

For boolean columns.

| Predicate | Params | SQL |
|-----------|--------|-----|
| `eq_true` | 0 | `= true` |
| `eq_false` | 0 | `= false` |

## JSON

For json/jsonb columns.

| Predicate | Params | SQL |
|-----------|--------|-----|
| `contains` | 1 | `@>` (PostgreSQL containment) |

## PostgreSQL: Network

For inet and cidr columns.

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `inet_contains` | 1 | `>>` | Network contains address |
| `inet_contained_within` | 1 | `<<` | Address is within network |
| `inet_overlaps` | 1 | `&&` | Networks overlap |

## PostgreSQL: Array

For PostgreSQL array columns.

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `array_contains` | 1 | `@>` | Array contains all elements |
| `array_contained_by` | 1 | `<@` | Array is subset of value |
| `array_overlaps` | 1 | `&&` | Arrays share elements |

## PostgreSQL: Range

For PostgreSQL range columns (daterange, tsrange, int4range, etc.).

| Predicate | Params | Operator | Description |
|-----------|--------|----------|-------------|
| `range_contains` | 1 | `@>` | Range contains value |
| `range_contained_by` | 1 | `<@` | Range is within value |
| `range_overlaps` | 1 | `&&` | Ranges overlap |
| `range_strictly_left_of` | 1 | `<<` | Range is left of value |
| `range_strictly_right_of` | 1 | `>>` | Range is right of value |
| `range_adjacent_to` | 1 | `-\|-` | Range is adjacent to value |

## Compound variants

Predicates registered with `compounds: true` opt in to generated `_any` and `_all` variants:

- `eq_any` - matches if the value equals **any** element in the array
- `eq_all` - matches if the value equals **all** elements in the array (useful with transforms)

```ruby
# Users named "Alice" OR "Bob" (eq_any)
{ type: "property", property: "first_name", predicate: "eq_any", args: [["Alice", "Bob"]] }
```

Association and boolean predicates do not generate compounds.
