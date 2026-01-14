# frozen_string_literal: true

module AppQuery
  module Generators
    class QueryGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_application_query
        return if File.exist?(application_query_path)

        template "application_query.rb", application_query_path
      end

      def create_query_class
        template "query.rb",
          File.join(query_path, class_path, "#{file_name}_query.rb")
      end

      def create_query_file
        template "query.sql",
          File.join(query_path, class_path, "#{file_name}.sql")
      end

      hook_for :test_framework

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
