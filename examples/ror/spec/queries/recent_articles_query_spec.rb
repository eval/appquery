# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AppQuery recent_articles",
  type: :query,
  default_binds: [30.years.ago, nil] do
  describe "CTE recent_articles", default_binds: [nil] do
    let(:max_age) { -3.years }

    def described_query(...)
      # adjust the default described_query
      super.replace_cte(<<~SETTINGS)
settings(default_published_after) AS (
  values(datetime('now', '#{max_age.inspect}'))
)
SETTINGS
    end

    it do
      expect(select_all).to \
        have_attributes(columns: \
          a_collection_including("article_id", "article_title", "article_published_on", "article_url"))
    end

    it "by default selects no articles older than the 'recent period'" do
      expect(select_value(select: "select min(article_published_on) from :cte",
                          cast: [ActiveRecord::Type::Date.new])).to_not be < max_age.from_now
    end

    it "allows for passing a minimum published_on date" do
      expect(select_value(select: "select min(article_published_on) from :cte",
                          binds: [10.years.ago],
                          cast: [ActiveRecord::Type::Date.new])).to be < max_age.from_now
    end
  end
end
