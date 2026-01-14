# frozen_string_literal: true

module AppQuery
  module RSpec
    # RSpec helpers for testing query classes.
    #
    # @example Basic usage
    #   RSpec.describe ProductsQuery, type: :query do
    #     it "returns products" do
    #       expect(described_query.entries).to be_present
    #     end
    #   end
    #
    # @example Testing a specific CTE
    #   RSpec.describe ProductsQuery, type: :query do
    #     describe "cte active_products" do
    #       it "only contains active products" do
    #         expect(described_query.entries).to all(include("active" => true))
    #       end
    #     end
    #   end
    #
    # @example With required binds
    #   RSpec.describe UsersQuery, type: :query, binds: {company_id: 1} do
    #     it "returns users for company" do
    #       expect(described_query.entries).to be_present
    #     end
    #   end
    #
    # @example With vars
    #   RSpec.describe ProductsQuery, type: :query do
    #     describe "as admin", vars: {admin: true} do
    #       it "returns all products" do
    #         expect(described_query.entries.size).to eq(3)
    #       end
    #     end
    #   end
    module Helpers
      # Returns the query instance, optionally focused on a CTE.
      #
      # When inside a `describe "cte xxx"` block, returns a query
      # that selects from that CTE instead of the full query.
      #
      # @param kwargs [Hash] arguments passed to {#build_query}
      # @return [AppQuery::BaseQuery, AppQuery::Q] the query instance
      #
      # @example Override binds per-test
      #   expect(described_query(user_id: 123).entries).to include(...)
      def described_query(**kwargs)
        query = build_query(**kwargs)
        cte_name ? query.query.cte(cte_name) : query
      end

      # Builds the query instance. Override this to customize instantiation.
      #
      # @param kwargs [Hash] merged with {#query_binds} and {#query_vars}
      # @return [AppQuery::BaseQuery] the query instance
      #
      # @example Custom build method
      #   def build_query(**kwargs)
      #     described_class.build(**query_binds.merge(query_vars).merge(kwargs))
      #   end
      def build_query(**kwargs)
        described_class.new(**query_binds.merge(query_vars).merge(kwargs))
      end

      # Returns binds from RSpec metadata.
      #
      # @return [Hash] the binds hash
      def query_binds
        metadata_value(:binds) || {}
      end

      # Returns vars from RSpec metadata.
      #
      # @return [Hash] the vars hash
      def query_vars
        metadata_value(:vars) || {}
      end

      # Returns the CTE name if inside a "cte xxx" describe block.
      #
      # @return [String, nil] the CTE name
      def cte_name
        self.class.cte_name
      end

      def self.included(klass)
        klass.extend(ClassMethods)
      end

      private

      def metadata_value(key)
        self.class.metadata_value(key)
      end

      module ClassMethods
        def cte_name
          descriptions.find { _1[/\Acte\s/i] }&.split&.last
        end

        def metadata_value(key)
          metadatas.find { _1[key] }&.[](key)
        end

        def metadatas
          metahash = metadata
          result = []
          loop do
            result << metahash
            metahash = metahash[:parent_example_group]
            break unless metahash
          end
          result
        end

        def descriptions
          metadatas.map { _1[:description] }
        end
      end
    end
  end
end
