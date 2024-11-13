module Rspec
  module Generators
    class QueryGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_test_file
        template "query_spec.rb",
          File.join("spec/queries", class_path, "#{file_name}_query_spec.rb")
      end

      hide!

      private

      def query_path
        AppQuery.configuration.query_path
      end
    end
  end
end
