## [Unreleased]

## [0.5.0] - 2025-12-21

### 💥 Breaking Changes

- 🔄 **`select:` keyword argument removed** — use positional argument instead
  ```ruby
  # before
  query.select_all(select: "SELECT * FROM :_")
  # after
  query.select_all("SELECT * FROM :_")
  ```

### ✨ Features

- 🔗 **Nested result queries** via `with_select` — chain transformations using `:_` placeholder to reference the previous result
  ```ruby
  active_users = AppQuery("SELECT * FROM users").with_select("SELECT * FROM :_ WHERE active")
  active_users.count("SELECT * FROM :_ WHERE admin")
  ```
- 🚀 **New methods**: `#column`, `#ids`, `#count`, `#entries` — efficient shortcuts that only fetch what you need
  ```ruby
  query.column(:email)  # SELECT email only
  query.ids             # SELECT id only
  query.count           # SELECT COUNT(*) only
  query.entries         # shorthand for select_all.entries
  ```

### 🐛 Fixes

- 🔧 Fix leading whitespace in `prepend_cte` causing parse errors
- 🔧 Fix binds being reset when no placeholders found
- ⚡ `select_one` now uses `LIMIT 1` for better performance

### 📚 Documentation

- 📖 Revised README with cleaner intro and examples
- 🏠 Added example Rails app in `examples/demo`

## [0.4.0] - 2025-12-15

### features

- add insert, update and delete
- API docs at [eval.github.io/appquery](https://eval.github.io/appquery)
- add ERB-helpers [values, bind and quote ](https://eval.github.io/appquery/AppQuery/RenderHelpers.html).
- enabled trusted publishing to rubygems.org
