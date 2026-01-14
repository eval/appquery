require_relative "rspec/helpers"

RSpec.configure do |config|
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
