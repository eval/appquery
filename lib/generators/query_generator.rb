# frozen_string_literal: true

require_relative "app_query/query_generator"

class QueryGenerator < AppQuery::Generators::QueryGenerator
  # Hidden alias for app_query:query
  # Usage: rails g query products
  source_root AppQuery::Generators::QueryGenerator.source_root
  hide!
end
