# Demo

This is a Rails app that deals with all (release) articles from the [Ruby on Rails blog](https://rubyonrails.org/blog/).  

<img width="575" height="455" alt="Screenshot 2025-12-20 at 19 18 38" src="https://github.com/user-attachments/assets/b987bfe3-0c87-4d76-ab50-888600bc7ec4" />

## Points of interest:
- [demo.rb](./demo.rb)  
  A single script that contains a Rails application - to get a quick overview of config, schema, classes&controllers.
- [recent_articles.sql](./queries/recent_articles.sql)


## Usage

```
  ruby demo.rb --seed     # seed database (~300 news articles from rubyonrails.org)
  ruby demo.rb --console  # play around with queries from the console
  ruby demo.rb            # start server at localhost:3000 (or provide PORT env-var)

  Visit http://localhost:3000 to see the list of recent Rails releases.
```
