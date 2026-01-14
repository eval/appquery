# frozen_string_literal: true

module AppQuery
  module Generators
    class ExampleGenerator < Rails::Generators::Base
      desc <<~DESC
        Generates annotated example query demonstrating binds, vars, CTEs, and testing patterns.

        See also:
          rails generate query --help
      DESC
      source_root File.expand_path("templates", __dir__)

      def create_application_query
        return if File.exist?(application_query_path)

        template "application_query.rb", application_query_path
      end

      def create_example_files
        template "example_query.rb", File.join(query_path, "example_query.rb")
        template "example.sql.erb", File.join(query_path, "example.sql.erb")
      end

      hook_for :test_framework, as: :app_query_example

      private

      def query_path
        ::AppQuery.configuration.query_path
      end

      def application_query_path
        File.join(query_path, "application_query.rb")
      end
    end
  end
end
