# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/base_query"
require_relative "app_query/paginatable"
require_relative "app_query/mappable"
require_relative "app_query/tokenizer"
require_relative "app_query/render_helpers"
require "active_record"

# AppQuery provides a way to work with raw SQL queries using ERB templating,
# parameter binding, and CTE manipulation.
#
# @example Using the global function
#   AppQuery("SELECT * FROM users WHERE id = $1").select_one(binds: [1])
#   AppQuery("SELECT * FROM users WHERE id = :id").select_one(binds: {id: 1})
#
# @example Loading queries from files
#   # Loads from app/queries/invoices.sql
#   AppQuery[:invoices].select_all
#
# @example Configuration
#   AppQuery.configure do |config|
#     config.query_path = "db/queries"
#   end
#
# @example CTE manipulation
#   AppQuery(<<~SQL).select_all("select * from articles where id = 1")
#     WITH articles AS(...)
#     SELECT * FROM articles
#     ORDER BY id
#   SQL
module AppQuery
  # Generic error class for AppQuery errors.
  class Error < StandardError; end

  # Raised when attempting to execute a query that contains unrendered ERB.
  class UnrenderedQueryError < StandardError; end

  # Configuration options for AppQuery.
  #
  # @!attribute query_path
  #   @return [String] the directory path where query files are located
  #     (default: "app/queries")
  Configuration = Struct.new(:query_path)

  # Returns the current configuration.
  #
  # @return [Configuration] the configuration instance
  def self.configuration
    @configuration ||= AppQuery::Configuration.new
  end

  # Yields the configuration for modification.
  #
  # @yield [Configuration] the configuration instance
  #
  # @example
  #   AppQuery.configure do |config|
  #     config.query_path = "db/queries"
  #   end
  def self.configure
    yield configuration if block_given?
  end

  # Resets configuration to default values.
  #
  # @return [void]
  def self.reset_configuration!
    configure do |config|
      config.query_path = "app/queries"
    end
  end
  reset_configuration!

  # @!group Quoting Helpers

  # Quotes a table name for safe use in SQL.
  #
  # @param name [String, Symbol] the table name
  # @return [String] the quoted table name
  def self.quote_table(name)
    ActiveRecord::Base.connection.quote_table_name(name)
  end

  # Quotes a column name for safe use in SQL.
  #
  # @param name [String, Symbol] the column name
  # @return [String] the quoted column name
  def self.quote_column(name)
    ActiveRecord::Base.connection.quote_column_name(name)
  end

  # @!endgroup

  # Loads a query from a file in the configured query path.
  #
  # When no extension is provided, tries `.sql` first, then `.sql.erb`.
  # Raises an error if both files exist (ambiguous).
  #
  # @param query_name [String, Symbol] the query name or path (without extension)
  # @param opts [Hash] additional options passed to {Q#initialize}
  # @return [Q] a new query object loaded from the file
  #
  # @example Load a .sql file
  #   AppQuery[:invoices]  # loads app/queries/invoices.sql
  #
  # @example Load a .sql.erb file (when .sql doesn't exist)
  #   AppQuery[:dynamic_report]  # loads app/queries/dynamic_report.sql.erb
  #
  # @example Load from a subdirectory
  #   AppQuery["reports/weekly"]  # loads app/queries/reports/weekly.sql
  #
  # @example Load with explicit extension
  #   AppQuery["invoices.sql.erb"]  # loads app/queries/invoices.sql.erb
  #
  # @raise [Error] if both `.sql` and `.sql.erb` files exist for the same name
  def self.[](query_name, **opts)
    base = Pathname.new(configuration.query_path) / query_name.to_s

    full_path = if File.extname(query_name.to_s).empty?
      sql_path = base.sub_ext(".sql").expand_path
      erb_path = base.sub_ext(".sql.erb").expand_path
      sql_exists = sql_path.exist?
      erb_exists = erb_path.exist?

      if sql_exists && erb_exists
        raise Error, "Ambiguous query name #{query_name.inspect}: both #{sql_path} and #{erb_path} exist"
      end

      sql_exists ? sql_path : erb_path
    else
      base.expand_path
    end

    Q.new(full_path.read, name: "AppQuery #{query_name}", filename: full_path.to_s, **opts)
  end

  # Creates a query that selects all columns from a table.
  #
  # Convenience method for quickly querying a table without writing SQL.
  #
  # @param name [Symbol, String] the table name
  # @param opts [Hash] additional options passed to {Q#initialize}
  # @return [Q] a new query object selecting from the table
  #
  # @example Basic usage
  #   AppQuery.table(:products).count
  #   AppQuery.table(:products).take(5)
  #
  # @example With binds
  #   AppQuery.table(:users, binds: {active: true})
  #     .select_all("SELECT * FROM :_ WHERE active = :active")
  def self.table(name, **opts)
    Q.new("SELECT * FROM #{quote_table(name)}", name: "AppQuery.table(#{name})", **opts)
  end

  class Result < ActiveRecord::Result
    attr_accessor :cast
    alias_method :cast?, :cast

    def initialize(columns, rows, overrides = nil, cast: false)
      super(columns, rows, overrides)
      @cast = cast
      # Rails v6.1: prevent mutate on frozen object on #first
      @hash_rows = [] if columns.empty?
    end

    def column(name = nil, unique: false)
      return [] if empty?
      unless name.nil? || includes_column?(name)
        raise ArgumentError, "Unknown column #{name.inspect}. Should be one of #{columns.inspect}."
      end
      ix = name.nil? ? 0 : columns.index(name)
      rows.map { _1[ix] }.then { unique ? _1.uniq! : _1 }
    end

    def size
      count
    end

    private

    # Override to provide indifferent access (string or symbol keys).
    def hash_rows
      @hash_rows ||= rows.map do |row|
        columns.zip(row).to_h.with_indifferent_access
      end
    end

    public

    # Transforms each record in-place using the provided block.
    #
    # @yield [Hash] each record as a hash with indifferent access
    # @yieldreturn [Hash] the transformed record
    # @return [self] the result object for chaining
    #
    # @example Add a computed field
    #   result = AppQuery[:users].select_all
    #   result.transform! { |r| r.merge("full_name" => "#{r['first']} #{r['last']}") }
    def transform!
      @hash_rows = hash_rows.map { |r| yield(r) } unless empty?
      self
    end

    # Resolves a cast type value, converting symbols to ActiveRecord types.
    #
    # @param value [Symbol, Object] the cast type (symbol shorthand or type instance)
    # @return [Object] the resolved type instance
    #
    # @example
    #   resolve_cast_type(:date)  #=> ActiveRecord::Type::Date instance
    #   resolve_cast_type(ActiveRecord::Type::Json.new)  #=> returns as-is
    def self.resolve_cast_type(value)
      case value
      when Symbol
        ActiveRecord::Type.lookup(value)
      else
        value
      end
    end

    def self.from_ar_result(r, cast = nil)
      if r.empty?
        r.columns.empty? ? EMPTY : new(r.columns, [], r.column_types)
      else
        cast &&= case cast
        when Array
          r.columns.zip(cast).to_h
        when Hash
          cast.transform_keys(&:to_s).transform_values { |v| resolve_cast_type(v) }
        else
          {}
        end
        if !cast || (cast.empty? && r.column_types.empty?)
          # nothing to cast
          new(r.columns, r.rows, r.column_types)
        else
          overrides = (r.column_types || {}).merge(cast)
          rows = r.cast_values(overrides)
          # One column is special :( ;(
          # > ActiveRecord::Base.connection.select_all("select array[1,2]").rows
          # => [["{1,2}"]]
          # > ActiveRecord::Base.connection.select_all("select array[1,2]").cast_values
          # => [[1, 2]]
          rows = rows.zip if r.columns.one?
          new(r.columns, rows, overrides, cast: true)
        end
      end
    end

    empty_array = [].freeze
    EMPTY_HASH = {}.freeze
    private_constant :EMPTY_HASH

    EMPTY = new(empty_array, empty_array, EMPTY_HASH).freeze
    private_constant :EMPTY
  end

  # Query object for building, rendering, and executing SQL queries.
  #
  # Q wraps a SQL string (optionally with ERB templating) and provides methods
  # for query execution, CTE manipulation, and result handling.
  #
  # ## Method Groups
  #
  # - **Rendering** — Process ERB templates to produce executable SQL.
  # - **Query Execution** — Execute queries against the database. These methods
  #   wrap the equivalent `ActiveRecord::Base.connection` methods (`select_all`,
  #   `insert`, `update`, `delete`).
  # - **Query Introspection** — Inspect and analyze the structure of the query.
  # - **Query Transformation** — Create modified copies of the query. All
  #   transformation methods are immutable—they return a new {Q} instance and
  #   leave the original unchanged.
  # - **CTE Manipulation** — Add, replace, or reorder Common Table Expressions
  #   (CTEs). Like transformation methods, these return a new {Q} instance.
  #
  # @example Basic query
  #   AppQuery("SELECT * FROM users WHERE id = $1").select_one(binds: [1])
  #
  # @example ERB templating
  #   AppQuery("SELECT * FROM users WHERE name = <%= bind(name) %>")
  #     .render(name: "Alice")
  #     .select_all
  #
  # @example CTE manipulation
  #   AppQuery("WITH base AS (SELECT 1) SELECT * FROM base")
  #     .append_cte("extra AS (SELECT 2)")
  #     .select_all
  class Q
    # @return [String, nil] optional name for the query (used in logs)
    # @return [String] the SQL string
    # @return [Array, Hash] bind parameters
    # @return [Boolean, Hash, Array] casting configuration
    attr_reader :sql, :name, :filename, :binds, :cast

    # Creates a new query object.
    #
    # @param sql [String] the SQL query string (may contain ERB)
    # @param name [String, nil] optional name for logging
    # @param filename [String, nil] optional filename for ERB error reporting
    # @param binds [Hash, nil] bind parameters for the query
    # @param cast [Boolean, Hash, Array] type casting configuration
    #
    # @example Simple query
    #   Q.new("SELECT * FROM users")
    #
    # @example With ERB and binds
    #   Q.new("SELECT * FROM users WHERE id = :id", binds: {id: 1})
    def initialize(sql, name: nil, filename: nil, binds: {}, cast: true, cte_depth: 0)
      @sql = sql
      @name = name
      @filename = filename
      @binds = binds
      @cast = cast
      @cte_depth = cte_depth
      @binds = binds_with_defaults(sql, binds)
    end

    attr_reader :cte_depth

    def to_arel
      if binds.presence
        Arel::Nodes::BoundSqlLiteral.new sql, [], binds
      else
        # TODO: add retryable? available from >=7.1
        Arel::Nodes::SqlLiteral.new(sql)
      end
    end

    private def binds_with_defaults(sql, binds)
      if (named_binds = sql.scan(/:(?<!::)([a-zA-Z]\w*)/).flatten.map(&:to_sym).uniq.presence)
        named_binds.zip(Array.new(named_binds.count)).to_h.merge(binds.to_h)
      else
        binds.to_h
      end
    end

    def deep_dup(sql: self.sql, name: self.name, filename: self.filename, binds: self.binds.dup, cast: self.cast, cte_depth: self.cte_depth)
      self.class.new(sql, name:, filename:, binds:, cast:, cte_depth:)
    end

    # @!group Rendering

    # Renders the ERB template with the given variables.
    #
    # Processes ERB tags in the SQL and collects any bind parameters created
    # by helpers like {RenderHelpers#bind} and {RenderHelpers#values}.
    #
    # @param vars [Hash] variables to make available in the ERB template
    # @return [Q] a new query object with rendered SQL and collected binds
    #
    # @example Rendering with variables
    #   AppQuery("SELECT * FROM users WHERE name = <%= bind(name) %>")
    #     .render(name: "Alice")
    #   # => Q with SQL: "SELECT * FROM users WHERE name = :b1"
    #   #    and binds: {b1: "Alice"}
    #
    # @example Using instance variables
    #   AppQuery("SELECT * FROM users WHERE active = <%= @active %>")
    #     .render(active: true)
    #
    # @example vars are available as local and instance variable.
    #   # This fails as `ordering` is not provided:
    #   AppQuery(<<~SQL).render
    #     SELECT * FROM articles
    #     <%= order_by(ordering) %>
    #   SQL
    #
    #   # ...but this query works without `ordering` being passed to render:
    #   AppQuery(<<~SQL).render
    #     SELECT * FROM articles
    #     <%= @ordering.presence && order_by(ordering) %>
    #   SQL
    #   # NOTE that `@ordering.present? && ...` would render as `false`.
    #   # Use `@ordering.presence` instead.
    #
    #
    # @see RenderHelpers for available helper methods in templates
    def render(vars = {})
      vars ||= {}
      helper = render_helper(vars)
      sql = to_erb.result(helper.get_binding)
      collected = helper.collected_binds

      with_sql(sql).add_binds(**collected)
    end

    def to_erb
      ERB.new(sql, trim_mode: "-").tap { _1.location = [@filename, 0] if @filename }
    end
    private :to_erb

    def render_helper(vars)
      Module.new do
        extend self
        include AppQuery::RenderHelpers

        @collected_binds = {}
        @placeholder_counter = 0

        vars.each do |k, v|
          define_method(k) { v }
          instance_variable_set(:"@#{k}", v)
        end

        attr_reader :collected_binds

        def get_binding
          binding
        end
      end
    end
    private :render_helper

    # @!group Query Execution

    # Executes the query and returns all matching rows.
    #
    # @param select [String, nil] override the SELECT clause
    # @param binds [Hash, nil] bind parameters to add
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Result] the query results with optional type casting
    #
    # @example (Named) binds
    #   AppQuery("SELECT * FROM users WHERE id = :id").select_all(binds: {id: 1})
    #
    # @example With type casting (shorthand)
    #   AppQuery("SELECT published_on FROM articles")
    #     .select_all(cast: {"published_on" => :date})
    #
    # @example With type casting (explicit)
    #   AppQuery("SELECT metadata FROM products")
    #     .select_all(cast: {"metadata" => ActiveRecord::Type::Json.new})
    #
    # @example Override SELECT clause
    #   AppQuery("SELECT * FROM users").select_all("COUNT(*)")
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    def select_all(s = nil, binds: {}, cast: self.cast)
      add_binds(**binds).with_select(s).render({}).then do |aq|
        sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
          aq.to_arel
        else
          ActiveRecord::Base.sanitize_sql_array([aq.to_s, aq.binds])
        end
        ActiveRecord::Base.connection.select_all(sql, aq.name).then do |result|
          Result.from_ar_result(result, cast)
        end
      end
    rescue NameError => e
      # Prevent any subclasses, e.g. NoMethodError
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before select-ing."
    end

    # Executes the query and returns the first row.
    #
    # @param binds [Hash, nil] bind parameters to add
    # @param select [String, nil] override the SELECT clause
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Hash, nil] the first row as a hash, or nil if no results
    #
    # @example
    #   AppQuery("SELECT * FROM users WHERE id = :id").select_one(binds: {id: 1})
    #   # => {"id" => 1, "name" => "Alice"}
    #
    # @see #select_all
    def select_one(s = nil, binds: {}, cast: self.cast)
      with_select(s).select_all("SELECT * FROM :_ LIMIT 1", binds:, cast:).first
    end
    alias_method :first, :select_one

    # Executes the query and returns the last row.
    #
    # Uses OFFSET to skip to the last row without changing the query order.
    # Note: This requires counting all rows first, so it's less efficient
    # than {#first} for large result sets.
    #
    # @param s [String, nil] optional SELECT to apply before fetching
    # @param binds [Hash, nil] bind parameters to add
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Hash, nil] the last row as a hash, or nil if no results
    #
    # @example
    #   AppQuery("SELECT * FROM users ORDER BY created_at").last
    #   # => {"id" => 42, "name" => "Zoe"}
    #
    # @see #first
    def last(s = nil, binds: {}, cast: self.cast)
      with_select(s).select_all(
        "SELECT * FROM :_ LIMIT 1 OFFSET GREATEST((SELECT COUNT(*) FROM :_) - 1, 0)",
        binds:, cast:
      ).first
    end

    # Executes the query and returns the first n rows.
    #
    # @param n [Integer] the number of rows to return
    # @param s [String, nil] optional SELECT to apply before taking
    # @param binds [Hash, nil] bind parameters to add
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Array<Hash>] the first n rows as an array of hashes
    #
    # @example
    #   AppQuery("SELECT * FROM users ORDER BY created_at").take(5)
    #   # => [{"id" => 1, ...}, {"id" => 2, ...}, ...]
    #
    # @see #first
    def take(n, s = nil, binds: {}, cast: self.cast)
      with_select(s).select_all("SELECT * FROM :_ LIMIT #{n.to_i}", binds:, cast:).entries
    end
    alias_method :limit, :take

    # Executes the query and returns the first value of the first row.
    #
    # @param binds [Hash, nil] named bind parameters
    # @param select [String, nil] override the SELECT clause
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Object, nil] the first value, or nil if no results
    #
    # @example
    #   AppQuery("SELECT COUNT(*) FROM users").select_value
    #   # => 42
    #
    # @see #select_one
    def select_value(s = nil, binds: {}, cast: self.cast)
      select_one(s, binds:, cast:)&.values&.first
    end

    # Returns the count of rows from the query.
    #
    # Wraps the query in a CTE and selects only the count, which is more
    # efficient than fetching all rows via `select_all.count`.
    #
    # @param s [String, nil] optional SELECT to apply before counting
    # @param binds [Hash, nil] bind parameters to add
    # @return [Integer] the count of rows
    #
    # @example Simple count
    #   AppQuery("SELECT * FROM users").count
    #   # => 42
    #
    # @example Count with filtering
    #   AppQuery("SELECT * FROM users")
    #     .with_select("SELECT * FROM :_ WHERE active")
    #     .count
    #   # => 10
    def count(s = nil, binds: {})
      with_select(s).select_all("SELECT COUNT(*) c FROM :_", binds:).column("c").first
    end

    # Returns whether any rows exist in the query result.
    #
    # Uses `EXISTS` which stops at the first matching row, making it more
    # efficient than `count > 0` for large result sets.
    #
    # @param s [String, nil] optional SELECT to apply before checking
    # @param binds [Hash, nil] bind parameters to add
    # @return [Boolean] true if at least one row exists
    #
    # @example Check if query has results
    #   AppQuery("SELECT * FROM users").any?
    #   # => true
    #
    # @example Check with filtering
    #   AppQuery("SELECT * FROM users").any?("SELECT * FROM :_ WHERE admin")
    #   # => false
    def any?(s = nil, binds: {})
      with_select(s).select_all("SELECT EXISTS(SELECT 1 FROM :_) e", binds:).column("e").first
    end

    # Returns whether no rows exist in the query result.
    #
    # Inverse of {#any?}. Uses `EXISTS` for efficiency.
    #
    # @param s [String, nil] optional SELECT to apply before checking
    # @param binds [Hash, nil] bind parameters to add
    # @return [Boolean] true if no rows exist
    #
    # @example Check if query is empty
    #   AppQuery("SELECT * FROM users WHERE admin").none?
    #   # => true
    def none?(s = nil, binds: {})
      !any?(s, binds:)
    end

    # Returns an array of values for a single column.
    #
    # Wraps the query in a CTE and selects only the specified column, which is
    # more efficient than fetching all columns via `select_all.column(name)`.
    # The column name is safely quoted, making this method safe for user input.
    #
    # @param c [String, Symbol] the column name to extract
    # @param s [String, nil] optional SELECT to apply before extracting
    # @param binds [Hash, nil] bind parameters to add
    # @param unique [Boolean] whether to have unique values
    # @return [Array] the column values
    #
    # @example Extract a single column
    #   AppQuery("SELECT id, name FROM users").column(:name)
    #   # => ["Alice", "Bob", "Charlie"]
    #
    # @example With additional filtering
    #   AppQuery("SELECT * FROM users").column(:email, "SELECT * FROM :_ WHERE active")
    #   # => ["alice@example.com", "bob@example.com"]
    #
    # @example Extract unique values
    #   AppQuery("SELECT * FROM products").column(:category, unique: true)
    #   # => ["Electronics", "Clothing", "Home"]
    def column(c, s = nil, binds: {}, unique: false)
      quoted = quote_column(c)
      select_expr = unique ? "DISTINCT #{quoted}" : quoted
      with_select(s).select_all("SELECT #{select_expr} AS column FROM :_", binds:).column("column")
    end

    # Returns the column names from the query without fetching any rows.
    #
    # Uses `LIMIT 0` to get column metadata efficiently.
    #
    # @param s [String, nil] optional SELECT to apply before extracting
    # @param binds [Hash, nil] bind parameters to add
    # @return [Array<String>] the column names
    #
    # @example Get column names
    #   AppQuery("SELECT id, name, email FROM users").columns
    #   # => ["id", "name", "email"]
    #
    # @example From a CTE
    #   AppQuery("WITH t(a, b) AS (VALUES (1, 2)) SELECT * FROM t").columns
    #   # => ["a", "b"]
    def columns(s = nil, binds: {})
      with_select(s).select_all("SELECT * FROM :_ LIMIT 0", binds:).columns
    end

    # Returns an array of id values from the query.
    #
    # Convenience method equivalent to `column(:id)`. More efficient than
    # fetching all columns via `select_all.column("id")`.
    #
    # @param s [String, nil] optional SELECT to apply before extracting
    # @param binds [Hash, nil] bind parameters to add
    # @return [Array] the id values
    #
    # @example Get all user IDs
    #   AppQuery("SELECT * FROM users").ids
    #   # => [1, 2, 3]
    #
    # @example With filtering
    #   AppQuery("SELECT * FROM users").ids("SELECT * FROM :_ WHERE active")
    #   # => [1, 3]
    def ids(s = nil, binds: {})
      column(:id, s, binds:)
    end

    # Executes the query and returns results as an Array of Hashes.
    #
    # Shorthand for `select_all(...).entries`. Accepts the same arguments as
    # {#select_all}.
    #
    # @return [Array<Hash>] the query results as an array
    #
    # @example
    #   AppQuery("SELECT * FROM users").entries
    #   # => [{"id" => 1, "name" => "Alice"}, {"id" => 2, "name" => "Bob"}]
    #
    # @see #select_all
    def entries(...)
      select_all(...).entries
    end

    # Executes an INSERT query.
    #
    # @param binds [Hash, nil] bind parameters for the query
    # @param returning [String, nil] columns to return (Rails 7.1+ only)
    # @return [Integer, Object] the inserted ID or returning value
    #
    # @example With values helper
    #   articles = [{title: "First", created_at: Time.current}]
    #   AppQuery(<<~SQL).render(articles:).insert
    #     INSERT INTO articles(title, created_at) <%= values(articles) %>
    #   SQL
    #
    # @example With returning (Rails 7.1+)
    #   AppQuery("INSERT INTO users(name) VALUES($1)")
    #     .insert(binds: ["Alice"], returning: "id, created_at")
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    # @raise [ArgumentError] if returning is used with Rails < 7.1
    def insert(binds: {}, returning: nil)
      # ActiveRecord::Base.connection.insert(sql, name, _pk = nil, _id_value = nil, _sequence_name = nil, binds, returning: nil)
      if returning && ActiveRecord::VERSION::STRING.to_f < 7.1
        raise ArgumentError, "The 'returning' option requires Rails 7.1+. Current version: #{ActiveRecord::VERSION::STRING}"
      end

      with_binds(**binds).render({}).then do |aq|
        sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
          aq.to_arel
        else
          ActiveRecord::Base.sanitize_sql_array([aq.to_s, **aq.binds])
        end
        if ActiveRecord::VERSION::STRING.to_f >= 7.1
          ActiveRecord::Base.connection.insert(sql, name, returning:)
        else
          ActiveRecord::Base.connection.insert(sql, name)
        end
      end
    rescue NameError => e
      # Prevent any subclasses, e.g. NoMethodError
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before select-ing."
    end

    # Executes an UPDATE query.
    #
    # @param binds [Hash, nil] bind parameters for the query
    # @return [Integer] the number of affected rows
    #
    # @example With named binds
    #   AppQuery("UPDATE videos SET title = 'New' WHERE id = :id")
    #     .update(binds: {id: 1})
    #
    # @example With positional binds
    #   AppQuery("UPDATE videos SET title = $1 WHERE id = $2")
    #     .update(binds: ["New Title", 1])
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    def update(binds: {})
      with_binds(**binds).render({}).then do |aq|
        sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
          aq.to_arel
        else
          ActiveRecord::Base.sanitize_sql_array([aq.to_s, **aq.binds])
        end
        ActiveRecord::Base.connection.update(sql, name)
      end
    rescue NameError => e
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before updating."
    end

    # Executes a DELETE query.
    #
    # @param binds [Hash, nil] bind parameters for the query
    # @return [Integer] the number of deleted rows
    #
    # @example With named binds
    #   AppQuery("DELETE FROM videos WHERE id = :id").delete(binds: {id: 1})
    #
    # @example With positional binds
    #   AppQuery("DELETE FROM videos WHERE id = $1").delete(binds: [1])
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    def delete(binds: {})
      with_binds(**binds).render({}).then do |aq|
        sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
          aq.to_arel
        else
          ActiveRecord::Base.sanitize_sql_array([aq.to_s, **aq.binds])
        end
        ActiveRecord::Base.connection.delete(sql, name)
      end
    rescue NameError => e
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before deleting."
    end

    # Executes COPY TO STDOUT for efficient data export.
    #
    # PostgreSQL-only. Uses raw connection for streaming. Raises an error
    # when used with SQLite or other non-PostgreSQL adapters.
    #
    # @param s [String, nil] optional SELECT to apply before extracting
    # @param format [:csv, :text, :binary] output format (default: :csv)
    # @param header [Boolean] include column headers (default: true, CSV only)
    # @param delimiter [Symbol, nil] field delimiter - :tab, :comma, :pipe, :semicolon (default: format's default)
    # @param dest [String, IO, nil] destination - file path, IO object, or nil to return string
    # @param binds [Hash] bind parameters
    # @return [String, Integer, nil] CSV string if dest: nil, bytes written if dest: path, nil if dest: IO
    #
    # @example Return as string
    #   csv = AppQuery[:users].copy_to
    #
    # @example Write to file path
    #   AppQuery[:users].copy_to(dest: "export.csv")
    #
    # @example Write to IO object
    #   File.open("export.csv", "w") { |f| query.copy_to(dest: f) }
    #
    # @example Export in Rails controller
    #   respond_to do |format|
    #      format.html do
    #        @invoices = query.entries
    #
    #        render :index
    #      end
    #
    #      format.csv do
    #        response.headers['Content-Type'] = 'text/csv'
    #        response.headers['Content-Disposition'] = 'attachment; filename="invoices.csv"'
    #
    #        query.unpaginated.copy_to(dest: response.stream)
    #      end
    #    end
    #
    # @example Rails runner
    #   bin/rails runner "puts Export::ProductsQuery.new.copy_to" > tmp/products.csv
    #
    # @raise [AppQuery::Error] if adapter is not PostgreSQL
    def copy_to(s = nil, format: :csv, header: true, delimiter: nil, dest: nil, binds: {})
      raw_conn = ActiveRecord::Base.connection.raw_connection
      unless raw_conn.respond_to?(:copy_data)
        raise Error, "copy_to requires PostgreSQL (current adapter does not support COPY)"
      end

      allowed_formats = %i[csv text binary]
      unless allowed_formats.include?(format)
        raise ArgumentError, "Invalid format: #{format.inspect}. Allowed: #{allowed_formats.join(", ")}"
      end

      delimiters = {tab: "\t", comma: ",", pipe: "|", semicolon: ";"}
      if delimiter
        if !delimiters.key?(delimiter)
          raise ArgumentError, "Invalid delimiter: #{delimiter.inspect}. Allowed: #{delimiters.keys.join(", ")}"
        elsif format == :binary
          raise ArgumentError, "Delimiter not allowed for format :binary"
        end
      end

      add_binds(**binds).with_select(s).render({}).then do |aq|
        options = ["FORMAT #{format.to_s.upcase}"]
        options << "HEADER" if header && format == :csv
        options << "DELIMITER E'#{delimiters[delimiter]}'" if delimiter

        inner_sql = ActiveRecord::Base.sanitize_sql_array([aq.to_s, aq.binds])
        copy_sql = "COPY (#{inner_sql}) TO STDOUT WITH (#{options.join(", ")})"

        case dest
        when NilClass
          output = +""
          raw_conn.copy_data(copy_sql) do
            while (row = raw_conn.get_copy_data)
              output << row
            end
          end
          # pg returns ASCII-8BIT, but CSV/text is UTF-8; binary stays as-is
          (format == :binary) ? output : output.force_encoding(Encoding::UTF_8)
        when String
          bytes = 0
          File.open(dest, "wb") do |f|
            raw_conn.copy_data(copy_sql) do
              while (row = raw_conn.get_copy_data)
                bytes += f.write(row)
              end
            end
          end
          bytes
        else
          raw_conn.copy_data(copy_sql) do
            while (row = raw_conn.get_copy_data)
              dest.write(row)
            end
          end
          nil
        end
      end
    end

    # @!group Query Introspection

    # Returns the tokenized representation of the SQL.
    #
    # @return [Array<Hash>] array of token hashes with :t (type) and :v (value) keys
    # @see Tokenizer
    def tokens
      @tokens ||= tokenizer.run
    end

    # Returns the tokenizer instance for this query.
    #
    # @return [Tokenizer] the tokenizer
    def tokenizer
      @tokenizer ||= Tokenizer.new(to_s)
    end

    # Returns the names of all CTEs (Common Table Expressions) in the query.
    #
    # @return [Array<String>] the CTE names in order of appearance
    #
    # @example
    #   AppQuery("WITH a AS (SELECT 1), b AS (SELECT 2) SELECT * FROM a, b").cte_names
    #   # => ["a", "b"]
    #
    # @example Quoted identifiers are returned without quotes
    #   AppQuery('WITH "special*name" AS (SELECT 1) SELECT * FROM "special*name"').cte_names
    #   # => ["special*name"]
    def cte_names
      tokens.filter { _1[:t] == "CTE_IDENTIFIER" }.map { _1[:v].delete_prefix('"').delete_suffix('"') }
    end

    # @!group Query Transformation

    # Returns a new query with different bind parameters.
    #
    # @param binds [Hash, nil] the bind parameters
    # @return [Q] a new query object with the binds replaced
    #
    # @example
    #   query = AppQuery("SELECT :foo, :bar", binds: {foo: 1})
    #   query.with_binds(bar: 2).binds
    #   # => {foo: nil, bar: 2}
    def with_binds(**binds)
      deep_dup(binds:)
    end
    alias_method :replace_binds, :with_binds

    # Returns a new query with binds added.
    #
    # @param binds [Hash, nil] the bind parameters to add
    # @return [Q] a new query object with the added binds
    #
    # @example
    #   query = AppQuery("SELECT :foo, :bar", binds: {foo: 1})
    #   query.add_binds(bar: 2).binds
    #   # => {foo: 1, bar: 2}
    def add_binds(**binds)
      deep_dup(binds: self.binds.merge(binds))
    end

    # Returns a new query with different cast settings.
    #
    # @param cast [Boolean, Hash, Array] the new cast configuration
    # @return [Q] a new query object with the specified cast settings
    #
    # @example
    #   query = AppQuery("SELECT created_at FROM users")
    #   query.with_cast(false).select_all  # disable casting
    def with_cast(cast)
      deep_dup(cast:)
    end

    # Returns a new query with different SQL.
    #
    # @param sql [String] the new SQL string
    # @return [Q] a new query object with the specified SQL
    def with_sql(sql)
      deep_dup(sql:)
    end

    # Returns a new query with a modified SELECT statement.
    #
    # Wraps the current SELECT in a numbered CTE and applies the new SELECT.
    # CTEs are named `_`, `_1`, `_2`, etc. Use `:_` in the new SELECT to
    # reference the previous result.
    #
    # @param sql [String, nil] the new SELECT statement (nil returns self)
    # @return [Q] a new query object with the modified SELECT
    #
    # @example Single transformation
    #   AppQuery("SELECT * FROM users").with_select("SELECT COUNT(*) FROM :_")
    #   # => "WITH _ AS (\n  SELECT * FROM users\n)\nSELECT COUNT(*) FROM _"
    #
    # @example Chained transformations
    #   AppQuery("SELECT * FROM users")
    #     .with_select("SELECT * FROM :_ WHERE active")
    #     .with_select("SELECT COUNT(*) FROM :_")
    #   # => WITH _ AS (SELECT * FROM users),
    #   #         _1 AS (SELECT * FROM _ WHERE active)
    #   #    SELECT COUNT(*) FROM _1
    def with_select(sql)
      return self if sql.nil?

      # First CTE is "_", then "_1", "_2", etc.
      current_cte = (cte_depth == 0) ? "_" : "_#{cte_depth}"

      # Replace :_ with the current CTE name
      processed_sql = sql.gsub(/:_\b/, current_cte)

      # Wrap current SELECT in numbered CTE (indent all lines, strip trailing whitespace)
      indented_select = select.rstrip.gsub("\n", "\n  ")
      new_cte = "#{current_cte} AS (\n  #{indented_select}\n)"

      append_cte(new_cte).then do |q|
        # Replace the SELECT token with processed_sql and increment depth
        new_sql = q.tokens.each_with_object([]) do |token, acc|
          v = (token[:t] == "SELECT") ? processed_sql : token[:v]
          acc << v
        end.join
        q.deep_dup(sql: new_sql, cte_depth: cte_depth + 1)
      end
    end

    # @!group Query Introspection

    # Returns the SELECT clause of the query.
    #
    # @return [String, nil] the SELECT clause, or nil if not found
    #
    # @example
    #   AppQuery("SELECT id, name FROM users").select
    #   # => "SELECT id, name FROM users"
    def select
      tokens.find { _1[:t] == "SELECT" }&.[](:v)
    end

    # Checks if the query uses RECURSIVE CTEs.
    #
    # @return [Boolean] true if the query contains WITH RECURSIVE
    #
    # @example
    #   AppQuery("WITH RECURSIVE t AS (...) SELECT * FROM t").recursive?
    #   # => true
    def recursive?
      !!tokens.find { _1[:t] == "RECURSIVE" }
    end

    # @!group CTE Manipulation

    # Returns a new query focused on the specified CTE.
    #
    # Wraps the query to select from the named CTE, allowing you to
    # inspect or test individual CTEs in isolation.
    #
    # @param name [Symbol, String] the CTE name to select from
    # @return [Q] a new query selecting from the CTE
    # @raise [ArgumentError] if the CTE doesn't exist
    #
    # @example Focus on a specific CTE
    #   query = AppQuery("WITH published AS (SELECT * FROM articles WHERE published) SELECT * FROM published")
    #   query.cte(:published).entries
    #
    # @example Chain with other methods
    #   ArticleQuery.new.cte(:active_articles).take(5)
    def cte(name)
      name = name.to_s
      unless cte_names.include?(name)
        raise ArgumentError, "Unknown CTE #{name.inspect}. Available: #{cte_names.inspect}"
      end
      with_select("SELECT * FROM #{quote_table(name)}")
    end

    # Prepends a CTE to the beginning of the WITH clause.
    #
    # If the query has no CTEs, wraps it with WITH. If the query already has
    # CTEs, adds the new CTE at the beginning.
    #
    # @param cte [String] the CTE definition (e.g., "foo AS (SELECT 1)")
    # @return [Q] a new query object with the prepended CTE
    #
    # @example Adding a CTE to a simple query
    #   AppQuery("SELECT 1").prepend_cte("foo AS (SELECT 2)")
    #   # => "WITH foo AS (SELECT 2) SELECT 1"
    #
    # @example Prepending to existing CTEs
    #   AppQuery("WITH bar AS (SELECT 2) SELECT * FROM bar")
    #     .prepend_cte("foo AS (SELECT 1)")
    #   # => "WITH foo AS (SELECT 1), bar AS (SELECT 2) SELECT * FROM bar"
    def prepend_cte(cte)
      # early raise when cte is not valid sql
      to_append = Tokenizer.tokenize(cte, state: :lex_prepend_cte).then do |tokens|
        recursive? ? tokens.reject { _1[:t] == "RECURSIVE" } : tokens
      end

      if cte_names.none?
        with_sql("WITH #{cte}\n#{self}")
      else
        split_at_type = recursive? ? "RECURSIVE" : "WITH"
        with_sql(tokens.map do |token|
          if token[:t] == split_at_type
            token[:v] + to_append.map { _1[:v] }.join
          else
            token[:v]
          end
        end.join)
      end
    end

    # Appends a CTE to the end of the WITH clause.
    #
    # If the query has no CTEs, wraps it with WITH. If the query already has
    # CTEs, adds the new CTE at the end.
    #
    # @param cte [String] the CTE definition (e.g., "foo AS (SELECT 1)")
    # @return [Q] a new query object with the appended CTE
    #
    # @example Adding a CTE to a simple query
    #   AppQuery("SELECT 1").append_cte("foo AS (SELECT 2)")
    #   # => "WITH foo AS (SELECT 2) SELECT 1"
    #
    # @example Appending to existing CTEs
    #   AppQuery("WITH bar AS (SELECT 2) SELECT * FROM bar")
    #     .append_cte("foo AS (SELECT 1)")
    #   # => "WITH bar AS (SELECT 2), foo AS (SELECT 1) SELECT * FROM bar"
    def append_cte(cte)
      # early raise when cte is not valid sql
      add_recursive, to_append = Tokenizer.tokenize(cte, state: :lex_append_cte).then do |tokens|
        [!recursive? && tokens.find { _1[:t] == "RECURSIVE" },
          tokens.reject { _1[:t] == "RECURSIVE" }]
      end

      if cte_names.none?
        with_sql("WITH #{cte}\n#{self}")
      else
        nof_ctes = cte_names.size

        with_sql(tokens.map do |token|
          nof_ctes -= 1 if token[:t] == "CTE_SELECT"

          if nof_ctes.zero?
            nof_ctes -= 1
            token[:v] + to_append.map { _1[:v] }.join
          elsif token[:t] == "WITH" && add_recursive
            token[:v] + add_recursive[:v]
          else
            token[:v]
          end
        end.join)
      end
    end

    # Replaces an existing CTE with a new definition.
    #
    # @param cte [String] the new CTE definition (must have same name as existing CTE)
    # @return [Q] a new query object with the replaced CTE
    #
    # @example
    #   AppQuery("WITH foo AS (SELECT 1) SELECT * FROM foo")
    #     .replace_cte("foo AS (SELECT 2)")
    #   # => "WITH foo AS (SELECT 2) SELECT * FROM foo"
    #
    # @raise [ArgumentError] if the CTE name doesn't exist in the query
    def replace_cte(cte)
      add_recursive, to_append = Tokenizer.tokenize(cte, state: :lex_recursive_cte).then do |tokens|
        [!recursive? && tokens.find { _1[:t] == "RECURSIVE" },
          tokens.reject { _1[:t] == "RECURSIVE" }]
      end

      cte_name = to_append.find { _1[:t] == "CTE_IDENTIFIER" }&.[](:v)
      unless cte_names.include?(cte_name)
        raise ArgumentError, "Unknown cte #{cte_name.inspect}. Options: #{cte_names}."
      end
      cte_ix = cte_names.index(cte_name)

      return self unless cte_ix

      cte_found = false

      with_sql(tokens.map do |token|
        if cte_found ||= token[:t] == "CTE_IDENTIFIER" && token[:v] == cte_name
          unless (cte_found = (token[:t] != "CTE_SELECT"))
            next to_append.map { _1[:v] }.join
          end

          next
        elsif token[:t] == "WITH" && add_recursive
          token[:v] + add_recursive[:v]
        else
          token[:v]
        end
      end.join)
    end

    # @!endgroup

    # Returns the SQL string.
    #
    # @return [String] the SQL query string
    def to_s
      @sql
    end

    private

    def quote_table(name)
      AppQuery.quote_table(name)
    end

    def quote_column(name)
      AppQuery.quote_column(name)
    end
  end
end

# Convenience method to create a new {AppQuery::Q} instance.
#
# Accepts the same arguments as {AppQuery::Q#initialize}.
#
# @return [AppQuery::Q] a new query object
#
# @example
#   AppQuery("SELECT * FROM users WHERE id = $1").select_one(binds: [1])
#
# @see AppQuery::Q#initialize
def AppQuery(...)
  AppQuery::Q.new(...)
end

begin
  require "rspec"
rescue LoadError
end

require_relative "app_query/rspec" if Object.const_defined? :RSpec
require_relative "app_query/railtie" if defined?(Rails::Railtie)
