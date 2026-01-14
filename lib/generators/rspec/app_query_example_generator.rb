# frozen_string_literal: true

module Rspec
  module Generators
    class AppQueryExampleGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_test_file
        template "app_query_example_spec.rb", "spec/queries/example_query_spec.rb"
      end
    end
  end
end
