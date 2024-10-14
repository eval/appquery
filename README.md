# App Query - raw SQL queries made convenient

> [!IMPORTANT]  
> This repository is currently `README`-ware, i.e. the code I wish I had. Though, having made various POCs at this point, the design sketched in this README is viable.
>  
> *Feedback and ideas welcome!*

This rubygem makes working with raw SQL queries in Ruby/Rails projects more convenient, by:
- ...having a dedicated folder to put them  
  `AppQuery[:some_query]` is read from `app/queries/some_query.sql`
- ...providing inspection and testability of query results  
  Test the end-result:
  ```ruby
  query.as_cte(select: "select * from app_query where ...").select_all
  ```
  Test individual CTEs:
  ```ruby
  query.replace_select("select * from some_cte").select_all
  ```
- ...having generators
  In Rails:
  ```bash
  $ rails generate query reports/weekly
  
  ..app/queries/reports/weekly_report.sql
  ...spec/queries/reports/weekly_report_spec.rb
  ```
- ...having spec-helpers  
  ```ruby
    expect(described_query.as_cte("select * from app_query").select_all.entries).to ...

    # maybe some sugar 🧁
    expect(select_entries(as_cte: "select * from app_query where ...")).to include "article_title" => "Some article"

    expect(select_entries(select: "select * from some_cte where ...", binds: [...])).to be_empty
  ```

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add appquery
```

## Usage

> [!NOTE]
> The queries below are so trivial that getting this data would be easier in ActiveRecord.
> The examples are meant to show what this library can do once you _are_ using raw SQL.

Create a query:  
```bash
rails g query recent_articles
```

Have some SQL:
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

Even for this trivial query, there's already quite some things 'encoded' that we might want to verify:
- we get certain columns
- we only want published articles
- we only want articles with authors
- we only want articles published after some date
  - we can provide this date or use the fallback
- authors appear in a certain order and are formatted a certain way

Using the SQL-rewriting capabilities shown below, this library allows you to express these assertions in tests or verify them during development.

You can now easily get a hold of the query (from the console) and inspect the end-result:
```ruby
AppQuery[:recent_articles].select_all([nil]).entries # => [{"article_id" => 1, "article_title" => "Some title", "authors" => "Foo, Baz"}, ...]
AppQuery[:recent_articles].select_all([1.month.ago]).entries
```

But you can also get a hold of a CTE:
```ruby
AppQuery[:recent_articles].replace_select("SELECT * FROM authors_by_article").select_all([nil]).cast_entries
# => [{"article_id" => 1, "authors" => ["Foo", "Baz"]}, ...]
```

We can even mock some values:
```ruby
AppQuery[:recent_articles].prepend_cte("articles", body: "VALUES(1, 'Some title', NOW() - '4 month'::interval)").select_all([nil])

# uing Ruby data:
sample_articles = [{id: 1, title: "Some title", published_at: 3.months.ago},
                   {id: 2, title: "Another title", published_at: 1.months.ago}]
# show the provided cutoff date works
AppQuery[:recent_articles].prepend_cte("articles", body: <<-CTE).select_all([6.weeks.ago, JSON[sample_articles]).entries
  SELECT * from json_to_recordset($2) AS x(id int, title text, published_at timestamp)
CTE
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/eval/appquery.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
