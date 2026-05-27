## [Unreleased]

### 💥 Breaking Changes

- ⚠️ **`AppQuery::Mappable` extension API changed.**  
  Row-level middleware now appends a transformer to the underlying `Q`'s `row_builder` pipeline via an overridden `#query`, instead of overriding `select_all`/`select_one`. The previous pattern of overriding those two methods will silently do nothing on row-returning paths it didn't cover (`entries`, `first`, `last`, `take`, `with_select(non_nil).first`, …). Any custom middleware that overrode `select_all`/`select_one` should migrate to:
  ```ruby
  def query
    @query ||= super.tap { |q| q.row_builder << method(:build_row) }
  end
  ```
- ⚠️ **`Q#column` now raises `ArgumentError` for unknown columns.**  
  Previously, on SQLite, `q.column(:typo)` silently returned a row per record containing the *string* `"typo"` (the SQLite "double-quoted strings are identifiers OR string literals" quirk masked the missing column). It now pre-validates against `column_names` and raises with the available column list — consistently across SQLite and PostgreSQL.

### ✨ Features

- 🧩 **`AppQuery::RowBuilder`** — composable pipeline of row transformers exposed as `Q#row_builder`. Append with `q.row_builder << callable`; transformers run in registration order. Multiple row-level middlewares stack cleanly in `include` order. The pipeline is applied everywhere `Q` exposes rows (`entries`, `first`, `last`, `take`, `take_last`, `with_select(...).first`, …) and is independently copied across `deep_dup` so chained queries don't mutate their parent.
- 🎯 **`Mappable` is now one method.** Maps everywhere — including `entries`, `last`, `take(n)`, `with_select("…").first` paths that previously slipped through. `raw` bypass still works.
- 🐛 **`Q#column` typo protection** — see breaking-change note above.
- 🐛 **Comments inside CTE selects** no longer break tokenization; the whole `(SELECT … -- foo … )` is preserved as a single `CTE_SELECT` token.
- Publishing gem requires MFA

## 0.8.0

**Releasedate**: 14-1-2026  
**Rubygems**: https://rubygems.org/gems/appquery/versions/0.8.0  

### 💥 Breaking Changes

- ⚠️ **RSpec helpers refactored**  
  Query under test is expected to be a class, `select_*` are no longer separate helpers:
  ```ruby
    expect(described_query.first).to \
      include("id" => be_a(Integer), ...)
    expect(described_query.entries).to include(a_hash_including("item_code" => "123456"))
  ```

### ✨ Features

- 📤 **`copy_to`** — efficient PostgreSQL COPY export to CSV/text/binary
  ```ruby
  # Return as string
  csv = AppQuery[:users].copy_to

  # Write to file
  AppQuery[:users].copy_to(dest: "export.csv")

  # Stream to IO (e.g., Rails response)
  query.copy_to(dest: response.stream)
  ```

- 🎯 **`cte(:name)`** — focus a query on a specific CTE for testing or inspection
  ```ruby
  query = AppQuery("WITH active AS (...), admins AS (...) SELECT ...")
  query.cte(:active).entries   # select from the active CTE
  query.cte(:admins).count     # count rows in admins CTE
  ```

- 🗃️ **`AppQuery.table(:name)`** — quick query from a table
  ```ruby
  AppQuery.table(:products).count
  AppQuery.table(:users).take(5)
  ```

- 🔢 **`take(n)` / `take_last(n)`** — fetch first or last n rows
  ```ruby
  query.take(5)       # first 5 rows
  query.take_last(5)  # last 5 rows
  ```

- ⏮️ **`last`** — fetch the last row (counterpart to `first`)
  ```ruby
  query.last  # => {"id" => 42, "name" => "Zoe"}
  ```

- 📋 **`column_names`** — get column names without fetching rows
  ```ruby
  query.column_names  # => ["id", "name", "email"]
  ```

- 🦄 **`unique:` keyword for `Q#column`** — return distinct values
  ```ruby
  query.column(:status, unique: true)  # => ["active", "pending"]
  ```

- 🏗️ **Overhauled generators** — moved to `AppQuery::` namespace
  ```bash
  rails g app_query:example # annotated example query
  rails g app_query:query Products
  rails g query Products  # hidden alias
  rails g query --help    # details
  ```

## 0.7.0

**Releasedate**: 8-1-2026  
**Rubygems**: https://rubygems.org/gems/appquery/versions/0.7.0  

### 💥 Breaking Changes

- ⛔ drop Ruby 3.2 support  
  Ruby 3.2 will be EOL in 2 months but is already no longer working for Rails >v8.1.

### ✨ Features

- 🗒️ Paginatable: unpaginated  
  Override any setting for pagination:
  ```ruby
  query = ArticlesQuery.build
  => #<RecentQuery:0x000000016ed7ef78 @page=1, @per_page=10, ...>
  query.unpaginated.count
  #=> 699
  ```
  Also: when `@page.nil?` then paginate erb-helper renders nothing:
  ```ruby
  # articles_query.erb.sql
  # before
  # skip pagination when we need the total count
  <%= @page && paginate(page:, per_page:) -%>
  # after
  <%= paginate(page:, per_page:) -%>
  ```
- 🌗 darkmode for API docs

### 🐛 Fixes

- 🔧 Fix literal strings containing parentheses breaking CTE-parsing.

## 0.6.0

**Releasedate**: 2-1-2026  
**Rubygems**: https://rubygems.org/gems/appquery/versions/0.6.0  

### ✨ Features

- 🏗️ **`AppQuery::BaseQuery`** — structured query objects with explicit parameter declaration
  ```ruby
  class ArticlesQuery < AppQuery::BaseQuery
    bind :author_id
    bind :status, default: nil
    var :order_by, default: "created_at DESC"
    cast published_at: :datetime
  end

  ArticlesQuery.new(author_id: 1).entries
  ArticlesQuery.new(author_id: 1, status: "draft").first
  ```
  Benefits over `AppQuery[:my_query]`:
  - Explicit `bind` and `var` declarations with defaults
  - Unknown parameter validation (catches typos)
  - Self-documenting: `ArticlesQuery.binds`, `ArticlesQuery.vars`
  - Middleware support via concerns

- 📄 **`AppQuery::Paginatable`** — pagination middleware (Kaminari-compatible)
  ```ruby
  class ApplicationQuery < AppQuery::BaseQuery
    include AppQuery::Paginatable
    per_page 25
  end

  # With count (full pagination)
  articles = ArticlesQuery.new.paginate(page: 1).entries
  articles.total_pages  # => 5

  # Without count (large datasets, uses limit+1 trick)
  articles = ArticlesQuery.new.paginate(page: 1, without_count: true).entries
  articles.next_page    # => 2 or nil
  ```

- 🗺️ **`AppQuery::Mappable`** — map results to Ruby objects
  ```ruby
  class ArticlesQuery < ApplicationQuery
    include AppQuery::Mappable

    class Item < Data.define(:title, :url, :published_on)
    end
  end

  articles = ArticlesQuery.new.entries
  articles.first.title  # => "Hello World"
  articles.first.class  # => ArticlesQuery::Item

  # Skip mapping
  ArticlesQuery.new.raw.entries.first  # => {"title" => "Hello", ...}
  ```

- 🔄 **`Result#transform!`** — transform result records in-place
  ```ruby
  result = AppQuery[:users].select_all
  result.transform! { |row| row.merge("full_name" => "#{row['first']} #{row['last']}") }
  ```

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
