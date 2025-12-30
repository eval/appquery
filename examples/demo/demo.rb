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

class BaseQuery
  class_attribute :_binds, default: {}
  class_attribute :_vars, default: {}
  class_attribute :_casts, default: {}

  class << self
    def bind(name, default: nil)
      self._binds = _binds.merge(name => { default: })
      attr_reader name
    end

    def var(name, default: nil)
      self._vars = _vars.merge(name => { default: })
      attr_reader name
    end

    def cast(casts = nil)
      return _casts if casts.nil?
      self._casts = casts
    end

    def binds = _binds
    def vars = _vars
  end

  def initialize(**params)
    all_known = self.class.binds.keys + self.class.vars.keys
    unknown = params.keys - all_known
    raise ArgumentError, "Unknown param(s): #{unknown.join(", ")}" if unknown.any?

    self.class.binds.merge(self.class.vars).each do |name, options|
      value = params.fetch(name) {
        default = options[:default]
        default.is_a?(Proc) ? instance_exec(&default) : default
      }
      instance_variable_set(:"@#{name}", value)
    end
  end

  delegate :select_all, :entries, :select_one, :count, :to_s, :column, :first, :ids, to: :query

  def query
    @query ||= base_query
      .render(**render_vars)
      .with_binds(**bind_vars)
  end

  def base_query
    AppQuery[query_name, cast: self.class.cast]
  end

  private

  def query_name
    self.class.name.underscore.sub(/_query$/, "")
  end

  def render_vars
    self.class.vars.keys.to_h { [_1, send(_1)] }
  end

  def bind_vars
    self.class.binds.keys.to_h { [_1, send(_1)] }
  end
end

module Paginate
  extend ActiveSupport::Concern

  class PaginatedResult
    include Enumerable
    delegate :each, :size, :[], :empty?, :first, :last, to: :@records

    def initialize(records, page:, per_page:, total_count: nil, has_next: nil)
      @records = records
      @page = page
      @per_page = per_page
      @total_count = total_count
      @has_next = has_next
    end

    def current_page = @page
    def limit_value = @per_page
    def prev_page = @page > 1 ? @page - 1 : nil
    def first_page? = @page == 1

    def total_count
      @total_count || raise("total_count not available in without_count mode")
    end

    def total_pages
      return nil unless @total_count
      (@total_count.to_f / @per_page).ceil
    end

    def next_page
      if @total_count
        @page < total_pages ? @page + 1 : nil
      else
        @has_next ? @page + 1 : nil
      end
    end

    def last_page?
      if @total_count
        @page >= total_pages
      else
        !@has_next
      end
    end

    def out_of_range?
      empty? && @page > 1
    end
  end

  included do
    var :page, default: nil
    var :per_page, default: -> { self.class.per_page }
  end

  class_methods do
    def per_page(value = nil)
      if value.nil?
        return @per_page if defined?(@per_page)
        superclass.respond_to?(:per_page) ? superclass.per_page : 25
      else
        @per_page = value
      end
    end
  end

  def paginate(page: 1, per_page: self.class.per_page, without_count: false)
    @page = page
    @per_page = per_page
    @without_count = without_count
    self
  end

  def entries
    @_entries ||= build_paginated_result(super)
  end

  def total_count
    @_total_count ||= unpaginated_query.count
  end

  def unpaginated_query
    base_query
      .render(**render_vars.except(:page, :per_page))
      .with_binds(**bind_vars)
  end

  private

  def build_paginated_result(entries)
    return entries unless @page  # No pagination requested

    if @without_count
      has_next = entries.size > @per_page
      records = has_next ? entries.first(@per_page) : entries
      PaginatedResult.new(records, page: @page, per_page: @per_page, has_next: has_next)
    else
      PaginatedResult.new(entries, page: @page, per_page: @per_page, total_count: total_count)
    end
  end

  def render_vars
    vars = super
    # Fetch one extra row in without_count mode to detect if there's more
    if @without_count && vars[:per_page]
      vars = vars.merge(per_page: vars[:per_page] + 1)
    end
    vars
  end
end

class ApplicationQuery < BaseQuery
  include Paginate

  per_page 50
end

class RecentArticlesQuery < ApplicationQuery
  bind :since, default: 0
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
    @tag = params[:tag]
    @page = params.fetch(:page, 1).to_i
    @query = RecentArticlesQuery.build(tag: @tag, page: @page, without_count: true)
    @articles = @query.entries

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
            <a class="title" href="<%= a["url"] %>" target="_open"><%= a["title"] %></a>
            <span class="date"><%= a["published_on"] %></span>
            <div class="tags">
              <% a["tags"]&.each do |tag| %>
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
