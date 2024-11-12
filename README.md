# AppQuery - raw SQL 🥦, cooked :stew:

[![Gem Version](https://badge.fury.io/rb/appquery.svg)](https://badge.fury.io/rb/appquery)

A Rubygem :gem: that makes working with raw SQL queries in Rails projects more convenient.  
Specifically it provides:
- **...a dedicated folder for queries**  
  e.g. `app/queries/reports/weekly.sql` is instantiated via `AppQuery["reports/weekly"]`.
- **...Rails/rspec generators**  
  ```
  $ rails generate query reports/weekly
    create  app/queries/reports/weekly.sql
    invoke  rspec
    create    spec/queries/reports/weekly_query_spec.rb
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
- **...rspec-helpers**  
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

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add appquery
```

## Usage

> [!NOTE]
> The following (trivial) examples are not meant to convince you to ditch your ORM, but just to show how this gem handles raw SQL queries.

### Create

Create a query:  
```bash
rails g query recent_articles
```

Have some SQL (for PostgreSQL):
```sql
-- app/queries/recent_articles.sql
WITH recent_articles(article_id, article_title) AS (
  SELECT id, title
  FROM articles
  WHERE published_at > COALESCE($1::timestamp, NOW() - '3 month'::interval)
),
authors_by_article(article_id, authors) AS (
  SELECT articles_authors.article_id, array_agg(authors.name)
  FROM articles_authors
  JOIN authors ON articles_authors.author_id=authors.id
  GROUP BY articles_authors.article_id
)
SELECT recent_articles.*,
  -- sort authors alphabetically
  array_to_string(array(select unnest(authors_by_article.authors) order by 1), ', ') AS authors
FROM recent_articles
JOIN authors_by_article USING(article_id)
```

Even for this trivial query, there's already quite some things 'encoded' that we might want to verify or capture in tests:
- only certain columns
- only published articles
- only articles _with_ authors
- only articles published after some date
  - either a provided date or a fallback date
- authors appear in a certain order and are formatted a certain way

Using the SQL-rewriting capabilities shown below, this library allows you to express these assertions in tests or verify them during development.

### Verify query results

> [!NOTE]
> There's `AppQuery#select_all`, `AppQuery#select_one` and `AppQuery#select_value` to execute a query. `select_(all|one)` are tiny wrappers around the equivalent methods from `ActiveRecord::Base.connection`.  
> Instead of [positional arguments](https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html#method-i-select_all), these methods accept keywords `select`, `binds` and `cast`. See below for examples.

Given the query above, you can get the result like so:
```ruby
AppQuery[:recent_articles].select_all(binds: [nil]).entries
# => [{"article_id" => 1, "article_title" => "Some title", "authors" => "{Foo, Baz}"}, ...]
AppQuery[:recent_articles].select_all(binds: [1.month.ago]).entries
```

Or query the result using the added CTE named `_`:

```ruby
AppQuery[:recent_articles].select_one(select: "select count(*) as cnt from _", binds: [nil])
# => {"cnt" => 1}
# select_value is ideal when only interested in the value of the one result
AppQuery[:recent_articles].select_value(select: "select count(*) from _", binds: [nil])
# => 1
```

Use `AppQuery#with_select` to get a new AppQuery-instance with the rewritten SQL:
```ruby
puts AppQuery[:recent_articles].with_select("select * from _")
```


### Verify CTE results

You can select from a CTE similarly`:
```ruby
AppQuery[:recent_articles].select_all(select: "SELECT * FROM authors_by_article", binds: [nil], cast: true)
# => [{"article_id" => 1, "authors" => ["Foo", "Baz"]}, ...]
# NOTE: the cast keyword ensures a proper authors-array
```

By adding CTEs we can even mock some values:
```ruby
AppQuery[:recent_articles]
  .prepend_cte("articles AS(VALUES(1, 'Some title', NOW() - '4 month'::interval))")
  .select_all(binds: [nil])

# using Ruby data:
sample_articles = [{id: 1, title: "Some title", published_at: 3.months.ago},
                   {id: 2, title: "Another title", published_at: 1.months.ago}]
# show the provided cutoff date works
AppQuery[:recent_articles].prepend_cte(<<-CTE).select_all(binds: [6.weeks.ago, JSON[sample_articles]).entries
  articles AS (
    SELECT * from json_to_recordset($2) AS x(id int, title text, published_at timestamp)
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

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/eval/appquery.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

