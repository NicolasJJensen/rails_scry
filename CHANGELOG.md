# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Filter diagnostics now identify the offending payload field or argument within
  nested filters, expressions, and ordering. Consumers that compare complete
  diagnostic paths must account for the new field and argument-index suffixes.

### Fixed

- Preserve diagnostics from partially valid association and aggregate scopes, and
  retain child diagnostics when group ordering also fails.

### Documentation

- Add complete JSON, HTML, Turbo Frame, and Turbo Stream response examples with
  retained form input, error summaries, and accessible field-error bindings.
- Clarify default exclusions for encrypted attributes and belongs-to foreign keys,
  and the model-permission requirements for association filtering.

## [0.1.0] - 2026-09-21

### Added

- Initial release.
