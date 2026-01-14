# frozen_string_literal: true

require_relative "app_query_generator"

module Rspec
  module Generators
    class QueryGenerator < AppQueryGenerator
      # Hidden hook for query generator alias
      source_root AppQueryGenerator.source_root
      hide!
    end
  end
end
