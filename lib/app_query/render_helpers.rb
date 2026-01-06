# frozen_string_literal: true

module AppQuery
  # Provides helper methods for rendering SQL templates in ERB.
  #
  # These helpers are available within ERB templates when using {Q#render}.
  # They provide safe SQL construction with parameterized queries.
  #
  # @note These methods require +@collected_binds+ (Hash) and
  #   +@placeholder_counter+ (Integer) instance variables to be initialized
  #   in the including context.
  #
  # @example Basic usage in an ERB template
  #   SELECT * FROM users WHERE name = <%= bind(name) %>
  #   <%= order_by(sorting) %>
  #
  # @see Q#render
  module RenderHelpers
    # Quotes a value for safe inclusion in SQL using ActiveRecord's quoting.
    #
    # Use this helper when you need to embed a literal value directly in SQL
    # rather than using a bind parameter. This is useful for values that need
    # to be visible in the SQL string itself.
    #
    # @param value [Object] the value to quote (typically a String or Number)
    # @return [String] the SQL-safe quoted value
    #
    # @example Quoting a string with special characters
    #   quote("Let's learn SQL!") #=> "'Let''s learn SQL!'"
    #
    # @example In an ERB template
    #   INSERT INTO articles (title) VALUES(<%= quote(title) %>)
    #
    # @note Prefer {#bind} for parameterized queries when possible, as it
    #   provides better security and query plan caching.
    #
    # @see #bind
    def quote(value)
      ActiveRecord::Base.connection.quote(value)
    end

    # Creates a named bind parameter placeholder and collects the value.
    #
    # This is the preferred way to include dynamic values in SQL queries.
    # The value is collected internally and a placeholder (e.g., +:b1+) is
    # returned for insertion into the SQL template.
    #
    # @param value [Object] the value to bind (any type supported by ActiveRecord)
    # @return [String] the placeholder string (e.g., ":b1", ":b2", etc.)
    #
    # @example Basic bind usage
    #   bind("Some title") #=> ":b1" (with "Some title" added to collected binds)
    #
    # @example In an ERB template
    #   SELECT * FROM videos WHERE title = <%= bind(title) %>
    #   # Results in: SELECT * FROM videos WHERE title = :b1
    #   # With binds: {b1: <value of title>}
    #
    # @example Multiple binds
    #   SELECT * FROM t WHERE a = <%= bind(val1) %> AND b = <%= bind(val2) %>
    #   # Results in: SELECT * FROM t WHERE a = :b1 AND b = :b2
    #
    # @see #values for binding multiple values in a VALUES clause
    # @see #quote for embedding quoted literals directly
    def bind(value)
      collect_bind(value)
    end

    # Generates a SQL VALUES clause from a collection with automatic bind parameters.
    #
    # Supports three input formats:
    # 1. *Array of Arrays* - Simple row data without column names
    # 2. *Array of Hashes* - Row data with automatic column name extraction
    # 3. *Collection with block* - Custom value transformation per row
    #
    # @param coll [Array<Array>, Array<Hash>] the collection of row data
    # @param skip_columns [Boolean] when true, omits the column name list
    #   (useful for UNION ALL or CTEs where column names are defined elsewhere)
    # @yield [item] optional block to transform each item into an array of SQL expressions
    # @yieldparam item [Object] each item from the collection
    # @yieldreturn [Array<String>] array of SQL expressions for the row values
    # @return [String] the complete VALUES clause SQL fragment
    #
    # @example Array of arrays (simplest form)
    #   values([[1, "Title A"], [2, "Title B"]])
    #   #=> "VALUES (:b1, :b2),\n(:b3, :b4)"
    #   # binds: {b1: 1, b2: "Title A", b3: 2, b4: "Title B"}
    #
    # @example Array of hashes (with automatic column names)
    #   values([{id: 1, title: "Video A"}, {id: 2, title: "Video B"}])
    #   #=> "(id, title) VALUES (:b1, :b2),\n(:b3, :b4)"
    #
    # @example Hashes with mixed keys (NULL for missing values)
    #   values([{title: "A"}, {title: "B", published_on: "2024-01-01"}])
    #   #=> "(title, published_on) VALUES (:b1, NULL),\n(:b2, :b3)"
    #
    # @example Skip columns for UNION ALL
    #   SELECT id FROM articles UNION ALL <%= values([{id: 1}], skip_columns: true) %>
    #   #=> "SELECT id FROM articles UNION ALL VALUES (:b1)"
    #
    # @example With block for custom expressions
    #   values(videos) { |v| [bind(v[:id]), quote(v[:title]), 'now()'] }
    #   #=> "VALUES (:b1, 'Escaped Title', now()), (:b2, 'Other', now())"
    #
    # @example In a CTE
    #   WITH articles(id, title) AS (<%= values(data) %>)
    #   SELECT * FROM articles
    #
    # @see #bind for individual value binding
    # @see #quote for quoting literal values
    #
    # TODO: Add types: parameter to cast bind placeholders (needed for UNION ALL
    #   where PG can't infer types). E.g. values([[1]], types: [:integer])
    #   would generate VALUES (:b1::integer)
    def values(coll, skip_columns: false, &block)
      first = coll.first

      # For hash collections, collect all unique keys
      if first.is_a?(Hash) && !block
        all_keys = coll.flat_map(&:keys).uniq

        rows = coll.map do |row|
          vals = all_keys.map { |k| row.key?(k) ? collect_bind(row[k]) : "NULL" }
          "(#{vals.join(", ")})"
        end

        columns = skip_columns ? "" : "(#{all_keys.join(", ")}) "
        "#{columns}VALUES #{rows.join(",\n")}"
      else
        # Arrays or block - current behavior
        rows = coll.map do |item|
          vals = if block
            block.call(item)
          elsif item.is_a?(Array)
            item.map { |v| collect_bind(v) }
          else
            [collect_bind(item)]
          end
          "(#{vals.join(", ")})"
        end
        "VALUES #{rows.join(",\n")}"
      end
    end

    # Generates an ORDER BY clause from a hash of column directions.
    #
    # Converts a hash of column names and sort directions into a valid
    # SQL ORDER BY clause.
    #
    # @param hash [Hash{Symbol, String => Symbol, String, nil}] column names mapped to
    #   sort directions (+:asc+, +:desc+, +"ASC"+, +"DESC"+) or nil for default
    # @return [String] the complete ORDER BY clause
    #
    # @example Basic ordering
    #   order_by(year: :desc, month: :desc)
    #   #=> "ORDER BY year DESC, month DESC"
    #
    # @example Column without direction (uses database default)
    #   order_by(id: nil)
    #   #=> "ORDER BY id"
    #
    # @example SQL literal
    #   order_by("RANDOM()")
    #   #=> "ORDER BY RANDOM()"
    #
    # @example In an ERB template with a variable
    #   SELECT * FROM articles
    #   <%= order_by(ordering) %>
    #
    # @example Making it optional (when ordering may not be provided)
    #   <%= @order.presence && order_by(ordering) %>
    #
    # @example With default fallback
    #   <%= order_by(@order.presence || {id: :desc}) %>
    #
    # @raise [ArgumentError] if hash is blank (nil, empty, or not present)
    #
    # @note The hash must not be blank. Use conditional ERB for optional ordering.
    def order_by(order)
      usage = <<~USAGE
        Provide columns to sort by, e.g. order_by(id: :asc), or SQL-literal, e.g. order_by("RANDOM()")  (got #{order.inspect}).
      USAGE
      raise ArgumentError, usage unless order.present?

      case order
      when String then "ORDER BY #{order}"
      when Hash
        "ORDER BY " + order.map do |k, v|
          v.nil? ? k : [k, v.upcase].join(" ")
        end.join(", ")
      else
        raise ArgumentError, usage
      end
    end

    # Generates a LIMIT/OFFSET clause for pagination.
    #
    # @param page [Integer] the page number (1-indexed)
    # @param per_page [Integer] the number of items per page
    # @return [String] the LIMIT/OFFSET clause
    #
    # @example Basic pagination
    #   paginate(page: 1, per_page: 25)
    #   #=> "LIMIT 25 OFFSET 0"
    #
    # @example Second page
    #   paginate(page: 2, per_page: 25)
    #   #=> "LIMIT 25 OFFSET 25"
    #
    # @example In an ERB template
    #   SELECT * FROM articles
    #   ORDER BY created_at DESC
    #   <%= paginate(page: page, per_page: per_page) %>
    #
    # @raise [ArgumentError] if page or per_page is not a positive integer
    def paginate(page:, per_page:)
      return "" if page.nil?
      raise ArgumentError, "page must be a positive integer (got #{page.inspect})" unless page.is_a?(Integer) && page > 0
      raise ArgumentError, "per_page must be a positive integer (got #{per_page.inspect})" unless per_page.is_a?(Integer) && per_page > 0

      offset = (page - 1) * per_page
      "LIMIT #{per_page} OFFSET #{offset}"
    end

    private

    # Collects a value as a bind parameter and returns the placeholder name.
    #
    # This is the internal mechanism used by {#bind} and {#values} to
    # accumulate bind values during template rendering. Each call generates
    # a unique placeholder name (b1, b2, b3, ...).
    #
    # @api private
    # @param value [Object] the value to collect
    # @return [String] the placeholder string with colon prefix (e.g., ":b1")
    def collect_bind(value)
      @placeholder_counter += 1
      key = :"b#{@placeholder_counter}"
      @collected_binds[key] = value
      ":#{key}"
    end
  end
end
