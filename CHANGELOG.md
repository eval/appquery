## [Unreleased]

### ✨ Features

- Add `any?`, `none?` - efficient ways to see if there's any results for a query.
- 🎯 **Cast type shorthands** — use symbols instead of explicit type classes
  ```ruby
  query.select_all(cast: {"published_on" => :date})
  # instead of
  query.select_all(cast: {"published_on" => ActiveRecord::Type::Date.new})
  ```
  Supports all ActiveRecord types including adapter-specific ones (`:uuid`, `:jsonb`, etc.).
- 🔑 **Indifferent access** — for rows and cast keys
  ```ruby
  row = query.select_one
  row["name"]  # works
  row[:name]   # also works

  # cast keys can be symbols too
  query.select_all(cast: {published_on: :date})
  ```  

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

- 🍾 **Add paginate ERB-helper**
  ```ruby
  SELECT * FROM articles
    <%= paginate(page: 1, per_page: 15) %>
  # SELECT * FROM articles LIMIT 15 OFFSET 0
  ```
- 🧰 **Resolve query without extension**  
  `AppQuery[:weekly_sales]` loads `weekly_sales.sql` or `weekly_sales.sql.erb`.
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
