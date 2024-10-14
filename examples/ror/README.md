# README

This Rails v8 application shows in detail how AppQuery helps to inspect and test queries.

## Points of interest

The data consists of articles of all Rails releases from the [rubyonrails blog](https://rubyonrails.org/category/releases).  
Articles (in this application) have zero or more tags like `release:major`, `release:minor`, `release:8x`.

- query-file  
  [app/queries/recent_articles.sql](app/queries/recent_articles.sql)
- spec-file  
  [spec/queries/recent_articles_query_spec.rb](spec/queries/recent_articles_query_spec.rb)
- data  
  - [spec/fixtures/articles.yml](spec/fixtures/articles.yml)
  - [spec/fixtures/tags.yml](spec/fixtures/tags.yml)


## Setup

Running `setup` will create and seed the SQLite database:

```
$ ./bin/setup
# to erase any existing data
$ ./bin/setup --db-drop
```

## Walkthrough

An example console session:

```ruby
$ rails console
# Query instance
> AppQuery[:recent_articles]
# ...as string
> puts AppQuery[:recent_articles]

# See results
> AppQuery[:recent_articles].select_all.entries

# Notice the articles are sorted by publish date, oldest first.
# Let's reverse the order:
> AppQuery[:recent_articles].select_all(select: "select * from _ order by article_published_on desc").entries

# Let's select the oldest article (note the select_one):
> AppQuery[:recent_articles].select_one

# This is determined by one of the default settings.
# Let's see what settings are available by selecting from the settings CTE:
> AppQuery[:recent_articles].select_one(select: "select * from settings")

# What other CTEs do we have:
> AppQuery[:recent_articles].cte_names

# Let's select from the recent_articles CTE and pass a different cut-off date:
> AppQuery[:recent_articles].select_all(select: "select * from recent_articles", binds: ["2001"])
# or
> AppQuery[:recent_articles].select_all(select: "select * from recent_articles", binds: [30.years.ago])

# How many articles are there? (note the use of select_value):
> AppQuery[:recent_articles].select_value(select: "select count(*) from recent_articles", binds: [30.years.ago])

# Let's see what the oldest published date is now:
> AppQuery[:recent_articles].select_value(select: "select article_published_on from recent_articles", binds: [30.years.ago])

# SQLite doesn't have a separate date/time datatype, but luckily we can instruct AppQuery to cast it:
coltypes = {"article_published_on" => ActiveRecord::Type::Date.new}
AppQuery[:recent_articles].select_value(select: "select article_published_on from recent_articles", binds: [30.years.ago], cast: coltypes)
```
