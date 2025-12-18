# AppQuery - raw SQL 🥦, cooked :stew:

[![Gem Version](https://badge.fury.io/rb/appquery.svg)](https://badge.fury.io/rb/appquery)
[![API Docs](https://img.shields.io/badge/API_Docs-YARD-blue.svg)](https://eval.github.io/appquery/)

A Rubygem :gem: that makes working with raw SQL queries in Rails projects convenient.  
Specifically it provides:
- **...a dedicated folder for queries**  
  e.g. `app/queries/reports/weekly.sql` is instantiated via `AppQuery["reports/weekly"]`.

- **...ERB templating**  
  Simple ERB templating with helper-functions:
  ```sql
  -- app/queries/contracts.sql.erb
  SELECT * FROM contracts
  <%= order_by(order) %>
  ```
  ```ruby
  AppQuery[:contracts].render(order: {year: :desc, month: :desc}).select_all
  ```
- **...positional and named binds**  
  Intuitive binds:
  ```ruby
  AppQuery(<<~SQL).select_value(binds: {interval: '1 day'})
    select now() - (:interval)::interval as some_date
  SQL
  AppQuery(<<~SQL).select_all(binds: [2.day.ago, Time.now, '5 minutes']).column("series")
    select generate_series($1::timestamp, $2::timestamp, $3::interval) as series
  SQL
  ```
- **...casting**  
  Automatic and custom casting:
  ```ruby
  AppQuery(%{select array[1,2]}).select_value #=> [1,2]
  cast = {"data" => ActiveRecord::Type::Json.new}
  AppQuery(%{select '{"a": 1}' as data}).select_value(cast:)
  ```
- **...helpers to rewrite a query for introspection during development and testing**  
  See what a CTE yields: `query.select_all(select: "SELECT * FROM some_cte")`.  
  Query the end result: `query.select_one(select: "SELECT COUNT(*) FROM _ WHERE ...")`.  
  Append/prepend CTEs:
  ```ruby
  query.prepend_cte(<<~CTE)
    articles(id, title) AS (
      VALUES(1, 'Some title'),
            (2, 'Another article'))
  CTE
  ```
- **...rspec generators and helpers**  
  ```ruby
  RSpec.describe "AppQuery reports/weekly", type: :query do
    describe "CTE some_cte" do
      # see what this CTE yields
      expect(described_query.select_all(select: "select * from some_cte")).to \
        include(a_hash_including("id" => 1))
  
      # shorter: the query and CTE are derived from the describe-descriptions so this suffices:
      expect(select_all).to include ...
  ```

> [!IMPORTANT]  
> **Status**: alpha. API might change. See the CHANGELOG for breaking changes when upgrading.
>

## Rationale

Sometimes ActiveRecord doesn't cut it, and you'd rather use raw SQL to get the right data out. That, however, introduces some new problems. First of all, you'll run into the not-so-intuitive use of [select_(all|one|value)](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html#method-i-select_all) — for example, how they differ with respect to type casting, and how their behavior can vary between ActiveRecord versions. Then there's the testability, introspection, and maintainability of the resulting SQL queries.  
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
[postgresql]> AppQuery(%{select date('now') as today}).select_all.to_a
=> [{"today" => "2025-05-10"}]
[postgresql]> AppQuery(%{select date('now') as today}).select_one
=> {"today" => "2025-05-10"}
[postgresql]> AppQuery(%{select date('now') as today}).select_value
=> "2025-05-10"

# binds
# positional binds
[postgresql]> AppQuery(%{select now() - ($1)::interval as date}).select_value(binds: ['2 days'])
# named binds
[postgresql]> AppQuery(%{select now() - (:interval)::interval as date}).select_value(binds: {interval: '2 days'})

# casting
[postgresql]> AppQuery(%{select date('now') as today}).select_all(cast: true).to_a
=> [{"today" => Sat, 10 May 2025}]

## SQLite doesn't have a notion of dates or timestamp's so casting won't do anything:
[sqlite]> AppQuery(%{select date('now') as today}).select_one(cast: true)
=> {"today" => "2025-05-12"}
## Providing per-column-casts fixes this:
casts = {"today" => ActiveRecord::Type::Date.new}
[sqlite]> AppQuery(%{select date('now') as today}).select_one(cast: casts)
=> {"today" => Mon, 12 May 2025}


# rewriting queries (using CTEs)
[postgresql]> articles = [
  [1, "Using my new static site generator", 2.months.ago.to_date],
  [2, "Let's learn SQL", 1.month.ago.to_date],
  [3, "Another article", 2.weeks.ago.to_date]
]
[postgresql]> q = AppQuery(<<~SQL, cast: {"published_on" => ActiveRecord::Type::Date.new}).render(articles:)
  WITH articles(id,title,published_on) AS (<%= values(articles) %>)
  select * from articles order by id DESC
SQL

## query the articles-CTE
[postgresql]> q.select_all(select: %{select * from articles where id < 2}).to_a

## query the end-result (available as the CTE named '_')
[postgresql]> q.select_one(select: %{select * from _ limit 1})

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
> The included [example Rails app](./examples/ror) contains all data and queries described below.

Create a query:  
```bash
rails g query recent_articles
```

Have some SQL (for SQLite, in this example):
```sql
-- app/queries/recent_articles.sql
WITH settings(default_min_published_on) as (
  values(datetime('now', '-6 months'))
),

recent_articles(article_id, article_title, article_published_on, article_url) AS (
  SELECT id, title, published_on, url
  FROM articles
  RIGHT JOIN settings
  WHERE published_on > COALESCE(?1, settings.default_min_published_on)
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
  WHERE json_each.value LIKE ?2 OR ?2 IS NULL
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

# we can provide a different cut off date via binds^1:
AppQuery[:recent_articles].select_all(binds: [1.month.ago]).entries

1) note that SQLite can deal with unbound parameters, i.e. when no binds are provided it assumes null for
  $1 and $2 (which our query can deal with).
  For Postgres you would always need to provide 2 values, e.g. `binds: [nil, nil]`.
```

We can also dig deeper by query-ing the result, i.e. the CTE `_`:

```ruby
AppQuery[:recent_articles].select_one(select: "select count(*) as cnt from _")
# => {"cnt" => 13}

# For these kind of aggregate queries, we're only interested in the value:
AppQuery[:recent_articles].select_value(select: "select count(*) from _")
# => 13
```

Use `AppQuery#with_select` to get a new AppQuery-instance with the rewritten SQL:
```ruby
puts AppQuery[:recent_articles].with_select("select * from _")
```


### Verify CTE results

You can select from a CTE similarly:
```ruby
AppQuery[:recent_articles].select_all(select: "SELECT * FROM tags_by_article")
# => [{"article_id"=>1, "tags"=>"[\"release:pre\",\"release:patch\",\"release:1x\"]"},
      ...]

# NOTE how the tags are json strings. Casting allows us to turn these into proper arrays^1:
types = {"tags" => ActiveRecord::Type::Json.new}
AppQuery[:recent_articles].select_all(select: "SELECT * FROM tags_by_article", cast: types)

1) PostgreSQL, unlike SQLite, has json and array types. Just casting suffices:
AppQuery("select json_build_object('a', 1, 'b', true)").select_one(cast: true)
# => {"json_build_object"=>{"a"=>1, "b"=>true}}
```

Using the methods `(prepend|append|replace)_cte`, we can rewrite the query beyond just the select:

```ruby
AppQuery[:recent_articles].replace_cte(<<~SQL).select_all.entries
settings(default_min_published_on) as (
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
AppQuery[:recent_articles].prepend_cte(<<-CTE).select_all(binds: [6.weeks.ago, nil, JSON[sample_articles]).entries
  articles AS (
    SELECT * from json_to_recordset($3) AS x(id int, title text, published_on timestamp)
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
      expect(described_query.select_all(select: "select * from :cte")).to \
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
  E.g. given a query with a where-clause `WHERE published_at > COALESCE($1::timestamp, NOW() - '3 month'::interval)`, when setting `defaults_binds: [nil]` then `select_all` works like `select_all(binds: [nil])`.

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

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/eval/appquery.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
