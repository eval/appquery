require_relative "rspec/helpers"

RSpec.configure do |config|
  config.include AppQuery::RSpec::Helpers, type: :query
end
