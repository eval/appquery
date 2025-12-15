# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"
require_relative "app_query/render_helpers"
require "active_record"

module AppQuery
  class Error < StandardError; end

  class UnrenderedQueryError < StandardError; end

  Configuration = Struct.new(:query_path)

  def self.configuration
    @configuration ||= AppQuery::Configuration.new
  end

  def self.configure
    yield configuration if block_given?
  end

  def self.reset_configuration!
    configure do |config|
      config.query_path = "app/queries"
    end
  end
  reset_configuration!

  # Examples:
  #   AppQuery[:invoices] # looks for invoices.sql
  #   AppQuery["reports/weekly"]
  #   AppQuery["invoices.sql.erb"]
  def self.[](query_name, **opts)
    filename = File.extname(query_name.to_s).empty? ? "#{query_name}.sql" : query_name.to_s
    full_path = (Pathname.new(configuration.query_path) / filename).expand_path
    Q.new(full_path.read, name: "AppQuery #{query_name}", filename: full_path.to_s, **opts)
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

    def column(name = nil)
      return [] if empty?
      unless name.nil? || includes_column?(name)
        raise ArgumentError, "Unknown column #{name.inspect}. Should be one of #{columns.inspect}."
      end
      ix = name.nil? ? 0 : columns.index(name)
      rows.map { _1[ix] }
    end

    def size
      count
    end

    def self.from_ar_result(r, cast = nil)
      if r.empty?
        EMPTY
      else
        cast &&= case cast
        when Array
          r.columns.zip(cast).to_h
        when Hash
          cast
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
    attr_reader :name, :sql, :binds, :cast

    # Creates a new query object.
    #
    # @param sql [String] the SQL query string (may contain ERB)
    # @param name [String, nil] optional name for logging
    # @param filename [String, nil] optional filename for ERB error reporting
    # @param binds [Array, Hash] bind parameters for the query
    # @param cast [Boolean, Hash, Array] type casting configuration
    #
    # @example Simple query
    #   Q.new("SELECT * FROM users")
    #
    # @example With ERB and binds
    #   Q.new("SELECT * FROM users WHERE id = :id", binds: {id: 1})
    def initialize(sql, name: nil, filename: nil, binds: [], cast: true)
      @sql = sql
      @name = name
      @filename = filename
      @binds = binds
      @cast = cast
    end

    # @private
    def deep_dup
      super.send(:reset!)
    end
    private :deep_dup

    # @private
    def reset!
      (instance_variables - %i[@sql @filename @name @binds @cast]).each do
        instance_variable_set(_1, nil)
      end
      self
    end
    private :reset!

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

      with_sql(sql).tap do |q|
        # Merge collected binds with existing binds (convert array to hash if needed)
        existing = @binds.is_a?(Hash) ? @binds : {}
        new_binds = existing.merge(collected)
        q.instance_variable_set(:@binds, new_binds) if new_binds.any?
      end
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

    # Executes the query and returns all matching rows.
    #
    # @param binds [Array, Hash, nil] bind parameters (positional or named)
    # @param select [String, nil] override the SELECT clause
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Result] the query results with optional type casting
    #
    # @example Simple query with positional binds
    #   AppQuery("SELECT * FROM users WHERE id = $1").select_all(binds: [1])
    #
    # @example Named binds
    #   AppQuery("SELECT * FROM users WHERE id = :id").select_all(binds: {id: 1})
    #
    # @example With type casting
    #   AppQuery("SELECT created_at FROM users")
    #     .select_all(cast: {created_at: ActiveRecord::Type::DateTime.new})
    #
    # @example Override SELECT clause
    #   AppQuery("SELECT * FROM users").select_all(select: "COUNT(*)")
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    # @raise [ArgumentError] if mixing positional binds with collected named binds
    #
    # TODO: have aliases for common casts: select_all(cast: {"today" => :date})
    def select_all(binds: nil, select: nil, cast: self.cast)
      with_select(select).render({}).then do |aq|
        # Support both positional (array) and named (hash) binds
        if binds.is_a?(Array)
          if @binds.is_a?(Hash) && @binds.any?
            raise ArgumentError, "Cannot use positional binds (Array) when query has collected named binds from values()/bind() helpers. Use named binds (Hash) instead."
          end
          # Positional binds using $1, $2, etc.
          ActiveRecord::Base.connection.select_all(aq.to_s, name, binds).then do |result|
            Result.from_ar_result(result, cast)
          end
        else
          # Named binds - merge collected binds with explicitly passed binds
          merged_binds = (@binds.is_a?(Hash) ? @binds : {}).merge(binds || {})
          if merged_binds.any?
            sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
              Arel.sql(aq.to_s, **merged_binds)
            else
              ActiveRecord::Base.sanitize_sql_array([aq.to_s, **merged_binds])
            end
            ActiveRecord::Base.connection.select_all(sql, name).then do |result|
              Result.from_ar_result(result, cast)
            end
          else
            ActiveRecord::Base.connection.select_all(aq.to_s, name).then do |result|
              Result.from_ar_result(result, cast)
            end
          end
        end
      end
    rescue NameError => e
      # Prevent any subclasses, e.g. NoMethodError
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before select-ing."
    end

    # Executes the query and returns the first row.
    #
    # @param binds [Array, Hash, nil] bind parameters (positional or named)
    # @param select [String, nil] override the SELECT clause
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Hash, nil] the first row as a hash, or nil if no results
    #
    # @example
    #   AppQuery("SELECT * FROM users WHERE id = $1").select_one(binds: [1])
    #   # => {"id" => 1, "name" => "Alice"}
    #
    # @see #select_all
    def select_one(binds: nil, select: nil, cast: self.cast)
      select_all(binds:, select:, cast:).first
    end

    # Executes the query and returns the first value of the first row.
    #
    # @param binds [Array, Hash, nil] bind parameters (positional or named)
    # @param select [String, nil] override the SELECT clause
    # @param cast [Boolean, Hash, Array] type casting configuration
    # @return [Object, nil] the first value, or nil if no results
    #
    # @example
    #   AppQuery("SELECT COUNT(*) FROM users").select_value
    #   # => 42
    #
    # @see #select_one
    def select_value(binds: nil, select: nil, cast: self.cast)
      select_one(binds:, select:, cast:)&.values&.first
    end

    # Executes an INSERT query.
    #
    # @param binds [Array, Hash] bind parameters for the query
    # @param returning [String, nil] columns to return (Rails 7.1+ only)
    # @return [Integer, Object] the inserted ID or returning value
    #
    # @example With positional binds
    #   AppQuery(<<~SQL).insert(binds: ["Let's learn SQL!"])
    #     INSERT INTO videos(title, created_at, updated_at) VALUES($1, now(), now())
    #   SQL
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
    def insert(binds: [], returning: nil)
      # ActiveRecord::Base.connection.insert(sql, name, _pk = nil, _id_value = nil, _sequence_name = nil, binds, returning: nil)
      if returning && ActiveRecord::VERSION::STRING.to_f < 7.1
        raise ArgumentError, "The 'returning' option requires Rails 7.1+. Current version: #{ActiveRecord::VERSION::STRING}"
      end

      binds = binds.presence || @binds
      render({}).then do |aq|
        if binds.is_a?(Hash)
          sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
            Arel.sql(aq.to_s, **binds)
          else
            ActiveRecord::Base.sanitize_sql_array([aq.to_s, **binds])
          end
          if ActiveRecord::VERSION::STRING.to_f >= 7.1
            ActiveRecord::Base.connection.insert(sql, name, returning:)
          else
            ActiveRecord::Base.connection.insert(sql, name)
          end
        elsif ActiveRecord::VERSION::STRING.to_f >= 7.1
          # pk is the less flexible returning
          ActiveRecord::Base.connection.insert(aq.to_s, name, _pk = nil, _id_value = nil, _sequence_name = nil, binds, returning:)
        else
          ActiveRecord::Base.connection.insert(aq.to_s, name, _pk = nil, _id_value = nil, _sequence_name = nil, binds)
        end
      end
    rescue NameError => e
      # Prevent any subclasses, e.g. NoMethodError
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before select-ing."
    end

    # Executes an UPDATE query.
    #
    # @param binds [Array, Hash] bind parameters for the query
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
    def update(binds: [])
      binds = binds.presence || @binds
      render({}).then do |aq|
        if binds.is_a?(Hash)
          sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
            Arel.sql(aq.to_s, **binds)
          else
            ActiveRecord::Base.sanitize_sql_array([aq.to_s, **binds])
          end
          ActiveRecord::Base.connection.update(sql, name)
        else
          ActiveRecord::Base.connection.update(aq.to_s, name, binds)
        end
      end
    rescue NameError => e
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before updating."
    end

    # Executes a DELETE query.
    #
    # @param binds [Array, Hash] bind parameters for the query
    # @return [Integer] the number of deleted rows
    #
    # @example With named binds
    #   AppQuery("DELETE FROM videos WHERE id = :id").delete(binds: {id: 1})
    #
    # @example With positional binds
    #   AppQuery("DELETE FROM videos WHERE id = $1").delete(binds: [1])
    #
    # @raise [UnrenderedQueryError] if the query contains unrendered ERB
    def delete(binds: [])
      binds = binds.presence || @binds
      render({}).then do |aq|
        if binds.is_a?(Hash)
          sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
            Arel.sql(aq.to_s, **binds)
          else
            ActiveRecord::Base.sanitize_sql_array([aq.to_s, **binds])
          end
          ActiveRecord::Base.connection.delete(sql, name)
        else
          ActiveRecord::Base.connection.delete(aq.to_s, name, binds)
        end
      end
    rescue NameError => e
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before deleting."
    end

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
    def cte_names
      tokens.filter { _1[:t] == "CTE_IDENTIFIER" }.map { _1[:v] }
    end

    # Returns a new query with different bind parameters.
    #
    # @param binds [Array, Hash] the new bind parameters
    # @return [Q] a new query object with the specified binds
    #
    # @example
    #   query = AppQuery("SELECT * FROM users WHERE id = :id")
    #   query.with_binds(id: 1).select_one
    def with_binds(binds)
      deep_dup.tap do
        _1.instance_variable_set(:@binds, binds)
      end
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
      deep_dup.tap do
        _1.instance_variable_set(:@cast, cast)
      end
    end

    # Returns a new query with different SQL.
    #
    # @param sql [String] the new SQL string
    # @return [Q] a new query object with the specified SQL
    def with_sql(sql)
      deep_dup.tap do
        _1.instance_variable_set(:@sql, sql)
      end
    end

    # Returns a new query with a modified SELECT statement.
    #
    # If the query has a CTE named `"_"`, replaces the SELECT statement.
    # Otherwise, wraps the original query in a `"_"` CTE and uses the new SELECT.
    #
    # @param sql [String, nil] the new SELECT statement (nil returns self)
    # @return [Q] a new query object with the modified SELECT
    #
    # @example
    #   AppQuery("SELECT id, name FROM users").with_select("SELECT COUNT(*) FROM _")
    #   # => "WITH _ AS (\n  SELECT id, name FROM users\n)\nSELECT COUNT(*) FROM _"
    def with_select(sql)
      return self if sql.nil?
      if cte_names.include?("_")
        with_sql(tokens.each_with_object([]) do |token, acc|
          v = (token[:t] == "SELECT") ? sql : token[:v]
          acc << v
        end.join)
      else
        append_cte("_ as (\n  #{select}\n)").with_select(sql)
      end
    end

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

    # Returns the SQL string.
    #
    # @return [String] the SQL query string
    def to_s
      @sql
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

require "app_query/base" if defined?(ActiveRecord::Base)
