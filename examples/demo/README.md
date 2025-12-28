# Demo

This is a Rails app that deals with all (release) articles from the [Ruby on Rails blog](https://rubyonrails.org/blog/).  
It demonstrates how to use AppQuery to iterate on developing a query and explore the results.

<img width="575" height="455" alt="Screenshot 2025-12-20 at 19 18 38" src="https://github.com/user-attachments/assets/b987bfe3-0c87-4d76-ab50-888600bc7ec4" />


## Usage

```
  ruby demo.rb --seed     # seed SQLite database (~300 news articles from rubyonrails.org)
  ruby demo.rb --console  # play around with queries from the console
  ruby demo.rb            # start server at localhost:3000 (or provide PORT env-var)

  Visit http://localhost:3000 to see the list of recent Rails releases.
```

## Points of interest:
- [demo.rb](./demo.rb)  
  A single script that contains a Rails application - to get a quick overview of config, schema, classes&controllers.
- [recent_articles.sql](./queries/recent_articles.sql)
  


## Exercises

- <details>
  <summary>how many results are there since '2020-1-1'</summary>
  
  ```ruby
  since = Date.parse("2020-1-1")
  recent_articles.with_binds(since:).count
  ```
  </details>
- <details>
  <summary>show the settings being used</summary>
  
  ```ruby
  since = Date.parse("2020-1-1")
  recent_articles.with_binds(since:).select_value("select * from settings")
  ```
  </details>
- <details>
  <summary>how many unique tags exist?</summary>
  
  ```ruby
  recent_articles.select_value("select count(*) from tags")
  # or 
  recent_articles.count
  ```
  </details>
- <details>
  <summary>list all titles</summary>
  
  ```ruby
  recent_articles.select_all("select title from :_").entries
  # or
  recent_articles.select_all.column("title")
  ```
  </details>
- how many articles don't have a tag?
- what is the articles with the most tags?
- what tag got used the least?
- what tag is used the most?
- per tag: what was the first article it was used for?
- search for titles containing some word
- tags is a JSON-string. Use a cast to get an array.


