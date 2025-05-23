# frozen_string_literal: true

require_relative "app_query/version"
require_relative "app_query/tokenizer"
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

  class Q
    attr_reader :name, :sql, :binds, :cast

    def initialize(sql, name: nil, filename: nil, binds: [], cast: true)
      @sql = sql
      @name = name
      @filename = filename
      @binds = binds
      @cast = cast
    end

    def deep_dup
      super.send(:reset!)
    end

    def reset!
      (instance_variables - %i[@sql @filename @name @binds @cast]).each do
        instance_variable_set(_1, nil)
      end
      self
    end
    private :reset!

    def render(params)
      params ||= []
      with_sql(to_erb.result(render_helper(params).get_binding))
    end

    def to_erb
      ERB.new(sql, trim_mode: "-").tap { _1.location = [@filename, 0] if @filename }
    end
    private :to_erb

    def render_helper(params)
      Module.new do
        extend self

        params.each do |k, v|
          define_method(k) { v }
          instance_variable_set(:"@#{k}", v)
        end

        # Examples
        #   <%= order_by({year: :desc, month: :desc}) %>
        #   #=> ORDER BY year DESC, month DESC
        #
        # Using variable:
        #   <%= order_by(ordering) %>
        # NOTE Raises when ordering not provided or when blank.
        #
        # Make it optional:
        #   <%= @ordering.presence && order_by(ordering) %>
        #
        def order_by(hash)
          raise ArgumentError, "Provide columns to sort by, e.g. order_by(id: :asc)  (got #{hash.inspect})." unless hash.present?
          "ORDER BY " + hash.map do |k, v|
            v.nil? ? k : [k, v.upcase].join(" ")
          end.join(", ")
        end

        def get_binding
          binding
        end
      end
    end
    private :render_helper

    def select_all(binds: [], select: nil, cast: self.cast)
      binds = binds.presence || @binds
      with_select(select).render({}).then do |aq|
        if binds.is_a?(Hash)
          sql = if ActiveRecord::VERSION::STRING.to_f >= 7.1
            Arel.sql(aq.to_s, **binds)
          else
            ActiveRecord::Base.sanitize_sql_array([aq.to_s, **binds])
          end
          ActiveRecord::Base.connection.select_all(sql, name).then do |result|
            Result.from_ar_result(result, cast)
          end
        else
          ActiveRecord::Base.connection.select_all(aq.to_s, name, binds).then do |result|
            Result.from_ar_result(result, cast)
          end
        end
      end
    rescue NameError => e
      # Prevent any subclasses, e.g. NoMethodError
      raise e unless e.instance_of?(NameError)
      raise UnrenderedQueryError, "Query is ERB. Use #render before select-ing."
    end

    def select_one(binds: [], select: nil, cast: self.cast)
      select_all(binds:, select:, cast:).first
    end

    def select_value(binds: [], select: nil, cast: self.cast)
      select_one(binds:, select:, cast:)&.values&.first
    end

    def tokens
      @tokens ||= tokenizer.run
    end

    def tokenizer
      @tokenizer ||= Tokenizer.new(to_s)
    end

    def cte_names
      tokens.filter { _1[:t] == "CTE_IDENTIFIER" }.map { _1[:v] }
    end

    def with_binds(binds)
      deep_dup.tap do
        _1.instance_variable_set(:@binds, binds)
      end
    end

    def with_cast(cast)
      deep_dup.tap do
        _1.instance_variable_set(:@cast, cast)
      end
    end

    def with_sql(sql)
      deep_dup.tap do
        _1.instance_variable_set(:@sql, sql)
      end
    end

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

    def select
      tokens.find { _1[:t] == "SELECT" }&.[](:v)
    end

    def recursive?
      !!tokens.find { _1[:t] == "RECURSIVE" }
    end

    # example:
    #  AppQuery("select 1").prepend_cte("foo as(select 1)")
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

    # example:
    #  AppQuery("select 1").append_cte("foo as(select 1)")
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

    # Replaces an existing cte.
    # Raises `ArgumentError` when cte does not exist.
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

    def to_s
      @sql
    end
  end
end

def AppQuery(...)
  AppQuery::Q.new(...)
end

begin
  require "rspec"
rescue LoadError
end

require_relative "app_query/rspec" if Object.const_defined? :RSpec
