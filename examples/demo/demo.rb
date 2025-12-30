# Usage:
#   ruby demo.rb --seed      # seed database
#   ruby demo.rb --console   # start IRB console
#   ruby demo.rb             # start server
#   rerun ruby demo.rb       # start with auto-reload on file changes

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "rails"
  gem "sqlite3"
  gem "puma"
  gem "rackup"
  gem "nokogiri"  # for seeds
  gem "kaminari"
  gem "appquery", path: File.expand_path("../..", __dir__)
end

require "action_controller/railtie"
require "active_record"
require "cgi"

ROOT = __dir__
STYLE = File.read(__FILE__).gsub(/.*__END__/m, "")

# Minimal Rails app
class DemoApp < Rails::Application
  config.root = ROOT
  config.eager_load = false
  config.secret_key_base = "demo"
  config.logger = Logger.new($stdout)
  config.log_level = :info
end

# Database setup
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: File.join(ROOT, "db/demo.sqlite3")
)
ActiveRecord::Base.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :articles, force: false, if_not_exists: true do |t|
    t.string :title
    t.string :url
    t.date :published_on
    t.timestamps
  end

  create_table :tags, force: false, if_not_exists: true do |t|
    t.string :name
    t.timestamps
  end

  create_table :articles_tags, id: false, force: false, if_not_exists: true do |t|
    t.integer :article_id
    t.integer :tag_id
    t.index :article_id
    t.index :tag_id
  end
end

# Models
class Article < ActiveRecord::Base
  has_and_belongs_to_many :tags
end

class Tag < ActiveRecord::Base
  has_and_belongs_to_many :articles
end

class ApplicationQuery < AppQuery::BaseQuery
  include AppQuery::Paginatable

  per_page 50
end

class RecentArticlesQuery < ApplicationQuery
  include AppQuery::Mappable

  class Item < Data.define(
    :published_on,
    :tags,
    :title,
    :url,
  )
    def initialize(tags: [], **)
      super
    end
  end

  bind :since, default: 0 # since forever
  bind :tag

  cast tags: :json
  per_page 10

  def self.build(tag: nil, page: 1, without_count: false)
    new(tag:).paginate(page:, without_count:)
  end
end

# Handle --seed flag
if ARGV.delete("--seed")
  load File.join(ROOT, "db/seeds.rb")
  puts "Seeded #{Article.count} articles, #{Tag.count} tags"
  exit
end

# AppQuery setup
AppQuery.configure { |c| c.query_path = File.join(ROOT, "queries") }

# Handle --console flag
if ARGV.delete("--console")
  def recent_articles(...)
    RecentArticlesQuery.build(...)
  end
  require "irb"
  puts "Available helper methods: [recent_articles]"
  IRB.start
  exit
end

# Controllers
class StyleController < ActionController::Base
  def show
    render plain: STYLE, content_type: "text/css"
  end
end

class ArticlesController < ActionController::Base
  include Rails.application.routes.url_helpers

  def index
    @articles = RecentArticlesQuery.build(
      page: params.fetch(:page, 1).to_i,
      tag: params[:tag],
      without_count: false
    ).entries

    render inline: <<~ERB
      <!DOCTYPE html>
      <html>
      <head>
        <title>AppQuery Demo</title>
        <link rel="stylesheet" href="/style.css">
      </head>
      <body>
        <h1><a href="/">Recent Articles</a></h1>
        <% if @tag %>
          <p class="filter">Filtering by tag: <strong><%= @tag %></strong> &mdash; <a href="/">clear filter</a></p>
        <% end %>
        <% if @articles.total_pages %>
          <%= paginate @articles %>
        <% else %>
          <nav class="pagination">
            <%= link_to_prev_page @articles, "← Previous" %>
            <%= link_to_next_page @articles, "Next →" %>
          </nav>
        <% end %>
        <ul>
        <% @articles.each do |a| %>
          <li>
            <a class="title" href="<%= a.url %>" target="_open">
              <%= a.title %>
            </a>
            <span class="date"><%= a.published_on %></span>
            <div class="tags">
              <% a.tags.each do |tag| %>
                <a class="tag" href="?tag=<%= CGI.escape(tag) %>"><%= tag %></a>
              <% end %>
            </div>
          </li>
        <% end %>
        </ul>
        <% if @articles.total_pages %>
          <%= paginate @articles %>
        <% else %>
          <nav class="pagination">
            <%= link_to_prev_page @articles, "← Previous" %>
            <%= link_to_next_page @articles, "Next →" %>
          </nav>
        <% end %>
      </body>
      </html>
    ERB
  end
end

# Start server
DemoApp.initialize!

# Routes must be drawn after initialization
Rails.application.routes.draw do
  root "articles#index"
  get "style.css", to: "style#show"
end

require "rackup"
Rackup::Server.start(app: DemoApp, Port: ENV.fetch("PORT", 3000).to_i)

__END__
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  max-width: 800px;
  margin: 0 auto;
  padding: 2rem;
  line-height: 1.6;
  color: #333;
}
h1 { color: #c00; margin-bottom: 0.5rem; }
h1 a, h1 a:visited { color: inherit; text-decoration: none; }
.filter {
  background: #f5f5f5;
  padding: 0.75rem 1rem;
  border-radius: 4px;
  margin-bottom: 1.5rem;
}
.filter a { color: #c00; }
ul { list-style: none; padding: 0; }
li {
  padding: 0.75rem 0;
  border-bottom: 1px solid #eee;
}
li a.title {
  color: #0066cc;
  text-decoration: none;
  font-weight: 500;
}
li a.title:hover { text-decoration: underline; }
.date {
  color: #666;
  font-size: 0.875rem;
  margin-left: 0.5rem;
}
.tags { margin-top: 0.25rem; }
.tag {
  display: inline-block;
  background: #e0e0e0;
  color: #333;
  padding: 0.125rem 0.5rem;
  border-radius: 3px;
  font-size: 0.75rem;
  text-decoration: none;
  margin-right: 0.25rem;
}
.tag:hover { background: #c00; color: white; }
.pagination {
  display: flex;
  gap: 1rem;
  align-items: center;
  margin-top: 1.5rem;
  padding-top: 1rem;
  border-top: 1px solid #eee;
}
.pagination a { color: #0066cc; text-decoration: none; }
.pagination a:hover { text-decoration: underline; }
