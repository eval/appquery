require "open-uri"

def title(post)
  post.css("a").text
end

def url(post, path_only: false)
  path = post.at_css("a").attr("href")
  path_only ? path : ("https://rubyonrails.org%s" % path)
end

def publish_date(post)
  url(post, path_only: true).split("/").compact_blank.take(3).join("-")
end

def tags(title)
  re_pre = /\d+(\.\d+){2}\.\D|(?<!\.)0(\.\d+){2}/ # "1.2.3.rc1" "0.12.3"
  re_rev = /\d+(\.\d+){3}/
  re_pre_generic = / (alpha|beta|candidate|preview|rc)/i
  re_patch = /\d+(\.\d+){2}/
  re_minor = /\d+\.[1-9][0-9]?/
  re_major = /\d+\.0/

  [[re_pre, "release:pre"],
   [re_pre_generic, "release:pre", "release:pre-generic"],
   [re_rev, "release:revision"],
   [re_patch, "release:patch"],
   [re_minor, "release:minor"],
   [re_major, "release:major"]].each_with_object({title: title, tags: []}) do |(re, *tags), acc|
     matches = []

     acc[:title].scan(re){ matches << $& }
     next unless matches.any?

     version_tags = matches.map { "release:%sx" % $& if _1[/^[1-9]/] }.compact.uniq

     acc[:title] = matches.reduce(acc[:title]) {|title, m| title.sub(m, "") }
     acc[:tags] += tags if matches.any? && !acc[:tags].include?("release:pre-generic")
     acc[:tags] += version_tags
   end[:tags].uniq.reject { _1["release:pre-generic"] }
end

Nokogiri::HTML(URI.open("https://rubyonrails.org/category/releases")).then do |doc|
  doc.css("body > div > div.blog.common-padding--bottom > div > div > li.blog__post").then do |posts|
    posts.reverse.each_with_index do |post, ix|
      title = title(post)
      next unless title[/rails/i] # && !title[/recipes|phusion/i]

      _, tags, url, published_on = p [title, tags(title), url(post), publish_date(post)]
      # next unless tags.any?
      next if published_on.in?(%w[2006-4-19 2006-5-15]) # not Rails releases
      tags << "releases"
      tags = tags.map { Tag.find_or_create_by!(name: _1) }

      Article.find_or_create_by!(id: ix.next).update(title:, url:, published_on:, tags: tags)
    end
  end
end

Nokogiri::HTML(URI.open("https://rubyonrails.org/category/news")).then do |doc|
  doc.css("body > div > div.blog.common-padding--bottom > div > div > li.blog__post").then do |posts|
    posts.reverse.each_with_index do |post, ix|
      title = title(post)

      _, url, published_on = p [title, url(post), publish_date(post)]
      # next unless tags.any?
      tags = %w[news].map { Tag.find_or_create_by!(name: _1) }

      Article.find_or_create_by!(id: 1000 + ix.next).update(title:, url:, published_on:, tags: tags)
    end
  end
end
