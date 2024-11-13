module Rails
  module Generators
    class QueryGenerator < NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_query_file
        template "query.sql",
          File.join(AppQuery.configuration.query_path, class_path, "#{file_name}.sql")

        # in_root do
        #  if behavior == :invoke && !File.exist?(application_mailbox_file_name)
        #    template "application_mailbox.rb", application_mailbox_file_name
        #  end
        # end
      end

      hook_for :test_framework
    end
  end
end
