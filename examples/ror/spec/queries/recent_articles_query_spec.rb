# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AppQuery recent_articles", type: :query,
  # ensure a 'published after' date that will select all articles by default
  default_binds: [30.years.ago, nil] do
    fixtures :articles, :tags

  describe "CTE recent_articles",
    default_binds: [nil, nil] do

    let(:max_age) { 6.months }

    def described_query(...)
      # adjust the default described_query
      super.replace_cte(<<~SETTINGS)
settings(default_min_published_on) AS (
  values(datetime('now', '-#{max_age.inspect}'))
)
SETTINGS
    end

    it do
      expect(select_all).to \
        have_attributes(columns: \
          a_collection_including("article_id", "article_title", "article_published_on", "article_url"))
    end

    it "by default selects no articles older than the max age" do
      expect(select_value(select: "select min(article_published_on) from :cte",
                          cast: [ActiveRecord::Type::Date.new])).to_not be < max_age.ago
    end

    it "allows for passing a minimum published_on date" do
      expect(select_value(select: "select min(article_published_on) from :cte",
                          binds: [10.years.ago],
                          cast: [ActiveRecord::Type::Date.new])).to be < max_age.ago
    end
  end

  # TODO articles without tags are not included (e.g. article_id=13)
end
