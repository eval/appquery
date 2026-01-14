module AppQuery
  class Railtie < ::Rails::Railtie # :nodoc:
    generators do
      require_relative "../generators/app_query/query_generator"
      require_relative "../generators/app_query/example_generator"
      require_relative "../generators/query_generator"
      require_relative "../generators/rspec/app_query_generator"
      require_relative "../generators/rspec/app_query_example_generator"
      require_relative "../generators/rspec/query_generator"
    end
  end
end
