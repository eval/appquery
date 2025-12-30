# frozen_string_literal: true

require "active_support/core_ext/class/attribute" # class_attribute
require "active_support/core_ext/module/delegation" # delegate

module AppQuery
  # Base class for query objects that wrap SQL files.
  #
  # BaseQuery provides a structured way to work with SQL queries compared to
  # using `AppQuery[:my_query]` directly.
  #
  # ## Benefits over AppQuery[:my_query]
  #
  # ### 1. Explicit parameter declaration
  # Declare required binds and vars upfront with defaults:
  #
  #   class ArticlesQuery < AppQuery::BaseQuery
  #     bind :author_id              # required
  #     bind :status, default: nil   # optional
  #     var :order_by, default: "created_at DESC"
  #   end
  #
  # ### 2. Unknown parameter validation
  # Raises ArgumentError for typos or unknown parameters:
  #
  #   ArticlesQuery.new(athor_id: 1)  # => ArgumentError: Unknown param(s): athor_id
  #
  # ### 3. Self-documenting queries
  # Query classes show exactly what parameters are available:
  #
  #   ArticlesQuery.binds  # => {author_id: {default: nil}, status: {default: nil}}
  #   ArticlesQuery.vars   # => {order_by: {default: "created_at DESC"}}
  #
  # ### 4. Middleware support
  # Include concerns to add functionality:
  #
  #   class ApplicationQuery < AppQuery::BaseQuery
  #     include AppQuery::Paginatable
  #     include AppQuery::Mappable
  #   end
  #
  # ### 5. Casts
  # Define casts for columns:
  #
  #   class ApplicationQuery < AppQuery::BaseQuery
  #     cast metadata: :json
  #   end
  #
  # ## Parameter types
  #
  # - **bind**: SQL bind parameters (safe from injection, used in WHERE clauses)
  # - **var**: ERB template variables (for dynamic SQL generation like ORDER BY)
  #
  # ## Naming convention
  #
  # Query class name maps to SQL file:
  # - `ArticlesQuery` -> `articles.sql.erb`
  # - `Reports::MonthlyQuery` -> `reports/monthly.sql.erb`
  #
  # ## Example
  #
  #   # app/queries/articles.sql.erb
  #   SELECT * FROM articles
  #   WHERE author_id = :author_id
  #   <% if @status %>AND status = :status<% end %>
  #   ORDER BY <%= @order_by %>
  #
  #   # app/queries/articles_query.rb
  #   class ArticlesQuery < AppQuery::BaseQuery
  #     bind :author_id
  #     bind :status, default: nil
  #     var :order_by, default: "created_at DESC"
  #     cast published_at: :datetime
  #   end
  #
  #   # Usage
  #   ArticlesQuery.new(author_id: 1).entries
  #   ArticlesQuery.new(author_id: 1, status: "draft", order_by: "title").first
  #
  class BaseQuery
    class_attribute :_binds, default: {}
    class_attribute :_vars, default: {}
    class_attribute :_casts, default: {}

    class << self
      def bind(name, default: nil)
        self._binds = _binds.merge(name => {default:})
        attr_reader name
      end

      def var(name, default: nil)
        self._vars = _vars.merge(name => {default:})
        attr_reader name
      end

      def cast(casts = nil)
        return _casts if casts.nil?
        self._casts = casts
      end

      def binds = _binds

      def vars = _vars
    end

    def initialize(**params)
      all_known = self.class.binds.keys + self.class.vars.keys
      unknown = params.keys - all_known
      raise ArgumentError, "Unknown param(s): #{unknown.join(", ")}" if unknown.any?

      self.class.binds.merge(self.class.vars).each do |name, options|
        value = params.fetch(name) {
          default = options[:default]
          default.is_a?(Proc) ? instance_exec(&default) : default
        }
        instance_variable_set(:"@#{name}", value)
      end
    end

    delegate :select_all, :select_one, :count, :to_s, :column, :first, :ids, to: :query

    def entries
      select_all
    end

    def query
      @query ||= base_query
        .render(**render_vars)
        .with_binds(**bind_vars)
    end

    def base_query
      AppQuery[query_name, cast: self.class.cast]
    end

    private

    def query_name
      self.class.name.underscore.sub(/_query$/, "")
    end

    def render_vars
      self.class.vars.keys.to_h { [_1, send(_1)] }
    end

    def bind_vars
      self.class.binds.keys.to_h { [_1, send(_1)] }
    end
  end
end
