<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/eval/appquery/main/.github/banner-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/eval/appquery/main/.github/banner-light.svg">
  <img alt="AppQuery - Raw SQL, ergonomically" src="https://raw.githubusercontent.com/eval/appquery/main/.github/banner-light.svg" width="100%">
</picture>

<p align="center">
  <strong>Ergonomic raw SQL queries for ActiveRecord</strong>
</p>

<p align="center">
  <a href="https://rubygems.org/gems/appquery"><img src="https://img.shields.io/gem/v/appquery.svg?style=flat-square&color=blue" alt="Gem Version"></a>
  <a href="https://github.com/eval/appquery/actions/workflows/main.yml"><img src="https://img.shields.io/github/actions/workflow/status/eval/appquery/main.yml?branch=main&style=flat-square&label=CI" alt="CI Status"></a>
  <a href="https://eval.github.io/appquery/"><img src="https://img.shields.io/badge/docs-YARD-blue.svg?style=flat-square" alt="API Docs"></a>
  <a href="https://rubygems.org/gems/appquery"><img src="https://img.shields.io/gem/dt/appquery.svg?style=flat-square&color=orange" alt="Downloads"></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-green.svg?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="#installation">Installation</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#usage">Usage</a> •
  <a href="#api-documentation">API Docs</a> •
  <a href="#compatibility">Compatibility</a>
</p>

---

A Ruby gem for working with raw SQL in Rails. Store queries in `app/queries/`, execute with proper type casting, filter/transform using CTEs, and parameterize via ERB.

```ruby
# Load and execute
week = AppQuery[:weekly_sales].with_binds(week: 1, year: 2025)
week.entries
#=> [{"week" => 2025-01-13, "category" => "Electronics", "revenue" => 12500, "target_met" => true}, ...]

# Filter results (query wraps in CTE, :_ references it)
week.count
#=> 5
week.count("SELECT * FROM :_ WHERE NOT target_met")
#=> 3

# Extract a column efficiently (only fetches that column)
week.column(:category)
#=> ["Electronics", "Clothing", "Home & Garden"]

# Named binds with defaults
AppQuery[:weekly_sales].select_all(binds: {min_revenue: 5000})

# ERB templating
AppQuery("SELECT * FROM contracts <%= order_by(ordering) %>")
  .render(ordering: {year: :desc}).select_all

# Custom type casting
AppQuery("SELECT metadata FROM products").select_all(cast: {metadata: :json})

# Inspect/mock CTEs for testing
query.prepend_cte("sales AS (SELECT * FROM mock_data)")
```

## Highlights

| Feature | Description |
|---------|-------------|
| **Query Files** | Store SQL in `app/queries/` with Rails generator |
| **Execution** | `select_all` / `select_one` / `select_value` / `count` / `column` / `ids` |
| **CTE Manipulation** | Query transformation via `prepend_cte` / `append_cte` / `replace_cte` |
| **Immutable** | Derive new queries from existing ones |
| **Named Binds** | Safe parameterization with automatic defaults |
| **ERB Helpers** | `order_by`, `paginate`, `values`, `bind` |
| **Type Casting** | Automatic + custom type casting |
| **RSpec Integration** | Built-in matchers and helpers for testing |
| **Export** | Stream results via `copy_to` (PostgreSQL) |

> [!IMPORTANT]
> **Status**: Using in production for multiple projects, but API might change pre v1.0.
> See [the CHANGELOG](./CHANGELOG.md) for breaking changes when upgrading.

## Rationale

Sometimes ActiveRecord doesn't cut it: you need performance, prefer raw SQL over Arel, and hash-maps suffice instead of full ActiveRecord instances.

That introduces new problems: the not-so-intuitive `select_all`/`select_one`/`select_value` methods differ in type casting behavior across ActiveRecord versions. Then there's testability, introspection, and maintainability of SQL queries.

**AppQuery** provides:
- Consistent interface across `select_*` methods and ActiveRecord versions
- Easy inspection and testing—especially for CTE-based queries
- Clean parameterization via named binds and ERB

## Installation

```bash
bundle add appquery
```

## Quick Start

Generate a query:

```bash
rails g query weekly_sales
```

Write your SQL in `app/queries/weekly_sales.sql`:

```sql
SELECT week, category, revenue
FROM sales
WHERE week = :week AND year = :year
ORDER BY revenue DESC
```

Execute it:

```ruby
AppQuery[:weekly_sales].select_all(binds: {week: 1, year: 2025})
#=> [{"week" => 1, "category" => "Electronics", "revenue" => 12500}, ...]
```

## Usage

> [!NOTE]
> The following examples show how this gem handles raw SQL. The included [example Rails app](./examples/demo) contains runnable queries.

### Console Exploration

```ruby
# Testdrive from console
[postgresql]> AppQuery(%{select date('now') as today}).select_all.entries
=> [{"today" => Fri, 02 Jan 2026}]

[postgresql]> AppQuery(%{select date('now') as today}).select_one
=> {"today" => Fri, 02 Jan 2026}

[postgresql]> AppQuery(%{select date('now') as today}).select_value
=> Fri, 02 Jan 2026
```

<details>
<summary><strong>Database setup</strong> (the <code>bin/console</code> script does this for you)</summary>

```ruby
ActiveRecord::Base.logger = Logger.new(STDOUT)
ActiveRecord::Base.establish_connection(url: 'postgres://localhost:5432/some_db')
```
</details>

### Type Casting

Values are automatically cast (unlike raw ActiveRecord):

```ruby
# AppQuery
AppQuery(%{select date('now') as today}).select_one
=> {"today" => Fri, 02 Jan 2026}

# Compare with raw ActiveRecord
ActiveRecord::Base.connection.select_one(%{select date('now') as today})
=> {"today" => "2025-12-20"}  # String, not Date!

# Custom casting
AppQuery("SELECT metadata FROM products").select_all(cast: {metadata: :json})
```

### Named Binds

```ruby
# Named binds
AppQuery(%{select now() - (:interval)::interval as date})
  .select_value(binds: {interval: '2 days'})

# Binds default to nil - add SQL defaults via COALESCE
AppQuery(<<~SQL).select_all(binds: {ts1: 2.days.ago, ts2: Time.now})
  SELECT generate_series(
    :ts1::timestamp,
    :ts2::timestamp,
    COALESCE(:interval, '5 minutes')::interval
  ) AS series
SQL
```

### CTE Manipulation

Rewrite queries using CTEs:

```ruby
articles = [
  [1, "Using my new static site generator", 2.months.ago.to_date],
  [2, "Let's learn SQL", 1.month.ago.to_date],
]

q = AppQuery(<<~SQL, cast: {published_on: :date}).render(articles:)
  WITH articles(id, title, published_on) AS (<%= values(articles) %>)
  SELECT * FROM articles ORDER BY id DESC
SQL

# Query the CTE directly
q.select_all("SELECT * FROM articles WHERE id < 2")

# Query the result (via :_ placeholder)
q.select_one("SELECT * FROM :_ LIMIT 1")
q.first  # shorthand

# Rewrite CTEs
q.replace_cte("settings(cutoff) AS (VALUES(DATE '2024-01-01'))")
q.prepend_cte("mock_data AS (SELECT 1)")
q.append_cte("extra AS (SELECT 2)")
```

### ERB Templating

```ruby
# Dynamic ORDER BY
q = AppQuery("SELECT * FROM articles <%= order_by(ordering) %>")
q.render(ordering: {published_on: :desc, title: :asc}).select_all

# Pagination
AppQuery("SELECT * FROM users <%= paginate(page: page, per_page: per_page) %>")
  .render(page: 2, per_page: 25).select_all

# Optional clauses using instance variables
AppQuery(<<~SQL).render(order: nil)  # @order is nil, clause is skipped
  SELECT * FROM articles
  <%= @order.presence && order_by(order) %>
SQL
```

### Data Export (PostgreSQL)

```ruby
# Return as string
csv = AppQuery[:users].copy_to
#=> "id,name\n1,Alice\n2,Bob\n..."

# Write to file
AppQuery[:users].copy_to(to: "export.csv")

# Stream to IO
File.open("users.csv.gz", "wb") do |f|
  gz = Zlib::GzipWriter.new(f)
  AppQuery[:users].copy_to(to: gz)
  gz.close
end
```

### RSpec Integration

Generated spec files include helpers:

```ruby
# spec/queries/reports/weekly_query_spec.rb
RSpec.describe "AppQuery reports/weekly", type: :query, default_binds: [] do
  describe "CTE articles" do
    specify do
      expect(described_query.select_all("SELECT * FROM :cte")).to \
        include(a_hash_including("article_id" => 1))

      # Short version: query, cte and select are implied from descriptions
      expect(select_all).to include(a_hash_including("article_id" => 1))
    end
  end
end
```

## API Documentation

See the [YARD documentation](https://eval.github.io/appquery/) for the full API reference.

## Compatibility

| Component | Supported |
|-----------|-----------|
| **Databases** | PostgreSQL, SQLite |
| **Rails** | 7.x, 8.x |
| **Ruby** | 3.3+ ([maintained versions](https://www.ruby-lang.org/en/downloads/branches/)) |

## Development

```bash
# Setup
bin/setup  # Make sure it exits with code 0

# Console (connects to database)
bin/console sqlite3::memory:
bin/console postgres://localhost:5432/some_db

# With specific Rails version
bin/run rails_head console

# Run tests
rake spec
```

Using [mise](https://mise.jdx.dev/) for env-vars is recommended.

### Releasing

Create a signed git tag and push:

```bash
# Regular release
git tag -s 1.2.3 -m "Release 1.2.3"

# Prerelease
git tag -s 1.2.3.rc1 -m "Release 1.2.3.rc1"

git push origin --tags
```

CI will build, sign (Sigstore attestation), push to RubyGems, and create a GitHub release.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/eval/appquery.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
