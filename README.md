# AppQuery - raw SQL 🥦, cooked :stew:

[![Gem Version](https://badge.fury.io/rb/appquery.svg)](https://badge.fury.io/rb/appquery)
[![API Docs](https://img.shields.io/badge/API_Docs-YARD-blue.svg)](https://eval.github.io/appquery/)

A Ruby gem providing ergonomic raw SQL queries for ActiveRecord. Inline or stored queries in `app/queries/`, execute them with proper type casting, filter/transform results using CTEs and have parameterization via ERB.

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

**Highlights**: query files with generator · `select_all`/`select_one`/`select_value`/`count`/`column`/`ids` · query transformation via CTEs · immutable (derive new queries from existing) · named binds · ERB helpers (`order_by`, `paginate`, `values`, `bind`) · automatic + custom type casting · RSpec integration

> [!IMPORTANT]  
> **Status**: using it in production for multiple projects, but API might change pre v1.0. See [the CHANGELOG](./CHANGELOG.md) for breaking changes when upgrading.
>

## Rationale

Sometimes ActiveRecord doesn't cut it: you need performance, would rather use raw SQL instead of Arel and hash-maps are fine instead of full-fledge ActiveRecord instances.  
That, however, introduces some new problems. First of all, you'll run into the not-so-intuitive use of [select_(all|one|value)](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html#method-i-select_all) — for example, how they differ with respect to type casting, and how their behavior can vary between ActiveRecord versions. Then there's the testability, introspection, and maintainability of the resulting SQL queries.  

This library aims to alleviate all of these issues by providing a consistent interface across select_* methods and ActiveRecord versions. It should make inspecting and testing queries easier—especially when they're built from CTEs.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add appquery
```

## Usage

> [!NOTE]
> The following (trivial) examples are not meant to convince you to ditch your ORM, but just to show how this gem handles raw SQL queries.

### ...from console

Testdriving can be easily done from the console. Either by cloning this repository (recommended, see `Development`-section) or installing the gem in an existing Rails project.  
<details>
  <summary>Database setup (the `bin/console`-script does this for your)</summary>
  
  ```ruby
  ActiveRecord::Base.logger = Logger.new(STDOUT)
  ActiveRecord::Base.establish_connection(url: 'postgres://localhost:5432/some_db')
  ```
</details>

The prompt indicates what adapter the example uses:

```ruby
# showing select_(all|one|value)
[postgresql]> AppQuery(%{select date('now') as today}).select_all.entries
=> [{"today" => Fri, 02 Jan 2026}]
[postgresql]> AppQuery(%{select date('now') as today}).select_one
=> {"today" => Fri, 02 Jan 2026}
[postgresql]> AppQuery(%{select date('now') as today}).select_value
=> Fri, 02 Jan 2026

# casting
# As can be seen from these examples, values are automatically casted.

## compare ActiveRecord
[postgresql]> ActiveRecord::Base.connection.select_one(%{select date('now') as today})
=> {"today" => "2025-12-20"}

## SQLite doesn't have a notion of dates or timestamp's so casting won't do anything:
[sqlite]> AppQuery(%{select date('now') as today}).select_one(cast: true)
=> {"today" => "2025-05-12"}
## Providing per-column-casts fixes this:
cast = {today: :date}
[sqlite]> AppQuery(%{select date('now') as today}).select_one(cast:)
=> {"today" => Mon, 12 May 2025}

# binds
## named binds
[postgresql]> AppQuery(%{select now() - (:interval)::interval as date}).select_value(binds: {interval: '2 days'})
=> 2025-12-31 12:57:27.41132 UTC

## not all binds need to be provided (ie they are nil by default) - so defaults can be added in SQL:
[postgresql]> AppQuery(<<~SQL).select_all(binds: {ts1: 2.days.ago, ts2: Time.now, interval: '1 hour'}).column("series")
    SELECT generate_series(
      :ts1::timestamp,
      :ts2::timestamp,
      COALESCE(:interval, '5 minutes')::interval
    ) AS series
  SQL
=>
[2025-12-31 12:57:46.969709 UTC,
 2025-12-31 13:57:46.969709 UTC,
 2025-12-31 14:57:46.969709 UTC,
 ...]

# rewriting queries (using CTEs)
[postgresql]> articles = [
  [1, "Using my new static site generator", 2.months.ago.to_date],
  [2, "Let's learn SQL", 1.month.ago.to_date],
  [3, "Another article", 2.weeks.ago.to_date]
]
[postgresql]> q = AppQuery(<<~SQL, cast: {published_on: :date}).render(articles:)
  WITH articles(id,title,published_on) AS (<%= values(articles) %>)
  select * from articles order by id DESC
SQL

## query the articles-CTE
[postgresql]> q.select_all(%{select * from articles where id::integer < 2}).entries

## query the end-result (available via the placeholder ':_')
[postgresql]> q.select_one(%{select * from :_ limit 1})
### shorthand for that
[postgresql]> q.first

## ERB templating
# Extract a query from q that can be sorted dynamically:
[postgresql]> q2 = q.with_select("select id,title,published_on::date from articles <%= order_by(order) %>")
[postgresql]> q2.render(order: {"published_on::date": :desc, 'lower(title)': "asc"}).select_all.entries

# shows latest articles first, and titles sorted alphabetically
# for articles published on the same date.
# order_by raises when it's passed something that would result in just `ORDER BY`:
[postgresql]> q2.render(order: {})

# doing a select using a query that should be rendered, a `AppQuery::UnrenderedQueryError` will be raised:
[postgresql]> q2.select_all.entries

# NOTE you can use both `order` and `@order`: local variables like `order` are required,
# while instance variables like `@order` are optional.
# To skip the order-part when provided:
<%= @order.presence && order_by(order) %>
# or use a default when order-part is always wanted but not always provided:
<%= order_by(@order || {id: :desc}) %>
```


### ...in a Rails project

> [!NOTE]
> The included [example Rails app](./examples/demo) contains all data and queries described below.

Create a query:  
```bash
rails g query recent_articles
```

Have some SQL (for SQLite, in this example):
```sql
-- app/queries/recent_articles.sql
WITH settings(min_published_on) as (
  values(COALESCE(:since, datetime('now', '-6 months')))
),

recent_articles(article_id, article_title, article_published_on, article_url) AS (
  SELECT id, title, published_on, url
  FROM articles
  RIGHT JOIN settings
  WHERE published_on > settings.min_published_on
),

tags_by_article(article_id, tags) AS (
  SELECT articles_tags.article_id,
    json_group_array(tags.name) AS tags
  FROM articles_tags
  JOIN tags ON articles_tags.tag_id = tags.id
  GROUP BY articles_tags.article_id
)

SELECT recent_articles.*,
       group_concat(json_each.value, ',' ORDER BY value ASC) tags_str
FROM recent_articles
JOIN tags_by_article USING(article_id),
  json_each(tags)
WHERE EXISTS (
  SELECT 1
  FROM json_each(tags)
  WHERE json_each.value LIKE :tag OR :tag IS NULL
)
GROUP BY recent_articles.article_id
ORDER BY recent_articles.article_published_on
```

The result would look like this:

```ruby
[{"article_id"=>292,
 "article_title"=>"Rails Versions 7.0.8.2, and 7.1.3.3 have been released!",
 "article_published_on"=>"2024-05-17",
 "article_url"=>"https://rubyonrails.org/2024/5/17/Rails-Versions-7-0-8-2-and-7-1-3-3-have-been-released",
 "tags_str"=>"release:7x,release:revision"},
...
]
```

Even for this fairly trivial query, there's already quite some things 'encoded' that we might want to verify or capture in tests:
- only certain columns
- only published articles
- only articles _with_ tags
- only articles published after some date
  - either provided or using the default
- articles are sorted in a certain order
- tags appear in a certain order and are formatted a certain way

Using the SQL-rewriting capabilities shown below, this library allows you to express these assertions in tests or verify them during development.

### Verify query results

> [!NOTE]
> There's `AppQuery#select_all`, `AppQuery#select_one` and `AppQuery#select_value` to execute a query. `select_(all|one)` are tiny wrappers around the equivalent methods from `ActiveRecord::Base.connection`.  
> Instead of [positional arguments](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html#method-i-select_all), these methods accept keywords `select`, `binds` and `cast`. See below for examples.

Given the query above, you can get the result like so:
```ruby
AppQuery[:recent_articles].select_all.entries
# =>
[{"article_id"=>292,
 "article_title"=>"Rails Versions 7.0.8.2, and 7.1.3.3 have been released!",
 "article_published_on"=>"2024-05-17",
 "article_url"=>"https://rubyonrails.org/2024/5/17/Rails-Versions-7-0-8-2-and-7-1-3-3-have-been-released",
 "tags_str"=>"release:7x,release:revision"},
...
]

# we can provide a different cut off date via binds:
AppQuery[:recent_articles].select_all(binds: {since: 1.month.ago}).entries

# NOTE: by default the binds get initialized with nil, e.g. for this example {since: nil, tag: nil}
# This prevents you from having to provide all binds every time. Default values are put in the SQL (via COALESCE).
```

We can also dig deeper by query-ing the result, i.e. the CTE `:_`:

```ruby
AppQuery[:recent_articles].select_one("select count(*) as cnt from :_")
# => {"cnt" => 13}

# For these kind of aggregate queries, we're only interested in the value:
AppQuery[:recent_articles].select_value("select count(*) from :_")
# => 13

# but there's also the shorthand #count (which takes a sub-select):
AppQuery[:recent_articles].count #=> 13
AppQuery[:recent_articles].count(binds: {since: 0}) #=> 275
```

Use `AppQuery#with_select` to get a new AppQuery-instance with the rewritten SQL:
```ruby
puts AppQuery[:recent_articles].with_select("select id from :_")
```


### Verify CTE results

You can select from a CTE similarly:
```ruby
AppQuery[:recent_articles].select_all("SELECT * FROM tags_by_article")
# => [{"article_id"=>1, "tags"=>"[\"release:pre\",\"release:patch\",\"release:1x\"]"},
      ...]

# NOTE how the tags are json strings. Casting allows us to turn these into proper arrays^1:
cast = {tags: :json}
AppQuery[:recent_articles].select_all("SELECT * FROM tags_by_article", cast:)

1) unlike SQLite, PostgreSQL has json and array types. Just casting suffices:
AppQuery("select json_build_object('a', 1, 'b', true)").select_one(cast: true)
# => {"json_build_object"=>{"a"=>1, "b"=>true}}
```

Using the methods `(prepend|append|replace)_cte`, we can rewrite the query beyond just the select:

```ruby
AppQuery[:recent_articles].replace_cte(<<~SQL).select_all.entries
settings(min_published_on) as (
  values(datetime('now', '-12 months'))
)
SQL
```

You could even mock existing tables (using PostgreSQL):
```ruby
# using Ruby data:
sample_articles = [{id: 1, title: "Some title", published_on: 3.months.ago},
                   {id: 2, title: "Another title", published_on: 1.months.ago}]
# show the provided cutoff date works
AppQuery[:recent_articles].prepend_cte(<<-CTE).select_all(binds: {since: 6.weeks.ago, articles: JSON[sample_articles]}).entries
articles AS (
  SELECT * from json_to_recordset(:articles) AS x(id int, title text, published_on timestamp)
)
CTE
```

Use `AppQuery#with_select` to get a new AppQuery-instance with the rewritten sql:
```ruby
puts AppQuery[:recent_articles].with_select("select * from some_cte")
```

### Spec

When generating a query `reports/weekly`, a spec-file like below is generated:

```ruby
# spec/queries/reports/weekly_query_spec.rb
require "rails_helper"

RSpec.describe "AppQuery reports/weekly", type: :query, default_binds: [] do
  describe "CTE articles" do
    specify do
      expect(described_query.select_all("select * from :cte")).to \
        include(a_hash_including("article_id" => 1))

      # short version: query, cte and select are all implied from descriptions
      expect(select_all).to include(a_hash_including("article_id" => 1))
    end
  end
end
```

There's some sugar:
- `described_query`  
  ...just like `described_class` in regular class specs.  
  It's an instance of `AppQuery` based on the last word of the top-description (i.e. "reports/weekly" from "AppQuery reports/weekly").
- `:cte` placeholder  
  When doing `select_all`, you can rewrite the `SELECT` of the query by passing `select`. There's no need to use the full name of the CTE as the spec-description contains the name (i.e. "articles" in "CTE articles").
- default_binds  
  The `binds`-value used when not explicitly provided.  

## API Documentation

See the [YARD documentation](https://eval.github.io/appquery/) for the full API reference.

## Compatibility

- 💾 tested with **SQLite** and **PostgreSQL**
- 🚆 tested with Rails v7.x and v8.x (might still work with v6.1, but is no longer included in the test-matrix)
- 💎 requires Ruby **>=v3.2**  
  Goal is to support [maintained Ruby versions](https://www.ruby-lang.org/en/downloads/branches/).

## Development

After checking out the repo, run `bin/setup` to install dependencies. **Make sure to check it exits with status code 0.**

Using [mise](https://mise.jdx.dev/) for env-vars recommended.

### console

The [console-script](./bin/console) is setup such that it's easy to connect with a database and experiment with the library:
```bash
$ bin/console sqlite3::memory:
$ bin/console postgres://localhost:5432/some_db

# more details
$ bin/console -h

# when needing an appraisal, use bin/run (this ensures signals are handled correctly):
$ bin/run rails_head console
```

### various

Run `rake spec` to run the tests.

To install this gem onto your local machine, run `bundle exec rake install`.

### Releasing

Create a signed git tag and push:

```bash
# Regular release
git tag -s 1.2.3 -m "Release 1.2.3"

# Prerelease
git tag -s 1.2.3.rc1 -m "Release 1.2.3.rc1"

# Push the tag
git push origin --tags
```

CI will build the gem, sign it (Sigstore attestation), push to RubyGems, and create a GitHub release (see [release.yml](https://github.com/eval/appquery/blob/3ed2adfacf952acc191a21a44b7c43a375b8975b/.github/workflows/release.yml#L34)).

After the release, update version.rb to the next dev version:

```ruby
VERSION = "1.2.4.dev"
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/eval/appquery.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
