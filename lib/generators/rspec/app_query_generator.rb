# frozen_string_literal: true

module Rspec
  module Generators
    class AppQueryGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_test_file
        template "app_query_spec.rb",
          File.join("spec/queries", class_path, "#{file_name}_query_spec.rb")
      end
    end
  end
end
