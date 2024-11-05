# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#

[
  ["Rails 1.0: Party like it's one oh oh!!", "2005-12-13", "David",
     %w[release:major release:1x], "https://web.archive.org/web/20060101040631/http://weblog.rubyonrails.org/articles/2005/12/13/rails-1-0-party-like-its-one-oh-oh"],
  ["Rails 2.0: It's done!", "2007-12-7", "David",
     %w[release:major release:2x], "https://rubyonrails.org/2007/12/7/rails-2-0-it-s-done"],
  ["Rails 3.0: It's ready!", "2010-8-29", "David",
     %w[release:major release:3x], "https://rubyonrails.org/2010/8/29/rails-3-0-it-s-done"],
  ["Rails 4.0: Final version released!", "2013-6-25", "David",
     %w[release:major release:4x], "https://rubyonrails.org/2013/6/25/Rails-4-0-final"],
  ["Rails 5.0: Action Cable, API mode, and so much more", "2016-6-30", "David",
     %w[release:major release:5x], "https://rubyonrails.org/2016/6/30/Rails-5-0-final"],
  ["Rails 6 excitement, connection pool reaping, bug fixes", "2019-8-25", "Daniel",
    %w[release:major release:6x], "https://rubyonrails.org/2019/8/25/this-week-in-rails-rails-6-excitement-connection-pool-reaping-bug-fixes"],
  ["Rails 7.0: Fulfilling a vision", "2021-12-15", "David",
    %w[release:major release:7x], "https://rubyonrails.org/2021/12/15/Rails-7-fulfilling-a-vision"],
  ["Rails 1.1: RJS, Active Record++, respond_to, integration tests, and 500 other things!", "2006-3-28", "David",
     %w[release:minor release:1x], "https://web.archive.org/web/20060424173241/http://weblog.rubyonrails.org/articles/2006/03/28/rails-1-1-rjs-active-record-respond_to-integration-tests-and-500-other-things"],
  ["Rails 1.1.2: Tiny fix for gems dependencies", "2006-4-9", "David",
     %w[release:patch release:1x], "https://web.archive.org/web/20060428161945/http://weblog.rubyonrails.org/articles/2006/04/09/rails-1-1-2-tiny-fix-for-gems-dependencies"]
].each_with_index do |(title, published_on, author, tags, url), ix|
  tags = tags.map { Tag.find_or_create_by!(name: _1) }
  author = Author.find_or_create_by!(name: author)

  Article.find_or_create_by(id: ix.next).update(title:, url:, published_on:, author: author, tags: tags)
end
