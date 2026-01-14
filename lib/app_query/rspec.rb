module AppQuery
  # RSpec integration for testing query classes.
  #
  # Provides helpers for testing queries, including CTE isolation,
  # bind/var metadata, and SQL logging.
  #
  # @example Setup in spec/rails_helper.rb
  #   require "app_query/rspec"
  #
  # @example Basic query spec
  #   RSpec.describe ProductsQuery, type: :query do
  #     it "returns products" do
  #       expect(described_query.entries).to be_present
  #     end
  #   end
  #
  # @see AppQuery::RSpec::Helpers
  module RSpec
    autoload :Helpers, "app_query/rspec/helpers"
  end
end

::RSpec.configure do |config|
  config.include AppQuery::RSpec::Helpers, type: :query

  # Enable SQL logging with `log: true` metadata
  config.around(:each, type: :query) do |example|
    if example.metadata[:log]
      old_logger = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = Logger.new($stdout)
      example.run
      ActiveRecord::Base.logger = old_logger
    else
      example.run
    end
  end
end
